import Foundation
import Testing
@testable import SessionVisCore

@Suite struct SessionDiscoveryTests {
    /// Builds a fake projects root. Returns (root, transcript URLs by name).
    func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID().uuidString)")
        let a = root.appendingPathComponent("-Users-me-repo")
        let b = root.appendingPathComponent("-Users-me-repo--claude-worktrees-wt")
        try FileManager.default.createDirectory(at: a.appendingPathComponent("s1/subagents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        func write(_ url: URL, _ lines: [String]) throws { try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8) }
        // s1: member (cwd == root); first records have no cwd
        try write(a.appendingPathComponent("s1.jsonl"), [
            #"{"type":"last-prompt","leafUuid":"x","sessionId":"s1"}"#,
            #"{"type":"mode","mode":"normal","sessionId":"s1"}"#,
            #"{"type":"user","message":{"role":"user","content":"hi"},"timestamp":"2026-09-08T01:42:05.584Z","cwd":"/Users/me/repo","sessionId":"s1"}"#,
        ])
        // s2: not a member
        try write(a.appendingPathComponent("s2.jsonl"), [
            #"{"type":"user","message":{"role":"user","content":"hi"},"timestamp":"2026-09-08T01:42:05.584Z","cwd":"/Users/me/other","sessionId":"s2"}"#,
        ])
        // s3: member via worktree cwd
        try write(b.appendingPathComponent("s3.jsonl"), [
            #"{"type":"user","message":{"role":"user","content":"hi"},"timestamp":"2026-09-08T01:42:05.584Z","cwd":"/Users/me/repo/.claude/worktrees/wt","sessionId":"s3"}"#,
        ])
        // subagents of s1: one complete, one missing meta
        try write(a.appendingPathComponent("s1/subagents/agent-abc.jsonl"), [#"{"type":"mode","mode":"normal"}"#])
        try #"{"agentType":"general-purpose","description":"Implement Task 2","toolUseId":"toolu_1","spawnDepth":1,"model":"sonnet"}"#
            .write(to: a.appendingPathComponent("s1/subagents/agent-abc.meta.json"), atomically: true, encoding: .utf8)
        try write(a.appendingPathComponent("s1/subagents/agent-nometa.jsonl"), [#"{"type":"mode","mode":"normal"}"#])
        // a stray non-jsonl file and a nested dir must be ignored
        try "x".write(to: a.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func projectsRootHonoursEnvironment() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(SessionDiscovery.projectsRoot(environment: [:], home: home).path == "/Users/me/.claude/projects")
        #expect(SessionDiscovery.projectsRoot(environment: ["CLAUDE_CONFIG_DIR": "/cfg"], home: home).path == "/cfg/projects")
    }

    @Test func listsTranscriptsOneLevelDeep() throws {
        let root = try makeRoot()
        let found = SessionDiscovery.listTranscripts(projectsRoot: root)
        #expect(Set(found.map(\.sessionId)) == ["s1", "s2", "s3"])
        #expect(found.allSatisfy { $0.transcriptURL.pathExtension == "jsonl" })
    }

    @Test func membershipUsesFirstCwd() throws {
        let root = try makeRoot()
        let folder = PathFolder(root: "/Users/me/repo")
        let byId = Dictionary(uniqueKeysWithValues: SessionDiscovery.listTranscripts(projectsRoot: root).map { ($0.sessionId, $0.transcriptURL) })
        #expect(SessionDiscovery.isMember(transcriptURL: byId["s1"]!, folder: folder))
        #expect(!SessionDiscovery.isMember(transcriptURL: byId["s2"]!, folder: folder))
        #expect(SessionDiscovery.isMember(transcriptURL: byId["s3"]!, folder: folder))
    }

    @Test func membershipHeadCapIsRespected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).jsonl")
        let filler = String(repeating: #"{"type":"mode","mode":"normal"}"# + "\n", count: 12_000)   // > 256 KB, no cwd
        try (filler + #"{"type":"user","message":{"role":"user","content":"hi"},"cwd":"/Users/me/repo"}"# + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(!SessionDiscovery.isMember(transcriptURL: url, folder: PathFolder(root: "/Users/me/repo")))
    }

    @Test func membershipIsUndeterminedUntilACwdAppears() throws {
        let folder = PathFolder(root: "/Users/me/repo")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grow-\(UUID().uuidString).jsonl")
        try (#"{"type":"mode","mode":"normal"}"# + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(SessionDiscovery.membership(transcriptURL: url, folder: folder) == nil)
        let h = try FileHandle(forWritingTo: url); try h.seekToEnd()
        try h.write(contentsOf: Data((#"{"type":"user","message":{"role":"user","content":"hi"},"cwd":"/Users/me/repo"}"# + "\n").utf8)); try h.close()
        #expect(SessionDiscovery.membership(transcriptURL: url, folder: folder) == true)
        let big = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).jsonl")
        try String(repeating: #"{"type":"mode","mode":"normal"}"# + "\n", count: 12_000).write(to: big, atomically: true, encoding: .utf8)
        #expect(SessionDiscovery.membership(transcriptURL: big, folder: folder) == false)
    }

    @Test func listsSubagentsWithMetaOnly() throws {
        let root = try makeRoot()
        let s1 = root.appendingPathComponent("-Users-me-repo/s1.jsonl")
        let subs = SessionDiscovery.listSubagents(sessionTranscriptURL: s1)
        #expect(subs.count == 1)
        #expect(subs.first?.agentId == "abc")
        #expect(subs.first?.meta == SubagentMeta(description: "Implement Task 2", agentType: "general-purpose", model: "sonnet", toolUseId: "toolu_1", spawnDepth: 1))
        #expect(SessionDiscovery.listSubagents(sessionTranscriptURL: root.appendingPathComponent("-Users-me-repo/s2.jsonl")).isEmpty)
    }

    @Test func pathFolderMembershipHelpers() {
        let f = PathFolder(root: "/Users/me/repo")
        #expect(f.isMemberCwd("/Users/me/repo"))
        #expect(f.isMemberCwd("/Users/me/repo/"))
        #expect(f.isMemberCwd("/Users/me/repo/.claude/worktrees/wt"))
        #expect(f.isMemberCwd("/Users/me/repo/.claude/worktrees/wt/sub"))
        #expect(!f.isMemberCwd("/Users/me/repo/Sources"))
        #expect(!f.isMemberCwd("/Users/me/other"))
        #expect(f.worktreeName(ofCwd: "/Users/me/repo/.claude/worktrees/wt/sub") == "wt")
        #expect(f.worktreeName(ofCwd: "/Users/me/repo") == nil)
    }
}
