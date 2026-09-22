import Foundation
import SceneKit
import Metal
import CoreVideo
import AppKit

/// A camera move with exactly known rates, in docs/motion-spec.md units. The ground truth for `motif-cli eval`,
/// and later the converter from a user-keyframed camera path to motion channels.
public struct SynthMove: Codable, Sendable {
    public var name: String
    public var rates: [Float]                  // 7 channels, constant over the clip
    public var handheldDegrees: Float = 0      // amplitude of rotational jitter
    public var movingSubject = false
    /// A damped knock just before the end, as when the record button is pressed on a locked-off camera.
    public var endBumpDegrees: Float?
    public var duration: Double = 4
    /// Measured by ray-casting the rendered scene; converts the nominal translation rates into true scene-depths/s.
    public var medianDepth: Float?

    public init(_ name: String, _ rates: [MotionChannel: Float], handheld: Float = 0, subject: Bool = false, duration: Double = 4) {
        self.name = name
        var r = [Float](repeating: 0, count: 7)
        for (c, v) in rates { r[c.rawValue] = v }
        self.rates = r; handheldDegrees = handheld; movingSubject = subject; self.duration = duration
    }

    public static let standardSet: [SynthMove] = {
        var moves: [SynthMove] = [SynthMove("static", [:])]
        let magnitudes: [MotionChannel: Float] = [.pan: 8, .tilt: 5, .roll: 6, .zoom: 0.12, .truck: 0.035, .pedestal: 0.012, .dolly: 0.04]
        for (channel, m) in magnitudes.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            moves.append(SynthMove("\(channel.name)_pos", [channel: m]))
            moves.append(SynthMove("\(channel.name)_neg", [channel: -m]))
        }
        moves += [
            SynthMove("pan_fast", [.pan: 35]),
            SynthMove("pan_slow", [.pan: 2.5]),
            SynthMove("pushin_slow", [.dolly: 0.02]),
            SynthMove("pan_tilt", [.pan: 6, .tilt: -4]),
            SynthMove("pushin_tiltup", [.dolly: 0.04, .tilt: 3]),
            SynthMove("arc_right", [.truck: 0.04, .pan: -6.9]),
            SynthMove("dolly_zoom", [.dolly: 0.04, .zoom: -0.08]),
            SynthMove("static_handheld", [:], handheld: 0.35),
            { var m = SynthMove("static_endbump", [:], duration: 6); m.endBumpDegrees = 2.0; return m }(),
            { var m = SynthMove("pan_endbump", [.pan: 6], duration: 6); m.endBumpDegrees = 2.0; return m }(),
            SynthMove("pan_handheld", [.pan: 7], handheld: 0.35),
            SynthMove("static_subject", [:], subject: true),
            SynthMove("pan_subject", [.pan: -8], subject: true),
            SynthMove("pushin_subject", [.dolly: 0.04], subject: true),
        ]
        return moves
    }()
}

public final class SynthRenderer {
    public static let nominalDepth: Float = 30          // metres; converts scene-depths/s into m/s
    public let width: Int, height: Int, fps: Double

    private let renderer: SCNRenderer
    private let scene = SCNScene()
    private let cameraNode = SCNNode()
    private let subject = SCNNode()
    private let baseFOV = CGFloat(MotionSpec.defaultHorizontalFOVDegrees)

