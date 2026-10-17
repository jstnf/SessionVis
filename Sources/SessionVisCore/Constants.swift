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

    /// A git subprocess (listing files or worktrees) is terminated after this long.
    public static let gitTimeout: TimeInterval = 3
    /// Pause before listing worktrees after the registry directory changes, so git has finished writing the entry.
    public static let registryRefreshDelay: TimeInterval = 0.3

    /// After a timed-out git subprocess is asked to terminate, it is killed and its output abandoned following this grace.
    public static let gitKillGrace: TimeInterval = 1

    /// How often a git subprocess read checks whether it should be abandoned.
    public static let gitReadPollInterval: TimeInterval = 0.1

    /// How many suffix patterns Settings offers as one-click hidden-file rules.
    public static let filterSuggestionLimit = 12

    /// Following a session frames its orb, its halo and its recent touches within this zoom range, padded in world points.
    public static let followMinZoom: CGFloat = 0.6
    public static let followMaxZoom: CGFloat = 2.5
    public static let followPadding: CGFloat = 80
    /// Per-second easing rates toward the follow frame; the zoom eases slower so a spreading session does not breathe.
    public static let followCenterRate: Double = 3.0
    public static let followZoomRate: Double = 1.2
    /// Orb radii at render scale 1, shared by the orbs and the follow ring.
    public static let orbRadiusMain: CGFloat = 11
    public static let orbRadiusSubagent: CGFloat = 5.5
    /// The ring drawn just outside the followed orb.
    public static let followRingGap: CGFloat = 5
    public static let followRingWidth: CGFloat = 1.2
    /// Ripples, badges and labels are not drawn for an avatar at or below this alpha.
    public static let effectMinAlpha: Double = 0.02
    /// The followed orb stays at least this far inside the view edge, in screen points.
    public static let followOrbMargin: CGFloat = 40
    /// An avatar at or below this alpha is treated as gone: no ring, no halo point, no part in the follow frame.
    public static let haloMinAlpha: Double = 0.03
    /// The echo ring sits this far outside the main ring, in points.
    public static let followRingEchoOffset: CGFloat = 2
    /// Opacities of the main ring and its echo, before the orb's own alpha.
    public static let followRingOpacity: Double = 0.9
    public static let followRingEchoOpacity: Double = 0.25
    /// `ps` is given this long when bringing a session's terminal to the front.
    public static let terminalCommandTimeout: TimeInterval = 3
    /// `osascript` is given this long. The first time the app scripts a terminal, macOS shows an Automation consent
    /// dialog and the script blocks until it is answered, so this must outlast a person reading it.
    public static let terminalFocusTimeout: TimeInterval = 30
    /// A session file's pid is trusted only if the process started within this much of the file's `startedAt`.
    public static let terminalStartTolerance: TimeInterval = 60
    /// How long the session list shows why a terminal could not be opened.
    public static let terminalMessageDuration: TimeInterval = 4
    /// Context window per model-id prefix, first match wins; an id matching none has no known window.
    public static let contextWindows: [(prefix: String, tokens: Int)] = [("claude-haiku-4-5", 200_000), ("claude-", 1_000_000)]
    /// When an observed context exceeds its model's window, the window is raised to the first of these that holds it.
    public static let contextWindowTiers = [200_000, 1_000_000]
    /// Parsed token counts are clamped to 0...this; anything larger is a malformed record.
    public static let tokenCountCap = 1_000_000_000_000
    /// Published token counts are rounded down to a multiple of this, so they stay stable to the hundred.
    public static let tokenQuantum = 100
    /// Context fill at which the ring and the list line turn amber, then red; below the minimum the ring is not drawn.
    public static let contextWarnFill = 0.8
    public static let contextDangerFill = 0.92
    public static let contextRingMinFill = 0.05
    /// The context ring sits this far outside the orb's edge.
    public static let contextRingGap: CGFloat = 3
    public static let contextRingWidth: CGFloat = 1.5
    /// Focus mode. A file is active when touched within this window (or while it still carries a tint)...
    public static let focusActiveWindow: TimeInterval = 30 * 60
    /// ...the active set is re-judged this often, relaying the tree out only when it changed...
    public static let focusRelayoutInterval: TimeInterval = 3
    /// ...a directory's sector weighs its active files plus this much per file it holds...
    public static let focusInactiveWeight: CGFloat = 0.02
    /// ...an inactive file takes this much of its ring instead of `fileSpacing`...
    public static let focusInactiveSpacing: CGFloat = 1.5
    /// ...sibling directories are laid out at least this far apart on their ring, however idle...
    public static let focusMinSiblingSpacing: CGFloat = 16
    /// ...and is drawn this faint and this small, as is the edge to it.
    public static let focusInactiveAlpha: Double = 0.15
    /// Radius of an inactive file's dot in screen points (unlike `focusInactiveSpacing`, which is world units).
    public static let focusInactiveRadius: CGFloat = 1.0
    /// Subagents take a shade of their session's hue family, by the rank of their transcript among the session's, cycling through these. Rotations stay
    /// within ±5° because the orange and yellow families sit 15° apart; the shades differ mainly in saturation and brightness.
    public static let subagentShades: [HueShade] = [
        HueShade(hueDegrees: -5, saturation: 0.72, brightness: 1.00),   // paler
        HueShade(hueDegrees: 5, saturation: 1.00, brightness: 0.80),    // darker
        HueShade(hueDegrees: -3, saturation: 0.50, brightness: 0.92),   // pastel
        HueShade(hueDegrees: 3, saturation: 1.15, brightness: 0.68),    // deep
    ]
    public static var subagentShadeCount: Int { subagentShades.count }
    /// How far up a parent chain the store walks before giving up.
    public static let maxAgentDepth = 16
    /// The app-wide hook spool is drained on vnode events and at least this often...
    public static let hookSpoolPollInterval: TimeInterval = 1
    /// ...and payloads older than `hookPruneAge` are pruned every this many drains.
    public static let hookSpoolPruneEveryTicks = 600

    /// A tab revealed after being hidden advances its scene in steps this long...
    public static let catchUpStep: TimeInterval = 0.1
    /// ...for at most this much simulated time, which outlives every beam, pulse, ripple, particle and heat glow.
    public static let catchUpMaxDuration: TimeInterval = 5
    /// A hidden tab polls its store this often (the visible one uses `snapshotInterval`); aging and retirement run in the poll.
    public static let hiddenSnapshotInterval: TimeInterval = 1
    /// The tab strip above the scene.
    public static let tabStripHeight: CGFloat = 30
    /// A waiting-on-permission count in a tab badge pulses with this period.
    public static let tabBadgePulsePeriod: TimeInterval = 1.6

    /// The tab badge's waiting count redraws at most this often while it pulses.
    public static let tabBadgePulseInterval: TimeInterval = 0.1
    /// The waiting count's opacity swings between `tabBadgePulseFloor` and `tabBadgePulseFloor + tabBadgePulseDepth`.
    public static let tabBadgePulseFloor: Double = 0.55
    public static let tabBadgePulseDepth: Double = 0.45

    /// The main window's size on a first launch, before there is a saved frame to restore.
    public static let defaultWindowWidth: CGFloat = 1400
    public static let defaultWindowHeight: CGFloat = 900

    /// How long an app-level launch message (such as a refused `--replay`) stays on screen.
    public static let launchMessageDuration: TimeInterval = 6
}
