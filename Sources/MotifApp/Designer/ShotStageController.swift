import SceneKit
import AppKit
import MotifKit

/// The SceneKit side of the shot designer: the reference set, the camera being keyframed (with a rig only the overview
/// can see), its path, and the overview camera orbiting the set.
@MainActor
final class ShotStageController {
    /// The camera view shows more than the frame, dimmed — so you can see what a move is about to bring in.
    static let overscan: CGFloat = 1.28

    let stage = ReferenceStage()
    let shotCamera = SCNNode()
    let overviewCamera = SCNNode()

    private let rig = SCNNode()
    private let frustum = SCNNode()
    private let path = SCNNode()
    private var cameraViewSize = CGSize(width: 16, height: 9)
    private(set) var pose = CameraPose()

    // Overview orbit
    var azimuth: Float = -0.62, elevation: Float = 0.5, distance: Float = 21
    var target = SIMD3<Float>(0, 1, -3)

    private let accent = NSColor(red: 0.369, green: 0.416, blue: 0.824, alpha: 1)

    init() {
        let camera = SCNCamera()
        camera.projectionDirection = .horizontal
        camera.zNear = 0.05; camera.zFar = 400
        camera.categoryBitMask = ReferenceStage.setMask
        shotCamera.camera = camera
        stage.scene.rootNode.addChildNode(shotCamera)

        let body = SCNNode(geometry: SCNBox(width: 0.34, height: 0.26, length: 0.5, chamferRadius: 0.03)); body.simdPosition = [0, 0, 0.25]
        body.geometry!.firstMaterial = Self.flat(NSColor(white: 0.18, alpha: 1))
        let lens = SCNNode(geometry: SCNCylinder(radius: 0.1, height: 0.16)); lens.eulerAngles.x = .pi / 2; lens.simdPosition = [0, 0, -0.06]
        lens.geometry!.firstMaterial = Self.flat(NSColor(white: 0.3, alpha: 1))
        // Generous invisible handle: the rig is small on screen and should be easy to grab.
        let handle = SCNNode(geometry: SCNSphere(radius: 0.75)); handle.name = "rig-handle"
        handle.geometry!.firstMaterial = Self.flat(.white); handle.opacity = 0.011
        for node in [body, lens, handle, frustum] { rig.addChildNode(node) }
        shotCamera.addChildNode(rig)
        stage.scene.rootNode.addChildNode(path)

        let overview = SCNCamera()
        overview.fieldOfView = 36; overview.zNear = 0.1; overview.zFar = 600
        overview.categoryBitMask = ReferenceStage.setMask | ReferenceStage.rigMask
        overviewCamera.camera = overview
        stage.scene.rootNode.addChildNode(overviewCamera)
        updateOverview()
        apply(pose)
    }

    func apply(_ pose: CameraPose) {
        let focalChanged = pose.focal != self.pose.focal || frustum.childNodes.isEmpty
        self.pose = pose
        shotCamera.simdPosition = pose.position
        shotCamera.simdOrientation = pose.orientation
        updateProjection()
        if focalChanged { rebuildFrustum() }
    }

    func setCameraViewSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1, size != cameraViewSize else { return }
        cameraViewSize = size
        updateProjection()
    }

    /// The frame inside a camera view of the given size (16:9, inset by the overscan).
    static func frameRect(in size: CGSize) -> CGRect {
        let fitted = min(size.width, size.height * 16 / 9)
        let w = fitted / overscan, h = w * 9 / 16
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func updateProjection() {
        let frame = Self.frameRect(in: cameraViewSize)
        let tanShot = tan(CGFloat(pose.horizontalFOV) / 2 * .pi / 180)
        shotCamera.camera?.fieldOfView = 2 * atan(tanShot * cameraViewSize.width / frame.width) * 180 / .pi
    }

    func updateOverview() {
        elevation = max(0.08, min(1.45, elevation)); distance = max(5, min(90, distance))
        let offset = SIMD3<Float>(sin(azimuth) * cos(elevation), sin(elevation), cos(azimuth) * cos(elevation)) * distance
        overviewCamera.simdPosition = target + offset
        overviewCamera.simdLook(at: target, up: [0, 1, 0], localFront: [0, 0, -1])
    }

    // MARK: rig + path

    private func rebuildFrustum() {
        frustum.childNodes.forEach { $0.removeFromParentNode() }
        let reach: Float = 3, halfW = tan(pose.horizontalFOV / 2 * .pi / 180) * reach, halfH = halfW * 9 / 16
        let corners: [SIMD3<Float>] = [[-halfW, halfH, -reach], [halfW, halfH, -reach], [halfW, -halfH, -reach], [-halfW, -halfH, -reach]]
        for (i, corner) in corners.enumerated() {
            frustum.addChildNode(Self.rod(from: .zero, to: corner, radius: 0.012, colour: accent))
            frustum.addChildNode(Self.rod(from: corner, to: corners[(i + 1) % 4], radius: 0.012, colour: accent))
        }
        // Which way is up in frame — makes roll readable from the overview.
        frustum.addChildNode(Self.rod(from: [0, halfH, -reach], to: [0, halfH + 0.35, -reach], radius: 0.02, colour: accent))
        rig.enumerateHierarchy { node, _ in node.categoryBitMask = ReferenceStage.rigMask; node.castsShadow = false }
    }

    func rebuildPath(for shot: DesignedShot, currentTime: Double) {
        path.childNodes.forEach { $0.removeFromParentNode() }
        guard shot.keyframes.count > 1 else { return }
        let steps = max(12, min(96, Int(shot.duration * 10)))
        var previous = shot.pose(at: 0).position
        for i in 1...steps {
            let position = shot.pose(at: shot.duration * Double(i) / Double(steps)).position
            if simd_distance(position, previous) > 0.004 { path.addChildNode(Self.rod(from: previous, to: position, radius: 0.028, colour: accent)) }
            previous = position
        }
        for key in shot.keyframes {
            let current = abs(key.time - currentTime) < 0.06
            let marker = SCNNode(geometry: SCNSphere(radius: current ? 0.15 : 0.1))
            marker.geometry!.firstMaterial = Self.flat(current ? accent : .white)
            marker.simdPosition = key.pose.position
            path.addChildNode(marker)
            if !current {
                let ring = SCNNode(geometry: SCNSphere(radius: 0.125)); ring.geometry!.firstMaterial = Self.flat(accent)
                ring.geometry!.firstMaterial!.cullMode = .front            // an outline: only the far side draws
                ring.simdPosition = key.pose.position
                path.addChildNode(ring)
            }
        }
        path.enumerateHierarchy { node, _ in node.categoryBitMask = ReferenceStage.rigMask; node.castsShadow = false }
    }

    static func flat(_ colour: NSColor) -> SCNMaterial {
        let m = SCNMaterial(); m.diffuse.contents = colour; m.lightingModel = .constant
        return m
    }

    static func rod(from a: SIMD3<Float>, to b: SIMD3<Float>, radius: CGFloat, colour: NSColor) -> SCNNode {
        let length = simd_distance(a, b)
        let node = SCNNode(geometry: SCNCylinder(radius: radius, height: CGFloat(length)))
        node.geometry!.firstMaterial = flat(colour)
        (node.geometry as? SCNCylinder)?.radialSegmentCount = 8
        node.simdPosition = (a + b) / 2
        if length > 1e-5 { node.simdOrientation = simd_quatf(from: [0, 1, 0], to: simd_normalize(b - a)) }
        return node
    }
}