    public init(width: Int = 640, height: Int = 360, fps: Double = 24) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw MotifError.analysis("no Metal device") }
        self.width = width; self.height = height; self.fps = fps
        renderer = SCNRenderer(device: device, options: nil)
        buildScene()
        renderer.scene = scene
        renderer.pointOfView = cameraNode
    }

    /// Returns the median scene depth seen over the clip (metres).
    @discardableResult
    public func render(_ move: SynthMove, to url: URL) async throws -> Float {
        let writer = try VideoWriter(url: url, width: width, height: height, bitrate: 6_000_000)
        var orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
        var position = SIMD3<Float>(0, 2.4, 0)
        let dt = Float(1 / fps), rad = Float.pi / 180
        subject.isHidden = !move.movingSubject
        var depths: [Float] = []

        for i in 0..<Int(move.duration * fps) {
            let t = Float(i) * dt
            let camera = cameraNode.camera!
            let zoomFactor = exp(move.rates[MotionChannel.zoom.rawValue] * t)
            camera.fieldOfView = 2 * atan(tan(baseFOV / 2 * .pi / 180) / CGFloat(zoomFactor)) * 180 / .pi

            // Jitter is added on top of the integrated path so the underlying move keeps its exact rate.
            let j = move.handheldDegrees * rad
            let jitter = simd_quatf(angle: j * sin(2 * .pi * 2.3 * t + 0.4), axis: [0, 1, 0])
                * simd_quatf(angle: j * 0.8 * sin(2 * .pi * 3.1 * t + 1.9), axis: [1, 0, 0])
                * simd_quatf(angle: j * 0.5 * sin(2 * .pi * 1.7 * t + 0.7), axis: [0, 0, 1])
            var knock = simd_quatf(angle: 0, axis: [1, 0, 0])
            let since = t - (Float(move.duration) - 0.45)
            if let bump = move.endBumpDegrees, since > 0 {
                let angle = bump * rad * exp(-since / 0.12) * sin(2 * .pi * 6 * since)
                knock = simd_quatf(angle: -angle, axis: [1, 0, 0]) * simd_quatf(angle: 0.4 * angle, axis: [0, 0, 1])
            }
            cameraNode.simdOrientation = orientation * jitter * knock
            cameraNode.simdPosition = position
            subject.simdPosition = [-2.4 + 1.2 * t, 1.2, -5.5]

            let image = renderer.snapshot(atTime: TimeInterval(t), with: CGSize(width: width, height: height), antialiasingMode: .multisampling2X)
            try writer.append(try Self.pixelBuffer(from: image, width: width, height: height), time: Double(t))

            if i % 12 == 0 { depths.append(medianDepth(position: position, orientation: orientation, zoom: zoomFactor)) }

            // Integrate one frame: rotations about the camera's own axes, translation in the camera frame.
            let r = move.rates
            let step = simd_quatf(angle: -r[0] * rad * dt, axis: [0, 1, 0])      // pan right = negative yaw
                * simd_quatf(angle: r[1] * rad * dt, axis: [1, 0, 0])            // tilt up
                * simd_quatf(angle: -r[2] * rad * dt, axis: [0, 0, 1])           // roll clockwise
            let metres = Self.nominalDepth * dt
            position += orientation.act([r[4] * metres, r[5] * metres, -r[6] * metres])
            orientation = orientation * step
        }
        try await writer.finish()
        return depths.sorted()[depths.count / 2]
    }

    private func medianDepth(position: SIMD3<Float>, orientation: simd_quatf, zoom: Float) -> Float {
        let tanHalf = tan(Float(baseFOV) / 2 * .pi / 180) / zoom, aspect = Float(height) / Float(width)
        var depths: [Float] = []
        for iy in 0..<9 {
            for ix in 0..<16 {
                let nx = (Float(ix) + 0.5) / 16 * 2 - 1, ny = (Float(iy) + 0.5) / 9 * 2 - 1
                let local = SIMD3<Float>(nx * tanHalf, -ny * tanHalf * aspect, -1)
                let end = position + orientation.act(local) * 300
                let hits = scene.rootNode.hitTestWithSegment(from: SCNVector3(position), to: SCNVector3(end),
                                                             options: [SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.closest.rawValue])
                if let hit = hits.first {
                    let world = SIMD3<Float>(hit.simdWorldCoordinates)
                    depths.append(simd_dot(world - position, orientation.act([0, 0, -1])))
                }
            }
        }
        return depths.isEmpty ? Self.nominalDepth : depths.sorted()[depths.count / 2]
    }

    // MARK: - scene

    private func buildScene() {
        let camera = SCNCamera()
        camera.projectionDirection = .horizontal
        camera.fieldOfView = baseFOV
        camera.zNear = 0.1; camera.zFar = 400
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        scene.background.contents = NSColor(white: 0.55, alpha: 1)

        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light!.type = .ambient; ambient.light!.intensity = 650
        let sun = SCNNode(); sun.light = SCNLight(); sun.light!.type = .directional; sun.light!.intensity = 700
        sun.eulerAngles = SCNVector3(-1.0, 0.6, 0)
        scene.rootNode.addChildNode(ambient); scene.rootNode.addChildNode(sun)

        var rng = SplitMix(seed: 7)
        func rand(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * Float(rng.next() % 10_000) / 10_000 }

        let floor = SCNNode(geometry: SCNPlane(width: 160, height: 160))
        floor.eulerAngles.x = -.pi / 2
        floor.geometry!.firstMaterial = Self.material(seed: 1, repeats: 24)
        scene.rootNode.addChildNode(floor)

        // Walls all round so every pan direction keeps texture in frame.
        for (i, (x, z, yaw)) in [(Float(0), Float(-45), Float(0)), (45, 0, -.pi / 2), (-45, 0, .pi / 2), (0, 45, .pi)].enumerated() {
            let wall = SCNNode(geometry: SCNPlane(width: 90, height: 40))
            wall.simdPosition = [x, 20, z]; wall.eulerAngles.y = CGFloat(yaw)
            wall.geometry!.firstMaterial = Self.material(seed: UInt64(10 + i), repeats: 8)
            scene.rootNode.addChildNode(wall)
        }

        // Clutter at many depths: parallax for the translation channels.
        for i in 0..<70 {
            let angle = rand(0, 2 * .pi), distance = rand(4, 38)
            let size = rand(0.6, 2.2) * (0.6 + distance / 20)
            let geometry: SCNGeometry = i % 3 == 0 ? SCNSphere(radius: CGFloat(size / 2))
                : i % 3 == 1 ? SCNCylinder(radius: CGFloat(size / 3), height: CGFloat(size * 2))
                : SCNBox(width: CGFloat(size), height: CGFloat(size * rand(0.8, 2.5)), length: CGFloat(size), chamferRadius: 0)
            geometry.firstMaterial = Self.material(seed: UInt64(100 + i), repeats: 2)
            let node = SCNNode(geometry: geometry)
            node.simdPosition = [sin(angle) * distance, rand(0.3, 1.5) * size, -cos(angle) * distance]
            node.eulerAngles.y = CGFloat(rand(0, 3))
            scene.rootNode.addChildNode(node)
        }

        subject.geometry = SCNBox(width: 1.7, height: 2.2, length: 0.6, chamferRadius: 0.1)
        subject.geometry!.firstMaterial = Self.material(seed: 999, repeats: 1)
        subject.isHidden = true
        scene.rootNode.addChildNode(subject)
    }

    static func material(seed: UInt64, repeats: Float) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = texture(seed: seed)
        m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .repeat
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(CGFloat(repeats), CGFloat(repeats), 1)
        m.diffuse.mipFilter = .linear
        m.isDoubleSided = true
        return m
    }

    /// Multi-scale random patches: texture at every scale, so optical flow has something to hold at any distance.
    public static func texture(seed: UInt64, size: Int = 512) -> CGImage {
        var rng = SplitMix(seed: seed)
        func unit() -> CGFloat { CGFloat(rng.next() % 10_000) / 10_000 }
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let hue = unit()
        ctx.setFillColor(NSColor(hue: hue, saturation: 0.3, brightness: 0.55, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        for (count, extent) in [(40, 120.0), (220, 40.0), (900, 12.0)] {
            for _ in 0..<count {
                let w = CGFloat(extent) * (0.4 + unit()), h = CGFloat(extent) * (0.4 + unit())
                let colour = NSColor(hue: (hue + unit() * 0.25).truncatingRemainder(dividingBy: 1), saturation: 0.2 + unit() * 0.5,
                                     brightness: 0.2 + unit() * 0.75, alpha: 0.9)
                ctx.setFillColor(colour.cgColor)
                let rect = CGRect(x: unit() * CGFloat(size) - w / 2, y: unit() * CGFloat(size) - h / 2, width: w, height: h)
                if rng.next() % 2 == 0 { ctx.fill(rect) } else { ctx.fillEllipse(in: rect) }
            }
        }
        return ctx.makeImage()!
    }

    static func pixelBuffer(from image: NSImage, width: Int, height: Int) throws -> CVPixelBuffer {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw MotifError.analysis("snapshot failed") }
        return try pixelBuffer(from: cg, width: width, height: height)
    }

    public static func pixelBuffer(from cg: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let buffer = pb else { throw MotifError.analysis("pixel buffer allocation failed") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
