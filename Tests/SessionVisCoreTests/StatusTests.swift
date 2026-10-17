import Foundation
import Testing
@testable import SessionVisCore

@Suite struct StatusTests {
    @Test func touchSourceLabels() {
        #expect(TouchSource.tool("Read").label == "via Read")
        #expect(TouchSource.shell("sed").label == "via sed")
        #expect(TouchSource.disk.label == "on disk")
    }

    @Test func touchCarriesScopeAndSource() {
        let t = Touch(seq: 1, agent: AgentID("a"), path: RepoPath(string: "Sources"), worktree: nil, kind: .read,
                      scope: .directory, source: .shell("grep"), at: Date(timeIntervalSince1970: 0))
        #expect(t.scope == .directory && t.source == .shell("grep") && t.hueIndex == 0 && t.shade == 0 && t.agentTitle == nil)
    }
}
