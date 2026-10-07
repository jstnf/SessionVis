import Foundation
import Testing
@testable import SessionVisCore

@Suite struct HookEventDecodingTests {
    let now = Date(timeIntervalSince1970: 2_000_000)

    @Test func decodesCommonAndSpecificFields() throws {
        let json = #"{"session_id":"s1","transcript_path":"/p/s1.jsonl","cwd":"/repo","hook_event_name":"Notification","permission_mode":"auto","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash","tool_name":"Bash"}"#
        let e = try #require(HookEvent(json: Data(json.utf8), receivedAt: now))
        #expect(e.name == "Notification" && e.sessionId == "s1" && e.cwd == "/repo" && e.transcriptPath == "/p/s1.jsonl")
        #expect(e.notificationType == "permission_prompt" && e.message == "Claude needs your permission to use Bash" && e.toolName == "Bash")
        #expect(e.receivedAt == now)
        let stop = try #require(HookEvent(json: Data(#"{"session_id":"s1","hook_event_name":"SubagentStop","agent_id":"abc","agent_type":"Explore","last_assistant_message":"done"}"#.utf8), receivedAt: now))
        #expect(stop.agentId == "abc" && stop.agentType == "Explore" && stop.lastAssistantMessage == "done")
    }

    @Test func rejectsMissingRequiredFields() {
        #expect(HookEvent(json: Data(#"{"cwd":"/repo"}"#.utf8), receivedAt: now) == nil)
        #expect(HookEvent(json: Data("garbage".utf8), receivedAt: now) == nil)
    }
}

