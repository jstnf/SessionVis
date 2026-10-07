import Foundation
import Testing
@testable import SessionVisCore

@Suite struct TranscriptTailerTests {
    func tempFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tailer-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }
    func append(_ s: String, to url: URL) throws { try append(Data(s.utf8), to: url) }
    func append(_ d: Data, to url: URL) throws {
        let h = try FileHandle(forWritingTo: url); try h.seekToEnd(); try h.write(contentsOf: d); try h.close()
    }
    let title = #"{"type":"ai-title","aiTitle":"T","sessionId":"s"}"#

    @Test func readsAppendedLinesIncrementally() async throws {
        let url = tempFile(); let t = TranscriptTailer(url: url)
        try append(title + "\n" + title + "\n", to: url)
        #expect(await t.readNewLines().count == 2)
        #expect(await t.readNewLines().isEmpty)
        try append(title + "\n", to: url)
        #expect(await t.readNewLines().count == 1)
    }

    @Test func partialLineIsHeldUntilNewline() async throws {
        let url = tempFile(); let t = TranscriptTailer(url: url)
        let half = title.prefix(10); let rest = title.dropFirst(10)
        try append(String(half), to: url)
        #expect(await t.readNewLines().isEmpty)
        try append(String(rest) + "\n", to: url)
        let lines = await t.readNewLines()
        #expect(lines.count == 1)
        #expect(lines[0].event == .title("T"))
    }

    @Test func partialMultibyteCharacterIsReassembled() async throws {
        let url = tempFile(); let t = TranscriptTailer(url: url)
        let line = #"{"type":"ai-title","aiTitle":"héllo","sessionId":"s"}"# + "\n"
        let bytes = Data(line.utf8)
        let cut = line.utf8.distance(from: line.utf8.startIndex, to: line.utf8.firstIndex(of: 0xC3)!) + 1 // split inside "é"
        try append(bytes.prefix(cut), to: url)
        #expect(await t.readNewLines().isEmpty)
        try append(bytes.dropFirst(cut), to: url)
        #expect(await t.readNewLines().first?.event == .title("héllo"))
    }

    @Test func malformedLinesAreSkippedAndCounted() async throws {
        let url = tempFile(); let t = TranscriptTailer(url: url)
        try append("not json\n" + title + "\n\n", to: url)
        let lines = await t.readNewLines()
        #expect(lines.count == 1)
        #expect(await t.skippedLines == 1)   // "not json" only; blank lines are ignored silently
    }

    @Test func shrinkResetsToStart() async throws {
        let url = tempFile(); let t = TranscriptTailer(url: url)
        try append(title + "\n" + title + "\n", to: url)
        _ = await t.readNewLines()
        try Data((title + "\n").utf8).write(to: url)   // replaced with a shorter file
        #expect(await t.readNewLines().count == 1)
        #expect(await t.offset == UInt64((title + "\n").utf8.count))
    }

    @Test func missingFileYieldsNothing() async {
        let t = TranscriptTailer(url: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jsonl"))
        #expect(await t.readNewLines().isEmpty)
    }

    @Test func fileWatcherFiresOnWrite() async throws {
        let url = tempFile()
        let fired = AsyncStream<Void>.makeStream()
        let w = FileWatcher(path: url.path, directory: false) { fired.continuation.yield() }
        #expect(w != nil)
        try append("x\n", to: url)
        let stream = fired.stream
        let got = await withTaskGroup(of: Bool.self) { g in
            g.addTask { var it = stream.makeAsyncIterator(); return await it.next() != nil }
            g.addTask { try? await Task.sleep(for: .seconds(2)); return false }
            let first = await g.next()!; g.cancelAll(); return first
        }
        #expect(got)
        w?.cancel()
    }
}
