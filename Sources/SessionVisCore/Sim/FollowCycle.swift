import Foundation

/// Which session Tab (or Shift-Tab) follows next.
public enum FollowCycle {
    /// The id after `current` in `order` (before it when `forward` is false), wrapping at either end.
    /// The first (or last) id when `current` is nil or not in `order`; nil when `order` is empty.
    /// When `current` has left `order` (it ended) and `lastIndex` is where it used to sit, stepping lands on whoever
    /// now holds that slot (forward) or the one before it (backward), wrapping.
    public static func next(after current: AgentID?, lastIndex: Int? = nil, in order: [AgentID], forward: Bool) -> AgentID? {
        guard !order.isEmpty else { return nil }
        let n = order.count
        guard let current, let i = order.firstIndex(of: current) else {
            guard current != nil, let k = lastIndex else { return forward ? order.first : order.last }
            return order[forward ? min(max(k, 0), n) % n : (min(max(k, 0), n) + n - 1) % n]
        }
        return order[(i + (forward ? 1 : n - 1)) % n]
    }
}
