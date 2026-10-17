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

    @Test func touchLightsEveryEdgeFromRootToFile() {
        var sim = primed()
        let x = RepoPath(string: "A/deep/x.swift"), deep = RepoPath(string: "A/deep"), dirA = RepoPath(string: "A")
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "A/deep/x.swift"), F.touch(2, "s1", "B/c.swift", kind: .read)]), now: F.t0)
        for p in [x, deep, dirA] {
            #expect(sim.edgeTint(p)?.strength == Constants.tintWrite)
            #expect(sim.edgeTint(p)?.hueIndex == sim.avatars[s1]?.hueIndex)
        }
        #expect(sim.edgeTint(RepoPath(string: "B/c.swift"))?.strength == Constants.tintRead)
        #expect(sim.edgeTint(RepoPath(string: "B"))?.strength == Constants.tintRead)
        #expect(sim.edgeTint(RepoPath([])) == nil)      // the root has no edge above it
        #expect(sim.edgeTint(a) == nil)                 // untouched siblings stay dark
    }

    @Test func sharedEdgeTakesNewestHueKeepsStrongerStrengthAndExpiresWithTheTint() {
        var sim = primed()
        let agents = [F.agent("s1"), F.agent("s2", hue: 3)]
        let dirA = RepoPath(string: "A")
        sim.apply(snapshot: StoreSnapshot(agents: agents, recentTouches: [F.touch(1, "s1", "A/a.swift")]), now: F.t0)
        let later = F.t0.addingTimeInterval(Constants.tintDuration / 4)
        sim.update(dt: 1, now: later)
        // a read of a sibling by another agent recolours the shared edge but keeps the stronger remaining strength
        sim.apply(snapshot: StoreSnapshot(agents: agents, recentTouches: [F.touch(2, "s2", "A/b.swift", kind: .read, at: later)]), now: later)
        #expect(sim.edgeTint(dirA)?.hueIndex == 3)
        #expect(abs(sim.edgeTint(dirA)!.strength - Constants.tintWrite * 0.75) < 0.001)
        #expect(sim.edgeTint(a)?.hueIndex == 0)                       // each file's own edge keeps its own toucher
        #expect(sim.edgeTint(b)?.strength == Constants.tintRead)
        // the shared edge now fades from the newer touch and is dropped with the file tints
        sim.update(dt: 1, now: later.addingTimeInterval(Constants.tintDuration / 2))
        #expect(abs(sim.edgeTint(dirA)!.strength - Constants.tintWrite * 0.75 / 2) < 0.001)
        sim.update(dt: 1, now: later.addingTimeInterval(Constants.tintDuration + 1))
        #expect(sim.edgeTint(dirA) == nil && sim.edgeTints.isEmpty)
    }

    @Test func primingLightsEdgesFromHistoryByAge() {
        var sim = Simulation(tree: F.tree())
        let quarterAgo = F.t0.addingTimeInterval(-Constants.tintDuration / 4)
        let longAgo = F.t0.addingTimeInterval(-Constants.tintDuration - 1)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "B/c.swift", at: longAgo), F.touch(2, "s1", "A/b.swift", at: quarterAgo)]), now: F.t0)
        #expect(sim.edgeTints[RepoPath(string: "B")] == nil)
        #expect(abs(sim.edgeTint(RepoPath(string: "A"))!.strength - Constants.tintWrite * 0.75) < 0.001)
        #expect(abs(sim.edgeTint(b)!.strength - Constants.tintWrite * 0.75) < 0.001)
    }

    @Test func commandSpawnsPulseWithLabelAndNothingOnPriming() {
        var sim = Simulation(tree: F.tree())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentCommands: [F.command(1, "s1", "ls")]), now: F.t0)
        #expect(sim.pulses.isEmpty && sim.lastCommandSeq == 1)                       // history primes silently
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentCommands: [F.command(1, "s1", "ls"), F.command(2, "s1", "swift test", label: "Run tests")]), now: F.t0)
        #expect(sim.pulses.count == 1)
        #expect(sim.pulses[0].agent == s1 && sim.pulses[0].label == "Run tests" && sim.pulses[0].milestone == nil && sim.pulses[0].age == 0)
        #expect(sim.pulses[0].ringProgress == 0 && sim.pulses[0].ringAlpha == 1 && sim.pulses[0].labelAlpha == 1)
        sim.update(dt: Constants.pulseDuration / 2, now: F.t0)
        #expect(abs(sim.pulses[0].ringProgress - 0.5) < 0.01 && abs(sim.pulses[0].ringAlpha - 0.5) < 0.01)
        sim.update(dt: Constants.pulseLabelDuration, now: F.t0)
        #expect(sim.pulses.isEmpty)                                                  // gone once the label has expired
        #expect(sim.lastCommandSeq == 2)
    }

    @Test func commitRipplesLitEdgesDropsTintsToFloorAndBadgesTheOrb() {
        var sim = primed()
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1"), F.agent("s2", hue: 1)], recentTouches: [
            F.touch(1, "s1", "A/a.swift"), F.touch(2, "s2", "B/c.swift", hue: 1)]), now: F.t0)
        let later = F.t0.addingTimeInterval(10)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1"), F.agent("s2", hue: 1)], recentTouches: [
            F.touch(1, "s1", "A/a.swift"), F.touch(2, "s2", "B/c.swift", hue: 1)],
            recentCommands: [F.command(1, "s1", "git commit -m x", at: later)]), now: later)
        #expect(sim.pulses.count == 1 && sim.pulses[0].milestone == .commit(nil))
        #expect(sim.ripples.count == 1 && sim.ripples[0].agent == s1 && sim.ripples[0].maxDepth == 2)
        #expect(sim.tints[a]?.strength == Constants.committedTintFloor && sim.tints[a]?.touchedAt == later)
        #expect(sim.heatValue(a) == Constants.heatWrite)                            // the flash
        #expect(sim.tints[RepoPath(string: "B/c.swift")]?.strength == Constants.tintWrite)   // another agent's files untouched
        #expect(sim.avatars[s1]?.badge == "committed" && sim.avatars[s1]?.badgeLift == nil)
        // The hash arrives later on the same event: the badge updates without a new pulse.
        let info = CommitInfo(hash: "a1b2c3d4", branch: "main", message: "x")
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1"), F.agent("s2", hue: 1)],
            recentCommands: [F.command(1, "s1", "git commit -m x", at: later, commit: info)]), now: later)
        #expect(sim.pulses.count == 1 && sim.avatars[s1]?.badge == "a1b2c3d")
        sim.update(dt: Constants.rippleDuration + 0.1, now: later)
        #expect(sim.ripples.isEmpty)
    }

    @Test func pushLiftsTheBadgeOff() {
        var sim = primed()
        let info = CommitInfo(hash: "a1b2c3d", branch: "main", message: "x")
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentCommands: [F.command(1, "s1", "git commit -m x", commit: info)]), now: F.t0)
        #expect(sim.avatars[s1]?.badge == "a1b2c3d")
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentCommands: [F.command(1, "s1", "git commit -m x", commit: info), F.command(2, "s1", "git push")]), now: F.t0)
        #expect(sim.pulses.last?.milestone == .push)
        #expect(sim.avatars[s1]?.badgeLift == 0 && sim.avatars[s1]?.badgeAlpha == 1 && sim.avatars[s1]?.badgeRise == 0)
        sim.update(dt: Constants.badgeLiftDuration / 2, now: F.t0)
        #expect(abs(sim.avatars[s1]!.badgeAlpha - 0.5) < 0.05 && abs(sim.avatars[s1]!.badgeRise - 0.5) < 0.05)
        sim.update(dt: Constants.badgeLiftDuration, now: F.t0)
        #expect(sim.avatars[s1]?.badge == nil && sim.avatars[s1]?.badgeLift == nil)
        // A push with no badge is just a pulse.
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentCommands: [F.command(3, "s1", "git push")]), now: F.t0)
        #expect(sim.avatars[s1]?.badge == nil && sim.avatars[s1]?.badgeLift == nil)
    }

    @Test func mergeAndRebaseOnlyPulse() {
        var sim = primed()
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "A/a.swift")]), now: F.t0)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentCommands: [F.command(1, "s1", "git merge feat"), F.command(2, "s1", "git rebase main")]), now: F.t0)
        #expect(sim.pulses.map(\.milestone) == [.merge, .rebase])
        #expect(sim.ripples.isEmpty && sim.tints[a]?.strength == Constants.tintWrite && sim.avatars[s1]?.badge == nil)
    }
}
