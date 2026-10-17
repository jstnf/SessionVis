import Foundation
import Testing
@testable import SessionVisCore

@Suite struct RepoWatcherTests {
    func folder(_ d: URL, worktrees: [Worktree] = []) -> PathFolder { PathFolder(root: d.path, worktrees: worktrees) }

    /// `<base>/repo` and `<base>/feature` as a sibling checkout, each with `Sources/A.swift`; returns both plus a folder registering the sibling.
    func makeSiblingRepo(_ tag: String) throws -> (repo: URL, sibling: URL, folder: PathFolder) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(tag)-\(UUID().uuidString)")
        let d = base.appendingPathComponent("repo"), sib = base.appendingPathComponent("feature")
        for dir in [d, sib] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources"), withIntermediateDirectories: true)
            try "a".write(to: dir.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
        }
        return (d, sib, PathFolder(root: d.path, worktrees: [Worktree(name: "feature", path: sib.path)]))
    }

    @Test func computesDeltaOnRescan() async throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "a".write(to: d.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
        let tree = FileTreeScanner.scan(folder: folder(d))
        let w = RepoWatcher(folder: folder(d), initial: tree)
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
        let w = RepoWatcher(folder: folder(d), initial: FileTreeScanner.scan(folder: folder(d)), latency: 0.2)
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
        let w = RepoWatcher(folder: folder(d), initial: FileTreeScanner.scan(folder: folder(d)))
        let reader = DeltaReader(w.deltas)
        try "x".write(to: d.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
        w.rescan()
        let delta = try #require(await reader.next())
        #expect(delta.snapshot == [RepoPath(string: "n.txt")])
        #expect(!w.lastScanTruncated)
        w.stop()
    }

    @Test func emitsOneDeltaPerChangedOrigin() async throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("watch-wt-\(UUID().uuidString)")
        let wt = d.appendingPathComponent(".claude/worktrees/feat")
        try FileManager.default.createDirectory(at: d.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wt.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "a".write(to: d.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
        try "a".write(to: wt.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
        let f = folder(d, worktrees: [Worktree(name: "feat", path: wt.path)])
        let w = RepoWatcher(folder: f, initial: FileTreeScanner.scan(folder: f))
        let reader = DeltaReader(w.deltas)
        try "g".write(to: wt.appendingPathComponent("Sources/G.swift"), atomically: true, encoding: .utf8)
        w.rescan()
        let first = try #require(await reader.next())
        #expect(first.origin == .worktree("feat"))
        #expect(first.added == [RepoPath(string: "Sources/G.swift")] && first.removed.isEmpty)
        #expect(first.snapshot == [RepoPath(string: "Sources/A.swift"), RepoPath(string: "Sources/G.swift")])
        // Both origins change: main first, then the worktree.
        try "b".write(to: d.appendingPathComponent("Sources/B.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: wt)
        w.rescan()
        let main = try #require(await reader.next())
        #expect(main.origin == .main && main.added == [RepoPath(string: "Sources/B.swift")])
        let gone = try #require(await reader.next())
        #expect(gone.origin == .worktree("feat"))
        #expect(Set(gone.removed) == [RepoPath(string: "Sources/A.swift"), RepoPath(string: "Sources/G.swift")])
        #expect(gone.snapshot == [])
        w.rescan()
        w.stop()
        #expect(await reader.next() == nil)
    }

    @Test func rewrittenFilesAreReportedAsChangedWithATimestamp() async throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("watch-chg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: d.appendingPathComponent(".build"), withIntermediateDirectories: true)
        try "a".write(to: d.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
        let w = RepoWatcher(folder: folder(d), initial: FileTreeScanner.scan(folder: folder(d)))
        let reader = DeltaReader(w.deltas)
        try "aa".write(to: d.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
        try "n".write(to: d.appendingPathComponent("Sources/N.swift"), atomically: true, encoding: .utf8)
        try "x".write(to: d.appendingPathComponent(".build/x.o"), atomically: true, encoding: .utf8)
        w.noteChanged([d.path + "/Sources/A.swift", d.path + "/Sources/N.swift", d.path + "/.build/x.o", d.path + "/Sources"])
        w.rescan()
        let delta = try #require(await reader.next())
        #expect(delta.changed == [RepoPath(string: "Sources/A.swift")])          // the new file is in `added` only
        #expect(delta.added == [RepoPath(string: "Sources/N.swift")])
        #expect(delta.at > Date.distantPast)
        // A change with no add/remove/move still emits.
        try "aaa".write(to: d.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
        w.noteChanged([d.path + "/Sources/A.swift"])
        w.rescan()
        let only = try #require(await reader.next())
        #expect(only.changed == [RepoPath(string: "Sources/A.swift")] && only.added.isEmpty && only.removed.isEmpty)
        w.stop()
    }

    @Test(.timeLimit(.minutes(1))) func fsEventsReportRewrites() async throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("watch-live-chg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try "x".write(to: d.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let w = RepoWatcher(folder: folder(d), initial: FileTreeScanner.scan(folder: folder(d)), latency: 0.2)
        let reader = DeltaReader(w.deltas)
        w.start()
        try await Task.sleep(for: .milliseconds(300))
        try "xy".write(to: d.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let delta = try #require(await reader.next())
        #expect(delta.changed.contains(RepoPath(string: "f.txt")) || delta.added.contains(RepoPath(string: "f.txt")))
        w.stop()
    }

    @Test func watchedRootsAreTheRootPlusCheckoutsOutsideIt() {
        let f = PathFolder(root: "/r", worktrees: [Worktree(name: "in", path: "/r/.worktrees/in"), Worktree(name: "out", path: "/x/out"), Worktree(name: "c", path: "/r/.claude/worktrees/c")])
        #expect(RepoWatcher.watchedRoots(of: f) == ["/r", "/x/out"])
        #expect(RepoWatcher.watchedRoots(of: PathFolder(root: "/r")) == ["/r"])
    }

    @Test func siblingWorktreeChangesCarryItsOrigin() async throws {
        let (_, sib, f) = try makeSiblingRepo("sib")
        let w = RepoWatcher(folder: f, initial: FileTreeScanner.scan(folder: f))
        let reader = DeltaReader(w.deltas)
        try "s".write(to: sib.appendingPathComponent("Sources/S.swift"), atomically: true, encoding: .utf8)
        w.noteChanged([sib.path + "/Sources/A.swift", sib.path + "/Sources/S.swift"])
        w.rescan()
        let delta = try #require(await reader.next())
        #expect(delta.origin == .worktree("feature"))
        #expect(delta.added == [RepoPath(string: "Sources/S.swift")] && delta.changed == [RepoPath(string: "Sources/A.swift")])
        #expect(delta.snapshot == [RepoPath(string: "Sources/A.swift"), RepoPath(string: "Sources/S.swift")])
        w.stop()
    }

    @Test func setFolderAddsAndRemovesOrigins() async throws {
        let (d, sib, withFeature) = try makeSiblingRepo("set")
        try "f".write(to: sib.appendingPathComponent("Sources/F.swift"), atomically: true, encoding: .utf8)
        let plain = folder(d)
        let w = RepoWatcher(folder: plain, initial: FileTreeScanner.scan(folder: plain))
        let reader = DeltaReader(w.deltas)
        w.setFolder(withFeature)
        let added = try #require(await reader.next())
        #expect(added.origin == .worktree("feature") && added.removed.isEmpty && added.moved.isEmpty)
        #expect(Set(added.added) == [RepoPath(string: "Sources/A.swift"), RepoPath(string: "Sources/F.swift")])
        #expect(added.snapshot == Set(added.added))
        #expect(w.folder == withFeature)
        w.setFolder(plain)
        let gone = try #require(await reader.next())
        #expect(gone.origin == .worktree("feature") && gone.added.isEmpty && gone.snapshot == [])
        #expect(Set(gone.removed) == [RepoPath(string: "Sources/A.swift"), RepoPath(string: "Sources/F.swift")])
        w.setFolder(plain)   // same registry: nothing changed, nothing emitted
        w.rescan()
        w.stop()
        #expect(await reader.next() == nil)
    }

    @Test(.timeLimit(.minutes(1))) func fsEventsCoverASiblingWorktreeAddedBySetFolder() async throws {
        let (d, sib, withFeature) = try makeSiblingRepo("live-sib")
        let plain = folder(d)
        let w = RepoWatcher(folder: plain, initial: FileTreeScanner.scan(folder: plain), latency: 0.2)
        let reader = DeltaReader(w.deltas)
        w.start()
        w.setFolder(withFeature)
        let registered = try #require(await reader.next())          // the sibling's existing file arrives as an add
        #expect(registered.origin == .worktree("feature") && registered.added == [RepoPath(string: "Sources/A.swift")])
        try await Task.sleep(for: .milliseconds(300))               // let the recreated stream attach
        try "n".write(to: sib.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let delta = try #require(await reader.next())
        #expect(delta.origin == .worktree("feature") && delta.added.contains(RepoPath(string: "new.txt")))
        w.stop()
    }
}

final class DeltaReader: @unchecked Sendable {
    private var it: AsyncStream<TreeDelta>.Iterator
    init(_ s: AsyncStream<TreeDelta>) { it = s.makeAsyncIterator() }
    func next() async -> TreeDelta? { await it.next() }
}
