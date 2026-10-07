import CoreGraphics
import Foundation
import Testing
@testable import SessionVisCore

@Suite struct SimulationDeltaTests {
    typealias F = SimFixtures
    let a = RepoPath(string: "A/a.swift"), b = RepoPath(string: "A/b.swift"), c = RepoPath(string: "B/c.swift")

    @Test func removedFileDiesThenLeavesTheTree() {
        var sim = Simulation(tree: F.tree())
        sim.apply(delta: TreeDelta(removed: [a]), now: F.t0)
        #expect(sim.deathAlpha(a) == 1 && sim.tree.node(a) != nil)
        sim.update(dt: 0.5, now: F.t0)
        #expect(abs(sim.deathAlpha(a)! - 0.5) < 0.01)
        sim.update(dt: 0.6, now: F.t0)
        #expect(sim.deathAlpha(a) == nil && sim.tree.node(a) == nil && sim.position(of: a) == nil)
        #expect(sim.tree.fileCount == 2)
    }

    @Test func addedFileIsBornAtItsDirectoryAndScalesIn() {
        var sim = Simulation(tree: F.tree())
        let dirPos = sim.position(of: RepoPath(string: "A"))!
        let n = RepoPath(string: "A/new.swift")
        sim.apply(delta: TreeDelta(added: [n]), now: F.t0)
        #expect(sim.tree.node(n) != nil)
        #expect(Geometry.distance(sim.position(of: n)!, dirPos) < 0.01)      // starts at the directory
        #expect(sim.birthScale(n) == 0)
        sim.update(dt: 0.2, now: F.t0)
        #expect(abs(sim.birthScale(n) - 0.5) < 0.01)
        sim.update(dt: 0.3, now: F.t0)
        #expect(sim.birthScale(n) == 1)
        #expect(Geometry.distance(sim.position(of: n)!, sim.layout.position(n)!) < Geometry.distance(dirPos, sim.layout.position(n)!))   // gliding toward its place
    }

    @Test func movedFileGlidesFromOldPosition() {
        var sim = Simulation(tree: F.tree())
        let oldPos = sim.position(of: a)!
        let dest = RepoPath(string: "B/a.swift")
        sim.apply(delta: TreeDelta(moved: [TreeDelta.Move(from: a, to: dest)]), now: F.t0)
        #expect(sim.deathAlpha(a) == nil && sim.tree.node(a) == nil)           // moves do not die red
        #expect(Geometry.distance(sim.position(of: dest)!, oldPos) < 0.01)
        sim.update(dt: 0.1, now: F.t0)
        #expect(Geometry.distance(sim.position(of: dest)!, oldPos) > 0.01)
    }

    @Test func renderPositionsEaseTowardNewLayout() {
        var sim = Simulation(tree: F.tree())
        let before = sim.position(of: c)!
        sim.apply(delta: TreeDelta(added: (0..<10).map { RepoPath(string: "A/f\($0).swift") }), now: F.t0)   // A's sector grows, B shifts
        let target = sim.layout.position(c)!
        #expect(target != before)
        #expect(Geometry.distance(sim.position(of: c)!, before) < 0.01)      // not jumped yet
        for _ in 0..<90 { sim.update(dt: 1.0 / 60, now: F.t0) }
        #expect(Geometry.distance(sim.position(of: c)!, target) < 1.0)
    }

