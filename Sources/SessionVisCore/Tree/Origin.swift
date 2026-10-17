import Foundation

/// Where a file exists: the main checkout, or a registered worktree checkout folded onto the same tree.
public enum Origin: Hashable, Sendable, Comparable {
    case main
    case worktree(String)

    /// Claude Code's own worktree directory inside the root; its entries stand in for the registry when git cannot be asked.
    public static let worktreesComponent = ".claude/worktrees"

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
