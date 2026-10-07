import Testing
@testable import SessionVisCore

@Suite struct LaunchOptionsTests {
    @Test func directoryOnly() {
        #expect(LaunchOptions.parse(["/repo"]) == LaunchOptions(directory: "/repo"))
        #expect(LaunchOptions.parse([]) == LaunchOptions())
    }
    @Test func replayAndSpeed() {
        let o = LaunchOptions.parse(["--replay", "/t/s.jsonl", "--speed", "20", "/repo"])
        #expect(o == LaunchOptions(directory: "/repo", replayTranscript: "/t/s.jsonl", speed: 20))
        #expect(LaunchOptions.parse(["--speed", "nope", "/repo"]).speed == 10)
    }
    @Test func unknownFlagsWithValuesAreSkipped() {
        #expect(LaunchOptions.parse(["-NSDocumentRevisionsDebugMode", "YES", "/repo"]).directory == "/repo")
        #expect(LaunchOptions.parse(["--verbose", "/repo"]).directory == "/repo")
    }
    @Test func tildeIsExpanded() {
        let o = LaunchOptions.parse(["~/dev/x"])
        #expect(o.directory?.hasPrefix("/") == true && o.directory?.hasSuffix("/dev/x") == true)
    }
    @Test func dirFlag() {
        #expect(LaunchOptions.parse(["--dir", "/repo"]) == LaunchOptions(directory: "/repo"))
        let d = LaunchOptions.parse(["-d", "~/x"]).directory
        #expect(d?.hasPrefix("/") == true && d?.hasSuffix("/x") == true)
        #expect(LaunchOptions.parse(["--replay", "/t.jsonl", "--dir", "/repo"]) == LaunchOptions(directory: "/repo", replayTranscript: "/t.jsonl"))
    }
}
