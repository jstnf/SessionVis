import Foundation

/// The repository's directory tree with per-directory leaf counts.
public struct FileTree: Equatable, Sendable {
    public struct Node: Equatable, Sendable {
        public let path: RepoPath
        public let isDirectory: Bool
        public var children: [RepoPath]    // directories first, then by name
        public var leafCount: Int          // files in the subtree (0 for a file node itself)
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

    /// Returns true when the file was new.
    @discardableResult
    public mutating func insert(file: RepoPath) -> Bool {
        guard !file.isRoot, nodes[file] == nil else { return false }
        // Create missing directories along the way.
        var dir = RepoPath([])
        for component in file.components.dropLast() {
            let next = dir.appending(component)
            if nodes[next] == nil {
                nodes[next] = Node(path: next, isDirectory: true, children: [], leafCount: 0)
                addChild(next, to: dir)
            }
            dir = next
        }
        nodes[file] = Node(path: file, isDirectory: false, children: [], leafCount: 0)
        addChild(file, to: dir)
        // Bump leaf counts up the chain.
        var p: RepoPath? = dir
        while let d = p { nodes[d]!.leafCount += 1; p = d.parent }
        fileCount += 1
        return true
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
}
