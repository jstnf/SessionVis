import Foundation
import Testing
@testable import SessionVisCore

@Suite struct TabListTests {
    @Test func openAppendsAndSelectsOncePerDirectory() {
        var l = TabList()
        let a = l.open(directory: "/r/a")
        let b = l.open(directory: "/r/b/")
        #expect(l.entries.map(\.directory) == ["/r/a", "/r/b"])
        #expect(l.selectedID == b)
        let again = l.open(directory: "/r/a/")
        #expect(again == a)
        #expect(l.entries.count == 2 && l.selectedID == a)
        #expect(l.selected?.name == "a" && l.index(of: b) == 1)
        #expect(l.entry(forDirectory: "/r/b")?.id == b && l.entry(forDirectory: "/r/c") == nil)
    }

    @Test func closeMovesSelectionToTheFollowingThenPrecedingTab() {
        var l = TabList()
        let a = l.open(directory: "/a"), b = l.open(directory: "/b"), c = l.open(directory: "/c")
        l.select(b)
        let closedB = l.close(b)
        #expect(closedB && l.selectedID == c)
        let closedC = l.close(c)
        #expect(closedC && l.selectedID == a)
        let closedA = l.close(a)
        #expect(closedA && l.selectedID == nil && l.isEmpty)
        let closedAgain = l.close(a)
        #expect(!closedAgain)
    }

    @Test func closingAnUnselectedTabKeepsTheSelection() {
        var l = TabList()
        let a = l.open(directory: "/a")
        _ = l.open(directory: "/b")
        let c = l.open(directory: "/c")
        l.select(a)
        let closed = l.close(c)
        #expect(closed)
        #expect(l.selectedID == a && l.entries.count == 2)
    }

    @Test func nextAndPreviousWrapAndIndexSelectionIsBounded() {
        var l = TabList()
        l.selectNext()
        #expect(l.selectedID == nil)
        let a = l.open(directory: "/a"), b = l.open(directory: "/b"), c = l.open(directory: "/c")
        l.select(a)
        l.selectPrevious()
        #expect(l.selectedID == c)
        l.selectNext()
        #expect(l.selectedID == a)
        l.selectNext()
        #expect(l.selectedID == b)
        l.select(index: 2)
        #expect(l.selectedID == c)
        l.select(index: 3)
        #expect(l.selectedID == c)
        l.select(index: -1)
        #expect(l.selectedID == c)
        l.select(UUID())
        #expect(l.selectedID == c)
    }

    @Test func moveClampsToTheList() {
        var l = TabList()
        let a = l.open(directory: "/a")
        _ = l.open(directory: "/b")
        _ = l.open(directory: "/c")
        l.move(a, by: 1)
        #expect(l.entries.map(\.name) == ["b", "a", "c"])
        l.move(a, by: 5)
        #expect(l.entries.map(\.name) == ["b", "c", "a"])
        l.move(a, by: -9)
        #expect(l.entries.map(\.name) == ["a", "b", "c"])
        l.move(UUID(), by: 1)
        #expect(l.entries.map(\.name) == ["a", "b", "c"])
    }

    @Test func replayTabsAreSeparateAndNeverMatchedByOpen() {
        var l = TabList()
        let a = l.open(directory: "/a")
        let r = l.openReplay(directory: "/a", transcript: "/t.jsonl", speed: 20)
        #expect(l.entries.count == 2 && l.selectedID == r)
        #expect(l.selected?.isReplay == true && l.selected?.replay == ReplayRequest(transcript: "/t.jsonl", speed: 20))
        let again = l.open(directory: "/a")
        #expect(again == a)
        #expect(l.entries.count == 2 && l.entry(forDirectory: "/a")?.id == a)
    }

