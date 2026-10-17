import CoreGraphics
import Foundation
import Testing
@testable import SessionVisCore

@Suite struct SimulationFilterTests {
    typealias F = SimFixtures
    let s1 = AgentID("s1")
    let a = RepoPath(string: "A/a.swift"), b = RepoPath(string: "A/b.swift"), c = RepoPath(string: "B/c.swift")
    let x = RepoPath(string: "Gen/x.graphql.swift"), y = RepoPath(string: "Gen/y.graphql.swift"), g = RepoPath(string: "A/g.graphql.swift")
    let gen = RepoPath(string: "Gen"), root = RepoPath([])

    /// Three plain files, two generated ones under Gen, and a generated ghost in A.
    func tree() -> FileTree {
        var t = FileTree(files: [a, b, c, x, y])
        t.insert(file: g, origin: .worktree("wt"))
        return t
    }

    func filter(_ patterns: String...) -> FileFilter { FileFilter(rules: patterns.map { FilterRule(pattern: $0) }) }

    func touched(_ sim: inout Simulation, _ path: String, seq: UInt64 = 1, scope: TouchScope = .file) {
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(seq, "s1", path, scope: scope)]), now: F.t0)
    }

    @Test func initialFilterPrunesFilesAndTheDirectoriesTheyEmpty() {
        let sim = Simulation(tree: tree(), filter: filter("*.graphql.swift"))
        #expect(sim.tree.fileCount == 3 && sim.tree.node(gen) == nil && sim.tree.node(g) == nil)
        #expect(sim.hidden == [x: [.main], y: [.main], g: [.worktree("wt")]])
        #expect(sim.hiddenFileCount == 3 && sim.visibleFileCount == 3)
        #expect(sim.layout.position(gen) == nil && sim.tree.root.leafCount == 3)
        #expect(sim.filter == filter("*.graphql.swift"))
        let plain = Simulation(tree: tree())
        #expect(plain.hiddenFileCount == 0 && plain.tree.fileCount == 6 && plain.filter.isEmpty)
    }

    @Test func setFilterHidesAtOnceAndClearsEffects() {
        var sim = Simulation(tree: tree())
        touched(&sim, "A/a.swift")
        #expect(sim.tints[a] != nil && sim.heatValue(a) > 0 && sim.edgeTints[a] != nil && sim.touchedPaths.contains(a))
        let version = sim.treeVersion
        sim.setFilter(filter("a.swift"))
        #expect(sim.edgeTints[RepoPath(string: "A")] == nil)   // A survives through b.swift, which nobody touched
        #expect(sim.tree.node(a) == nil && sim.position(of: a) == nil && sim.deathAlpha(a) == nil)
        #expect(sim.tints[a] == nil && sim.heatValue(a) == 0 && sim.edgeTints[a] == nil && !sim.touchedPaths.contains(a))
        #expect(sim.hidden[a] == [.main] && sim.hiddenFileCount == 1 && sim.visibleFileCount == 5)
        #expect(sim.treeVersion == version + 1)
        #expect(sim.hitTest(screen: sim.worldToScreen(sim.layout.position(b)!)) == .node(b))   // the rest still hit-tests
        sim.setFilter(filter("a.swift"))                                                           // same rules: no relayout
        #expect(sim.treeVersion == version + 1)
    }

    @Test func hidingAFileRelightsSharedEdgesFromSurvivingTouches() {
        var sim = Simulation(tree: tree())
        let dirA = RepoPath(string: "A")
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1"), F.agent("s2")]), now: F.t0)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1"), F.agent("s2")], recentTouches: [F.touch(1, "s2", "A/b.swift")]), now: F.t0)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1"), F.agent("s2")], recentTouches: [F.touch(2, "s1", "A/a.swift")]), now: F.t0.addingTimeInterval(1))
        #expect(sim.edgeTints[dirA]?.toucher == AgentID("s1"))
        sim.setFilter(filter("a.swift"))
        #expect(sim.edgeTints[dirA]?.toucher == AgentID("s2") && sim.edgeTints[b]?.toucher == AgentID("s2"))
        #expect(sim.edgeTints[a] == nil)
    }

    @Test func restoringScalesFilesInWithTheirOrigins() {
        var t = tree()
        t.insert(file: x, origin: .worktree("wt"))
        var sim = Simulation(tree: t, filter: filter("*.graphql.swift"))
        #expect(sim.hidden[g] == [.worktree("wt")] && sim.hidden[x] == [.main, .worktree("wt")])
        let genlessVersion = sim.treeVersion
        sim.setFilter(FileFilter())
        #expect(sim.hiddenFileCount == 0 && sim.tree.fileCount == 6 && sim.treeVersion == genlessVersion + 1)
        #expect(sim.tree.isGhost(g) && !sim.tree.isGhost(x))
        #expect(sim.tree.node(x)?.origins == [.main, .worktree("wt")] && sim.tree.node(g)?.origins == [.worktree("wt")])
        #expect(sim.birthScale(x) == 0 && sim.birthScale(g) == 0 && !sim.isLanding(x) && !sim.isLanding(g))
        #expect(Geometry.distance(sim.position(of: g)!, sim.position(of: RepoPath(string: "A"))!) < 0.01)   // born at its directory
        sim.update(dt: Constants.birthDuration + 0.1, now: F.t0)
        #expect(sim.birthScale(x) == 1 && sim.tree.node(gen) != nil)
    }

    @Test func disablingARuleShowsFilesAndReenablingHidesThemAgain() {
        var f = filter("*.graphql.swift")
        var sim = Simulation(tree: tree(), filter: f)
        f.setEnabled(false, for: "*.graphql.swift")
        sim.setFilter(f)
        #expect(sim.tree.node(x) != nil && sim.hiddenFileCount == 0)
        touched(&sim, "Gen/x.graphql.swift")
        #expect(sim.tints[x] != nil && sim.touchedPaths.contains(x))
        f.setEnabled(true, for: "*.graphql.swift")
        sim.setFilter(f)
        #expect(sim.tree.node(x) == nil && sim.tints[x] == nil && !sim.touchedPaths.contains(x) && sim.hidden[x] == [.main])
        #expect(sim.hiddenFileCount == 3)
    }

    @Test func aRuleHidingEverythingLeavesTheRootAndComesBack() {
        var sim = Simulation(tree: tree(), filter: filter("*"))
        #expect(sim.tree.fileCount == 0 && sim.tree.root.children.isEmpty && sim.hiddenFileCount == 6 && sim.visibleFileCount == 0)
        #expect(sim.position(of: root) != nil)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        sim.update(dt: 0.1, now: F.t0)                 // layout, grid, camera fit and avatars cope with an empty tree
        #expect(sim.hitTest(screen: sim.worldToScreen(.zero)) == .node(root))
        sim.setFilter(FileFilter())
        #expect(sim.tree.fileCount == 6 && sim.hiddenFileCount == 0)
    }

    @Test func hidingADyingOrBornFileDropsItsAnimation() {
        var sim = Simulation(tree: tree())
        sim.apply(delta: TreeDelta(added: [RepoPath(string: "B/n.swift")], removed: [a]), now: F.t0)
        #expect(sim.deathAlpha(a) != nil && sim.birthScale(RepoPath(string: "B/n.swift")) == 0)
        sim.setFilter(filter("a.swift", "n.swift"))
        #expect(sim.dying.isEmpty && sim.born.isEmpty && sim.hidden[a] == nil && sim.hidden[RepoPath(string: "B/n.swift")] == [.main])
        sim.update(dt: Constants.deathDuration + 0.1, now: F.t0)
        #expect(sim.tree.node(a) == nil && sim.hiddenFileCount == 1)
    }

    @Test func hiddenFileTouchIsConsumedAndNotReplayed() {
        var sim = Simulation(tree: tree(), filter: filter("*.graphql.swift"))
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        sim.update(dt: 1, now: F.t0)
        let anchor = sim.avatars[s1]!.anchor
        let never = RepoPath(string: "Gen/never.graphql.swift")
        let touches = [F.touch(1, "s1", "Gen/x.graphql.swift"), F.touch(2, "s1", "Gen/never.graphql.swift"),
                       Touch(seq: 3, agent: s1, path: g, worktree: "wt", kind: .write, scope: .file, source: .tool("Edit"), at: F.t0)]
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: touches), now: F.t0)
        #expect(sim.lastTouchSeq == 3)
        #expect(sim.beams.isEmpty && sim.particles.isEmpty && sim.tints.isEmpty && sim.edgeTints.isEmpty && sim.heat.isEmpty && sim.touchedPaths.isEmpty)
        #expect(sim.tree.node(x) == nil && sim.tree.node(never) == nil && sim.tree.node(g) == nil)
        #expect(sim.hidden[never] == nil && sim.hiddenFileCount == 3)
        #expect(sim.avatars[s1]?.lastTouchPath == nil)
        sim.update(dt: 1, now: F.t0)
        #expect(Geometry.distance(sim.avatars[s1]!.anchor, anchor) < 0.01)
        sim.setFilter(FileFilter())
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: touches), now: F.t0)
        #expect(sim.beams.isEmpty && sim.tints[x] == nil && sim.tree.node(never) == nil)
        let later = Touch(seq: 4, agent: s1, path: x, worktree: nil, kind: .write, scope: .file, source: .tool("Edit"), at: F.t0)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: touches + [later]), now: F.t0)
        #expect(sim.beams.count == 1 && sim.tints[x] != nil)
    }

    @Test func directoryTouchOnAHiddenDirectoryLandsOnTheNearestVisibleAncestor() {
        var sim = Simulation(tree: tree(), filter: filter("Gen"))
        #expect(sim.tree.node(gen) == nil)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "Gen", kind: .read, scope: .directory, source: .shell("ls"))]), now: F.t0)
        #expect(sim.tints[root] != nil && sim.touchedPaths.contains(root) && sim.beams.count == 1 && sim.beams[0].to == root)
        #expect(sim.tree.node(gen) == nil)
    }

    @Test func addedHiddenPathIsRememberedNotInserted() {
        var sim = Simulation(tree: tree(), filter: filter("*.graphql.swift"))
        let z = RepoPath(string: "Gen/z.graphql.swift"), n = RepoPath(string: "Gen/n.swift")
        let version = sim.treeVersion
        sim.apply(delta: TreeDelta(added: [z], origin: .worktree("wt")), now: F.t0)
        #expect(sim.tree.node(z) == nil && sim.hidden[z] == [.worktree("wt")] && sim.treeVersion == version)
        sim.apply(delta: TreeDelta(added: [z, n]), now: F.t0)
        #expect(sim.hidden[z] == [.main, .worktree("wt")] && sim.tree.node(n) != nil && sim.birthScale(n) == 0)
        #expect(sim.hiddenFileCount == 4 && sim.visibleFileCount == 4)
        sim.setFilter(FileFilter())
        #expect(sim.tree.node(z)?.origins == [.main, .worktree("wt")])
    }

    @Test func movesFollowTheFilterInAllThreeDirections() {
        var sim = Simulation(tree: tree(), filter: filter("*.graphql.swift"))
        let aHidden = RepoPath(string: "A/a.graphql.swift"), xShown = RepoPath(string: "Gen/x.swift"), yMoved = RepoPath(string: "C/y.graphql.swift")
        sim.apply(delta: TreeDelta(moved: [TreeDelta.Move(from: a, to: aHidden), TreeDelta.Move(from: x, to: xShown), TreeDelta.Move(from: y, to: yMoved)]), now: F.t0)
        #expect(sim.deathAlpha(a) == 1 && sim.tree.node(aHidden) == nil && sim.hidden[aHidden] == [.main])
        #expect(sim.hidden[x] == nil && sim.tree.node(xShown) != nil && sim.birthScale(xShown) == 0 && !sim.isLanding(xShown))
        #expect(sim.hidden[y] == nil && sim.hidden[yMoved] == [.main] && sim.tree.node(yMoved) == nil)
        #expect(sim.hiddenFileCount == 3)
        sim.update(dt: Constants.deathDuration + 0.1, now: F.t0)
        #expect(sim.tree.node(a) == nil && sim.tree.fileCount == 3)
    }

    @Test func removedAndUnlistedHiddenPathsLoseTheOriginAndAreForgottenWithTheLast() throws {
        var t = tree()
        t.insert(file: x, origin: .worktree("wt"))
        var sim = Simulation(tree: t, filter: filter("*.graphql.swift"))
        #expect(sim.hidden[x] == [.main, .worktree("wt")])
        sim.apply(delta: TreeDelta(removed: [x], origin: .main), now: F.t0)
        #expect(sim.hidden[x] == [.worktree("wt")] && sim.tree.node(x) == nil && sim.dying.isEmpty)
        sim.apply(delta: TreeDelta(removed: [x], origin: .worktree("wt")), now: F.t0)
        #expect(sim.hidden[x] == nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("filter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Gen"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("Gen/y.graphql.swift"), atomically: true, encoding: .utf8)
        sim.folder = PathFolder(root: dir.path)
        sim.apply(delta: TreeDelta(origin: .main, snapshot: [a, b, c]), now: F.t0)
        #expect(sim.hidden[y] == [.main])
        #expect(sim.deathAlpha(a) == nil && sim.deathAlpha(b) == nil)
        try FileManager.default.removeItem(at: dir)
        sim.apply(delta: TreeDelta(origin: .main, snapshot: [a, b, c]), now: F.t0)
        #expect(sim.hidden[y] == nil)
        #expect(sim.hidden[g] == [.worktree("wt")])
        #expect(sim.hiddenFileCount == 1)
    }

    @Test func noInsertionPathLetsAHiddenFileIntoTheTree() {
        let f = filter("*.graphql.swift")
        var sim = Simulation(tree: tree(), filter: f)
        let t1 = RepoPath(string: "Gen/t1.graphql.swift"), d1 = RepoPath(string: "Gen/d1.graphql.swift"), m1 = RepoPath(string: "A/m1.graphql.swift")
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")]), now: F.t0)
        sim.apply(snapshot: StoreSnapshot(agents: [F.agent("s1")], recentTouches: [F.touch(1, "s1", "Gen/t1.graphql.swift")]), now: F.t0)
        sim.apply(delta: TreeDelta(added: [d1], moved: [TreeDelta.Move(from: a, to: m1)], snapshot: [a, b, c, d1, t1, m1]), now: F.t0)
        sim.update(dt: Constants.deathDuration + 0.1, now: F.t0)
        #expect(!sim.tree.files.contains { f.hides($0) })
    }
}
