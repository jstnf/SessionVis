import Foundation

/// Reads a JSONL transcript incrementally by byte offset.
public actor TranscriptTailer {
    public nonisolated let url: URL
    public private(set) var offset: UInt64 = 0
    public private(set) var skippedLines = 0
    private var partial = Data()

    public init(url: URL) { self.url = url }

    /// Reads from `offset` to EOF and returns every complete line's events. Safe to call repeatedly.
    public func readNewLines() -> [TranscriptLine] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return [] }
        if size < offset { offset = 0; partial.removeAll() }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let chunk = try? handle.readToEnd(), !chunk.isEmpty else { return [] }
        offset += UInt64(chunk.count)

        var buffer = partial + chunk
        var out: [TranscriptLine] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer = buffer[buffer.index(after: nl)...]
            out.append(contentsOf: parse(lineData))
        }
        partial = Data(buffer)
        return out
    }

    private func parse(_ data: Data) -> [TranscriptLine] {
        guard let s = String(data: data, encoding: .utf8) else { skippedLines += 1; return [] }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)   // tolerate \r\n
        if trimmed.isEmpty { return [] }
        do { return try TranscriptParser.parse(line: trimmed) }
        catch { skippedLines += 1; return [] }
    }
}
