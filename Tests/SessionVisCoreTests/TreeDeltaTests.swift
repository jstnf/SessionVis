import Testing
@testable import SessionVisCore

@Suite struct TreeDeltaTests {
    func p(_ s: String) -> RepoPath { RepoPath(string: s) }

    @Test func addsAndRemoves() {
        let d = TreeDelta.compute(old: [p("a"), p("b")], new: [p("b"), p("c")])
        #expect(d.added == [p("c")] && d.removed == [p("a")] && d.moved.isEmpty && !d.isEmpty)
        #expect(TreeDelta.compute(old: [p("a")], new: [p("a")]).isEmpty)
    }

    @Test func uniqueNamePairsAsMove() {
        let d = TreeDelta.compute(old: [p("Sources/A/File.swift"), p("x")], new: [p("Sources/B/File.swift"), p("x")])
        #expect(d.moved == [TreeDelta.Move(from: p("Sources/A/File.swift"), to: p("Sources/B/File.swift"))])
        #expect(d.added.isEmpty && d.removed.isEmpty)
    }

    @Test func ambiguousNamesStaySeparate() {
        let d = TreeDelta.compute(old: [p("a/f.swift"), p("b/f.swift")], new: [p("c/f.swift")])
        #expect(d.moved.isEmpty)
        #expect(d.removed == [p("a/f.swift"), p("b/f.swift")] && d.added == [p("c/f.swift")])
    }

    @Test func deterministicOrdering() {
        let d = TreeDelta.compute(old: [p("z"), p("y")], new: [p("b"), p("a")])
        #expect(d.added == [p("a"), p("b")] && d.removed == [p("y"), p("z")])
    }
}
