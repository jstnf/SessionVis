import Foundation
import SessionVisCore

/// Holds the simulation outside SwiftUI's observation so stepping it per frame does not trigger view invalidation.
@MainActor
final class SimulationBox {
    private(set) var simulation = Simulation(tree: FileTree(files: []))
    private var lastFrame: Date?

    func reset(tree: FileTree, rootPath: String?) {
        simulation = Simulation(tree: tree, viewSize: simulation.viewSize)
        simulation.rootPath = rootPath
        lastFrame = nil
        SceneRenderer.resetCaches()
    }

    /// Advances to `date`, clamping long gaps (tab switch, sleep) to 50 ms.
    func step(to date: Date) {
        let dt = lastFrame.map { min(0.05, max(0, date.timeIntervalSince($0))) } ?? 0
        lastFrame = date
        simulation.update(dt: dt, now: date)
    }

    func apply(delta: TreeDelta, now: Date) { simulation.apply(delta: delta, now: now) }
    func apply(_ snapshot: StoreSnapshot, now: Date) { simulation.apply(snapshot: snapshot, now: now) }
    func setViewSize(_ size: CGSize) { if size != simulation.viewSize { simulation.setViewSize(size) } }
    func pan(by delta: CGSize) { simulation.pan(by: delta) }
    func zoom(by factor: CGFloat, around point: CGPoint) { simulation.zoom(by: factor, around: point) }
    func resetCamera() { simulation.resetCamera() }
    func setFollow(_ id: AgentID?) { simulation.setFollow(id) }
}
