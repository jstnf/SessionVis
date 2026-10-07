import Foundation
import Testing
@testable import SessionVisCore

/// A controllable clock the store reads from.
final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { now = start }
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
    var read: @Sendable () -> Date { { [self] in now } }
}

@Suite struct SessionStoreTests {
    let folder = PathFolder(root: "/repo")
    let url = URL(fileURLWithPath: "/p/s1.jsonl")
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func line(_ event: TranscriptEvent, at: TimeInterval = 0, cwd: String? = "/repo", agent: String? = nil, branch: String? = "main") -> SourceEvent {
        .line(sessionId: "s1", agentId: agent, TranscriptLine(timestamp: t0.addingTimeInterval(at), cwd: cwd, gitBranch: branch, agentId: agent, event: event))
    }
    func edit(_ path: String, id: String = "t1", at: TimeInterval = 0, cwd: String? = "/repo", agent: String? = nil, branch: String? = "main") -> SourceEvent {
        line(.toolUse(id: id, name: "Edit", filePath: path, description: nil, question: nil), at: at, cwd: cwd, agent: agent, branch: branch)
    }

    @Test func sessionAppearsWithHueAndTitleFallbacks() async {
        let clock = TestClock(); let store = SessionStore(folder: folder, clock: clock.read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(.sessionAppeared(sessionId: "s2", transcriptURL: URL(fileURLWithPath: "/p/s2.jsonl")))
        var snap = await store.snapshot()
        #expect(snap.agents.map(\.hueIndex) == [0, 1])
        #expect(snap.agents[0].title == "s1")                      // uuid prefix fallback
        #expect(snap.agents[0].status == .idle(preview: nil))
        await store.apply(line(.userPrompt(text: "Please fix the horrible scroll hitch on the media page right away thanks")))
        snap = await store.snapshot()
        #expect(snap.agents[0].title == "Please fix the horrible scroll hitch on the media page right")   // ≤60, word boundary
        await store.apply(line(.title("Scroll perf")))
        snap = await store.snapshot()
        #expect(snap.agents[0].title == "Scroll perf")
        #expect(snap.agents[0].branch == "main")
    }

    @Test func historicalLinesSetStatusWhenClockIsAhead() async {
        let clock = TestClock(t0.addingTimeInterval(60)); let store = SessionStore(folder: folder, clock: clock.read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(line(.userPrompt(text: "go"), at: 1))
        await store.apply(line(.toolUse(id: "q", name: "AskUserQuestion", filePath: nil, description: nil, question: "Which one?"), at: 2))
        let snap = await store.snapshot()
        #expect(snap.agents[0].status == .waiting(preview: "Which one?"))
        #expect(snap.agents[0].lastActivity == t0.addingTimeInterval(2))
        #expect(snap.agents[0].endedAt == nil)
    }

    @Test func freshRecordWithoutEventsIsNotAged() async {
        let clock = TestClock(); let store = SessionStore(folder: folder, clock: clock.read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        clock.advance(Constants.activeWindow + 1)
        let snap = await store.snapshot()
        #expect(snap.agents.count == 1)
        #expect(snap.agents[0].status != .ended && snap.agents[0].endedAt == nil)
    }

    @Test func touchesAreRecordedWithKindsAndFolding() async {
        let store = SessionStore(folder: folder, clock: TestClock().read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(edit("/repo/Sources/A.swift", id: "a"))
        await store.apply(line(.toolUse(id: "b", name: "Read", filePath: "/repo/Sources/B.swift", description: nil, question: nil)))
        await store.apply(line(.toolUse(id: "c", name: "Bash", filePath: nil, description: nil, question: nil)))
        await store.apply(edit("/elsewhere/C.swift", id: "d"))                       // external: ignored
        await store.apply(edit("/repo/.claude/worktrees/wt/Sources/D.swift", id: "e"))
        let snap = await store.snapshot()
        let touches = snap.recentTouches
        #expect(touches.map(\.seq) == [1, 2, 3])
        #expect(touches[0].path == RepoPath(string: "Sources/A.swift") && touches[0].kind == .write)
        #expect(touches[1].kind == .read)
        #expect(touches[2].path == RepoPath(string: "Sources/D.swift") && touches[2].worktree == "wt")
        #expect(snap.agents[0].touchCount == 3)
    }

    @Test func relativeFilePathResolvesAgainstCwd() async {
        let store = SessionStore(folder: folder, clock: TestClock().read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(edit("Sources/A.swift", cwd: "/repo"))
        await store.apply(edit("B.swift", id: "t2", cwd: "/repo/.claude/worktrees/wt"))
        let touches = await store.snapshot().recentTouches
        #expect(touches.map(\.path) == [RepoPath(string: "Sources/A.swift"), RepoPath(string: "B.swift")])
        #expect(touches[1].worktree == "wt")
    }

    @Test func relocatedSessionFoldsWorktreePaths() async {
        let store = SessionStore(folder: folder, clock: TestClock().read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(line(.relocated(cwd: "/repo/.claude/worktrees/wt")))
        await store.apply(line(.worktree(name: "wt", branch: "worktree-wt", path: "/repo/.claude/worktrees/wt")))
        await store.apply(edit("/repo/.claude/worktrees/wt/Sources/A.swift", cwd: "/repo/.claude/worktrees/wt", branch: "worktree-wt"))
        var snap = await store.snapshot()
        #expect(snap.agents.count == 1)
        #expect(snap.agents[0].worktree == "wt")
        #expect(snap.agents[0].branch == "worktree-wt")
        #expect(snap.recentTouches.first?.path == RepoPath(string: "Sources/A.swift"))
        #expect(snap.recentTouches.first?.worktree == "wt")
        await store.apply(line(.userPrompt(text: "back"), cwd: "/repo", branch: "main"))
        snap = await store.snapshot()
        #expect(snap.agents[0].branch == "main")   // branch follows the records
    }

    @Test func statusFlowsFromEvents() async {
        let store = SessionStore(folder: folder, clock: TestClock().read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(line(.toolUse(id: "q", name: "AskUserQuestion", filePath: nil, description: nil, question: "Which?"), at: 1))
        #expect(await store.snapshot().agents[0].status == .waiting(preview: "Which?"))
        await store.apply(line(.toolResult(toolUseId: "q"), at: 2))
        await store.apply(line(.assistantText(text: "Done.", endOfTurn: true), at: 3))
        await store.apply(line(.turnEnded, at: 3))
        #expect(await store.snapshot().agents[0].status == .idle(preview: "Done."))
    }

    @Test func subagentParentageResolvedAndProvisional() async {
        let store = SessionStore(folder: folder, clock: TestClock().read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        // main spawns A
        await store.apply(line(.toolUse(id: "toolu_A", name: "Agent", filePath: nil, description: "do A", question: nil)))
        await store.apply(.subagentAppeared(sessionId: "s1", agentId: "A", meta: SubagentMeta(description: "do A", agentType: "general-purpose", model: "sonnet", toolUseId: "toolu_A", spawnDepth: 1)))
        // B's meta points at a tool use A has not emitted yet → provisional parent is main
        await store.apply(.subagentAppeared(sessionId: "s1", agentId: "B", meta: SubagentMeta(description: "do B", toolUseId: "toolu_B", spawnDepth: 2)))
        var snap = await store.snapshot()
        let a = snap.agents.first { $0.id == AgentID("A") }!, b0 = snap.agents.first { $0.id == AgentID("B") }!
        #expect(a.parent == AgentID("s1") && a.hueIndex == 0 && a.title == "do A" && a.isSubagent)
        #expect(b0.parent == AgentID("s1"))
        // A emits toolu_B → B is re-parented to A
        await store.apply(line(.toolUse(id: "toolu_B", name: "Agent", filePath: nil, description: "do B", question: nil), agent: "A"))
        snap = await store.snapshot()
        #expect(snap.agents.first { $0.id == AgentID("B") }?.parent == AgentID("A"))
    }

    @Test func subagentEndsOnParentResultOrOwnTurnEndAndIsRemovedAfterLinger() async {
        let clock = TestClock(); let store = SessionStore(folder: folder, clock: clock.read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(.subagentAppeared(sessionId: "s1", agentId: "A", meta: SubagentMeta(description: "A", toolUseId: "toolu_A")))
        await store.apply(.subagentAppeared(sessionId: "s1", agentId: "B", meta: SubagentMeta(description: "B", toolUseId: "toolu_B")))
        await store.apply(line(.toolResult(toolUseId: "toolu_A"), at: 5))                        // (a) parent result
        await store.apply(line(.assistantText(text: "final", endOfTurn: true), at: 5, agent: "B"))
        await store.apply(line(.turnEnded, at: 5, agent: "B"))                                      // (b) own end of turn
        var snap = await store.snapshot()
        #expect(snap.agents.filter(\.isSubagent).allSatisfy { $0.status == .ended && $0.endedAt != nil })
        clock.advance(Constants.endedLinger + 0.1)
        snap = await store.snapshot()
        #expect(snap.agents.count == 1)   // only main remains
    }

    @Test func mainAgesOutAndTakesSubagentsWithIt() async {
        let clock = TestClock(); let store = SessionStore(folder: folder, clock: clock.read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(line(.userPrompt(text: "go")))
        await store.apply(.subagentAppeared(sessionId: "s1", agentId: "A", meta: SubagentMeta(description: "A", toolUseId: "x")))
        clock.advance(Constants.activeWindow + 1)
        var snap = await store.snapshot()
        #expect(snap.agents.count == 2 && snap.agents.allSatisfy { $0.status == .ended })
        clock.advance(Constants.endedLinger + 1)
        snap = await store.snapshot()
        #expect(snap.agents.isEmpty)
    }

    @Test func linesForUnknownAgentsCreateThem() async {
        let store = SessionStore(folder: folder, clock: TestClock().read)
        await store.apply(line(.userPrompt(text: "hello")))                         // no sessionAppeared first
        await store.apply(edit("/repo/A.swift", agent: "Z"))                          // subagent line before its meta
        let snap = await store.snapshot()
        #expect(snap.agents.count == 2)
        #expect(snap.agents.first { $0.id == AgentID("Z") }?.parent == AgentID("s1"))
        #expect(snap.recentTouches.first?.agent == AgentID("Z"))
    }

    @Test func recentTouchesAreCappedAndDiagnosticsStored() async {
        let store = SessionStore(folder: folder, clock: TestClock().read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        for i in 0..<(Constants.recentTouchLimit + 5) { await store.apply(edit("/repo/f\(i).swift", id: "t\(i)")) }
        await store.apply(.diagnostics(skippedLines: 7))
        let snap = await store.snapshot()
        #expect(snap.recentTouches.count == Constants.recentTouchLimit)
        #expect(snap.recentTouches.first?.seq == 6)
        #expect(snap.skippedLines == 7)
    }

    @Test func resumedSubagentKeepsItsIdentity() async {
        let clock = TestClock(); let store = SessionStore(folder: folder, clock: clock.read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(.subagentAppeared(sessionId: "s1", agentId: "A", meta: SubagentMeta(description: "Research hitches", toolUseId: "toolu_A")))
        await store.apply(line(.assistantText(text: "done", endOfTurn: true), at: 1, agent: "A"))
        await store.apply(line(.turnEnded, at: 1, agent: "A"))
        var snap = await store.snapshot()
        let hue = snap.agents.first { $0.id == AgentID("A") }?.hueIndex
        #expect(snap.agents.first { $0.id == AgentID("A") }?.status == .ended)
        clock.advance(Constants.endedLinger + 0.1)
        snap = await store.snapshot()
        #expect(snap.agents.first { $0.id == AgentID("A") } == nil)
        clock.advance(10)
        await store.apply(line(.userPrompt(text: "continue"), at: 20, agent: "A"))
        snap = await store.snapshot()
        let a = snap.agents.first { $0.id == AgentID("A") }
        #expect(a?.title == "Research hitches")
        #expect(a?.parent == AgentID("s1"))
        #expect(a?.status == .working)
        #expect(a?.endedAt == nil)
        #expect(a?.hueIndex == hue)
        #expect(snap.agents.first { $0.id == AgentID("s1") } != nil)
    }

    @Test func endedButLingeringSubagentResumesOnNewerEvent() async {
        let clock = TestClock(); let store = SessionStore(folder: folder, clock: clock.read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(.subagentAppeared(sessionId: "s1", agentId: "A", meta: SubagentMeta(description: "A", toolUseId: "toolu_A")))
        await store.apply(line(.assistantText(text: "done", endOfTurn: true), at: 1, agent: "A"))
        await store.apply(line(.turnEnded, at: 1, agent: "A"))
        #expect(await store.snapshot().agents.first { $0.id == AgentID("A") }?.status == .ended)
        await store.apply(line(.userPrompt(text: "more"), at: 2, agent: "A"))   // within endedLinger, not yet retired
        let a = await store.snapshot().agents.first { $0.id == AgentID("A") }
        #expect(a?.status == .working && a?.endedAt == nil)
    }

    @Test func olderLineDoesNotReviveEndedSubagent() async {
        let clock = TestClock(); let store = SessionStore(folder: folder, clock: clock.read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(.subagentAppeared(sessionId: "s1", agentId: "A", meta: SubagentMeta(description: "A", toolUseId: "toolu_A")))
        await store.apply(line(.toolResult(toolUseId: "toolu_A"), at: 10))         // parent result ends A
        await store.apply(line(.assistantText(text: "working", endOfTurn: false), at: 5, agent: "A"))   // A's history, read later
        await store.apply(edit("/repo/x.swift", id: "e1", at: 6, agent: "A"))
        let snap = await store.snapshot()
        let a = snap.agents.first { $0.id == AgentID("A") }
        #expect(a?.status == .ended && a?.endedAt != nil)
        #expect(snap.recentTouches.count == 1 && a?.touchCount == 1)
    }

    @Test func agedOutMainResumesWithSameHue() async {
        let clock = TestClock(); let store = SessionStore(folder: folder, clock: clock.read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(.sessionAppeared(sessionId: "s2", transcriptURL: URL(fileURLWithPath: "/p/s2.jsonl")))
        await store.apply(line(.userPrompt(text: "go")))
        // A record with no events is never aged, so s2 needs one to age out.
        await store.apply(.line(sessionId: "s2", agentId: nil, TranscriptLine(timestamp: t0, cwd: "/repo", event: .userPrompt(text: "go"))))
        clock.advance(Constants.activeWindow + 1)
        var snap = await store.snapshot()   // main ends here
        clock.advance(Constants.endedLinger + 1)
        snap = await store.snapshot()
        #expect(snap.agents.first { $0.id == AgentID("s1") } == nil)
        let later = Constants.activeWindow + Constants.endedLinger + 5
        await store.apply(line(.userPrompt(text: "again"), at: later))
        snap = await store.snapshot()
        let s1 = snap.agents.first { $0.id == AgentID("s1") }
        #expect(s1?.hueIndex == 0)
        #expect(s1?.status == .working)
        #expect(snap.agents.first { $0.id == AgentID("s2") } == nil)   // s2 stays retired; s1 resuming does not revive it
    }

    @Test func resumedSubagentRevivesRetiredParent() async {
        let clock = TestClock(); let store = SessionStore(folder: folder, clock: clock.read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(line(.userPrompt(text: "go")))   // a record with no events is never aged
        await store.apply(.subagentAppeared(sessionId: "s1", agentId: "A", meta: SubagentMeta(description: "Research hitches", toolUseId: "toolu_A")))
        await store.apply(line(.assistantText(text: "done", endOfTurn: true), at: 1, agent: "A"))
        await store.apply(line(.turnEnded, at: 1, agent: "A"))
        clock.advance(Constants.activeWindow + 1)
        _ = await store.snapshot()
        clock.advance(Constants.endedLinger + 1)
        var snap = await store.snapshot()
        #expect(snap.agents.isEmpty)
        await store.apply(line(.userPrompt(text: "continue"), at: Constants.activeWindow + Constants.endedLinger + 10, agent: "A"))
        snap = await store.snapshot()
        let s1 = snap.agents.first { $0.id == AgentID("s1") }
        let a = snap.agents.first { $0.id == AgentID("A") }
        #expect(s1?.hueIndex == 0 && s1?.endedAt == nil)
        #expect(a?.parent == AgentID("s1") && a?.title == "Research hitches" && a?.status == .working)
    }

    @Test func backgroundSubagentEndsOnHandbackAndStaysEndedUntilResumed() async {
        let clock = TestClock(); let store = SessionStore(folder: folder, clock: clock.read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(.subagentAppeared(sessionId: "s1", agentId: "A", meta: SubagentMeta(description: "Read files", toolUseId: "toolu_A")))
        await store.apply(line(.toolUse(id: "toolu_A", name: "Agent", filePath: nil, description: "Read files", question: nil), at: 1))
        await store.apply(line(.toolResult(toolUseId: "toolu_A"), at: 2))           // "Async agent launched" ends A prematurely…
        await store.apply(line(.toolUse(id: "r1", name: "Read", filePath: "/repo/a.swift", description: nil, question: nil), at: 3, agent: "A"))   // …and its next line brings it back
        var a = await store.snapshot().agents.first { $0.id == AgentID("A") }
        #expect(a?.status == .working && a?.endedAt == nil)
        await store.apply(line(.toolResult(toolUseId: "r1"), at: 4, agent: "A"))
        await store.apply(line(.toolUse(id: "hb", name: "SubagentHandback", filePath: nil, description: nil, question: nil), at: 5, agent: "A"))
        a = await store.snapshot().agents.first { $0.id == AgentID("A") }
        #expect(a?.status == .ended && a?.endedAt != nil)
        await store.apply(line(.toolResult(toolUseId: "hb"), at: 6, agent: "A"))     // the hand-back's own result is not a resume
        a = await store.snapshot().agents.first { $0.id == AgentID("A") }
        #expect(a?.status == .ended)
        await store.apply(line(.taskNotification(taskId: "A", status: "completed"), at: 7))
        a = await store.snapshot().agents.first { $0.id == AgentID("A") }
        #expect(a?.status == .ended)
        await store.apply(line(.userPrompt(text: "one more thing"), at: 8, agent: "A"))   // a real resume
        a = await store.snapshot().agents.first { $0.id == AgentID("A") }
        #expect(a?.status == .working && a?.endedAt == nil)
    }

    @Test func taskNotificationEndsASubagentThatNeverHandedBack() async {
        let clock = TestClock(); let store = SessionStore(folder: folder, clock: clock.read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(.subagentAppeared(sessionId: "s1", agentId: "A", meta: SubagentMeta(description: "Long job", toolUseId: "toolu_A")))
        await store.apply(line(.toolUse(id: "r1", name: "Read", filePath: "/repo/a.swift", description: nil, question: nil), at: 3, agent: "A"))
        await store.apply(line(.taskNotification(taskId: "A", status: "killed"), at: 4))
        let snap = await store.snapshot()
        let a = snap.agents.first { $0.id == AgentID("A") }
        #expect(a?.status == .ended && a?.endedAt != nil)
        #expect(snap.agents.first { $0.id == AgentID("s1") }?.status != .ended)      // the parent is unaffected
    }

    @Test func interruptedSubagentEndsAndStaysEnded() async {
        let clock = TestClock(); let store = SessionStore(folder: folder, clock: clock.read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(.subagentAppeared(sessionId: "s1", agentId: "A", meta: SubagentMeta(description: "Read docs", toolUseId: "toolu_A")))
        await store.apply(line(.toolUse(id: "r1", name: "Read", filePath: "/repo/a.swift", description: nil, question: nil), at: 3, agent: "A"))
        await store.apply(line(.interrupted, at: 4, agent: "A"))
        var a = await store.snapshot().agents.first { $0.id == AgentID("A") }
        #expect(a?.status == .ended && a?.endedAt != nil)
        await store.apply(line(.toolResult(toolUseId: "r1"), at: 5, agent: "A"))       // a straggling result is not a resume
        a = await store.snapshot().agents.first { $0.id == AgentID("A") }
        #expect(a?.status == .ended)
        await store.apply(line(.interrupted, at: 6))                                     // the main session's own interruption is still just idle
        #expect(await store.snapshot().agents.first { $0.id == AgentID("s1") }?.status == .idle(preview: nil))
    }

    @Test func notificationReadBeforeChildHistoryKeepsAKilledAgentEnded() async {
        let clock = TestClock(); let store = SessionStore(folder: folder, clock: clock.read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(.subagentAppeared(sessionId: "s1", agentId: "A", meta: SubagentMeta(description: "Killed job", toolUseId: "toolu_A")))
        await store.apply(line(.toolUse(id: "toolu_A", name: "Agent", filePath: nil, description: nil, question: nil), at: 1))
        await store.apply(line(.toolResult(toolUseId: "toolu_A"), at: 2))                        // async launch result: non-sticky end
        await store.apply(line(.taskNotification(taskId: "A", status: "killed"), at: 9))          // read first, as at launch
        await store.apply(line(.toolUse(id: "r1", name: "Read", filePath: "/repo/a.swift", description: nil, question: nil), at: 3, agent: "A"))
        await store.apply(line(.toolUse(id: "b1", name: "Bash", filePath: nil, description: nil, question: nil), at: 8, agent: "A"))
        let a = await store.snapshot().agents.first { $0.id == AgentID("A") }
        #expect(a?.status == .ended && a?.endedAt != nil)
        #expect(a?.touchCount == 1)                                                               // its history still counted (I-1)
    }
}
