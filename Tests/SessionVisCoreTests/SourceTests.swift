import Foundation
import Testing
@testable import SessionVisCore

/// Reads one shared stream across several awaits. Tests only read events they know were already yielded, so no timeouts are needed.
final class EventReader: @unchecked Sendable {
    private var iterator: AsyncStream<SourceEvent>.Iterator
    init(_ stream: AsyncStream<SourceEvent>) { iterator = stream.makeAsyncIterator() }
    func next() async -> SourceEvent? { await iterator.next() }
    func collect(_ n: Int) async -> [SourceEvent] {
        var out: [SourceEvent] = []
        while out.count < n, let e = await next() { out.append(e) }
        return out
    }
}

enum SourceFixtures {
    static let t = "2026-09-08T01:42:05.584Z"
    static func userLine(_ text: String, cwd: String, ts: String = t) -> String {
        #"{"type":"user","message":{"role":"user","content":"\#(text)"},"timestamp":"\#(ts)","cwd":"\#(cwd)","sessionId":"s1"}"#
    }
    /// projects root with a member session s1 (with one subagent), a non-member s2, and a member s3 that is stale.
    static func makeProjects() throws -> (root: URL, s1: URL) {
        let root = URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path).appendingPathComponent("live-\(UUID().uuidString)")
        let proj = root.appendingPathComponent("-repo")
        try FileManager.default.createDirectory(at: proj.appendingPathComponent("s1/subagents"), withIntermediateDirectories: true)
        let s1 = proj.appendingPathComponent("s1.jsonl")
        try (userLine("hello", cwd: "/repo") + "\n").write(to: s1, atomically: true, encoding: .utf8)
        try (userLine("hello", cwd: "/other") + "\n").write(to: proj.appendingPathComponent("s2.jsonl"), atomically: true, encoding: .utf8)
        let s3 = proj.appendingPathComponent("s3.jsonl")
        try (userLine("old", cwd: "/repo") + "\n").write(to: s3, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 3600)], ofItemAtPath: s3.path)
        try (#"{"type":"assistant","agentId":"abc","message":{"id":"m","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"sub done"}]},"timestamp":"2026-09-08T01:42:06.000Z"}"# + "\n")
            .write(to: proj.appendingPathComponent("s1/subagents/agent-abc.jsonl"), atomically: true, encoding: .utf8)
        try #"{"agentType":"Explore","description":"look around","toolUseId":"toolu_1","spawnDepth":1}"#
            .write(to: proj.appendingPathComponent("s1/subagents/agent-abc.meta.json"), atomically: true, encoding: .utf8)
        return (root, s1)
    }
}

