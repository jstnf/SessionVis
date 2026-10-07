import Foundation

/// Seeds the tree from the repository: git-tracked files when available, otherwise a directory walk, capped at `maxTreeFiles`.
public enum FileTreeScanner {
    static let skippedDirectoryNames: Set<String> = [".git", ".build", ".swiftpm", "node_modules", "DerivedData", "Pods", "dist"]
    static let worktreesPrefix = ".claude/worktrees"

    public static func scan(directory: String) -> FileTree {
        if let files = gitFiles(directory: directory) {
            let truncated = files.count > Constants.maxTreeFiles
            return FileTree(files: files.prefix(Constants.maxTreeFiles).map(RepoPath.init(string:)), truncated: truncated)
        }
        let (files, truncated) = walkFiles(directory: directory, limit: Constants.maxTreeFiles)
        return FileTree(files: files.map(RepoPath.init(string:)), truncated: truncated)
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
