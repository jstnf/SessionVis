import Foundation

/// Focus mode: the layout gives the room to the files sessions are working in. A file is active when it was
/// touched within `focusActiveWindow` or still carries a tint; everything else is packed tightly and drawn faint.
/// The active set is re-judged every `focusRelayoutInterval` of simulation time and the tree is laid out again
/// only when it changed, so the layout follows activity without jittering.
extension Simulation {
    public func isActive(_ path: RepoPath) -> Bool { activeFiles.contains(path) }

    /// Files touched within the window, or still tinted, judged against the simulation clock.
    func currentActiveFiles() -> Set<RepoPath> {
        var out = Set<RepoPath>()
        for (path, at) in lastTouchAt where clock.timeIntervalSince(at) <= Constants.focusActiveWindow && tree.node(path)?.isDirectory == false { out.insert(path) }
        for path in tints.keys where !searchTinted.contains(path) && tree.node(path)?.isDirectory == false && tint(path) != nil { out.insert(path) }
        return out
    }

    /// Switching relayouts at once from the current activity; the camera is left alone, so auto-fit follows unless
    /// the user has panned or zoomed.
    public mutating func setFocusMode(_ on: Bool) {
        guard on != focusMode else { return }
        focusMode = on
        activeFiles = on ? currentActiveFiles() : []
        nextFocusRefresh = time + Constants.focusRelayoutInterval
        relayout()
    }

    /// Called every frame: while focus is on, re-judges activity at the throttle interval and relayouts on a change.
    mutating func refreshFocus() {
        guard focusMode, time >= nextFocusRefresh else { return }
        nextFocusRefresh = time + Constants.focusRelayoutInterval
        lastTouchAt = lastTouchAt.filter { clock.timeIntervalSince($0.value) <= Constants.focusActiveWindow }
        let next = currentActiveFiles()
        guard next != activeFiles else { return }
        activeFiles = next
        relayout()
    }
}