@Suite struct ReplayScheduleTests {
    func line(_ s: TimeInterval?, _ e: TranscriptEvent) -> TranscriptLine {
        TranscriptLine(timestamp: s.map { Date(timeIntervalSince1970: $0) }, event: e)
    }
    @Test func mergesSortsScalesAndCapsDelays() {
        let main = [line(0, .userPrompt(text: "a")), line(100, .turnEnded), line(nil, .title("t")), line(400, .userPrompt(text: "b"))]
        let sub = DiscoveredSubagent(agentId: "x", transcriptURL: URL(fileURLWithPath: "/x.jsonl"), meta: SubagentMeta(description: "d"))
        let subLines = [line(50, .assistantText(text: "hi", endOfTurn: false))]
        let sched = ReplaySource.schedule(sessionId: "s1", main: main, subagents: [(sub, subLines)], speed: 10)
        #expect(sched.map(\.delay) == [0, 0, 5, 0, 5, 0, 5])
        if case .sessionAppeared(let sid, _) = sched[0].event { #expect(sid == "s1") } else { Issue.record("expected sessionAppeared first") }
        #expect(sched[1].event == .line(sessionId: "s1", agentId: nil, main[0]))
        #expect(sched[2].event == .subagentAppeared(sessionId: "s1", agentId: "x", meta: sub.meta))   // at the subagent's first timestamp (50)
        #expect(sched[3].event == .line(sessionId: "s1", agentId: "x", subLines[0]))
        #expect(sched[4].event == .line(sessionId: "s1", agentId: nil, main[1]))
        #expect(sched[5].event == .line(sessionId: "s1", agentId: nil, main[2]))                     // nil timestamp inherits previous
        #expect(sched[6].event == .line(sessionId: "s1", agentId: nil, main[3]))
    }
}

@Suite struct ReplaySourceTests {
    @Test(.timeLimit(.minutes(1))) func replaysTranscriptAndSubagents() async throws {
        let (_, s1) = try SourceFixtures.makeProjects()
        let reader = EventReader(ReplaySource(transcriptURL: s1, speed: 1000).events())
        let events = await reader.collect(6)
        #expect(events.count == 6)
        if case .sessionAppeared(let sid, let url) = events[0] { #expect(sid == "s1" && url == s1) } else { Issue.record("expected sessionAppeared") }
        #expect(events[1] == .initialLoadComplete)
        #expect(events.contains { if case .subagentAppeared(_, let aid, _) = $0 { return aid == "abc" } else { return false } })
        let end = await reader.next()
        #expect(end == nil)   // stream finishes
    }

    @Test(.timeLimit(.minutes(1))) func replayedLinesAreRebasedToNow() async throws {
        let (_, s1) = try SourceFixtures.makeProjects()
        let reader = EventReader(ReplaySource(transcriptURL: s1, speed: 1000).events())
        var lines: [TranscriptLine] = []
        while let e = await reader.next() { if case .line(_, _, let l) = e { lines.append(l) } }
        #expect(!lines.isEmpty)
        for l in lines {
            let ts = try #require(l.timestamp)
            #expect(abs(ts.timeIntervalSinceNow) < 5)
        }
    }
}

@Suite struct LiveSourceTests {
    @Test(.timeLimit(.minutes(1))) func discoversMembersTailsAndIgnoresStaleOrForeign() async throws {
        let (root, s1) = try SourceFixtures.makeProjects()
        let spool = FileManager.default.temporaryDirectory.appendingPathComponent("spool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        let source = LiveSource(folder: PathFolder(root: "/repo"), projectsRoot: root, spoolDirectory: spool)
        let reader = EventReader(source.events)
        await source.rescan()
        await source.tick()
        // Expected: s1 appears, its subagent appears, then lines: s1's prompt, abc's text + turnEnded, then diagnostics.
        let first = await reader.collect(6)
        #expect(first[0] == .sessionAppeared(sessionId: "s1", transcriptURL: s1))
        if case .subagentAppeared(let sid, let aid, let meta) = first[1] { #expect(sid == "s1" && aid == "abc" && meta.description == "look around") } else { Issue.record("expected subagentAppeared, got \(first[1])") }
        #expect(first.contains { if case .line("s1", nil, let l) = $0 { return l.event == .userPrompt(text: "hello") } else { return false } })
        #expect(first.contains { if case .line("s1", "abc", let l) = $0 { return l.event == .turnEnded } else { return false } })
        #expect(first.last == .diagnostics(skippedLines: 0))
        #expect(!first.contains { if case .sessionAppeared(let sid, _) = $0 { return sid == "s2" || sid == "s3" } else { return false } })

        // Append to s1 and drop a hook file: both arrive on the next tick.
        let h = try FileHandle(forWritingTo: s1); try h.seekToEnd()
        try h.write(contentsOf: Data((SourceFixtures.userLine("second", cwd: "/repo", ts: "2026-09-08T01:43:00.000Z") + "\n").utf8)); try h.close()
        let hookFile = spool.appendingPathComponent("ev.1")
        try #"{"session_id":"s1","hook_event_name":"Stop","cwd":"/repo","last_assistant_message":"ok"}"#.write(to: hookFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-1)], ofItemAtPath: hookFile.path)
        await source.tick()
        // The file watcher on s1.jsonl may trigger an extra tick, so read until the hook shows up (bounded).
        var second: [SourceEvent] = []
        while second.count < 10, let e = await reader.next() {
            second.append(e)
            if case .hook = e { break }
        }
        #expect(second.contains { if case .line("s1", nil, let l) = $0 { return l.event == .userPrompt(text: "second") } else { return false } })
        #expect(second.contains { if case .hook(let e) = $0 { return e.name == "Stop" && e.sessionId == "s1" } else { return false } })
        await source.stop()
    }

    @Test(.timeLimit(.minutes(1))) func oldSubagentIsNotAnnouncedAndOnlyMainsAreFileWatched() async throws {
        let (root, _) = try SourceFixtures.makeProjects()
        let subs = root.appendingPathComponent("-repo/s1/subagents")
        let old = subs.appendingPathComponent("agent-old.jsonl")
        try (#"{"type":"assistant","agentId":"old","message":{"id":"m","role":"assistant","content":[{"type":"text","text":"x"}]},"timestamp":"2026-09-08T01:00:00.000Z"}"# + "\n")
            .write(to: old, atomically: true, encoding: .utf8)
        try #"{"description":"stale"}"#.write(to: subs.appendingPathComponent("agent-old.meta.json"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 3600)], ofItemAtPath: old.path)
        let source = LiveSource(folder: PathFolder(root: "/repo"), projectsRoot: root, spoolDirectory: nil)
        let reader = EventReader(source.events)
        await source.start()
        var events: [SourceEvent] = []
        while let e = await reader.next() {
            events.append(e)
            if e == .initialLoadComplete { break }
        }
        #expect(events.contains { if case .subagentAppeared(_, let aid, _) = $0 { return aid == "abc" } else { return false } })
        #expect(!events.contains { if case .subagentAppeared(_, let aid, _) = $0 { return aid == "old" } else { return false } })
        // initialLoadComplete follows the initial lines and diagnostics.
        #expect(events.contains { if case .line("s1", nil, let l) = $0 { return l.event == .userPrompt(text: "hello") } else { return false } })
        #expect(events.dropLast().last == .diagnostics(skippedLines: 0))
        #expect(await source.fileWatcherCount == 1)   // s1 only; subagent abc is polled
        await source.stop()
    }

    @Test(.timeLimit(.minutes(1))) func concurrentTicksKeepFileOrder() async throws {
        let (root, s1) = try SourceFixtures.makeProjects()
        let source = LiveSource(folder: PathFolder(root: "/repo"), projectsRoot: root, spoolDirectory: nil)
        let reader = EventReader(source.events)
        await source.rescan(); await source.tick()
        _ = await reader.collect(6)
        var body = ""
        for i in 0..<50 {
            body += #"{"type":"assistant","message":{"id":"m\#(i)","role":"assistant","content":[{"type":"tool_use","id":"tu\#(i)","name":"Bash","input":{}}]},"timestamp":"2026-09-08T01:44:00.000Z","cwd":"/repo"}"# + "\n"
        }
        let h = try FileHandle(forWritingTo: s1); try h.seekToEnd(); try h.write(contentsOf: Data(body.utf8)); try h.close()
        async let a: Void = source.tick()
        async let b: Void = source.tick()
        _ = await (a, b)
        var ids: [String] = []
        while ids.count < 50, let e = await reader.next() {
            if case .line("s1", nil, let l) = e, case .toolUse(let id, _, _, _, _) = l.event { ids.append(id) }
        }
        #expect(ids == (0..<50).map { "tu\($0)" })
        await source.stop()
    }

    @Test(.timeLimit(.minutes(1))) func newSessionIsPickedUpOnRescan() async throws {
        let (root, _) = try SourceFixtures.makeProjects()
        let source = LiveSource(folder: PathFolder(root: "/repo"), projectsRoot: root, spoolDirectory: nil)
        let reader = EventReader(source.events)
        await source.rescan(); await source.tick()
        _ = await reader.collect(6)
        let s9 = root.appendingPathComponent("-repo/s9.jsonl")
        try (SourceFixtures.userLine("new", cwd: "/repo") + "\n").write(to: s9, atomically: true, encoding: .utf8)
        await source.rescan(); await source.tick()
        let events = await reader.collect(3)
        #expect(events[0] == .sessionAppeared(sessionId: "s9", transcriptURL: s9))
        await source.stop()
    }

    @Test(.timeLimit(.minutes(1))) func newSessionWithoutCwdYetIsPickedUpOnceItHasOne() async throws {
        let (root, _) = try SourceFixtures.makeProjects()
        let source = LiveSource(folder: PathFolder(root: "/repo"), projectsRoot: root, spoolDirectory: nil)
        let reader = EventReader(source.events)
        let s7 = root.appendingPathComponent("-repo/s7.jsonl")
        try (#"{"type":"mode","mode":"normal"}"# + "\n").write(to: s7, atomically: true, encoding: .utf8)
        await source.rescan(); await source.tick()
        let initial = await reader.collect(6)
        #expect(!initial.contains { if case .sessionAppeared(let sid, _) = $0 { return sid == "s7" } else { return false } })
        let h = try FileHandle(forWritingTo: s7); try h.seekToEnd()
        try h.write(contentsOf: Data((SourceFixtures.userLine("late", cwd: "/repo") + "\n").utf8)); try h.close()
        await source.rescan(); await source.tick()
        var later: [SourceEvent] = []
        while later.count < 10, let e = await reader.next() {
            later.append(e)
            if case .sessionAppeared(let sid, _) = e, sid == "s7" { break }
        }
        #expect(later.contains { if case .sessionAppeared(let sid, _) = $0 { return sid == "s7" } else { return false } })
        await source.stop()
    }
}
