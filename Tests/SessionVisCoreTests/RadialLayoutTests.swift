import CoreGraphics
import Testing
@testable import SessionVisCore

@Suite struct RadialLayoutTests {
    func near(_ a: CGPoint, _ b: CGPoint, _ eps: CGFloat = 0.01) -> Bool { abs(a.x - b.x) < eps && abs(a.y - b.y) < eps }

    @Test func rootAtOriginAndDepthRings() {
        let tree = FileTree(files: ["A/a1", "A/B/b1"].map(RepoPath.init(string:)))
        let l = RadialLayout.compute(tree)
        #expect(l.position(RepoPath([])) == .zero)
        let a = l.position(RepoPath(string: "A"))!, b = l.position(RepoPath(string: "A/B"))!
        #expect(abs(hypot(a.x, a.y) - Constants.ringSpacing) < 0.01)
        #expect(abs(hypot(b.x, b.y) - 2 * Constants.ringSpacing) < 0.01)
    }

    @Test func sectorsAreProportionalToLeafCount() {
        // A has 3 leaves, B has 1 → A gets 3/4 of the circle: mid angle 0.75π; B mid angle 1.75π.
        let tree = FileTree(files: ["A/1", "A/2", "A/3", "B/1"].map(RepoPath.init(string:)))
        let l = RadialLayout.compute(tree)
        let r = Constants.ringSpacing
        #expect(near(l.position(RepoPath(string: "A"))!, CGPoint(x: r * cos(0.75 * .pi), y: r * sin(0.75 * .pi))))
        #expect(near(l.position(RepoPath(string: "B"))!, CGPoint(x: r * cos(1.75 * .pi), y: r * sin(1.75 * .pi))))
    }

    @Test func filesRingAroundTheirDirectory() {
        let tree = FileTree(files: (0..<3).map { RepoPath(string: "A/f\($0)") })
        let l = RadialLayout.compute(tree)
        let a = l.position(RepoPath(string: "A"))!
        for i in 0..<3 {
            let f = l.position(RepoPath(string: "A/f\(i)"))!
            #expect(abs(hypot(f.x - a.x, f.y - a.y) - Constants.fileRingMinRadius) < 0.01)
        }
        // 100 files → radius grows to keep 7 pt spacing
        let big = FileTree(files: (0..<100).map { RepoPath(string: "A/f\($0)") })
        let lb = RadialLayout.compute(big)
        let ab = lb.position(RepoPath(string: "A"))!, f0 = lb.position(RepoPath(string: "A/f0"))!
        #expect(abs(hypot(f0.x - ab.x, f0.y - ab.y) - 100 * Constants.fileSpacing / (2 * .pi)) < 0.01)
    }

    @Test func rootFilesRingAroundOrigin() {
        let l = RadialLayout.compute(FileTree(files: [RepoPath(string: "README.md")]))
        let p = l.position(RepoPath(string: "README.md"))!
        #expect(abs(hypot(p.x, p.y) - Constants.fileRingMinRadius) < 0.01)
    }

    @Test func deterministicAndBounded() {
        let files = (0..<40).map { RepoPath(string: "D\($0 % 5)/S\($0 % 3)/f\($0)") }
        let t = FileTree(files: files)
        let a = RadialLayout.compute(t), b = RadialLayout.compute(t)
        #expect(a == b)
        #expect(a.positions.count == t.nodes.count)
        for p in a.positions.values { #expect(a.bounds.insetBy(dx: -0.01, dy: -0.01).contains(p)) }
        #expect(a.outerRadius >= 2 * Constants.ringSpacing)
    }
}
