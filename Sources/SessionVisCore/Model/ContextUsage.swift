import Foundation

/// The size of one agent's context and the window it fits in, as the list and the ring show them.
public struct ContextUsage: Equatable, Sendable {
    public let tokens: Int
    public let window: Int?
    public init(tokens: Int, window: Int?) { self.tokens = tokens; self.window = window }

    /// tokens / window rounded to the nearest percent; nil without a window.
    public var fill: Double? {
        guard let window, window > 0 else { return nil }
        return (Double(tokens) / Double(window) * 100).rounded() / 100
    }

    /// "142k / 1M · 14%", or "142k tokens" without a window.
    public var line: String {
        guard let window, let fill else { return "\(TokenFormat.short(tokens)) tokens" }
        return "\(TokenFormat.short(tokens)) / \(TokenFormat.short(window)) · \(Int((fill * 100).rounded()))%"
    }
}

/// Lifetime totals. `input` includes cache reads and cache creation.
public struct TokenTotals: Equatable, Sendable {
    public let input: Int
    public let output: Int
    public init(input: Int, output: Int) { self.input = input; self.output = output }
    /// "in 3.2M · out 48k"
    public var line: String { "in \(TokenFormat.short(input)) · out \(TokenFormat.short(output))" }
}

public enum TokenFormat {
    /// 950 → "950", 1_234 → "1.2k", 142_300 → "142k", 1_000_000 → "1M", 3_240_000 → "3.2M".
    /// Negative values read as 0 and values above `Constants.tokenCountCap` as the cap.
    public static func short(_ n: Int) -> String {
        let n = clamped(n)
        if n >= 999_500 { return scaled(n, by: 1_000_000, suffix: "M") }   // where "k" would round to 1000k
        if n >= 1_000 { return scaled(n, by: 1_000, suffix: "k") }
        return String(n)
    }

    /// One decimal below 10 units, none from 10 up, rounding half up.
    private static func scaled(_ n: Int, by unit: Int, suffix: String) -> String {
        let tenths = (n * 10 + unit / 2) / unit
        if tenths < 100 {
            return tenths % 10 == 0 ? "\(tenths / 10)\(suffix)" : "\(tenths / 10).\(tenths % 10)\(suffix)"
        }
        return "\((n + unit / 2) / unit)\(suffix)"
    }

    /// Floors to a multiple of `Constants.tokenQuantum`; negative values read as 0 and values above `Constants.tokenCountCap` as the cap.
    public static func quantise(_ n: Int) -> Int {
        let n = clamped(n)
        return n - n % Constants.tokenQuantum
    }

    private static func clamped(_ n: Int) -> Int { min(max(n, 0), Constants.tokenCountCap) }
}

public enum ContextWindow {
    /// First prefix match in `Constants.contextWindows`; nil for an unlisted model.
    public static func lookup(model: String) -> Int? {
        Constants.contextWindows.first { model.hasPrefix($0.prefix) }?.tokens
    }

    /// `base`, unless `observed` exceeds it: then the first tier that holds `observed`, or the top tier above every tier.
    public static func fitting(observed: Int, base: Int) -> Int {
        guard observed > base else { return base }
        return Constants.contextWindowTiers.first { $0 >= observed } ?? max(base, Constants.contextWindowTiers.last ?? base)
    }
}
