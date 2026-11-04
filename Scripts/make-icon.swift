// Draws Motif's app icon: "Trace", an M drawn as one motion-graph line ending in a playhead dot,
// in amber on a graphite tile. Usage: swift Scripts/make-icon.swift <out.iconset>
// Source artwork: motif-site assets/brand/icon.svg (1024 canvas, mark scaled 6.2× about the centre).
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ size: Int) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Tile: 824/1024 squircle-ish rounded rect with a soft drop shadow and a hairline highlight.
    let inset = s * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: s * 185 / 1024, cornerHeight: s * 185 / 1024, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 12 / 1024), blur: s * 28 / 1024, color: CGColor(gray: 0, alpha: 0.32))
    ctx.addPath(tilePath); ctx.setFillColor(CGColor(red: 0.08, green: 0.083, blue: 0.1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let tileColours = [CGColor(red: 0.188, green: 0.196, blue: 0.227, alpha: 1), CGColor(red: 0.078, green: 0.082, blue: 0.098, alpha: 1)] as CFArray
    ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: tileColours, locations: [0, 1])!,
                           start: CGPoint(x: 0, y: s - inset), end: CGPoint(x: 0, y: inset), options: [])
    ctx.restoreGState()
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: s * 1.5 / 1024, dy: s * 1.5 / 1024), cornerWidth: s * 183.5 / 1024, cornerHeight: s * 183.5 / 1024, transform: nil))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.08)); ctx.setLineWidth(s * 3 / 1024); ctx.strokePath()

    // Mark, in the SVG's 100-unit space (y down), mapped onto the tile.
    let k = s / 1024 * 6.2
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: s / 2 + (x - 49) * k, y: s - (s / 2 + (y - 48.5) * k)) }
    let small = size <= 64                                   // thin strokes turn to mush at 16/32 px
    let path = CGMutablePath()
    path.move(to: p(10, 68)); path.addLine(to: p(19.5, 68))
    path.addCurve(to: p(36, 29), control1: p(27, 68), control2: p(28.5, 29))
    path.addCurve(to: p(50, 55), control1: p(43.5, 29), control2: p(44, 55))
    path.addCurve(to: p(64, 29), control1: p(56, 55), control2: p(56.5, 29))
    path.addCurve(to: p(80.5, 68), control1: p(71.5, 29), control2: p(73, 68))
    let stroked = path.copy(strokingWithWidth: (small ? 11 : 7.5) * k, lineCap: .round, lineJoin: .round, miterLimit: 10)
    let r = (small ? 8.75 : 6.25) * k
    let dot = CGPath(ellipseIn: CGRect(x: p(87.5, 68).x - r, y: p(87.5, 68).y - r, width: 2 * r, height: 2 * r), transform: nil)
    let ink = CGGradient(colorsSpace: nil, colors: [CGColor(red: 1.0, green: 0.824, blue: 0.478, alpha: 1), CGColor(red: 1.0, green: 0.71, blue: 0.18, alpha: 1)] as CFArray, locations: [0, 1])!
    for shape in [stroked, dot] {                            // filled one at a time: their windings would cancel where they overlap
        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        ctx.drawLinearGradient(ink, start: p(0, 26), end: p(0, 75), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try draw(points * scale).write(to: out.appendingPathComponent(name))
}
