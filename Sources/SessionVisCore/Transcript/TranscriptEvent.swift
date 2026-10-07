import Foundation

/// The events one transcript record can yield.
public enum TranscriptEvent: Equatable, Sendable {
    case title(String)
    case relocated(cwd: String)
    case worktree(name: String, branch: String, path: String)
    case userPrompt(text: String)
    case toolUse(id: String, name: String, filePath: String?, description: String?, question: String?)
    case toolResult(toolUseId: String)
    case assistantText(text: String, endOfTurn: Bool)
    case turnEnded
    /// The user pressed Esc: `[Request interrupted by user…]`.
    case interrupted
    /// The parent's `<task-notification>` record for a background task; `taskId` is the subagent id for Agent tasks.
    case taskNotification(taskId: String, status: String)
}

public struct TranscriptLine: Equatable, Sendable {
    public var timestamp: Date?
    public var cwd: String?
    public var gitBranch: String?
    public var agentId: String?
    public var event: TranscriptEvent

    public init(timestamp: Date? = nil, cwd: String? = nil, gitBranch: String? = nil, agentId: String? = nil, event: TranscriptEvent) {
        self.timestamp = timestamp; self.cwd = cwd; self.gitBranch = gitBranch; self.agentId = agentId; self.event = event
    }
}
