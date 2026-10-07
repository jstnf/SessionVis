import Foundation
import CoreGraphics

public struct AvatarState: Equatable, Sendable {
    public let id: AgentID
    public var position: CGPoint
    public var target: CGPoint
    public var anchor: CGPoint          // last touch-derived target; idle drift orbits this
    public var scale: CGFloat           // 0 → 1 over spawnDuration
    public var renderScale: CGFloat     // scale × waiting pulse
    public var alpha: CGFloat           // 1 → 0 over endedLinger once ended
    public var hueIndex: Int
    public var isSubagent: Bool
    public var parent: AgentID?
    public var status: Status
    public var title: String
    public var spawnAngle: CGFloat
    public var lastTouchPath: RepoPath?
}

public struct Camera: Equatable, Sendable {
    public var center: CGPoint = .zero
    public var zoom: CGFloat = 1
    public var userAdjusted = false
    public static let minZoom: CGFloat = 0.1
    public static let maxZoom: CGFloat = 8
}

public enum Hit: Equatable, Sendable {
    case avatar(AgentID)
    case node(RepoPath)
}

struct TouchRef: Equatable, Sendable {
    let path: RepoPath
    let at: Date
}

struct GridKey: Hashable, Sendable {
    let x: Int
    let y: Int
}

public struct FileHeat: Equatable, Sendable {
    public var value: CGFloat
    public var hueIndex: Int
}

/// A file's lingering colour after a touch; fades to nothing over `tintDuration`.
public struct FileTint: Equatable, Sendable {
    public var hueIndex: Int
    public var strength: CGFloat
    public var toucher: AgentID
    public var toucherTitle: String?
    public var touchedAt: Date
}

public struct Beam: Equatable, Sendable {
    public let id: UInt64
    public let from: AgentID
    public let to: RepoPath
    public let hueIndex: Int
    public let kind: TouchKind
    public var age: TimeInterval
    public var alpha: CGFloat { max(0, 1 - CGFloat(age / Constants.beamDuration)) }
    /// 0 → 1 over the first 45% of the beam's life.
    public var dotProgress: CGFloat { min(1, CGFloat(age / Constants.beamDuration) / 0.45) }
}

public struct Particle: Equatable, Sendable {
    public var position: CGPoint
    public var velocity: CGPoint
    public var life: TimeInterval
    public let hueIndex: Int
}

/// The scene state: avatars, effects, tree animation and camera. Pure value type; the UI steps it once per frame.
public struct Simulation: Sendable {
    public private(set) var tree: FileTree
    public private(set) var layout: RadialLayout
    public private(set) var avatars: [AgentID: AvatarState] = [:]
    public private(set) var avatarOrder: [AgentID] = []
    public private(set) var camera = Camera()
    public private(set) var followedAgent: AgentID?
    public private(set) var viewSize: CGSize
    public private(set) var lastTouchSeq: UInt64 = 0
    public private(set) var time: TimeInterval = 0
    var recentTouches: [AgentID: [TouchRef]] = [:]
    public private(set) var beams: [Beam] = []
    public private(set) var particles: [Particle] = []
    public private(set) var heat: [RepoPath: FileHeat] = [:]
    public private(set) var tints: [RepoPath: FileTint] = [:]
    /// `now` of the latest `update`/`apply`; lets pure accessors age time-based state.
    public private(set) var clock = Date.distantPast
    public private(set) var renderPositions: [RepoPath: CGPoint] = [:]
    public private(set) var dying: [RepoPath: TimeInterval] = [:]
    public private(set) var born: [RepoPath: TimeInterval] = [:]
    public private(set) var touchedPaths: Set<RepoPath> = []
    public private(set) var treeVersion = 0
    /// Absolute directory the tree is rooted at; enables the existence check when reconciling a watcher snapshot.
    public var rootPath: String?
    /// Files shown in the tree, not counting ones already fading out.
    public var visibleFileCount: Int { tree.fileCount - dying.count }
    private var primed = false
    private var nextBeamId: UInt64 = 1
    static let particleMinSpeed: CGFloat = 12
    static let particleSpeedRange: CGFloat = 20
    static let particleLife: TimeInterval = 1
    static let particleDamping: Double = 0.96
    private var grid: [GridKey: [RepoPath]] = [:]

