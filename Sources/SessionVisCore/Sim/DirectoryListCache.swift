import Foundation

/// The non-root directories of a tree in path order, recomputed only when the tree version changes. One per scene:
/// tree versions are per-simulation counters, so a cache shared between scenes would hand one the other's list.
public final class DirectoryListCache {
    private var cached: (version: Int, paths: [RepoPath])?

    public init() {}

    public func reset() { cached = nil }

    public func sortedDirectories(of tree: FileTree, version: Int) -> [RepoPath] {
        if let c = cached, c.version == version { return c.paths }
        let paths = tree.nodes.values.filter { $0.isDirectory && !$0.path.isRoot }.map(\.path).sorted()
        cached = (version, paths)
        return paths
    }
}
