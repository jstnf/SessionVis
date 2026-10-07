import Foundation
import CoreGraphics

/// Deterministic radial tree layout. World units are points at zoom 1.
public struct RadialLayout: Equatable, Sendable {
    public private(set) var positions: [RepoPath: CGPoint] = [:]
    public private(set) var bounds: CGRect = .zero
    public private(set) var outerRadius: CGFloat = 0

    public func position(_ p: RepoPath) -> CGPoint? { positions[p] }

    public static func compute(_ tree: FileTree) -> RadialLayout {
        var layout = RadialLayout()
        layout.place(directory: RepoPath([]), center: .zero, depth: 0, sectorStart: 0, sectorEnd: 2 * .pi, tree: tree)
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

    private mutating func place(directory: RepoPath, center: CGPoint, depth: Int, sectorStart: CGFloat, sectorEnd: CGFloat, tree: FileTree) {
        positions[directory] = center
        let mid = (sectorStart + sectorEnd) / 2

        let files = tree.files(in: directory)
        if !files.isEmpty {
            let n = CGFloat(files.count)
            let r = max(Constants.fileRingMinRadius, n * Constants.fileSpacing / (2 * .pi))
            for (i, f) in files.enumerated() {
                let a = mid + .pi + 2 * .pi * CGFloat(i) / n
                positions[f] = CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
            }
        }

        let subdirs = tree.subdirectories(in: directory)
        guard !subdirs.isEmpty else { return }
        let weights = subdirs.map { CGFloat(max(1, tree.node($0)?.leafCount ?? 0)) }
        let total = weights.reduce(0, +)
        var start = sectorStart
        for (d, w) in zip(subdirs, weights) {
            let width = (sectorEnd - sectorStart) * w / total
            let childMid = start + width / 2
            let radius = CGFloat(depth + 1) * Constants.ringSpacing
            let childCenter = CGPoint(x: radius * cos(childMid), y: radius * sin(childMid))
            place(directory: d, center: childCenter, depth: depth + 1, sectorStart: start, sectorEnd: start + width, tree: tree)
            start += width
        }
    }
}
