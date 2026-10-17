import CoreGraphics
import Foundation
import Testing
@testable import SessionVisCore

@Suite struct SimulationFocusTests {
    typealias F = SimFixtures
    let s1 = AgentID("s1")
    let a0 = RepoPath(string: "A/a0.swift"), a1 = RepoPath(string: "A/a1.swift"), b0 = RepoPath(string: "B/b0.swift")

    /// Thirty files under A and thirty under B, so weights visibly move the layout.
    func bigTree() -> FileTree {
        FileTree(files: (0..<30).map { RepoPath(string: "A/a\($0).swift") } + (0..<30).map { RepoPath(string: "B/b\($0).swift") })
    }

    func primed() -> Simulation {
        var sim = Simulation(tree: bigTree())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        return sim
    }

    func touch(_ sim: inout Simulation, _ path: String, seq: UInt64, at: Date = SimFixtures.t0, now: Date = SimFixtures.t0) {
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(seq, "s1", path, at: at)]), now: now)
    }

    @Test func turningFocusOnRelayoutsFromCurrentActivityAndOffRestoresThePlainLayout() {
        var sim = primed()
        let plain = sim.layout
        touch(&sim, "A/a0.swift", seq: 1)
        let version = sim.treeVersion
        sim.setFocusMode(true)
        #expect(sim.focusMode && sim.activeFiles == [a0] && sim.treeVersion == version + 1)
        #expect(sim.isActive(a0) && !sim.isActive(a1) && !sim.isActive(b0))
        #expect(sim.layout == RadialLayout.compute(sim.tree, active: [a0]) && sim.layout != plain)
        #expect(sim.hitTest(screen: sim.worldToScreen(sim.layout.position(b0)!)) == .node(b0))   // a packed file still hovers
        sim.setFocusMode(true)                                                                    // unchanged: no relayout
        #expect(sim.treeVersion == version + 1)
        sim.setFocusMode(false)
        #expect(!sim.focusMode && sim.activeFiles.isEmpty && sim.treeVersion == version + 2 && sim.layout == plain)
    }

    @Test func renderPositionsEaseTowardTheFocusedLayout() {
        var sim = primed()
        touch(&sim, "A/a0.swift", seq: 1)
        let start = sim.position(of: b0)!
        sim.setFocusMode(true)
        let target = sim.layout.position(b0)!
        #expect(sim.position(of: b0) == start && Geometry.distance(start, target) > 1)
        sim.update(dt: 0.1, now: F.t0)
        let moved = sim.position(of: b0)!
        #expect(Geometry.distance(moved, target) < Geometry.distance(start, target) && Geometry.distance(moved, start) > 0.1)
    }

    @Test func activityExpiresAfterTheWindowAndALiveTintKeepsItActive() {
        var sim = primed()
        touch(&sim, "A/a0.swift", seq: 1)
        sim.setFocusMode(true)
        #expect(sim.isActive(a0))
        sim.update(dt: Constants.focusRelayoutInterval, now: F.t0.addingTimeInterval(Constants.focusActiveWindow + 1))
        #expect(!sim.isActive(a0) && sim.activeFiles.isEmpty && sim.lastTouchAt[a0] == nil)

        // Checks the live-tint clause of the activity judgement: a file whose tint is still alive stays active past the touch window.
        var committed = primed()
        touch(&committed, "A/a0.swift", seq: 1)
        let commitAt = F.t0.addingTimeInterval(29 * 60)
        committed.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentCommands: [F.command(1, "s1", "git commit -m x", at: commitAt)]), now: commitAt)
        #expect(committed.tints[a0]?.touchedAt == commitAt)
        committed.setFocusMode(true)
        committed.update(dt: Constants.focusRelayoutInterval, now: F.t0.addingTimeInterval(Constants.focusActiveWindow + 30))
        #expect(committed.isActive(a0))
    }

    @Test func aSimulationCreatedFocusedStartsPackedAndRejudgesAfterHistoryAtOnce() {
        let tree = bigTree()
        var sim = Simulation(tree: tree, focusMode: true)
        #expect(sim.focusMode && sim.layout == RadialLayout.compute(tree, active: []))
        let history = F.t0.addingTimeInterval(-10 * 60)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "A/a0.swift", at: history)]), now: F.t0)
        sim.update(dt: 0.016, now: F.t0)
        #expect(sim.activeFiles == [a0])
    }

    @Test func relayoutIsThrottledAndOnlyWhenActivityChanges() {
        var sim = primed()
        sim.setFocusMode(true)                                   // nothing active: everything packed
        #expect(sim.activeFiles.isEmpty && sim.layout == RadialLayout.compute(sim.tree, active: []))
        sim.update(dt: 0.1, now: F.t0)
        #expect(sim.hitTest(screen: sim.worldToScreen(.zero)) == .node(RepoPath([])))
        let version = sim.treeVersion
        touch(&sim, "A/a0.swift", seq: 1)
        #expect(sim.treeVersion == version && !sim.isActive(a0) && sim.tints[a0] != nil)   // lit at once, judged later
        sim.update(dt: Constants.focusRelayoutInterval / 2, now: F.t0)
        #expect(sim.treeVersion == version)
        sim.update(dt: Constants.focusRelayoutInterval / 2, now: F.t0)
        #expect(sim.treeVersion == version + 1 && sim.isActive(a0))
        sim.update(dt: Constants.focusRelayoutInterval, now: F.t0)                            // same set: no relayout
        #expect(sim.treeVersion == version + 1)
        sim.setFocusMode(false)
        touch(&sim, "A/a1.swift", seq: 2)
        let off = sim.treeVersion
        sim.update(dt: 10 * Constants.focusRelayoutInterval, now: F.t0)
        #expect(sim.treeVersion == off && sim.activeFiles.isEmpty)                            // focus off: never re-judged
    }

    @Test func primingHistoryCountsByAgeAndMovesCarryTheTouchTime() {
        var sim = Simulation(tree: bigTree())
        let recent = F.t0.addingTimeInterval(-10 * 60), old = F.t0.addingTimeInterval(-40 * 60)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "A/a0.swift", at: old), F.touch(2, "s1", "A/a1.swift", at: recent)]), now: F.t0)
        #expect(sim.lastTouchAt[a0] == old && sim.lastTouchAt[a1] == recent)
        sim.setFocusMode(true)
        #expect(sim.activeFiles == [a1])
        let moved = RepoPath(string: "B/a1.swift")
        sim.apply(delta: TreeDelta(moved: [TreeDelta.Move(from: a1, to: moved)]), now: F.t0)
        #expect(sim.lastTouchAt[moved] == recent && sim.lastTouchAt[a1] == nil)
        sim.update(dt: Constants.focusRelayoutInterval, now: F.t0)
        #expect(sim.activeFiles == [moved])
        sim.apply(delta: TreeDelta(removed: [moved]), now: F.t0)
        sim.update(dt: Constants.deathDuration + 0.1, now: F.t0)
        #expect(sim.tree.node(moved) == nil && sim.lastTouchAt[moved] == nil)
        sim.update(dt: Constants.focusRelayoutInterval, now: F.t0)
        #expect(sim.activeFiles.isEmpty)
    }

    @Test func hiddenFilesNeverCountAndFocusSurvivesAFilterChange() {
        var f = FileFilter()
        _ = f.add("a0.swift")
        var sim = Simulation(tree: bigTree(), filter: f)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        touch(&sim, "A/a0.swift", seq: 1)                        // consumed: the file is hidden
        touch(&sim, "A/a1.swift", seq: 2)
        sim.setFocusMode(true)
        #expect(sim.activeFiles == [a1] && sim.lastTouchAt[a0] == nil)
        sim.setFilter(FileFilter())
        #expect(sim.focusMode && sim.tree.node(a0) != nil && !sim.isActive(a0))
        #expect(sim.layout == RadialLayout.compute(sim.tree, active: sim.activeFiles))
    }

    @Test func aDirectoryTouchMakesNothingActive() {
        var sim = primed()
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "A", kind: .read, scope: .directory, source: .shell("ls"))]), now: F.t0)
        sim.setFocusMode(true)
        #expect(sim.activeFiles.isEmpty && sim.lastTouchAt.isEmpty && sim.tints[RepoPath(string: "A")] != nil)
    }

    @Test func searchTouchesNeverMakeAFileActive() {
        var sim = primed()
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "A/a0.swift", kind: .read, scope: .directory, source: .tool("Grep"))]), now: F.t0)
        sim.setFocusMode(true)
        #expect(sim.activeFiles.isEmpty)
    }

    @Test func hidingAndShowingAFileKeepsItsActivity() {
        var sim = primed()
        touch(&sim, "A/a0.swift", seq: 1)
        sim.setFocusMode(true)
        var f = FileFilter(); _ = f.add("a0.swift")
        sim.setFilter(f)
        sim.setFilter(FileFilter())
        #expect(sim.lastTouchAt[a0] == F.t0)
        sim.update(dt: Constants.focusRelayoutInterval, now: F.t0.addingTimeInterval(1))
        #expect(sim.isActive(a0))
    }

    @Test func snapshotActiveFilesPrimeTheWindowRegardlessOfTheTouchRing() {
        var sim = Simulation(tree: bigTree(), focusMode: true)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], activeFiles: [a0: F.t0.addingTimeInterval(-60), b0: F.t0.addingTimeInterval(-3 * 3600)]), now: F.t0)
        sim.update(dt: 0.016, now: F.t0)
        #expect(sim.isActive(a0) && !sim.isActive(b0))
    }

    @Test func aTouchWhileHiddenLeavesNoActivityBehind() {
        var f = FileFilter(); _ = f.add("a0.swift")
        var sim = Simulation(tree: bigTree(), filter: f)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "A/a0.swift")], activeFiles: [a0: F.t0]), now: F.t0)
        sim.setFocusMode(true)
        sim.setFilter(FileFilter())
        sim.update(dt: Constants.focusRelayoutInterval, now: F.t0.addingTimeInterval(1))
        #expect(!sim.isActive(a0))
    }

    @Test func aSearchOnlyTintStaysInactiveAcrossARename() {
        let moved = RepoPath(string: "A/moved.swift")
        var sim = primed()
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "A/a0.swift", kind: .read, scope: .directory, source: .tool("Grep"))]), now: F.t0)
        sim.setFocusMode(true)
        sim.apply(delta: TreeDelta(moved: [TreeDelta.Move(from: a0, to: moved)]), now: F.t0)
        sim.update(dt: Constants.focusRelayoutInterval, now: F.t0)
        #expect(!sim.isActive(moved))
        #expect(!sim.searchTinted.contains(a0))
    }
}
