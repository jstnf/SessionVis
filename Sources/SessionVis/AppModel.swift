import SwiftUI
import AppKit
import SessionVisCore

@MainActor @Observable
final class AppModel {
    var directory: String?
    var snapshot: StoreSnapshot = .empty
    var treeFileCount = 0
    var treeTruncated = false
    var errorMessage: String?
    var listCollapsed = false
    var selectedAgent: AgentID?
    var hover: Hit?
    var hoverPoint: CGPoint?
    var isReplay = false
    var hookInstalled = false
    /// True from source start until it reports `.initialLoadComplete`; the scene is not fed meanwhile.
    var isLoading = false
    let projectsRoot = SessionDiscovery.projectsRoot()
    let box = SimulationBox()

    @ObservationIgnored private var store: SessionStore?
    @ObservationIgnored private var live: LiveSource?
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var launched = false
    @ObservationIgnored private var openGeneration = 0
    @ObservationIgnored private var watcher: RepoWatcher?
    @ObservationIgnored private var watcherTask: Task<Void, Never>?
    static let lastDirectoryKey = "lastDirectory"

    var mains: [AgentSnapshot] { snapshot.agents.filter { !$0.isSubagent } }
    var subagentCount: Int { snapshot.agents.count - mains.count }
    var windowTitle: String { directory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "SessionVis" }
    var windowSubtitle: String {
        guard let d = directory else { return "Open a directory to begin" }
        var s = "\(d) · \(mains.count) sessions · \(subagentCount) subagents · \(treeFileCount) files"
        if treeTruncated { s += " · truncated" }
        if isReplay { s += " · replay" }
        return s
    }

    // MARK: - Launch

