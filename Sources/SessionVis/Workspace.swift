import SwiftUI
import AppKit
import SessionVisCore

/// Owns the tabs: the ordered list and its persistence, one session per tab, the app-wide hook router and the launch
/// arguments. Everything that belongs to one directory lives in that tab's `RepoSession`.
@MainActor @Observable
final class Workspace {
    private(set) var tabs = TabList()
    private(set) var sessions: [UUID: RepoSession] = [:]
    var hookInstalled = false
    /// When the router last saw a payload, from any directory.
    var hookEventsSeenAt: Date?
    /// A launch argument that could not be honoured; shown briefly and cleared on any tab change.
    private(set) var launchMessage: String?
    let projectsRoot = SessionDiscovery.projectsRoot()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var router: HookRouter!
    @ObservationIgnored private var routerStarted = false
    @ObservationIgnored private var hiddenSince: [UUID: Date] = [:]
    @ObservationIgnored private var launched = false
    @ObservationIgnored private var launchMessageTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    static let lastDirectoryKey = "lastDirectory"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        router = HookRouter(spoolDirectory: HookSnippet.defaultSpoolDirectory, onActivity: { [weak self] date in
            Task { @MainActor in self?.hookEventsSeenAt = date }
        })
    }

    var selected: RepoSession? { tabs.selectedID.flatMap { sessions[$0] } }
    var selectedEntry: TabEntry? { tabs.selected }

    // MARK: - Launch

    func handleLaunch() async {
        guard !launched else { return }
        launched = true
        hookInstalled = HookSnippet.isInstalled(settingsURL: HookSnippet.defaultSettingsURL())
        tabs = TabList.decode(defaults.data(forKey: TabList.defaultsKey))
            ?? TabList.migrated(lastDirectory: defaults.string(forKey: Self.lastDirectoryKey))
        defaults.removeObject(forKey: Self.lastDirectoryKey)
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.retryAllMissing() }
        }
        let options = LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
        switch tabs.launchAction(for: options) {
        case .replayNeedsDirectory:
            showLaunchMessage("--replay needs a directory argument to seed the tree.")
        case .openReplay(let directory, let transcript, let speed):
            tabs.openReplay(directory: directory, transcript: transcript, speed: speed)
        case .open(let directory):
            tabs.open(directory: directory)
        case .restore:
            break
        case .presentOpenPanel:
            presentOpenPanel(replacing: nil)
        }
        save()
        await startAll()
    }

    /// The selected tab first, so the visible scene comes up before the others scan.
    private func startAll() async {
        if let entry = tabs.selected { await startSession(for: entry) }
        for id in tabs.entries.map(\.id) {
            // A tab closed while an earlier one was opening is no longer listed.
            guard sessions[id] == nil, let entry = tabs.entries.first(where: { $0.id == id }) else { continue }
            await startSession(for: entry)
        }
    }

    private func startSession(for entry: TabEntry) async {
        guard tabs.index(of: entry.id) != nil, sessions[entry.id] == nil else { return }
        let session = RepoSession(id: entry.id, hooks: entry.isReplay ? nil : router)
        sessions[entry.id] = session
        session.isVisible = entry.id == tabs.selectedID
        // A tab that starts out of sight is revealed with a catch-up like any other hidden tab.
        if !session.isVisible { hiddenSince[entry.id] = Date() }
        if let replay = entry.replay {
            await session.startReplay(transcript: URL(fileURLWithPath: replay.transcript), speed: replay.speed, directory: entry.directory)
        } else {
            await startRouterIfNeeded()
            guard sessions[entry.id] === session else { return }
            await session.open(directory: entry.directory)
        }
    }

    /// The hook command spools only while the marker exists: created with the first live tab, removed at quit.
    private func startRouterIfNeeded() async {
        guard !routerStarted else { return }
        routerStarted = true
        HookSnippet.createMarker()
        await router.start()
    }

    // MARK: - Tabs

    /// Asks for a directory. With `replacing`, the chosen tab (fixed now, not when the panel completes) is re-pointed.
    func presentOpenPanel(replacing target: UUID?) {
        let replacingCurrent = target != nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        panel.message = replacingCurrent ? "Choose the directory to watch in this tab" : "Choose a directory to watch in a new tab"
        if let dir = selectedEntry?.directory { panel.directoryURL = URL(fileURLWithPath: dir).deletingLastPathComponent() }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.open(directory: url.path, replacing: target) }
        }
    }

    /// Selects the tab for the directory or adds one; with `replacing`, that tab is re-pointed or closed.
    func open(directory: String, replacing target: UUID? = nil) async {
        let before = tabs.entries
        let id: UUID
        if let target {
            id = tabs.open(directory: directory, replacing: target)
        } else {
            id = tabs.open(directory: directory)
        }
        save()
        let after = tabs.entries
        for entry in before where !after.contains(where: { $0.id == entry.id }) { dropSession(entry.id) }
        if let old = before.first(where: { $0.id == id }), let new = after.first(where: { $0.id == id }), old != new { dropSession(id) }
        focus(id)
        if sessions[id] == nil, let entry = after.first(where: { $0.id == id }) { await startSession(for: entry) }
    }

    func closeTab(_ id: UUID) {
        guard tabs.close(id) else { return }
        save()
        dropSession(id)
        focus(tabs.selectedID)
    }

    func closeSelected() {
        if let id = tabs.selectedID { closeTab(id) }
    }

    func select(_ id: UUID) {
        tabs.select(id)
        save()
        focus(tabs.selectedID)
    }

    func select(index: Int) {
        tabs.select(index: index)
        save()
        focus(tabs.selectedID)
    }

    func selectNext() {
        tabs.selectNext()
        save()
        focus(tabs.selectedID)
    }

    func selectPrevious() {
        tabs.selectPrevious()
        save()
        focus(tabs.selectedID)
    }

    func moveSelected(by offset: Int) {
        guard let id = tabs.selectedID else { return }
        tabs.move(id, by: offset)
        save()
        clearLaunchMessage()
    }

    private func dropSession(_ id: UUID) {
        sessions[id]?.stop()
        sessions[id] = nil
        hiddenSince[id] = nil
    }

    /// Makes `id` the visible session: the others stop being stepped and forget their hover; the revealed one
    /// catches up on the time it was hidden and retries a missing directory.
    private func focus(_ id: UUID?) {
        clearLaunchMessage()
        let now = Date()
        for (sid, session) in sessions where sid != id && session.isVisible {
            session.isVisible = false
            session.hover = nil
            session.hoverPoint = nil
            hiddenSince[sid] = now
        }
        guard let id, let session = sessions[id] else { return }
        if session.isVisible {
            if session.directoryMissing { Task { await retryMissing(id) } }
            return
        }
        session.isVisible = true
        if let since = hiddenSince.removeValue(forKey: id) { session.box.catchUp(hiddenFor: now.timeIntervalSince(since)) }
        Task { await retryMissing(id) }
    }

    private func showLaunchMessage(_ text: String) {
        launchMessage = text
        launchMessageTask?.cancel()
        launchMessageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Constants.launchMessageDuration))
            guard !Task.isCancelled else { return }
            self?.launchMessage = nil
        }
    }

    private func clearLaunchMessage() {
        launchMessageTask?.cancel()
        launchMessageTask = nil
        launchMessage = nil
    }

    /// Retries a missing tab. Once its directory is back its stored spelling is made canonical, and the tab is
    /// merged into an existing one for the same directory rather than left as a second tab.
    private func retryMissing(_ id: UUID) async {
        guard let session = sessions[id], session.directoryMissing, let entry = tabs.entries.first(where: { $0.id == id }) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entry.directory, isDirectory: &isDirectory), isDirectory.boolValue,
              let result = tabs.recanonicalize(id), result.changed else {
            await session.retryIfMissing()
            return
        }
        save()
        dropSession(id)
        if result.id != id {
            if tabs.selectedID == id || tabs.selectedID == result.id { focus(result.id) }
        } else if let renamed = tabs.entries.first(where: { $0.id == id }) {
            await startSession(for: renamed)
        }
    }

    private func retryAllMissing() async {
        for id in sessions.filter({ $0.value.directoryMissing }).keys { await retryMissing(id) }
    }

    private func save() {
        if let data = tabs.encoded() {
            defaults.set(data, forKey: TabList.defaultsKey)
        } else {
            defaults.removeObject(forKey: TabList.defaultsKey)
        }
    }
}