    static let gridCell: CGFloat = 40
    static let spawnOffset: CGFloat = 120
    static let centroidPush: CGFloat = 60
    static let subagentFileOffset: CGFloat = 26
    static let subagentIdleOffset: CGFloat = 30
    static let driftAmplitude: CGFloat = 15
    static let spawnDuration: TimeInterval = 0.3
    static let motionRate: Double = 2.0
    static let followRate: Double = 3.0
    static let fitMargin: CGFloat = 1.1
    static let avatarHitRadius: CGFloat = 14
    static let nodeHitRadius: CGFloat = 8

    public init(tree: FileTree, viewSize: CGSize = CGSize(width: 800, height: 500)) {
        self.tree = tree
        self.layout = RadialLayout.compute(tree)
        self.renderPositions = layout.positions
        self.viewSize = viewSize
        rebuildGrid()
        fitCamera()
    }


    // MARK: - Snapshot sync

    public mutating func apply(snapshot: StoreSnapshot, now: Date) {
        clock = now
        var seen = Set<AgentID>()
        for a in snapshot.agents {
            seen.insert(a.id)
            if var av = avatars[a.id] {
                av.status = a.status; av.title = a.title; av.hueIndex = a.hueIndex; av.parent = a.parent
                avatars[a.id] = av
            } else if a.status != .ended {
                avatars[a.id] = spawnAvatar(for: a)
                avatarOrder.append(a.id)
            }
        }
        for id in avatarOrder where !seen.contains(id) {
            avatars.removeValue(forKey: id)
            recentTouches.removeValue(forKey: id)
        }
        avatarOrder.removeAll { !seen.contains($0) }
        ingest(touches: snapshot.recentTouches.filter { $0.seq > lastTouchSeq }, now: now)
    }

    private mutating func spawnAvatar(for a: AgentSnapshot) -> AvatarState {
        let angle = Geometry.unitAngle(fromHash: Geometry.stableHash(a.id.raw))
        var pos = Geometry.pointOnCircle(center: .zero, radius: layout.outerRadius + Self.spawnOffset, angle: angle)
        if a.isSubagent, let p = a.parent, let parentAvatar = avatars[p] { pos = parentAvatar.position }
        return AvatarState(id: a.id, position: pos, target: pos, anchor: pos, scale: 0, renderScale: 0, alpha: 1,
                           hueIndex: a.hueIndex, isSubagent: a.isSubagent, parent: a.parent, status: a.status,
                           title: a.title, spawnAngle: angle, lastTouchPath: nil)
    }

    /// Records touches for positioning and fires effects. The first call is a priming pass (history: heat and tint, no beams).
    mutating func ingest(touches: [Touch], now: Date) {
        let priming = !primed
        primed = true
        for t in touches {
            ensureLaidOut(t.path)
            touchedPaths.insert(t.path)
            recentTouches[t.agent, default: []].append(TouchRef(path: t.path, at: t.at))
            avatars[t.agent]?.lastTouchPath = t.path
            lastTouchSeq = max(lastTouchSeq, t.seq)
            let hue = avatars[t.agent]?.hueIndex ?? t.hueIndex
            applyTint(t, hue: hue, now: now)
            if priming {
                if now.timeIntervalSince(t.at) <= Constants.touchCentroidWindow { applyHeat(t, hue: hue) }
            } else {
                fire(t, hue: hue)
            }
        }
    }

    /// The newest touch sets the hue; strength never drops below what remains of the previous tint.
    private mutating func applyTint(_ t: Touch, hue: Int, now: Date) {
        if let old = tints[t.path], old.touchedAt > t.at { return }
        if tints[t.path] == nil, now.timeIntervalSince(t.at) >= Constants.tintDuration { return }
        let fresh = t.kind == .write ? Constants.tintWrite : Constants.tintRead
        let remaining = tints[t.path].map { Self.tintStrength($0, at: now) } ?? 0
        tints[t.path] = FileTint(hueIndex: hue, strength: max(fresh, remaining), toucher: t.agent, toucherTitle: avatars[t.agent]?.title ?? t.agentTitle, touchedAt: t.at)
    }

