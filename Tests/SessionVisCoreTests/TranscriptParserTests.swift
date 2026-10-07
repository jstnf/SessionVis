import Foundation
import Testing
@testable import SessionVisCore

@Suite struct TranscriptParserTests {
    func events(_ line: String) throws -> [TranscriptEvent] {
        try TranscriptParser.parse(line: line).map(\.event)
    }

    @Test func parsesTimestampWithAndWithoutFraction() {
        let a = TranscriptParser.parseTimestamp("2026-09-08T01:46:14.820Z")
        let b = TranscriptParser.parseTimestamp("2026-09-08T01:46:14Z")
        #expect(a != nil && b != nil)
        #expect(abs(a!.timeIntervalSince(b!) - 0.82) < 0.001)
        #expect(TranscriptParser.parseTimestamp("nope") == nil)
    }

    @Test func title() throws {
        #expect(try events(#"{"type":"ai-title","aiTitle":"Media page scroll performance","sessionId":"s1"}"#) == [.title("Media page scroll performance")])
    }

    @Test func relocatedAndWorktree() throws {
        #expect(try events(#"{"type":"relocated","sessionId":"s1","relocatedCwd":"/repo/.claude/worktrees/wt"}"#) == [.relocated(cwd: "/repo/.claude/worktrees/wt")])
        let wt = #"{"type":"worktree-state","worktreeSession":{"originalCwd":"/repo","worktreePath":"/repo/.claude/worktrees/wt","worktreeName":"wt","worktreeBranch":"worktree-wt","originalBranch":"main"},"sessionId":"s1"}"#
        #expect(try events(wt) == [.worktree(name: "wt", branch: "worktree-wt", path: "/repo/.claude/worktrees/wt")])
    }

    @Test func userPromptFromString() throws {
        let line = #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"Fix the scroll hitch"},"uuid":"u1","timestamp":"2026-09-08T01:42:05.584Z","cwd":"/repo","sessionId":"s1","version":"2.1.263","gitBranch":"main"}"#
        let parsed = try TranscriptParser.parse(line: line)
        #expect(parsed.count == 1)
        #expect(parsed[0].event == .userPrompt(text: "Fix the scroll hitch"))
        #expect(parsed[0].cwd == "/repo")
        #expect(parsed[0].gitBranch == "main")
        #expect(parsed[0].timestamp == TranscriptParser.parseTimestamp("2026-09-08T01:42:05.584Z"))
    }

    @Test func userPromptFromTextBlocks() throws {
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Look at "},{"type":"text","text":"this"}]},"timestamp":"2026-09-08T01:42:05.584Z","cwd":"/repo"}"#
        #expect(try events(line) == [.userPrompt(text: "Look at this")])
    }