@Suite struct HookSpoolReaderTests {
    func spoolDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("spool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    func write(_ dir: URL, _ name: String, _ body: String, mtime: Date) throws {
        let u = dir.appendingPathComponent(name)
        try body.write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: u.path)
    }
    let base = Date(timeIntervalSince1970: 3_000_000)

    @Test func drainsInMtimeOrderDeletesAndCountsMalformed() async throws {
        let d = try spoolDir()
        try write(d, "ev.b", #"{"session_id":"s1","hook_event_name":"Stop"}"#, mtime: base.addingTimeInterval(2))
        try write(d, "ev.a", #"{"session_id":"s1","hook_event_name":"UserPromptSubmit"}"#, mtime: base.addingTimeInterval(1))
        try write(d, "ev.c", "{broken", mtime: base.addingTimeInterval(3))
        let r = HookSpoolReader(directory: d)
        let events = await r.drain(now: base.addingTimeInterval(10))
        #expect(events.map(\.name) == ["UserPromptSubmit", "Stop"])
        #expect(events[0].receivedAt == base.addingTimeInterval(1))
        #expect(await r.malformedCount == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: d.path).isEmpty)
    }

    @Test func freshFilesAreLeftToSettle() async throws {
        let d = try spoolDir()
        try write(d, "ev.a", #"{"session_id":"s1","hook_event_name":"Stop"}"#, mtime: base)
        let r = HookSpoolReader(directory: d)
        #expect(await r.drain(now: base.addingTimeInterval(0.01)).isEmpty)
        #expect(await r.drain(now: base.addingTimeInterval(1)).count == 1)
    }

    @Test func pruneRemovesOnlyOldFiles() async throws {
        let d = try spoolDir()
        try write(d, "old", "{}", mtime: base.addingTimeInterval(-2 * 3600))
        try write(d, "new", "{}", mtime: base)
        let r = HookSpoolReader(directory: d)
        await r.pruneOld(now: base, age: Constants.hookPruneAge)
        #expect(try FileManager.default.contentsOfDirectory(atPath: d.path) == ["new"])
    }

    @Test func missingDirectoryIsHarmless() async {
        let r = HookSpoolReader(directory: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"))
        #expect(await r.drain(now: Date()).isEmpty)
    }
}

@Suite struct HookSnippetTests {
    @Test func snippetIsValidJSONAndListsEvents() throws {
        let obj = try #require(JSONSerialization.jsonObject(with: Data(HookSnippet.json.utf8)) as? [String: Any])
        #expect(obj["type"] as? String == "command")
        #expect(obj["command"] as? String == HookSnippet.command)
        #expect(HookSnippet.command.contains("SessionVis/hooks") && HookSnippet.command.contains("mktemp"))
        #expect(HookSnippet.events == ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "PermissionRequest", "Stop", "SubagentStop"])
    }

    @Test func commandIsGatedOnMarkerAndAlwaysExitsZero() throws {
        #expect(HookSnippet.command.contains(#"[ -e "$m" ]"#))
        #expect(HookSnippet.command.contains("SessionVis/active"))
        #expect(HookSnippet.command.hasSuffix("exit 0"))
        #expect(HookSnippet.markerURL(home: URL(fileURLWithPath: "/Users/me")).path == "/Users/me/Library/Application Support/SessionVis/active")
    }

    /// Runs the snippet under `sh` with `HOME` pointed at a temp dir; returns (exit status, files in the spool).
    func runSnippet(home: URL) throws -> (Int32, [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", HookSnippet.command]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        p.standardInput = input
        try p.run()
        input.fileHandleForWriting.write(Data(#"{"session_id":"s1","hook_event_name":"Stop"}"#.utf8))
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        let spool = home.appendingPathComponent("Library/Application Support/SessionVis/hooks")
        return (p.terminationStatus, (try? FileManager.default.contentsOfDirectory(atPath: spool.path)) ?? [])
    }

    @Test func commandWritesOnlyWhileMarkerExists() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var (status, files) = try runSnippet(home: home)
        #expect(status == 0 && files.isEmpty)
        let marker = HookSnippet.markerURL(home: home)
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        (status, files) = try runSnippet(home: home)
        #expect(status == 0 && files.count == 1)
    }

    @Test func installedCheckReadsSettingsFile() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString).json")
        #expect(!HookSnippet.isInstalled(settingsURL: u))
        try #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(HookSnippet.command.replacingOccurrences(of: "\"", with: "\\\""))"}]}]}}"#.write(to: u, atomically: true, encoding: .utf8)
        #expect(HookSnippet.isInstalled(settingsURL: u))
        #expect(HookSnippet.defaultSettingsURL(home: URL(fileURLWithPath: "/Users/me")).path == "/Users/me/.claude/settings.json")
    }
}

@Suite struct StoreHookApplicationTests {
    let folder = PathFolder(root: "/repo")
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    func hook(_ name: String, at s: TimeInterval, cwd: String = "/repo", sid: String = "s1", tool: String? = nil, message: String? = nil, type: String? = nil, last: String? = nil, agent: String? = nil) -> SourceEvent {
        .hook(HookEvent(name: name, sessionId: sid, cwd: cwd, receivedAt: at(s), toolName: tool, message: message, notificationType: type, lastAssistantMessage: last, agentId: agent))
    }
    func line(_ e: TranscriptEvent, at s: TimeInterval, agent: String? = nil) -> SourceEvent {
        .line(sessionId: "s1", agentId: agent, TranscriptLine(timestamp: at(s), cwd: "/repo", gitBranch: nil, agentId: agent, event: e))
    }
    func makeStore() async -> SessionStore {
        let s = SessionStore(folder: folder, clock: { [t0] in t0 })
        await s.apply(.sessionAppeared(sessionId: "s1", transcriptURL: URL(fileURLWithPath: "/p/s1.jsonl")))
        await s.apply(line(.userPrompt(text: "go"), at: 1))
        return s
    }

    @Test func hookForOtherRepoIsIgnored() async {
        let s = await makeStore()
        await s.apply(hook("Notification", at: 5, cwd: "/other", sid: "zzz", message: "perm", type: "permission_prompt"))
        let snap = await s.snapshot()
        #expect(snap.agents.count == 1 && snap.agents[0].status == .working)
        #expect(snap.hookEventsSeenAt == at(5))
    }

    @Test func permissionNotificationWaitsThenTranscriptResumes() async {
        let s = await makeStore()
        await s.apply(hook("Notification", at: 5, message: "Claude needs your permission to use Bash", type: "permission_prompt"))
        #expect(await s.snapshot().agents[0].status == .waiting(preview: "Claude needs your permission to use Bash"))
        await s.apply(line(.toolResult(toolUseId: "x"), at: 6))
        #expect(await s.snapshot().agents[0].status == .working)
    }

    @Test func unrelatedNotificationTypesAreIgnored() async {
        let s = await makeStore()
        await s.apply(hook("Notification", at: 5, message: "Signed in", type: "auth_success"))
        #expect(await s.snapshot().agents[0].status == .working)
    }

    @Test func permissionRequestStopSessionEnd() async {
        let s = await makeStore()
        await s.apply(hook("PermissionRequest", at: 5, tool: "Bash"))
        #expect(await s.snapshot().agents[0].status == .waiting(preview: "Permission: Bash"))
        await s.apply(hook("Stop", at: 6, last: "All done.\nMore."))
        #expect(await s.snapshot().agents[0].status == .idle(preview: "All done."))
        await s.apply(hook("SessionEnd", at: 7))
        #expect(await s.snapshot().agents[0].status == .ended)
    }

    @Test func olderHookDoesNotOverrideNewerStatus() async {
        let s = await makeStore()
        await s.apply(line(.toolUse(id: "q", name: "AskUserQuestion", filePath: nil, description: nil, question: "Which?"), at: 10))
        await s.apply(hook("PreToolUse", at: 9, tool: "Bash"))
        #expect(await s.snapshot().agents[0].status == .waiting(preview: "Which?"))
    }

    @Test func preToolUseForAskUserQuestionIsIgnored() async {
        let s = await makeStore()
        await s.apply(line(.toolUse(id: "q", name: "AskUserQuestion", filePath: nil, description: nil, question: "Which?"), at: 10))
        await s.apply(hook("PreToolUse", at: 10.5, tool: "AskUserQuestion"))
        #expect(await s.snapshot().agents[0].status == .waiting(preview: "Which?"))
    }

    @Test func subagentHooksTargetTheSubagent() async {
        let s = await makeStore()
        await s.apply(.subagentAppeared(sessionId: "s1", agentId: "abc", meta: SubagentMeta(description: "sub", toolUseId: "t")))
        await s.apply(hook("PreToolUse", at: 5, tool: "Bash", agent: "abc"))
        var snap = await s.snapshot()
        #expect(snap.agents.first { $0.id == AgentID("abc") }?.status == .working)
        await s.apply(hook("SubagentStop", at: 6, last: "finished", agent: "abc"))
        snap = await s.snapshot()
        #expect(snap.agents.first { $0.id == AgentID("abc") }?.status == .ended)
        #expect(snap.agents.first { $0.id == AgentID("s1") }?.status == .working)
        await s.apply(hook("SubagentStop", at: 7, agent: "unknown"))   // ignored, no crash
    }

    @Test func waitingHooksForUnknownMemberSessionCreateIt() async {
        let s = SessionStore(folder: folder, clock: { [t0] in t0 })
        await s.apply(hook("Notification", at: 1, sid: "n1", message: "perm", type: "permission_prompt"))
        await s.apply(hook("PermissionRequest", at: 1, sid: "p1", tool: "Bash"))
        await s.apply(hook("Notification", at: 1, sid: "x1", message: "Signed in", type: "auth_success"))   // not a waiting type
        let snap = await s.snapshot()
        #expect(snap.agents.map(\.id) == [AgentID("n1"), AgentID("p1")])
        #expect(snap.agents.first { $0.id == AgentID("n1") }?.status == .waiting(preview: "perm"))
        #expect(snap.agents.first { $0.id == AgentID("p1") }?.status == .waiting(preview: "Permission: Bash"))
    }

    @Test func sessionStartForUnknownSessionCreatesIt() async {
        let s = SessionStore(folder: folder, clock: { [t0] in t0 })
        await s.apply(hook("SessionStart", at: 1, sid: "new"))
        let snap = await s.snapshot()
        #expect(snap.agents.map(\.id) == [AgentID("new")])
    }

    @Test func postToolUseHookAfterHandbackDoesNotReviveSubagent() async {
        let store = SessionStore(folder: folder, clock: { [t0] in t0 })
        await store.apply(.sessionAppeared(sessionId: "s1", transcriptURL: URL(fileURLWithPath: "/p/s1.jsonl")))
        await store.apply(.subagentAppeared(sessionId: "s1", agentId: "A", meta: SubagentMeta(description: "A", toolUseId: "toolu_A")))
        await store.apply(line(.toolUse(id: "hb", name: "SubagentHandback", filePath: nil, description: nil, question: nil), at: 5, agent: "A"))
        await store.apply(hook("PostToolUse", at: 6, tool: "SubagentHandback", agent: "A"))
        var a = await store.snapshot().agents.first { $0.id == AgentID("A") }
        #expect(a?.status == .ended && a?.endedAt != nil)
        await store.apply(hook("UserPromptSubmit", at: 7, agent: "A"))
        a = await store.snapshot().agents.first { $0.id == AgentID("A") }
        #expect(a?.status == .working && a?.endedAt == nil)   // a prompt to the subagent is a resume
    }
}
