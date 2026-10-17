import Foundation
import Testing
@testable import SessionVisCore

@Suite struct DirectoryListCacheTests {
    let t1 = FileTree(files: [RepoPath(string: "A/a.swift")])
    let t2 = FileTree(files: [RepoPath(string: "B/b.swift")])
    let dirA = [RepoPath(string: "A")], dirB = [RepoPath(string: "B")]

    @Test func eachCacheServesItsOwnTreeAtTheSameVersion() {
        let c1 = DirectoryListCache(), c2 = DirectoryListCache()
        #expect(c1.sortedDirectories(of: t1, version: 0) == dirA)
        #expect(c2.sortedDirectories(of: t2, version: 0) == dirB)
        #expect(c1.sortedDirectories(of: t1, version: 0) == dirA)
    }

    @Test func recomputesOnlyWhenTheVersionChangesOrAfterReset() {
        let c = DirectoryListCache()
        #expect(c.sortedDirectories(of: t1, version: 1) == dirA)
        #expect(c.sortedDirectories(of: t2, version: 1) == dirA)   // served from the cache until the version moves
        #expect(c.sortedDirectories(of: t2, version: 2) == dirB)
        c.reset()
        #expect(c.sortedDirectories(of: t1, version: 2) == dirA)
    }
}
