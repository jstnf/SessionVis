import Foundation
import Testing
@testable import SessionVisCore

@Suite struct SubprocessTests {
    @Test func capturesOutputAndStatus() {
        let ok = Subprocess.run(["printf", "a\\nb"], timeout: 5)
        #expect(ok?.status == 0)
        #expect(ok.map { String(decoding: $0.output, as: UTF8.self) } == "a\nb")
        #expect(Subprocess.run(["false"], timeout: 5)?.status != 0)
    }

    @Test func missingCommandExitsWith127() throws {
        let r = try #require(Subprocess.run(["sessionvis-no-such-command-\(UUID().uuidString)"], timeout: 5))
        #expect(r.status == 127)
    }

    @Test(.timeLimit(.minutes(1))) func terminatesAfterTimeout() {
        let start = Date()
        let r = Subprocess.run(["sleep", "30"], timeout: 0.2)
        #expect(r == nil)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test(.timeLimit(.minutes(1))) func killsAChildThatIgnoresTerminate() {
        let start = Date()
        let r = Subprocess.run(["sh", "-c", "trap '' TERM; sleep 30"], timeout: 0.2)
        #expect(r == nil)
        #expect(Date().timeIntervalSince(start) < 10)
    }
}
