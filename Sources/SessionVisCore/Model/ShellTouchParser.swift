import Foundation

/// A file or directory a shell command read or wrote, as far as its text shows.
public struct ShellTouch: Equatable, Sendable {
    public let path: String        // absolute, lexically normalised
    public let kind: TouchKind
    public let scope: TouchScope
    public let verb: String
    public init(path: String, kind: TouchKind, scope: TouchScope, verb: String) {
        self.path = path; self.kind = kind; self.scope = scope; self.verb = verb
    }
}

/// Turns the operands of common shell commands into touches. A fixed grammar: anything it does not know yields nothing.
public enum ShellTouchParser {
    indirect enum Token: Equatable {
        case word(String)
        case op(String)        // "&&", "||", "|", ";", "\n", ">", ">>", "<", "<<", "2>", "2>>", "&>", "2>&1", "(", "<(", ")"
        case group([Token])    // a subshell or process substitution: its own commands, with its own `cd`
    }

    static let readVerbs: Set<String> = ["cat", "head", "tail", "less", "more", "wc", "stat", "file", "od", "xxd", "nl", "tac"]
    static let directoryVerbs: Set<String> = ["ls", "tree", "find", "du"]
    static let grepVerbs: Set<String> = ["grep", "egrep", "fgrep", "rg"]
    static let wrappers: Set<String> = ["sudo", "env", "time", "nohup", "command", "nice"]
    /// Flags that take the next token as their argument, per verb.
    static let argFlags: [String: Set<String>] = [
        "sed": ["-e", "-f", "--expression", "--file"],
        "awk": ["-F", "-v", "-f"],
        "grep": ["-e", "-f", "-m", "-A", "-B", "-C", "--include", "--exclude", "--exclude-dir"],
        "egrep": ["-e", "-f", "-m", "-A", "-B", "-C"], "fgrep": ["-e", "-f", "-m", "-A", "-B", "-C"],
        "rg": ["-e", "-g", "-t", "-T", "-m", "-A", "-B", "-C", "--type", "--glob", "--max-count", "--regexp"],
        "head": ["-n", "-c"], "truncate": ["-s", "-r", "--size", "--reference"], "xxd": ["-l", "-s", "-c"], "stat": ["-f", "--format"], "tail": ["-n", "-c"], "cp": ["-t"], "wc": [], "cat": [], "ls": [], "find": [], "tree": ["-L", "-P", "-I", "--filelimit"], "du": ["-d", "--max-depth", "-B", "--block-size"],
    ]
    static let skipChars: Set<Character> = ["*", "?", "[", "$", "`", "~"]

    public static func touches(in command: String, cwd: String) -> [ShellTouch] {
        var out: [ShellTouch] = []
        var dir: String? = PathFolder.normalize(cwd)
        walk(nest(tokenize(command)), cwd: cwd, dir: &dir, out: &out)
        return Array(out.prefix(Constants.shellOperandLimit))
    }

