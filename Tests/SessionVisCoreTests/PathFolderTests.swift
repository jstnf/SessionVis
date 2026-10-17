import Testing
@testable import SessionVisCore

@Suite struct RepoPathTests {
    @Test func parsesAndJoins() {
        let p = RepoPath(string: "Sources/App/Main.swift")
        #expect(p.components == ["Sources", "App", "Main.swift"])
        #expect(p.string == "Sources/App/Main.swift")
        #expect(p.name == "Main.swift")
        #expect(p.depth == 3)
        #expect(p.parent == RepoPath(string: "Sources/App"))
        #expect(RepoPath(string: "").isRoot)
        #expect(RepoPath(string: "").parent == nil)
    }

    @Test func comparesLexically() {
        #expect(RepoPath(string: "a/b") < RepoPath(string: "a/c"))
        #expect(RepoPath(string: "a") < RepoPath(string: "a/b"))
    }
}

@Suite struct PathFolderTests {
    let root = "/Users/me/repo"
    let claude = Worktree(name: "feature-x", path: "/Users/me/repo/.claude/worktrees/feature-x")
    let inner = Worktree(name: "y", path: "/Users/me/repo/.worktrees/y")
    let sibling = Worktree(name: "repo-feature", path: "/Users/me/repo-feature")
    let siblingTwo = Worktree(name: "repo-feature-two", path: "/Users/me/repo-feature-two")
    let nested = Worktree(name: "deep", path: "/Users/me/repo/.worktrees/y/deep")
    var folder: PathFolder { PathFolder(root: root + "/", worktrees: [claude, inner, sibling, siblingTwo, nested]) }   // trailing slash must be tolerated

    @Test func foldsPlainPath() {
        let f = folder.fold("/Users/me/repo/Sources/A.swift")
        #expect(f?.path == RepoPath(string: "Sources/A.swift") && f?.worktree == nil)
        #expect(folder.fold("/Users/me/repo")?.path.isRoot == true)
        #expect(PathFolder(root: root).fold("/Users/me/repo/Sources/A.swift")?.path == RepoPath(string: "Sources/A.swift"))
    }

    @Test func foldsEveryKindOfCheckoutAndTagsIt() {
        #expect(folder.fold("/Users/me/repo/.claude/worktrees/feature-x/Sources/A.swift") == FoldedPath(path: RepoPath(string: "Sources/A.swift"), worktree: "feature-x"))
        #expect(folder.fold("/Users/me/repo/.worktrees/y/Sources/A.swift") == FoldedPath(path: RepoPath(string: "Sources/A.swift"), worktree: "y"))
        #expect(folder.fold("/Users/me/repo-feature/Sources/A.swift") == FoldedPath(path: RepoPath(string: "Sources/A.swift"), worktree: "repo-feature"))
    }

    @Test func siblingPrefixEndsAtASeparator() {
        #expect(folder.fold("/Users/me/repo-feature-two/A.swift") == FoldedPath(path: RepoPath(string: "A.swift"), worktree: "repo-feature-two"))
        #expect(folder.fold("/Users/me/repo-featureX/A.swift") == nil)
        #expect(folder.fold("/Users/me/repo-two/A.swift") == nil)
        #expect(folder.fold("/Users/me/other/A.swift") == nil)
    }

    @Test func worktreeRootItselfIsNotAFile() {
        #expect(folder.fold("/Users/me/repo/.claude/worktrees/feature-x") == nil)
        #expect(folder.fold("/Users/me/repo/.worktrees/y") == nil)
        #expect(folder.fold("/Users/me/repo-feature") == nil)
        #expect(folder.fold("/Users/me/repo/.claude/worktrees") == nil)
    }

    @Test func unregisteredClaudeWorktreeFolderFoldsToNil() {
        #expect(folder.fold("/Users/me/repo/.claude/worktrees/stale/Docs/note.md") == nil)
        #expect(folder.fold("/Users/me/repo/.claude/worktrees/stale") == nil)
        #expect(PathFolder(root: root).fold("/Users/me/repo/.claude/worktrees/anything/A.swift") == nil)
        // A `.worktrees` folder that is not registered is just a directory of the root.
        #expect(PathFolder(root: root).fold("/Users/me/repo/.worktrees/z/A.swift")?.path == RepoPath(string: ".worktrees/z/A.swift"))
    }

