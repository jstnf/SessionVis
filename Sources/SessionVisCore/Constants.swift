import Foundation
import CoreGraphics

/// Every tunable lives here.
public enum Constants {
    public static let activeWindow: TimeInterval = 30 * 60
    public static let endedLinger: TimeInterval = 3
    public static let touchCentroidWindow: TimeInterval = 20
    public static let beamDuration: TimeInterval = 0.7
    public static let heatWrite: CGFloat = 1.0
    public static let heatRead: CGFloat = 0.35
    public static let heatDecayPerSecond: CGFloat = 1.0 / 3.0
    public static let particlesPerWrite = 6
    public static let haloPadding: CGFloat = 24
    public static let pollInterval: TimeInterval = 1
    public static let rescanInterval: TimeInterval = 2
    public static let snapshotInterval: TimeInterval = 0.1
    public static let hookPruneAge: TimeInterval = 60 * 60
    public static let maxTreeFiles = 20_000
    public static let ringSpacing: CGFloat = 140
    public static let fileSpacing: CGFloat = 7
    public static let fileRingMinRadius: CGFloat = 28
    public static let membershipHeadBytes = 256 * 1024
    public static let recentTouchLimit = 200
    public static let agingInterval: TimeInterval = 5
    public static let watchDebounce: TimeInterval = 0.5
    public static let deathDuration: TimeInterval = 1.0
    public static let birthDuration: TimeInterval = 0.4
    public static let layoutEaseRate: Double = 4.0
    public static let tintWrite: CGFloat = 1.0
    public static let tintRead: CGFloat = 0.5
    public static let tintDuration: TimeInterval = 120
}
