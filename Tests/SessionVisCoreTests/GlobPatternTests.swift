import Foundation
import Testing
@testable import SessionVisCore

@Suite struct GlobPatternTests {
    func matches(_ pattern: String, _ path: String) -> Bool {
        guard let g = GlobPattern(pattern) else { Issue.record("\(pattern) did not compile"); return false }
        return g.matches(RepoPath(string: path))
    }

    func check(_ table: [(String, String, Bool)]) {
        for (p, path, expected) in table { #expect(matches(p, path) == expected, "\(p) vs \(path)") }
    }

    @Test func namePatternsMatchAnyComponentAtAnyDepth() {
        check([
            ("*.swift", "a.swift", true),
            ("*.swift", "Sources/App/Main.swift", true),
            ("*.swift", "Sources/App/Main.swift.bak", false),
            ("*.graphql.swift", "Gen/Q.graphql.swift", true),
            ("*.graphql.swift", "Gen/Q.swift", false),
            ("Package.resolved", "Package.resolved", true),
            ("Package.resolved", "Sub/Package.resolved", true),
            ("Generated", "Sources/Generated/A.swift", true),          // a directory component
            ("Generated", "Sources/Generated2/A.swift", false),
            ("Generated/", "Sources/Generated/A.swift", true),         // a trailing slash means the same as none
            ("build/", "build", false), ("build/", "build/x", true), ("build/", "a/build/x", true),
            ("Sources/**", "Sources", false), ("Sources/**", "Sources/a/b", true),
            ("*", "anything/at/all", true),
            ("**", "anything", true),
        ])
    }

    @Test func wildcardsSetsAndEscapes() {
        check([
            ("?.swift", "a.swift", true), ("?.swift", "ab.swift", false),
            ("a?c", "abc", true), ("a?c", "ac", false),
            ("[abc].txt", "b.txt", true), ("[abc].txt", "d.txt", false),
            ("[a-c].txt", "b.txt", true), ("[a-c].txt", "d.txt", false),
            ("[!a-c].txt", "d.txt", true), ("[!a-c].txt", "b.txt", false),
            ("[^abc].txt", "d.txt", true), ("[^abc].txt", "a.txt", false),
            ("[]a].txt", "].txt", true),                               // a leading "]" is literal
            ("[a-].txt", "-.txt", true),                               // a trailing "-" is literal
            ("a*b*c", "aXbYc", true), ("a*b*c", "aXcYb", false), ("a*b*c", "abc", true),
            ("*a*", "banana", true), ("x*y", "xy", true), ("x**y", "xzy", true),
            ("file\\*.txt", "file*.txt", true), ("file\\*.txt", "fileA.txt", false),
            ("\\[x].txt", "[x].txt", true),
            ("[\\]].txt", "].txt", true),
        ])
    }

    @Test func slashPatternsAreAnchoredAtTheRoot() {
        check([
            ("Sources/Gen", "Sources/Gen/A.swift", true),
            ("Sources/Gen", "Sources/Gen/Deep/A.swift", true),
            ("Sources/Gen", "Other/Sources/Gen/A.swift", false),
            ("/README.md", "README.md", true),
            ("/README.md", "docs/README.md", false),
            ("Sources/*.swift", "Sources/A.swift", true),
            ("Sources/*.swift", "Sources/App/A.swift", false),
            ("Sources/**", "Sources/A.swift", true),
            ("Sources/**", "Sources/App/Deep/A.swift", true),
            ("Sources/**", "Tests/A.swift", false),
            ("**/Gen", "Gen/A.swift", true),
            ("**/Gen", "A/B/Gen/C.swift", true),
            ("**/Gen", "A/Gen2/C.swift", false),
            ("Sources/**/Gen/*.swift", "Sources/Gen/A.swift", true),          // ** spans zero directories
            ("Sources/**/Gen/*.swift", "Sources/X/Gen/A.swift", true),        // one
            ("Sources/**/Gen/*.swift", "Sources/X/Y/Gen/A.swift", true),      // several
            ("Sources/**/Gen/*.swift", "Sources/X/Gen/A.txt", false),
            ("Sources/**/Gen/*.swift", "Lib/X/Gen/A.swift", false),
            ("a/**/b", "a/b", true), ("a/**/b", "a/x/b/c", true), ("a/**/b", "a/x", false),
        ])
    }

    @Test func matchingIsCaseSensitive() {
        #expect(matches("*.swift", "A.swift"))
        #expect(!matches("*.SWIFT", "a.swift"))
        #expect(!matches("readme.md", "README.md"))
    }

    @Test func invalidPatternsDoNotCompileAndTextIsTrimmed() {
        for bad in ["", "   ", "/", "//", "[abc", "a\\", "[", "x[a-", "\n"] { #expect(GlobPattern(bad) == nil, "\(bad.debugDescription) compiled") }
        #expect(GlobPattern("  *.md  ")?.text == "*.md")
        #expect(GlobPattern("*.md") == GlobPattern(" *.md "))
        #expect(GlobPattern("Generated/")?.text == "Generated/")
    }

    @Test func reversedRangesDoNotCompileAndPatternsNeverMatchTheRoot() {
        #expect(GlobPattern("[!z-a].txt") == nil)
        #expect(GlobPattern("[z-a].txt") == nil)
        #expect(GlobPattern("/**")?.matches(RepoPath([])) == false)
        #expect(GlobPattern("**")?.matches(RepoPath([])) == false)
    }
}
