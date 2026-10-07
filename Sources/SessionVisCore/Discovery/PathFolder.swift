import Foundation

public struct FoldedPath: Equatable, Sendable {
    public let path: RepoPath
    public let worktree: String?
    public init(path: RepoPath, worktree: String?) { self.path = path; self.worktree = worktree }
}

/// Maps absolute paths onto the watched directory.
public struct PathFolder: Sendable {
    public let root: String            // normalised, no trailing slash
    private let worktreesPrefix: String

    public init(root: String) {
        let r = PathFolder.normalize(root)
        self.root = r
        self.worktreesPrefix = r + "/.claude/worktrees/"
    }

    public func fold(_ absolute: String) -> FoldedPath? {
        let p = PathFolder.normalize(absolute)
        if p == root { return FoldedPath(path: RepoPath([]), worktree: nil) }
        if p.hasPrefix(worktreesPrefix) {
            let rest = p.dropFirst(worktreesPrefix.count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }   // the worktree dir itself
            let name = String(rest[rest.startIndex..<slash])
            let inner = String(rest[rest.index(after: slash)...])
            guard !name.isEmpty, !inner.isEmpty else { return nil }
            return FoldedPath(path: RepoPath(string: inner), worktree: name)
        }
        if p == root + "/.claude/worktrees" { return nil }
        if p.hasPrefix(root + "/") {
            return FoldedPath(path: RepoPath(string: String(p.dropFirst(root.count + 1))), worktree: nil)
        }
        return nil
    }

    /// A session belongs to the directory when its cwd is the directory or inside a worktree checkout.
    public func isMemberCwd(_ cwd: String) -> Bool {
        let p = PathFolder.normalize(cwd)
        return p == root || (p.hasPrefix(worktreesPrefix) && p.count > worktreesPrefix.count)
    }

    public func worktreeName(ofCwd cwd: String) -> String? {
        let p = PathFolder.normalize(cwd)
        guard p.hasPrefix(worktreesPrefix) else { return nil }
        let name = p.dropFirst(worktreesPrefix.count).split(separator: "/", maxSplits: 1).first
        return name.map(String.init)
    }

    /// Lexical normalisation: collapses `//`, `.`, `..`; strips a trailing slash. No file-system access.
    public static func normalize(_ path: String) -> String {
        var out: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": _ = out.popLast()
            default: out.append(part)
            }
        }
        return "/" + out.joined(separator: "/")
    }
}
