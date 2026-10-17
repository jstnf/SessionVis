import CoreGraphics
import Foundation
import Testing
@testable import SessionVisCore

@Suite struct SimulationFollowTests {
    typealias F = SimFixtures
    let s1 = AgentID("s1"), s2 = AgentID("s2"), sub = AgentID("A")
    let view = CGSize(width: 800, height: 500)

    func settled(_ agents: [AgentSnapshot], touches: [Touch] = []) -> Simulation {
        var sim = Simulation(tree: F.tree(), viewSize: view)
        sim.apply(snapshot: StoreSnapshot(agents: agents, recentTouches: touches), now: F.t0)
        for i in 1...40 { sim.update(dt: 0.05, now: F.t0.addingTimeInterval(Double(i) * 0.05)) }
        return sim
    }

    @Test func loneMainFramesAtMaxZoomOnTheOrb() {
        let sim = settled([F.agent("s1")])
        let t = sim.followTarget(for: s1)!
        #expect(t.zoom == Constants.followMaxZoom)
        #expect(Geometry.distance(t.center, sim.avatars[s1]!.position) < 0.001)
    }

    @Test func subagentsAndRecentTouchesWidenTheFrame() {
        let sim = settled([F.agent("s1"), F.agent("A", parent: "s1")],
                          touches: [F.touch(1, "s1", "A/a.swift"), F.touch(2, "A", "B/c.swift")])
        let t = sim.followTarget(for: s1)!
        var pts = sim.haloPoints(for: s1)
        pts.append(sim.layout.position(RepoPath(string: "A/a.swift"))!)
        pts.append(sim.layout.position(RepoPath(string: "B/c.swift"))!)
        var box = CGRect(origin: pts[0], size: .zero)
        for p in pts.dropFirst() { box = box.union(CGRect(origin: p, size: .zero)) }
        box = box.insetBy(dx: -Constants.followPadding, dy: -Constants.followPadding)
        #expect(Geometry.distance(t.center, CGPoint(x: box.midX, y: box.midY)) < 0.001)
        let z = min(view.width / (box.width * Simulation.fitMargin), view.height / (box.height * Simulation.fitMargin))
        #expect(abs(t.zoom - min(Constants.followMaxZoom, max(Constants.followMinZoom, z))) < 0.0001)
        #expect(t.zoom < Constants.followMaxZoom)
    }

    @Test func zoomClampsToMinInATinyView() {
        var sim = settled([F.agent("s1")], touches: [F.touch(1, "s1", "A/a.swift"), F.touch(2, "s1", "B/c.swift")])
        sim.setViewSize(CGSize(width: 40, height: 30))
        #expect(sim.followTarget(for: s1)!.zoom == Constants.followMinZoom)
    }

    @Test func followingASubagentFramesItsParentsHalo() {
        let sim = settled([F.agent("s1"), F.agent("A", parent: "s1")], touches: [F.touch(1, "s1", "A/a.swift")])
        let forMain = sim.followTarget(for: s1)!, forSub = sim.followTarget(for: sub)!
        #expect(forMain.zoom == forSub.zoom)
        #expect(Geometry.distance(forMain.center, forSub.center) < 0.001)
    }