    /// Touches of each segment in order. A group runs first, with a copy of the directory, so a `cd` inside it does not leak out.
    static func walk(_ tokens: [Token], cwd: String, dir: inout String?, out: inout [ShellTouch]) {
        for segment in segments(tokens) {
            guard out.count < Constants.shellOperandLimit else { return }
            for case .group(let inner) in segment {
                var scoped = dir
                walk(inner, cwd: cwd, dir: &scoped, out: &out)
            }
            let (words, redirects) = split(segment)
            var ws = words
            while let f = ws.first, isAssignment(f) { ws.removeFirst() }
            while let f = ws.first, wrappers.contains(f) { ws.removeFirst() }
            guard let rawVerb = ws.first else { continue }
            let verb = String(rawVerb.split(separator: "/").last ?? Substring(rawVerb))
            let args = Array(ws.dropFirst())
            if verb == "cd" {
                // `cd -P dir`, `cd -- dir`: flags come first; a lone `-` is the previous directory, which stays unknown.
                let target = args.first { !($0.hasPrefix("-") && $0 != "-") }
                dir = target.map { resolve($0, in: dir) } ?? PathFolder.normalize(cwd)
                continue
            }
            var found: [ShellTouch] = []
            func add(_ operand: String, _ kind: TouchKind, _ scope: TouchScope, _ v: String) {
                guard let p = resolve(operand, in: dir) else { return }
                found.append(ShellTouch(path: p, kind: kind, scope: scope, verb: v))
            }
            let operands = nonFlags(args, verb: verb)
            switch verb {
            case _ where readVerbs.contains(verb):
                for o in operands { add(o, .read, .file, verb) }
            case "sed":
                let inPlace = args.contains { $0 == "-i" || $0.hasPrefix("-i") && !$0.hasPrefix("-in") || $0 == "--in-place" || $0.hasPrefix("--in-place=") }
                let hasScriptFlag = args.contains { $0 == "-e" || $0 == "-f" || $0 == "--expression" || $0 == "--file" }
                for o in hasScriptFlag ? operands : Array(operands.dropFirst()) { add(o, inPlace ? .write : .read, .file, verb) }
            case "awk":
                let hasProgramFile = args.contains("-f")
                for o in hasProgramFile ? operands : Array(operands.dropFirst()) { add(o, .read, .file, verb) }
            case _ where grepVerbs.contains(verb):
                let hasPatternFlag = args.contains { ["-e", "-f", "--regexp"].contains($0) }
                let recursive = verb == "rg" || args.contains { $0 == "--recursive" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && ($0.contains("r") || $0.contains("R"))) }
                for o in hasPatternFlag ? operands : Array(operands.dropFirst()) { add(o, .read, recursive ? .directory : .file, verb) }
            case _ where directoryVerbs.contains(verb):
                add(operands.first ?? ".", .read, .directory, verb)
            case "diff", "cmp":
                for o in operands.prefix(2) { add(o, .read, .file, verb) }
            case "cp":
                guard operands.count >= 2, let dest = operands.last else { break }
                for o in operands.dropLast() { add(o, .read, .file, verb) }
                let dirDest = dest.hasSuffix("/") || args.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && ($0.contains("r") || $0.contains("R") || $0.contains("a")) }
                add(dest, .write, dirDest ? .directory : .file, verb)
            case "mv":
                if operands.count >= 2, let dest = operands.last { add(dest, .write, .file, verb) }
            case "tee", "touch", "truncate":
                for o in operands { add(o, .write, .file, verb) }
            default:
                break
            }
            for (op, target) in redirects {
                switch op {
                case ">", ">>", "&>": add(target, .write, .file, ">")
                case "<": add(target, .read, .file, "<")
                default: break
                }
            }
            out.append(contentsOf: found)
        }
    }

    // MARK: - Tokenising

    /// Quote-aware tokens; heredoc bodies and comments are skipped entirely. Command and arithmetic substitutions
    /// (`$(…)`, backticks, `$((…))`) stay inside their word, whose `$` or backtick then keeps it from being an operand;
    /// `((…))` arithmetic yields nothing; standalone `{` and `}` separate commands.
    static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        var word = ""
        var hasWord = false
        var pendingHeredocs: [String] = []
        var expectDelimiter = false
        let chars = Array(s)
        var i = 0
        func flush() {
            if hasWord {
                if expectDelimiter { pendingHeredocs.append(word); expectDelimiter = false }
                else if word == "{" || word == "}" { tokens.append(.op(";")) }
                else { tokens.append(.word(word)) }
                word = ""; hasWord = false
            }
        }
        /// Index just past the `)` that balances the `(` at `start`, or the end of input. Quotes are not tracked,
        /// so a heredoc body with an apostrophe (a commit message) cannot run the scan away.
        func balancedEnd(_ start: Int) -> Int {
            var depth = 0
            var k = start
            while k < chars.count {
                switch chars[k] {
                case "\\": k += 1
                case "(": depth += 1
                case ")":
                    depth -= 1
                    if depth == 0 { return k + 1 }
                default: break
                }
                k += 1
            }
            return chars.count
        }
        /// Index just past the backtick closing the one at `start`, or the end of input.
        func backtickEnd(_ start: Int) -> Int {
            var k = start + 1
            while k < chars.count, chars[k] != "`" { k += chars[k] == "\\" ? 2 : 1 }
            return min(k + 1, chars.count)
        }
        /// Appends a substitution starting at `i` to the current word, if one starts there.
        func takeSubstitution() -> Bool {
            let end: Int
            if chars[i] == "$", i + 1 < chars.count, chars[i + 1] == "(" { end = balancedEnd(i + 1) }
            else if chars[i] == "`" { end = backtickEnd(i) }
            else { return false }
            word.append(contentsOf: chars[i..<end]); hasWord = true; i = end
            return true
        }
        func skipHeredocBodies() {
            // `i` is just past a newline; consume lines until each pending delimiter has been seen in order.
            for delim in pendingHeredocs {
                while i < chars.count {
                    var line = ""
                    while i < chars.count, chars[i] != "\n" { line.append(chars[i]); i += 1 }
                    if i < chars.count { i += 1 }
                    if line.trimmingCharacters(in: .whitespaces) == delim { break }
                }
            }
            pendingHeredocs.removeAll()
        }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "'":
                i += 1
                while i < chars.count, chars[i] != "'" { word.append(chars[i]); i += 1 }
                guard i < chars.count else { return [] }   // unterminated: the shell would not run it
                i += 1; hasWord = true
            case "\"":
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if takeSubstitution() { continue }
                    if chars[i] == "\\", i + 1 < chars.count { i += 1 }
                    word.append(chars[i]); i += 1
                }
                guard i < chars.count else { return [] }
                i += 1; hasWord = true
            case "\\":
                guard i + 1 < chars.count else { return [] }   // a trailing backslash continues onto a line that never came
                word.append(chars[i + 1]); hasWord = true; i += 2
            case "$", "`":
                if !takeSubstitution() { word.append(c); hasWord = true; i += 1 }
            case "#" where !hasWord:
                while i < chars.count, chars[i] != "\n" { i += 1 }
            case "(":
                flush()
                if i + 1 < chars.count, chars[i + 1] == "(" {
                    i = balancedEnd(i)          // `(( n > 3 ))` arithmetic
                } else {
                    tokens.append(.op("(")); i += 1
                }
            case ")":
                flush(); tokens.append(.op(")")); i += 1
            case " ", "\t":
                flush(); i += 1
            case "\n":
                flush(); tokens.append(.op("\n")); i += 1
                if !pendingHeredocs.isEmpty { skipHeredocBodies() }
            case "&", "|", ";", ">", "<", "1", "2":
                // A file descriptor digit only starts a redirect at the beginning of a token.
                var j = i
                if c == "1" || c == "2" {
                    guard !hasWord, i + 1 < chars.count, chars[i + 1] == ">" else {
                        word.append(c); hasWord = true; i += 1
                        continue
                    }
                    j = i + 1
                }
                let fd = j > i ? c : Character(" ")
                let rest = String(chars[j..<min(chars.count, j + 3)])
                flush()
                if rest.hasPrefix("<(") || rest.hasPrefix(">(") {
                    tokens.append(.op("<(")); i = j + 2
                } else if rest.hasPrefix("<<<") {
                    tokens.append(.op("<<<")); i = j + 3
                } else if rest.hasPrefix("<<-") {
                    expectDelimiter = true; i = j + 3
                } else if rest.hasPrefix("<<") {
                    expectDelimiter = true; i = j + 2
                } else if rest.hasPrefix(">&") {
                    // `>&N` / `>&-` duplicates or closes a descriptor and names no file.
                    if j + 2 < chars.count, chars[j + 2].isNumber || chars[j + 2] == "-" {
                        i = j + 3
                    } else {
                        tokens.append(.op(">")); i = j + 2
                    }
                } else if rest.hasPrefix(">>") {
                    tokens.append(.op(fd == "2" ? "2>>" : ">>")); i = j + 2
                } else if rest.hasPrefix(">") {
                    tokens.append(.op(fd == "2" ? "2>" : ">")); i = j + 1
                } else if rest.hasPrefix("<") {
                    tokens.append(.op("<")); i = j + 1
                } else if rest.hasPrefix("&&") {
                    tokens.append(.op("&&")); i = j + 2
                } else if rest.hasPrefix("&>") {
                    i = j + 2
                    if i < chars.count, chars[i] == ">" { i += 1 }
                    tokens.append(.op("&>"))
                } else if rest.hasPrefix("&") {
                    tokens.append(.op(";")); i = j + 1
                } else if rest.hasPrefix("||") {
                    tokens.append(.op("||")); i = j + 2
                } else if rest.hasPrefix("|") {
                    tokens.append(.op("|")); i = j + 1
                } else {
                    tokens.append(.op(";")); i = j + 1
                }
            default:
                word.append(c); hasWord = true; i += 1
            }
        }
        flush()
        return tokens
    }

    /// Turns `(`…`)` and `<(`…`)` runs into groups. An unmatched `)` separates commands; an unclosed group runs to the end.
    static func nest(_ tokens: [Token]) -> [Token] {
        var i = 0
        return nest(tokens, from: &i, inGroup: false)
    }

    private static func nest(_ tokens: [Token], from i: inout Int, inGroup: Bool) -> [Token] {
        var out: [Token] = []
        while i < tokens.count {
            let t = tokens[i]
            i += 1
            switch t {
            case .op("("), .op("<("): out.append(.group(nest(tokens, from: &i, inGroup: true)))
            case .op(")"):
                if inGroup { return out }
                out.append(.op(";"))
            default: out.append(t)
            }
        }
        return out
    }

    /// Splits on `&&`, `||`, `|`, `;` and newlines; empty segments dropped.
    static func segments(_ tokens: [Token]) -> [[Token]] {
        var out: [[Token]] = []
        var current: [Token] = []
        for t in tokens {
            if case .op(let o) = t, ["&&", "||", "|", ";", "\n"].contains(o) {
                if !current.isEmpty { out.append(current) }
                current = []
            } else {
                current.append(t)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Words of a segment, and its redirections as (operator, target).
    static func split(_ segment: [Token]) -> (words: [String], redirects: [(String, String)]) {
        var words: [String] = []
        var redirects: [(String, String)] = []
        var i = 0
        while i < segment.count {
            switch segment[i] {
            case .word(let w): words.append(w); i += 1
            case .group: i += 1
            case .op(let o):
                if i + 1 < segment.count, case .word(let target) = segment[i + 1] {
                    redirects.append((o, target)); i += 2
                } else { i += 1 }
            }
        }
        return (words, redirects)
    }

    static func isAssignment(_ token: String) -> Bool {
        guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { return false }
        let name = token[..<eq]
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } && !(name.first?.isNumber ?? true)
    }

    /// Arguments that are not flags and not the argument of a flag.
    static func nonFlags(_ args: [String], verb: String) -> [String] {
        let takesArg = argFlags[verb] ?? []
        var out: [String] = []
        var i = 0
        var flagsEnded = false
        while i < args.count {
            let a = args[i]
            if a.isEmpty { i += 1; continue }                       // `''` (as in `sed -i ''`) is not an operand
            if a == "--" { flagsEnded = true; i += 1; continue }
            if !flagsEnded, a.hasPrefix("-"), a != "-" {
                i += takesArg.contains(a) ? 2 : 1
                continue
            }
            out.append(a); i += 1
        }
        return out
    }

    /// Characters no operand worth a touch contains: what is left of a construct the tokeniser did not understand.
    static let rejectChars: Set<Character> = ["(", ")", "{", "}"]

    /// Absolute normalised path for an operand, or nil for operands that cannot be resolved lexically.
    static func resolve(_ operand: String, in dir: String?) -> String? {
        guard !operand.isEmpty, operand != "-", !operand.contains(where: { skipChars.contains($0) || rejectChars.contains($0) }),
              !operand.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !operand.hasPrefix("/dev/") else { return nil }
        if operand.hasPrefix("/") { return PathFolder.normalize(operand) }
        guard let dir else { return nil }
        return PathFolder.normalize(dir + "/" + operand)
    }
}
