import Foundation
import Testing
@testable import SessionVisCore

@Suite struct StatusMachineTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    @Test func startsIdleWithNoPreview() {
        let m = StatusMachine(at: t0)
        #expect(m.status == .idle(preview: nil))
        #expect(m.lastActivity == t0)
    }

    @Test func promptThenToolUseIsWorking() {
        var m = StatusMachine(at: t0)
        m.apply(.userPrompt(text: "go"), at: at(1))
        #expect(m.status == .working)
        m.apply(.toolUse(id: "a", name: "Bash", filePath: nil, description: nil, question: nil), at: at(2))
        #expect(m.status == .working)
        #expect(m.pending.map(\.id) == ["a"])
        #expect(m.lastActivity == at(2))
    }

    @Test func askUserQuestionWaitsWithPreviewAndSurvivesUnrelatedResults() {
        var m = StatusMachine(at: t0)
        m.apply(.toolUse(id: "b", name: "Bash", filePath: nil, description: nil, question: nil), at: at(1))
        m.apply(.toolUse(id: "q", name: "AskUserQuestion", filePath: nil, description: nil, question: "Which layout?"), at: at(2))
        #expect(m.status == .waiting(preview: "Which layout?"))
        m.apply(.toolResult(toolUseId: "b"), at: at(3))
        #expect(m.status == .waiting(preview: "Which layout?"))
        m.apply(.assistantText(text: "thinking aloud", endOfTurn: false), at: at(4))
        #expect(m.status == .waiting(preview: "Which layout?"))
        m.apply(.toolResult(toolUseId: "q"), at: at(5))
        #expect(m.status == .working)
        #expect(m.pending.isEmpty)
    }

    @Test func turnEndedWithNoPendingIsIdleWithFirstLinePreview() {
        var m = StatusMachine(at: t0)
        m.apply(.userPrompt(text: "go"), at: at(1))
        m.apply(.assistantText(text: "  First line here.\nSecond line.", endOfTurn: true), at: at(2))
        m.apply(.turnEnded, at: at(2))
        #expect(m.status == .idle(preview: "First line here."))
    }

    @Test func turnEndedWithPendingKeepsStatus() {
        var m = StatusMachine(at: t0)
        m.apply(.toolUse(id: "q", name: "AskUserQuestion", filePath: nil, description: nil, question: "Q?"), at: at(1))
        m.apply(.turnEnded, at: at(2))
        #expect(m.status == .waiting(preview: "Q?"))
    }

    @Test func previewIsTruncatedTo120() {
        let long = String(repeating: "x", count: 300)
        #expect(StatusMachine.firstLine(long)?.count == 120)
        #expect(StatusMachine.firstLine(nil) == nil)
        #expect(StatusMachine.firstLine("  \n\n") == nil)
    }

    @Test func newPromptClearsPending() {
        var m = StatusMachine(at: t0)
        m.apply(.toolUse(id: "q", name: "AskUserQuestion", filePath: nil, description: nil, question: "Q?"), at: at(1))
        m.apply(.userPrompt(text: "answer"), at: at(2))
        #expect(m.pending.isEmpty)
        #expect(m.status == .working)
    }

    @Test func interruptedGoesIdleAndClearsPending() {
        var m = StatusMachine(at: t0)
        m.apply(.userPrompt(text: "go"), at: at(1))
        m.apply(.toolUse(id: "a", name: "Bash", filePath: nil, description: nil, question: nil), at: at(2))
        #expect(m.status == .working && !m.pending.isEmpty)
        m.apply(.interrupted, at: at(3))
        #expect(m.status == .idle(preview: nil))
        #expect(m.pending.isEmpty)
    }

    @Test func historicalEventsApplyRegardlessOfInitTime() {
        var m = StatusMachine(at: at(3600))
        m.apply(.userPrompt(text: "go"), at: at(1))
        #expect(m.status == .working)
    }

    @Test func setRespectsTimestampPrecedence() {
        var m = StatusMachine(at: t0)
        m.apply(.userPrompt(text: "go"), at: at(10))
        #expect(m.set(.waiting(preview: "perm"), at: at(5)) == false)   // older: ignored
        #expect(m.status == .working)
        #expect(m.set(.waiting(preview: "perm"), at: at(10)) == true)   // equal: applied
        #expect(m.status == .waiting(preview: "perm"))
        m.apply(.toolResult(toolUseId: "x"), at: at(11))                   // newer transcript event wins
        #expect(m.status == .working)
        m.apply(.toolResult(toolUseId: "y"), at: at(9))                    // older transcript event does not downgrade statusAt
        #expect(m.statusAt == at(11))
    }

    @Test func ageEndsAfterWindow() {
        var m = StatusMachine(at: t0)
        m.apply(.userPrompt(text: "go"), at: at(1))
        m.age(now: at(1 + 29 * 60), window: 30 * 60)
        #expect(m.status == .working)
        m.age(now: at(1 + 31 * 60), window: 30 * 60)
        #expect(m.status == .ended)
    }

    @Test func touchKindForTool() {
        #expect(TouchKind.forTool("Edit") == .write)
        #expect(TouchKind.forTool("Write") == .write)
        #expect(TouchKind.forTool("NotebookEdit") == .write)
        #expect(TouchKind.forTool("Read") == .read)
        #expect(TouchKind.forTool("Bash") == nil)
    }

    @Test func paletteHasEightEntries() {
        #expect(HuePalette.hues.count == 8 && HuePalette.tints.count == 8)
    }
}
