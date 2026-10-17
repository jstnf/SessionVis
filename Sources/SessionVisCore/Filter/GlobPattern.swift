import Foundation

/// A gitignore-like glob over repository paths. A pattern without `/` names one path component and matches it at
/// any depth; a pattern with `/` is anchored at the repository root, where `**` spans any number of directories.
/// A pattern matches a file when it matches the file's path or one of its ancestor directories (only the latter for a trailing `/` or a final `**`), so `Generated`
/// hides everything under any `Generated` directory and `Sources/Gen` everything under that one.
public struct GlobPattern: Hashable, Sendable {
    /// The pattern as given, trimmed. Equality and hashing use only this.
    public let text: String
    private let segments: [Segment]
    private let anchored: Bool
    /// A trailing slash, or an anchored pattern ending in `**`, names directories only: the file itself never matches, only its ancestors.
    private let directoryOnly: Bool

    enum Segment: Equatable, Sendable {
        case anyDirectories                 // a whole-segment "**"
        case component([Token])
    }

    enum Token: Equatable, Sendable {
        case literal(Character), question, star, set(CharacterClass)
    }

    struct CharacterClass: Equatable, Sendable {
        var negated = false
        var singles: Set<Character> = []
        var ranges: [ClosedRange<Character>] = []
        func contains(_ c: Character) -> Bool {
            (singles.contains(c) || ranges.contains { $0.contains(c) }) != negated
        }
    }

    /// nil for an empty or whitespace-only pattern, "/", an unclosed "[" or a trailing "\".
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = Substring(trimmed)
        var directoryOnly = false
        if body.hasSuffix("/") { body.removeLast(); directoryOnly = true }
        let anchored = body.contains("/")
        if body.hasPrefix("/") { body.removeFirst() }
        let parts = body.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return nil }
        var segments: [Segment] = []
        for part in parts {
            if part == "**" {
                if segments.last != .anyDirectories { segments.append(.anyDirectories) }
                continue
            }
            guard let tokens = Self.tokens(of: part) else { return nil }
            segments.append(.component(tokens))
        }
        self.text = trimmed
        self.segments = segments
        self.anchored = anchored
        self.directoryOnly = directoryOnly || (anchored && segments.last == .anyDirectories)
    }

    public func matches(_ path: RepoPath) -> Bool {
        if path.isRoot { return false }
        let components = directoryOnly ? Array(path.components.dropLast()) : path.components
        if !anchored {
            // One segment: test it against every component.
            switch segments[0] {
            case .anyDirectories: return true
            case .component(let tokens): return components.contains { Self.match(tokens, component: $0) }
            }
        }
        return Self.match(segments[...], components[...])
    }

    public static func == (lhs: GlobPattern, rhs: GlobPattern) -> Bool { lhs.text == rhs.text }
    public func hash(into hasher: inout Hasher) { hasher.combine(text) }

    // MARK: - Matching

    /// Segments against components from the root. Running out of segments is a match: the path, or an ancestor of it, matched.
    private static func match(_ segs: ArraySlice<Segment>, _ comps: ArraySlice<String>) -> Bool {
        guard let seg = segs.first else { return true }
        switch seg {
        case .anyDirectories:
            let rest = segs.dropFirst()
            if rest.isEmpty { return true }
            var i = comps.startIndex
            while i <= comps.endIndex {
                if match(rest, comps[i...]) { return true }
                i += 1
            }
            return false
        case .component(let tokens):
            guard let c = comps.first, match(tokens, component: c) else { return false }
            return match(segs.dropFirst(), comps.dropFirst())
        }
    }

    /// Iterative wildcard match with single-star backtracking.
    private static func match(_ tokens: [Token], component: String) -> Bool {
        let chars = Array(component)
        var ti = 0, ci = 0, starTi: Int? = nil, starCi = 0
        while ci < chars.count {
            if ti < tokens.count {
                switch tokens[ti] {
                case .star: starTi = ti; starCi = ci; ti += 1; continue
                case .question: ti += 1; ci += 1; continue
                case .literal(let l) where l == chars[ci]: ti += 1; ci += 1; continue
                case .set(let cls) where cls.contains(chars[ci]): ti += 1; ci += 1; continue
                default: break
                }
            }
            guard let s = starTi else { return false }
            starCi += 1; ci = starCi; ti = s + 1
        }
        while ti < tokens.count, case .star = tokens[ti] { ti += 1 }
        return ti == tokens.count
    }

    // MARK: - Parsing

    /// nil for an unclosed "[" or a trailing "\". Consecutive stars collapse into one.
    private static func tokens(of part: Substring) -> [Token]? {
        let chars = Array(part)
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]; i += 1
            switch c {
            case "\\":
                guard i < chars.count else { return nil }
                tokens.append(.literal(chars[i])); i += 1
            case "*":
                if tokens.last != .star { tokens.append(.star) }
            case "?":
                tokens.append(.question)
            case "[":
                guard let cls = characterClass(chars, from: &i) else { return nil }
                tokens.append(.set(cls))
            default:
                tokens.append(.literal(c))
            }
        }
        return tokens
    }

    /// Parses a set body starting after "[" and leaves `i` after the closing "]". A leading "!" or "^" negates,
    /// a "]" right after that is literal, "a-z" is a range, "\" escapes. nil when unclosed.
    private static func characterClass(_ chars: [Character], from i: inout Int) -> CharacterClass? {
        var cls = CharacterClass()
        if i < chars.count, chars[i] == "!" || chars[i] == "^" { cls.negated = true; i += 1 }
        var first = true
        while i < chars.count {
            var c = chars[i]; i += 1
            if c == "]" && !first { return cls }
            if c == "\\" {
                guard i < chars.count else { return nil }
                c = chars[i]; i += 1
            }
            first = false
            if i + 1 < chars.count, chars[i] == "-", chars[i + 1] != "]" {
                var hi = chars[i + 1]; i += 2
                if hi == "\\" {
                    guard i < chars.count else { return nil }
                    hi = chars[i]; i += 1
                }
                guard c <= hi else { return nil }
                cls.ranges.append(c...hi)
            } else {
                cls.singles.insert(c)
            }
        }
        return nil
    }
}
