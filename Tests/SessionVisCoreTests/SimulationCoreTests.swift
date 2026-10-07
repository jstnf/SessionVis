import CoreGraphics
import Foundation
import Testing
@testable import SessionVisCore

enum SimFixtures {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static func tree() -> FileTree { FileTree(files: ["A/a.swift", "A/b.swift", "B/c.swift"].map(RepoPath.init(string:))) }
    static func agent(_ id: String, parent: String? = nil, status: Status = .working, hue: Int = 0) -> AgentSnapshot {
        let kind: AgentKind = parent.map { .subagent(parent: AgentID($0), description: "sub \(id)", agentType: nil, model: nil) } ?? .main
        return AgentSnapshot(id: AgentID(id), kind: kind, title: id, status: status, hueIndex: hue, branch: nil, worktree: nil,
                             firstSeen: t0, lastActivity: t0, endedAt: nil, touchCount: 0)
    }
    static func touch(_ seq: UInt64, _ agent: String, _ path: String, kind: TouchKind = .write, at: Date = t0, hue: Int = 0, title: String? = nil) -> Touch {
        Touch(seq: seq, agent: AgentID(agent), path: RepoPath(string: path), worktree: nil, kind: kind, at: at, hueIndex: hue, agentTitle: title)
    }
}

@Suite struct SimulationCoreTests {
    typealias F = SimFixtures
    let s1 = AgentID("s1")

    @Test func mainSpawnsOnOuterCircleDeterministicallyAndScalesIn() {
        var sim = Simulation(tree: F.tree())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        let av = sim.avatars[s1]!
        #expect(abs(Geometry.distance(av.position, .zero) - (sim.layout.outerRadius + 120)) < 0.01)
        #expect(av.scale == 0)
        var sim2 = Simulation(tree: F.tree())
        sim2.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        #expect(sim2.avatars[s1]!.position == av.position)
        sim.update(dt: 0.15, now: F.t0)
        #expect(abs(sim.avatars[s1]!.scale - 0.5) < 0.01)
        sim.update(dt: 0.5, now: F.t0)
        #expect(sim.avatars[s1]!.scale == 1)
    }

    @Test func subagentIsBornAtParentAndIdlesBesideIt() {
        var sim = Simulation(tree: F.tree())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        sim.update(dt: 1, now: F.t0)
        let parentPos = sim.avatars[s1]!.position
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1"), F.agent("A", parent: "s1")]), now: F.t0)
        #expect(sim.avatars[AgentID("A")]!.position == parentPos)
        sim.update(dt: 0.016, now: F.t0)
        let a = sim.avatars[AgentID("A")]!
        #expect(abs(Geometry.distance(a.target, sim.avatars[s1]!.position) - 30) < 0.5)
    }

