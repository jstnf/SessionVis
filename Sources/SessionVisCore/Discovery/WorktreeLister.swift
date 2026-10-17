import Foundation

/// One linked checkout of the watched repository.
public struct Worktree: Hashable, Sendable {
    /// The label shown to the user and used as the origin tag; unique within one listing.
    public let name: String
    /// The checkout's absolute root, lexically normalised.
    public let path: String
    public init(name: String, path: String) { self.name = name; self.path = path }
}

/// Finds the repository's worktrees by asking git; the `.claude/worktrees` directories stand in when git cannot be asked.
public enum WorktreeLister {
    /// Every linked checkout other than `root` itself, sorted by path. nil when git could not be asked (missing, failed,
    /// timed out); the caller keeps the registry it had.
    public static func list(root: String, timeout: TimeInterval = Constants.gitTimeout) -> [Worktree]? {
        let root = PathFolder.normalize(root)
        guard let r = Subprocess.run(["git", "-C", root, "worktree", "list", "--porcelain"], timeout: timeout), r.status == 0 else { return nil }
        guard let top = Subprocess.run(["git", "-C", root, "rev-parse", "--show-toplevel", "--show-prefix"], timeout: timeout), top.status == 0 else { return nil }
        let topLines = String(decoding: top.output, as: UTF8.self).components(separatedBy: "\n")
        guard let toplevelLine = topLines.first, !toplevelLine.isEmpty else { return nil }
        let toplevel = PathFolder.normalize(toplevelLine)
        let prefix = topLines.count > 1 ? topLines[1] : ""
        let realRoot = PathFolder.realPath(root) ?? root
        return parse(porcelain: String(decoding: r.output, as: UTF8.self), root: root, realRoot: realRoot, toplevel: toplevel, prefix: prefix) { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// `root` is the directory as the app knows it and `realRoot` its symlink-free form, which is how git prints paths;
    /// a listed path under `realRoot` is mapped back under `root` so it matches the paths transcripts carry. `toplevel`
    /// is the real top of the checkout `root` lives in and `prefix` the path from there to `root` (empty, or ending in
    /// `/`). git lists every checkout of the repository, so the one containing `root` is dropped, and each other
    /// checkout is mapped to the same subdirectory inside it (`name` stays the checkout's basename). Also dropped:
    /// bare entries, prunable entries (a deleted directory git has not pruned yet) and mapped paths that are not
    /// directories now. Clashing names get `-2`, `-3`, … in path order so a name never depends on git's ordering.
    static func parse(porcelain: String, root: String, realRoot: String, toplevel: String, prefix: String, isDirectory: (String) -> Bool) -> [Worktree] {
        let sub = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        var entries: [(name: String, path: String)] = []
        for block in porcelain.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n").map(String.init)
            guard let entry = lines.first(where: { $0.hasPrefix("worktree ") }) else { continue }
            if lines.contains("bare") || lines.contains(where: { $0.hasPrefix("prunable") }) { continue }
            let listed = String(entry.dropFirst("worktree ".count))
            if listed.isEmpty { continue }
            var path = PathFolder.normalize(listed)
            if path == toplevel || path == realRoot || path == root { continue }
            if realRoot != root, path.hasPrefix(realRoot + "/") { path = root + path.dropFirst(realRoot.count) }
            let name = (path as NSString).lastPathComponent
            if !sub.isEmpty { path += "/" + sub }
            guard isDirectory(path) else { continue }
            entries.append((name, path))
        }
        var used: [String: Int] = [:]
        var out: [Worktree] = []
        for (base, path) in entries.sorted(by: { $0.path < $1.path }) {
            let n = (used[base] ?? 0) + 1
            used[base] = n
            out.append(Worktree(name: n == 1 ? base : "\(base)-\(n)", path: path))
        }
        return out
    }

    /// The directories directly under `<root>/.claude/worktrees`, by name.
    public static func conventionFallback(root: String) -> [Worktree] {
        let dir = PathFolder.normalize(root) + "/" + Origin.worktreesComponent
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return entries.filter { name in
            var isDirectory: ObjCBool = false
            return !name.hasPrefix(".") && FileManager.default.fileExists(atPath: dir + "/" + name, isDirectory: &isDirectory) && isDirectory.boolValue
        }.sorted().map { Worktree(name: $0, path: dir + "/" + $0) }
    }

    /// `<git common dir>/worktrees`, where git records linked checkouts; nil outside a git work tree. From the main
    /// checkout git answers `.git` (relative), from a linked one the main checkout's absolute `.git`.
    public static func registryDirectory(root: String, timeout: TimeInterval = Constants.gitTimeout) -> String? {
        let root = PathFolder.normalize(root)
        guard let r = Subprocess.run(["git", "-C", root, "rev-parse", "--git-common-dir"], timeout: timeout), r.status == 0 else { return nil }
        let common = String(decoding: r.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !common.isEmpty else { return nil }
        return PathFolder.normalize(common.hasPrefix("/") ? common : root + "/" + common) + "/worktrees"
    }
}
