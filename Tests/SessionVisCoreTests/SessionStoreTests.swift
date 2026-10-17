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

    func bash(_ command: String, id: String = "b1", description: String? = nil, at: TimeInterval = 0, cwd: String = "/repo", agent: String? = nil) -> SourceEvent {
        line(.toolUse(id: id, name: "Bash", filePath: nil, description: description, question: nil, command: command), at: at, cwd: cwd, agent: agent)
    }
    /// A real directory standing in for the repository, holding `files` (a trailing `/` makes a directory).
    func tempRepo(_ files: [String]) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sv-store-\(UUID().uuidString)").path
        for f in files {
            let full = root + "/" + f
            if f.hasSuffix("/") {
                try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: full, contents: Data())
            }
        }
        return root
    }

    @Test func bashCallsBecomeCommandEventsWithLabelsAndClasses() async {
        let store = SessionStore(folder: folder, clock: TestClock().read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(bash("cd /repo && swift test --filter X", id: "b1", description: "Run store tests", at: 1))
        await store.apply(bash("git push origin main", id: "b2", at: 2))
        await store.apply(edit("/repo/A.swift", id: "e1", at: 3))                              // not a command
        let snap = await store.snapshot()
        let cmds = snap.recentCommands
        #expect(cmds.map(\.seq) == [1, 2])
        #expect(cmds[0].agent == AgentID("s1") && cmds[0].commandClass == .test && cmds[0].label == "Run store tests")
        #expect(cmds[0].command == "cd /repo && swift test --filter X" && cmds[0].at == t0.addingTimeInterval(1))
        #expect(cmds[1].commandClass == .git(.push) && cmds[1].label == "git push" && cmds[1].milestone == .push)
        #expect(cmds[0].hueIndex == snap.agents[0].hueIndex)
        #expect(snap.agents[0].lastCommandLabel == "git push")
        #expect(snap.agents[0].lastMilestone == .push)
        #expect(snap.agents[0].status == .working)
    }

    @Test func commitInfoArrivesWithTheToolResult() async {
        let store = SessionStore(folder: folder, clock: TestClock().read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(bash("git commit -m 'Add thing'", id: "c1", at: 1))
        var snap = await store.snapshot()
        #expect(snap.recentCommands[0].commit == nil && snap.recentCommands[0].milestone == .commit(nil))
        #expect(snap.agents[0].lastMilestone == .commit(nil))
        await store.apply(line(.toolResult(toolUseId: "c1", text: "[main a1b2c3d] Add thing\n 1 file changed"), at: 2))
        snap = await store.snapshot()
        let info = CommitInfo(hash: "a1b2c3d", branch: "main", message: "Add thing")
        #expect(snap.recentCommands[0].commit == info)
        #expect(snap.agents[0].lastMilestone == .commit(info))
        // A result for a non-commit, or without the commit line, leaves things alone.
        await store.apply(bash("git commit -m again", id: "c2", at: 3))
        await store.apply(line(.toolResult(toolUseId: "c2", text: "nothing to commit"), at: 4))
        snap = await store.snapshot()
        #expect(snap.recentCommands[1].commit == nil && snap.agents[0].lastMilestone == .commit(nil))
    }

    @Test func chainWithSeveralMilestonesRecordsEachInOrder() async {
        let store = SessionStore(folder: folder, clock: TestClock().read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(bash("git commit -m x && git push origin main", id: "c1", description: "Commit and push", at: 1))
        var snap = await store.snapshot()
        let cmds = snap.recentCommands
        #expect(cmds.map(\.commandClass) == [.git(.commit), .git(.push)])
        #expect(cmds.count == 2 && cmds[1].seq == cmds[0].seq + 1)
        #expect(cmds[0].label == "Commit and push" && cmds[1].label == "git push")      // a description goes on the first only
        #expect(cmds[0].command == "git commit -m x" && cmds[1].command == "git push origin main")
        #expect(snap.agents[0].lastCommandLabel == "git push" && snap.agents[0].lastMilestone == .push)
        await store.apply(line(.toolResult(toolUseId: "c1", text: "[main a1b2c3d] x\n 1 file changed"), at: 2))
        snap = await store.snapshot()
        #expect(snap.recentCommands[0].commit == CommitInfo(hash: "a1b2c3d", branch: "main", message: "x"))
        #expect(snap.recentCommands[1].commit == nil && snap.agents[0].lastMilestone == .push)
        // Without a description each event is labelled from its own segment.
        await store.apply(bash("git commit -m y && git push", id: "c2", at: 3))
        snap = await store.snapshot()
        #expect(snap.recentCommands.suffix(2).map(\.label) == ["git commit", "git push"])
    }

    @Test func commandBufferIsCappedAndSubagentCommandsBelongToThem() async {
        let store = SessionStore(folder: folder, clock: TestClock().read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(.subagentAppeared(sessionId: "s1", agentId: "A", meta: SubagentMeta(description: "sub", agentType: "general-purpose")))
        for i in 0..<(Constants.recentCommandLimit + 5) {
            await store.apply(bash("ls \(i)", id: "x\(i)", at: TimeInterval(i), agent: "A"))
        }
        let snap = await store.snapshot()
        #expect(snap.recentCommands.count == Constants.recentCommandLimit)
        #expect(snap.recentCommands.first?.seq == 6 && snap.recentCommands.last?.seq == UInt64(Constants.recentCommandLimit + 5))
        #expect(snap.recentCommands.allSatisfy { $0.agent == AgentID("A") })
        #expect(snap.agents.first { $0.id == AgentID("A") }?.lastCommandLabel == "ls \(Constants.recentCommandLimit + 4)")
        #expect(snap.agents.first { $0.id == AgentID("s1") }?.lastCommandLabel == nil)
    }

    @Test func shellCommandsYieldTouchesWithVerbsAndScopes() async throws {
        let root = try tempRepo(["Sources/A.swift", "Sources/B.swift", "Tests/"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = SessionStore(folder: PathFolder(root: root), clock: TestClock().read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(bash("cd \(root) && sed -n 1,40p Sources/A.swift", id: "b1", at: 1, cwd: root))
        await store.apply(bash("grep -rn needle Sources Tests", id: "b2", at: 2, cwd: root))
        await store.apply(bash("cat > Sources/New.swift <<'EOF'\ncat Sources/B.swift\nEOF", id: "b3", at: 3, cwd: root))
        await store.apply(bash("cat /elsewhere/x.txt", id: "b4", at: 4, cwd: root))
        await store.apply(bash("ls", id: "b5", at: 5, cwd: root))
        let snap = await store.snapshot()
        let ts = snap.recentTouches
        #expect(ts.map(\.path.string) == ["Sources/A.swift", "Sources", "Tests", "Sources/New.swift", ""])
        #expect(ts[0].kind == .read && ts[0].scope == .file && ts[0].source == .shell("sed"))
        #expect(ts[1].scope == .directory && ts[1].source == .shell("grep"))
        #expect(ts[3].kind == .write && ts[3].source == .shell(">"))
        #expect(ts[4].path.isRoot && ts[4].scope == .directory)
        #expect(ts.allSatisfy { $0.hueIndex == snap.agents[0].hueIndex && $0.agentTitle == snap.agents[0].title })
        #expect(snap.agents[0].touchCount == 5)
        #expect(snap.recentCommands.count == 5)
    }

    @Test func shellTouchesFoldWorktreePathsAndUseTheRecordCwd() async throws {
        let root = try tempRepo([".claude/worktrees/wt/Sources/W.swift"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = SessionStore(folder: PathFolder(root: root), clock: TestClock().read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(line(.toolUse(id: "b1", name: "Bash", filePath: nil, description: nil, question: nil, command: "cat Sources/W.swift"), cwd: root + "/.claude/worktrees/wt"))
        let ts = await store.snapshot().recentTouches
        #expect(ts.count == 1 && ts[0].path == RepoPath(string: "Sources/W.swift") && ts[0].worktree == "wt")
    }

    @Test func toolTouchesCarrySourceAndSearchesTouchDirectories() async throws {
        let root = try tempRepo(["Sources/"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = SessionStore(folder: PathFolder(root: root), clock: TestClock().read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(edit(root + "/A.swift", id: "e1", at: 1, cwd: root))
        await store.apply(line(.toolUse(id: "g1", name: "Grep", filePath: root + "/Sources", description: nil, question: nil), at: 2, cwd: root))
        await store.apply(line(.toolUse(id: "g2", name: "Glob", filePath: nil, description: nil, question: nil), at: 3, cwd: root))
        let ts = await store.snapshot().recentTouches
        #expect(ts[0].source == .tool("Edit") && ts[0].scope == .file)
        #expect(ts[1].path == RepoPath(string: "Sources") && ts[1].scope == .directory && ts[1].kind == .read && ts[1].source == .tool("Grep"))
        #expect(ts[2].path.isRoot && ts[2].scope == .directory && ts[2].source == .tool("Glob"))
    }

    @Test func shellAndSearchReadsNeedTheTargetOnDisk() async throws {
        let root = try tempRepo(["Sources/A.swift"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = SessionStore(folder: PathFolder(root: root), clock: TestClock().read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(bash("cat Sources/A.swift Sources/Missing.swift", id: "b1", at: 1, cwd: root))
        var ts = await store.snapshot().recentTouches
        #expect(ts.map(\.path.string) == ["Sources/A.swift"] && ts[0].kind == .read)
        await store.apply(bash("grep -rn x Sources Nope", id: "b2", at: 2, cwd: root))
        ts = await store.snapshot().recentTouches
        #expect(ts.count == 2 && ts[1].path == RepoPath(string: "Sources") && ts[1].scope == .directory)
        await store.apply(bash("echo x > Sources/New.swift", id: "b3", at: 3, cwd: root))
        ts = await store.snapshot().recentTouches
        #expect(ts.count == 3 && ts[2].path == RepoPath(string: "Sources/New.swift") && ts[2].kind == .write)
        await store.apply(line(.toolUse(id: "g1", name: "Grep", filePath: root + "/Gone", description: nil, question: nil), at: 4, cwd: root))
        await store.apply(line(.toolUse(id: "r1", name: "Read", filePath: root + "/Gone.swift", description: nil, question: nil), at: 5, cwd: root))
        ts = await store.snapshot().recentTouches
        #expect(ts.count == 4 && ts[3].source == .tool("Read"))       // file tools are recorded as before
    }

    func disk(_ paths: [String], at: TimeInterval, origin: Origin = .main) -> SourceEvent {
        .diskChanges(DiskChange(origin: origin, paths: paths.map(RepoPath.init(string:)), at: t0.addingTimeInterval(at)))
    }
    func settle(_ clock: TestClock, _ store: SessionStore, to at: TimeInterval) async -> StoreSnapshot {
        clock.now = t0.addingTimeInterval(at + Constants.diskAttributionDelay)
        return await store.snapshot()
    }

    @Test func diskChangeDuringOneAgentsCommandIsAttributed() async {
        let clock = TestClock(t0); let store = SessionStore(folder: folder, clock: clock.read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(.initialLoadComplete)
        await store.apply(bash("python3 gen.py", id: "b1", at: 0))
        await store.apply(disk(["Sources/Gen.swift"], at: 1))
        var snap = await store.snapshot()                       // not settled yet
        #expect(snap.recentTouches.isEmpty)
        snap = await settle(clock, store, to: 1)
        let t = snap.recentTouches
        #expect(t.count == 1 && t[0].path == RepoPath(string: "Sources/Gen.swift") && t[0].kind == .write && t[0].source == .disk && t[0].scope == .file)
        #expect(t[0].agent == AgentID("s1") && t[0].at == t0.addingTimeInterval(1) && snap.agents[0].touchCount == 1)
        snap = await settle(clock, store, to: 2)                // queue drained: nothing twice
        #expect(snap.recentTouches.count == 1)
    }

    @Test func diskChangeIsUnattributedWhenAmbiguousOrNobodyIsRunning() async {
        let clock = TestClock(t0); let store = SessionStore(folder: folder, clock: clock.read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(.initialLoadComplete)
        await store.apply(.sessionAppeared(sessionId: "s2", transcriptURL: URL(fileURLWithPath: "/p/s2.jsonl")))
        await store.apply(bash("make", id: "b1", at: 0))
        await store.apply(.line(sessionId: "s2", agentId: nil, TranscriptLine(timestamp: t0, cwd: "/repo", gitBranch: nil, agentId: nil,
                               event: .toolUse(id: "b2", name: "Bash", filePath: nil, description: nil, question: nil, command: "make"))))
        await store.apply(disk(["a.txt"], at: 1))
        #expect(await settle(clock, store, to: 1).recentTouches.isEmpty)        // two candidates
        await store.apply(line(.toolResult(toolUseId: "b1", text: "ok"), at: 2))
        await store.apply(.line(sessionId: "s2", agentId: nil, TranscriptLine(timestamp: t0.addingTimeInterval(2), cwd: "/repo", gitBranch: nil, agentId: nil, event: .toolResult(toolUseId: "b2", text: "ok"))))
        await store.apply(disk(["b.txt"], at: 10))
        #expect(await settle(clock, store, to: 10).recentTouches.isEmpty)       // both finished long before
    }

    @Test func diskChangeEchoOfAToolWriteIsDeduped() async {
        let clock = TestClock(t0); let store = SessionStore(folder: folder, clock: clock.read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(.initialLoadComplete)
        await store.apply(.sessionAppeared(sessionId: "s2", transcriptURL: URL(fileURLWithPath: "/p/s2.jsonl")))
        await store.apply(bash("swift build", id: "b1", at: 0))                             // s1 is running a command
        await store.apply(disk(["Sources/A.swift"], at: 1))                                 // s2's edit lands on disk first...
        await store.apply(.line(sessionId: "s2", agentId: nil, TranscriptLine(timestamp: t0.addingTimeInterval(0.8), cwd: "/repo", gitBranch: nil, agentId: nil,
                               event: .toolUse(id: "e2", name: "Edit", filePath: "/repo/Sources/A.swift", description: nil, question: nil))))   // ...its line arrives later
        let snap = await settle(clock, store, to: 1)
        #expect(snap.recentTouches.count == 1 && snap.recentTouches[0].source == .tool("Edit"))   // no disk touch for s1
    }

    @Test func completedCommandsStopBeingCandidatesAfterTheSlack() async {
        let clock = TestClock(t0); let store = SessionStore(folder: folder, clock: clock.read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(.initialLoadComplete)
        await store.apply(bash("swift build", id: "b1", at: 0))
        await store.apply(line(.toolResult(toolUseId: "b1", text: "ok"), at: 5))
        #expect(await store.snapshot().recentCommands[0].completedAt == t0.addingTimeInterval(5))
        await store.apply(disk(["x.txt"], at: 6))                                           // within slack of completion
        #expect(await settle(clock, store, to: 6).recentTouches.count == 1)
        await store.apply(disk(["y.txt"], at: 9))                                           // past the slack
        #expect(await settle(clock, store, to: 9).recentTouches.count == 1)
    }

    @Test func diskChangesInAWorktreeCarryItsName() async {
        let clock = TestClock(t0); let store = SessionStore(folder: folder, clock: clock.read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(.initialLoadComplete)
        await store.apply(bash("make", id: "b1", at: 0))
        await store.apply(disk(["Sources/G.swift"], at: 1, origin: .worktree("wt")))
        let t = await settle(clock, store, to: 1).recentTouches
        #expect(t.count == 1 && t[0].worktree == "wt")
    }

    func s2(_ event: TranscriptEvent, at: TimeInterval) -> SourceEvent {
        .line(sessionId: "s2", agentId: nil, TranscriptLine(timestamp: t0.addingTimeInterval(at), cwd: "/repo", gitBranch: nil, agentId: nil, event: event))
    }
    func loadedStore(_ clock: TestClock, sessions: [String] = ["s1"]) async -> SessionStore {
        let store = SessionStore(folder: folder, clock: clock.read)
        for sid in sessions { await store.apply(.sessionAppeared(sessionId: sid, transcriptURL: URL(fileURLWithPath: "/p/\(sid).jsonl"))) }
        await store.apply(.initialLoadComplete)
        return store
    }

    @Test func fileToolWriteIsEchoedUntilItsResultSettles() async {
        let clock = TestClock(t0); let store = await loadedStore(clock, sessions: ["s1", "s2"])
        await store.apply(bash("swift build", id: "b1", at: 0))                                   // s1 runs a command throughout
        await store.apply(s2(.toolUse(id: "e2", name: "Edit", filePath: "/repo/Sources/A.swift", description: nil, question: nil), at: 0))
        await store.apply(disk(["Sources/A.swift"], at: 5))                                       // lands while the Edit waits
        var t = await settle(clock, store, to: 5).recentTouches
        #expect(t.count == 1 && t[0].source == .tool("Edit"))
        await store.apply(s2(.toolResult(toolUseId: "e2", text: "ok"), at: 6))
        await store.apply(disk(["Sources/A.swift"], at: 7))                                       // within the window of the result
        t = await settle(clock, store, to: 7).recentTouches
        #expect(t.count == 1)
        await store.apply(disk(["Sources/A.swift"], at: 12))                                      // long after: s1's own change
        t = await settle(clock, store, to: 12).recentTouches
        #expect(t.count == 2 && t[1].source == .disk && t[1].agent == AgentID("s1"))
    }

    @Test func aCommandPushedOutOfTheRecentListStillCounts() async {
        let clock = TestClock(t0); let store = await loadedStore(clock, sessions: ["s1", "s2"])
        await store.apply(bash("swift test", id: "long", at: 0))                                  // s1's long command
        for i in 0...Constants.recentCommandLimit {
            await store.apply(s2(.toolUse(id: "x\(i)", name: "Bash", filePath: nil, description: nil, question: nil, command: "ls"), at: 0.5))
            await store.apply(s2(.toolResult(toolUseId: "x\(i)", text: "ok"), at: 1))
        }
        await store.apply(s2(.toolUse(id: "y", name: "Bash", filePath: nil, description: nil, question: nil, command: "make"), at: 9))
        let snap = await settle(clock, store, to: 9)
        #expect(!snap.recentCommands.contains { $0.agent == AgentID("s1") })
        await store.apply(disk(["Sources/Gen.swift"], at: 10))
        #expect(await settle(clock, store, to: 10).recentTouches.isEmpty)                         // both s1 and s2 are running
    }

    @Test func aCommandStopsCountingWhenItsAgentsTurnOrLifeEnds() async {
        let clock = TestClock(t0); let store = await loadedStore(clock)
        await store.apply(.subagentAppeared(sessionId: "s1", agentId: "A", meta: SubagentMeta(description: "A", toolUseId: "toolu_A")))
        await store.apply(.subagentAppeared(sessionId: "s1", agentId: "B", meta: SubagentMeta(description: "B", toolUseId: "toolu_B")))
        await store.apply(bash("make", id: "b1", at: 0))                                           // s1 keeps running
        await store.apply(bash("swift test", id: "a1", at: 0, agent: "A"))
        await store.apply(bash("swift test", id: "bb1", at: 0, agent: "B"))
        await store.apply(line(.turnEnded, at: 1, agent: "A"))                                      // no result ever came
        await store.apply(line(.toolResult(toolUseId: "toolu_B"), at: 1))                           // parent's result ends B...
        await store.apply(line(.assistantText(text: "more", endOfTurn: false), at: 2, agent: "B")) // ...and B's next line revives it
        var snap = await store.snapshot()
        #expect(snap.agents.first { $0.id == AgentID("A") }?.status != .ended)
        #expect(snap.agents.first { $0.id == AgentID("B") }?.status != .ended)
        await store.apply(disk(["x.txt"], at: 6))
        snap = await settle(clock, store, to: 6)
        #expect(snap.recentTouches.count == 1 && snap.recentTouches[0].agent == AgentID("s1"))
    }

    @Test func endedAgentGetsNoCredit() async {
        let clock = TestClock(t0); let store = await loadedStore(clock)
        await store.apply(.subagentAppeared(sessionId: "s1", agentId: "A", meta: SubagentMeta(description: "A", toolUseId: "toolu_A")))
        await store.apply(bash("python3 gen.py", id: "a1", at: 0, agent: "A"))
        await store.apply(line(.toolResult(toolUseId: "toolu_A"), at: 5))                           // A ends with its command
        await store.apply(disk(["Sources/Gen.swift"], at: 5.5))
        #expect(await settle(clock, store, to: 5.5).recentTouches.isEmpty)
    }

    @Test func diskChangesBeforeTheInitialLoadAreDropped() async {
        let clock = TestClock(t0); let store = SessionStore(folder: folder, clock: clock.read)
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(bash("make", id: "b1", at: 0))
        await store.apply(disk(["a.txt"], at: 1))
        await store.apply(.initialLoadComplete)
        #expect(await settle(clock, store, to: 1).recentTouches.isEmpty)
        await store.apply(disk(["b.txt"], at: 2))
        #expect(await settle(clock, store, to: 2).recentTouches.map(\.path.string) == ["b.txt"])
    }

    @Test func storeWithoutDiskEventsRecordsNoDiskTouches() async {
        let clock = TestClock(t0); let store = SessionStore(folder: folder, clock: clock.read)   // as in replay: no watcher
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await store.apply(bash("python3 gen.py > out.txt", id: "b1", at: 0))
        let snap = await settle(clock, store, to: 5)
        #expect(!snap.recentTouches.contains { $0.source == .disk })
        #expect(snap.recentTouches.map(\.path.string) == ["out.txt"])
    }

    @Test func bulkDiskChangesAreNotCredited() async {
        let clock = TestClock(t0); let store = await loadedStore(clock)
        await store.apply(bash("git checkout other", id: "b1", at: 0))
        await store.apply(disk((0...Constants.diskAttributionPathLimit).map { "f\($0).txt" }, at: 1))
        #expect(await settle(clock, store, to: 1).recentTouches.isEmpty)
        await store.apply(disk((1...Constants.diskAttributionPathLimit).map { "g\($0).txt" }, at: 2))
        #expect(await settle(clock, store, to: 2).recentTouches.count == Constants.diskAttributionPathLimit)
    }
}
