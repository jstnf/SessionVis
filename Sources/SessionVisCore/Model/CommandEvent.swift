import Foundation

public enum GitVerb: Equatable, Sendable { case commit, push, merge, rebase, other }

/// What a Bash command was for, judged from its leading verb.
public enum CommandClass: Equatable, Sendable {
    case git(GitVerb)
    case build, test, run, other

    public var milestone: Milestone? {
        switch self {
        case .git(.commit): .commit(nil)
        case .git(.push): .push
        case .git(.merge): .merge
        case .git(.rebase): .rebase
        default: nil
        }
    }
}

public struct CommitInfo: Equatable, Sendable {
    public let hash: String
    public let branch: String
    public let message: String
    public init(hash: String, branch: String, message: String) { self.hash = hash; self.branch = branch; self.message = message }
    public var shortHash: String { String(hash.prefix(7)) }
}

/// A git event worth marking on the orb and in the session list.
public enum Milestone: Equatable, Sendable {
    case commit(CommitInfo?)
    case push, merge, rebase

    public var line: String {
        switch self {
        case .commit(let info?): "committed \(info.shortHash) · \(info.message)"
        case .commit(nil): "committed"
        case .push: "pushed"
        case .merge: "merged"
        case .rebase: "rebased"
        }
    }
}

/// One Bash tool call, classified. `commit` is filled from the tool result when the command was a git commit.
public struct CommandEvent: Equatable, Sendable {
    public let seq: UInt64
    public let agent: AgentID
    public let at: Date
    public let commandClass: CommandClass
    public let label: String
    public let command: String
    public var commit: CommitInfo?
    public let hueIndex: Int

    public init(seq: UInt64, agent: AgentID, at: Date, commandClass: CommandClass, label: String, command: String, commit: CommitInfo? = nil, hueIndex: Int = 0) {
        self.seq = seq; self.agent = agent; self.at = at; self.commandClass = commandClass; self.label = label
        self.command = command; self.commit = commit; self.hueIndex = hueIndex
    }

    public var milestone: Milestone? {
        if case .git(.commit) = commandClass { return .commit(commit) }
        return commandClass.milestone
    }
}
