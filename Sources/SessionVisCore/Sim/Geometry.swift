import Foundation
import CoreGraphics

public enum Geometry {
    /// Andrew's monotone chain. Returns points in counter-clockwise order.
    public static func convexHull(_ pts: [CGPoint]) -> [CGPoint] {
        if pts.count < 3 { return pts }
        let sorted = pts.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        lower.removeLast(); upper.removeLast()
        let hull = lower + upper
        return hull.isEmpty ? [sorted.first!] : hull
    }

    /// FNV-1a 64-bit.
    public static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    public static func unitAngle(fromHash h: UInt64) -> CGFloat {
        CGFloat(Double(h % 360_000) / 360_000.0) * 2 * .pi
    }

    /// A different pseudo-random fraction per salt, from one hash.
    public static func unitFraction(fromHash h: UInt64, salt: UInt64) -> CGFloat {
        var x = h ^ (salt &* 0x9E3779B97F4A7C15)
        x ^= x >> 33; x = x &* 0xff51afd7ed558ccd; x ^= x >> 33
        return CGFloat(Double(x % 1_000_000) / 1_000_000.0)
    }

    public static func centroid(_ pts: [CGPoint]) -> CGPoint {
        guard !pts.isEmpty else { return .zero }
        let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(pts.count), y: sum.y / CGFloat(pts.count))
    }

    public static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }

    public static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    public static func pointOnCircle(center: CGPoint, radius: CGFloat, angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    public static func towards(_ from: CGPoint, _ to: CGPoint, by d: CGFloat) -> CGPoint {
        let len = distance(from, to)
        guard len > 0.0001 else { return from }
        return CGPoint(x: from.x + (to.x - from.x) / len * d, y: from.y + (to.y - from.y) / len * d)
    }
}
