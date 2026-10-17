import Foundation

/// The terminal apps that can be asked, by AppleScript, which tab is on a tty. Addressed by bundle id so a renamed
/// `.app` still answers.
public enum TerminalApp: String, CaseIterable, Sendable {
    case iTerm = "com.googlecode.iterm2"
    case terminal = "com.apple.Terminal"

    public var bundleIdentifier: String { rawValue }

    public var name: String {
        switch self {
        case .iTerm: "iTerm2"
        case .terminal: "Terminal"
        }
    }
}

/// What one terminal app answered when asked to select the session on a tty.
public enum FocusResult: Equatable, Sendable {
    case focused
    /// The app owns no session on that tty.
    case missing
    /// Automation permission was refused (AppleScript error -1743).
    case denied
    /// Any other AppleScript error number; 0 when the output was not understood.
    case failed(Int)
}

extension TerminalLocator {
    /// The AppleScript that selects the session on tty `item 1 of argv` in `app` and prints `ok`, or `missing`, or
    /// `error <n>`. Errors are caught inside the script so a refused permission reaches stdout.
    public static func script(for app: TerminalApp) -> String {
        switch app {
        case .iTerm: iTermScript
        case .terminal: terminalScript
        }
    }

    public static func parseFocusResult(_ text: String) -> FocusResult {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line == "ok" { return .focused }
        if line == "missing" { return .missing }
        if line.hasPrefix("error "), let n = Int(line.dropFirst("error ".count).trimmingCharacters(in: .whitespaces)) {
            return n == -1743 ? .denied : .failed(n)
        }
        return .failed(0)
    }

    private static let iTermScript = """
    on run argv
        set target to item 1 of argv
        if not (application id "com.googlecode.iterm2" is running) then return "missing"
        try
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    try
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is target then
                                    select w
                                    select t
                                    select s
                                    activate
                                    return "ok"
                                end if
                            end repeat
                        end repeat
                    on error m number n
                        if n is -1743 then error m number n
                    end try
                end repeat
            end tell
            return "missing"
        on error message number n
            return "error " & n
        end try
    end run
    """

    private static let terminalScript = """
    on run argv
        set target to item 1 of argv
        if not (application id "com.apple.Terminal" is running) then return "missing"
        try
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    try
                        repeat with t in tabs of w
                            if tty of t is target then
                                set selected tab of w to t
                                set frontmost of w to true
                                activate
                                return "ok"
                            end if
                        end repeat
                    on error m number n
                        if n is -1743 then error m number n
                    end try
                end repeat
            end tell
            return "missing"
        on error message number n
            return "error " & n
        end try
    end run
    """
}
