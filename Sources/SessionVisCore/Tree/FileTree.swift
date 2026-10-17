import Foundation

/// The repository's directory tree with per-directory leaf counts.
public struct FileTree: Equatable, Sendable {
    public struct Node: Equatable, Sendable {
        public let path: RepoPath
        public let isDirectory: Bool
        public var children: [RepoPath]    // directories first, then by name
        public var leafCount: Int          // files in the subtree (0 for a file node itself)
        /// Where a file exists; empty for directories. A file with no `.main` is a ghost.
        public var origins: Set<Origin> = []
        /// A file that exists in no `.main` checkout. Directories are never ghosts.
        public var isGhost: Bool { !isDirectory && !origins.contains(.main) }
    }

    public private(set) var nodes: [RepoPath: Node]
    public var truncated: Bool
    public private(set) var fileCount = 0

    public init(files: [RepoPath], truncated: Bool = false) {
        nodes = [RepoPath([]): Node(path: RepoPath([]), isDirectory: true, children: [], leafCount: 0)]
        self.truncated = truncated
        for f in files { insert(file: f) }
    }

    public var root: Node { nodes[RepoPath([])]! }
    public func node(_ p: RepoPath) -> Node? { nodes[p] }
    public func files(in dir: RepoPath) -> [RepoPath] { (nodes[dir]?.children ?? []).filter { nodes[$0]?.isDirectory == false } }
    public func subdirectories(in dir: RepoPath) -> [RepoPath] { (nodes[dir]?.children ?? []).filter { nodes[$0]?.isDirectory == true } }

    /// Inserts a main-checkout file. Returns true when the file was new.
    @discardableResult
    public mutating func insert(file: RepoPath) -> Bool { insert(file: file, origin: .main) }

    /// Inserts `file` as existing in `origin`, or unions the origin onto an existing file. Returns true only when the node was created.
    /// A path that is a directory, or whose ancestor is a file, is left alone (returns false).
    @discardableResult
    public mutating func insert(file: RepoPath, origin: Origin) -> Bool {
        guard !file.isRoot else { return false }
        if let existing = nodes[file] {
            guard !existing.isDirectory else { return false }
            nodes[file]!.origins.insert(origin)
            return false
        }
        // Create missing directories along the way; stop at a file sitting on an ancestor.
        var dir = RepoPath([])
        for component in file.components.dropLast() {
            let next = dir.appending(component)
            if let n = nodes[next] {
                guard n.isDirectory else { return false }
            } else {
                nodes[next] = Node(path: next, isDirectory: true, children: [], leafCount: 0)
                addChild(next, to: dir)
            }
            dir = next
        }
        nodes[file] = Node(path: file, isDirectory: false, children: [], leafCount: 0, origins: [origin])
        addChild(file, to: dir)
        // Bump leaf counts up the chain.
        var p: RepoPath? = dir
        while let d = p { nodes[d]!.leafCount += 1; p = d.parent }
        fileCount += 1
        return true
    }

    /// True for a file that exists in no origin that is `.main`. Directories and unknown paths are never ghosts.
    public func isGhost(_ p: RepoPath) -> Bool {
        nodes[p]?.isGhost ?? false
    }

    public func files(in origin: Origin) -> Set<RepoPath> {
        Set(nodes.values.filter { !$0.isDirectory && $0.origins.contains(origin) }.map(\.path))
    }

    public var filesByOrigin: [Origin: Set<RepoPath>] {
        var out: [Origin: Set<RepoPath>] = [:]
        for n in nodes.values where !n.isDirectory {
            for o in n.origins { out[o, default: []].insert(n.path) }
        }
        return out
    }

    private mutating func addChild(_ child: RepoPath, to dir: RepoPath) {
        var children = nodes[dir]!.children
        let childIsDir = nodes[child]!.isDirectory
        let index = children.firstIndex { existing in
            let existingIsDir = nodes[existing]!.isDirectory
            if existingIsDir != childIsDir { return !existingIsDir }       // dirs before files
            return child.name < existing.name
        } ?? children.endIndex
        children.insert(child, at: index)
        nodes[dir]!.children = children
    }

    public var files: Set<RepoPath> { Set(nodes.values.filter { !$0.isDirectory }.map(\.path)) }

    /// Removes a file, fixes leaf counts, prunes directories left empty (never the root). Returns false for unknown paths or directories.
    @discardableResult
    public mutating func remove(file: RepoPath) -> Bool {
        guard let node = nodes[file], !node.isDirectory, let parent = file.parent else { return false }
        nodes.removeValue(forKey: file)
        nodes[parent]?.children.removeAll { $0 == file }
        fileCount -= 1
        var p: RepoPath? = parent
        while let d = p { nodes[d]?.leafCount -= 1; p = d.parent }
        var dir = parent
        while !dir.isRoot, let n = nodes[dir], n.children.isEmpty, let up = dir.parent {
            nodes.removeValue(forKey: dir)
            nodes[up]?.children.removeAll { $0 == dir }
            dir = up
        }
        return true
    }

    /// Removes `origin` from a file; deletes the node only when no origin is left. Returns whether the node was deleted.
    @discardableResult
    public mutating func remove(file: RepoPath, origin: Origin) -> Bool {
        guard let node = nodes[file], !node.isDirectory else { return false }
        var remaining = node.origins
        remaining.remove(origin)
        if remaining.isEmpty { return remove(file: file) }
        nodes[file]!.origins = remaining
        return false
    }
}
