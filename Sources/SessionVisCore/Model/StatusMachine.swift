import Foundation

public struct PendingTool: Equatable, Sendable {
    public let id: String
    public let name: String
    public let question: String?
}

/// Per-agent status derivation with timestamp precedence.
public struct StatusMachine: Equatable, Sendable {
    public private(set) var status: Status
    public private(set) var statusAt: Date
    public private(set) var lastActivity: Date
    public private(set) var lastAssistantText: String?
    public private(set) var pending: [PendingTool] = []

    /// `at` seeds `lastActivity` only. `statusAt` starts at `.distantPast` so historical transcript lines
    /// (older than the store clock) still drive status.
    public init(at: Date) {
        status = .idle(preview: nil)
        statusAt = .distantPast
        lastActivity = at
    }

    public mutating func apply(_ event: TranscriptEvent, at t: Date) {
        lastActivity = max(lastActivity, t)
        switch event {
        case .userPrompt:
            pending.removeAll()
            set(.working, at: t)
        case .toolUse(let id, let name, _, _, let question):
            pending.append(PendingTool(id: id, name: name, question: question))
            if name == "AskUserQuestion" { set(.waiting(preview: question ?? "Question"), at: t) }
            else { set(.working, at: t) }
        case .toolResult(let id):
            pending.removeAll { $0.id == id }
            if let q = pending.first(where: { $0.name == "AskUserQuestion" }) {
                set(.waiting(preview: q.question ?? "Question"), at: t)
            } else {
                set(.working, at: t)
            }
        case .assistantText(let text, let endOfTurn):
            lastAssistantText = text
            if !endOfTurn, !status.isWaiting { set(.working, at: t) }
        case .turnEnded:
            if pending.isEmpty { set(.idle(preview: StatusMachine.firstLine(lastAssistantText)), at: t) }
        case .interrupted:
            pending.removeAll()
            set(.idle(preview: nil), at: t)
        case .title, .relocated, .worktree, .taskNotification:
            break
        }
    }

    /// Applies `status` only if `t >= statusAt`. Returns whether it applied.
    @discardableResult
    public mutating func set(_ new: Status, at t: Date) -> Bool {
        guard t >= statusAt else { return false }
        status = new
        statusAt = t
        return true
    }

    public mutating func setLastAssistantText(_ text: String?) { if let text { lastAssistantText = text } }

    public mutating func age(now: Date, window: TimeInterval) {
        guard status != .ended, now.timeIntervalSince(lastActivity) > window else { return }
        status = .ended
        statusAt = max(statusAt, now)
    }

    public mutating func end(at t: Date) {
        status = .ended
        statusAt = max(statusAt, t)
    }

    public mutating func touch(at t: Date) { lastActivity = max(lastActivity, t) }

    public static func firstLine(_ s: String?) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first else { return nil }
        let line = first.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : String(line.prefix(120))
    }
}
