import Foundation

/// The difference between two file sets: additions, removals, and moves paired by unique file name.
public struct TreeDelta: Equatable, Sendable {
    public struct Move: Equatable, Sendable {
        public let from: RepoPath
        public let to: RepoPath
        public init(from: RepoPath, to: RepoPath) { self.from = from; self.to = to }
    }
    public var added: [RepoPath]
    public var removed: [RepoPath]
    public var moved: [Move]
    /// The full file set the watcher saw (spec R34); the simulation uses it to reconcile touch-inserted phantoms.
    public var snapshot: Set<RepoPath>?

    public init(added: [RepoPath] = [], removed: [RepoPath] = [], moved: [Move] = [], snapshot: Set<RepoPath>? = nil) {
        self.added = added; self.removed = removed; self.moved = moved; self.snapshot = snapshot
    }

    /// For truncated scans: removals whose path still exists are not real. A move whose source still exists becomes a plain add.
    public func droppingPhantomRemovals(exists: (RepoPath) -> Bool) -> TreeDelta {
        var out = self
        out.removed = removed.filter { !exists($0) }
        out.moved = []
        for m in moved {
            if exists(m.from) { out.added.append(m.to) } else { out.moved.append(m) }
        }
        out.added.sort()
        return out
    }

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && moved.isEmpty }

    public static func compute(old: Set<RepoPath>, new: Set<RepoPath>) -> TreeDelta {
        var added = new.subtracting(old)
        var removed = old.subtracting(new)
        var moved: [Move] = []
        let addedByName = Dictionary(grouping: added, by: \.name)
        let removedByName = Dictionary(grouping: removed, by: \.name)
        for (name, rs) in removedByName {
            guard rs.count == 1, let adds = addedByName[name], adds.count == 1 else { continue }
            moved.append(Move(from: rs[0], to: adds[0]))
            removed.remove(rs[0])
            added.remove(adds[0])
        }
        return TreeDelta(added: added.sorted(), removed: removed.sorted(), moved: moved.sorted { $0.from < $1.from })
    }
}
