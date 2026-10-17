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
    public static let edgeWidth: CGFloat = 0.5
    /// Width of a lit edge at full tint strength; it eases back to `edgeWidth` as the tint fades.
    public static let litEdgeWidth: CGFloat = 1.2
    /// Ghost files (present only in a worktree) draw as rings on dashed edges.
    public static let ghostRingRadius: CGFloat = 3.4
    public static let ghostRingWidth: CGFloat = 1.0
    public static let ghostDash: [CGFloat] = [3, 2.5]

    /// Bash command text kept per tool call, and tool-result text kept for commit parsing.
    public static let commandTextLimit = 400
    public static let toolResultTextLimit = 4096
    public static let recentCommandLimit = 100

    /// Command pulses on an orb and their labels.
    public static let pulseDuration: TimeInterval = 1.0
    public static let pulseRadius: CGFloat = 44
    public static let pulseLabelDuration: TimeInterval = 2.2
    /// Commit milestone: a ripple along the agent's lit edges, then its file tints drop to this floor.
    public static let rippleDuration: TimeInterval = 1.2
    public static let committedTintFloor: CGFloat = 0.35
    /// A push lifts the commit badge off the orb over this long.
    public static let badgeLiftDuration: TimeInterval = 0.9
    /// Shell commands yield at most this many touches each.
    public static let shellOperandLimit = 8
    /// A filesystem change is credited to the one agent whose command was running within this slack...
    public static let diskAttributionSlack: TimeInterval = 2
    /// ...after waiting this long for the transcript lines around it to arrive...
    public static let diskAttributionDelay: TimeInterval = 1.5
    /// ...unless any touch on the same path happened within this window.
    public static let touchDedupeWindow: TimeInterval = 3
    /// A disk change naming more paths than this is a bulk operation (checkout, worktree add, formatter) and is not credited.
    public static let diskAttributionPathLimit = 25
}
