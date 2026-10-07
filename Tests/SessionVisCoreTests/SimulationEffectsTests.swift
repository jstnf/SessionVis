import CoreGraphics
import Foundation
import Testing
@testable import SessionVisCore

@Suite struct SimulationEffectsTests {
    typealias F = SimFixtures
    let s1 = AgentID("s1")
    let a = RepoPath(string: "A/a.swift"), b = RepoPath(string: "A/b.swift")

    func primed() -> Simulation {
        var sim = Simulation(tree: F.tree())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1"), F.agent("A", parent: "s1")]), now: F.t0)
        return sim
    }

    @Test func primingPassHeatsRecentHistoryWithoutBeams() {
        var sim = Simulation(tree: F.tree())
        let old = F.t0.addingTimeInterval(-Constants.touchCentroidWindow - 1)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "A/a.swift", at: old), F.touch(2, "s1", "A/b.swift", at: F.t0)]), now: F.t0)
        #expect(sim.beams.isEmpty && sim.particles.isEmpty)
        #expect(sim.heatValue(a) == 0)
        #expect(sim.heatValue(b) == Constants.heatWrite)
        #expect(sim.lastTouchSeq == 2)
    }

    @Test func writeTouchFiresBeamHeatAndParticlesReadIsFaint() {
        var sim = primed()
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "A/a.swift"), F.touch(2, "s1", "A/b.swift", kind: .read)]), now: F.t0)
        #expect(sim.beams.count == 2)
        #expect(sim.beams[0].from == s1 && sim.beams[0].to == a && sim.beams[0].kind == .write && sim.beams[0].age == 0)
        #expect(sim.heatValue(a) == Constants.heatWrite && sim.heatValue(b) == Constants.heatRead)
        #expect(sim.particles.count == Constants.particlesPerWrite)
        #expect(sim.touchedPaths == [a, b])
        #expect(sim.tints[a]?.toucher == s1)
        // same snapshot again: nothing new fires
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "A/a.swift"), F.touch(2, "s1", "A/b.swift", kind: .read)]), now: F.t0)
        #expect(sim.beams.count == 2 && sim.particles.count == Constants.particlesPerWrite)
    }

    @Test func effectsAgeAndExpire() {
        var sim = primed()
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "A/a.swift")]), now: F.t0)
        let p0 = sim.particles[0]
        sim.update(dt: 0.35, now: F.t0)
        #expect(abs(sim.beams[0].alpha - 0.5) < 0.01)
        #expect(sim.beams[0].dotProgress == 1)              // dot arrives in the first 45% of life
        #expect(abs(sim.heatValue(a) - (1 - 0.35 / 3)) < 0.001)
        #expect(sim.particles[0].position != p0.position)
        #expect(abs(sim.particles[0].life - 0.65) < 0.001)
        sim.update(dt: 0.4, now: F.t0)
        #expect(sim.beams.isEmpty)
        sim.update(dt: 0.3, now: F.t0)
        #expect(sim.particles.isEmpty)
        sim.update(dt: 3, now: F.t0)
        #expect(sim.heatValue(a) == 0 && sim.heat[a] == nil)
    }

    @Test func heatKeepsTheMaximumAndLatestToucher() {
        var sim = primed()
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1"), F.agent("A", parent: "s1")], recentTouches: [F.touch(1, "s1", "A/a.swift")]), now: F.t0)
        sim.update(dt: 1, now: F.t0)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1"), F.agent("A", parent: "s1")], recentTouches: [F.touch(2, "A", "A/a.swift", kind: .read)]), now: F.t0)
        #expect(abs(sim.heatValue(a) - (1 - 1.0 / 3)) < 0.001)   // read (0.35) does not lower existing heat
        #expect(sim.tints[a]?.toucher == AgentID("A"))
    }

    @Test func particlesAreDeterministic() {
        var s1sim = primed(), s2sim = primed()
        let snap = StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(7, "s1", "A/a.swift")])
        s1sim.apply(snapshot: snap, now: F.t0); s2sim.apply(snapshot: snap, now: F.t0)
        #expect(s1sim.particles == s2sim.particles)
        for p in s1sim.particles {
            let speed = hypot(p.velocity.x, p.velocity.y)
            #expect(speed >= 12 - 0.001 && speed <= 32 + 0.001)
        }
    }

    @Test func haloPointsIncludeVisibleSubagentsOnly() {
        var sim = primed()
        sim.update(dt: 1, now: F.t0)
        #expect(sim.haloPoints(for: s1).count == 2)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1"), F.agent("A", parent: "s1", status: .ended)]), now: F.t0)
        sim.update(dt: 2.95, now: F.t0)   // alpha ≈ 0.017 < 0.03
        #expect(sim.haloPoints(for: s1).count == 1)
        #expect(sim.haloPoints(for: AgentID("A")).isEmpty)
        #expect(sim.haloPoints(for: AgentID("nope")).isEmpty)
    }

    @Test func touchTintsFileAndTintFadesOverTintDuration() {
        var sim = primed()
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "A/a.swift"), F.touch(2, "s1", "A/b.swift", kind: .read)]), now: F.t0)
        #expect(sim.tintStrength(a) == Constants.tintWrite)
        #expect(sim.tintStrength(b) == Constants.tintRead)
        #expect(sim.tint(a)?.hueIndex == sim.avatars[s1]?.hueIndex)
        #expect(sim.tints[a]?.toucher == s1)
        sim.update(dt: 1, now: F.t0.addingTimeInterval(Constants.tintDuration / 2))
        #expect(abs(sim.tintStrength(a) - Constants.tintWrite / 2) < 0.001)
        #expect(abs(sim.tintStrength(b) - Constants.tintRead / 2) < 0.001)
        sim.update(dt: 1, now: F.t0.addingTimeInterval(Constants.tintDuration + 1))
        #expect(sim.tintStrength(a) == 0 && sim.tint(a) == nil && sim.tints.isEmpty)
    }

    @Test func primingTintsHistoryByAgeAndNewerTouchRecoloursWithoutWeakening() {
        var sim = Simulation(tree: F.tree())
        let quarterAgo = F.t0.addingTimeInterval(-Constants.tintDuration / 4)
        let longAgo = F.t0.addingTimeInterval(-Constants.tintDuration - 1)
        let agents = [F.agent("s1"), F.agent("s2", hue: 3)]
        sim.apply(snapshot: StoreSnapshot(agents: agents, recentTouches: [F.touch(1, "s1", "A/a.swift", at: longAgo), F.touch(2, "s1", "A/b.swift", at: quarterAgo)]), now: F.t0)
        #expect(sim.tintStrength(a) == 0)
        #expect(abs(sim.tintStrength(b) - Constants.tintWrite * 0.75) < 0.001)
        #expect(sim.beams.isEmpty)
        // a read by another agent recolours the file but keeps the stronger remaining tint
        sim.apply(snapshot: StoreSnapshot(agents: agents, recentTouches: [F.touch(3, "s2", "A/b.swift", kind: .read)]), now: F.t0)
        #expect(sim.tint(b)?.hueIndex == 3 && sim.tints[b]?.toucher == AgentID("s2"))
        #expect(abs(sim.tintStrength(b) - Constants.tintWrite * 0.75) < 0.001)
        // an older history touch never overrides a newer one
        sim.apply(snapshot: StoreSnapshot(agents: agents, recentTouches: [F.touch(4, "s1", "A/b.swift", at: longAgo)]), now: F.t0)
        #expect(sim.tint(b)?.hueIndex == 3)
    }

    @Test func touchByAgentMissingFromSnapshotKeepsItsOwnHueAndTitle() {
        var sim = Simulation(tree: F.tree())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "gone", "A/a.swift", hue: 5, title: "Old session")]), now: F.t0)
        #expect(sim.tint(a)?.hueIndex == 5)
        #expect(sim.tints[a]?.toucherTitle == "Old session")
        #expect(sim.avatars[AgentID("gone")] == nil)
    }
}
