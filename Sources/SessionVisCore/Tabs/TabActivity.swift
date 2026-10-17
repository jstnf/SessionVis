import Foundation

/// What a tab's badge shows: how many main sessions are working and how many wait on the user.
public struct TabActivity: Equatable, Sendable {
    public var working: Int
    public var waiting: Int

    public init(working: Int = 0, waiting: Int = 0) {
        self.working = working
        self.waiting = waiting
    }

    /// Main sessions only; subagents live inside their parent's halo and ended sessions count for neither.
    public init(snapshot: StoreSnapshot) {
        var working = 0, waiting = 0
        for a in snapshot.agents where !a.isSubagent {
            switch a.status {
            case .working: working += 1
            case .waiting: waiting += 1
            case .idle, .ended: break
            }
        }
        self.init(working: working, waiting: waiting)
    }

    public var isQuiet: Bool { working == 0 && waiting == 0 }
}
