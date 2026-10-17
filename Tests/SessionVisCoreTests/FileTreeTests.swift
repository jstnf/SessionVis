import Foundation
import Testing
@testable import SessionVisCore

@Suite struct FileTreeTests {
    @Test func buildsDirectoriesChildrenAndLeafCounts() {
        let tree = FileTree(files: ["b.txt", "Sources/App/Main.swift", "Sources/App/View.swift", "Sources/Lib/L.swift", "a.txt"].map(RepoPath.init(string:)))
        #expect(tree.fileCount == 5)
        #expect(tree.root.leafCount == 5)
        #expect(tree.root.children == [RepoPath(string: "Sources"), RepoPath(string: "a.txt"), RepoPath(string: "b.txt")])   // dirs first, then by name
        #expect(tree.node(RepoPath(string: "Sources"))?.leafCount == 3)
        #expect(tree.node(RepoPath(string: "Sources/App"))?.isDirectory == true)
        #expect(tree.files(in: RepoPath(string: "Sources/App")).map(\.name) == ["Main.swift", "View.swift"])
        #expect(tree.subdirectories(in: RepoPath(string: "Sources")).map(\.name) == ["App", "Lib"])
        #expect(tree.node(RepoPath(string: "a.txt"))?.isDirectory == false)
    }

    @Test func insertAddsNewFilesAndIgnoresKnownOnes() {
        var tree = FileTree(files: [RepoPath(string: "a.txt")])
        #expect(tree.insert(file: RepoPath(string: "New/Deep/f.swift")) == true)
        #expect(tree.insert(file: RepoPath(string: "New/Deep/f.swift")) == false)
        #expect(tree.insert(file: RepoPath(string: "a.txt")) == false)
        #expect(tree.fileCount == 2)
        #expect(tree.root.leafCount == 2)
        #expect(tree.node(RepoPath(string: "New"))?.leafCount == 1)
        #expect(tree.root.children.first == RepoPath(string: "New"))
    }

