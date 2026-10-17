import Foundation

/// One hidden-file rule: a glob the user can switch off without deleting it.
public struct FilterRule: Codable, Hashable, Identifiable, Sendable {
    public let pattern: String
    public var isEnabled: Bool
    public var id: String { pattern }
    public init(pattern: String, isEnabled: Bool = true) { self.pattern = pattern; self.isEnabled = isEnabled }
}

/// A file-name suffix pattern and how many files carry it.
public struct Suggestion: Hashable, Identifiable, Sendable {
    public let pattern: String
    public let count: Int
    public var id: String { pattern }
    public init(pattern: String, count: Int) { self.pattern = pattern; self.count = count }
}

/// The hidden-file rules for one watched directory. Only `rules` is persisted; the compiled patterns are derived.
public struct FileFilter: Codable, Equatable, Sendable {
    public private(set) var rules: [FilterRule] { didSet { compiled = Self.compile(rules) } }
    private var compiled: [GlobPattern] = []

    /// Invalid patterns and later repeats of a pattern are dropped.
    public init(rules: [FilterRule] = []) {
        self.rules = Self.pruned(rules)
        compiled = Self.compile(self.rules)
    }

    /// True when no rule is enabled.
    public var isEmpty: Bool { compiled.isEmpty }

    public func hides(_ path: RepoPath) -> Bool { compiled.contains { $0.matches(path) } }

    public enum AddError: Error, Equatable { case invalid, duplicate }

    /// Trims `text` and appends it as an enabled rule. A pattern already present, enabled or not, is a duplicate.
    @discardableResult
    public mutating func add(_ text: String) -> Result<FilterRule, AddError> {
        guard let glob = GlobPattern(text) else { return .failure(.invalid) }
        guard !rules.contains(where: { $0.pattern == glob.text }) else { return .failure(.duplicate) }
        let rule = FilterRule(pattern: glob.text)
        rules.append(rule)
        return .success(rule)
    }

    public mutating func remove(_ pattern: String) { rules.removeAll { $0.pattern == pattern } }

    public mutating func setEnabled(_ enabled: Bool, for pattern: String) {
        guard let i = rules.firstIndex(where: { $0.pattern == pattern }) else { return }
        rules[i].isEnabled = enabled
    }

    /// Counts `*.<ext>` for every file name with an extension and `*.<a>.<b>` when the name has two, skipping dotfiles
    /// and patterns already present as rules. Sorted by count descending, then pattern.
    public static func suggestions<S: Sequence>(for files: S, excluding filter: FileFilter, limit: Int) -> [Suggestion] where S.Element == RepoPath {
        var counts: [String: Int] = [:]
        for path in files {
            let name = path.name
            guard !name.hasPrefix(".") else { continue }
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 2, let last = parts.last, !last.isEmpty else { continue }
            counts["*.\(escaped(last))", default: 0] += 1
            if parts.count >= 3 {
                let previous = parts[parts.count - 2]
                if !previous.isEmpty { counts["*.\(escaped(previous)).\(escaped(last))", default: 0] += 1 }
            }
        }
        let present = Set(filter.rules.map(\.pattern))
        let ranked = counts.filter { !present.contains($0.key) }
            .map { Suggestion(pattern: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.pattern < $1.pattern }
        return Array(ranked.prefix(limit))
    }

    /// Backslash-escapes the characters a glob reads specially, so a suggestion matches the suffix literally.
    private static func escaped<S: StringProtocol>(_ fragment: S) -> String {
        var out = ""
        for c in fragment {
            if "*?[\\".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    // MARK: - Codable (rules only)

    private enum CodingKeys: String, CodingKey { case rules }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(rules: try container.decode([FilterRule].self, forKey: .rules))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rules, forKey: .rules)
    }

    private static func pruned(_ rules: [FilterRule]) -> [FilterRule] {
        var seen = Set<String>()
        return rules.filter { GlobPattern($0.pattern) != nil && seen.insert($0.pattern).inserted }
    }

    private static func compile(_ rules: [FilterRule]) -> [GlobPattern] {
        rules.filter(\.isEnabled).compactMap { GlobPattern($0.pattern) }
    }
}
