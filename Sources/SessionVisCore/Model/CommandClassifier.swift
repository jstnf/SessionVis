import Foundation

/// Heuristic classification of shell commands. Wrong guesses only change a label's styling, never file state.
public enum CommandClassifier {
    static let labelLimit = 40

    /// Drops leading `cd <dir> &&` / `cd <dir>;` segments and leading `NAME=value` assignments.
    public static func strip(_ command: String) -> String {
        var s = command.trimmingCharacters(in: .whitespacesAndNewlines)
        while s == "cd" || s.hasPrefix("cd ") || s.hasPrefix("cd\t") || s.hasPrefix("cd\n") {
            guard let r = firstSeparator(in: s) else { return "" }
            s = s[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var tokens = words(s)
        while let first = tokens.first, isAssignment(first) { tokens.removeFirst() }
        return tokens.joined(separator: " ")
    }

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// The earliest `&&`, `;` or newline in `s`.
    private static func firstSeparator(in s: String) -> Range<String.Index>? {
        ["&&", ";", "\n"].compactMap { s.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
    }

    /// The command's segments split on `&&`, `;` and newlines, each stripped of `cd` and assignment prefixes; empty ones dropped.
    private static func segments(_ command: String) -> [String] {
        var out: [String] = []
        var rest = command
        while true {
            let sep = firstSeparator(in: rest)
            let piece = sep.map { String(rest[..<$0.lowerBound]) } ?? rest
            let stripped = strip(piece)
            if !stripped.isEmpty { out.append(stripped) }
            guard let sep else { break }
            rest = String(rest[sep.upperBound...])
        }
        return out
    }

    /// The segment that decides classification and label: the first with a git milestone, else the first segment.
    private static func deciding(_ command: String) -> (segment: String, cls: CommandClass)? {
        let classified = segments(command).map { ($0, classifySegment($0)) }
        return classified.first(where: { $0.1.milestone != nil }) ?? classified.first
    }

    /// Every chained segment, in order and stripped like `segments`, whose class carries a git milestone.
    public static func milestoneSegments(_ command: String) -> [String] {
        segments(command).filter { classifySegment($0).milestone != nil }
    }

    private static func isAssignment(_ token: String) -> Bool {
        guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { return false }
        let name = token[..<eq]
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } && !(name.first?.isNumber ?? true)
    }

    public static func classify(_ command: String) -> CommandClass {
        deciding(command)?.cls ?? .other
    }

    private static func classifySegment(_ segment: String) -> CommandClass {
        let tokens = words(segment)
        guard let first = tokens.first else { return .other }
        let rest = Array(tokens.dropFirst())
        switch first {
        case "git": return .git(gitVerb(rest))
        case "swift", "cargo", "go":
            switch rest.first { case "build": return .build; case "test": return .test; case "run": return .run; default: return .other }
        case "xcodebuild": return rest.contains("test") ? .test : .build
        case "make": return rest.first == "test" || rest.first == "check" ? .test : .build
        case "npm", "yarn", "pnpm", "bun":
            switch rest.first {
            case "test": return .test
            case "build": return .build
            case "start", "dev": return .run
            case "run": return rest.dropFirst().first == "build" ? .build : rest.dropFirst().first == "test" ? .test : .run
            default: return .other
            }
        case "pytest", "jest", "vitest", "rspec", "ctest": return .test
        default: return first.hasPrefix("./") ? .run : .other
        }
    }

    /// The git subcommand, skipping global options (`-C <dir>`, `-c <k=v>`, `--git-dir=…`, bare flags).
    private static func gitVerb(_ args: [String]) -> GitVerb {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "-C" || a == "-c" || a == "--git-dir" || a == "--work-tree" { i += 2; continue }
            if a.hasPrefix("-") { i += 1; continue }
            switch a {
            case "commit": return .commit
            case "push": return .push
            case "merge": return .merge
            case "rebase": return .rebase
            default: return .other
            }
        }
        return .other
    }

    /// The description when present, else the first two words of the deciding segment; at most `labelLimit` characters.
    public static func label(command: String, description: String?) -> String {
        if let d = description?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { return String(d.prefix(labelLimit)) }
        let first = words(deciding(command)?.segment ?? "").prefix(2)
        return String(first.joined(separator: " ").prefix(labelLimit))
    }

    /// The `[branch hash] message` line git prints after a commit; `(root-commit)` is stripped from the branch.
    public static func parseCommit(_ resultText: String) -> CommitInfo? {
        let pattern = /^\[(.+?) ([0-9a-f]{7,40})\] (.*)$/
        for line in resultText.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let m = line.wholeMatch(of: pattern) else { continue }
            var branch = String(m.1)
            if branch.hasSuffix(" (root-commit)") { branch = String(branch.dropLast(" (root-commit)".count)) }
            return CommitInfo(hash: String(m.2), branch: branch, message: String(m.3).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
