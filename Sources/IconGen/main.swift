import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SessionVisCore

// Deterministic drawing of the SessionVis icon in a 1024-pt design space.

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: IconGen <output-iconset-dir>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let S: CGFloat = 1024
let orange = HuePalette.hue(0), tintOrange = HuePalette.tint(0)

func color(_ rgb: HuePalette.RGB, _ a: CGFloat = 1) -> CGColor { CGColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: a) }
func hex(_ h: UInt32, _ a: CGFloat = 1) -> CGColor { color(HuePalette.rgb(h), a) }

func radial(_ ctx: CGContext, at c: CGPoint, radius: CGFloat, color rgb: HuePalette.RGB, alpha: CGFloat) {
    let colors = [color(rgb, alpha), color(rgb, 0)] as CFArray
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius)); ctx.clip()
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
    ctx.restoreGState()
}

func disc(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ col: CGColor) {
    ctx.setFillColor(col)
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
}

func line(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, _ col: CGColor, _ w: CGFloat) {
    ctx.setStrokeColor(col); ctx.setLineWidth(w); ctx.setLineCap(.round)
    ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
}

func draw(into ctx: CGContext) {
    // Background squircle with vignette (CoreGraphics y axis points up; the drawing is symmetric enough that we flip once).
    ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)
    let inset: CGFloat = 60
    let rect = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    let squircle = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.224, cornerHeight: rect.height * 0.224, transform: nil)
    ctx.addPath(squircle); ctx.clip()
    ctx.setFillColor(hex(0x0E1117)); ctx.fill(rect)
    let vignette = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [hex(0x1E2638), hex(0x0E1117)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(vignette, startCenter: CGPoint(x: S / 2, y: S / 2), startRadius: 0, endCenter: CGPoint(x: S / 2, y: S / 2), endRadius: S * 0.7, options: [])

    // Bold tree: thick edges and big nodes so the shapes read at Dock size.
    let root = CGPoint(x: 170, y: 512), d1 = CGPoint(x: 330, y: 330), d2 = CGPoint(x: 330, y: 700)
    let fileA = CGPoint(x: 470, y: 250), lit = CGPoint(x: 470, y: 512), fileB = CGPoint(x: 470, y: 780)
    let edgeCol = hex(0x3B4659)
    for (a, b) in [(root, d1), (root, d2), (d1, fileA), (d1, lit), (d2, fileB)] { line(ctx, a, b, edgeCol, 36) }
    let nodeCol = hex(0x6B7A94)
    disc(ctx, root, 44, nodeCol); disc(ctx, d1, 34, nodeCol); disc(ctx, d2, 34, nodeCol)
    disc(ctx, fileA, 32, nodeCol); disc(ctx, fileB, 32, nodeCol)

    // Halo around main + two subagents, one soft blob.
    let main = CGPoint(x: 760, y: 470), subA = CGPoint(x: 620, y: 300), subB = CGPoint(x: 640, y: 690)
    let hull = Geometry.convexHull([main, subA, subB])
    let pad: CGFloat = 120
    let path = CGMutablePath(); path.move(to: hull[0]); for q in hull.dropFirst() { path.addLine(to: q) }; path.closeSubpath()
    ctx.setLineJoin(.round); ctx.setLineCap(.round)
    ctx.addPath(path); ctx.setStrokeColor(color(orange, 0.30)); ctx.setLineWidth(2 * pad); ctx.strokePath()
    ctx.addPath(path); ctx.setFillColor(color(orange, 0.30)); ctx.fillPath()

    // Single beam to the lit file.
    radial(ctx, at: lit, radius: 90, color: orange, alpha: 0.9)
    disc(ctx, lit, 32, color(orange))
    line(ctx, main, lit, color(orange), 22)

    // Orbs.
    for s in [subA, subB] { radial(ctx, at: s, radius: 100, color: tintOrange, alpha: 0.55); disc(ctx, s, 44, color(tintOrange)) }
    radial(ctx, at: main, radius: 200, color: orange, alpha: 0.65)
    disc(ctx, main, 96, color(orange))
}

func render(size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / S, y: CGFloat(size) / S)
    draw(into: ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw NSError(domain: "IconGen", code: 1) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "IconGen", code: 2) }
}

for pt in [16, 32, 128, 256, 512] {
    try writePNG(render(size: pt), to: outDir.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try writePNG(render(size: pt * 2), to: outDir.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
print("wrote iconset to \(outDir.path)")