    @Test func nestedWorktreeWinsOverItsContainer() {
        #expect(folder.fold("/Users/me/repo/.worktrees/y/deep/A.swift") == FoldedPath(path: RepoPath(string: "A.swift"), worktree: "deep"))
        #expect(folder.fold("/Users/me/repo/.worktrees/y/deeper/A.swift") == FoldedPath(path: RepoPath(string: "deeper/A.swift"), worktree: "y"))
    }

    @Test func membershipAndNamingForEveryKindOfCwd() {
        let f = folder
        #expect(f.isMemberCwd("/Users/me/repo") && f.isMemberCwd("/Users/me/repo/"))
        #expect(!f.isMemberCwd("/Users/me/repo/Sources") && !f.isMemberCwd("/Users/me/other"))
        #expect(f.isMemberCwd("/Users/me/repo/.claude/worktrees/feature-x") && f.isMemberCwd("/Users/me/repo/.claude/worktrees/feature-x/sub"))
        #expect(f.isMemberCwd("/Users/me/repo/.worktrees/y") && f.isMemberCwd("/Users/me/repo-feature/sub"))
        #expect(!f.isMemberCwd("/Users/me/repo/.claude/worktrees/stale"))
        #expect(!f.isMemberCwd("/Users/me/repo-featureX"))
        #expect(f.worktreeName(ofCwd: "/Users/me/repo/.claude/worktrees/feature-x/sub") == "feature-x")
        #expect(f.worktreeName(ofCwd: "/Users/me/repo-feature") == "repo-feature")
        #expect(f.worktreeName(ofCwd: "/Users/me/repo/.worktrees/y/deep/sub") == "deep")
        #expect(f.worktreeName(ofCwd: "/Users/me/repo") == nil)
        #expect(f.worktreeName(ofCwd: "/Users/me/repo/.claude/worktrees/stale") == nil)
    }

    @Test func rootPathOfOrigins() {
        #expect(folder.rootPath(of: .main) == "/Users/me/repo")
        #expect(folder.rootPath(of: .worktree("repo-feature")) == "/Users/me/repo-feature")
        #expect(folder.rootPath(of: .worktree("y")) == "/Users/me/repo/.worktrees/y")
        #expect(folder.rootPath(of: .worktree("unknown")) == "/Users/me/repo/.claude/worktrees/unknown")
    }

    @Test func nestedWorktreePathsAreTheOnesInsideTheRoot() {
        #expect(folder.nestedWorktreePaths == [RepoPath(string: ".claude/worktrees/feature-x"), RepoPath(string: ".worktrees/y"), RepoPath(string: ".worktrees/y/deep")])
        #expect(PathFolder(root: root).nestedWorktreePaths == [])
    }

    @Test func normalisesDotSegmentsAndWorktreePaths() {
        #expect(folder.fold("/Users/me/repo/Sources/./Sub/../A.swift")?.path == RepoPath(string: "Sources/A.swift"))
        #expect(PathFolder.normalize("/a/b/../../c/") == "/c")
        #expect(PathFolder.normalize("/") == "/")
        let sloppy = PathFolder(root: root, worktrees: [Worktree(name: "s", path: "/Users/me/repo-s/")])
        #expect(sloppy.worktrees == [Worktree(name: "s", path: "/Users/me/repo-s")])
        #expect(sloppy.fold("/Users/me/repo-s/A.swift")?.worktree == "s")
    }

    @Test func equalityFollowsRootAndWorktrees() {
        #expect(PathFolder(root: root, worktrees: [sibling]) == PathFolder(root: root + "/", worktrees: [sibling]))
        #expect(PathFolder(root: root, worktrees: [sibling]) != PathFolder(root: root))
    }
}