    @Test func mainTargetsTouchCentroidPushedOutward() {
        var sim = Simulation(tree: F.tree())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "A/a.swift"), F.touch(2, "s1", "A/b.swift")]), now: F.t0)
        sim.update(dt: 0.016, now: F.t0)
        let c = Geometry.centroid([sim.position(of: RepoPath(string: "A/a.swift"))!, sim.position(of: RepoPath(string: "A/b.swift"))!])
        let expected = Geometry.towards(c, CGPoint(x: c.x * 2, y: c.y * 2), by: 60)
        #expect(Geometry.distance(sim.avatars[s1]!.target, expected) < 0.01)
        #expect(sim.lastTouchSeq == 2)
    }

    @Test func idleMainDriftsAroundAnchorAndOldTouchesExpire() {
        var sim = Simulation(tree: F.tree())
        let old = F.t0.addingTimeInterval(-Constants.touchCentroidWindow - 1)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "A/a.swift", at: old)]), now: F.t0)
        sim.update(dt: 0.5, now: F.t0)
        let av = sim.avatars[s1]!
        #expect(Geometry.distance(av.target, av.anchor) <= 15 * 1.5)
        #expect(av.target != av.anchor)
    }

    @Test func subagentTargetsItsFileOffsetTowardParent() {
        var sim = Simulation(tree: F.tree())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1"), F.agent("A", parent: "s1")]), now: F.t0)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1"), F.agent("A", parent: "s1")], recentTouches: [F.touch(1, "A", "B/c.swift")]), now: F.t0)
        sim.update(dt: 0.016, now: F.t0)
        let file = sim.position(of: RepoPath(string: "B/c.swift"))!
        let a = sim.avatars[AgentID("A")]!
        #expect(abs(Geometry.distance(a.target, file) - 26) < 0.01)
        #expect(a.lastTouchPath == RepoPath(string: "B/c.swift"))
    }

    @Test func motionEasesTowardTarget() {
        var sim = Simulation(tree: F.tree())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "A/a.swift")]), now: F.t0)
        let start = sim.avatars[s1]!.position
        sim.update(dt: 0.1, now: F.t0)
        let after = sim.avatars[s1]!
        let expected = Geometry.lerp(start, after.target, 0.2)
        #expect(Geometry.distance(after.position, expected) < 0.01)
    }

    @Test func endedFadesTowardParentAndIsRemovedAbsentAgentsVanish() {
        var sim = Simulation(tree: F.tree())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1"), F.agent("A", parent: "s1")]), now: F.t0)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1"), F.agent("A", parent: "s1", status: .ended)]), now: F.t0)
        sim.update(dt: 1.5, now: F.t0)
        let a = sim.avatars[AgentID("A")]!
        #expect(abs(a.alpha - 0.5) < 0.01)
        #expect(a.target == sim.avatars[s1]!.position)
        sim.update(dt: 1.6, now: F.t0)
        #expect(sim.avatars[AgentID("A")] == nil && sim.avatarOrder == [s1])
        sim.apply(snapshot: StoreSnapshot(agents: []), now: F.t0)
        #expect(sim.avatars.isEmpty && sim.avatarOrder.isEmpty)
    }

    @Test func waitingAvatarPulses() {
        var sim = Simulation(tree: F.tree())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1", status: .waiting(preview: "?"))]), now: F.t0)
        sim.update(dt: 1, now: F.t0)
        for _ in 0..<10 {
            sim.update(dt: 0.07, now: F.t0)
            let r = sim.avatars[s1]!.renderScale
            #expect(r >= 1 && r <= 1.15 + 0.0001)
        }
    }

    @Test func cameraFitsBoundsAndResizes() {
        var sim = Simulation(tree: F.tree(), viewSize: CGSize(width: 800, height: 500))
        let b = sim.fitBounds()
        #expect(abs(sim.camera.zoom - min(800 / (b.width * 1.1), 500 / (b.height * 1.1))) < 0.0001)
        #expect(sim.camera.center == CGPoint(x: b.midX, y: b.midY))
        sim.setViewSize(CGSize(width: 1600, height: 500))
        #expect(abs(sim.camera.zoom - min(1600 / (b.width * 1.1), 500 / (b.height * 1.1))) < 0.0001)
    }

    @Test func cameraFitIncludesAvatars() {
        var sim = Simulation(tree: F.tree(), viewSize: CGSize(width: 800, height: 500))
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        for i in 1...60 { sim.update(dt: 0.05, now: F.t0.addingTimeInterval(Double(i) * 0.05)) }
        let p = sim.worldToScreen(sim.avatars[s1]!.position)
        #expect(CGRect(origin: .zero, size: CGSize(width: 800, height: 500)).contains(p))
    }

    @Test func userAdjustedCameraDoesNotAutoFit() {
        var sim = Simulation(tree: F.tree(), viewSize: CGSize(width: 800, height: 500))
        sim.pan(by: CGSize(width: 30, height: 10))
        let c = sim.camera.center, z = sim.camera.zoom
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        for i in 1...60 { sim.update(dt: 0.05, now: F.t0.addingTimeInterval(Double(i) * 0.05)) }
        #expect(sim.camera.center == c && sim.camera.zoom == z)
    }

    @Test func zoomKeepsCursorPointFixedAndPanMoves() {
        var sim = Simulation(tree: F.tree())
        let cursor = CGPoint(x: 100, y: 80)
        let before = sim.screenToWorld(cursor)
        sim.zoom(by: 2, around: cursor)
        #expect(Geometry.distance(sim.screenToWorld(cursor), before) < 0.001)
        #expect(sim.camera.userAdjusted)
        sim.setFollow(s1)
        let c0 = sim.camera.center
        sim.pan(by: CGSize(width: 10, height: -20))
        #expect(abs(sim.camera.center.x - (c0.x - 10 / sim.camera.zoom)) < 0.0001)
        #expect(abs(sim.camera.center.y - (c0.y + 20 / sim.camera.zoom)) < 0.0001)
        #expect(sim.followedAgent == nil)
        sim.zoom(by: 1000, around: cursor)
        #expect(sim.camera.zoom == Camera.maxZoom)
        sim.resetCamera()
        #expect(!sim.camera.userAdjusted && sim.camera.center == CGPoint(x: sim.layout.bounds.midX, y: sim.layout.bounds.midY))
    }

    @Test func followEasesCenterTowardAvatar() {
        var sim = Simulation(tree: F.tree())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        sim.setFollow(s1)
        let c0 = sim.camera.center, target = sim.avatars[s1]!.position
        sim.update(dt: 0.1, now: F.t0)
        let d0 = Geometry.distance(c0, target), d1 = Geometry.distance(sim.camera.center, target)
        #expect(d1 < d0 && d1 > 0)
    }

    @Test func followClearsWhenAvatarVanishes() {
        var sim = Simulation(tree: F.tree())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        sim.setFollow(s1)
        sim.apply(snapshot: StoreSnapshot(agents: []), now: F.t0)
        sim.update(dt: 0.1, now: F.t0)
        #expect(sim.followedAgent == nil)
    }

    @Test func alphaRestoresWhenStatusLeavesEnded() {
        var sim = Simulation(tree: F.tree())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1", status: .ended)]), now: F.t0)
        sim.update(dt: 1, now: F.t0)
        #expect(sim.avatars[s1]!.alpha < 1)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1", status: .working)]), now: F.t0)
        sim.update(dt: 0.01, now: F.t0)
        #expect(sim.avatars[s1]!.alpha == 1)
    }

    @Test func hitTestPrefersAvatarsThenNodes() {
        var sim = Simulation(tree: F.tree())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        sim.update(dt: 1, now: F.t0)
        let avatarScreen = sim.worldToScreen(sim.avatars[s1]!.position)
        #expect(sim.hitTest(screen: CGPoint(x: avatarScreen.x + 5, y: avatarScreen.y)) == .avatar(s1))
        let nodeScreen = sim.worldToScreen(sim.position(of: RepoPath(string: "A/a.swift"))!)
        #expect(sim.hitTest(screen: CGPoint(x: nodeScreen.x + 3, y: nodeScreen.y)) == .node(RepoPath(string: "A/a.swift")))
        #expect(sim.hitTest(screen: CGPoint(x: -500, y: -500)) == nil)
    }

    @Test func unknownTouchPathIsInsertedAndLaidOut() {
        var sim = Simulation(tree: F.tree())
        #expect(sim.position(of: RepoPath(string: "New/file.swift")) == nil)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "New/file.swift")]), now: F.t0)
        #expect(sim.position(of: RepoPath(string: "New/file.swift")) != nil)
        #expect(sim.tree.fileCount == 4)
    }

    @Test func endedAgentNeverRespawnsAfterRemoval() {
        var sim = Simulation(tree: F.tree())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1"), F.agent("A", parent: "s1")]), now: F.t0)
        let ended = StoreSnapshot(agents: [F.agent("s1"), F.agent("A", parent: "s1", status: .ended)])
        sim.apply(snapshot: ended, now: F.t0)
        sim.update(dt: Constants.endedLinger + 0.1, now: F.t0)
        #expect(sim.avatars[AgentID("A")] == nil)
        sim.apply(snapshot: ended, now: F.t0)
        #expect(sim.avatars[AgentID("A")] == nil && !sim.avatarOrder.contains(AgentID("A")))

        var fresh = Simulation(tree: F.tree())
        fresh.apply(snapshot: StoreSnapshot(agents: [F.agent("s1", status: .ended)]), now: F.t0)
        #expect(fresh.avatars.isEmpty && fresh.avatarOrder.isEmpty)
    }
}
