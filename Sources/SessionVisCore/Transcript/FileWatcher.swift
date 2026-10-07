import Foundation

/// A vnode watcher on a file or directory. The handler runs on a global queue; keep it tiny.
public final class FileWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject

    public init?(path: String, directory: Bool, handler: @escaping @Sendable () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let mask: DispatchSource.FileSystemEvent = directory ? [.write] : [.write, .extend, .delete, .rename]
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .global(qos: .utility))
        src.setEventHandler(handler: handler)
        src.setCancelHandler { close(fd) }
        src.resume()
        self.source = src
    }

    public func cancel() { if !source.isCancelled { source.cancel() } }
    deinit { cancel() }
}
