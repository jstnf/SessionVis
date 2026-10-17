import Foundation

/// Hidden files stay out of the tree (so out of layout, hit testing and drawing) but keep their origins, so a rule
/// change moves them in and out without a rescan and the watcher's later deltas still find them.
extension Simulation {
    public var hiddenFileCount: Int { hidden.count }

    /// Splits a freshly built tree into the files the filter shows and the ones it hides.
    static func partition(_ tree: FileTree, by filter: FileFilter) -> (visible: FileTree, hidden: [RepoPath: Set<Origin>]) {
        guard !filter.isEmpty else { return (tree, [:]) }
        var visible = tree
        var hidden: [RepoPath: Set<Origin>] = [:]
        for node in tree.nodes.values where !node.isDirectory && filter.hides(node.path) {
            hidden[node.path] = node.origins
            visible.remove(file: node.path)
        }
        return (visible, hidden)
    }

    /// Files the new rules hide leave at once with their effects cleared (a rule change is not a repo event, so no
    /// fade); files they no longer hide come back with their origins and scale in. One relayout when anything moved.
    public mutating func setFilter(_ newFilter: FileFilter) {
        guard newFilter != filter else { return }
        filter = newFilter
        let toHide = tree.nodes.values.filter { !$0.isDirectory && newFilter.hides($0.path) }
        for node in toHide {
            let deleted = dying[node.path] != nil   // a file already deleted from disk is not worth remembering
            if !deleted { hidden[node.path] = node.origins }
            let touched = lastTouchAt[node.path]
            finishDeath(node.path)
            if !deleted, let touched { lastTouchAt[node.path] = touched }   // activity outlives hiding
        }
        relightEdges(above: toHide.map(\.path))
        let toShow = hidden.filter { !newFilter.hides($0.key) }
        for (path, origins) in toShow {
            hidden.removeValue(forKey: path)
            for origin in origins.sorted() { add(path, origin: origin) }   // main first, so a ghost stays a ghost and nothing lands
        }
        if !toHide.isEmpty || !toShow.isEmpty { relayout() }
    }

    /// Edges above removed files keep only the light of the file tints that survive beneath them, in the newest toucher's hue.
    private mutating func relightEdges(above removed: [RepoPath]) {
        var affected: Set<RepoPath> = []
        for path in removed {
            var node = path.parent
            while let n = node, !n.isRoot { affected.insert(n); node = n.parent }
        }
        guard !affected.isEmpty else { return }
        for n in affected { edgeTints.removeValue(forKey: n) }
        for (path, tint) in tints where tree.node(path) != nil {
            var node = path.parent
            while let n = node, !n.isRoot {
                if affected.contains(n) { Self.merge(tint, into: &edgeTints, at: n, now: clock) }
                node = n.parent
            }
        }
    }

    /// Takes `origin` off a hidden entry and forgets the entry when none is left.
    mutating func forgetHidden(_ path: RepoPath, origin: Origin) {
        guard var origins = hidden[path] else { return }
        origins.remove(origin)
        if origins.isEmpty { hidden.removeValue(forKey: path) } else { hidden[path] = origins }
    }

    /// Records the hidden side of a watcher delta and returns the remainder for the visible tree: a hidden addition is
    /// remembered, a hidden removal forgotten, and a move becomes a removal, an addition or a record move depending on
    /// which side of the filter each end falls.
    mutating func visibleRemainder(of delta: TreeDelta) -> TreeDelta {
        guard !filter.isEmpty || !hidden.isEmpty else { return delta }
        let o = delta.origin
        var out = delta
        out.added = []; out.removed = []; out.moved = []
        for p in delta.added {
            if filter.hides(p) { hidden[p, default: []].insert(o) } else { out.added.append(p) }
        }
        for p in delta.removed {
            if hidden[p] != nil { forgetHidden(p, origin: o) } else { out.removed.append(p) }
        }
        for m in delta.moved {
            let fromHidden = hidden[m.from] != nil, toHidden = filter.hides(m.to)
            switch (fromHidden, toHidden) {
            case (false, false):
                out.moved.append(m)
            case (false, true):
                out.removed.append(m.from)
                hidden[m.to, default: []].insert(o)
            case (true, false):
                forgetHidden(m.from, origin: o)
                out.added.append(m.to)
            case (true, true):
                forgetHidden(m.from, origin: o)
                hidden[m.to, default: []].insert(o)
            }
        }
        return out
    }

    /// Hidden entries that `origin`'s snapshot no longer lists lose that origin, unless the file really exists under the
    /// origin's root (a gitignored file an agent wrote), mirroring the check the visible tree gets.
    mutating func reconcileHidden(origin o: Origin, snapshot: Set<RepoPath>?) {
        guard let snap = snapshot, let folder else { return }
        let originRoot = folder.rootPath(of: o)
        for (path, origins) in hidden where origins.contains(o) && !snap.contains(path) {
            if FileManager.default.fileExists(atPath: originRoot + "/" + path.string) { continue }
            forgetHidden(path, origin: o)
        }
    }
}
