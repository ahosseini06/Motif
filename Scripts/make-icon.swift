// Draws Motif's app icon: a frame trailing two ghosts of itself — a camera move. Usage: swift Scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ size: Int) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let inset = s * 0.1
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: s * 0.185, cornerHeight: s * 0.185, transform: nil))
    ctx.clip()
    let colours = [CGColor(red: 0.16, green: 0.165, blue: 0.19, alpha: 1), CGColor(red: 0.05, green: 0.052, blue: 0.06, alpha: 1)] as CFArray
    ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: colours, locations: [0, 1])!,
                           start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    let w = s * 0.40, h = w * 9 / 16
    for (i, alpha) in [0.22, 0.5, 1.0].enumerated() {
        let t = CGFloat(i)
        let rect = CGRect(x: s * 0.215 + t * s * 0.085, y: s * 0.30 + t * s * 0.085, width: w, height: h)
        ctx.setStrokeColor(CGColor(red: 1.0, green: 0.72, blue: 0.26, alpha: alpha))
        ctx.setLineWidth(s * 0.028)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: s * 0.03, cornerHeight: s * 0.03, transform: nil))
        ctx.strokePath()
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try draw(points * scale).write(to: out.appendingPathComponent(name))
}
