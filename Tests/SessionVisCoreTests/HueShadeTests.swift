import Foundation
import Testing
@testable import SessionVisCore

@Suite struct HueShadeTests {
    let shades = 1...Constants.subagentShadeCount
    let families = 0..<HuePalette.count

    /// Red-mean weighted RGB distance on the 0…255 scale.
    func distance(_ a: HuePalette.RGB, _ b: HuePalette.RGB) -> Double {
        let r1 = a.r * 255, g1 = a.g * 255, b1 = a.b * 255, r2 = b.r * 255, g2 = b.g * 255, b2 = b.b * 255
        let rm = (r1 + r2) / 2, dr = r1 - r2, dg = g1 - g2, db = b1 - b2
        return ((2 + rm / 256) * dr * dr + 4 * dg * dg + (2 + (255 - rm) / 256) * db * db).squareRoot()
    }
    func angle(_ c: HuePalette.RGB) -> Double { HueShade.hsb(of: c).h }
    func angleDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
    func close(_ a: HuePalette.RGB, _ b: HuePalette.RGB, _ tolerance: Double = 0.001) -> Bool {
        abs(a.r - b.r) < tolerance && abs(a.g - b.g) < tolerance && abs(a.b - b.b) < tolerance
    }

    @Test func shadeZeroAndUnknownShadesAreTheFamilyColour() {
        for i in families {
            #expect(HuePalette.hue(i, shade: 0) == HuePalette.hue(i) && HuePalette.tint(i, shade: 0) == HuePalette.tint(i))
            #expect(HuePalette.hue(i, shade: Constants.subagentShadeCount + 1) == HuePalette.hue(i))
            #expect(HuePalette.tint(i, shade: -1) == HuePalette.tint(i))
        }
        #expect(Constants.subagentShadeCount == 4)
    }

    @Test func hsbRoundTripsTheFamilyColours() {
        for i in families {
            for base in [HuePalette.hue(i), HuePalette.tint(i)] {
                let (h, s, b) = HueShade.hsb(of: base)
                #expect(close(HueShade.rgb(h: h, s: s, b: b), base))
            }
        }
        let black = HueShade.hsb(of: (0, 0, 0))
        #expect(black.h == 0 && black.s == 0 && black.b == 0)
        #expect(close(HueShade.rgb(h: 360 + 120, s: 1, b: 1), (0, 1, 0)))     // angles wrap
        #expect(close(HueShade.rgb(h: -120, s: 1, b: 1), (0, 0, 1)))
    }

    @Test func everyShadeStaysInGamut() {
        for i in families {
            for k in shades {
                for c in [HuePalette.hue(i, shade: k), HuePalette.tint(i, shade: k)] {
                    #expect((0...1).contains(c.r) && (0...1).contains(c.g) && (0...1).contains(c.b), "family \(i) shade \(k)")
                }
            }
        }
        let clamped = HueShade(hueDegrees: 0, saturation: 5, brightness: 5).apply(to: (0.5, 0.2, 0.2))
        #expect(close(clamped, (1, 0, 0)))
    }

    @Test func shadesAreDistinctFromTheFamilyColourAndFromEachOther() {
        for i in families {
            let hues = shades.map { HuePalette.hue(i, shade: $0) }
            let tints = shades.map { HuePalette.tint(i, shade: $0) }
            for (k, c) in hues.enumerated() { #expect(distance(c, HuePalette.hue(i)) >= 45, "hue family \(i) shade \(k + 1)") }
            for (k, c) in tints.enumerated() { #expect(distance(c, HuePalette.tint(i)) >= 24, "tint family \(i) shade \(k + 1)") }
            for a in hues.indices {
                for b in hues.indices where b > a {
                    #expect(distance(hues[a], hues[b]) >= 35, "hue family \(i) shades \(a + 1) and \(b + 1)")
                    #expect(distance(tints[a], tints[b]) >= 30, "tint family \(i) shades \(a + 1) and \(b + 1)")
                }
            }
        }
    }

    @Test func everyShadeStaysNearestItsOwnFamilyHue() {
        for table in [HuePalette.hues, HuePalette.tints] {
            let angles = table.map(angle)
            for i in families {
                for k in shades {
                    let shaded = Constants.subagentShades[k - 1].apply(to: table[i])
                    let own = angleDistance(angle(shaded), angles[i])
                    let nearestOther = families.filter { $0 != i }.map { angleDistance(angle(shaded), angles[$0]) }.min()!
                    #expect(own < nearestOther, "family \(i) shade \(k)")
                }
            }
        }
    }

    @Test func ordinalsCycleThroughTheShades() {
        let n = Constants.subagentShadeCount
        #expect(HuePalette.shade(forOrdinal: 0) == 0 && HuePalette.shade(forOrdinal: -3) == 0)
        #expect((1...n).map { HuePalette.shade(forOrdinal: $0) } == Array(1...n))
        #expect(HuePalette.shade(forOrdinal: n + 1) == 1 && HuePalette.shade(forOrdinal: 2 * n) == n)
    }

    @Test func aShadeEqualToTheParentsIsBumpedOnceAndStaysInRange() {
        let n = Constants.subagentShadeCount
        #expect(HuePalette.shade(forOrdinal: 1, avoiding: 1) == 2)
        #expect(HuePalette.shade(forOrdinal: n, avoiding: n) == 1)
        #expect(HuePalette.shade(forOrdinal: 2, avoiding: 1) == 2)
    }

    @Test func orangeShadeTwoIsADarkerOrange() {
        #expect(close(HuePalette.hue(0, shade: 2), (0.753, 0.548, 0.201), 0.02))
    }
}
