import Foundation

/// Where a file exists: the main checkout, or a `.claude/worktrees/<name>` checkout folded onto the same tree.
public enum Origin: Hashable, Sendable, Comparable {
    case main
    case worktree(String)

    public static let worktreesComponent = ".claude/worktrees"

    public static func worktreesDirectory(under root: String) -> String { root + "/" + worktreesComponent }

    /// The absolute directory this origin's files are relative to.
    public func rootPath(under root: String) -> String {
        switch self {
        case .main: root
        case .worktree(let name): Self.worktreesDirectory(under: root) + "/" + name
        }
    }

    /// Main first, then worktrees by name.
    public static func < (lhs: Origin, rhs: Origin) -> Bool {
        switch (lhs, rhs) {
        case (.main, .main): false
        case (.main, .worktree): true
        case (.worktree, .main): false
        case (.worktree(let a), .worktree(let b)): a < b
        }
    }
}
