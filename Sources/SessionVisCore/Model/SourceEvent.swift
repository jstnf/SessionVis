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

/// Files the watcher saw change (added or rewritten) in one checkout, with the watcher's clock.
public struct DiskChange: Equatable, Sendable {
    public let origin: Origin
    public let paths: [RepoPath]
    public let at: Date
    public init(origin: Origin, paths: [RepoPath], at: Date) { self.origin = origin; self.paths = paths; self.at = at }
}

/// What both the live source and the replay source emit; the store consumes it.
public enum SourceEvent: Equatable, Sendable {
    case sessionAppeared(sessionId: String, transcriptURL: URL)
    case subagentAppeared(sessionId: String, agentId: String, meta: SubagentMeta)
    case line(sessionId: String, agentId: String?, TranscriptLine)
    case hook(HookEvent)
    case diagnostics(skippedLines: Int)
    case diskChanges(DiskChange)
    /// The source has emitted everything already on disk at launch (live: first rescan + tick; replay: after `sessionAppeared`).
    case initialLoadComplete
}