    func handleLaunch() async {
        guard !launched else { return }
        launched = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let candidates = [
            Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Assets/AppIcon.icns"),
        ].compactMap { $0 }
        if let iconURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }), let image = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = image
        }
        let options = LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
        if let replay = options.replayTranscript {
            guard let dir = options.directory else {
                errorMessage = "--replay needs a directory argument to seed the tree."
                return
            }
            await startReplay(transcript: URL(fileURLWithPath: replay), speed: options.speed, directory: dir)
        } else if let dir = options.directory ?? UserDefaults.standard.string(forKey: Self.lastDirectoryKey) {
            await open(directory: dir)
        } else {
            presentOpenPanel()
        }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        panel.message = "Choose the directory whose Claude Code sessions to visualise"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.open(directory: url.path) }
        }
    }

    // MARK: - Sources

    func open(directory raw: String) async {
        let dir = PathFolder.normalize(raw)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue else {
            errorMessage = "\(dir) is not a directory."
            return
        }
        stop()
        openGeneration += 1
        let generation = openGeneration
        directory = dir
        isReplay = false
        errorMessage = nil
        UserDefaults.standard.set(dir, forKey: Self.lastDirectoryKey)
        guard FileManager.default.fileExists(atPath: projectsRoot.path) else {
            errorMessage = "Claude Code's projects folder was not found at \(projectsRoot.path)."
            return
        }
        let tree = await loadTree(dir)
        guard generation == openGeneration else { return }
        applyTree(tree, root: dir)
        let watcher = RepoWatcher(directory: dir, initial: tree)
        self.watcher = watcher
        watcher.start()
        watcherTask = Task { [weak self] in
            for await delta in watcher.deltas {
                guard let self, self.openGeneration == generation else { return }
                self.box.apply(delta: delta, now: Date())
                self.treeFileCount = self.box.simulation.visibleFileCount
            }
        }
        let folder = PathFolder(root: dir)
        let store = SessionStore(folder: folder)
        let live = LiveSource(folder: folder, projectsRoot: projectsRoot, spoolDirectory: HookSnippet.defaultSpoolDirectory)
        self.store = store
        self.live = live
        hookInstalled = HookSnippet.isInstalled(settingsURL: HookSnippet.defaultSettingsURL())
        HookSnippet.createMarker()
        startPump(live.events, store: store, generation: generation)
        await live.start()
        guard generation == openGeneration else { return }
        startPolling(store)
    }

    func startReplay(transcript: URL, speed: Double, directory raw: String) async {
        stop()
        openGeneration += 1
        let generation = openGeneration
        let dir = PathFolder.normalize(raw)
        directory = dir
        isReplay = true
        errorMessage = nil
        let tree = await loadTree(dir)
        guard generation == openGeneration else { return }
        applyTree(tree, root: dir)
        let store = SessionStore(folder: PathFolder(root: dir))
        self.store = store
        let source = ReplaySource(transcriptURL: transcript, speed: speed)
        startPump(source.events(), store: store, generation: generation)
        startPolling(store)
    }

    /// Feeds the store in order; flips `isLoading` off once everything on disk at launch has been applied.
    private func startPump(_ events: AsyncStream<SourceEvent>, store: SessionStore, generation: Int) {
        isLoading = true
        pumpTask = Task { [weak self] in
            for await event in events {
                await store.apply(event)
                if event == .initialLoadComplete, let self, generation == self.openGeneration { self.isLoading = false }
            }
        }
    }

    private func loadTree(_ dir: String) async -> FileTree {
        await Task.detached(priority: .userInitiated) { FileTreeScanner.scan(directory: dir) }.value
    }

    private func applyTree(_ tree: FileTree, root: String) {
        treeFileCount = tree.fileCount
        treeTruncated = tree.truncated
        box.reset(tree: tree, rootPath: root)
    }

    private func startPolling(_ store: SessionStore) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let snap = await store.snapshot()
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if snap != self.snapshot { self.snapshot = snap }
                let visible = self.box.simulation.visibleFileCount
                if visible != self.treeFileCount { self.treeFileCount = visible }
                if let sel = self.selectedAgent, !snap.agents.contains(where: { $0.id == sel }) { self.selectedAgent = nil }
                // While loading, the list may update but the scene waits, so history lands as one priming pass.
                if !self.isLoading { self.box.apply(snap, now: Date()) }
                try? await Task.sleep(for: .seconds(Constants.snapshotInterval))
                guard !Task.isCancelled else { return }
            }
        }
    }

    func stop() {
        pumpTask?.cancel(); pumpTask = nil
        pollTask?.cancel(); pollTask = nil
        watcherTask?.cancel(); watcherTask = nil
        watcher?.stop(); watcher = nil
        if let live { Task { await live.stop() } }
        if live != nil { HookSnippet.removeMarker() }
        live = nil
        isLoading = false
        store = nil
        snapshot = .empty
        selectedAgent = nil
        hover = nil
    }

    // MARK: - Selection

    /// Toggle: selecting the selected agent again deselects and stops following.
    func select(_ id: AgentID?) {
        if id == nil || selectedAgent == id {
            selectedAgent = nil
            box.setFollow(nil)
        } else {
            selectedAgent = id
            box.setFollow(id)
        }
    }

    // MARK: - Input

    func handleScroll(_ delta: CGSize) {
        box.pan(by: delta)
        if selectedAgent != nil { selectedAgent = nil }   // follow was cleared by the pan
    }

    func handleMagnify(_ factor: CGFloat, at point: CGPoint) {
        box.zoom(by: factor, around: point)
        if selectedAgent != nil { selectedAgent = nil }
    }

    func handleMove(_ point: CGPoint?) {
        hoverPoint = point
        let hit = point.flatMap { box.simulation.hitTest(screen: $0) }
        if hit != hover { hover = hit }
    }

    func handleClick(_ point: CGPoint, clickCount: Int) {
        if clickCount == 2 {
            box.resetCamera()
            selectedAgent = nil
            return
        }
        if case .avatar(let id) = box.simulation.hitTest(screen: point) { select(id) }
    }

    /// Tooltip text for the current hover.
    func tooltipLines() -> [String] {
        guard let hover else { return [] }
        let sim = box.simulation
        switch hover {
        case .node(let path):
            guard let node = sim.tree.node(path) else { return [] }
            if node.isDirectory {
                return [path.isRoot ? "/" : path.string, "\(node.leafCount) files"]
            }
            var lines = [path.string]
            if let t = sim.tints[path] {
                let title = snapshot.agents.first { $0.id == t.toucher }?.title ?? t.toucherTitle ?? t.toucher.raw
                let ago = Int(Date().timeIntervalSince(t.touchedAt))
                lines.append("last touched by \(title) · \(ago)s ago")
            }
            if let wt = snapshot.recentTouches.last(where: { $0.path == path })?.worktree { lines.append("in worktree \(wt)") }
            return lines
        case .avatar(let id):
            guard let a = snapshot.agents.first(where: { $0.id == id }) else { return [] }
            var lines = [a.title, a.status.word]
            if let b = a.branch { lines.append(b) }
            if let w = a.worktree { lines.append("worktree \(w)") }
            lines.append("\(a.touchCount) touches")
            return lines
        }
    }
}
