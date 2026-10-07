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
    let folder = PathFolder(root: "/Users/me/repo/")   // trailing slash must be tolerated

    @Test func foldsPlainPath() {
        let f = folder.fold("/Users/me/repo/Sources/A.swift")
        #expect(f?.path == RepoPath(string: "Sources/A.swift"))
        #expect(f?.worktree == nil)
    }

    @Test func foldsWorktreePathAndTagsIt() {
        let f = folder.fold("/Users/me/repo/.claude/worktrees/feature-x/Sources/A.swift")
        #expect(f?.path == RepoPath(string: "Sources/A.swift"))
        #expect(f?.worktree == "feature-x")
    }

    @Test func worktreeRootItselfIsNotAFile() {
        #expect(folder.fold("/Users/me/repo/.claude/worktrees/feature-x") == nil)
        #expect(folder.fold("/Users/me/repo/.claude/worktrees") == nil)
    }

    @Test func externalPathIsNil() {
        #expect(folder.fold("/Users/me/other/A.swift") == nil)
        #expect(folder.fold("/Users/me/repo-two/A.swift") == nil)   // prefix must end at a separator
    }

    @Test func normalisesDotSegments() {
        let f = folder.fold("/Users/me/repo/Sources/./Sub/../A.swift")
        #expect(f?.path == RepoPath(string: "Sources/A.swift"))
        #expect(PathFolder.normalize("/a/b/../../c/") == "/c")
        #expect(PathFolder.normalize("/") == "/")
    }

    @Test func rootItselfFoldsToRootPath() {
        #expect(folder.fold("/Users/me/repo")?.path.isRoot == true)
    }
}