    @Test func interruptMarkersEmitInterrupted() throws {
        let plain = #"{"type":"user","message":{"role":"user","content":"[Request interrupted by user]"},"timestamp":"2026-09-08T01:42:05.584Z","cwd":"/repo"}"#
        let forTool = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]},"timestamp":"2026-09-08T01:42:05.584Z","cwd":"/repo"}"#
        #expect(try events(plain) == [.interrupted])
        #expect(try events(forTool) == [.interrupted])
    }

    @Test func metaAndAngleBracketPromptsAreDropped() throws {
        let meta = #"{"type":"user","isMeta":true,"message":{"role":"user","content":"anything"},"timestamp":"2026-09-08T01:42:05.584Z"}"#
        let cmd = #"{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>"},"timestamp":"2026-09-08T01:42:05.584Z"}"#
        #expect(try events(meta) == [])
        #expect(try events(cmd) == [])
    }

    @Test func toolResultBlocksEmitResultsAndNoPrompt() throws {
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"},{"type":"tool_result","tool_use_id":"toolu_2","content":[{"type":"text","text":"x"}]}]},"timestamp":"2026-09-08T01:42:05.584Z","cwd":"/repo","toolUseResult":{"success":true}}"#
        #expect(try events(line) == [.toolResult(toolUseId: "toolu_1"), .toolResult(toolUseId: "toolu_2")])
    }

    @Test func toolUseFilePathsPerTool() throws {
        func use(_ name: String, _ input: String) -> String {
            #"{"type":"assistant","message":{"id":"m1","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_9","name":"\#(name)","input":\#(input)}]},"timestamp":"2026-09-08T01:46:14.820Z","cwd":"/repo"}"#
        }
        #expect(try events(use("Edit", #"{"file_path":"/repo/A.swift","old_string":"a","new_string":"b"}"#)) == [.toolUse(id: "toolu_9", name: "Edit", filePath: "/repo/A.swift", description: nil, question: nil)])
        #expect(try events(use("Read", #"{"file_path":"/repo/B.swift"}"#)) == [.toolUse(id: "toolu_9", name: "Read", filePath: "/repo/B.swift", description: nil, question: nil)])
        #expect(try events(use("NotebookEdit", #"{"notebook_path":"/repo/n.ipynb","new_source":""}"#)) == [.toolUse(id: "toolu_9", name: "NotebookEdit", filePath: "/repo/n.ipynb", description: nil, question: nil)])
        #expect(try events(use("Bash", #"{"command":"ls"}"#)) == [.toolUse(id: "toolu_9", name: "Bash", filePath: nil, description: nil, question: nil)])
        #expect(try events(use("Agent", #"{"description":"Research hitches","prompt":"..."}"#)) == [.toolUse(id: "toolu_9", name: "Agent", filePath: nil, description: "Research hitches", question: nil)])
        #expect(try events(use("AskUserQuestion", #"{"questions":[{"question":"Which layout?","header":"Layout","options":[]}]}"#)) == [.toolUse(id: "toolu_9", name: "AskUserQuestion", filePath: nil, description: nil, question: "Which layout?")])
    }

    @Test func assistantTextAndTurnEnded() throws {
        let mid = #"{"type":"assistant","message":{"id":"m1","role":"assistant","stop_reason":"tool_use","content":[{"type":"text","text":"Looking now."}]},"timestamp":"2026-09-08T01:46:14.820Z"}"#
        let end = #"{"type":"assistant","message":{"id":"m2","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done.\nDetails."}]},"timestamp":"2026-09-08T01:46:15.000Z"}"#
        let thinkingOnly = #"{"type":"assistant","message":{"id":"m2","role":"assistant","stop_reason":"end_turn","content":[{"type":"thinking","thinking":""}]},"timestamp":"2026-09-08T01:46:15.000Z"}"#
        let streaming = #"{"type":"assistant","message":{"id":"m3","role":"assistant","stop_reason":null,"content":[{"type":"text","text":"partial"}]},"timestamp":"2026-09-08T01:46:15.000Z"}"#
        #expect(try events(mid) == [.assistantText(text: "Looking now.", endOfTurn: false)])
        #expect(try events(end) == [.assistantText(text: "Done.\nDetails.", endOfTurn: true), .turnEnded])
        #expect(try events(thinkingOnly) == [.turnEnded])
        #expect(try events(streaming) == [.assistantText(text: "partial", endOfTurn: false)])
    }

    @Test func agentIdIsCarried() throws {
        let line = #"{"type":"assistant","isSidechain":true,"agentId":"a19f1a06b62d47fae","message":{"id":"m1","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"x"}]},"timestamp":"2026-09-08T01:46:14.820Z"}"#
        #expect(try TranscriptParser.parse(line: line).first?.agentId == "a19f1a06b62d47fae")
    }

    @Test func ignoredTypesYieldNothing() throws {
        #expect(try events(#"{"type":"mode","mode":"normal","sessionId":"s1"}"#) == [])
        #expect(try events(#"{"type":"system","subtype":"turn_duration","durationMs":1}"#) == [])
        #expect(try events(#"{"type":"attachment","attachment":{}}"#) == [])
    }

    @Test func malformedThrows() {
        #expect(throws: TranscriptParser.ParseError.self) { try TranscriptParser.parse(line: "{not json") }
        #expect(throws: TranscriptParser.ParseError.self) { try TranscriptParser.parse(line: "[1,2]") }
        #expect(throws: TranscriptParser.ParseError.self) { try TranscriptParser.parse(line: "") }
    }

    @Test func taskNotificationIsParsedAndOtherAngleBracketRecordsAreNot() throws {
        let note = #"{"type":"user","message":{"role":"user","content":"<task-notification>\n<task-id>a09957ce9fa9b473d</task-id>\n<tool-use-id>toolu_01K4</tool-use-id>\n<status>completed</status>\n<summary>Agent finished</summary>\n</task-notification>"},"timestamp":"2026-10-07T04:39:13.773Z","cwd":"/repo"}"#
        #expect(try events(note) == [.taskNotification(taskId: "a09957ce9fa9b473d", status: "completed")])
        let command = #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"},"timestamp":"2026-10-07T04:39:13.773Z","cwd":"/repo"}"#
        #expect(try events(command) == [])
        let noId = #"{"type":"user","message":{"role":"user","content":"<task-notification>\n<status>completed</status>\n</task-notification>"},"timestamp":"2026-10-07T04:39:13.773Z","cwd":"/repo"}"#
        #expect(try events(noId) == [])
    }

    @Test func queuedTaskNotificationIsParsedAndQueuedPromptIsNot() throws {
        let queued = #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-07T04:39:50.284Z","sessionId":"s1","content":"<task-notification>\n<task-id>ab7da679b7a576caa</task-id>\n<status>killed</status>\n<summary>Agent was stopped</summary>\n</task-notification>"}"#
        #expect(try events(queued) == [.taskNotification(taskId: "ab7da679b7a576caa", status: "killed")])
        let removed = #"{"type":"queue-operation","operation":"remove","timestamp":"2026-10-07T04:39:50.712Z","sessionId":"s1","content":"<task-notification>\n<task-id>ab7da679b7a576caa</task-id>\n<status>killed</status>\n</task-notification>"}"#
        #expect(try events(removed) == [])
        let prompt = #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-07T04:39:50.284Z","sessionId":"s1","content":"please also fix the tests"}"#
        #expect(try events(prompt) == [])
    }
}
