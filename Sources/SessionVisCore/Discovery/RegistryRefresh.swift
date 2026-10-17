import Foundation

/// How the app turns a worktree listing into the folder everything folds through.
public enum RegistryRefresh {
    /// The folder for `root` from git's listing, or from the `.claude/worktrees` directories when git cannot be asked.
    public static func folder(root: String) -> PathFolder {
        PathFolder(root: root, worktrees: WorktreeLister.list(root: root) ?? WorktreeLister.conventionFallback(root: root))
    }

    /// The folder to switch to after a fresh listing, or nil when nothing should change: the listing failed (keep the
    /// registry rather than kill every worktree's files on a transient error) or it matches the current one.
    public static func next(current: PathFolder, listed: [Worktree]?) -> PathFolder? {
        guard let listed else { return nil }
        let candidate = PathFolder(root: current.root, worktrees: listed)
        return candidate == current ? nil : candidate
    }
}
