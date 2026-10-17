import Foundation
import CoreServices

/// Watches the directory with FSEvents and emits tree deltas computed by rescanning.
public final class RepoWatcher: @unchecked Sendable {
    public let directory: String
    /// `directory` with symlinks resolved, as FSEvents reports it; nil if it could not be resolved.
    private let realDirectory: String?
    public let deltas: AsyncStream<TreeDelta>
    private let continuation: AsyncStream<TreeDelta>.Continuation
    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "SessionVis.RepoWatcher")
    private var stream: FSEventStreamRef?
    private var known: [Origin: Set<RepoPath>]
    private var finished = false
    /// Absolute paths of files FSEvents reported as modified; only touched on `queue`.
    private var pendingChanged: Set<String> = []
    private var _lastScanTruncated = false
    /// Whether the most recent rescan hit the file cap.
    public var lastScanTruncated: Bool { queue.sync { _lastScanTruncated } }

    public init(directory: String, initial: FileTree, latency: TimeInterval = Constants.watchDebounce) {
        self.directory = PathFolder.normalize(directory)
        self.realDirectory = Self.realPath(self.directory)
        self.latency = latency
        self.known = initial.filesByOrigin
        (deltas, continuation) = AsyncStream<TreeDelta>.makeStream()
    }

    public func start() {
        queue.sync {
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
            guard let s = FSEventStreamCreate(nil, callback, &context, [directory] as CFArray,
                                              FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
            stream = s
        }
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
        let wtPrefix = Origin.worktreesDirectory(under: directory) + "/"
        for abs in changedNow {
            var p = PathFolder.normalize(abs)
            // FSEvents reports real paths; the watched directory may be given through a symlink such as /var.
            if let real = realDirectory, real != directory, p.hasPrefix(real + "/") { p = directory + p.dropFirst(real.count) }
            if p.hasPrefix(wtPrefix) {
                let rest = p.dropFirst(wtPrefix.count)
                guard let slash = rest.firstIndex(of: "/") else { continue }
                changedByOrigin[.worktree(String(rest[..<slash])), default: []].insert(RepoPath(string: String(rest[rest.index(after: slash)...])))
            } else if p.hasPrefix(directory + "/") {
                changedByOrigin[.main, default: []].insert(RepoPath(string: String(p.dropFirst(directory.count + 1))))
            }
        }
        let scan = FileTreeScanner.scanOrigins(directory: directory)
        _lastScanTruncated = scan.truncated
        var next = scan.files
        let origins = Set(known.keys).union(next.keys).sorted()
        var deltas: [TreeDelta] = []
        for origin in origins {
            var files = next[origin] ?? []
            var delta = TreeDelta.compute(old: known[origin] ?? [], new: files)
            if scan.truncated, !delta.isEmpty {
                // A capped scan can miss files that still exist; do not report those as deleted.
                let root = origin.rootPath(under: directory)
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

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public func stop() {
        queue.sync {
            if let s = stream {
                FSEventStreamStop(s)
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
                stream = nil
            }
            finished = true
            continuation.finish()
        }
    }

    deinit { if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) } }
}
