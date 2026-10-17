import Foundation
import Testing
@testable import SessionVisCore

@Suite struct TabActivityTests {
    func agent(_ id: String, _ status: Status, parent: String? = nil) -> AgentSnapshot {
        let kind: AgentKind = parent.map { .subagent(parent: AgentID($0), description: "d", agentType: nil, model: nil) } ?? .main
        return AgentSnapshot(id: AgentID(id), kind: kind, title: id, status: status, hueIndex: 0, branch: nil, worktree: nil,
                             firstSeen: .distantPast, lastActivity: .distantPast, endedAt: nil, touchCount: 0)
    }

    @Test func countsWorkingAndWaitingMainsOnly() {
        let snap = StoreSnapshot(agents: [
            agent("w1", .working), agent("w2", .working),
            agent("p", .waiting(preview: "Allow Bash?")),
            agent("i", .idle(preview: nil)), agent("e", .ended),
            agent("sub", .working, parent: "w1"), agent("subp", .waiting(preview: "?"), parent: "w1"),
        ])
        #expect(TabActivity(snapshot: snap) == TabActivity(working: 2, waiting: 1))
        #expect(!TabActivity(snapshot: snap).isQuiet)
        #expect(TabActivity(snapshot: .empty) == TabActivity() && TabActivity().isQuiet)
    }
}
