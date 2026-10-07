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
    private var known: Set<RepoPath>
    private var finished = false
    private var _lastScanTruncated = false
    /// Whether the most recent rescan hit the file cap.
    public var lastScanTruncated: Bool { queue.sync { _lastScanTruncated } }

    public init(directory: String, initial: FileTree, latency: TimeInterval = Constants.watchDebounce) {
        self.directory = PathFolder.normalize(directory)
        self.latency = latency
        self.known = initial.files
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
        let scan = FileTreeScanner.scan(directory: directory)
        _lastScanTruncated = scan.truncated
        var files = scan.files
        var delta = TreeDelta.compute(old: known, new: files)
        if scan.truncated, !delta.isEmpty {
            // A capped scan can miss files that still exist; do not report those as deleted.
            let root = directory
            let filtered = delta.droppingPhantomRemovals { FileManager.default.fileExists(atPath: root + "/" + $0.string) }
            let before = Set(delta.removed + delta.moved.map(\.from))
            let after = Set(filtered.removed + filtered.moved.map(\.from))
            files.formUnion(before.subtracting(after))
            delta = filtered
        }
        known = files
        delta.snapshot = files
        if !delta.isEmpty { continuation.yield(delta) }
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
