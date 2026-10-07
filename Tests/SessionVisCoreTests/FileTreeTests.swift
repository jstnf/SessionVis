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
        #expect(FileTreeScanner.scan(directory: d.path).fileCount == 3)
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
}
