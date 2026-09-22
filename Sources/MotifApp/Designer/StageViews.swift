import SwiftUI
import SceneKit
import MotifKit

/// One of the designer's two 3D views. Both render the same scene; they differ in camera and in what the mouse does.
struct StageView: NSViewRepresentable {
    enum Kind { case overview, camera }
    let kind: Kind
    let model: ShotDesignerModel

    func makeNSView(context: Context) -> InteractiveStageView {
        let view = InteractiveStageView(frame: .zero, options: nil)
        view.kind = kind; view.model = model
        view.scene = model.stageController.stage.scene
        view.pointOfView = kind == .overview ? model.stageController.overviewCamera : model.stageController.shotCamera
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.backgroundColor = NSColor(red: 0.955, green: 0.957, blue: 0.965, alpha: 1)
        view.isJitteringEnabled = false
        return view
    }

    func updateNSView(_ view: InteractiveStageView, context: Context) { view.model = model }
}

final class InteractiveStageView: SCNView {
    var kind: StageView.Kind = .camera
    weak var model: ShotDesignerModel?

    private enum Drag { case none, orbit, moveRig(offset: SIMD3<Float>, height: Float), liftRig }
    private var drag = Drag.none

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        if kind == .camera { MainActor.assumeIsolated { model?.stageController.setCameraViewSize(bounds.size) } }
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard kind == .overview, let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        let hits = hitTest(point, options: [.categoryBitMask: ReferenceStage.rigMask, .searchMode: SCNHitTestSearchMode.all.rawValue])
        if hits.contains(where: { $0.node.name == "rig-handle" }) {
            if event.modifierFlags.contains(.option) { drag = .liftRig }
            else {
                let height = model.pose.position.y
                let grabbed = groundPoint(at: point, height: height) ?? model.pose.position
                drag = .moveRig(offset: model.pose.position - grabbed, height: height)
            }
            NSCursor.closedHand.set()
        } else { drag = .orbit }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        let dx = Float(event.deltaX), dy = Float(event.deltaY)
        switch kind {
        case .overview:
            switch drag {
            case .orbit:
                let stage = model.stageController
                if event.modifierFlags.contains(.option) {                     // ⌥-drag slides the overview's focus across the floor
                    let scale = stage.distance * 0.0016
                    let right = SIMD3<Float>(cos(stage.azimuth), 0, -sin(stage.azimuth)), ahead = SIMD3<Float>(-sin(stage.azimuth), 0, -cos(stage.azimuth))
                    stage.target -= right * dx * scale - ahead * dy * scale
                } else { stage.azimuth -= dx * 0.008; stage.elevation += dy * 0.008 }
                stage.updateOverview()
            case .moveRig(let offset, let height):
                guard let ground = groundPoint(at: convert(event.locationInWindow, from: nil), height: height) else { return }
                model.edit { $0.position = [ground.x + offset.x, height, ground.z + offset.z] }
            case .liftRig:
                model.edit { $0.position.y -= dy * 0.02 }
            case .none: break
            }
        case .camera:
            // Sensitivity follows the lens: a long lens turns slowly, as it does on a real head.
            let look = 0.11 * max(0.25, min(1.4, 35 / model.pose.focal))
            if event.modifierFlags.contains(.option) {
                let scale: Float = 0.012
                model.edit { $0.position += $0.right * dx * scale - $0.up * dy * scale }
            } else if event.modifierFlags.contains(.shift) {
                model.edit { $0.roll += dx * 0.2 }
            } else {
                model.edit { $0.yaw += dx * look; $0.pitch -= dy * look }
            }
        }
    }

    override func mouseUp(with event: NSEvent) { drag = .none; NSCursor.arrow.set() }

    override func scrollWheel(with event: NSEvent) {
        guard let model else { return }
        let dy = Float(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 1 : 8), dx = Float(event.scrollingDeltaX) * (event.hasPreciseScrollingDeltas ? 1 : 8)
        switch kind {
        case .overview:
            model.stageController.distance *= exp(-dy * 0.004)
            model.stageController.updateOverview()
        case .camera:
            if event.modifierFlags.contains(.command) { model.edit { $0.focal *= exp(dy * 0.004) } }
            else { model.edit { $0.position += $0.forward * dy * 0.012 + $0.right * (-dx) * 0.012 } }
        }
    }

    override func magnify(with event: NSEvent) {
        guard let model else { return }
        switch kind {
        case .overview: model.stageController.distance *= exp(-Float(event.magnification)); model.stageController.updateOverview()
        case .camera: model.edit { $0.focal *= exp(Float(event.magnification)) }
        }
    }

    override func rotate(with event: NSEvent) {
        guard kind == .camera, let model else { return }
        model.edit { $0.roll -= event.rotation }
    }

    /// Where the pointer's ray meets the horizontal plane at `height`.
    private func groundPoint(at point: CGPoint, height: Float) -> SIMD3<Float>? {
        let near = SIMD3<Float>(unprojectPoint(SCNVector3(point.x, point.y, 0))), far = SIMD3<Float>(unprojectPoint(SCNVector3(point.x, point.y, 1)))
        let direction = far - near
        guard abs(direction.y) > 1e-5 else { return nil }
        let t = (height - near.y) / direction.y
        guard t > 0, t < 1 else { return nil }
        return near + direction * t
    }
}

/// The part of the camera view outside the frame, dimmed, with the frame outlined and thirds marked — Blender's passepartout.
struct Passepartout: View {
    var body: some View {
        GeometryReader { geo in
            let frame = ShotStageController.frameRect(in: geo.size)
            Canvas { ctx, size in
                var outside = Path(CGRect(origin: .zero, size: size))
                outside.addRect(frame)
                ctx.fill(outside, with: .color(Color(red: 0.1, green: 0.11, blue: 0.14).opacity(0.42)), style: FillStyle(eoFill: true))
                var thirds = Path()
                for i in 1...2 {
                    let x = frame.minX + frame.width * CGFloat(i) / 3, y = frame.minY + frame.height * CGFloat(i) / 3
                    thirds.move(to: CGPoint(x: x, y: frame.minY)); thirds.addLine(to: CGPoint(x: x, y: frame.maxY))
                    thirds.move(to: CGPoint(x: frame.minX, y: y)); thirds.addLine(to: CGPoint(x: frame.maxX, y: y))
                }
                ctx.stroke(thirds, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
                ctx.stroke(Path(frame), with: .color(.white), lineWidth: 1.5)
                ctx.stroke(Path(frame.insetBy(dx: -1.5, dy: -1.5)), with: .color(.black.opacity(0.35)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}
