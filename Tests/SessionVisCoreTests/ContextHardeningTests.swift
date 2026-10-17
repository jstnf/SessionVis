import Foundation
import Testing
@testable import SessionVisCore

@Suite struct ContextHardeningTests {
    let folder = PathFolder(root: "/repo", worktrees: [])
    let url = URL(fileURLWithPath: "/p/s1.jsonl")
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func line(_ event: TranscriptEvent, at: TimeInterval?) -> SourceEvent {
        .line(sessionId: "s1", agentId: nil, TranscriptLine(timestamp: at.map { t0.addingTimeInterval($0) }, cwd: "/repo", gitBranch: "main", event: event))
    }
    func usage(_ id: String, model: String? = "claude-fable-5-1", input: Int, output: Int = 1, at: TimeInterval?) -> SourceEvent {
        line(.usage(messageID: id, model: model, input: input, output: output, cacheRead: 0, cacheCreate: 0), at: at)
    }
    func events(_ s: String) throws -> [TranscriptEvent] { try TranscriptParser.parse(line: s).map(\.event) }
    func record(_ usage: String, model: String? = "claude-fable-5-1") -> String {
        let m = model.map { #""model":"\#($0)","# } ?? ""
        return #"{"type":"assistant","timestamp":"2026-10-17T05:39:05.246Z","message":{"id":"msg_1",\#(m)"content":[],"usage":{\#(usage)}}}"#
    }
    func store() async -> SessionStore {
        let s = SessionStore(folder: folder, clock: TestClock().read)
        await s.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        return s
    }

    // MARK: store

    @Test func lateRecordOfAnotherModelLeavesModelWindowAndContextUntouched() async {
        let s = await store()
        await s.apply(usage("m1", input: 500_000, at: 10))
        await s.apply(usage("m2", model: "claude-haiku-4-5-20251001", input: 50_000, at: 5))
        let a = await s.snapshot().agents[0]
        #expect(a.model == "claude-fable-5-1")
        #expect(a.context == ContextUsage(tokens: 500_000, window: 1_000_000))
    }

    @Test func modelChangeRefitsTheWindowAgainstTheCurrentContext() async {
        let s = await store()
        await s.apply(usage("m1", input: 500_000, at: 1))
        await s.apply(usage("m2", model: "claude-haiku-4-5-20251001", input: 300_000, at: 2))
        let a = await s.snapshot().agents[0]
        #expect(a.context == ContextUsage(tokens: 300_000, window: 1_000_000))
        #expect((a.context?.fill ?? 0) <= 1)
    }

    @Test func hugeCountsDoNotTrapTheStore() async throws {
        let s = await store()
        let huge = #""input_tokens":9223372036854775807,"output_tokens":9223372036854775807,"cache_read_input_tokens":1,"cache_creation_input_tokens":9223372036854775807"#
        for l in try TranscriptParser.parse(line: record(huge)) { await s.apply(.line(sessionId: "s1", agentId: nil, l)) }
        await s.apply(line(.usage(messageID: "m2", model: "claude-fable-5-1", input: Int.max, output: Int.max, cacheRead: Int.max, cacheCreate: Int.max), at: 100))
        await s.apply(line(.compacted(pre: Int.max, post: Int.max), at: 200))
        await s.apply(line(.usage(messageID: "m3", model: "claude-fable-5-1", input: Int.min, output: -5, cacheRead: -1, cacheCreate: 0), at: 300))
        let a = await s.snapshot().agents[0]
        #expect(a.context?.tokens == Constants.tokenCountCap)   // the first record carries a later timestamp than the rest
        #expect(a.tokens != nil && a.tokens!.input <= Constants.tokenCountCap * 100)
        #expect(!(a.tokens!.line.isEmpty))
    }

    @Test func compactionDoesNotReviveOrBumpAnEndedMain() async {
        let clock = TestClock()
        let s = SessionStore(folder: folder, clock: clock.read)
        await s.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await s.apply(line(.userPrompt(text: "hi"), at: 0))
        await s.apply(line(.turnEnded, at: 1))
        clock.advance(Constants.activeWindow + 10)
        let before = await s.snapshot().agents[0]
        #expect(before.status == .ended)
        await s.apply(line(.compacted(pre: 100, post: 10), at: Constants.activeWindow + 20))
        let after = await s.snapshot().agents[0]
        #expect(after.status == .ended)
        #expect(after.lastActivity == before.lastActivity)
        #expect(after.context?.tokens == 0)   // quantised 10
    }

    @Test func usageRecordMayReviveAnAgedMain() async {
        let clock = TestClock()
        let s = SessionStore(folder: folder, clock: clock.read)
        await s.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await s.apply(line(.userPrompt(text: "hi"), at: 0))
        await s.apply(line(.turnEnded, at: 1))
        clock.advance(Constants.activeWindow + 10)
        #expect(await s.snapshot().agents[0].status == .ended)
        await s.apply(usage("m1", input: 10, at: Constants.activeWindow + 20))
        #expect(await s.snapshot().agents[0].status != .ended)
    }

    @Test func recordsWithoutTimestampUpdateTotalsOnly() async {
        let s = await store()
        await s.apply(usage("m1", input: 5_000, output: 7, at: 1))
        await s.apply(usage("m2", model: "claude-haiku-4-5-20251001", input: 900_000, output: 3, at: nil))
        await s.apply(line(.compacted(pre: 1, post: 40_000), at: nil))
        let a = await s.snapshot().agents[0]
        #expect(a.context == ContextUsage(tokens: 5_000, window: 1_000_000))
        #expect(a.model == "claude-fable-5-1")
        #expect(a.tokens == TokenTotals(input: 905_000, output: 0))
    }

    @Test func recordWithoutModelKeepsThePreviousModel() async {
        let s = await store()
        await s.apply(usage("m1", input: 5_000, at: 1))
        await s.apply(usage("m2", model: nil, input: 8_000, at: 2))
        let a = await s.snapshot().agents[0]
        #expect(a.model == "claude-fable-5-1")
        #expect(a.context == ContextUsage(tokens: 8_000, window: 1_000_000))
    }

    @Test func compactionNeverCreatesRevivesOrBumpsARecord() async {
        let clock = TestClock()
        let s = SessionStore(folder: folder, clock: clock.read)
        await s.apply(line(.compacted(pre: 1, post: 5_000), at: 1))   // no record yet: nothing is created
        #expect(await s.snapshot().agents.isEmpty)
        await s.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await s.apply(line(.userPrompt(text: "hi"), at: 0))
        await s.apply(line(.turnEnded, at: 1))
        clock.advance(Constants.activeWindow + 2)
        _ = await s.snapshot()   // main ends
        clock.advance(Constants.endedLinger + 1)
        #expect(await s.snapshot().agents.isEmpty)   // retired   // aged out and retired
        await s.apply(line(.compacted(pre: 100, post: 9_000), at: Constants.activeWindow + 20))
        #expect(await s.snapshot().agents.isEmpty)   // still retired
        await s.apply(line(.userPrompt(text: "back"), at: Constants.activeWindow + 30))
        let a = await s.snapshot().agents[0]
        #expect(a.context?.tokens == 9_000)           // the compaction was applied to the retired record
        #expect(a.lastActivity == t0.addingTimeInterval(Constants.activeWindow + 30))
    }

    @Test func untimedUsageNeverCreatesRevivesOrBumpsARecord() async {
        let clock = TestClock()
        let s = SessionStore(folder: folder, clock: clock.read)
        await s.apply(usage("m0", input: 10, at: nil))
        #expect(await s.snapshot().agents.isEmpty)
        await s.apply(.sessionAppeared(sessionId: "s1", transcriptURL: url))
        await s.apply(line(.userPrompt(text: "hi"), at: 0))
        await s.apply(line(.turnEnded, at: 1))
        clock.advance(Constants.activeWindow + 2)
        _ = await s.snapshot()   // main ends
        clock.advance(Constants.endedLinger + 1)
        #expect(await s.snapshot().agents.isEmpty)   // retired
        await s.apply(usage("m1", input: 7_000, output: 300, at: nil))
        #expect(await s.snapshot().agents.isEmpty)
        await s.apply(line(.userPrompt(text: "back"), at: Constants.activeWindow + 30))
        let a = await s.snapshot().agents[0]
        #expect(a.tokens == TokenTotals(input: 7_000, output: 300))
        #expect(a.context == nil)
        #expect(a.lastActivity == t0.addingTimeInterval(Constants.activeWindow + 30))
    }

    @Test func contextAboveTheTopTierKeepsTheTopTierWindow() async {
        let s = await store()
        await s.apply(usage("m1", input: 1_300_000, at: 1))
        let a = await s.snapshot().agents[0]
        #expect(a.context == ContextUsage(tokens: 1_300_000, window: 1_000_000))
        #expect(a.context?.line == "1.3M / 1M · 130%")
    }

    // MARK: parser

    @Test func nonNumericCountsReadAsZero() throws {
        func parsed(_ u: String) throws -> TranscriptEvent {
            try #require(try events(record(u)).first)
        }
        #expect(try parsed(#""input_tokens":true,"output_tokens":false,"cache_read_input_tokens":"12","cache_creation_input_tokens":4"#)
                == .usage(messageID: "msg_1", model: "claude-fable-5-1", input: 0, output: 0, cacheRead: 0, cacheCreate: 4))
        #expect(try parsed(#""input_tokens":12.5,"output_tokens":3.0"#)
                == .usage(messageID: "msg_1", model: "claude-fable-5-1", input: 0, output: 3, cacheRead: 0, cacheCreate: 0))
    }

    @Test func negativeAndHugeCountsClamp() throws {
        #expect(try events(record(#""input_tokens":-500,"output_tokens":-1,"cache_read_input_tokens":9223372036854775807"#))
                == [.usage(messageID: "msg_1", model: "claude-fable-5-1", input: 0, output: 0, cacheRead: Constants.tokenCountCap, cacheCreate: 0)])
        let compact = #"{"type":"system","subtype":"compact_boundary","timestamp":"2026-10-17T07:09:34.570Z","compactMetadata":{"preTokens":true,"postTokens":-5}}"#
        #expect(try events(compact) == [.compacted(pre: 0, post: 0)])
    }

    @Test func recordWithoutModelStillYieldsUsage() throws {
        #expect(try events(record(#""input_tokens":1,"output_tokens":2"#, model: nil))
                == [.usage(messageID: "msg_1", model: nil, input: 1, output: 2, cacheRead: 0, cacheCreate: 0)])
    }

    // MARK: formatting

    @Test func formattingNeverTraps() {
        #expect(!TokenFormat.short(Int.max).isEmpty)
        #expect(TokenFormat.short(Int.min) == "0")
        #expect(TokenFormat.short(-1_500) == "0")
        #expect(TokenFormat.quantise(Int.max) == Constants.tokenCountCap)
        #expect(TokenFormat.quantise(-150) == 0)
    }

    @Test func quantiseFloorsJustAboveABoundary() {
        #expect(TokenFormat.quantise(101) == 100)
        #expect(TokenFormat.quantise(199) == 100)
        #expect(TokenFormat.quantise(200) == 200)
        #expect(TokenFormat.quantise(142_301) == 142_300)
    }
}
