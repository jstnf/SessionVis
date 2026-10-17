import Foundation

/// One of Claude Code's per-process session files (`<sessions>/<pid>.json`).
public struct SessionProcessFile: Equatable, Sendable {
    public let pid: Int32
    public let sessionId: String
    public let cwd: String
    public let startedAt: Date?
    public let updatedAt: Date?
    public init(pid: Int32, sessionId: String, cwd: String, startedAt: Date? = nil, updatedAt: Date? = nil) {
        self.pid = pid; self.sessionId = sessionId; self.cwd = cwd; self.startedAt = startedAt; self.updatedAt = updatedAt
    }
}

/// What `ps` says about one process: its controlling terminal and how long it has run.
public struct ProcessProbe: Equatable, Sendable {
    public let pid: Int32
    /// `/dev/ttys000`; nil when the process has no controlling terminal.
    public let tty: String?
    public let elapsed: TimeInterval
    public init(pid: Int32, tty: String?, elapsed: TimeInterval) { self.pid = pid; self.tty = tty; self.elapsed = elapsed }
}

/// Pure parsing for finding the terminal a Claude Code session runs in: the session files Claude Code writes, `ps`
/// output, and the AppleScript results. Nothing here runs a process.
public enum TerminalLocator {
    /// `$CLAUDE_CONFIG_DIR/sessions` or `~/.claude/sessions`.
    public static func sessionsRoot(environment: [String: String] = ProcessInfo.processInfo.environment,
                                    home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let cfg = environment["CLAUDE_CONFIG_DIR"], !cfg.isEmpty {
            return URL(fileURLWithPath: cfg).appendingPathComponent("sessions")
        }
        return home.appendingPathComponent(".claude/sessions")
    }

    /// nil unless the JSON has an integer `pid` whose decimal digits are exactly the filename stem, a non-empty
    /// `sessionId` and a `cwd`. A `startedAt` that is present but not a number rejects the file: the start time is
    /// what proves a pid has not been reused, so an unreadable one must never mean "skip the check".
    public static func parseSessionFile(_ data: Data, fileName: String) -> SessionProcessFile? {
        let stem = (fileName as NSString).deletingPathExtension
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pidNumber = obj["pid"] as? NSNumber, isInteger(pidNumber),
              let pid = Int32(exactly: pidNumber.int64Value), String(pid) == stem,
              obj["startedAt"] == nil || isNumber(obj["startedAt"]),
              let sessionId = obj["sessionId"] as? String, !sessionId.isEmpty,
              let cwd = obj["cwd"] as? String else { return nil }
        return SessionProcessFile(pid: pid, sessionId: sessionId, cwd: cwd,
                                  startedAt: millis(obj["startedAt"]), updatedAt: millis(obj["updatedAt"]))
    }

    private static func isNumber(_ value: Any?) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) != CFBooleanGetTypeID()
    }

    private static func isInteger(_ n: NSNumber) -> Bool {
        isNumber(n) && !CFNumberIsFloatType(n)
    }

    /// Timestamps in the session files are milliseconds since the epoch.
    private static func millis(_ value: Any?) -> Date? {
        guard isNumber(value), let n = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: n.doubleValue / 1000)
    }

    /// Every `<pid>.json` under `root` naming `sessionId`, newest `updatedAt` first (files without one last). A
    /// resumed session has one file per process that ran it.
    public static func candidates(for sessionId: String, in root: URL) -> [SessionProcessFile] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: nil) else { return [] }
        let parsed = files.filter { $0.pathExtension == "json" }.compactMap { url -> SessionProcessFile? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return parseSessionFile(data, fileName: url.lastPathComponent)
        }
        return parsed.filter { $0.sessionId == sessionId }.sorted { a, b in
            let ua = a.updatedAt ?? .distantPast, ub = b.updatedAt ?? .distantPast
            return ua != ub ? ua > ub : a.pid > b.pid
        }
    }

    /// One line of `ps -o pid=,tty=,etime= -p <pid>`; nil for empty output (the process is gone) or a malformed line.
    /// `ps` prints the tty without `/dev/`; the terminal apps print the full device path, so it is added here.
    public static func parseProbe(_ text: String) -> ProcessProbe? {
        guard let line = text.split(whereSeparator: \.isNewline).first else { return nil }
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count == 3, let pid = Int32(fields[0]), let elapsed = parseElapsed(String(fields[2])) else { return nil }
        let tty = fields[1] == "??" ? nil : "/dev/" + fields[1]
        return ProcessProbe(pid: pid, tty: tty, elapsed: elapsed)
    }

    /// `[[dd-]hh:]mm:ss`, as `ps` prints elapsed time.
    static func parseElapsed(_ field: String) -> TimeInterval? {
        let dayParts = field.split(separator: "-", omittingEmptySubsequences: false)
        guard dayParts.count <= 2, let clockField = dayParts.last else { return nil }
        var total: TimeInterval = 0
        if dayParts.count == 2 {
            guard let days = Int(dayParts[0]), days >= 0 else { return nil }
            total += TimeInterval(days) * 86_400
        }
        let clock = clockField.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(clock.count) else { return nil }
        var scale: TimeInterval = 1
        for part in clock.reversed() {
            guard let n = Int(part), n >= 0 else { return nil }
            total += TimeInterval(n) * scale
            scale *= 60
        }
        return total
    }

    /// The process is the one the file describes: same pid, on a tty, and (when the file knows when the session
    /// started) started within `tolerance` of that moment, so a pid reused by another process is never trusted.
    public static func matches(_ probe: ProcessProbe, _ file: SessionProcessFile, now: Date, tolerance: TimeInterval) -> Bool {
        guard probe.pid == file.pid, probe.tty != nil else { return false }
        guard let startedAt = file.startedAt else { return true }
        let processStart = now.addingTimeInterval(-probe.elapsed)
        return abs(processStart.timeIntervalSince(startedAt)) <= tolerance
    }
}
