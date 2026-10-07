import CoreGraphics
import Testing
@testable import SessionVisCore

@Suite struct GeometryTests {
    @Test func hullOfSquareWithInteriorPoint() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10), CGPoint(x: 5, y: 5)]
        let hull = Geometry.convexHull(pts)
        #expect(hull.count == 4)
        #expect(!hull.contains(CGPoint(x: 5, y: 5)))
    }

    @Test func hullSmallCases() {
        #expect(Geometry.convexHull([]).isEmpty)
        #expect(Geometry.convexHull([CGPoint(x: 1, y: 1)]) == [CGPoint(x: 1, y: 1)])
        #expect(Geometry.convexHull([CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)]).count == 2)
        let collinear = Geometry.convexHull([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)])
        #expect(Set(collinear.map { "\($0.x),\($0.y)" }) == ["0.0,0.0", "2.0,2.0"])
    }

    @Test func hashIsStableFNV1a() {
        #expect(Geometry.stableHash("") == 0xcbf29ce484222325)
        #expect(Geometry.stableHash("a") == 0xaf63dc4c8601ec8c)
        #expect(Geometry.stableHash("agent-1") == Geometry.stableHash("agent-1"))
        #expect(Geometry.stableHash("agent-1") != Geometry.stableHash("agent-2"))
    }

    @Test func anglesAndFractionsInRange() {
        for s in ["a", "b", "c", "session-uuid"] {
            let a = Geometry.unitAngle(fromHash: Geometry.stableHash(s))
            #expect(a >= 0 && a < 2 * .pi)
            let f = Geometry.unitFraction(fromHash: Geometry.stableHash(s), salt: 3)
            #expect(f >= 0 && f < 1)
        }
    }

    @Test func vectorHelpers() {
        #expect(Geometry.centroid([CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 4)]) == CGPoint(x: 1, y: 2))
        #expect(Geometry.centroid([]) == .zero)
        #expect(Geometry.distance(.zero, CGPoint(x: 3, y: 4)) == 5)
        #expect(Geometry.lerp(.zero, CGPoint(x: 10, y: 0), 0.25) == CGPoint(x: 2.5, y: 0))
        let t = Geometry.towards(.zero, CGPoint(x: 10, y: 0), by: 4)
        #expect(abs(t.x - 4) < 0.0001 && t.y == 0)
        #expect(Geometry.towards(.zero, .zero, by: 4) == .zero)
        let c = Geometry.pointOnCircle(center: CGPoint(x: 1, y: 1), radius: 2, angle: 0)
        #expect(abs(c.x - 3) < 0.0001 && abs(c.y - 1) < 0.0001)
    }
}
