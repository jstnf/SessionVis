import Foundation

/// The one consumer of the hook spool. Each tab registers its folder and a sink; every drained event goes to each
/// tab whose folder accepts the payload's cwd. There is one reader for the whole app because the reader deletes a
/// payload as it reads it, so two readers would steal from each other.
public actor HookRouter {
    public typealias Sink = @Sendable (HookEvent) async -> Void

    private struct Registration {
        let id: UUID
        let generation: Int
        var folder: PathFolder
        let sink: Sink
    }

    private let reader: HookSpoolReader
    private let clock: @Sendable () -> Date
    private let onActivity: (@Sendable (Date) -> Void)?
    private var registrations: [Registration] = []
    private var watcher: FileWatcher?
    private var timerTask: Task<Void, Never>?
    private var isTicking = false
    private var tickRequested = false
    /// When the latest payload was written, whether or not any tab wanted it.
    public private(set) var lastSeenAt: Date?

    public init(spoolDirectory: URL, clock: @escaping @Sendable () -> Date = { Date() }, onActivity: (@Sendable (Date) -> Void)? = nil) {
        self.reader = HookSpoolReader(directory: spoolDirectory)
        self.clock = clock
        self.onActivity = onActivity
    }

    public nonisolated var spoolDirectory: URL { reader.directory }
    public var registeredCount: Int { registrations.count }

    /// Registers (or replaces) the sink for a tab. `generation` lets a later `unregister` for an earlier open
    /// leave a newer registration alone.
    public func register(_ id: UUID, generation: Int = 0, folder: PathFolder, sink: @escaping Sink) {
        registrations.removeAll { $0.id == id }
        registrations.append(Registration(id: id, generation: generation, folder: folder, sink: sink))
    }

    public func setFolder(_ folder: PathFolder, for id: UUID) {
        guard let i = registrations.firstIndex(where: { $0.id == id }) else { return }
        registrations[i].folder = folder
    }

    /// Removes the tab's registration; with a generation, only when it is the one registered.
    public func unregister(_ id: UUID, generation: Int? = nil) {
        registrations.removeAll { $0.id == id && (generation == nil || $0.generation == generation) }
    }

    /// Creates the spool directory, prunes stale payloads, and drains on vnode events and on a timer.
    public func start() async {
        guard timerTask == nil else { return }
        try? FileManager.default.createDirectory(at: reader.directory, withIntermediateDirectories: true)
        await reader.pruneOld(now: clock())
        watcher = FileWatcher(path: reader.directory.path, directory: true) { [weak self] in
            Task { await self?.tick() }
        }
        timerTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Constants.hookSpoolPollInterval))
                guard let self else { return }
                await self.tick()
                ticks += 1
                if ticks % Constants.hookSpoolPruneEveryTicks == 0 { await self.prune() }
            }
        }
    }

    public func stop() {
        timerTask?.cancel()
        timerTask = nil
        watcher?.cancel()
        watcher = nil
    }

    private func prune() async { await reader.pruneOld(now: clock()) }

    /// Drains the spool once, in write order, and delivers. Calls that arrive while a pass is in progress coalesce
    /// into one more pass, so no payload is read twice and events reach each sink in order.
    public func tick() async {
        if isTicking { tickRequested = true; return }
        isTicking = true
        defer { isTicking = false }
        repeat {
            tickRequested = false
            for event in await reader.drain(now: clock()) {
                lastSeenAt = event.receivedAt
                onActivity?(event.receivedAt)
                let targets = Self.targets(for: event.cwd, in: registrations.map { (id: $0.id, folder: $0.folder) })
                for r in registrations where targets.contains(r.id) { await r.sink(event) }
            }
        } while tickRequested
    }

    /// The registered tabs, in registration order, whose folder accepts the cwd. A payload without a cwd matches none.
    public static func targets(for cwd: String?, in tabs: [(id: UUID, folder: PathFolder)]) -> [UUID] {
        guard let cwd else { return [] }
        return tabs.filter { $0.folder.isMemberCwd(cwd) }.map(\.id)
    }
}