    @Test func openReplacingSelectsAnExistingTabRepointsOrAppends() {
        var l = TabList()
        let a = l.open(directory: "/a"), b = l.open(directory: "/b")
        let existing = l.open(directory: "/a", replacing: b)       // existing directory: select it, drop b
        #expect(existing == a)
        #expect(l.entries.map(\.name) == ["a"] && l.selectedID == a)
        let repointed = l.open(directory: "/c", replacing: a)      // new directory: re-point in place, same id
        #expect(repointed == a)
        #expect(l.entries.map(\.name) == ["c"] && l.selected?.id == a)
        let unchanged = l.open(directory: "/c", replacing: a)      // same tab, same directory: nothing changes
        #expect(unchanged == a)
        #expect(l.entries.map(\.name) == ["c"])
        let r = l.openReplay(directory: "/c", transcript: "/t.jsonl", speed: 1)
        let fromReplay = l.open(directory: "/d", replacing: r)
        #expect(fromReplay == r && l.selected?.isReplay == false)
        let e = l.open(directory: "/e", replacing: UUID())         // unknown id: a plain open
        #expect(l.entries.map(\.name) == ["c", "d", "e"] && l.selectedID == e)
    }

    @Test func hueIndexIsStableAndInThePalette() {
        let a = TabEntry(directory: "/r/a"), b = TabEntry(directory: "/r/a/")
        #expect(a.hueIndex == b.hueIndex)
        #expect((0..<HuePalette.count).contains(a.hueIndex))
    }
}

@Suite struct TabPersistenceTests {
    @Test func roundTripKeepsOrderIdsAndSelection() throws {
        var l = TabList()
        let a = l.open(directory: "/a")
        _ = l.open(directory: "/b")
        l.select(a)
        let data = try #require(l.encoded())
        let back = try #require(TabList.decode(data))
        #expect(back == l)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"version\":1") && text.contains("\"directory\":\"/a\""))
    }

    @Test func replayTabsAreNotWrittenAndAReplaySelectionFallsBackToTheFirstLiveTab() throws {
        var l = TabList()
        _ = l.open(directory: "/a")
        _ = l.open(directory: "/b")
        _ = l.openReplay(directory: "/a", transcript: "/t.jsonl", speed: 5)
        let back = try #require(TabList.decode(l.encoded()))
        #expect(back.entries.map(\.directory) == ["/a", "/b"])
        #expect(back.selected?.directory == "/a")
        var only = TabList()
        _ = only.openReplay(directory: "/a", transcript: "/t.jsonl", speed: 5)
        #expect(only.encoded() == nil)
        #expect(TabList().encoded() == nil)
    }

    @Test func corruptFutureAndEmptyDataDecodeAsNil() {
        #expect(TabList.decode(nil) == nil)
        #expect(TabList.decode(Data("{broken".utf8)) == nil)
        #expect(TabList.decode(Data(#"{"version":2,"tabs":[{"id":"\#(UUID())","directory":"/a"}]}"#.utf8)) == nil)
        #expect(TabList.decode(Data(#"{"version":1,"tabs":[]}"#.utf8)) == nil)
        #expect(TabList.decode(Data(#"{"version":1,"tabs":[{"id":"\#(UUID())","directory":""}]}"#.utf8)) == nil)
    }

    @Test func decodeDropsDuplicatesAndUnknownSelection() throws {
        let id1 = UUID(), id2 = UUID()
        let json = #"{"version":1,"selected":"\#(UUID())","tabs":[{"id":"\#(id1)","directory":"/a/"},{"id":"\#(id2)","directory":"/a"},{"id":"\#(UUID())","directory":"/b"}]}"#
        let l = try #require(TabList.decode(Data(json.utf8)))
        #expect(l.entries.map(\.directory) == ["/a", "/b"])
        #expect(l.entries[0].id == id1 && l.selectedID == id1)
    }

    @Test func migrationSeedsOneTabFromTheOldDefault() {
        let l = TabList.migrated(lastDirectory: "/old/")
        #expect(l.entries.map(\.directory) == ["/old"] && l.selectedID == l.entries[0].id)
        #expect(TabList.migrated(lastDirectory: nil).isEmpty)
        #expect(TabList.migrated(lastDirectory: "").isEmpty)
    }
}

