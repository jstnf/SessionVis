import Foundation
import Testing
@testable import SessionVisCore

@Suite struct RepoWatcherTests {
    @Test func computesDeltaOnRescan() async throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "a".write(to: d.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
        let tree = FileTreeScanner.scan(directory: d.path)
        let w = RepoWatcher(directory: d.path, initial: tree)
        let reader = DeltaReader(w.deltas)
        try "b".write(to: d.appendingPathComponent("Sources/B.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: d.appendingPathComponent("Sources/A.swift"))
        w.rescan()
        let delta = try #require(await reader.next())
        #expect(delta.added == [RepoPath(string: "Sources/B.swift")] && delta.removed == [RepoPath(string: "Sources/A.swift")])
        try FileManager.default.moveItem(at: d.appendingPathComponent("Sources/B.swift"), to: d.appendingPathComponent("B.swift"))
        w.rescan()
        let move = try #require(await reader.next())
        #expect(move.moved == [TreeDelta.Move(from: RepoPath(string: "Sources/B.swift"), to: RepoPath(string: "B.swift"))])
        w.rescan()   // no change → nothing emitted; the next read must come from the live stream below
        w.stop()
        #expect(await reader.next() == nil)
    }

    @Test(.timeLimit(.minutes(1))) func fsEventsDeliverDeltas() async throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("watch-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let w = RepoWatcher(directory: d.path, initial: FileTreeScanner.scan(directory: d.path), latency: 0.2)
        let reader = DeltaReader(w.deltas)
        w.start()
        try await Task.sleep(for: .milliseconds(300))          // let the stream attach
        try "x".write(to: d.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let delta = try #require(await reader.next())
        #expect(delta.added.contains(RepoPath(string: "new.txt")))
        w.stop()
    }

    @Test func droppingPhantomRemovalsKeepsOnlyTrulyMissing() {
        let gone = RepoPath(string: "gone.swift"), still = RepoPath(string: "still.swift")
        let src = RepoPath(string: "src/m.swift"), dst = RepoPath(string: "dst/m.swift")
        let delta = TreeDelta(removed: [gone, still], moved: [TreeDelta.Move(from: src, to: dst)])
        let out = delta.droppingPhantomRemovals { $0 == still || $0 == src }
        #expect(out.removed == [gone])   // still exists: dropped
        #expect(out.moved.isEmpty && out.added == [dst])
        let kept = delta.droppingPhantomRemovals { _ in false }
        #expect(kept == delta)
    }

    @Test func emittedDeltaCarriesSnapshot() async throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("watch-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let w = RepoWatcher(directory: d.path, initial: FileTreeScanner.scan(directory: d.path))
        let reader = DeltaReader(w.deltas)
        try "x".write(to: d.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
        w.rescan()
        let delta = try #require(await reader.next())
        #expect(delta.snapshot == [RepoPath(string: "n.txt")])
        #expect(!w.lastScanTruncated)
        w.stop()
    }
}

final class DeltaReader: @unchecked Sendable {
    private var it: AsyncStream<TreeDelta>.Iterator
    init(_ s: AsyncStream<TreeDelta>) { it = s.makeAsyncIterator() }
    func next() async -> TreeDelta? { await it.next() }
}
