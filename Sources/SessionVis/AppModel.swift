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
    /// The registered worktrees, for Settings.
    var worktrees: [Worktree] = []
    /// Hidden-file rules for the watched directory, and what they currently hide.
    var filter = FileFilter()
    var hiddenFileCount = 0
    var suggestions: [Suggestion] = []
    /// True from source start until it reports `.initialLoadComplete`; the scene is not fed meanwhile.
    var isLoading = false
    /// Whether any main session is live; stored so the Session menu does not re-evaluate on every snapshot.
    var hasLiveMain = false
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
    @ObservationIgnored private var folder: PathFolder?
    @ObservationIgnored private var registryWatcher: FileWatcher?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private let filterStore = FileFilterStore()
    static let lastDirectoryKey = "lastDirectory"

    var mains: [AgentSnapshot] { snapshot.agents.filter { !$0.isSubagent } }
    /// Main sessions that have not ended, in list order: what Tab steps through.
    var liveMains: [AgentID] { mains.filter { !$0.status.isEnded }.map(\.id) }
    var isFollowing: Bool { selectedAgent != nil }
    /// The main session the follow is on: the followed main itself, or a followed subagent's parent.
    private var followedMain: AgentID? {
        guard let id = selectedAgent else { return nil }
        guard let a = snapshot.agents.first(where: { $0.id == id }) else { return id }
        return a.parent ?? a.id
    }
    /// Where the followed main last sat in `liveMains`, kept by the snapshot poll alone, so Tab can carry on from that slot once it ends.
    @ObservationIgnored private var followedIndex: Int?
    private func rememberFollowedIndex() {
        if selectedAgent == nil { followedIndex = nil }
        else if let m = followedMain, let i = liveMains.firstIndex(of: m) { followedIndex = i }
    }
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
        filter = filterStore.filter(for: dir)
        isReplay = false
        errorMessage = nil
        UserDefaults.standard.set(dir, forKey: Self.lastDirectoryKey)
        guard FileManager.default.fileExists(atPath: projectsRoot.path) else {
            errorMessage = "Claude Code's projects folder was not found at \(projectsRoot.path)."
            return
        }
        let folder = await Task.detached(priority: .userInitiated) { RegistryRefresh.folder(root: dir) }.value
        guard generation == openGeneration else { return }
        let tree = await loadTree(folder)
        guard generation == openGeneration else { return }
        self.folder = folder
        worktrees = folder.worktrees
        applyTree(tree, folder: folder)
        let store = SessionStore(folder: folder)
        let watcher = RepoWatcher(folder: folder, initial: tree)
        self.watcher = watcher
        watcher.start()
        watcherTask = Task { [weak self] in
            for await delta in watcher.deltas {
                guard let self, self.openGeneration == generation else { return }
                self.box.apply(delta: delta, now: Date())
                self.treeFileCount = self.box.simulation.visibleFileCount
                let paths = delta.added + delta.changed
                if !paths.isEmpty { await store.apply(.diskChanges(DiskChange(origin: delta.origin, paths: paths, at: delta.at))) }
            }
        }
        let live = LiveSource(folder: folder, projectsRoot: projectsRoot, spoolDirectory: HookSnippet.defaultSpoolDirectory)
        self.store = store
        self.live = live
        hookInstalled = HookSnippet.isInstalled(settingsURL: HookSnippet.defaultSettingsURL())
        HookSnippet.createMarker()
        startPump(live.events, store: store, generation: generation)
        await live.start()
        guard generation == openGeneration else { return }
        startPolling(store)
        await armRegistryWatcher(root: dir, generation: generation)
    }

    func startReplay(transcript: URL, speed: Double, directory raw: String) async {
        stop()
        openGeneration += 1
        let generation = openGeneration
        let dir = PathFolder.normalize(raw)
        directory = dir
        isReplay = true
        errorMessage = nil
        filter = filterStore.filter(for: dir)
        let folder = await Task.detached(priority: .userInitiated) { RegistryRefresh.folder(root: dir) }.value
        guard generation == openGeneration else { return }
        let tree = await loadTree(folder)
        guard generation == openGeneration else { return }
        self.folder = folder
        worktrees = folder.worktrees
        applyTree(tree, folder: folder)
        let store = SessionStore(folder: folder)
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

    private func loadTree(_ folder: PathFolder) async -> FileTree {
        await Task.detached(priority: .userInitiated) { FileTreeScanner.scan(folder: folder) }.value
    }

    private func applyTree(_ tree: FileTree, folder: PathFolder) {
        treeTruncated = tree.truncated
        box.reset(tree: tree, folder: folder, filter: filter)
        treeFileCount = box.simulation.visibleFileCount
        hiddenFileCount = box.simulation.hiddenFileCount
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
                let hiddenCount = self.box.simulation.hiddenFileCount
                if hiddenCount != self.hiddenFileCount { self.hiddenFileCount = hiddenCount }
                // Selection mirrors the follow: the simulation hands it to the parent when a subagent vanishes and drops it
                // when the orb vanishes or a pan or pinch cancels it.
                if !self.isLoading, self.selectedAgent != self.box.simulation.followedAgent { self.selectedAgent = self.box.simulation.followedAgent }
                self.rememberFollowedIndex()
                let live = !self.liveMains.isEmpty
                if live != self.hasLiveMain { self.hasLiveMain = live }
                // While loading, the list may update but the scene waits, so history lands as one priming pass.
                if !self.isLoading { self.box.apply(snap, now: Date()) }
                try? await Task.sleep(for: .seconds(Constants.snapshotInterval))
                guard !Task.isCancelled else { return }
            }
        }
    }

    // MARK: - Worktree registry

    /// Watches `<git common dir>/worktrees`, which git writes on `worktree add`, `remove` and `prune`. Until that
    /// directory exists (no worktree was ever added) the watcher sits on its parent, the common dir, and moves over
    /// the first time the directory appears.
    private func armRegistryWatcher(root: String, generation: Int) async {
        let registry = await Task.detached(priority: .utility) { WorktreeLister.registryDirectory(root: root) }.value
        guard generation == openGeneration, let registry else { return }
        watchRegistry(registry, generation: generation)
        await refreshWorktrees()
    }

    /// The directory to watch for `registry` right now: the registry itself once it exists, else its parent.
    private func registryWatchPath(_ registry: String) -> String {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: registry, isDirectory: &isDirectory) && isDirectory.boolValue
        return exists ? registry : (registry as NSString).deletingLastPathComponent
    }

    /// Git removes the emptied directory with the last worktree and may recreate it at once, so every event opens a
    /// fresh watcher on whichever node is right now; a watcher left on an unlinked inode would never fire again.
    private func watchRegistry(_ registry: String, generation: Int) {
        registryWatcher?.cancel()
        registryWatcher = FileWatcher(path: registryWatchPath(registry), directory: true) { [weak self] in
            Task { @MainActor in
                guard let self, self.openGeneration == generation else { return }
                self.watchRegistry(registry, generation: generation)
                await self.refreshWorktrees()
            }
        }
    }

    /// Lists the worktrees again and, when the registry changed, hands the new folder to the store, the live source,
    /// the watcher (whose rescan emits the deltas) and the simulation, in that order. Calls that arrive while a
    /// listing is in flight coalesce into one more pass, so the newest listing always wins.
    func refreshWorktrees() async {
        if refreshing { refreshRequested = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshRequested = false
            let generation = openGeneration
            guard !isReplay, let root = folder?.root else { return }
            // Git creates the entry's directory before it fills it in; give it a moment.
            try? await Task.sleep(for: .seconds(Constants.registryRefreshDelay))
            let listed = await Task.detached(priority: .utility) { WorktreeLister.list(root: root) }.value
            guard generation == openGeneration, let current = folder, let next = RegistryRefresh.next(current: current, listed: listed) else { continue }
            if let store { await store.setFolder(next) }
            guard generation == openGeneration else { continue }
            if let live { await live.setFolder(next) }
            guard generation == openGeneration else { continue }
            folder = next
            worktrees = next.worktrees
            watcher?.setFolder(next)
            box.setFolder(next)
        } while refreshRequested
    }

    func stop() {
        openGeneration += 1
        pumpTask?.cancel(); pumpTask = nil
        pollTask?.cancel(); pollTask = nil
        watcherTask?.cancel(); watcherTask = nil
        watcher?.stop(); watcher = nil
        registryWatcher?.cancel(); registryWatcher = nil
        refreshing = false
        refreshRequested = false
        folder = nil
        worktrees = []
        if let live { Task { await live.stop() } }
        if live != nil { HookSnippet.removeMarker() }
        live = nil
        isLoading = false
        store = nil
        snapshot = .empty
        selectedAgent = nil
        hover = nil
    }

    // MARK: - Hidden files

    func setFilter(_ newFilter: FileFilter) {
        filter = newFilter
        if let dir = directory { filterStore.save(newFilter, for: dir) }
        box.setFilter(newFilter)
        treeFileCount = box.simulation.visibleFileCount
        hiddenFileCount = box.simulation.hiddenFileCount
        refreshSuggestions()
    }

    /// nil when the rule was added, else why it was not.
    func addRule(_ text: String) -> FileFilter.AddError? {
        var next = filter
        switch next.add(text) {
        case .success: setFilter(next); return nil
        case .failure(let error): return error
        }
    }

    func removeRule(_ pattern: String) {
        var next = filter
        next.remove(pattern)
        setFilter(next)
    }

    func setRuleEnabled(_ enabled: Bool, for pattern: String) {
        var next = filter
        next.setEnabled(enabled, for: pattern)
        setFilter(next)
    }

    /// Suffix patterns over every file the tree knows, shown and hidden alike.
    func refreshSuggestions() {
        let sim = box.simulation
        suggestions = FileFilter.suggestions(for: sim.tree.files.union(sim.hidden.keys), excluding: filter, limit: Constants.filterSuggestionLimit)
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

    func followNext() { step(forward: true) }
    func followPrevious() { step(forward: false) }

    private func step(forward: Bool) {
        guard !isLoading else { return }
        follow(FollowCycle.next(after: followedMain, lastIndex: followedIndex, in: liveMains, forward: forward))
    }

    private func follow(_ id: AgentID?) {
        guard let id else { return }
        selectedAgent = id
        box.setFollow(id)
    }

    /// Escape and the menu: the follow ends and the camera stays put.
    func stopFollowing() {
        selectedAgent = nil
        box.stopFollowing()
    }

    // MARK: - Input

    func handleKey(_ command: KeyCommand) {
        switch command {
        case .followNext: followNext()
        case .followPrevious: followPrevious()
        case .stopFollowing: stopFollowing()
        }
    }

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
                var lines = [path.isRoot ? "/" : path.string, "\(node.leafCount) files"]
                if let t = sim.tints[path] {
                    let title = snapshot.agents.first { $0.id == t.toucher }?.title ?? t.toucherTitle ?? t.toucher.raw
                    lines.append("read by \(title) · \(Int(Date().timeIntervalSince(t.touchedAt)))s ago" + (t.source.map { " · \($0.label)" } ?? ""))
                }
                return lines
            }
            var lines = [path.string]
            if let t = sim.tints[path] {
                let title = snapshot.agents.first { $0.id == t.toucher }?.title ?? t.toucherTitle ?? t.toucher.raw
                let ago = Int(Date().timeIntervalSince(t.touchedAt))
                lines.append("last touched by \(title) · \(ago)s ago" + (t.source.map { " · \($0.label)" } ?? ""))
            }
            let origins = node.origins.compactMap { if case .worktree(let n) = $0 { return n } else { return nil } }.sorted()
            if sim.tree.isGhost(path), !origins.isEmpty {
                lines.append("only in worktree\(origins.count == 1 ? "" : "s") \(origins.joined(separator: ", "))")
            } else if let wt = snapshot.recentTouches.last(where: { $0.path == path })?.worktree {
                lines.append("in worktree \(wt)")
            }
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