    static func tintStrength(_ t: FileTint, at now: Date) -> CGFloat {
        let age = max(0, now.timeIntervalSince(t.touchedAt))
        return min(1, t.strength * CGFloat(max(0, 1 - age / Constants.tintDuration)))
    }

    /// The file's current tint aged against `clock`, or nil when it has none left.
    public func tint(_ path: RepoPath) -> (hueIndex: Int, strength: CGFloat)? {
        guard let t = tints[path] else { return nil }
        let s = Self.tintStrength(t, at: clock)
        return s > 0 ? (t.hueIndex, s) : nil
    }

    public func tintStrength(_ path: RepoPath) -> CGFloat { tint(path)?.strength ?? 0 }

    private mutating func applyHeat(_ t: Touch, hue: Int) {
        let amount = t.kind == .write ? Constants.heatWrite : Constants.heatRead
        var h = heat[t.path] ?? FileHeat(value: 0, hueIndex: hue)
        h.value = max(h.value, amount)
        h.hueIndex = hue
        heat[t.path] = h
    }

    private mutating func fire(_ t: Touch, hue: Int) {
        beams.append(Beam(id: nextBeamId, from: t.agent, to: t.path, hueIndex: hue, kind: t.kind, age: 0))
        nextBeamId += 1
        applyHeat(t, hue: hue)
        guard t.kind == .write, let origin = layout.position(t.path) else { return }
        let h = Geometry.stableHash("touch-\(t.seq)")
        for i in 0..<Constants.particlesPerWrite {
            let angle = Geometry.unitFraction(fromHash: h, salt: UInt64(i)) * 2 * .pi
            let speed = Self.particleMinSpeed + Geometry.unitFraction(fromHash: h, salt: UInt64(100 + i)) * Self.particleSpeedRange
            particles.append(Particle(position: origin, velocity: CGPoint(x: cos(angle) * speed, y: sin(angle) * speed),
                                      life: Self.particleLife, hueIndex: hue))
        }
    }

    private mutating func updateEffects(dt: TimeInterval) {
        for i in beams.indices { beams[i].age += dt }
        beams.removeAll { $0.age >= Constants.beamDuration }

        for (path, var h) in heat {
            h.value -= Constants.heatDecayPerSecond * CGFloat(dt)
            if h.value <= 0 { heat.removeValue(forKey: path) } else { heat[path] = h }
        }

        let damp = CGFloat(pow(Self.particleDamping, dt * 60))
        for i in particles.indices {
            particles[i].position.x += particles[i].velocity.x * CGFloat(dt)
            particles[i].position.y += particles[i].velocity.y * CGFloat(dt)
            particles[i].velocity.x *= damp
            particles[i].velocity.y *= damp
            particles[i].life -= dt
        }
        particles.removeAll { $0.life <= 0 }
    }

    public func heatValue(_ path: RepoPath) -> CGFloat { heat[path]?.value ?? 0 }

    /// Halo points: the main avatar plus its subagents with alpha > 0.03.
    public func haloPoints(for main: AgentID) -> [CGPoint] {
        guard let m = avatars[main], !m.isSubagent else { return [] }
        var pts = [m.position]
        for id in avatarOrder {
            if let s = avatars[id], s.isSubagent, s.parent == main, s.alpha > 0.03 { pts.append(s.position) }
        }
        return pts
    }

    mutating func ensureLaidOut(_ path: RepoPath) {
        if dying[path] != nil { revive(path); return }
        guard layout.position(path) == nil else { return }
        tree.insert(file: path)
        relayout()
    }

