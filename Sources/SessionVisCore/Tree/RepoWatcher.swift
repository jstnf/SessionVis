import Foundation
import CoreServices

/// Watches the root and every registered checkout with FSEvents and emits tree deltas computed by rescanning.
public final class RepoWatcher: @unchecked Sendable {
    public let deltas: AsyncStream<TreeDelta>
    private let continuation: AsyncStream<TreeDelta>.Continuation
    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "SessionVis.RepoWatcher")
    private var stream: FSEventStreamRef?
    private var _folder: PathFolder
    /// Watched roots reached through a symlink: FSEvents reports the real path, paths are folded against the given one.
    private var realRoots: [(real: String, given: String)]
    private var known: [Origin: Set<RepoPath>]
    private var finished = false
    /// Absolute paths of files FSEvents reported as modified; only touched on `queue`.
    private var pendingChanged: Set<String> = []
    private var _lastScanTruncated = false
    /// Whether the most recent rescan hit the file cap.
    public var lastScanTruncated: Bool { queue.sync { _lastScanTruncated } }
    /// The registry the watcher currently classifies paths with.
    public var folder: PathFolder { queue.sync { _folder } }

    public init(folder: PathFolder, initial: FileTree, latency: TimeInterval = Constants.watchDebounce) {
        self._folder = folder
        self.realRoots = Self.symlinkedRoots(of: folder)
        self.latency = latency
        self.known = initial.filesByOrigin
        (deltas, continuation) = AsyncStream<TreeDelta>.makeStream()
    }

    /// The root plus every checkout outside it; checkouts inside the root are covered by its own stream.
    static func watchedRoots(of folder: PathFolder) -> [String] {
        [folder.root] + folder.worktrees.map(\.path).filter { !$0.hasPrefix(folder.root + "/") }
    }

    private static func symlinkedRoots(of folder: PathFolder) -> [(real: String, given: String)] {
        watchedRoots(of: folder).compactMap { given in
            guard let real = PathFolder.realPath(given), real != given else { return nil }
            return (real, given)
        }
    }

    public func start() { queue.sync { startStreamLocked() } }

    /// Swaps the registry. When the set of watched roots changed the stream is recreated for the new set; either way a
    /// rescan follows, so a new checkout arrives as an added-only delta and a vanished one as a removed-only delta with
    /// an empty snapshot. Runs on the watcher's queue; the deltas come through `deltas` as usual.
    public func setFolder(_ folder: PathFolder) {
        queue.async { [self] in
            guard !finished else { return }
            let rootsChanged = Self.watchedRoots(of: folder) != Self.watchedRoots(of: _folder)
            _folder = folder
            realRoots = Self.symlinkedRoots(of: folder)
            if rootsChanged, stream != nil { stopStreamLocked(); startStreamLocked() }
            rescanLocked()
        }
    }

    private func startStreamLocked() {
        guard stream == nil else { return }
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()
            let names = Unmanaged<NSArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let flagList = UnsafeBufferPointer(start: flags, count: count)
            let interesting = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed)
            for (i, name) in names.enumerated() where i < flagList.count {
                let f = flagList[i]
                if f & UInt32(kFSEventStreamEventFlagItemIsFile) != 0, f & interesting != 0 { watcher.pendingChanged.insert(name) }
            }
            watcher.rescanLocked()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, callback, &context, Self.watchedRoots(of: _folder) as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    private func stopStreamLocked() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    /// Rescans now and emits a delta if anything changed. Test hook; the FSEvents callback uses the same path.
    func rescan() { queue.sync { rescanLocked() } }

    /// Records files as modified, as the FSEvents callback does. Test hook.
    func noteChanged(_ absolutePaths: [String]) { queue.sync { pendingChanged.formUnion(absolutePaths) } }

    private func rescanLocked() {
        guard !finished else { return }
        let changedNow = pendingChanged
        pendingChanged = []
        let at = Date()
        var changedByOrigin: [Origin: Set<RepoPath>] = [:]
        for abs in changedNow {
            var p = PathFolder.normalize(abs)
            for r in realRoots where p.hasPrefix(r.real + "/") { p = r.given + p.dropFirst(r.real.count); break }
            guard let folded = _folder.fold(p) else { continue }
            let origin: Origin = folded.worktree.map { .worktree($0) } ?? .main
            changedByOrigin[origin, default: []].insert(folded.path)
        }
        let scan = FileTreeScanner.scanOrigins(folder: _folder)
        _lastScanTruncated = scan.truncated
        var next = scan.files
        let origins = Set(known.keys).union(next.keys).sorted()
        var deltas: [TreeDelta] = []
        for origin in origins {
            var files = next[origin] ?? []
            var delta = TreeDelta.compute(old: known[origin] ?? [], new: files)
            if scan.truncated, !delta.isEmpty {
                // A capped scan can miss files that still exist; do not report those as deleted.
                let root = _folder.rootPath(of: origin)
                let filtered = delta.droppingPhantomRemovals { FileManager.default.fileExists(atPath: root + "/" + $0.string) }
                let before = Set(delta.removed + delta.moved.map(\.from))
                let after = Set(filtered.removed + filtered.moved.map(\.from))
                files.formUnion(before.subtracting(after))
                delta = filtered
            }
            delta.origin = origin
            delta.snapshot = files
            let addedSet = Set(delta.added)
            delta.changed = (changedByOrigin[origin] ?? []).filter { files.contains($0) && !addedSet.contains($0) }.sorted()
            delta.at = at
            if files.isEmpty { next.removeValue(forKey: origin) } else { next[origin] = files }
            if !delta.isEmpty { deltas.append(delta) }
        }
        known = next
        for d in deltas { continuation.yield(d) }
    }

    public func stop() {
        queue.sync {
            stopStreamLocked()
            finished = true
            continuation.finish()
        }
    }

    deinit { if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) } }
}
