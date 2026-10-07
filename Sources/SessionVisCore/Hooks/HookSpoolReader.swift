import Foundation

/// Consumes hook payload files written by the snippet command.
public actor HookSpoolReader {
    public nonisolated let directory: URL
    public private(set) var malformedCount = 0
    /// Files modified more recently than this are still being written; leave them for the next drain.
    static let settleInterval: TimeInterval = 0.05

    public init(directory: URL) { self.directory = directory }

    public func pruneOld(now: Date = Date(), age: TimeInterval = Constants.hookPruneAge) {
        for (url, mtime) in listFiles() where now.timeIntervalSince(mtime) > age {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func drain(now: Date = Date()) -> [HookEvent] {
        var out: [HookEvent] = []
        let ready = listFiles()
            .filter { now.timeIntervalSince($0.1) >= Self.settleInterval }
            .sorted { $0.1 == $1.1 ? $0.0.lastPathComponent < $1.0.lastPathComponent : $0.1 < $1.1 }
        for (url, mtime) in ready {
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url), let event = HookEvent(json: data, receivedAt: mtime) else {
                malformedCount += 1
                continue
            }
            out.append(event)
        }
        return out
    }

    private func listFiles() -> [(URL, Date)] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return [] }
        return urls.compactMap { u in
            let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard v?.isRegularFile == true else { return nil }
            return (u, v?.contentModificationDate ?? .distantPast)
        }
    }
}
