import Foundation
import Testing
@testable import SessionVisCore

@Suite struct FileFilterTests {
    let md = RepoPath(string: "docs/a.md"), swift = RepoPath(string: "Sources/A.swift")

    @Test func emptyFilterHidesNothing() {
        let f = FileFilter()
        #expect(f.isEmpty && !f.hides(md) && f.rules.isEmpty)
    }

    @Test func addTrimsRejectsInvalidAndDuplicatesAndHides() {
        var f = FileFilter()
        #expect(f.add("  *.md ") == .success(FilterRule(pattern: "*.md")))
        #expect(f.add("*.md") == .failure(.duplicate))
        #expect(f.add(" *.md") == .failure(.duplicate))
        #expect(f.add("[abc") == .failure(.invalid))
        #expect(f.add("   ") == .failure(.invalid))
        #expect(f.rules == [FilterRule(pattern: "*.md")] && !f.isEmpty)
        #expect(f.hides(md) && !f.hides(swift))
        #expect(f.add("Sources/**") == .success(FilterRule(pattern: "Sources/**")))
        #expect(f.hides(swift))
    }

    @Test func disablingKeepsTheRuleButStopsHiding() {
        var f = FileFilter()
        f.add("*.md")
        f.setEnabled(false, for: "*.md")
        #expect(!f.hides(md) && f.isEmpty && f.rules == [FilterRule(pattern: "*.md", isEnabled: false)])
        #expect(f.add("*.md") == .failure(.duplicate))        // a disabled rule still counts
        f.setEnabled(true, for: "*.md")
        #expect(f.hides(md) && !f.isEmpty)
        f.setEnabled(false, for: "unknown")                   // no such rule: nothing changes
        #expect(f.rules.count == 1 && f.hides(md))
    }

    @Test func removeForgetsTheRule() {
        var f = FileFilter()
        f.add("*.md"); f.add("Gen")
        f.remove("*.md")
        #expect(f.rules == [FilterRule(pattern: "Gen")] && !f.hides(md))
        f.remove("unknown")
        #expect(f.rules.count == 1)
        #expect(f.add("*.md") == .success(FilterRule(pattern: "*.md")))
    }

    @Test func initDropsInvalidAndRepeatedRules() {
        let f = FileFilter(rules: [FilterRule(pattern: "*.md"), FilterRule(pattern: "[bad"), FilterRule(pattern: "*.md", isEnabled: false)])
        #expect(f.rules == [FilterRule(pattern: "*.md")])
    }

    @Test func jsonRoundTripKeepsRulesAndDropsBadOnes() throws {
        var f = FileFilter()
        f.add("*.md"); f.add("Gen")
        f.setEnabled(false, for: "Gen")
        let data = try JSONEncoder().encode(f)
        #expect(String(decoding: data, as: UTF8.self).contains("\"rules\""))
        let back = try JSONDecoder().decode(FileFilter.self, from: data)
        #expect(back == f && back.hides(md) && !back.hides(RepoPath(string: "Gen/x")))
        let json = #"{"rules":[{"pattern":"*.md","isEnabled":true},{"pattern":"[bad","isEnabled":true},{"pattern":"*.md","isEnabled":false}]}"#
        let decoded = try JSONDecoder().decode(FileFilter.self, from: Data(json.utf8))
        #expect(decoded.rules == [FilterRule(pattern: "*.md")])
    }

    @Test func suggestionsRankSuffixesByCountThenName() {
        let files = ["a.graphql.swift", "b.graphql.swift", "Gen/c.graphql.swift", "d.swift", "e.swift.bak", ".gitignore", "README",
                     "Package.resolved", "x.", "y..z", "Assets.xcassets/Contents.json"].map(RepoPath.init(string:))
        let all = FileFilter.suggestions(for: files, excluding: FileFilter(), limit: 10)
        #expect(all == [
            Suggestion(pattern: "*.swift", count: 4),
            Suggestion(pattern: "*.graphql.swift", count: 3),
            Suggestion(pattern: "*.bak", count: 1),
            Suggestion(pattern: "*.json", count: 1),
            Suggestion(pattern: "*.resolved", count: 1),
            Suggestion(pattern: "*.swift.bak", count: 1),
            Suggestion(pattern: "*.z", count: 1),
        ])
        var f = FileFilter()
        f.add("*.swift")
        f.setEnabled(false, for: "*.swift")                    // present rules are left out even when disabled
        let rest = FileFilter.suggestions(for: files, excluding: f, limit: 2)
        #expect(rest == [Suggestion(pattern: "*.graphql.swift", count: 3), Suggestion(pattern: "*.bak", count: 1)])
        #expect(FileFilter.suggestions(for: [RepoPath](), excluding: f, limit: 5).isEmpty)
    }

    @Test func suggestionsEscapeGlobMetacharacters() {
        let files = ["x.b?r", "y.a[b.c*d", "z.w\\v"].map(RepoPath.init(string:))
        let patterns = FileFilter.suggestions(for: files, excluding: FileFilter(), limit: 10).map(\.pattern)
        #expect(patterns.contains("*.b\\?r") && patterns.contains("*.c\\*d") && patterns.contains("*.a\\[b.c\\*d") && patterns.contains("*.w\\\\v"))
        #expect(patterns.allSatisfy { GlobPattern($0) != nil })
        #expect(GlobPattern("*.b\\?r")?.matches(RepoPath(string: "x.b?r")) == true && GlobPattern("*.b\\?r")?.matches(RepoPath(string: "x.bar")) == false)
    }

    @Test func suggestionLimitConstantIsSet() {
        #expect(Constants.filterSuggestionLimit == 12)
    }
}