    /// Recomputes the layout; existing nodes keep their render position and ease to the new one. New nodes start at `startPositions[path]`, else at their parent directory's render position, else at their layout position.
    private mutating func relayout(startPositions: [RepoPath: CGPoint] = [:]) {
        treeVersion += 1
        layout = RadialLayout.compute(tree)
        rebuildGrid()
        let fresh = layout.positions.filter { renderPositions[$0.key] == nil }.sorted { $0.key.depth < $1.key.depth }
        for (path, target) in fresh {
            if let s = startPositions[path] { renderPositions[path] = s }
            else if let parent = path.parent, let pp = renderPositions[parent] { renderPositions[path] = pp }
            else { renderPositions[path] = target }
        }
        for path in renderPositions.keys where layout.position(path) == nil && dying[path] == nil { renderPositions.removeValue(forKey: path) }
    }

    public func position(of path: RepoPath) -> CGPoint? { renderPositions[path] ?? layout.position(path) }
    public func birthScale(_ path: RepoPath) -> CGFloat { born[path].map { CGFloat(min(1, $0 / Constants.birthDuration)) } ?? 1 }
    public func deathAlpha(_ path: RepoPath) -> CGFloat? { dying[path].map { CGFloat(max(0, 1 - $0 / Constants.deathDuration)) } }

    private mutating func revive(_ path: RepoPath) { dying.removeValue(forKey: path); born[path] = 0 }

    /// Cleanup shared by the end of the death fade and by name-swap conflicts. No relayout.
    private mutating func finishDeath(_ path: RepoPath) {
        dying.removeValue(forKey: path); born.removeValue(forKey: path); renderPositions.removeValue(forKey: path)
        heat.removeValue(forKey: path); tints.removeValue(forKey: path); touchedPaths.remove(path)
        tree.remove(file: path)
    }

    /// Before inserting `path`: a file sitting on one of its ancestors, or a directory sitting on the path itself, must go first.
    private mutating func clearConflicts(for path: RepoPath) {
        var anc = path.parent
        while let a = anc, !a.isRoot {
            if let n = tree.node(a), !n.isDirectory { finishDeath(a) }
            anc = a.parent
        }
        if let n = tree.node(path), n.isDirectory {
            let prefix = path.components
            for f in tree.nodes.values where !f.isDirectory && f.path.components.count > prefix.count && Array(f.path.components.prefix(prefix.count)) == prefix {
                finishDeath(f.path)
            }
        }
    }

    /// Applies a watcher delta: moved files glide from their old place, added files are born at their directory, removed files fade out.
    public mutating func apply(delta: TreeDelta, now: Date) {
        var starts: [RepoPath: CGPoint] = [:]
        for m in delta.moved {
            if let old = renderPositions[m.from] { starts[m.to] = old }
            tree.remove(file: m.from)
            renderPositions.removeValue(forKey: m.from); heat.removeValue(forKey: m.from); if touchedPaths.remove(m.from) != nil { touchedPaths.insert(m.to) }; dying.removeValue(forKey: m.from); born.removeValue(forKey: m.from)
            if let t = tints.removeValue(forKey: m.from) { tints[m.to] = t }
            if dying[m.to] != nil { revive(m.to) } else { clearConflicts(for: m.to); tree.insert(file: m.to) }
        }
        for p in delta.added {
            if dying[p] != nil { revive(p) } else if tree.node(p)?.isDirectory != false { clearConflicts(for: p); tree.insert(file: p); born[p] = 0 }
        }
        for p in delta.removed where tree.node(p) != nil && dying[p] == nil { dying[p] = 0 }
        if let snap = delta.snapshot, let root = rootPath {
            // Touch-inserted files the watcher never saw: fade them unless they really exist (e.g. gitignored files an agent wrote).
            for p in tree.files where !snap.contains(p) && dying[p] == nil {
                if !FileManager.default.fileExists(atPath: root + "/" + p.string) { dying[p] = 0 }
            }
        }
        if !delta.added.isEmpty || !delta.moved.isEmpty { relayout(startPositions: starts) }
    }

