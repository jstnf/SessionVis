import CoreGraphics
import Foundation
import Testing
@testable import SessionVisCore

@Suite struct SimulationCatchUpTests {
    typealias F = SimFixtures
    let a = RepoPath(string: "A/a.swift")

    /// A primed scene with one fresh write: a beam, particles, heat and a tint on `A/a.swift`.
    func withEffects() -> Simulation {
        var sim = Simulation(tree: F.tree())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "A/a.swift")]), now: F.t0)
        return sim
    }

    @Test func catchUpExpiresEffectsAndKeepsTints() {
        var sim = withEffects()
        #expect(!sim.beams.isEmpty && !sim.particles.isEmpty && sim.heatValue(a) > 0)
        sim.catchUp(hiddenFor: 60, now: F.t0.addingTimeInterval(60))
        #expect(sim.beams.isEmpty && sim.particles.isEmpty && sim.pulses.isEmpty && sim.ripples.isEmpty)
        #expect(sim.heatValue(a) == 0)
        #expect(sim.tints[a] != nil && sim.edgeTints[RepoPath(string: "A")] != nil)
        #expect(abs(sim.time - Constants.catchUpMaxDuration) < 1e-6)
    }

    @Test func zeroOrNegativeHiddenTimeChangesNothing() {
        var sim = withEffects()
        let beams = sim.beams.count, particles = sim.particles.count, time = sim.time
        sim.catchUp(hiddenFor: 0, now: F.t0)
        sim.catchUp(hiddenFor: -1, now: F.t0)
        #expect(sim.beams.count == beams && sim.particles.count == particles && sim.time == time)
    }

    @Test func shortAbsencesAdvanceOnlyThatLong() {
        var sim = withEffects()
        sim.catchUp(hiddenFor: 0.25, now: F.t0.addingTimeInterval(0.25))
        #expect(abs(sim.time - 0.25) < 1e-6)
        #expect(!sim.beams.isEmpty)   // beams outlive a quarter second
    }

    @Test func aTabHiddenSinceLaunchRevealsWithoutAFreshBurst() {
        typealias F = SimFixtures
        var sim = Simulation(tree: F.tree())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        var touches: [Touch] = []
        for i in 1...40 {
            touches.append(F.touch(UInt64(i), "s1", "A/a.swift"))
            sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: touches), now: F.t0.addingTimeInterval(Double(i) * 30))
        }
        sim.catchUp(hiddenFor: 1200, now: F.t0.addingTimeInterval(1200))
        sim.update(dt: 0, now: F.t0.addingTimeInterval(1200))
        #expect(sim.beams.isEmpty)
    }
}
