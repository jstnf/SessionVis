import Foundation

public struct AgentID: Hashable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
}

public enum AgentKind: Equatable, Sendable {
    case main
    case subagent(parent: AgentID, description: String, agentType: String?, model: String?)
}

public enum Status: Equatable, Sendable {
    case working
    case waiting(preview: String)
    case idle(preview: String?)
    case ended

    public var word: String {
        switch self {
        case .working: "working"
        case .waiting: "waiting"
        case .idle: "idle"
        case .ended: "ended"
        }
    }
    public var isWaiting: Bool { if case .waiting = self { return true } else { return false } }
    public var isEnded: Bool { self == .ended }
}

public enum TouchKind: Equatable, Sendable {
    case write, read
    /// The kind of file access a tool call represents, or nil for tools that do not touch files.
    public static func forTool(_ name: String) -> TouchKind? {
        switch name {
        case "Edit", "Write", "NotebookEdit": .write
        case "Read": .read
        default: nil
        }
    }
}

public struct Touch: Equatable, Sendable {
    public let seq: UInt64
    public let agent: AgentID
    public let path: RepoPath
    public let worktree: String?
    public let kind: TouchKind
    public let at: Date
    public let hueIndex: Int
    public let agentTitle: String?
    public init(seq: UInt64, agent: AgentID, path: RepoPath, worktree: String?, kind: TouchKind, at: Date, hueIndex: Int = 0, agentTitle: String? = nil) {
        self.seq = seq; self.agent = agent; self.path = path; self.worktree = worktree; self.kind = kind; self.at = at
        self.hueIndex = hueIndex; self.agentTitle = agentTitle
    }
}

public struct AgentSnapshot: Equatable, Sendable, Identifiable {
    public let id: AgentID
    public let kind: AgentKind
    public let title: String
    public let status: Status
    public let hueIndex: Int
    public let branch: String?
    public let worktree: String?
    public let firstSeen: Date
    public let lastActivity: Date
    public let endedAt: Date?
    public let touchCount: Int

    public init(id: AgentID, kind: AgentKind, title: String, status: Status, hueIndex: Int, branch: String?, worktree: String?, firstSeen: Date, lastActivity: Date, endedAt: Date?, touchCount: Int) {
        self.id = id; self.kind = kind; self.title = title; self.status = status; self.hueIndex = hueIndex
        self.branch = branch; self.worktree = worktree; self.firstSeen = firstSeen; self.lastActivity = lastActivity
        self.endedAt = endedAt; self.touchCount = touchCount
    }

    public var isSubagent: Bool { if case .subagent = kind { return true } else { return false } }
    public var parent: AgentID? { if case .subagent(let p, _, _, _) = kind { return p } else { return nil } }
}

public struct StoreSnapshot: Equatable, Sendable {
    public var agents: [AgentSnapshot]
    public var recentTouches: [Touch]
    public var hookEventsSeenAt: Date?
    public var skippedLines: Int

    public init(agents: [AgentSnapshot] = [], recentTouches: [Touch] = [], hookEventsSeenAt: Date? = nil, skippedLines: Int = 0) {
        self.agents = agents; self.recentTouches = recentTouches; self.hookEventsSeenAt = hookEventsSeenAt; self.skippedLines = skippedLines
    }
    public static let empty = StoreSnapshot()
}

/// Session hues and their lighter tints. RGB in 0…1.
public enum HuePalette {
    public typealias RGB = (r: Double, g: Double, b: Double)
    public static let count = 8
    public static let hues: [RGB] = [
        rgb(0xF0A040), rgb(0x5B9CF5), rgb(0x6FCF7B), rgb(0xF06C9B),
        rgb(0xA578F0), rgb(0x3FC9C0), rgb(0xE6C84A), rgb(0xF0605A),
    ]
    public static let tints: [RGB] = [
        rgb(0xF7C98A), rgb(0xA9C8FA), rgb(0xB5E6BB), rgb(0xF7B5CB),
        rgb(0xD1BCF7), rgb(0x9EE4E0), rgb(0xF2E2A3), rgb(0xF7AFAC),
    ]
    public static func hue(_ i: Int) -> RGB { hues[((i % count) + count) % count] }
    public static func tint(_ i: Int) -> RGB { tints[((i % count) + count) % count] }
    public static func rgb(_ hex: UInt32) -> RGB {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
}
