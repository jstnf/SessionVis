import SwiftUI
import SessionVisCore

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    init(rgb: HuePalette.RGB) { self.init(red: rgb.r, green: rgb.g, blue: rgb.b) }
}

/// Spec colours (Global Constraints).
enum Palette {
    static let background = Color(hex: 0x0E1117)
    static let danger = Color(hex: 0xF0605A)
    static let edge = Color(hex: 0x2A3140)
    static let nodeRGB = HuePalette.rgb(0x3A4354)
    static let node = Color(rgb: nodeRGB)
    /// Linear blend from `a` toward `b` by `t` in 0…1.
    static func mix(_ a: HuePalette.RGB, _ b: HuePalette.RGB, _ t: Double) -> Color {
        Color(red: a.r + (b.r - a.r) * t, green: a.g + (b.g - a.g) * t, blue: a.b + (b.b - a.b) * t)
    }
    static let text = Color(hex: 0xE6E9EF)
    static let textSecondary = Color(hex: 0x9AA3B2)
    static let rowHighlight = Color(hex: 0x1B2230)
    static let panel = Color(hex: 0x131821)

    static func hue(_ i: Int) -> Color { Color(rgb: HuePalette.hue(i)) }
    static func tint(_ i: Int) -> Color { Color(rgb: HuePalette.tint(i)) }

    static func status(_ s: Status) -> Color {
        switch s {
        case .waiting: Color(hex: 0x5B9CF5)
        case .working: Color(hex: 0xF0A040)
        case .idle: Color(hex: 0x6FCF7B)
        case .ended: Color(hex: 0x6B7280)
        }
    }
}