@Suite struct LaunchActionTests {
    @Test func replayNeedsADirectory() {
        #expect(TabList().launchAction(for: LaunchOptions(replayTranscript: "/t.jsonl")) == .replayNeedsDirectory)
        #expect(TabList().launchAction(for: LaunchOptions(directory: "/r", replayTranscript: "/t.jsonl", speed: 20))
                == .openReplay(directory: "/r", transcript: "/t.jsonl", speed: 20))
    }

    @Test func directoryOpensRegardlessOfPersistedTabs() {
        var l = TabList()
        _ = l.open(directory: "/a")
        #expect(l.launchAction(for: LaunchOptions(directory: "/b")) == .open(directory: "/b"))
        #expect(TabList().launchAction(for: LaunchOptions(directory: "/b")) == .open(directory: "/b"))
    }

    @Test func noArgumentsRestoresOrAsks() {
        var l = TabList()
        _ = l.open(directory: "/a")
        #expect(l.launchAction(for: LaunchOptions()) == .restore)
        #expect(TabList().launchAction(for: LaunchOptions()) == .presentOpenPanel)
    }

    private func scratchDirectory() throws -> String {
        let d = "/private/tmp/tablist-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d + "/repo", withIntermediateDirectories: true)
        return d
    }

    @Test func symlinksAndTmpSpellingsOfOneDirectoryAreOneTab() throws {
        let d = try scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: d) }
        try FileManager.default.createSymbolicLink(atPath: d + "/link", withDestinationPath: d + "/repo")
        var list = TabList()
        list.open(directory: d + "/repo")
        list.open(directory: d + "/link")
        list.open(directory: (d + "/repo").replacingOccurrences(of: "/private/tmp", with: "/tmp"))
        #expect(list.entries.count == 1)
        #expect(list.entries[0].directory == d + "/repo")
    }

    @Test func caseVariantsOfOneDirectoryAreOneTab() throws {
        let d = try scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: d) }
        var list = TabList()
        list.open(directory: d + "/repo")
        list.open(directory: d + "/REPO")
        #expect(list.entries.count == 1)
    }

    @Test func missingDirectoriesFallBackToLexicalNormalisation() {
        #expect(TabEntry(directory: "/no/such//dir/../place/").directory == "/no/such/place")
    }

    @Test func decodeDropsDuplicateIdsAndDirectoriesKeepingTheFirst() throws {
        let id = UUID().uuidString
        let json = #"{"version":1,"selected":"\#(id)","tabs":[{"id":"\#(id)","directory":"/a"},{"id":"\#(id)","directory":"/b"},{"id":"\#(UUID().uuidString)","directory":"/a/"},{"id":"\#(UUID().uuidString)","directory":"/c"}]}"#
        let list = try #require(TabList.decode(Data(json.utf8)))
        #expect(list.entries.map(\.directory) == ["/a", "/c"])
        #expect(Set(list.entries.map(\.id)).count == 2)
    }

    @Test func moveClampsExtremeOffsets() {
        var list = TabList()
        let a = list.open(directory: "/a"), b = list.open(directory: "/b"), c = list.open(directory: "/c")
        list.move(a, by: Int.max)
        #expect(list.entries.map(\.id) == [b, c, a])
        list.move(a, by: Int.min)
        #expect(list.entries.map(\.id) == [a, b, c])
    }

    @Test func aTabStoredWhileDanglingMergesOnceItsDirectoryIsBack() throws {
        let base = "/private/tmp/tablist-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createSymbolicLink(atPath: base + "/link", withDestinationPath: base + "/real")
        var list = TabList()
        let dangling = list.open(directory: base + "/link")
        try FileManager.default.createDirectory(atPath: base + "/real", withIntermediateDirectories: true)
        list.open(directory: base + "/real")
        #expect(list.entries.count == 1)
        #expect(list.entries[0].id == dangling)
        var other = TabList()
        let base2 = base + "/second"
        try FileManager.default.createSymbolicLink(atPath: base2, withDestinationPath: base + "/later")
        let id = other.open(directory: base2)
        #expect(other.entries[0].directory == base2)      // dangling: lexical
        try FileManager.default.createDirectory(atPath: base + "/later", withIntermediateDirectories: true)
        #expect(other.recanonicalize(id)?.changed == true)
        #expect(other.entries[0].directory == base + "/later")
    }
}
