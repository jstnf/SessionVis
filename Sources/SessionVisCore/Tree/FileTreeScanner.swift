import Foundation

/// The files of the main checkout and of each registered worktree, plus the merged tree.
public struct ScanResult: Sendable {
    public var files: [Origin: Set<RepoPath>]
    public var truncated: Bool
    public var tree: FileTree
}

/// Seeds the tree from the repository: git-tracked files when available, otherwise a directory walk, capped at `maxTreeFiles`.
public enum FileTreeScanner {
    static let skippedDirectoryNames: Set<String> = [".git", ".build", ".swiftpm", "node_modules", "DerivedData", "Pods", "dist"]
    static let worktreesPrefix = Origin.worktreesComponent

    public static func scan(folder: PathFolder) -> FileTree { scanOrigins(folder: folder).tree }

    /// Lists main first, then each registered worktree in registry order; `limit` caps the distinct paths across all of
    /// them. A path an earlier checkout already listed costs nothing, so a worktree's copies of main's files are always
    /// kept; once the cap is reached a worktree keeps only those and loses its other paths. Every path not listed earlier
    /// counts, including one that collides with a main file or directory: such paths are dropped later, when the tree is
    /// merged. Main's listing skips `.claude/worktrees` and every checkout nested inside the root.
    public static func scanOrigins(folder: PathFolder, limit: Int = Constants.maxTreeFiles) -> ScanResult {
        var files: [Origin: Set<RepoPath>] = [:]
        var truncated = false
        var seen = Set<RepoPath>()
        var origins: [Origin] = [.main]
        origins += folder.worktrees.map { Origin.worktree($0.name) }
        for origin in origins {
            let skipped = origin == .main ? [worktreesPrefix] + folder.nestedWorktreePaths.map(\.string) : [worktreesPrefix]
            let (list, cut) = listFiles(directory: folder.rootPath(of: origin), skipping: skipped, limit: limit)
            if cut { truncated = true }
            var kept = Set<RepoPath>()
            for path in list.map(RepoPath.init(string:)) {
                if !seen.contains(path) {
                    guard seen.count < limit else { truncated = true; continue }
                    seen.insert(path)
                }
                kept.insert(path)
            }
            files[origin] = kept
        }
        var tree = FileTree(files: Array(files[.main] ?? []), truncated: truncated)
        for origin in origins.dropFirst() {
            for f in (files[origin] ?? []).sorted() { tree.insert(file: f, origin: origin) }
        }
        return ScanResult(files: files, truncated: truncated, tree: tree)
    }

    /// Git listing when the directory is a work tree, else a walk; at most `limit` entries, with a flag when cut.
    static func listFiles(directory: String, skipping: [String], limit: Int) -> (files: [String], truncated: Bool) {
        if let files = gitFiles(directory: directory, skipping: skipping) {
            return (Array(files.prefix(limit)), files.count > limit)
        }
        return walkFiles(directory: directory, skipping: skipping, limit: limit)
    }

    /// Tracked + untracked-not-ignored paths relative to `directory`, or nil when not a git work tree. A nested checkout
    /// shows up as one untracked `dir/` entry (git emits trailing-slash entries only for embedded repositories), so those entries are dropped, and the skip list removes registered checkouts.
    static func gitFiles(directory: String, skipping: [String]) -> [String]? {
        guard let probe = Subprocess.run(["git", "-C", directory, "rev-parse", "--is-inside-work-tree"], timeout: Constants.gitTimeout), probe.status == 0,
              String(decoding: probe.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return nil }
        guard let list = Subprocess.run(["git", "-C", directory, "ls-files", "-z", "--cached", "--others", "--exclude-standard"], timeout: Constants.gitTimeout), list.status == 0 else { return nil }
        var seen = Set<String>()
        var out: [String] = []
        for part in list.output.split(separator: 0, omittingEmptySubsequences: true) {
            let path = String(decoding: part, as: UTF8.self)
            guard !path.isEmpty, !path.hasSuffix("/"), !isSkipped(path, skipping), seen.insert(path).inserted else { continue }
            out.append(path)
        }
        return out
    }

    static func walkFiles(directory: String, skipping: [String], limit: Int) -> (files: [String], truncated: Bool) {
        let base = URL(fileURLWithPath: directory)
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: []) else { return ([], false) }
        var files: [String] = []
        let basePath = base.standardizedFileURL.path
        while let url = enumerator.nextObject() as? URL {
            let rel = String(url.standardizedFileURL.path.dropFirst(basePath.count + 1))
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if skippedDirectoryNames.contains(url.lastPathComponent) || skipping.contains(rel) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if files.count >= limit { return (files, true) }
            files.append(rel)
        }
        return (files.sorted(), false)
    }

    private static func isSkipped(_ path: String, _ skipping: [String]) -> Bool {
        skipping.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
