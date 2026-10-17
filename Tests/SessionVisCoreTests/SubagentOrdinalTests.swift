import Foundation
import Testing
@testable import SessionVisCore

@Suite struct SubagentOrdinalTests {
    let folder = PathFolder(root: "/repo")

    func makeSession() throws -> (root: URL, subs: URL) {
        let root = URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path).appendingPathComponent("ord-\(UUID().uuidString)")
        let proj = root.appendingPathComponent("-repo")
        let subs = proj.appendingPathComponent("s1/subagents")
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
        try (SourceFixtures.userLine("hello", cwd: "/repo") + "\n").write(to: proj.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        return (root, subs)
    }
    func addSub(_ id: String, in subs: URL, born: TimeInterval, meta: Bool = true) throws {
        let log = subs.appendingPathComponent("agent-\(id).jsonl")
        try (#"{"type":"assistant","agentId":"\#(id)","message":{"id":"m","role":"assistant","content":[{"type":"text","text":"x"}]},"timestamp":"2026-09-08T01:00:00.000Z"}"# + "\n").write(to: log, atomically: true, encoding: .utf8)
        if meta { try writeMeta(id, in: subs) }
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: born)], ofItemAtPath: log.path)
    }
    func writeMeta(_ id: String, in subs: URL) throws {
        try #"{"description":"\#(id)"}"#.write(to: subs.appendingPathComponent("agent-\(id).meta.json"), atomically: true, encoding: .utf8)
    }
    func shades(_ store: SessionStore) async -> [String: Int] {
        var out: [String: Int] = [:]
        for a in await store.snapshot().agents { out[a.id.raw] = a.shade }
        return out
    }
    /// Reads events into `store` until `done` matches one.
    func pump(_ reader: EventReader, into store: SessionStore, until done: (SourceEvent) -> Bool) async {
        while let e = await reader.next() { await store.apply(e); if done(e) { break } }
    }
    func launchShades(root: URL) async -> [String: Int] {
        let source = LiveSource(folder: folder, projectsRoot: root, spoolDirectory: nil)
        let reader = EventReader(source.events)
        let store = SessionStore(folder: folder)
        await source.start()
        await pump(reader, into: store) { $0 == .initialLoadComplete }
        await source.stop()
        return await shades(store)
    }

    @Test(.timeLimit(.minutes(1))) func metaWrittenLateStillEndsWithDistinctOrdinalsMatchingARelaunch() async throws {
        let (root, subs) = try makeSession()
        try addSub("X", in: subs, born: 1_000, meta: false)
        try addSub("Y", in: subs, born: 2_000)
        let source = LiveSource(folder: folder, projectsRoot: root, spoolDirectory: nil)
        let reader = EventReader(source.events)
        let store = SessionStore(folder: folder)
        await source.start()
        await pump(reader, into: store) { $0 == .initialLoadComplete }
        #expect(await shades(store)["Y"] == 2)                       // X holds rank 1 although it has no metadata yet
        try writeMeta("X", in: subs)
        await source.rescan()
        await pump(reader, into: store) { if case .subagentAppeared(_, "X", _, _) = $0 { return true } else { return false } }
        await source.stop()
        let live = await shades(store)
        #expect(live["X"] == 1 && live["Y"] == 2)
        #expect(live == (await launchShades(root: root)))
    }

    @Test(.timeLimit(.minutes(1))) func deletedTranscriptShiftsTheRestAndANewSiblingGetsADistinctRank() async throws {
        let (root, subs) = try makeSession()
        for (i, id) in ["A", "B", "C"].enumerated() { try addSub(id, in: subs, born: TimeInterval(1_000 * (i + 1))) }
        let source = LiveSource(folder: folder, projectsRoot: root, spoolDirectory: nil)
        let reader = EventReader(source.events)
        let store = SessionStore(folder: folder)
        await source.start()
        await pump(reader, into: store) { $0 == .initialLoadComplete }
        try FileManager.default.removeItem(at: subs.appendingPathComponent("agent-A.jsonl"))
        try FileManager.default.removeItem(at: subs.appendingPathComponent("agent-A.meta.json"))
        try addSub("D", in: subs, born: 4_000)
        await source.rescan()
        await pump(reader, into: store) { if case .subagentAppeared(_, "D", _, _) = $0 { return true } else { return false } }
        await source.stop()
        let live = await shades(store)
        #expect(live["B"] == 1 && live["C"] == 2 && live["D"] == 3)
    }

    @Test func replayUsesTheDiscoveryRankNotFirstLineTime() {
        func sub(_ id: String, _ ordinal: Int) -> DiscoveredSubagent {
            DiscoveredSubagent(agentId: id, transcriptURL: URL(fileURLWithPath: "/x/\(id).jsonl"), meta: SubagentMeta(description: id), ordinal: ordinal)
        }
        let main = [TranscriptLine(timestamp: Date(timeIntervalSince1970: 10), event: .userPrompt(text: "hi"))]
        let aLines = [TranscriptLine(timestamp: Date(timeIntervalSince1970: 20), event: .userPrompt(text: "a"))]
        let sched = ReplaySource.schedule(sessionId: "s1", main: main, subagents: [(sub("A", 1), aLines), (sub("B", 2), [])], speed: 1)
        var got: [String: Int] = [:]
        for s in sched { if case .subagentAppeared(_, let aid, _, let o) = s.event { got[aid] = o } }
        #expect(got == ["A": 1, "B": 2])
    }

    @Test func discoveryRanksTranscriptsWhoseMetadataIsMissing() throws {
        let (root, subs) = try makeSession()
        try addSub("X", in: subs, born: 1_000, meta: false)
        try addSub("Y", in: subs, born: 2_000)
        let found = SessionDiscovery.listSubagents(sessionTranscriptURL: root.appendingPathComponent("-repo/s1.jsonl"))
        #expect(found.map(\.agentId) == ["Y"] && found.map(\.ordinal) == [2])
    }
}
