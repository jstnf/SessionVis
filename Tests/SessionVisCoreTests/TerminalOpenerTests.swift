import Foundation
import Testing
@testable import SessionVisCore

@Suite struct TerminalOpenerTests {
    /// Every fixture session started at 1,000,000 s; `now` is 100 s later, so a live probe reports `elapsed` 100.
    let now = Date(timeIntervalSince1970: 1_000_100)

    func makeRoot(_ sessions: [(pid: Int32, id: String, updatedAt: Int)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("opener-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for s in sessions {
            try #"{"pid":\#(s.pid),"sessionId":"\#(s.id)","cwd":"/r","startedAt":1000000000,"updatedAt":\#(s.updatedAt)}"#
                .write(to: root.appendingPathComponent("\(s.pid).json"), atomically: true, encoding: .utf8)
        }
        return root
    }

    func alive(_ pid: Int32) -> ProcessProbe { ProcessProbe(pid: pid, tty: "/dev/ttys\(pid)", elapsed: 100) }

    @Test func noRunningTerminalFailsBeforeProbing() async throws {
        let root = try makeRoot([(10, "s", 1)])
        defer { try? FileManager.default.removeItem(at: root) }
        var probed = 0
        let outcome = await TerminalOpener.open(sessionId: "s", running: [], sessionsRoot: root, now: now,
                                          probe: { _ in probed += 1; return nil }, focus: { _, _ in .focused })
        #expect(outcome == .failed(.noTerminalRunning))
        #expect(probed == 0)
    }

    @Test func deadPidIsNotFound() async throws {
        let root = try makeRoot([(10, "s", 1)])
        defer { try? FileManager.default.removeItem(at: root) }
        var focused = 0
        let outcome = await TerminalOpener.open(sessionId: "s", running: [.iTerm], sessionsRoot: root, now: now,
                                          probe: { _ in nil }, focus: { _, _ in focused += 1; return .focused })
        #expect(outcome == .failed(.notFound))
        #expect(focused == 0)
    }

    @Test func reusedPidIsNotFound() async throws {
        let root = try makeRoot([(10, "s", 1)])
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await TerminalOpener.open(sessionId: "s", running: [.iTerm], sessionsRoot: root, now: now,
                                          probe: { pid in ProcessProbe(pid: pid, tty: "/dev/ttys010", elapsed: 5_000) },
                                          focus: { _, _ in .focused })
        #expect(outcome == .failed(.notFound))
    }

    @Test func unknownSessionIsNotFound() async throws {
        let root = try makeRoot([(10, "other", 1)])
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await TerminalOpener.open(sessionId: "s", running: [.iTerm], sessionsRoot: root, now: now,
                                          probe: { pid in self.alive(pid) }, focus: { _, _ in .focused })
        #expect(outcome == .failed(.notFound))
    }

    @Test func staleFileIsSkippedForTheLiveOne() async throws {
        let root = try makeRoot([(10, "s", 2000), (20, "s", 1000)])   // the newer file's process is gone
        defer { try? FileManager.default.removeItem(at: root) }
        var ttys: [String] = []
        let outcome = await TerminalOpener.open(sessionId: "s", running: [.iTerm], sessionsRoot: root, now: now,
                                          probe: { pid in pid == 20 ? self.alive(pid) : nil },
                                          focus: { tty, _ in ttys.append(tty); return .focused })
        #expect(outcome == .opened(.iTerm))
        #expect(ttys == ["/dev/ttys20"])
    }

    @Test func theNextAppIsTriedAfterMissingOrFailed() async throws {
        let root = try makeRoot([(10, "s", 1)])
        defer { try? FileManager.default.removeItem(at: root) }
        var asked: [TerminalApp] = []
        let opened = await TerminalOpener.open(sessionId: "s", running: [.iTerm, .terminal], sessionsRoot: root, now: now,
                                         probe: { pid in self.alive(pid) },
                                         focus: { _, app in asked.append(app); return app == .iTerm ? .missing : .focused })
        #expect(opened == .opened(.terminal))
        #expect(asked == [.iTerm, .terminal])
        let afterError = await TerminalOpener.open(sessionId: "s", running: [.iTerm, .terminal], sessionsRoot: root, now: now,
                                             probe: { pid in self.alive(pid) },
                                             focus: { _, app in app == .iTerm ? .failed(-1728) : .focused })
        #expect(afterError == .opened(.terminal))
        let nowhere = await TerminalOpener.open(sessionId: "s", running: [.iTerm, .terminal], sessionsRoot: root, now: now,
                                          probe: { pid in self.alive(pid) }, focus: { _, _ in .missing })
        #expect(nowhere == .failed(.notFound))
    }

    @Test func deniedStopsAtOnce() async throws {
        let root = try makeRoot([(10, "s", 1)])
        defer { try? FileManager.default.removeItem(at: root) }
        var asked: [TerminalApp] = []
        let outcome = await TerminalOpener.open(sessionId: "s", running: [.iTerm, .terminal], sessionsRoot: root, now: now,
                                          probe: { pid in self.alive(pid) },
                                          focus: { _, app in asked.append(app); return .denied })
        #expect(outcome == .failed(.denied(.iTerm)))
        #expect(asked == [.iTerm])
    }

    @Test func timeoutIsReported() async throws {
        let root = try makeRoot([(10, "s", 1)])
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await TerminalOpener.open(sessionId: "s", running: [.terminal], sessionsRoot: root, now: now,
                                          probe: { pid in self.alive(pid) }, focus: { _, _ in nil })
        #expect(outcome == .failed(.timedOut(.terminal)))
    }

    @Test func realProbeSeesThisProcessAndNotAnImpossiblePid() throws {
        let own = ProcessInfo.processInfo.processIdentifier
        let probe = try #require(TerminalOpener.probe(pid: own))
        #expect(probe.pid == own)
        #expect(probe.elapsed >= 0)
        #expect(TerminalOpener.probe(pid: 99_999) == nil)
    }

    @Test func parsesFocusResults() {
        #expect(TerminalLocator.parseFocusResult("ok\n") == .focused)
        #expect(TerminalLocator.parseFocusResult("missing\n") == .missing)
        #expect(TerminalLocator.parseFocusResult("error -1743\n") == .denied)
        #expect(TerminalLocator.parseFocusResult("error -1728\n") == .failed(-1728))
        #expect(TerminalLocator.parseFocusResult("") == .failed(0))
        #expect(TerminalLocator.parseFocusResult("something else") == .failed(0))
    }

    @Test func scriptsAddressEachAppByBundleIdAndTakeTheTtyAsArgument() {
        for app in TerminalApp.allCases {
            let script = TerminalLocator.script(for: app)
            #expect(script.hasPrefix("on run argv"))
            #expect(script.contains("tell application id \"\(app.bundleIdentifier)\""))
            #expect(script.contains("return \"missing\""))
            #expect(script.contains("on error message number n"))
        }
        #expect(TerminalLocator.script(for: .iTerm).contains("select s"))
        #expect(TerminalLocator.script(for: .terminal).contains("set selected tab of w to t"))
    }

    @Test func failureMessagesNameTheApp() {
        #expect(TerminalFailure.denied(.iTerm).message.contains("iTerm2"))
        #expect(TerminalFailure.denied(.iTerm).message.contains("Automation"))
        #expect(TerminalFailure.timedOut(.terminal).message.contains("Terminal"))
        #expect(!TerminalFailure.notFound.message.isEmpty)
        #expect(!TerminalFailure.noTerminalRunning.message.isEmpty)
    }

    @Test func cancellationBeforeTheFocusScriptNeverSendsIt() async throws {
        let root = try makeRoot([(10, "s", 1)])
        defer { try? FileManager.default.removeItem(at: root) }
        let focused = Counter()
        let task = Task {
            await TerminalOpener.open(sessionId: "s", running: [.iTerm, .terminal], sessionsRoot: root, now: now,
                                      probe: { pid in withUnsafeCurrentTask { $0?.cancel() }; return self.alive(pid) },
                                      focus: { _, _ in focused.bump(); return .focused })
        }
        #expect(await task.value == .cancelled)
        #expect(focused.value == 0)
    }

    @Test func cancellationAfterOneAppStopsBeforeTheNext() async throws {
        let root = try makeRoot([(10, "s", 1)])
        defer { try? FileManager.default.removeItem(at: root) }
        let focused = Counter()
        let task = Task {
            await TerminalOpener.open(sessionId: "s", running: [.iTerm, .terminal], sessionsRoot: root, now: now,
                                      probe: { pid in self.alive(pid) },
                                      focus: { _, _ in focused.bump(); withUnsafeCurrentTask { $0?.cancel() }; return .missing })
        }
        #expect(await task.value == .cancelled)
        #expect(focused.value == 1)
    }

    @Test func aTaskCancelledBeforeStartingRunsNothing() async throws {
        let root = try makeRoot([(10, "s", 1)])
        defer { try? FileManager.default.removeItem(at: root) }
        let focused = Counter()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return await TerminalOpener.open(sessionId: "s", running: [.iTerm], sessionsRoot: root, now: now,
                                             probe: { pid in self.alive(pid) }, focus: { _, _ in focused.bump(); return .focused })
        }
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(focused.value == 0)
    }

    @Test func focusHasItsOwnLongerTimeout() {
        #expect(Constants.terminalFocusTimeout > Constants.terminalCommandTimeout)
    }

    @Test func scriptsReturnMissingWhenTheAppIsNotRunning() {
        for app in TerminalApp.allCases {
            let script = TerminalLocator.script(for: app)
            let guardRange = script.range(of: "application id \"\(app.bundleIdentifier)\" is running")
            let tellRange = script.range(of: "tell application id")
            #expect(guardRange != nil)
            if let g = guardRange, let t = tellRange { #expect(g.lowerBound < t.lowerBound) }
        }
    }

    @Test func shippedScriptsCompileAndReportMissingForAnUnknownTty() throws {
        for app in TerminalApp.allCases {
            let r = try #require(Subprocess.run(["/usr/bin/osascript", "-e", TerminalLocator.script(for: app), "/dev/ttys999"], timeout: 30))
            let text = String(decoding: r.output, as: UTF8.self)
            #expect(TerminalLocator.parseFocusResult(text) != .failed(0), "\(app.name): \(text)")
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
