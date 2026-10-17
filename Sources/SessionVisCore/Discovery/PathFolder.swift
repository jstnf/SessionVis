import Foundation

public struct FoldedPath: Equatable, Sendable {
    public let path: RepoPath
    public let worktree: String?
    public init(path: RepoPath, worktree: String?) { self.path = path; self.worktree = worktree }
}

/// Maps absolute paths onto the watched directory: the root checkout plus every registered worktree, wherever it is.
public struct PathFolder: Sendable, Equatable {
    public let root: String            // normalised, no trailing slash
    /// Registered checkouts in registry order, paths normalised.
    public let worktrees: [Worktree]
    /// Longest path first, so a worktree nested inside another matches before its container.
    private let byLength: [Worktree]
    private let worktreesDir: String

    public init(root: String, worktrees: [Worktree] = []) {
        let r = PathFolder.normalize(root)
        self.root = r
        self.worktrees = worktrees.map { Worktree(name: $0.name, path: PathFolder.normalize($0.path)) }
        self.byLength = self.worktrees.sorted { $0.path.count > $1.path.count }
        self.worktreesDir = r + "/" + Origin.worktreesComponent
    }

    /// The root itself folds to the root path; a path inside a registered worktree folds relative to that worktree and
    /// carries its name; anything else under the root folds relative to the root. A checkout's own directory, the
    /// `.claude/worktrees` folder and any unregistered directory under it fold to nil.
    public func fold(_ absolute: String) -> FoldedPath? {
        let p = PathFolder.normalize(absolute)
        if p == root { return FoldedPath(path: RepoPath([]), worktree: nil) }
        if let wt = containing(p) {
            guard p != wt.path else { return nil }
            return FoldedPath(path: RepoPath(string: String(p.dropFirst(wt.path.count + 1))), worktree: wt.name)
        }
        if p == worktreesDir || p.hasPrefix(worktreesDir + "/") { return nil }
        if p.hasPrefix(root + "/") {
            return FoldedPath(path: RepoPath(string: String(p.dropFirst(root.count + 1))), worktree: nil)
        }
        return nil
    }

    /// A session belongs to the directory when its cwd is the root or is inside any registered checkout.
    public func isMemberCwd(_ cwd: String) -> Bool {
        let p = PathFolder.normalize(cwd)
        return p == root || containing(p) != nil
    }

    public func worktreeName(ofCwd cwd: String) -> String? { containing(PathFolder.normalize(cwd))?.name }

    /// The absolute directory an origin's files are relative to. A name that is not registered (a touch recorded just
    /// before the registry caught up) resolves by the `.claude/worktrees` convention.
    public func rootPath(of origin: Origin) -> String {
        switch origin {
        case .main: return root
        case .worktree(let name): return worktrees.first { $0.name == name }?.path ?? worktreesDir + "/" + name
        }
    }

    /// Worktree roots that sit inside `root`, relative to it; the main listing skips them.
    public var nestedWorktreePaths: [RepoPath] {
        worktrees.filter { $0.path.hasPrefix(root + "/") }.map { RepoPath(string: String($0.path.dropFirst(root.count + 1))) }.sorted()
    }

    /// The registered worktree whose root is `p` or contains it; the deepest one when they nest.
    private func containing(_ p: String) -> Worktree? {
        byLength.first { p == $0.path || p.hasPrefix($0.path + "/") }
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

    /// The path with every symlink resolved, which is how git and FSEvents report paths; nil when it does not exist.
    public static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
