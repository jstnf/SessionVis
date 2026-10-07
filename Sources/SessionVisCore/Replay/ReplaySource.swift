import Foundation

/// Plays one transcript (and its subagents) back at speed.
public struct ReplaySource: Sendable {
    public let transcriptURL: URL
    public let speed: Double
    /// Long idle gaps are capped so a replay never stalls.
    public static let maxGap: TimeInterval = 5

    public init(transcriptURL: URL, speed: Double = 10) {
        self.transcriptURL = transcriptURL
        self.speed = max(0.01, speed)
    }

    public struct Scheduled: Equatable, Sendable {
        public let delay: TimeInterval
        public let event: SourceEvent
    }

    /// Pure: merges main and subagent lines by timestamp, inherits missing timestamps from the previous entry,
    /// and converts gaps into scaled, capped delays. A subagent's `subagentAppeared` sits at its first line's time.
    static func schedule(sessionId: String, main: [TranscriptLine], subagents: [(DiscoveredSubagent, [TranscriptLine])], speed: Double) -> [Scheduled] {
        struct Entry { let time: Date; let order: Int; let event: SourceEvent }
        var entries: [Entry] = []
        var order = 0
        func fill(_ lines: [TranscriptLine]) -> [(Date, TranscriptLine)] {
            var last = Date.distantPast
            return lines.map { l in
                if let t = l.timestamp { last = t }
                return (last, l)
            }
        }
        for (t, l) in fill(main) { entries.append(Entry(time: t, order: order, event: .line(sessionId: sessionId, agentId: nil, l))); order += 1 }
        for (sub, lines) in subagents {
            let filled = fill(lines)
            let appearAt = filled.first?.0 ?? .distantPast
            entries.append(Entry(time: appearAt, order: order, event: .subagentAppeared(sessionId: sessionId, agentId: sub.agentId, meta: sub.meta))); order += 1
            for (t, l) in filled { entries.append(Entry(time: t, order: order, event: .line(sessionId: sessionId, agentId: sub.agentId, l))); order += 1 }
        }
        entries.sort { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }

        var out: [Scheduled] = [Scheduled(delay: 0, event: .sessionAppeared(sessionId: sessionId, transcriptURL: URL(fileURLWithPath: "/dev/null")))]
        var previous: Date?
        for e in entries {
            var delay: TimeInterval = 0
            if let p = previous, e.time != .distantPast { delay = min(Self.maxGap, max(0, e.time.timeIntervalSince(p) / speed)) }
            if e.time != .distantPast { previous = e.time }
            out.append(Scheduled(delay: delay, event: e.event))
        }
        return out
    }

    public func events() -> AsyncStream<SourceEvent> {
        let (stream, continuation) = AsyncStream<SourceEvent>.makeStream()
        let url = transcriptURL, speed = speed
        Task.detached {
            let sessionId = url.deletingPathExtension().lastPathComponent
            let main = await TranscriptTailer(url: url).readNewLines()
            var subs: [(DiscoveredSubagent, [TranscriptLine])] = []
            for s in SessionDiscovery.listSubagents(sessionTranscriptURL: url) {
                subs.append((s, await TranscriptTailer(url: s.transcriptURL).readNewLines()))
            }
            for item in ReplaySource.schedule(sessionId: sessionId, main: main, subagents: subs, speed: speed) {
                if item.delay > 0 { try? await Task.sleep(for: .seconds(item.delay)) }
                if Task.isCancelled { break }
                switch item.event {
                case .sessionAppeared(let sid, _):
                    continuation.yield(.sessionAppeared(sessionId: sid, transcriptURL: url))
                    continuation.yield(.initialLoadComplete)
                case .line(let sid, let aid, var line):
                    // Rebase to wall-clock time: the store ages and windows touches on its own clock.
                    line.timestamp = Date()
                    continuation.yield(.line(sessionId: sid, agentId: aid, line))
                default:
                    continuation.yield(item.event)
                }
            }
            continuation.finish()
        }
        return stream
    }
}