    func makeDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
        for sub in ["Sources/App", "node_modules/x", ".git/objects", ".claude/worktrees/wt/Sources", ".hidden"] {
            try FileManager.default.createDirectory(at: d.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        for f in ["Sources/App/Main.swift", "README.md", "node_modules/x/i.js", ".git/objects/abc", ".claude/worktrees/wt/Sources/W.swift", ".hidden/keep.txt"] {
            try "x".write(to: d.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        return d
    }

    @Test func walkSkipsExcludedDirectoriesButKeepsDotfiles() throws {
        let d = try makeDir()
        let (files, truncated) = FileTreeScanner.walkFiles(directory: d.path, skipping: [FileTreeScanner.worktreesPrefix], limit: 100)
        #expect(Set(files) == ["Sources/App/Main.swift", "README.md", ".hidden/keep.txt"])
        #expect(!truncated)
    }

    @Test func walkTruncatesAtLimit() throws {
        let d = try makeDir()
        let (files, truncated) = FileTreeScanner.walkFiles(directory: d.path, skipping: [FileTreeScanner.worktreesPrefix], limit: 2)
        #expect(files.count == 2 && truncated)
    }

    @Test func gitModeListsTrackedAndUntrackedNotIgnored() throws {
        let d = try makeDir()
        func git(_ args: String...) throws {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git", "-C", d.path] + args; p.standardOutput = nil; p.standardError = nil
            try p.run(); p.waitUntilExit()
        }
        try git("init", "-q")
        try git("config", "user.email", "t@t"); try git("config", "user.name", "t")
        try ".claude/\nnode_modules/\n".write(to: d.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try git("add", "README.md", ".gitignore"); try git("commit", "-q", "-m", "init")
        let files = try #require(FileTreeScanner.gitFiles(directory: d.path, skipping: [FileTreeScanner.worktreesPrefix]))
        #expect(Set(files) == ["README.md", ".gitignore", "Sources/App/Main.swift", ".hidden/keep.txt"])
        let tree = FileTreeScanner.scan(folder: PathFolder(root: d.path))
        #expect(tree.fileCount == 4 && !tree.truncated)
    }

    @Test func gitModeDropsEmbeddedCheckoutsAndKeepsSiblingNames() throws {
        let root = try GitFixtures.makeRepo()
        let parent = (root as NSString).deletingLastPathComponent
        defer { try? FileManager.default.removeItem(atPath: parent) }
        try "a".write(toFile: root + "/README.md", atomically: true, encoding: .utf8)
        try GitFixtures.git(["add", "."], in: root)
        try GitFixtures.git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "readme"], in: root)
        try GitFixtures.git(["worktree", "add", "-q", ".worktrees/y"], in: root)
        try FileManager.default.createDirectory(atPath: root + "/.worktrees/yy", withIntermediateDirectories: true)
        try "b".write(toFile: root + "/.worktrees/yy/f.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: root + "/vendor/z", withIntermediateDirectories: true)
        try GitFixtures.git(["init", "-q"], in: root + "/vendor/z")
        let folder = PathFolder(root: root, worktrees: [Worktree(name: "y", path: root + "/.worktrees/y")])
        let result = FileTreeScanner.scanOrigins(folder: folder)
        let main = try #require(result.files[.main])
        for dropped in [".worktrees/y", ".worktrees/y/", "vendor/z", "vendor/z/"] {
            #expect(!main.contains(RepoPath(string: dropped)))
            #expect(result.tree.node(RepoPath(string: dropped)) == nil)
        }
        #expect(main.contains(RepoPath(string: ".worktrees/yy/f.txt")))
        #expect(result.files[.worktree("y")]?.contains(RepoPath(string: "README.md")) == true)
        #expect(!(result.files[.worktree("y")] ?? []).contains(RepoPath(string: ".worktrees/y")))
    }

    @Test func nonGitFallsBackToWalk() throws {
        let d = try makeDir()
        #expect(FileTreeScanner.gitFiles(directory: d.path, skipping: [FileTreeScanner.worktreesPrefix]) == nil)
        #expect(FileTreeScanner.scan(folder: PathFolder(root: d.path)).fileCount == 3)     // the unregistered .claude/worktrees/wt folder is not an origin
    }

    @Test func removePrunesEmptyDirectoriesAndFixesCounts() {
        var tree = FileTree(files: ["A/B/f.swift", "A/g.swift", "h.txt"].map(RepoPath.init(string:)))
        let r1 = tree.remove(file: RepoPath(string: "A/B/f.swift"))
        #expect(r1)
        #expect(tree.node(RepoPath(string: "A/B")) == nil)                      // pruned
        #expect(tree.node(RepoPath(string: "A"))?.leafCount == 1)
        #expect(tree.node(RepoPath(string: "A"))?.children == [RepoPath(string: "A/g.swift")])
        #expect(tree.root.leafCount == 2 && tree.fileCount == 2)
        let r2 = tree.remove(file: RepoPath(string: "A/g.swift"))
        #expect(r2)
        #expect(tree.node(RepoPath(string: "A")) == nil)
        let r3 = tree.remove(file: RepoPath(string: "h.txt"))
        #expect(r3)
        #expect(tree.root.children.isEmpty && tree.root.leafCount == 0 && tree.node(RepoPath([])) != nil)   // root never pruned
        let r4 = tree.remove(file: RepoPath(string: "nope"))
        #expect(!r4)
        let r5 = tree.remove(file: RepoPath(string: "A"))
        #expect(!r5)                       // directories are not files
        #expect(tree.files.isEmpty)
    }

    @Test func originsUnionOnInsertAndGhostIsNoMain() {
        var tree = FileTree(files: [RepoPath(string: "A/a.swift")])
        #expect(tree.node(RepoPath(string: "A/a.swift"))?.origins == [.main])
        #expect(!tree.isGhost(RepoPath(string: "A/a.swift")))
        #expect(tree.insert(file: RepoPath(string: "A/g.swift"), origin: .worktree("wt")) == true)
        #expect(tree.isGhost(RepoPath(string: "A/g.swift")))
        #expect(tree.insert(file: RepoPath(string: "A/g.swift"), origin: .main) == false)      // union, not new
        #expect(tree.node(RepoPath(string: "A/g.swift"))?.origins == [.main, .worktree("wt")])
        #expect(!tree.isGhost(RepoPath(string: "A/g.swift")))
        #expect(tree.isGhost(RepoPath(string: "A")) == false)                                  // directories are never ghosts
        #expect(tree.files(in: .worktree("wt")) == [RepoPath(string: "A/g.swift")])
        #expect(tree.filesByOrigin[.main] == [RepoPath(string: "A/a.swift"), RepoPath(string: "A/g.swift")])
        #expect(tree.fileCount == 2)
    }

    @Test func removeOriginDeletesOnlyWhenLastOriginGoes() {
        var tree = FileTree(files: [RepoPath(string: "A/a.swift")])
        tree.insert(file: RepoPath(string: "A/a.swift"), origin: .worktree("wt"))
        #expect(tree.remove(file: RepoPath(string: "A/a.swift"), origin: .main) == false)
        #expect(tree.isGhost(RepoPath(string: "A/a.swift")))
        #expect(tree.fileCount == 1)
        #expect(tree.remove(file: RepoPath(string: "A/a.swift"), origin: .worktree("wt")) == true)
        #expect(tree.node(RepoPath(string: "A/a.swift")) == nil && tree.node(RepoPath(string: "A")) == nil)
        #expect(tree.remove(file: RepoPath(string: "nope"), origin: .main) == false)
        var other = FileTree(files: [RepoPath(string: "x.swift")])
        other.insert(file: RepoPath(string: "x.swift"), origin: .worktree("wt"))
        #expect(other.remove(file: RepoPath(string: "x.swift")) == true)                      // plain remove ignores origins
        #expect(other.files.isEmpty)
    }

    @Test func insertDropsConflictsWithExistingFilesAndDirectories() {
        var tree = FileTree(files: [RepoPath(string: "A/a.swift"), RepoPath(string: "B")])
        #expect(tree.insert(file: RepoPath(string: "B/inner.swift"), origin: .worktree("wt")) == false)   // ancestor is a file in main
        #expect(tree.node(RepoPath(string: "B/inner.swift")) == nil)
        #expect(tree.node(RepoPath(string: "B"))?.isDirectory == false && tree.node(RepoPath(string: "B"))?.children.isEmpty == true)
        #expect(tree.insert(file: RepoPath(string: "A"), origin: .worktree("wt")) == false)               // path is a directory in main
        #expect(tree.node(RepoPath(string: "A"))?.isDirectory == true)
        #expect(tree.fileCount == 2)
    }

    /// `<base>/repo` with a `.claude/worktrees/feat` checkout, a `.worktrees/nest` checkout nested in the root, a stale
    /// (unregistered) `.claude/worktrees/stale` folder, and a sibling checkout at `<base>/side`. None is a git repo: all are walked.
    func makeWorktreeRepo() throws -> (root: URL, folder: PathFolder) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("wt-scan-\(UUID().uuidString)")
        let d = base.appendingPathComponent("repo"), side = base.appendingPathComponent("side")
        for sub in ["Sources", ".claude/worktrees/feat/Sources/Shared", ".claude/worktrees/stale/Docs", ".worktrees/nest"] {
            try FileManager.default.createDirectory(at: d.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: side.appendingPathComponent("Docs"), withIntermediateDirectories: true)
        for f in ["Sources/Main.swift", "README.md", "Sources/Shared", ".claude/worktrees/feat/Sources/Main.swift",
                  ".claude/worktrees/feat/Sources/New.swift", ".claude/worktrees/feat/Sources/Shared/inner.swift",
                  ".claude/worktrees/stale/Docs/note.md", ".worktrees/nest/Nested.swift"] {
            try "x".write(to: d.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        try "x".write(to: side.appendingPathComponent("Docs/note.md"), atomically: true, encoding: .utf8)
        let folder = PathFolder(root: d.path, worktrees: [
            Worktree(name: "feat", path: d.appendingPathComponent(".claude/worktrees/feat").path),
            Worktree(name: "nest", path: d.appendingPathComponent(".worktrees/nest").path),
            Worktree(name: "side", path: side.path),
        ])
        return (d, folder)
    }

    @Test func scanOriginsListsRegisteredWorktreesWhereverTheyAre() throws {
        let (_, folder) = try makeWorktreeRepo()
        let r = FileTreeScanner.scanOrigins(folder: folder)
        #expect(r.files[.main] == Set(["Sources/Main.swift", "README.md", "Sources/Shared"].map(RepoPath.init(string:))))   // nested checkouts skipped
        #expect(r.files[.worktree("feat")] == Set(["Sources/Main.swift", "Sources/New.swift", "Sources/Shared/inner.swift"].map(RepoPath.init(string:))))
        #expect(r.files[.worktree("nest")] == [RepoPath(string: "Nested.swift")])
        #expect(r.files[.worktree("side")] == [RepoPath(string: "Docs/note.md")])
        #expect(r.files[.worktree("stale")] == nil)                                 // not registered: not an origin
        #expect(!r.truncated)
        // Merged tree: the shared file has both origins, New.swift is a ghost, the conflict under main's file "Sources/Shared" is dropped.
        #expect(r.tree.node(RepoPath(string: "Sources/Main.swift"))?.origins == [.main, .worktree("feat")])
        #expect(r.tree.isGhost(RepoPath(string: "Sources/New.swift")) && r.tree.isGhost(RepoPath(string: "Docs/note.md")) && r.tree.isGhost(RepoPath(string: "Nested.swift")))
        #expect(r.tree.node(RepoPath(string: "Sources/Shared/inner.swift")) == nil)
        #expect(r.tree.node(RepoPath(string: "Sources/Shared"))?.isDirectory == false)
        #expect(r.tree.node(RepoPath(string: ".worktrees/nest")) == nil && r.tree.node(RepoPath(string: ".worktrees/nest/Nested.swift")) == nil)
        #expect(r.tree.fileCount == 6)
        #expect(FileTreeScanner.scan(folder: folder).fileCount == 6)
    }

    @Test func scanWithoutRegisteredWorktreesListsMainOnly() throws {
        let (d, _) = try makeWorktreeRepo()
        let r = FileTreeScanner.scanOrigins(folder: PathFolder(root: d.path))
        #expect(r.files.keys.sorted() == [.main])
        #expect(r.tree.node(RepoPath(string: ".claude")) == nil)
        #expect(r.tree.node(RepoPath(string: ".worktrees/nest/Nested.swift")) != nil)   // an unregistered folder is plain files of the root
    }

    @Test func scanOriginsCapAppliesToUnionMainFirst() throws {
        // Distinct paths in listing order: main's 3, then feat's New.swift and Shared/inner.swift (the clash with main's
        // file still counts; the merge drops it), then nest's Nested.swift, then side's note.md. feat's Main.swift is main's and costs nothing.
        let (d, folder) = try makeWorktreeRepo()
        let shared = RepoPath(string: "Sources/Main.swift"), new = RepoPath(string: "Sources/New.swift")
        let inner = RepoPath(string: "Sources/Shared/inner.swift")
        let four = FileTreeScanner.scanOrigins(folder: folder, limit: 4)
        #expect(four.truncated && four.tree.truncated)
        #expect(four.files[.main]?.count == 3)
        #expect(four.files[.worktree("feat")] == [shared, new])
        #expect(four.files[.worktree("nest")]?.isEmpty == true && four.files[.worktree("side")]?.isEmpty == true)
        #expect(four.tree.fileCount == 4 && four.tree.isGhost(new))
        let five = FileTreeScanner.scanOrigins(folder: folder, limit: 5)
        #expect(five.truncated)
        #expect(five.files[.worktree("feat")] == [shared, new, inner])
        #expect(five.files[.worktree("nest")]?.isEmpty == true)
        let seven = FileTreeScanner.scanOrigins(folder: folder, limit: 7)
        #expect(!seven.truncated)
        #expect(seven.files[.worktree("nest")] == [RepoPath(string: "Nested.swift")] && seven.files[.worktree("side")] == [RepoPath(string: "Docs/note.md")])
        // Main exactly filling the cap, with worktrees that add nothing new, is not truncated.
        try FileManager.default.removeItem(at: d.appendingPathComponent(".claude/worktrees/feat/Sources/New.swift"))
        try FileManager.default.removeItem(at: d.appendingPathComponent(".claude/worktrees/feat/Sources/Shared"))
        try FileManager.default.removeItem(at: d.appendingPathComponent(".worktrees"))   // no longer registered, it would be plain files of main
        let onlyFeat = PathFolder(root: d.path, worktrees: [folder.worktrees[0]])
        let exact = FileTreeScanner.scanOrigins(folder: onlyFeat, limit: 3)
        #expect(!exact.truncated && exact.files[.worktree("feat")] == [shared])
    }
}
