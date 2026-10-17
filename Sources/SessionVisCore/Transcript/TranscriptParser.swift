import Foundation

/// Turns one JSONL line into zero or more `TranscriptLine`s.
public enum TranscriptParser {
    public enum ParseError: Error, Equatable { case malformed }

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    public static func parseTimestamp(_ s: String) -> Date? {
        (try? fractional.parse(s)) ?? (try? plain.parse(s))
    }

    public static func parse(line: String) throws(ParseError) -> [TranscriptLine] {
        guard let data = line.data(using: .utf8), !data.isEmpty,
              let any = try? JSONSerialization.jsonObject(with: data),
              let obj = any as? [String: Any],
              let type = obj["type"] as? String else { throw ParseError.malformed }

        let envelope = TranscriptLine(
            timestamp: (obj["timestamp"] as? String).flatMap(parseTimestamp),
            cwd: obj["cwd"] as? String,
            gitBranch: obj["gitBranch"] as? String,
            agentId: obj["agentId"] as? String,
            event: .turnEnded)   // placeholder event, replaced below

        func wrap(_ events: [TranscriptEvent]) -> [TranscriptLine] {
            events.map { var l = envelope; l.event = $0; return l }
        }

        switch type {
        case "ai-title":
            guard let t = obj["aiTitle"] as? String else { return [] }
            return wrap([.title(t)])
        case "relocated":
            guard let c = obj["relocatedCwd"] as? String else { return [] }
            return wrap([.relocated(cwd: c)])
        case "worktree-state":
            guard let w = obj["worktreeSession"] as? [String: Any],
                  let name = w["worktreeName"] as? String,
                  let branch = w["worktreeBranch"] as? String,
                  let path = w["worktreePath"] as? String else { return [] }
            return wrap([.worktree(name: name, branch: branch, path: path)])
        case "user":
            return wrap(userEvents(obj))
        case "assistant":
            return wrap(assistantEvents(obj))
        case "queue-operation":
            guard obj["operation"] as? String == "enqueue", let text = obj["content"] as? String else { return [] }
            return wrap(promptIfAllowed(text, isMeta: true))   // isMeta: a queued user prompt must not count as a prompt
        case "system":
            guard obj["subtype"] as? String == "compact_boundary" else { return [] }
            let meta = obj["compactMetadata"] as? [String: Any] ?? [:]
            return wrap([.compacted(pre: tokenCount(meta["preTokens"]), post: tokenCount(meta["postTokens"]))])
        default:
            return []
        }
    }

    private static func userEvents(_ obj: [String: Any]) -> [TranscriptEvent] {
        guard let message = obj["message"] as? [String: Any] else { return [] }
        let isMeta = obj["isMeta"] as? Bool ?? false
        if let text = message["content"] as? String {
            return promptIfAllowed(text, isMeta: isMeta)
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        let results = blocks.compactMap { b -> TranscriptEvent? in
            guard b["type"] as? String == "tool_result", let id = b["tool_use_id"] as? String else { return nil }
            return .toolResult(toolUseId: id, text: resultText(b["content"]))
        }
        if !results.isEmpty { return results }
        let text = blocks.compactMap { b -> String? in
            b["type"] as? String == "text" ? b["text"] as? String : nil
        }.joined()
        return promptIfAllowed(text, isMeta: isMeta)
    }

    /// The text of a tool result: a plain string, or the `text` blocks joined by newlines; nil when empty. Capped.
    private static func resultText(_ content: Any?) -> String? {
        let text: String
        if let s = content as? String { text = s }
        else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        } else { return nil }
        guard !text.isEmpty else { return nil }
        return String(text.prefix(Constants.toolResultTextLimit))
    }

    private static func promptIfAllowed(_ text: String, isMeta: Bool) -> [TranscriptEvent] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[Request interrupted by user") { return [.interrupted] }
        if trimmed.hasPrefix("<task-notification>") {
            guard let id = tag("task-id", in: trimmed) else { return [] }
            return [.taskNotification(taskId: id, status: tag("status", in: trimmed) ?? "completed")]
        }
        guard !isMeta, !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return [] }
        return [.userPrompt(text: trimmed)]
    }

    /// The trimmed text of the first `<name>…</name>` element in `s`.
    private static func tag(_ name: String, in s: String) -> String? {
        guard let open = s.range(of: "<\(name)>"),
              let close = s.range(of: "</\(name)>", range: open.upperBound..<s.endIndex) else { return nil }
        let v = s[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    private static func assistantEvents(_ obj: [String: Any]) -> [TranscriptEvent] {
        guard let message = obj["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return [] }
        let endOfTurn = (message["stop_reason"] as? String) == "end_turn"
        var out: [TranscriptEvent] = []
        for b in blocks {
            switch b["type"] as? String {
            case "text":
                if let t = b["text"] as? String, !t.isEmpty { out.append(.assistantText(text: t, endOfTurn: endOfTurn)) }
            case "tool_use":
                guard let id = b["id"] as? String, let name = b["name"] as? String else { continue }
                let input = b["input"] as? [String: Any] ?? [:]
                let filePath: String? = switch name {
                    case "Edit", "Write", "Read": input["file_path"] as? String
                    case "NotebookEdit": input["notebook_path"] as? String
                    case "Grep", "Glob": input["path"] as? String
                    default: nil
                }
                let question = (name == "AskUserQuestion")
                    ? ((input["questions"] as? [[String: Any]])?.first?["question"] as? String) : nil
                let command: String? = name == "Bash" ? (input["command"] as? String).map { String($0.prefix(Constants.commandTextLimit)) } : nil
                out.append(.toolUse(id: id, name: name, filePath: filePath,
                                    description: input["description"] as? String, question: question, command: command))
            default:
                continue
            }
        }
        if let usage = usageEvent(message) { out.append(usage) }
        if endOfTurn { out.append(.turnEnded) }
        return out
    }

    /// The record's token accounting; nil for the synthetic record Claude Code writes on an API failure, or without an id or a usage object.
    /// A record without a model still yields the event, with a nil model.
    private static func usageEvent(_ message: [String: Any]) -> TranscriptEvent? {
        guard let id = message["id"] as? String, let usage = message["usage"] as? [String: Any] else { return nil }
        let model = message["model"] as? String
        if model == "<synthetic>" { return nil }
        func int(_ key: String) -> Int { tokenCount(usage[key]) }
        return .usage(messageID: id, model: model, input: int("input_tokens"), output: int("output_tokens"),
                      cacheRead: int("cache_read_input_tokens"), cacheCreate: int("cache_creation_input_tokens"))
    }

    /// A token count: a JSON integer (or a float with an integral value) clamped to 0...`Constants.tokenCountCap`;
    /// anything else, booleans and strings included, reads as 0.
    private static func tokenCount(_ value: Any?) -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), let n = value as? Int else { return 0 }
        return min(max(n, 0), Constants.tokenCountCap)
    }
}