    @Test func removalDropsHeatAndTouches() {
        var sim = Simulation(tree: F.tree())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "A/a.swift")]), now: F.t0)
        #expect(sim.heatValue(a) > 0)
        sim.apply(delta: TreeDelta(removed: [a]), now: F.t0)
        sim.update(dt: 1.1, now: F.t0)
        #expect(sim.heatValue(a) == 0 && !sim.touchedPaths.contains(a))
    }

    @Test func recreatedDyingFileIsRevived() {
        var sim = Simulation(tree: F.tree())
        sim.apply(delta: TreeDelta(removed: [a]), now: F.t0)
        sim.update(dt: 0.5, now: F.t0)
        sim.apply(delta: TreeDelta(added: [a]), now: F.t0)
        #expect(sim.deathAlpha(a) == nil && sim.tree.node(a) != nil)
        sim.update(dt: 1.1, now: F.t0)
        #expect(sim.tree.node(a) != nil && sim.position(of: a) != nil)
    }

    @Test func moveOntoDyingPathRevivesIt() {
        var sim = Simulation(tree: F.tree())
        sim.apply(delta: TreeDelta(removed: [a]), now: F.t0)
        sim.update(dt: 0.3, now: F.t0)
        sim.apply(delta: TreeDelta(moved: [TreeDelta.Move(from: c, to: a)]), now: F.t0)
        #expect(sim.deathAlpha(a) == nil && sim.tree.node(a) != nil && sim.tree.node(c) == nil)
        sim.update(dt: 1.1, now: F.t0)
        #expect(sim.tree.node(a) != nil)
    }

    @Test func touchOnDyingFileRevivesIt() {
        var sim = Simulation(tree: F.tree())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        sim.apply(delta: TreeDelta(removed: [a]), now: F.t0)
        sim.update(dt: 0.3, now: F.t0)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "A/a.swift")]), now: F.t0)
        #expect(sim.deathAlpha(a) == nil)
        sim.update(dt: 1.1, now: F.t0)
        #expect(sim.tree.node(a) != nil)
    }

    @Test func newDirectoryAndFileStartAtTheirAncestor() {
        for _ in 0..<10 {
            var sim = Simulation(tree: F.tree())
            let rootPos = sim.position(of: RepoPath(string: ""))!
            let f = RepoPath(string: "New/Deep/f.swift")
            sim.apply(delta: TreeDelta(added: [f]), now: F.t0)
            #expect(Geometry.distance(sim.position(of: f)!, rootPos) < 0.01)
            #expect(Geometry.distance(sim.layout.position(f)!, rootPos) > 1)
        }
    }

    @Test func visibleFileCountExcludesDyingAndDropsAfterDeath() {
        var sim = Simulation(tree: F.tree())
        sim.apply(delta: TreeDelta(added: [RepoPath(string: "B/d.swift")]), now: F.t0)
        #expect(sim.visibleFileCount == 4)
        sim.apply(delta: TreeDelta(removed: [a]), now: F.t0)
        #expect(sim.visibleFileCount == 3 && sim.tree.fileCount == 4)
        sim.update(dt: 1.1, now: F.t0)
        #expect(sim.visibleFileCount == 3 && sim.tree.fileCount == 3)
    }

    @Test func relayoutBumpsTreeVersion() {
        var sim = Simulation(tree: F.tree())
        let v = sim.treeVersion
        sim.apply(delta: TreeDelta(moved: [TreeDelta.Move(from: a, to: RepoPath(string: "Z/a.swift"))]), now: F.t0)
        #expect(sim.treeVersion > v)
        #expect(sim.tree.fileCount == 3)
    }

    @Test func reconcileMarksPhantomFilesDying() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("ignored.log"), atomically: true, encoding: .utf8)
        var sim = Simulation(tree: F.tree())
        sim.rootPath = dir.path
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [
            F.touch(1, "s1", "Ghost/x.swift"), F.touch(2, "s1", "ignored.log")]), now: F.t0)
        let ghost = RepoPath(string: "Ghost/x.swift"), ignored = RepoPath(string: "ignored.log")
        #expect(sim.tree.node(ghost) != nil && sim.tree.node(ignored) != nil)
        let snap = sim.tree.files.subtracting([ghost, ignored])
        var delta = TreeDelta(); delta.snapshot = snap
        sim.apply(delta: delta, now: F.t0)
        #expect(sim.deathAlpha(ghost) != nil)
        #expect(sim.deathAlpha(ignored) == nil)
    }

    @Test func fileReplacedByDirectoryDoesNotOrphanChildren() {
        var sim = Simulation(tree: F.tree())
        sim.apply(delta: TreeDelta(removed: [a]), now: F.t0)
        sim.update(dt: 0.3, now: F.t0)
        let inner = RepoPath(string: "A/a.swift/inner.swift")
        sim.apply(delta: TreeDelta(added: [inner]), now: F.t0)
        sim.update(dt: 1.1, now: F.t0)
        #expect(sim.tree.node(a)?.isDirectory == true && sim.tree.node(a)?.children == [inner])
        #expect(sim.tree.fileCount == 3 && sim.dying.isEmpty)
        #expect(sim.tree.node(inner) != nil && sim.position(of: inner) != nil)
    }

    @Test func directoryReplacedByFile() {
        var sim = Simulation(tree: FileTree(files: ["A/x/inner.swift", "B/c.swift"].map(RepoPath.init(string:))))
        let x = RepoPath(string: "A/x"), inner = RepoPath(string: "A/x/inner.swift")
        sim.apply(delta: TreeDelta(removed: [inner]), now: F.t0)
        sim.update(dt: 0.3, now: F.t0)
        sim.apply(delta: TreeDelta(added: [x]), now: F.t0)
        sim.update(dt: 1.1, now: F.t0)
        #expect(sim.tree.node(x)?.isDirectory == false && sim.tree.node(inner) == nil)
        #expect(sim.tree.fileCount == 2 && sim.dying.isEmpty)
    }

    @Test func moveCarriesTintAndFinishedDeathDropsIt() {
        var sim = Simulation(tree: F.tree())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "A/a.swift"), F.touch(2, "s1", "A/b.swift")]), now: F.t0)
        let dest = RepoPath(string: "B/a.swift")
        sim.apply(delta: TreeDelta(moved: [TreeDelta.Move(from: a, to: dest)]), now: F.t0)
        #expect(sim.tints[a] == nil && sim.tintStrength(dest) == Constants.tintWrite)
        #expect(sim.touchedPaths.contains(dest) && !sim.touchedPaths.contains(a))
        sim.apply(delta: TreeDelta(removed: [b]), now: F.t0)
        #expect(sim.tintStrength(b) == Constants.tintWrite)      // still tinted while fading out
        sim.update(dt: Constants.deathDuration + 0.1, now: F.t0)
        #expect(sim.tree.node(b) == nil && sim.tints[b] == nil)
    }
}
