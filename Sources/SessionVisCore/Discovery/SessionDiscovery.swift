import Foundation

public struct DiscoveredSession: Equatable, Sendable {
    public let sessionId: String
    public let transcriptURL: URL
    public let modifiedAt: Date
}

public struct DiscoveredSubagent: Equatable, Sendable {
    public let agentId: String
    public let transcriptURL: URL
    public let meta: SubagentMeta
    /// 1-based rank by creation date among every subagent transcript of the session, announced or not.
    public var ordinal = 0
}

/// Finds the Claude Code transcripts (sessions and their subagents) that belong to a directory.
public enum SessionDiscovery {
    public static func projectsRoot(environment: [String: String] = ProcessInfo.processInfo.environment,
                                    home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let cfg = environment["CLAUDE_CONFIG_DIR"], !cfg.isEmpty {
            return URL(fileURLWithPath: cfg).appendingPathComponent("projects")
        }
        return home.appendingPathComponent(".claude/projects")
    }

    /// Every `*.jsonl` directly inside each project folder.
    public static func listTranscripts(projectsRoot: URL) -> [DiscoveredSession] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [DiscoveredSession] = []
        for project in projects {
            guard (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let files = try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                let values = try? f.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                out.append(DiscoveredSession(sessionId: f.deletingPathExtension().lastPathComponent,
                                             transcriptURL: f,
                                             modifiedAt: values?.contentModificationDate ?? .distantPast))
            }
        }
        return out.sorted { $0.transcriptURL.path < $1.transcriptURL.path }
    }

    /// Membership is decided by the first record carrying `cwd`, within the head cap.
    public static func isMember(transcriptURL: URL, folder: PathFolder) -> Bool {
        membership(transcriptURL: transcriptURL, folder: folder) == true
    }

    /// `nil` while undetermined: the head is short (file may still be growing) and no `cwd` record has appeared yet.
    public static func membership(transcriptURL: URL, folder: PathFolder) -> Bool? {
        guard let handle = try? FileHandle(forReadingFrom: transcriptURL) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: Constants.membershipHeadBytes), !head.isEmpty else { return nil }
        var remaining = head[...]
        while let nl = remaining.firstIndex(of: 0x0A) {
            let lineData = remaining[remaining.startIndex..<nl]
            remaining = remaining[remaining.index(after: nl)...]
            if let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
               let cwd = obj["cwd"] as? String {
                return folder.isMemberCwd(cwd)
            }
        }
        return head.count >= Constants.membershipHeadBytes ? false : nil
    }

    /// `<dir>/<uuid>/subagents/agent-*.jsonl` that also have `agent-*.meta.json`. Each one's `ordinal` ranks it among
    /// every `agent-*.jsonl` in the folder, whether or not its metadata has been written yet.
    public static func listSubagents(sessionTranscriptURL: URL) -> [DiscoveredSubagent] {
        let dir = sessionTranscriptURL.deletingPathExtension().appendingPathComponent("subagents")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]) else { return [] }
        var out: [(sub: DiscoveredSubagent?, id: String, born: Date)] = []
        for f in files where f.pathExtension == "jsonl" && f.lastPathComponent.hasPrefix("agent-") {
            let base = f.deletingPathExtension().lastPathComponent          // agent-<id>
            let metaURL = dir.appendingPathComponent(base + ".meta.json")
            let values = try? f.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let born = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            let agentId = String(base.dropFirst("agent-".count))
            let meta = (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(SubagentMeta.self, from: $0) }
            out.append((meta.map { DiscoveredSubagent(agentId: agentId, transcriptURL: f, meta: $0) }, agentId, born))
        }
        // Oldest first; the rank is the subagent's ordinal, so shading is stable across launches.
        let sorted = out.sorted { $0.born != $1.born ? $0.born < $1.born : $0.id < $1.id }
        return sorted.enumerated().compactMap { i, item in
            guard var sub = item.sub else { return nil }
            sub.ordinal = i + 1
            return sub
        }
    }
}
