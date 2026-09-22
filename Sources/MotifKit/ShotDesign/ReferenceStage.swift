import Foundation
import SceneKit
import AppKit

/// The reference set the shot designer films: a figure to frame, a second figure, and objects at many depths so that
/// translation reads as parallax. Also answers "how deep is the scene from here", which turns metres into scene-depths.
public final class ReferenceStage {
    /// Set dressing. Visible to every camera.
    public static let setMask = 1
    /// Camera rig, path and keyframe markers. Visible in the overview only — the shot camera must not film its own rig.
    public static let rigMask = 2

    public let scene = SCNScene()
    public let setRoot = SCNNode()

    public init() {
        scene.background.contents = NSColor(red: 0.955, green: 0.957, blue: 0.965, alpha: 1)
        scene.rootNode.addChildNode(setRoot)
        build()
    }

    /// Median distance along the view axis to whatever the pose sees, in metres.
    public func medianDepth(from pose: CameraPose) -> Float {
        let tanHalf = tan(pose.horizontalFOV / 2 * .pi / 180), aspect: Float = 9 / 16
        var depths: [Float] = []
        for iy in 0..<7 {
            for ix in 0..<12 {
                let nx = (Float(ix) + 0.5) / 12 * 2 - 1, ny = (Float(iy) + 0.5) / 7 * 2 - 1
                let direction = pose.orientation.act(SIMD3<Float>(nx * tanHalf, -ny * tanHalf * aspect, -1))
                let end = pose.position + direction * 200
                let hits = setRoot.hitTestWithSegment(from: SCNVector3(pose.position), to: SCNVector3(end),
                                                      options: [SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.closest.rawValue])
                if let hit = hits.first { depths.append(simd_dot(SIMD3<Float>(hit.simdWorldCoordinates) - pose.position, pose.forward)) }
            }
        }
        let valid = depths.filter { $0 > 0.2 }.sorted()
        return valid.isEmpty ? 10 : valid[valid.count / 2]
    }

    // MARK: set

