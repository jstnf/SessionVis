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
        let (files, truncated) = FileTreeScanner.walkFiles(directory: d.path, limit: 100)
        #expect(Set(files) == ["Sources/App/Main.swift", "README.md", ".hidden/keep.txt"])
        #expect(!truncated)
    }

    @Test func walkTruncatesAtLimit() throws {
        let d = try makeDir()
        let (files, truncated) = FileTreeScanner.walkFiles(directory: d.path, limit: 2)
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
        let files = try #require(FileTreeScanner.gitFiles(directory: d.path))
        #expect(Set(files) == ["README.md", ".gitignore", "Sources/App/Main.swift", ".hidden/keep.txt"])
        let tree = FileTreeScanner.scan(directory: d.path)
        #expect(tree.fileCount == 4 && !tree.truncated)
    }

    @Test func nonGitFallsBackToWalk() throws {
        let d = try makeDir()
        #expect(FileTreeScanner.gitFiles(directory: d.path) == nil)
        #expect(FileTreeScanner.scan(directory: d.path).fileCount == 4)     // three main files plus the worktree-only W.swift
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

    @Test func originRootPaths() {
        #expect(Origin.main.rootPath(under: "/repo") == "/repo")
        #expect(Origin.worktree("wt").rootPath(under: "/repo") == "/repo/.claude/worktrees/wt")
        #expect(Origin.worktreesDirectory(under: "/repo") == "/repo/.claude/worktrees")
    }

    /// A repo with one git worktree checkout and one stale (non-git) worktree folder.
    func makeWorktreeRepo() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("wt-scan-\(UUID().uuidString)")
        for sub in ["Sources", ".claude/worktrees/feat/Sources", ".claude/worktrees/stale/Docs", ".claude/worktrees/feat/Sources/Shared"] {
            try FileManager.default.createDirectory(at: d.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        for f in ["Sources/Main.swift", "README.md", "Sources/Shared", ".claude/worktrees/feat/Sources/Main.swift",
                  ".claude/worktrees/feat/Sources/New.swift", ".claude/worktrees/feat/Sources/Shared/inner.swift",
                  ".claude/worktrees/stale/Docs/note.md"] {
            try "x".write(to: d.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        return d
    }

    @Test func scanOriginsListsMainAndEachWorktree() throws {
        let d = try makeWorktreeRepo()
        #expect(FileTreeScanner.worktreeNames(directory: d.path) == ["feat", "stale"])
        let r = FileTreeScanner.scanOrigins(directory: d.path)
        #expect(r.files[.main] == Set(["Sources/Main.swift", "README.md", "Sources/Shared"].map(RepoPath.init(string:))))
        #expect(r.files[.worktree("feat")] == Set(["Sources/Main.swift", "Sources/New.swift", "Sources/Shared/inner.swift"].map(RepoPath.init(string:))))
        #expect(r.files[.worktree("stale")] == [RepoPath(string: "Docs/note.md")])     // not a git checkout: walked
        #expect(!r.truncated)
        // Merged tree: shared file has both origins, New.swift is a ghost, the conflict under the main file "Sources/Shared" is dropped.
        #expect(r.tree.node(RepoPath(string: "Sources/Main.swift"))?.origins == [.main, .worktree("feat")])
        #expect(r.tree.isGhost(RepoPath(string: "Sources/New.swift")))
        #expect(r.tree.isGhost(RepoPath(string: "Docs/note.md")))
        #expect(r.tree.node(RepoPath(string: "Sources/Shared/inner.swift")) == nil)
        #expect(r.tree.node(RepoPath(string: "Sources/Shared"))?.isDirectory == false)
        #expect(r.tree.fileCount == 5)
        #expect(FileTreeScanner.scan(directory: d.path).fileCount == 5)
    }

    @Test func scanOriginsCapAppliesToUnionMainFirst() throws {
        // Distinct paths in listing order: main's 3, then feat's New.swift and Shared/inner.swift (the clash with main's
        // file still counts; the merge drops it), then stale's note.md. feat's Main.swift is main's and costs nothing.
        let d = try makeWorktreeRepo()
        let shared = RepoPath(string: "Sources/Main.swift"), new = RepoPath(string: "Sources/New.swift")
        let inner = RepoPath(string: "Sources/Shared/inner.swift")
        let four = FileTreeScanner.scanOrigins(directory: d.path, limit: 4)
        #expect(four.truncated && four.tree.truncated)
        #expect(four.files[.main]?.count == 3)
        #expect(four.files[.worktree("feat")] == [shared, new])
        #expect(four.files[.worktree("stale")]?.isEmpty == true)
        #expect(four.tree.fileCount == 4 && four.tree.isGhost(new))
        let five = FileTreeScanner.scanOrigins(directory: d.path, limit: 5)
        #expect(five.truncated)
        #expect(five.files[.worktree("feat")] == [shared, new, inner])
        #expect(five.files[.worktree("stale")]?.isEmpty == true)
        let six = FileTreeScanner.scanOrigins(directory: d.path, limit: 6)
        #expect(!six.truncated)
        #expect(six.files[.worktree("feat")]?.count == 3 && six.files[.worktree("stale")] == [RepoPath(string: "Docs/note.md")])
        // Main exactly filling the cap, with worktrees that add nothing new, is not truncated.
        try FileManager.default.removeItem(at: d.appendingPathComponent(".claude/worktrees/stale"))
        try FileManager.default.removeItem(at: d.appendingPathComponent(".claude/worktrees/feat/Sources/New.swift"))
        try FileManager.default.removeItem(at: d.appendingPathComponent(".claude/worktrees/feat/Sources/Shared"))
        let exact = FileTreeScanner.scanOrigins(directory: d.path, limit: 3)
        #expect(!exact.truncated && exact.files[.worktree("feat")] == [shared])
    }
}