    private mutating func updateTreeTransitions(dt: TimeInterval) {
        let k = CGFloat(min(1, dt * Constants.layoutEaseRate))
        for (path, target) in layout.positions {
            if let current = renderPositions[path] { renderPositions[path] = Geometry.lerp(current, target, k) }
        }
        for path in born.keys { born[path]! += dt }
        born = born.filter { $0.value < Constants.birthDuration }
        var finished: [RepoPath] = []
        for path in dying.keys { dying[path]! += dt; if dying[path]! >= Constants.deathDuration { finished.append(path) } }
        guard !finished.isEmpty else { return }
        for path in finished { finishDeath(path) }
        relayout()
    }

    // MARK: - Per-frame update

    public mutating func update(dt: TimeInterval, now: Date) {
        time += dt
        clock = now
        let k = CGFloat(min(1, dt * Self.motionRate))
        for (path, t) in tints where now.timeIntervalSince(t.touchedAt) >= Constants.tintDuration { tints.removeValue(forKey: path) }
        for id in avatarOrder {
            guard var av = avatars[id] else { continue }
            av.scale = min(1, av.scale + CGFloat(dt / Self.spawnDuration))
            recentTouches[id] = recentTouches[id]?.filter { now.timeIntervalSince($0.at) <= Constants.touchCentroidWindow }

            if av.status != .ended { av.alpha = 1 }   // a resumed agent comes back fully visible
            if av.status == .ended {
                av.alpha = max(0, av.alpha - CGFloat(dt / Constants.endedLinger))
                if av.isSubagent, let p = av.parent, let pa = avatars[p] { av.target = pa.position }
            } else if av.isSubagent {
                let parentPos = av.parent.flatMap { avatars[$0]?.position } ?? av.position
                if let path = av.lastTouchPath, let fp = layout.position(path) {
                    av.target = Geometry.towards(fp, parentPos, by: Self.subagentFileOffset)
                } else {
                    av.target = Geometry.pointOnCircle(center: parentPos, radius: Self.subagentIdleOffset, angle: av.spawnAngle)
                }
            } else {
                let pts = (recentTouches[id] ?? []).compactMap { layout.position($0.path) }
                if !pts.isEmpty {
                    let c = Geometry.centroid(pts)
                    if Geometry.distance(c, .zero) < 1 {
                        av.anchor = Geometry.pointOnCircle(center: c, radius: Self.centroidPush, angle: av.spawnAngle)
                    } else {
                        av.anchor = Geometry.towards(c, CGPoint(x: c.x * 2, y: c.y * 2), by: Self.centroidPush)
                    }
                    av.target = av.anchor
                } else {
                    let phi = Double(av.spawnAngle)
                    av.target = CGPoint(x: av.anchor.x + Self.driftAmplitude * CGFloat(sin(0.5 * time + phi)),
                                        y: av.anchor.y + Self.driftAmplitude * CGFloat(cos(0.37 * time + phi)))
                }
            }

            av.position = Geometry.lerp(av.position, av.target, k)
            let pulse: CGFloat = av.status.isWaiting ? 1 + 0.15 * CGFloat(0.5 + 0.5 * sin(2 * .pi * time)) : 1
            av.renderScale = av.scale * pulse
            avatars[id] = av
        }
        for id in avatarOrder {
            if let av = avatars[id], av.status == .ended, av.alpha <= 0 { avatars.removeValue(forKey: id) }
        }
        avatarOrder.removeAll { avatars[$0] == nil }

        updateEffects(dt: dt)
        updateTreeTransitions(dt: dt)

        if let f = followedAgent, avatars[f] == nil { followedAgent = nil }
        if let f = followedAgent, let av = avatars[f] {
            camera.center = Geometry.lerp(camera.center, av.position, CGFloat(min(1, dt * Self.followRate)))
        }
        if followedAgent == nil, !camera.userAdjusted, let t = fitTarget(for: fitBounds()) {
            let k = CGFloat(min(1, dt * 2))
            camera.zoom += (t.zoom - camera.zoom) * k
            camera.center = Geometry.lerp(camera.center, t.center, k)
        }
    }