    private func build() {
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light!.type = .ambient; ambient.light!.intensity = 520
        ambient.light!.color = NSColor.white
        let sun = SCNNode(); sun.light = SCNLight(); sun.light!.type = .directional; sun.light!.intensity = 780
        sun.light!.castsShadow = true; sun.light!.shadowMode = .deferred; sun.light!.shadowColor = NSColor.black.withAlphaComponent(0.22)
        sun.light!.shadowRadius = 6; sun.light!.shadowSampleCount = 8
        sun.eulerAngles = SCNVector3(-0.95, 0.7, 0)
        scene.rootNode.addChildNode(ambient); scene.rootNode.addChildNode(sun)

        let ground = SCNNode(geometry: SCNPlane(width: 120, height: 120))
        ground.eulerAngles.x = -.pi / 2
        let groundMaterial = Self.matte(NSColor.white)
        groundMaterial.diffuse.contents = Self.gridTexture()
        groundMaterial.diffuse.wrapS = .repeat; groundMaterial.diffuse.wrapT = .repeat
        groundMaterial.diffuse.contentsTransform = SCNMatrix4MakeScale(60, 60, 1)          // one cell = 2 m
        groundMaterial.diffuse.mipFilter = .linear
        ground.geometry!.firstMaterial = groundMaterial
        add(ground)

        let accent = NSColor(red: 0.369, green: 0.416, blue: 0.824, alpha: 1)
        add(Self.figure(colour: accent), at: [0, 0, 0])                                     // the subject
        add(Self.figure(colour: NSColor(white: 0.62, alpha: 1)), at: [2.6, 0, -3.2], yaw: 0.5)
        add(Self.figure(colour: NSColor(white: 0.70, alpha: 1)), at: [-5.5, 0, -9], yaw: -0.8)

        let stone = NSColor(white: 0.86, alpha: 1), dark = NSColor(white: 0.74, alpha: 1)
        for (i, z) in stride(from: Float(3), through: -21, by: -4).enumerated() {            // a colonnade: depth cues both sides
            for x in [Float(-4.2), 4.2] {
                let pillar = SCNNode(geometry: SCNBox(width: 0.5, height: 3.6, length: 0.5, chamferRadius: 0.03))
                pillar.geometry!.firstMaterial = Self.matte(i % 2 == 0 ? stone : dark)
                add(pillar, at: [x, 1.8, z])
            }
        }
        for (position, size) in [(SIMD3<Float>(-1.9, 0, 1.6), SIMD3<Float>(0.9, 0.7, 0.9)), ([1.7, 0, 2.4], [0.6, 1.1, 0.6]),
                                 ([-2.6, 0, -4.5], [1.4, 1.0, 1.0]), ([3.1, 0, -8], [1.2, 2.2, 1.2]), ([-1.2, 0, -12], [2.4, 1.4, 1.2])] {
            let crate = SCNNode(geometry: SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0.04))
            crate.geometry!.firstMaterial = Self.matte(NSColor(white: 0.80, alpha: 1))
            add(crate, at: [position.x, size.y / 2, position.z])
        }
        for (x, z, h) in [(Float(-8), Float(-6), Float(4.5)), (8.5, -11, 5.5), (-10, -17, 6), (7, 2, 4), (11, -22, 7), (-7, 5, 3.8)] {
            let tree = SCNNode()
            let trunk = SCNNode(geometry: SCNCylinder(radius: 0.18, height: CGFloat(h * 0.4))); trunk.simdPosition = [0, h * 0.2, 0]
            trunk.geometry!.firstMaterial = Self.matte(NSColor(white: 0.66, alpha: 1))
            let crown = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: CGFloat(h * 0.28), height: CGFloat(h * 0.7))); crown.simdPosition = [0, h * 0.4 + h * 0.35, 0]
            crown.geometry!.firstMaterial = Self.matte(NSColor(red: 0.78, green: 0.84, blue: 0.80, alpha: 1))
            tree.addChildNode(trunk); tree.addChildNode(crown)
            add(tree, at: [x, 0, z])
        }
        let wall = SCNNode(geometry: SCNBox(width: 30, height: 7, length: 0.4, chamferRadius: 0))
        wall.geometry!.firstMaterial = Self.matte(NSColor(white: 0.90, alpha: 1))
        add(wall, at: [0, 3.5, -27])
        for x in stride(from: Float(-12), through: 12, by: 4) {
            let window = SCNNode(geometry: SCNBox(width: 1.6, height: 2.4, length: 0.1, chamferRadius: 0))
            window.geometry!.firstMaterial = Self.matte(NSColor(white: 0.72, alpha: 1))
            add(window, at: [x, 3.8, -26.75])
        }
        setRoot.enumerateHierarchy { node, _ in node.categoryBitMask = Self.setMask; node.castsShadow = true }
    }

    private func add(_ node: SCNNode, at position: SIMD3<Float>? = nil, yaw: Float = 0) {
        if let position { node.simdPosition = position }
        if yaw != 0 { node.eulerAngles.y = CGFloat(yaw) }
        setRoot.addChildNode(node)
    }

    static func matte(_ colour: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = colour
        m.lightingModel = .lambert
        return m
    }

    /// 1.75 m stand-in: body, head and a nose so you can tell which way it faces.
    static func figure(colour: NSColor) -> SCNNode {
        let node = SCNNode()
        let body = SCNNode(geometry: SCNCapsule(capRadius: 0.24, height: 1.45)); body.simdPosition = [0, 0.725, 0]
        let head = SCNNode(geometry: SCNSphere(radius: 0.16)); head.simdPosition = [0, 1.6, 0]
        let nose = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.05, height: 0.14)); nose.simdPosition = [0, 1.6, 0.2]; nose.eulerAngles.x = .pi / 2
        for part in [body, head, nose] { part.geometry!.firstMaterial = matte(colour); node.addChildNode(part) }
        return node
    }

    static func gridTexture() -> CGImage {
        let size = 128
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor(white: 0.93, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setStrokeColor(NSColor(white: 0.80, alpha: 1).cgColor); ctx.setLineWidth(2)
        ctx.stroke(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setStrokeColor(NSColor(white: 0.87, alpha: 1).cgColor); ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: size / 2, y: 0)); ctx.addLine(to: CGPoint(x: size / 2, y: size))
        ctx.move(to: CGPoint(x: 0, y: size / 2)); ctx.addLine(to: CGPoint(x: size, y: size / 2)); ctx.strokePath()
        return ctx.makeImage()!
    }
}
