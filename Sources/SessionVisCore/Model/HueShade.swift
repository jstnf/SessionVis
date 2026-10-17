import Foundation

/// One shade of a hue family: a small hue rotation plus saturation and brightness scaling of the family's colour.
public struct HueShade: Equatable, Sendable {
    public let hueDegrees: Double
    /// Multipliers; the results are clamped to 0…1.
    public let saturation: Double
    public let brightness: Double

    public init(hueDegrees: Double, saturation: Double, brightness: Double) {
        self.hueDegrees = hueDegrees; self.saturation = saturation; self.brightness = brightness
    }

    public func apply(to rgb: HuePalette.RGB) -> HuePalette.RGB {
        let (h, s, b) = Self.hsb(of: rgb)
        return Self.rgb(h: h + hueDegrees, s: min(1, max(0, s * saturation)), b: min(1, max(0, b * brightness)))
    }

    /// Hue in degrees (0…360), saturation and brightness in 0…1.
    static func hsb(of c: HuePalette.RGB) -> (h: Double, s: Double, b: Double) {
        let maxC = max(c.r, c.g, c.b), minC = min(c.r, c.g, c.b), delta = maxC - minC
        var h = 0.0
        if delta > 0 {
            if maxC == c.r { h = (c.g - c.b) / delta }
            else if maxC == c.g { h = (c.b - c.r) / delta + 2 }
            else { h = (c.r - c.g) / delta + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        return (h, maxC > 0 ? delta / maxC : 0, maxC)
    }

    static func rgb(h: Double, s: Double, b: Double) -> HuePalette.RGB {
        let sector = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let i = Int(sector.rounded(.down)), f = sector - Double(i)
        let p = b * (1 - s), q = b * (1 - s * f), t = b * (1 - s * (1 - f))
        switch i % 6 {
        case 0: return (b, t, p)
        case 1: return (q, b, p)
        case 2: return (p, b, t)
        case 3: return (p, q, b)
        case 4: return (t, p, b)
        default: return (b, p, q)
        }
    }
}

extension HuePalette {
    /// Shade `shade` of family `i`: 0 is the family's own colour, 1… apply `Constants.subagentShades` to it.
    /// A shade outside the table is the family colour.
    public static func hue(_ i: Int, shade: Int) -> RGB { apply(shade, to: hue(i)) }
    public static func tint(_ i: Int, shade: Int) -> RGB { apply(shade, to: tint(i)) }

    /// The shade a subagent takes from its ordinal under its session (1 for the first), cycling through the table.
    /// When that equals `parentShade` (a nested subagent's parent) the next shade is taken instead.
    public static func shade(forOrdinal n: Int, avoiding parentShade: Int = 0) -> Int {
        let count = Constants.subagentShadeCount
        guard n > 0, count > 0 else { return 0 }
        let shade = (n - 1) % count + 1
        return shade == parentShade && count > 1 ? shade % count + 1 : shade
    }

    private static func apply(_ shade: Int, to base: RGB) -> RGB {
        guard shade > 0, shade <= Constants.subagentShades.count else { return base }
        return Constants.subagentShades[shade - 1].apply(to: base)
    }
}
