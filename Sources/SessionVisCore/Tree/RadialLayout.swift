import Foundation
import CoreGraphics

/// How much room each part of the tree gets when the layout favours activity: an active file keeps its full
/// spacing on its ring, an inactive one is packed tightly, and a directory's sector grows with the active files
/// beneath it rather than with its size alone. Paths that are not files of the tree are ignored.
public struct LayoutWeights: Equatable, Sendable {
    public let active: Set<RepoPath>
    /// Active files in each directory's subtree; a file counts for every ancestor up to the root.
    public private(set) var activeCount: [RepoPath: Int] = [:]

    public init(tree: FileTree, active: Set<RepoPath>) {
        self.active = active
        for path in active where tree.node(path)?.isDirectory == false {
            var dir = path.parent
            while let d = dir { activeCount[d, default: 0] += 1; dir = d.parent }
        }
    }

    public func spacing(for file: RepoPath) -> CGFloat {
        active.contains(file) ? Constants.fileSpacing : Constants.focusInactiveSpacing
    }

    /// Active files plus a sliver per file held, so an idle directory keeps room in proportion to its size.
    public func sectorWeight(of directory: RepoPath, in tree: FileTree) -> CGFloat {
        let leaves = CGFloat(max(1, tree.node(directory)?.leafCount ?? 0))
        return CGFloat(activeCount[directory] ?? 0) + Constants.focusInactiveWeight * leaves
    }
}

/// Deterministic radial tree layout. World units are points at zoom 1.
public struct RadialLayout: Equatable, Sendable {
    public private(set) var positions: [RepoPath: CGPoint] = [:]
    public private(set) var bounds: CGRect = .zero
    public private(set) var outerRadius: CGFloat = 0

    public func position(_ p: RepoPath) -> CGPoint? { positions[p] }

    /// With `active` nil every file gets `fileSpacing` and every directory a sector proportional to its leaf count;
    /// with a set, `LayoutWeights` decides both.
    public static func compute(_ tree: FileTree, active: Set<RepoPath>? = nil) -> RadialLayout {
        var layout = RadialLayout()
        let weights = active.map { LayoutWeights(tree: tree, active: $0) }
        layout.place(directory: RepoPath([]), center: .zero, depth: 0, sectorStart: 0, sectorEnd: 2 * .pi, tree: tree, weights: weights)
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        var outer: CGFloat = 0
        for p in layout.positions.values {
            minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            outer = max(outer, hypot(p.x, p.y))
        }
        let pad = Constants.fileRingMinRadius
        layout.bounds = CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + 2 * pad, height: maxY - minY + 2 * pad)
        layout.outerRadius = outer
        return layout
    }

    private mutating func place(directory: RepoPath, center: CGPoint, depth: Int, sectorStart: CGFloat, sectorEnd: CGFloat, tree: FileTree, weights: LayoutWeights?) {
        positions[directory] = center
        let mid = (sectorStart + sectorEnd) / 2

        let files = tree.files(in: directory)
        if !files.isEmpty {
            if let weights {
                // Each file takes its own share of the circumference.
                let spacing = files.map { weights.spacing(for: $0) }
                let total = spacing.reduce(0, +)
                let r = max(Constants.fileRingMinRadius, total / (2 * .pi))
                var along: CGFloat = 0
                for (f, s) in zip(files, spacing) {
                    let a = mid + .pi + 2 * .pi * along / total
                    positions[f] = CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
                    along += s
                }
            } else {
                let n = CGFloat(files.count)
                let r = max(Constants.fileRingMinRadius, n * Constants.fileSpacing / (2 * .pi))
                for (i, f) in files.enumerated() {
                    let a = mid + .pi + 2 * .pi * CGFloat(i) / n
                    positions[f] = CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
                }
            }
        }

        let subdirs = tree.subdirectories(in: directory)
        guard !subdirs.isEmpty else { return }
        let span = sectorEnd - sectorStart
        let radius = CGFloat(depth + 1) * Constants.ringSpacing
        let sectorWeights = subdirs.map { d in weights?.sectorWeight(of: d, in: tree) ?? CGFloat(max(1, tree.node(d)?.leafCount ?? 0)) }
        let total = sectorWeights.reduce(0, +)
        // With weights, every sibling first takes the angle that keeps neighbouring centres a minimum apart on their ring;
        // the rest of the sector is shared by weight. If the floors alone fill the sector they are scaled down evenly.
        let floor: CGFloat = weights == nil ? 0 : 2 * asin(min(1, Constants.focusMinSiblingSpacing / (2 * radius)))
        let floorTotal = floor * CGFloat(subdirs.count)
        let floorScale = floorTotal > span ? span / floorTotal : 1
        let remaining = max(0, span - floorTotal)
        var start = sectorStart
        for (d, w) in zip(subdirs, sectorWeights) {
            let width = weights == nil ? span * w / total : floor * floorScale + remaining * w / total
            let childMid = start + width / 2
            let childCenter = CGPoint(x: radius * cos(childMid), y: radius * sin(childMid))
            place(directory: d, center: childCenter, depth: depth + 1, sectorStart: start, sectorEnd: start + width, tree: tree, weights: weights)
            start += width
        }
    }
}