    @Test func subagentWithoutParentIsFramedAlone() {
        var sim = settled([F.agent("s1"), F.agent("A", parent: "s1")])
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("A", parent: "s1")]), now: F.t0)
        #expect(sim.avatars[s1] == nil)
        let t = sim.followTarget(for: sub)!
        #expect(t.zoom == Constants.followMaxZoom)
        #expect(Geometry.distance(t.center, sim.avatars[sub]!.position) < 0.001)
    }

    @Test func centreEasesFasterThanZoom() {
        var sim = settled([F.agent("s1")])
        sim.zoom(by: 0.2, around: CGPoint(x: 400, y: 250))
        sim.pan(by: CGSize(width: 300, height: 200))
        sim.setFollow(s1)
        let t = sim.followTarget(for: s1)!
        let c0 = sim.camera.center, z0 = sim.camera.zoom
        sim.update(dt: 0.1, now: F.t0)
        let centreFraction = 1 - Geometry.distance(sim.camera.center, t.center) / Geometry.distance(c0, t.center)
        let zoomFraction = 1 - abs(sim.camera.zoom - t.zoom) / abs(z0 - t.zoom)
        #expect(abs(centreFraction - 0.1 * Constants.followCenterRate) < 0.01)
        #expect(abs(zoomFraction - 0.1 * Constants.followZoomRate) < 0.01)
        #expect(centreFraction > zoomFraction)
    }

    @Test func stopFollowingHoldsTheCamera() {
        var sim = settled([F.agent("s1")])
        sim.setFollow(s1)
        sim.update(dt: 0.1, now: F.t0)
        #expect(!sim.camera.userAdjusted)
        sim.stopFollowing()
        #expect(sim.followedAgent == nil && sim.camera.userAdjusted)
        let c = sim.camera.center, z = sim.camera.zoom
        for i in 1...20 { sim.update(dt: 0.05, now: F.t0.addingTimeInterval(Double(i) * 0.05)) }
        #expect(sim.camera.center == c && sim.camera.zoom == z)
    }

    @Test func stopFollowingWhileNotFollowingChangesNothing() {
        var sim = settled([F.agent("s1")])
        sim.stopFollowing()
        #expect(sim.followedAgent == nil && !sim.camera.userAdjusted)
    }

    @Test func unknownAgentHasNoTarget() {
        let sim = settled([F.agent("s1")])
        #expect(sim.followTarget(for: s2) == nil)
    }

    @Test func resizingWhileFollowingKeepsTheFollowZoom() {
        var sim = settled([F.agent("s1")])
        sim.setFollow(s1)
        for i in 1...200 { sim.update(dt: 0.05, now: F.t0.addingTimeInterval(10 + Double(i) * 0.05)) }
        let target = sim.followTarget(for: s1)!.zoom
        #expect(abs(sim.camera.zoom - target) < 0.01)
        let before = sim.camera.zoom
        sim.setViewSize(CGSize(width: 1400, height: 900))
        #expect(sim.camera.zoom == before)
        sim.update(dt: 0.05, now: F.t0.addingTimeInterval(30))
        #expect(abs(sim.camera.zoom - sim.followTarget(for: s1)!.zoom) < 0.05)
    }

    @Test func followHandsToTheParentWhenTheSubagentIsGone() {
        var sim = settled([F.agent("s1"), F.agent("A", parent: "s1")])
        sim.setFollow(sub)
        let now = F.t0.addingTimeInterval(10)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1"), F.agent("A", parent: "s1", status: .ended)]), now: now)
        var t = now
        for _ in 1...400 { t = t.addingTimeInterval(0.05); sim.update(dt: 0.05, now: t) }
        #expect(sim.avatars[sub] == nil)
        #expect(sim.followedAgent == s1)
    }

    @Test func followHandsToTheParentWhenTheSubagentLeavesTheSnapshot() {
        var sim = settled([F.agent("s1"), F.agent("A", parent: "s1")])
        sim.setFollow(sub)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0.addingTimeInterval(10))
        sim.update(dt: 0.05, now: F.t0.addingTimeInterval(10.05))
        #expect(sim.followedAgent == s1)
    }

    @Test func followClearsWhenTheSubagentAndItsParentAreGone() {
        var sim = settled([F.agent("s1"), F.agent("A", parent: "s1")])
        sim.setFollow(sub)
        sim.apply(snapshot: StoreSnapshot(agents: []), now: F.t0.addingTimeInterval(10))
        sim.update(dt: 0.05, now: F.t0.addingTimeInterval(10.05))
        #expect(sim.followedAgent == nil)
    }

    @Test(arguments: [300, 4000]) func followedOrbStaysOnScreenInABigRepo(perDir: Int) {
        var files: [RepoPath] = []
        for d in ["A", "M", "Z", "Q"] { files += (0..<perDir).map { RepoPath(string: "\(d)/f\($0).swift") } }
        var sim = Simulation(tree: FileTree(files: files), viewSize: view)
        let cluster = (0..<20).map { RepoPath(string: "A/f\($0).swift") }
        let c = Geometry.centroid(cluster.map { sim.layout.position($0)! })
        let far = files.max { Geometry.distance(sim.layout.position($0)!, c) < Geometry.distance(sim.layout.position($1)!, c) }!
        var touches = cluster.enumerated().map { F.touch(UInt64($0.offset + 1), "s1", $0.element.string, at: F.t0) }
        touches.append(F.touch(100, "s1", far.string, at: F.t0))
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: touches), now: F.t0)
        sim.setFollow(s1)
        for i in 1...160 { sim.update(dt: 0.05, now: F.t0.addingTimeInterval(Double(i) * 0.05)) }
        let orb = sim.worldToScreen(sim.avatars[s1]!.position)
        #expect(CGRect(origin: .zero, size: view).contains(orb))
    }

    @Test func rootDirectoryTouchDoesNotWidenTheFrame() {
        let sim = settled([F.agent("s1")], touches: [F.touch(1, "s1", "A/a.swift"), F.touch(2, "s1", "", kind: .read, scope: .directory, source: .shell("ls"))])
        let t = sim.followTarget(for: s1)!
        var pts = sim.haloPoints(for: s1)
        pts.append(sim.layout.position(RepoPath(string: "A/a.swift"))!)
        var box = CGRect(origin: pts[0], size: .zero)
        for p in pts.dropFirst() { box = box.union(CGRect(origin: p, size: .zero)) }
        box = box.insetBy(dx: -Constants.followPadding, dy: -Constants.followPadding)
        let z = min(view.width / (box.width * Simulation.fitMargin), view.height / (box.height * Simulation.fitMargin))
        #expect(abs(t.zoom - min(Constants.followMaxZoom, max(Constants.followMinZoom, z))) < 0.0001)
        #expect(Geometry.distance(t.center, CGPoint(x: box.midX, y: box.midY)) < 0.001)
    }

    /// The subagent's touch lies far from the main, and the frame is compared exactly with the one without that touch.
    @Test func fadedSubagentTouchesLeaveTheFrameExactly() {
        var files: [RepoPath] = []
        for d in ["A", "M", "Z", "Q"] { files += (0..<300).map { RepoPath(string: "\(d)/f\($0).swift") } }
        var sim = Simulation(tree: FileTree(files: files), viewSize: view)
        let touches = [F.touch(1, "s1", "A/f1.swift"), F.touch(2, "A", "Z/f150.swift")]
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1"), F.agent("A", parent: "s1")], recentTouches: touches), now: F.t0)
        var now = F.t0
        for _ in 0..<20 { now = now.addingTimeInterval(0.05); sim.update(dt: 0.05, now: now) }
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1"), F.agent("A", parent: "s1", status: .ended)]), now: now)
        var steps = 0
        while let a = sim.avatars[sub], a.alpha > Constants.haloMinAlpha, steps < 2000 {
            now = now.addingTimeInterval(0.05); sim.update(dt: 0.05, now: now); steps += 1
        }
        #expect(sim.avatars[sub] != nil, "subagent must still linger below the cutoff for this test to mean anything")
        let t = sim.followTarget(for: s1)!
        var pts = sim.haloPoints(for: s1)
        pts.append(sim.layout.position(RepoPath(string: "A/f1.swift"))!)
        var box = CGRect(origin: pts[0], size: .zero)
        for p in pts.dropFirst() { box = box.union(CGRect(origin: p, size: .zero)) }
        box = box.insetBy(dx: -Constants.followPadding, dy: -Constants.followPadding)
        let z = min(view.width / (box.width * Simulation.fitMargin), view.height / (box.height * Simulation.fitMargin))
        let expected = min(Constants.followMaxZoom, max(Constants.followMinZoom, z))
                #expect(abs(t.zoom - expected) < 0.0001)
    }


    /// straddles followMinZoom and count how often the target centre jumps.
    @Test func followCentreIsContinuousAtTheFitBoundary() {
        var files: [RepoPath] = []
        for d in ["A", "M", "Z", "Q"] { files += (0..<1500).map { RepoPath(string: "\(d)/f\($0).swift") } }
        let old = F.t0.addingTimeInterval(-Constants.touchCentroidWindow - 1)
        func make(view: CGSize) -> Simulation {
            var sim = Simulation(tree: FileTree(files: files), viewSize: view)
            sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1"), F.agent("A", parent: "s1")],
                                              recentTouches: [F.touch(1, "A", "Z/f700.swift", at: old)]), now: F.t0)
            return sim
        }
        // measure the halo box over time with a huge view
        var probe = make(view: CGSize(width: 1e6, height: 1e6))
        var now = F.t0
        var widths: [CGFloat] = []
        for i in 0..<600 {
            now = now.addingTimeInterval(0.05); probe.update(dt: 0.05, now: now)
            if i > 200 {
                let pts = probe.haloPoints(for: s1)
                var b = CGRect(origin: pts[0], size: .zero); for p in pts.dropFirst() { b = b.union(CGRect(origin: p, size: .zero)) }
                widths.append(max(b.width, b.height) + 2 * Constants.followPadding)
            }
        }
        let mid = (widths.min()! + widths.max()!) / 2
        let side = Constants.followMinZoom * Simulation.fitMargin * mid
        var sim = make(view: CGSize(width: side, height: side))
        sim.setFollow(s1)
        now = F.t0
        var flips = 0, lastOnOrb: Bool? = nil, maxJump: CGFloat = 0, prev: CGPoint? = nil
        for frame in 0..<1200 {
            now = now.addingTimeInterval(0.05); sim.update(dt: 0.05, now: now)
            let t = sim.followTarget(for: s1)!
            let onOrb = Geometry.distance(t.center, sim.avatars[s1]!.position) < 0.001
            if let l = lastOnOrb, l != onOrb { flips += 1 }
            lastOnOrb = onOrb
            if frame > 200, let p = prev { maxJump = max(maxJump, Geometry.distance(p, t.center)) }
            prev = t.center
        }
        #expect(flips <= 1)
        #expect(maxJump < 100)
    }
}
