import Foundation

/// A path relative to the watched directory. `[]` is the root.
public struct RepoPath: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let components: [String]

    public init(_ components: [String]) { self.components = components }

    public init(string: String) {
        self.components = string.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    public var isRoot: Bool { components.isEmpty }
    public var depth: Int { components.count }
    public var name: String { components.last ?? "" }
    public var string: String { components.joined(separator: "/") }
    public var description: String { isRoot ? "/" : string }

    public var parent: RepoPath? {
        guard !isRoot else { return nil }
        return RepoPath(Array(components.dropLast()))
    }

    public func appending(_ component: String) -> RepoPath { RepoPath(components + [component]) }

    public static func < (lhs: RepoPath, rhs: RepoPath) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}
