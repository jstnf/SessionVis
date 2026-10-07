import Foundation

public struct SubagentMeta: Equatable, Sendable, Codable {
    public var description: String
    public var agentType: String?
    public var model: String?
    public var toolUseId: String?
    public var spawnDepth: Int?
    public init(description: String, agentType: String? = nil, model: String? = nil, toolUseId: String? = nil, spawnDepth: Int? = nil) {
        self.description = description; self.agentType = agentType; self.model = model; self.toolUseId = toolUseId; self.spawnDepth = spawnDepth
    }
}

/// What both the live source and the replay source emit; the store consumes it.
public enum SourceEvent: Equatable, Sendable {
    case sessionAppeared(sessionId: String, transcriptURL: URL)
    case subagentAppeared(sessionId: String, agentId: String, meta: SubagentMeta)
    case line(sessionId: String, agentId: String?, TranscriptLine)
    case hook(HookEvent)
    case diagnostics(skippedLines: Int)
    /// The source has emitted everything already on disk at launch (live: first rescan + tick; replay: after `sessionAppeared`).
    case initialLoadComplete
}
