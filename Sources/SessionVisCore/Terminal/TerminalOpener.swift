import Foundation

/// Why a session's terminal could not be brought to the front, in the words the session list shows.
public enum TerminalFailure: Equatable, Sendable {
    case noTerminalRunning
    case notFound
    case denied(TerminalApp)
    case timedOut(TerminalApp)

    public var message: String {
        switch self {
        case .noTerminalRunning: "iTerm2 or Terminal must be running"
        case .notFound: "No terminal window found for this session"
        case .denied(let app): "Allow SessionVis to control \(app.name) under System Settings › Privacy & Security › Automation"
        case .timedOut(let app): "\(app.name) did not answer"
        }
    }
}

/// Brings the terminal tab running a Claude Code session to the front: the session's pid from Claude Code's session
/// files, its tty from `ps`, then one AppleScript per running terminal app that selects the tab on that tty.
public enum TerminalOpener {
    public enum Outcome: Equatable, Sendable {
        case opened(TerminalApp)
        case failed(TerminalFailure)
        /// The calling task was cancelled; nothing further was run.
        case cancelled
    }

    /// Runs its blocking subprocesses (with timeouts) off the caller's actor, in the caller's task, so cancelling that
    /// task stops the attempt: it is checked between the `ps` and `osascript` steps and after each, the focus
    /// script is never started once it is cancelled, and a running one is terminated. `running` is tried in order and must hold only apps that are
    /// running, because addressing one that is not would launch it.
    @concurrent public static func open(sessionId: String, running: [TerminalApp],
                            sessionsRoot: URL = TerminalLocator.sessionsRoot(), now: Date = Date(),
                            probe: (Int32) -> ProcessProbe? = TerminalOpener.probe(pid:),
                            focus: (String, TerminalApp) async -> FocusResult? = TerminalOpener.focus(tty:in:)) async -> Outcome {
        guard !running.isEmpty else { return .failed(.noTerminalRunning) }
        var tty: String?
        for file in TerminalLocator.candidates(for: sessionId, in: sessionsRoot) {
            if Task.isCancelled { return .cancelled }
            guard let p = probe(file.pid), TerminalLocator.matches(p, file, now: now, tolerance: Constants.terminalStartTolerance) else { continue }
            tty = p.tty
            break
        }
        if Task.isCancelled { return .cancelled }
        guard let tty else { return .failed(.notFound) }
        for app in running {
            if Task.isCancelled { return .cancelled }
            let result = await focus(tty, app)
            if Task.isCancelled { return .cancelled }
            switch result {
            case .focused: return .opened(app)
            case .missing, .failed: continue
            case .denied: return .failed(.denied(app))
            case nil: return .failed(.timedOut(app))
            }
        }
        return .failed(.notFound)
    }

    /// `ps -o pid=,tty=,etime= -p <pid>`; nil when the process is gone (ps exits 1) or ps timed out.
    public static func probe(pid: Int32) -> ProcessProbe? {
        guard let r = Subprocess.run(["/bin/ps", "-o", "pid=,tty=,etime=", "-p", String(pid)], timeout: Constants.terminalCommandTimeout),
              r.status == 0 else { return nil }
        return TerminalLocator.parseProbe(String(decoding: r.output, as: UTF8.self))
    }

    /// `osascript -e <script> <tty>`; nil when osascript timed out or the calling task was cancelled, which also
    /// stops the script so a terminal is never raised after the attempt was given up.
    public static func focus(tty: String, in app: TerminalApp) async -> FocusResult? {
        guard let r = await Subprocess.runCancellable(["/usr/bin/osascript", "-e", TerminalLocator.script(for: app), tty], timeout: Constants.terminalFocusTimeout) else { return nil }
        return TerminalLocator.parseFocusResult(String(decoding: r.output, as: UTF8.self))
    }
}