    // MARK: - Camera

    /// Layout bounds unioned with visible avatars, padded by 60 pt.
    func fitBounds() -> CGRect {
        var r = layout.bounds
        for av in avatars.values where av.alpha > 0.03 {
            r = r.union(CGRect(x: av.position.x, y: av.position.y, width: 0, height: 0))
        }
        return r.insetBy(dx: -60, dy: -60)
    }

    private func fitTarget(for b: CGRect) -> (zoom: CGFloat, center: CGPoint)? {
        guard b.width > 0, b.height > 0, viewSize.width > 0, viewSize.height > 0 else { return nil }
        let z = min(viewSize.width / (b.width * Self.fitMargin), viewSize.height / (b.height * Self.fitMargin))
        return (min(Camera.maxZoom, max(Camera.minZoom, z)), CGPoint(x: b.midX, y: b.midY))
    }

    mutating func fitCamera() {
        guard let t = fitTarget(for: fitBounds()) else { return }
        camera.zoom = t.zoom
        camera.center = t.center
    }

    public mutating func setViewSize(_ size: CGSize) {
        viewSize = size
        if !camera.userAdjusted { fitCamera() }
    }

    public mutating func setFollow(_ id: AgentID?) { followedAgent = id }

    public mutating func resetCamera() {
        camera.userAdjusted = false
        followedAgent = nil
        fitCamera()
    }

    public mutating func pan(by delta: CGSize) {
        camera.center.x -= delta.width / camera.zoom
        camera.center.y -= delta.height / camera.zoom
        camera.userAdjusted = true
        followedAgent = nil
    }

    public mutating func zoom(by factor: CGFloat, around screen: CGPoint) {
        let before = screenToWorld(screen)
        camera.zoom = min(Camera.maxZoom, max(Camera.minZoom, camera.zoom * factor))
        let after = screenToWorld(screen)
        camera.center.x += before.x - after.x
        camera.center.y += before.y - after.y
        camera.userAdjusted = true
        followedAgent = nil
    }

    public func worldToScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - camera.center.x) * camera.zoom + viewSize.width / 2,
                y: (p.y - camera.center.y) * camera.zoom + viewSize.height / 2)
    }

    public func screenToWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - viewSize.width / 2) / camera.zoom + camera.center.x,
                y: (p.y - viewSize.height / 2) / camera.zoom + camera.center.y)
    }

    // MARK: - Hit testing

    public func hitTest(screen: CGPoint) -> Hit? {
        var bestAvatar: (AgentID, CGFloat)?
        for id in avatarOrder {
            guard let av = avatars[id], av.alpha > 0.05 else { continue }
            let d = Geometry.distance(worldToScreen(av.position), screen)
            if d <= Self.avatarHitRadius, d < (bestAvatar?.1 ?? .infinity) { bestAvatar = (id, d) }
        }
        if let b = bestAvatar { return .avatar(b.0) }

        let world = screenToWorld(screen)
        let radius = Self.nodeHitRadius / camera.zoom
        let cell = Self.gridCell
        let cx = Int(floor(world.x / cell)), cy = Int(floor(world.y / cell))
        let span = Int(ceil(radius / cell)) + 1
        var bestNode: (RepoPath, CGFloat)?
        for gx in (cx - span)...(cx + span) {
            for gy in (cy - span)...(cy + span) {
                for p in grid[GridKey(x: gx, y: gy)] ?? [] {
                    guard let pos = layout.position(p) else { continue }
                    let d = Geometry.distance(pos, world)
                    if d <= radius, d < (bestNode?.1 ?? .infinity) { bestNode = (p, d) }
                }
            }
        }
        return bestNode.map { .node($0.0) }
    }

    private mutating func rebuildGrid() {
        grid = [:]
        for (p, pos) in layout.positions {
            grid[GridKey(x: Int(floor(pos.x / Self.gridCell)), y: Int(floor(pos.y / Self.gridCell))), default: []].append(p)
        }
    }
}
