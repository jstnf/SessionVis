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

    @Test func withoutAnActiveSetTheLayoutIsUnchanged() {
        let files = (0..<40).map { RepoPath(string: "D\($0 % 5)/S\($0 % 3)/f\($0)") }
        let t = FileTree(files: files)
        #expect(RadialLayout.compute(t, active: nil).positions == RadialLayout.compute(t).positions)
        // The plain ring maths, pinned: one directory of 40 files is the root's lone subdirectory, so its sector midpoint is π.
        let ring = FileTree(files: (0..<40).map { RepoPath(string: "A/f\($0)") })
        let plain = RadialLayout.compute(ring)
        let center = plain.position(RepoPath(string: "A"))!
        let r = max(Constants.fileRingMinRadius, CGFloat(40) * Constants.fileSpacing / (2 * .pi))
        for (i, f) in ring.files(in: RepoPath(string: "A")).enumerated() {
            let a = CGFloat.pi + .pi + 2 * .pi * CGFloat(i) / CGFloat(40)
            #expect(plain.position(f) == CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a)))
        }
        #expect(RadialLayout.compute(ring, active: nil) == plain)
        let big = FileTree(files: (0..<100).map { RepoPath(string: "A/f\($0)") })
        #expect(RadialLayout.compute(big, active: []) != RadialLayout.compute(big))   // an empty set packs a ring that was above its minimum
    }

    @Test func activeFilesWidenTheirDirectorySector() {
        // A and B hold 4 files each; two of A's are active → A weighs 2 + 4ε, B weighs 4ε.
        let tree = FileTree(files: ["A/1", "A/2", "A/3", "A/4", "B/1", "B/2", "B/3", "B/4"].map(RepoPath.init(string:)))
        let l = RadialLayout.compute(tree, active: [RepoPath(string: "A/1"), RepoPath(string: "A/2")])
        let e = Constants.focusInactiveWeight
        let wa = 2 + 4 * e, wb = 4 * e
        let r = Constants.ringSpacing
        let floor = 2 * asin(Constants.focusMinSiblingSpacing / (2 * r))   // each sibling's guaranteed angle; the rest is shared by weight
        let widthA = floor + (2 * CGFloat.pi - 2 * floor) * wa / (wa + wb), widthB = floor + (2 * CGFloat.pi - 2 * floor) * wb / (wa + wb)
        let midA = widthA / 2                                                   // A's sector starts at 0
        let midB = widthA + widthB / 2
        #expect(near(l.position(RepoPath(string: "A"))!, CGPoint(x: r * cos(midA), y: r * sin(midA))))
        #expect(near(l.position(RepoPath(string: "B"))!, CGPoint(x: r * cos(midB), y: r * sin(midB))))
    }

    @Test func inactiveFilesPackTheRingAndActiveOnesKeepTheirSpacing() {
        let big = FileTree(files: (0..<400).map { RepoPath(string: "A/f\($0)") })
        let a = RepoPath(string: "A")
        let packed = RadialLayout.compute(big, active: [])
        let pa = packed.position(a)!, pf = packed.position(RepoPath(string: "A/f0"))!
        #expect(abs(hypot(pf.x - pa.x, pf.y - pa.y) - 400 * Constants.focusInactiveSpacing / (2 * .pi)) < 0.01)
        #expect(packed.position(RepoPath([])) == .zero)

        let mixed = RadialLayout.compute(big, active: [RepoPath(string: "A/f0"), RepoPath(string: "A/f1")])
        let total = 2 * Constants.fileSpacing + 398 * Constants.focusInactiveSpacing
        let ma = mixed.position(a)!, m0 = mixed.position(RepoPath(string: "A/f0"))!
        #expect(abs(hypot(m0.x - ma.x, m0.y - ma.y) - total / (2 * .pi)) < 0.01)
        func gap(_ x: String, _ y: String) -> CGFloat {
            let p = mixed.position(RepoPath(string: x))!, q = mixed.position(RepoPath(string: y))!
            return hypot(p.x - q.x, p.y - q.y)
        }
        // Files ring in name order (f0, f1, f10, f100, …): a full step follows each active file, a short one each inactive file.
        #expect(abs(gap("A/f0", "A/f1") - Constants.fileSpacing) < 0.05)
        #expect(abs(gap("A/f1", "A/f10") - Constants.fileSpacing) < 0.05)
        #expect(abs(gap("A/f10", "A/f100") - Constants.focusInactiveSpacing) < 0.05)
    }

    @Test func weightsCountActiveFilesUpEveryAncestorAndIgnoreOtherPaths() {
        let tree = FileTree(files: ["A/B/x", "A/B/y", "A/z", "C/w"].map(RepoPath.init(string:)))
        let w = LayoutWeights(tree: tree, active: [RepoPath(string: "A/B/x"), RepoPath(string: "A/z"), RepoPath(string: "A/B"), RepoPath(string: "gone")])
        #expect(w.activeCount[RepoPath(string: "A/B")] == 1 && w.activeCount[RepoPath(string: "A")] == 2)
        #expect(w.activeCount[RepoPath([])] == 2 && w.activeCount[RepoPath(string: "C")] == nil)
        let e = Constants.focusInactiveWeight
        #expect(abs(w.sectorWeight(of: RepoPath(string: "A"), in: tree) - (2 + 3 * e)) < 1e-9)
        #expect(abs(w.sectorWeight(of: RepoPath(string: "C"), in: tree) - e) < 1e-9)
        #expect(w.spacing(for: RepoPath(string: "A/z")) == Constants.fileSpacing)
        #expect(w.spacing(for: RepoPath(string: "C/w")) == Constants.focusInactiveSpacing)
    }

    @Test func idleSiblingDirectoriesKeepAMinimumSpacing() {
        var paths = (0..<40).map { RepoPath(string: "Hot/h\($0).swift") }
        for d in 0..<30 { for f in 0..<3 { paths.append(RepoPath(string: "Idle\(d)/f\(f).swift")) } }
        let tree = FileTree(files: paths)
        let active = Set((0..<40).map { RepoPath(string: "Hot/h\($0).swift") })
        let l = RadialLayout.compute(tree, active: active)
        let centres = (0..<30).map { l.position(RepoPath(string: "Idle\($0)"))! }
        for p in l.positions.values { #expect(p.x.isFinite && p.y.isFinite) }
        for i in 0..<centres.count { for j in (i + 1)..<centres.count {
            #expect(Geometry.distance(centres[i], centres[j]) >= Constants.focusMinSiblingSpacing - 1e-6)
        } }
    }

    @Test func floorsLargerThanTheSectorScaleDownWithoutNaN() {
        let tree = FileTree(files: (0..<400).map { RepoPath(string: "D\($0)/f.swift") })
        let l = RadialLayout.compute(tree, active: [RepoPath(string: "D0/f.swift")])
        for p in l.positions.values { #expect(p.x.isFinite && p.y.isFinite) }
    }
}
