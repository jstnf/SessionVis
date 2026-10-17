import Foundation
import Testing
@testable import SessionVisCore

@Suite struct ContextUsageTests {
    @Test func shortFormatsTokens() {
        #expect(TokenFormat.short(0) == "0")
        #expect(TokenFormat.short(950) == "950")
        #expect(TokenFormat.short(999) == "999")
        #expect(TokenFormat.short(1_000) == "1k")
        #expect(TokenFormat.short(1_234) == "1.2k")
        #expect(TokenFormat.short(1_250) == "1.3k")
        #expect(TokenFormat.short(9_949) == "9.9k")
        #expect(TokenFormat.short(9_950) == "10k")
        #expect(TokenFormat.short(142_300) == "142k")
        #expect(TokenFormat.short(966_616) == "967k")
        #expect(TokenFormat.short(999_499) == "999k")
        #expect(TokenFormat.short(999_500) == "1M")
        #expect(TokenFormat.short(1_000_000) == "1M")
        #expect(TokenFormat.short(1_500_000) == "1.5M")
        #expect(TokenFormat.short(3_240_000) == "3.2M")
        #expect(TokenFormat.short(12_000_000) == "12M")
    }

    @Test func quantiseRoundsDownToTheQuantum() {
        #expect(TokenFormat.quantise(0) == 0)
        #expect(TokenFormat.quantise(99) == 0)
        #expect(TokenFormat.quantise(200) == 200)
        #expect(TokenFormat.quantise(142_399) == 142_300)
    }

    @Test func lookupMatchesByPrefix() {
        #expect(ContextWindow.lookup(model: "claude-fable-5-1") == 1_000_000)
        #expect(ContextWindow.lookup(model: "claude-sonnet-5-5") == 1_000_000)
        #expect(ContextWindow.lookup(model: "claude-haiku-5-5") == 1_000_000)
        #expect(ContextWindow.lookup(model: "claude-haiku-4-5-20251001") == 200_000)
        #expect(ContextWindow.lookup(model: "mystery-9") == nil)
        #expect(ContextWindow.lookup(model: "") == nil)
    }

    @Test func fittingBumpsToTheTierThatHoldsTheObservation() {
        #expect(ContextWindow.fitting(observed: 150_000, base: 200_000) == 200_000)
        #expect(ContextWindow.fitting(observed: 200_000, base: 200_000) == 200_000)
        #expect(ContextWindow.fitting(observed: 250_000, base: 200_000) == 1_000_000)
        #expect(ContextWindow.fitting(observed: 1_200_000, base: 1_000_000) == 1_000_000)
        #expect(ContextWindow.fitting(observed: 1_200_000, base: 200_000) == 1_000_000)
    }

    @Test func fillAndLineWithAndWithoutAWindow() {
        let c = ContextUsage(tokens: 142_300, window: 1_000_000)
        #expect(c.fill == 0.14)
        #expect(c.line == "142k / 1M · 14%")
        #expect(ContextUsage(tokens: 966_600, window: 1_000_000).fill == 0.97)
        #expect(ContextUsage(tokens: 0, window: 200_000).line == "0 / 200k · 0%")
        #expect(ContextUsage(tokens: 1_200_000, window: 1_000_000).fill == 1.2)
        let unknown = ContextUsage(tokens: 142_300, window: nil)
        #expect(unknown.fill == nil)
        #expect(unknown.line == "142k tokens")
        #expect(ContextUsage(tokens: 10, window: 0).fill == nil)
    }

    @Test func totalsLine() {
        #expect(TokenTotals(input: 3_240_000, output: 48_100).line == "in 3.2M · out 48k")
    }
}
