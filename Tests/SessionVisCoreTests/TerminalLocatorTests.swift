import Foundation
import Testing
@testable import SessionVisCore

@Suite struct TerminalLocatorTests {
    /// Verbatim from a running Claude Code 2.1.300 session.
    static let fixture = #"{"pid":94675,"sessionId":"825769d5-63c6-48ca-bff4-c8383da4664c","cwd":"/Users/justin/Developer/ai/session-vis","startedAt":1792206852861,"procStart":"Sat Oct 17 03:14:10 2026","version":"2.1.300","peerProtocol":1,"peerFeatures":["notify_idle","reply_across_default_dirs","artifact_yield"],"kind":"interactive","entrypoint":"cli","pidDomain":"darwin","messagingSocketPath":"/tmp/cc-socks/94675.sock","name":"Agent sessions visualization tool","nameSource":"auto","nameSince":1792206856739,"status":"busy","updatedAt":1792267829461,"statusUpdatedAt":1792267829461,"bridgeSessionId":"session_01JBTPDSRhs2Frz4RbskxY6Q"}"#

    func makeSessionsRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func write(_ root: URL, _ name: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test func parsesARealSessionFile() throws {
        let f = try #require(TerminalLocator.parseSessionFile(Data(Self.fixture.utf8), fileName: "94675.json"))
        #expect(f.pid == 94675)
        #expect(f.sessionId == "825769d5-63c6-48ca-bff4-c8383da4664c")
        #expect(f.cwd == "/Users/justin/Developer/ai/session-vis")
        #expect(f.startedAt == Date(timeIntervalSince1970: 1_792_206_852.861))
        #expect(f.updatedAt == Date(timeIntervalSince1970: 1_792_267_829.461))
    }

    @Test func rejectsMismatchedOrIncompleteFiles() {
        let data = Data(Self.fixture.utf8)
        #expect(TerminalLocator.parseSessionFile(data, fileName: "94676.json") == nil)    // stem differs from pid
        #expect(TerminalLocator.parseSessionFile(data, fileName: "notes.json") == nil)
        #expect(TerminalLocator.parseSessionFile(Data(#"{"pid":1,"cwd":"/x"}"#.utf8), fileName: "1.json") == nil)
        #expect(TerminalLocator.parseSessionFile(Data(#"{"pid":1,"sessionId":"","cwd":"/x"}"#.utf8), fileName: "1.json") == nil)
        #expect(TerminalLocator.parseSessionFile(Data(#"{"pid":1,"sessionId":"s"}"#.utf8), fileName: "1.json") == nil)
        #expect(TerminalLocator.parseSessionFile(Data("not json".utf8), fileName: "1.json") == nil)
        let minimal = TerminalLocator.parseSessionFile(Data(#"{"pid":1,"sessionId":"s","cwd":"/x"}"#.utf8), fileName: "1.json")
        #expect(minimal == SessionProcessFile(pid: 1, sessionId: "s", cwd: "/x", startedAt: nil, updatedAt: nil))
    }

    @Test func candidatesAreTheSessionsFilesNewestFirst() throws {
        let root = try makeSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "100.json", #"{"pid":100,"sessionId":"s1","cwd":"/r","updatedAt":1000}"#)
        try write(root, "200.json", #"{"pid":200,"sessionId":"s1","cwd":"/r","updatedAt":2000}"#)
        try write(root, "300.json", #"{"pid":300,"sessionId":"s1","cwd":"/r"}"#)                      // no updatedAt: last
        try write(root, "400.json", #"{"pid":400,"sessionId":"s2","cwd":"/r","updatedAt":9000}"#)     // another session
        try write(root, "500.json", #"{"pid":501,"sessionId":"s1","cwd":"/r","updatedAt":9000}"#)     // pid differs from the name
        try write(root, "notes.json", #"{"pid":600,"sessionId":"s1","cwd":"/r","updatedAt":9000}"#)
        try write(root, "100.abcdef.key", "secret")
        #expect(TerminalLocator.candidates(for: "s1", in: root).map(\.pid) == [200, 100, 300])
        #expect(TerminalLocator.candidates(for: "s3", in: root) == [])
        #expect(TerminalLocator.candidates(for: "s1", in: root.appendingPathComponent("missing")) == [])
    }

    @Test func sessionsRootHonoursTheConfigDirectory() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(TerminalLocator.sessionsRoot(environment: [:], home: home).path == "/Users/me/.claude/sessions")
        #expect(TerminalLocator.sessionsRoot(environment: ["CLAUDE_CONFIG_DIR": "/cfg"], home: home).path == "/cfg/sessions")
        #expect(TerminalLocator.sessionsRoot(environment: ["CLAUDE_CONFIG_DIR": ""], home: home).path == "/Users/me/.claude/sessions")
    }

    @Test func parsesProbes() {
        #expect(TerminalLocator.parseProbe("94675 ttys000  17:01:34\n") == ProcessProbe(pid: 94675, tty: "/dev/ttys000", elapsed: 61_294))
        #expect(TerminalLocator.parseProbe("    1 ??       04-13:40:28\n") == ProcessProbe(pid: 1, tty: nil, elapsed: 394_828))
        #expect(TerminalLocator.parseProbe("") == nil)                      // ps prints nothing for a dead pid
        #expect(TerminalLocator.parseProbe("94675 ttys000\n") == nil)
        #expect(TerminalLocator.parseProbe("abc ttys000 22:04\n") == nil)
    }

    @Test func parsesElapsedTimes() {
        #expect(TerminalLocator.parseElapsed("22:04") == 1_324)
        #expect(TerminalLocator.parseElapsed("17:01:34") == 61_294)
        #expect(TerminalLocator.parseElapsed("04-13:40:28") == 394_828)
        #expect(TerminalLocator.parseElapsed("04-") == nil)
        #expect(TerminalLocator.parseElapsed("1:2:3:4") == nil)
        #expect(TerminalLocator.parseElapsed("") == nil)
        #expect(TerminalLocator.parseElapsed("x:y") == nil)
    }

    @Test func matchesAliveProcessesThatStartedWhenTheFileSays() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let file = SessionProcessFile(pid: 7, sessionId: "s", cwd: "/r", startedAt: Date(timeIntervalSince1970: 1_999_000), updatedAt: nil)
        let probe = ProcessProbe(pid: 7, tty: "/dev/ttys003", elapsed: 1_002)   // the file is written about 2 s after the process starts
        #expect(TerminalLocator.matches(probe, file, now: now, tolerance: 60))
        #expect(!TerminalLocator.matches(ProcessProbe(pid: 7, tty: "/dev/ttys003", elapsed: 1_200), file, now: now, tolerance: 60))   // a reused pid
        #expect(!TerminalLocator.matches(ProcessProbe(pid: 7, tty: nil, elapsed: 1_002), file, now: now, tolerance: 60))
        #expect(!TerminalLocator.matches(ProcessProbe(pid: 8, tty: "/dev/ttys003", elapsed: 1_002), file, now: now, tolerance: 60))
        let undated = SessionProcessFile(pid: 7, sessionId: "s", cwd: "/r", startedAt: nil, updatedAt: nil)
        #expect(TerminalLocator.matches(ProcessProbe(pid: 7, tty: "/dev/ttys003", elapsed: 1_200), undated, now: now, tolerance: 60))
    }

    @Test func aStartedAtThatIsNotANumberRejectsTheFile() {
        for value in [#""2026-10-14T21:48:12Z""#, #""1000000000""#, "true", "null", "[1]"] {
            let json = #"{"pid":10,"sessionId":"s","cwd":"/r","startedAt":\#(value)}"#
            #expect(TerminalLocator.parseSessionFile(Data(json.utf8), fileName: "10.json") == nil, "startedAt \(value)")
        }
        #expect(TerminalLocator.parseSessionFile(Data(#"{"pid":10,"sessionId":"s","cwd":"/r","startedAt":5}"#.utf8), fileName: "10.json") != nil)
    }

    @Test func pidMustBeAnIntegerNumberMatchingTheStemExactly() {
        func parse(_ pid: String, _ name: String) -> SessionProcessFile? {
            TerminalLocator.parseSessionFile(Data(#"{"pid":\#(pid),"sessionId":"s","cwd":"/r"}"#.utf8), fileName: name)
        }
        #expect(parse("94675", "94675.json") != nil)
        #expect(parse("94675.9", "94675.json") == nil)
        #expect(parse("94675.0", "94675.json") == nil)
        #expect(parse("true", "1.json") == nil)
        #expect(parse("\"94675\"", "94675.json") == nil)
        #expect(parse("94675", "+94675.json") == nil)
        #expect(parse("94675", "094675.json") == nil)
        #expect(parse("4294967296", "0.json") == nil)
        #expect(parse("\(Int64(Int32.max) + 94675)", "\(Int64(Int32.max) + 94675).json") == nil)
    }

    @Test func aSymlinkedSessionsDirectoryIsListed() throws {
        let root = try makeSessionsRoot()
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: link) }
        try write(root, "7.json", #"{"pid":7,"sessionId":"s","cwd":"/r"}"#)
        #expect(TerminalLocator.candidates(for: "s", in: link).map(\.pid) == [7])
    }
}
