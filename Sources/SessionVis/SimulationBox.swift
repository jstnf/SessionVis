import Foundation
import SessionVisCore

/// Holds the simulation outside SwiftUI's observation so stepping it per frame does not trigger view invalidation.
@MainActor
final class SimulationBox {
    private(set) var simulation = Simulation(tree: FileTree(files: []))
    /// The renderer's directory label list for this scene.
    let cache = DirectoryListCache()
    private var lastFrame: Date?

    func reset(tree: FileTree, folder: PathFolder?, filter: FileFilter, focusMode: Bool = false) {
        simulation = Simulation(tree: tree, filter: filter, viewSize: simulation.viewSize, focusMode: focusMode)
        simulation.folder = folder
        lastFrame = nil
        cache.reset()
    }

    func setFolder(_ folder: PathFolder) { simulation.folder = folder }

    /// Advances to `date`, clamping long gaps (tab switch, sleep) to 50 ms.
    func step(to date: Date) {
        let dt = lastFrame.map { min(0.05, max(0, date.timeIntervalSince($0))) } ?? 0
        lastFrame = date
        simulation.update(dt: dt, now: date)
    }

    /// On reveal after being hidden: expire the effects that piled up unstepped; the next frame starts fresh.
    func catchUp(hiddenFor: TimeInterval) {
        simulation.catchUp(hiddenFor: hiddenFor, now: Date())
        lastFrame = nil
    }

    func apply(delta: TreeDelta, now: Date) { simulation.apply(delta: delta, now: now) }
    func apply(_ snapshot: StoreSnapshot, now: Date) { simulation.apply(snapshot: snapshot, now: now) }
    func setViewSize(_ size: CGSize) { if size != simulation.viewSize { simulation.setViewSize(size) } }
    func pan(by delta: CGSize) { simulation.pan(by: delta) }
    func zoom(by factor: CGFloat, around point: CGPoint) { simulation.zoom(by: factor, around: point) }
    func resetCamera() { simulation.resetCamera() }
    func setFollow(_ id: AgentID?) { simulation.setFollow(id) }
    func stopFollowing() { simulation.stopFollowing() }
    func setFocusMode(_ on: Bool) { simulation.setFocusMode(on) }
    func setFilter(_ filter: FileFilter) {
        simulation.setFilter(filter)
        cache.reset()
    }
}
