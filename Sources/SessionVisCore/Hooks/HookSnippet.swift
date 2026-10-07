import Foundation

/// The shell command users add to their Claude Code hooks; it spools each payload into the app's hooks directory while the app is running.
public enum HookSnippet {
    /// Writes the payload only while SessionVis is running (its marker file exists); always exits 0.
    public static let command = #"m="$HOME/Library/Application Support/SessionVis/active"; d="$HOME/Library/Application Support/SessionVis/hooks"; [ -e "$m" ] && mkdir -p "$d" && cat > "$(mktemp "$d/ev.XXXXXXXX")"; exit 0"#
    public static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "PermissionRequest", "Stop", "SubagentStop"]

    /// The hook entry to add under each event's `hooks` array.
    public static var json: String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "{ \"type\": \"command\", \"command\": \"\(escaped)\" }"
    }

    public static func isInstalled(settingsURL: URL) -> Bool {
        guard let text = try? String(contentsOf: settingsURL, encoding: .utf8) else { return false }
        return text.contains("SessionVis/hooks")
    }

    public static var defaultSpoolDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SessionVis/hooks")
    }

    /// Present only while a live SessionVis window is open; the hook command checks it.
    public static func markerURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/SessionVis/active")
    }

    public static func createMarker() {
        let url = markerURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    public static func removeMarker() { try? FileManager.default.removeItem(at: markerURL()) }

    public static func defaultSettingsURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".claude/settings.json")
    }
}
