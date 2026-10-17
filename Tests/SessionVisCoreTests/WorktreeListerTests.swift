import Foundation
import Testing
@testable import SessionVisCore

/// A real repository with one empty commit, under a symlink-free path (git prints real paths, and macOS temp dirs are symlinked).
enum GitFixtures {
    enum GitError: Error { case failed([String]) }

    /// Returns `<base>/repo`; delete `<base>` (the parent) when done.
    static func makeRepo() throws -> String {
        let tmp = FileManager.default.temporaryDirectory.path
        let base = (PathFolder.realPath(tmp) ?? tmp) + "/wt-git-\(UUID().uuidString)"
        let root = base + "/repo"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try git(["init", "-q"], in: root)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], in: root)
        return root
    }

    static func git(_ args: [String], in dir: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-c", "init.templateDir=", "-C", dir] + args
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("GIT_") { env[key] = nil }
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["HOME"] = FileManager.default.temporaryDirectory.path
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw GitError.failed(args) }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw GitError.failed(args) }
    }
}

@Suite struct WorktreeListerTests {
    func block(_ path: String, extra: String = "") -> String {
        "worktree \(path)\nHEAD 0123456789abcdef0123456789abcdef01234567\nbranch refs/heads/x\n\(extra)"
    }

    @Test func parsesEveryKindOfCheckoutDropsRootBareAndPrunable() {
        let porcelain = [
            block("/private/Users/me/repo"),                          // the root, as git prints it (real path): dropped
            block("/private/Users/me/repo/.claude/worktrees/a"),      // mapped back under the given root
            block("/private/Users/me/repo/.claude/worktrees/b"),
            block("/private/Users/me/repo/.worktrees/c"),
            block("/Users/me/repo-feature"),
            block("/Users/me/elsewhere/a"),                            // same basename as the nested "a": path order decides who gets the suffix
            "worktree /Users/me/bare.git\nbare\n",
            block("/Users/me/gone", extra: "prunable gitdir file points to non-existent location\n"),
            block("/Users/me/not-a-dir"),
        ].joined(separator: "\n") + "\n"
        let dirs: Set<String> = ["/Users/me/repo/.claude/worktrees/a", "/Users/me/repo/.claude/worktrees/b", "/Users/me/repo/.worktrees/c",
                                 "/Users/me/repo-feature", "/Users/me/elsewhere/a", "/Users/me/gone", "/Users/me/bare.git"]
        let out = WorktreeLister.parse(porcelain: porcelain, root: "/Users/me/repo", realRoot: "/private/Users/me/repo", toplevel: "/private/Users/me/repo", prefix: "") { dirs.contains($0) }
        #expect(out == [
            Worktree(name: "a", path: "/Users/me/elsewhere/a"),
            Worktree(name: "repo-feature", path: "/Users/me/repo-feature"),
            Worktree(name: "a-2", path: "/Users/me/repo/.claude/worktrees/a"),
            Worktree(name: "b", path: "/Users/me/repo/.claude/worktrees/b"),
            Worktree(name: "c", path: "/Users/me/repo/.worktrees/c"),
        ])
    }

    @Test func rootGivenAsLinkedWorktreeSkipsOnlyItself() {
        let porcelain = block("/Users/me/repo") + "\n" + block("/Users/me/repo-feature") + "\n"
        let out = WorktreeLister.parse(porcelain: porcelain, root: "/Users/me/repo-feature", realRoot: "/Users/me/repo-feature", toplevel: "/Users/me/repo-feature", prefix: "") { _ in true }
        #expect(out == [Worktree(name: "repo", path: "/Users/me/repo")])
    }

    @Test func subdirectoryRootMapsSiblingsAndDropsTheEnclosingCheckout() {
        let porcelain = [block("/Users/me/repo"), block("/Users/me/repo-feat"), block("/Users/me/repo-nopkg")].joined(separator: "\n") + "\n"
        let dirs: Set<String> = ["/Users/me/repo-feat/pkg/app"]
        let out = WorktreeLister.parse(porcelain: porcelain, root: "/Users/me/repo/pkg/app", realRoot: "/Users/me/repo/pkg/app",
                                       toplevel: "/Users/me/repo", prefix: "pkg/app/") { dirs.contains($0) }
        #expect(out == [Worktree(name: "repo-feat", path: "/Users/me/repo-feat/pkg/app")])
    }

    @Test func blockWithEmptyPathIsDropped() {
        let out = WorktreeLister.parse(porcelain: "worktree \nHEAD 0123\nbranch refs/heads/x\n", root: "/r", realRoot: "/r", toplevel: "/r", prefix: "") { _ in true }
        #expect(out == [])
    }

    @Test func emptyOrGarbageListingYieldsNothing() {
        #expect(WorktreeLister.parse(porcelain: "", root: "/r", realRoot: "/r", toplevel: "/r", prefix: "") { _ in true } == [])
        #expect(WorktreeLister.parse(porcelain: "fatal: not a git repository\n", root: "/r", realRoot: "/r", toplevel: "/r", prefix: "") { _ in true } == [])
    }

    @Test func conventionFallbackListsDirectoriesOnly() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("wt-conv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: d) }
        let wts = d.appendingPathComponent(".claude/worktrees")
        for sub in ["b", "a", ".hidden"] {
            try FileManager.default.createDirectory(at: wts.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try "x".write(to: wts.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let root = PathFolder.normalize(d.path)
        #expect(WorktreeLister.conventionFallback(root: root) == [
            Worktree(name: "a", path: root + "/.claude/worktrees/a"),
            Worktree(name: "b", path: root + "/.claude/worktrees/b"),
        ])
        #expect(WorktreeLister.conventionFallback(root: "/nonexistent-\(UUID().uuidString)") == [])
    }

    @Test func realPathResolvesSymlinksAndIsNilForMissingPaths() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("wt-real-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: d) }
        try FileManager.default.createDirectory(at: d.appendingPathComponent("target"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: d.appendingPathComponent("link").path, withDestinationPath: "target")
        let real = try #require(PathFolder.realPath(d.appendingPathComponent("link").path))
        #expect(real.hasSuffix("/target") && !real.contains("/link"))
        #expect(PathFolder.realPath("/nonexistent-\(UUID().uuidString)") == nil)
    }
}

@Suite struct WorktreeListerGitTests {
    @Test func listsLinkedCheckoutsWhereverTheyAre() throws {
        let root = try GitFixtures.makeRepo()
        let parent = (root as NSString).deletingLastPathComponent
        defer { try? FileManager.default.removeItem(atPath: parent) }
        try GitFixtures.git(["worktree", "add", "-q", "../feature"], in: root)
        try GitFixtures.git(["worktree", "add", "-q", ".claude/worktrees/wt"], in: root)
        #expect(WorktreeLister.list(root: root) == [
            Worktree(name: "feature", path: parent + "/feature"),
            Worktree(name: "wt", path: root + "/.claude/worktrees/wt"),
        ])
        // Asked from the linked checkout, the main checkout is the one listed and the asker is skipped.
        #expect(WorktreeLister.list(root: parent + "/feature") == [
            Worktree(name: "repo", path: root),
            Worktree(name: "wt", path: root + "/.claude/worktrees/wt"),
        ])
    }

    @Test func subdirectoryRootListsTheSameSubdirectoryOfEachSibling() throws {
        let root = try GitFixtures.makeRepo()
        let parent = (root as NSString).deletingLastPathComponent
        defer { try? FileManager.default.removeItem(atPath: parent) }
        try FileManager.default.createDirectory(atPath: root + "/pkg/app", withIntermediateDirectories: true)
        try "x".write(toFile: root + "/pkg/app/A.swift", atomically: true, encoding: .utf8)
        try GitFixtures.git(["add", "."], in: root)
        try GitFixtures.git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "files"], in: root)
        try GitFixtures.git(["worktree", "add", "-q", "../repo-feat"], in: root)
        #expect(WorktreeLister.list(root: root + "/pkg/app") == [Worktree(name: "repo-feat", path: parent + "/repo-feat/pkg/app")])
        try FileManager.default.removeItem(atPath: parent + "/repo-feat/pkg/app")
        #expect(WorktreeLister.list(root: root + "/pkg/app") == [])
    }

    @Test func deletedDirectoryIsPrunableAndDropped() throws {
        let root = try GitFixtures.makeRepo()
        let parent = (root as NSString).deletingLastPathComponent
        defer { try? FileManager.default.removeItem(atPath: parent) }
        try GitFixtures.git(["worktree", "add", "-q", "../gone"], in: root)
        try FileManager.default.removeItem(atPath: parent + "/gone")
        #expect(WorktreeLister.list(root: root) == [])
    }

    @Test func registryDirectoryIsTheCommonDirFromEitherCheckout() throws {
        let root = try GitFixtures.makeRepo()
        let parent = (root as NSString).deletingLastPathComponent
        defer { try? FileManager.default.removeItem(atPath: parent) }
        try GitFixtures.git(["worktree", "add", "-q", "../feature"], in: root)
        #expect(WorktreeLister.registryDirectory(root: root) == root + "/.git/worktrees")
        #expect(WorktreeLister.registryDirectory(root: parent + "/feature") == root + "/.git/worktrees")
        try FileManager.default.createDirectory(atPath: root + "/pkg/app", withIntermediateDirectories: true)
        #expect(WorktreeLister.registryDirectory(root: root + "/pkg/app") == root + "/.git/worktrees")
    }

    @Test func nonGitDirectoryYieldsNil() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("wt-nogit-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: d) }
        #expect(WorktreeLister.list(root: d) == nil)
        #expect(WorktreeLister.registryDirectory(root: d) == nil)
    }
}
