import Foundation

/// The files of the main checkout and of each `.claude/worktrees/<name>` checkout, plus the merged tree.
public struct ScanResult: Sendable {
    public var files: [Origin: Set<RepoPath>]
    public var truncated: Bool
    public var tree: FileTree
}

/// Seeds the tree from the repository: git-tracked files when available, otherwise a directory walk, capped at `maxTreeFiles`.
public enum FileTreeScanner {
    static let skippedDirectoryNames: Set<String> = [".git", ".build", ".swiftpm", "node_modules", "DerivedData", "Pods", "dist"]
    static let worktreesPrefix = Origin.worktreesComponent

    public static func scan(directory: String) -> FileTree { scanOrigins(directory: directory).tree }

    /// Lists main first, then each worktree by name; `limit` caps the distinct paths across all of them. A path an
    /// earlier checkout already listed costs nothing, so a worktree's copies of main's files are always kept; once the
    /// cap is reached a worktree keeps only those and loses its other paths. Every path not listed earlier counts,
    /// including one that collides with a main file or directory: such paths are dropped later, when the tree is merged.
    public static func scanOrigins(directory: String, limit: Int = Constants.maxTreeFiles) -> ScanResult {
        var files: [Origin: Set<RepoPath>] = [:]
        var truncated = false
        var seen = Set<RepoPath>()
        var origins: [Origin] = [.main]
        origins += worktreeNames(directory: directory).map(Origin.worktree)
        for origin in origins {
            let (list, cut) = listFiles(directory: origin.rootPath(under: directory), limit: limit)
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

    /// Directory names directly under `<directory>/.claude/worktrees`, sorted.
    public static func worktreeNames(directory: String) -> [String] {
        let dir = Origin.worktreesDirectory(under: directory)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return entries.filter { name in
            var isDir: ObjCBool = false
            return !name.hasPrefix(".") && FileManager.default.fileExists(atPath: dir + "/" + name, isDirectory: &isDir) && isDir.boolValue
        }.sorted()
    }

    /// Git listing when the directory is a work tree, else a walk; at most `limit` entries, with a flag when cut.
    static func listFiles(directory: String, limit: Int) -> (files: [String], truncated: Bool) {
        if let files = gitFiles(directory: directory) {
            return (Array(files.prefix(limit)), files.count > limit)
        }
        return walkFiles(directory: directory, limit: limit)
    }

    /// Tracked + untracked-not-ignored paths relative to `directory`, or nil when not a git work tree.
    static func gitFiles(directory: String) -> [String]? {
        guard let probe = run(["git", "-C", directory, "rev-parse", "--is-inside-work-tree"]), probe.status == 0,
              String(decoding: probe.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return nil }
        guard let list = run(["git", "-C", directory, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]), list.status == 0 else { return nil }
        var seen = Set<String>()
        var out: [String] = []
        for part in list.output.split(separator: 0, omittingEmptySubsequences: true) {
            let path = String(decoding: part, as: UTF8.self)
            guard !path.isEmpty, !path.hasPrefix(worktreesPrefix), seen.insert(path).inserted else { continue }
            out.append(path)
        }
        return out
    }

    static func walkFiles(directory: String, limit: Int) -> (files: [String], truncated: Bool) {
        let base = URL(fileURLWithPath: directory)
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: []) else { return ([], false) }
        var files: [String] = []
        let basePath = base.standardizedFileURL.path
        while let url = enumerator.nextObject() as? URL {
            let rel = String(url.standardizedFileURL.path.dropFirst(basePath.count + 1))
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if skippedDirectoryNames.contains(url.lastPathComponent) || rel == worktreesPrefix { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if files.count >= limit { return (files, true) }
            files.append(rel)
        }
        return (files.sorted(), false)
    }

    private static func run(_ args: [String]) -> (status: Int32, output: Data)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }
}
