import Foundation

/// Discovery + tailers + hook spool → one `SourceEvent` stream.
public actor LiveSource {
    public nonisolated let events: AsyncStream<SourceEvent>
    private let continuation: AsyncStream<SourceEvent>.Continuation
    private let folder: PathFolder
    private let projectsRoot: URL
    private let spool: HookSpoolReader?
    private let clock: @Sendable () -> Date

    private struct Tracked {
        let sessionId: String
        let agentId: String?
        let tailer: TranscriptTailer
        var watcher: FileWatcher?
    }
    private var tracked: [String: Tracked] = [:]          // transcript path → tailer
    private var membership: [String: Bool] = [:]           // transcript path → belongs to folder
    private var mainTranscripts: [String: URL] = [:]       // sessionId → URL (for subagent discovery)
    private var directoryWatchers: [String: FileWatcher] = [:]
    private var subagentDirWatchers: [String: FileWatcher] = [:]   // sessionId → watcher on `<uuid>/subagents/`
    private var tickTask: Task<Void, Never>?
    private var rescanTask: Task<Void, Never>?
    private var isTicking = false
    private var tickRequested = false
    /// Rescans between spool prunes: every 10 minutes at `rescanInterval` = 2 s.
    static let pruneEveryRescans = 300

    /// Per-file vnode watchers currently held (main transcripts only). Exposed for tests.
    var fileWatcherCount: Int { tracked.values.filter { $0.watcher != nil }.count }

    public init(folder: PathFolder, projectsRoot: URL, spoolDirectory: URL?, clock: @escaping @Sendable () -> Date = { Date() }) {
        let (stream, continuation) = AsyncStream<SourceEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
        self.folder = folder
        self.projectsRoot = projectsRoot
        self.spool = spoolDirectory.map { HookSpoolReader(directory: $0) }
        self.clock = clock
    }

    public func start() async {
        await pruneSpool()
        rescan()
        await tick()
        continuation.yield(.initialLoadComplete)
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Constants.pollInterval))
                guard let self else { return }
                await self.tick()
            }
        }
        rescanTask = Task { [weak self] in
            var count = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Constants.rescanInterval))
                guard let self else { return }
                await self.rescan()
                count += 1
                if count % Self.pruneEveryRescans == 0 { await self.pruneSpool() }
            }
        }
    }

    private func pruneSpool() async { await spool?.pruneOld(now: clock()) }

    public func stop() {
        tickTask?.cancel(); rescanTask?.cancel()
        for t in tracked.values { t.watcher?.cancel() }
        for w in directoryWatchers.values { w.cancel() }
        for w in subagentDirWatchers.values { w.cancel() }
        continuation.finish()
    }

    /// One discovery pass: new member sessions within the active window, and new subagents of tracked sessions.
    /// Transcripts (main or subagent) last modified longer than `activeWindow` ago are never read.
    public func rescan() {
        watchDirectory(projectsRoot.path)
        let now = clock()
        for s in SessionDiscovery.listTranscripts(projectsRoot: projectsRoot) {
            let path = s.transcriptURL.path
            watchDirectory(s.transcriptURL.deletingLastPathComponent().path)
            if tracked[path] != nil { continue }
            guard now.timeIntervalSince(s.modifiedAt) <= Constants.activeWindow else { continue }
            if membership[path] == nil, let m = SessionDiscovery.membership(transcriptURL: s.transcriptURL, folder: folder) { membership[path] = m }
            guard membership[path] == true else { continue }
            track(path: path, url: s.transcriptURL, sessionId: s.sessionId, agentId: nil, watchFile: true)
            mainTranscripts[s.sessionId] = s.transcriptURL
            continuation.yield(.sessionAppeared(sessionId: s.sessionId, transcriptURL: s.transcriptURL))
        }
        for (sessionId, url) in mainTranscripts.sorted(by: { $0.key < $1.key }) {
            watchSubagentDirectory(sessionId: sessionId, transcriptURL: url)
            for sub in SessionDiscovery.listSubagents(sessionTranscriptURL: url) where tracked[sub.transcriptURL.path] == nil {
                guard let mtime = Self.modificationDate(sub.transcriptURL),
                      now.timeIntervalSince(mtime) <= Constants.activeWindow else { continue }
                track(path: sub.transcriptURL.path, url: sub.transcriptURL, sessionId: sessionId, agentId: sub.agentId, watchFile: false)
                continuation.yield(.subagentAppeared(sessionId: sessionId, agentId: sub.agentId, meta: sub.meta))
            }
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Reads every tailer and the spool, then reports diagnostics. Calls that arrive while a tick is in
    /// progress (the actor is reentrant across awaits) coalesce into one more pass, so a file's lines are
    /// never read by two passes at once and always arrive in file order.
    public func tick() async {
        if isTicking { tickRequested = true; return }
        isTicking = true
        defer { isTicking = false }
        repeat {
            tickRequested = false
            await readAll()
        } while tickRequested
    }

    private func readAll() async {
        var skipped = 0
        for key in tracked.keys.sorted() {
            guard let t = tracked[key] else { continue }
            for line in await t.tailer.readNewLines() {
                continuation.yield(.line(sessionId: t.sessionId, agentId: t.agentId, line))
            }
            skipped += await t.tailer.skippedLines
        }
        if let spool {
            for e in await spool.drain(now: clock()) { continuation.yield(.hook(e)) }
        }
        continuation.yield(.diagnostics(skippedLines: skipped))
    }

    /// Main transcripts get a vnode watcher; subagent transcripts rely on the poll tick (fd budget).
    private func track(path: String, url: URL, sessionId: String, agentId: String?, watchFile: Bool) {
        let tailer = TranscriptTailer(url: url)
        let watcher = watchFile ? FileWatcher(path: path, directory: false) { [weak self] in
            Task { await self?.tick() }
        } : nil
        tracked[path] = Tracked(sessionId: sessionId, agentId: agentId, tailer: tailer, watcher: watcher)
    }

    /// One watcher per tracked session on `<uuid>/subagents/`, created once the directory exists.
    private func watchSubagentDirectory(sessionId: String, transcriptURL: URL) {
        guard subagentDirWatchers[sessionId] == nil else { return }
        let dir = transcriptURL.deletingPathExtension().appendingPathComponent("subagents").path
        subagentDirWatchers[sessionId] = FileWatcher(path: dir, directory: true) { [weak self] in
            Task { await self?.rescan() }
        }
    }

    private func watchDirectory(_ path: String) {
        guard directoryWatchers[path] == nil else { return }
        directoryWatchers[path] = FileWatcher(path: path, directory: true) { [weak self] in
            Task { await self?.rescan() }
        }
    }
}
