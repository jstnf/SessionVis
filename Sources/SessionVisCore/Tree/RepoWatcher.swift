import Foundation
import CoreServices

/// Watches the directory with FSEvents and emits tree deltas computed by rescanning.
public final class RepoWatcher: @unchecked Sendable {
    public let directory: String
    public let deltas: AsyncStream<TreeDelta>
    private let continuation: AsyncStream<TreeDelta>.Continuation
    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "SessionVis.RepoWatcher")
    private var stream: FSEventStreamRef?
    private var known: [Origin: Set<RepoPath>]
    private var finished = false
    private var _lastScanTruncated = false
    /// Whether the most recent rescan hit the file cap.
    public var lastScanTruncated: Bool { queue.sync { _lastScanTruncated } }

    public init(directory: String, initial: FileTree, latency: TimeInterval = Constants.watchDebounce) {
        self.directory = PathFolder.normalize(directory)
        self.latency = latency
        self.known = initial.filesByOrigin
        (deltas, continuation) = AsyncStream<TreeDelta>.makeStream()
    }

    public func start() {
        queue.sync {
            guard stream == nil else { return }
            var context = FSEventStreamContext()
            context.info = Unmanaged.passUnretained(self).toOpaque()
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue().rescanLocked()
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

    private func rescanLocked() {
        guard !finished else { return }
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
            if files.isEmpty { next.removeValue(forKey: origin) } else { next[origin] = files }
            if !delta.isEmpty { deltas.append(delta) }
        }
        known = next
        for d in deltas { continuation.yield(d) }
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
