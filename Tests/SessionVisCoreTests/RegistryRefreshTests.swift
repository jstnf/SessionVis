import Foundation
import Testing
@testable import SessionVisCore

@Suite struct RegistryRefreshTests {
    let a = Worktree(name: "a", path: "/r/.claude/worktrees/a"), b = Worktree(name: "b", path: "/x/b")

    @Test func nextFolderOnlyWhenTheListingChanged() {
        let current = PathFolder(root: "/r", worktrees: [a])
        #expect(RegistryRefresh.next(current: current, listed: nil) == nil)          // git failed: keep what we had
        #expect(RegistryRefresh.next(current: current, listed: [a]) == nil)          // unchanged
        #expect(RegistryRefresh.next(current: current, listed: [a, b]) == PathFolder(root: "/r", worktrees: [a, b]))
        #expect(RegistryRefresh.next(current: current, listed: []) == PathFolder(root: "/r"))
    }

    @Test func folderFallsBackToTheConventionOutsideGit() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d.appendingPathComponent(".claude/worktrees/conv"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let f = RegistryRefresh.folder(root: d.path)
        #expect(f.root == PathFolder.normalize(d.path))
        #expect(f.worktrees == [Worktree(name: "conv", path: PathFolder.normalize(d.path) + "/.claude/worktrees/conv")])
    }

    @Test func folderUsesGitWhenAvailable() throws {
        let root = try GitFixtures.makeRepo()
        let parent = (root as NSString).deletingLastPathComponent
        defer { try? FileManager.default.removeItem(atPath: parent) }
        try FileManager.default.createDirectory(atPath: root + "/.claude/worktrees/stale", withIntermediateDirectories: true)
        try GitFixtures.git(["worktree", "add", "-q", "../feature"], in: root)
        #expect(RegistryRefresh.folder(root: root) == PathFolder(root: root, worktrees: [Worktree(name: "feature", path: parent + "/feature")]))   // stale is not listed
    }
}
