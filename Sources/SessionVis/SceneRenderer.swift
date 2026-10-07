import SwiftUI
import SessionVisCore

/// Draws one frame of the simulation. Pure function of the simulation state
/// (plus a cache of the sorted directory list, rebuilt only when the tree changes).
@MainActor
enum SceneRenderer {
    static let labelBudget = 80
    private struct TintKey: Hashable { let hue: Int; let level: Int }
    private static let tintLevels = 8
    static let mono9 = Font.system(size: 9, design: .monospaced)
    static let mono10 = Font.system(size: 10, design: .monospaced)

    static func draw(_ sim: Simulation, hover: Hit?, into ctx: inout GraphicsContext, size: CGSize) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.background))
        let viewport = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40)
        drawEdges(sim, &ctx, viewport)
        drawNodes(sim, &ctx, viewport)
        drawHalos(sim, &ctx)
        drawBeams(sim, &ctx)
        drawParticles(sim, &ctx)
        drawAvatars(sim, &ctx)
        drawLabels(sim, hover: hover, &ctx, viewport)
    }

    private static func circle(_ center: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    }

    private static func glow(_ ctx: inout GraphicsContext, at p: CGPoint, radius: CGFloat, color: Color, centerAlpha: Double) {
        ctx.fill(circle(p, radius), with: .radialGradient(Gradient(colors: [color.opacity(centerAlpha), color.opacity(0)]),
                                                        center: p, startRadius: 0, endRadius: radius))
    }

    // 1. Edges
    private static func drawEdges(_ sim: Simulation, _ ctx: inout GraphicsContext, _ viewport: CGRect) {
        var path = Path()
        var fading: [(Path, Double)] = []
        for node in sim.tree.nodes.values {
            guard let parent = node.path.parent,
                  let a = sim.position(of: parent), let b = sim.position(of: node.path) else { continue }
            let sa = sim.worldToScreen(a), sb = sim.worldToScreen(b)
            let box = CGRect(x: min(sa.x, sb.x), y: min(sa.y, sb.y), width: abs(sa.x - sb.x), height: abs(sa.y - sb.y))
            guard viewport.intersects(box.insetBy(dx: -1, dy: -1)) else { continue }
            var seg = Path()
            seg.move(to: sa)
            seg.addLine(to: sb)
            if let alpha = sim.deathAlpha(node.path) { fading.append((seg, Double(alpha))) } else { path.addPath(seg) }
        }
        ctx.stroke(path, with: .color(Palette.edge), lineWidth: 0.5)
        for (seg, alpha) in fading { ctx.stroke(seg, with: .color(Palette.edge.opacity(alpha)), lineWidth: 0.5) }
    }

    // 2. Nodes: glows per hot node, then batched fills (untouched files; directories and touched files; tinted files per hue/level).
    private static func drawNodes(_ sim: Simulation, _ ctx: inout GraphicsContext, _ viewport: CGRect) {
        var dim = Path(), bright = Path()
        var tinted: [TintKey: Path] = [:]
        for node in sim.tree.nodes.values {
            guard let w = sim.position(of: node.path) else { continue }
            let p = sim.worldToScreen(w)
            guard viewport.contains(p) else { continue }
            if let alpha = sim.deathAlpha(node.path) {
                let dr = (node.isDirectory ? 4 : 2.5) * alpha
                ctx.fill(circle(p, max(0.5, dr)), with: .color(Palette.danger.opacity(Double(alpha))))
                continue
            }
            let scale = sim.birthScale(node.path)
            if scale <= 0 { continue }
            let r: CGFloat = (node.isDirectory ? 4 : 2.5) * scale
            if let h = sim.heat[node.path], h.value > 0 {
                glow(&ctx, at: p, radius: r + 4 + 6 * h.value, color: Palette.hue(h.hueIndex), centerAlpha: 0.35 + 0.6 * h.value)
            }
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            if node.isDirectory { bright.addEllipse(in: rect); continue }
            if let t = sim.tint(node.path), case let level = Int((t.strength * CGFloat(tintLevels)).rounded()), level > 0 {
                tinted[TintKey(hue: t.hueIndex, level: level), default: Path()].addEllipse(in: rect)
            } else if sim.touchedPaths.contains(node.path) { bright.addEllipse(in: rect) } else { dim.addEllipse(in: rect) }
        }
        ctx.fill(dim, with: .color(Palette.node.opacity(0.6)))
        ctx.fill(bright, with: .color(Palette.node))
        for (key, path) in tinted {
            ctx.fill(path, with: .color(Palette.mix(Palette.nodeRGB, HuePalette.hue(key.hue), Double(key.level) / Double(tintLevels))))
        }
    }

    /// Non-root directories in path order, recomputed only when the tree version changes.
    private static var directoryCache: (version: Int, paths: [RepoPath])?
    /// Called when a new tree replaces the old one (a different tree can have the same counts).
    static func resetCaches() { directoryCache = nil }

    private static func sortedDirectories(_ tree: FileTree, version: Int) -> [RepoPath] {
        if let c = directoryCache, c.version == version { return c.paths }
        let paths = tree.nodes.values.filter { $0.isDirectory && !$0.path.isRoot }.map(\.path).sorted()
        directoryCache = (version, paths)
        return paths
    }

    // 3. Halos
    private static func drawHalos(_ sim: Simulation, _ ctx: inout GraphicsContext) {
        for id in sim.avatarOrder {
            guard let av = sim.avatars[id], !av.isSubagent, av.alpha > 0 else { continue }
            let pts = sim.haloPoints(for: id).map(sim.worldToScreen)
            guard !pts.isEmpty else { continue }
            let pad = Constants.haloPadding * sim.camera.zoom
            let hue = Palette.hue(av.hueIndex)
            let fill = hue.opacity(0.12 * av.alpha)
            let rim = hue.opacity(0.07 * av.alpha)
            if pts.count == 1 {
                ctx.fill(circle(pts[0], pad), with: .color(fill))
                ctx.fill(circle(pts[0], pad + 1), with: .color(rim))
                continue
            }
            let hull = Geometry.convexHull(pts)
            var path = Path()
            path.move(to: hull[0])
            for q in hull.dropFirst() { path.addLine(to: q) }
            if hull.count >= 3 { path.closeSubpath() }
            ctx.stroke(path, with: .color(fill), style: StrokeStyle(lineWidth: 2 * pad, lineCap: .round, lineJoin: .round))
            if hull.count >= 3 { ctx.fill(path, with: .color(fill)) }
            ctx.stroke(path, with: .color(rim), style: StrokeStyle(lineWidth: 2 * pad + 2, lineCap: .round, lineJoin: .round))
        }
    }

    // 4. Beams
    private static func drawBeams(_ sim: Simulation, _ ctx: inout GraphicsContext) {
        for beam in sim.beams {
            guard let av = sim.avatars[beam.from], let fw = sim.position(of: beam.to) else { continue }
            let from = sim.worldToScreen(av.position), to = sim.worldToScreen(fw)
            let color = av.isSubagent ? Palette.tint(beam.hueIndex) : Palette.hue(beam.hueIndex)
            var path = Path()
            path.move(to: from)
            path.addLine(to: to)
            ctx.stroke(path, with: .color(color.opacity(0.9 * beam.alpha)), lineWidth: beam.kind == .write ? 1.5 : 1)
            let dot = Geometry.lerp(from, to, beam.dotProgress)
            ctx.fill(circle(dot, 2.2), with: .color(color.opacity(beam.alpha)))
        }
    }

    // 5. Particles
    private static func drawParticles(_ sim: Simulation, _ ctx: inout GraphicsContext) {
        for p in sim.particles {
            let s = sim.worldToScreen(p.position)
            ctx.fill(circle(s, 1.4), with: .color(Palette.hue(p.hueIndex).opacity(p.life * 0.8)))
        }
    }

    // 6 + 7. Orbs: subagents first, then mains on top
    private static func drawAvatars(_ sim: Simulation, _ ctx: inout GraphicsContext) {
        for id in sim.avatarOrder {
            guard let av = sim.avatars[id], av.isSubagent, av.alpha > 0 else { continue }
            let p = sim.worldToScreen(av.position)
            let r = 5.5 * av.renderScale
            let tint = Palette.tint(av.hueIndex)
            glow(&ctx, at: p, radius: 3 * r, color: tint, centerAlpha: 0.55 * av.alpha)
            ctx.fill(circle(p, r), with: .color(tint.opacity(av.alpha)))
        }
        for id in sim.avatarOrder {
            guard let av = sim.avatars[id], !av.isSubagent, av.alpha > 0 else { continue }
            let p = sim.worldToScreen(av.position)
            let r = 11 * av.renderScale
            let hue = Palette.hue(av.hueIndex)
            let alpha: Double = { if case .idle = av.status { return av.alpha * 0.6 } else { return av.alpha } }()
            glow(&ctx, at: p, radius: 2.2 * r, color: hue, centerAlpha: 0.6 * alpha)
            ctx.fill(circle(p, r), with: .color(hue.opacity(alpha)))
        }
    }

    // 8. Labels (budgeted; hot files first)
    private static func drawLabels(_ sim: Simulation, hover: Hit?, _ ctx: inout GraphicsContext, _ viewport: CGRect) {
        var budget = labelBudget
        var hoveredPath: RepoPath?
        if case .node(let p) = hover { hoveredPath = p }

        for (path, h) in sim.heat.sorted(by: { $0.value.value > $1.value.value }) where budget > 0 {
            guard let w = sim.position(of: path) else { continue }
            let p = sim.worldToScreen(w)
            guard viewport.contains(p) else { continue }
            let color = sim.deathAlpha(path).map { Palette.danger.opacity(Double($0)) }
                ?? (hoveredPath == path ? Palette.text : Palette.textSecondary.opacity(0.5 + 0.5 * h.value))
            ctx.draw(Text(path.name).font(mono9).foregroundStyle(color), at: CGPoint(x: p.x + 7, y: p.y), anchor: .leading)
            budget -= 1
        }
        if let hp = hoveredPath, sim.heat[hp] == nil, let w = sim.position(of: hp), budget > 0,
           sim.tree.node(hp)?.isDirectory == false {
            let p = sim.worldToScreen(w)
            ctx.draw(Text(hp.name).font(mono9).foregroundStyle(Palette.text), at: CGPoint(x: p.x + 7, y: p.y), anchor: .leading)
            budget -= 1
        }
        if sim.camera.zoom >= 0.6 {
            for path in sortedDirectories(sim.tree, version: sim.treeVersion) where budget > 0 {
                guard let w = sim.position(of: path) else { continue }
                let p = sim.worldToScreen(w)
                guard viewport.contains(p) else { continue }
                ctx.draw(Text(path.name).font(mono9).foregroundStyle(Palette.textSecondary.opacity(0.5)),
                         at: CGPoint(x: p.x, y: p.y + 6), anchor: .top)
                budget -= 1
            }
        }
        for id in sim.avatarOrder {
            guard let av = sim.avatars[id], av.alpha > 0.02 else { continue }
            let p = sim.worldToScreen(av.position)
            if av.isSubagent {
                ctx.draw(Text(av.title).font(mono9).foregroundStyle(Palette.tint(av.hueIndex).opacity(0.85 * av.alpha * av.scale)),
                         at: CGPoint(x: p.x, y: p.y + 15), anchor: .top)
            } else {
                ctx.draw(Text(av.title).font(mono10).foregroundStyle(Palette.text.opacity(av.alpha)),
                         at: CGPoint(x: p.x, y: p.y + 24), anchor: .top)
            }
        }
    }
}
