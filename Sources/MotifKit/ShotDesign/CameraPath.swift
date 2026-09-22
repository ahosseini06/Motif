import Foundation
import simd

/// A camera pose in the designer's world: metres, y up, looking down −z at yaw 0.
/// Angles follow docs/motion-spec.md: yaw + = panned right, pitch + = tilted up, roll + = clockwise.
public struct CameraPose: Codable, Equatable, Sendable {
    public var position: SIMD3<Float>
    public var yaw: Float, pitch: Float, roll: Float          // degrees
    public var focal: Float                                   // 35 mm-equivalent focal length

    public init(position: SIMD3<Float> = [0, 1.6, 6.5], yaw: Float = 0, pitch: Float = -2, roll: Float = 0, focal: Float = 35) {
        self.position = position; self.yaw = yaw; self.pitch = pitch; self.roll = roll; self.focal = focal
    }

    public var orientation: simd_quatf {
        let rad = Float.pi / 180
        return simd_quatf(angle: -yaw * rad, axis: [0, 1, 0]) * simd_quatf(angle: pitch * rad, axis: [1, 0, 0]) * simd_quatf(angle: -roll * rad, axis: [0, 0, 1])
    }

    public var forward: SIMD3<Float> { orientation.act([0, 0, -1]) }
    public var right: SIMD3<Float> { orientation.act([1, 0, 0]) }
    public var up: SIMD3<Float> { orientation.act([0, 1, 0]) }

    /// Horizontal field of view in degrees for a 36 mm-wide frame.
    public var horizontalFOV: Float { 2 * atan(18 / focal) * 180 / .pi }

    var values: [Float] { [position.x, position.y, position.z, yaw, pitch, roll, log(focal)] }

    init(values v: [Float]) {
        position = [v[0], v[1], v[2]]; yaw = v[3]; pitch = max(-89, min(89, v[4])); roll = v[5]; focal = max(10, min(300, exp(v[6])))
    }
}

public struct CameraKeyframe: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var time: Double
    public var pose: CameraPose

    public init(time: Double, pose: CameraPose) { self.time = time; self.pose = pose }
}

/// A shot drawn in the designer: a duration and a keyframed camera. The search query is derived from it.
public struct DesignedShot: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name = "Untitled shot"
    public var duration: Double = 5
    /// Ease in and out at the ends of the shot, as an operator would; off gives constant speed.
    public var eased = false
    public var keyframes: [CameraKeyframe] = [CameraKeyframe(time: 0, pose: CameraPose())]
    public var modifiedAt = Date()

    public init() {}

    // MARK: editing

    public mutating func setKeyframe(at time: Double, pose: CameraPose, snap: Double = 0.06) {
        let t = max(0, min(duration, time))
        if let i = keyframes.firstIndex(where: { abs($0.time - t) <= snap }) { keyframes[i].pose = pose }
        else { keyframes.append(CameraKeyframe(time: t, pose: pose)); keyframes.sort { $0.time < $1.time } }
        modifiedAt = Date()
    }

    public mutating func removeKeyframe(_ id: UUID) {
        guard keyframes.count > 1 else { return }
        keyframes.removeAll { $0.id == id }
        modifiedAt = Date()
    }

    public mutating func retime(_ id: UUID, to time: Double) {
        guard let i = keyframes.firstIndex(where: { $0.id == id }) else { return }
        let lower = i > 0 ? keyframes[i - 1].time + 0.1 : 0, upper = i < keyframes.count - 1 ? keyframes[i + 1].time - 0.1 : duration
        keyframes[i].time = max(lower, min(upper, time))
        modifiedAt = Date()
    }

    /// Changing the length stretches the move rather than cutting it off.
    public mutating func setDuration(_ seconds: Double) {
        let next = max(1, min(120, seconds))
        let scale = next / max(duration, 0.001)
        for i in keyframes.indices { keyframes[i].time *= scale }
        duration = next
        modifiedAt = Date()
    }

    public func keyframe(near time: Double, within: Double = 0.06) -> CameraKeyframe? {
        keyframes.first { abs($0.time - time) <= within }
    }

    // MARK: interpolation

    /// Pose at `time`. Cubic Hermite through the keyframes with Catmull-Rom tangents, so the camera keeps its velocity
    /// through a middle keyframe instead of stopping at it.
    public func pose(at time: Double) -> CameraPose {
        guard let first = keyframes.first, let last = keyframes.last else { return CameraPose() }
        var t = max(0, min(duration, time))
        if eased, duration > 0 { let u = t / duration; t = u * u * (3 - 2 * u) * duration }
        if t <= first.time || keyframes.count == 1 { return first.pose }
        if t >= last.time { return last.pose }
        let i = keyframes.lastIndex { $0.time <= t } ?? 0
        let a = keyframes[i], b = keyframes[i + 1]
        let h = Float(b.time - a.time), u = Float((t - a.time) / (b.time - a.time))
        let pa = a.pose.values, pb = b.pose.values
        func tangent(_ index: Int) -> [Float] {
            let prev = keyframes[max(0, index - 1)], next = keyframes[min(keyframes.count - 1, index + 1)]
            let dt = Float(next.time - prev.time)
            guard dt > 0 else { return [Float](repeating: 0, count: 7) }
            return zip(next.pose.values, prev.pose.values).map { ($0 - $1) / dt }
        }
        let ma = tangent(i), mb = tangent(i + 1)
        let u2 = u * u, u3 = u2 * u
        let h00 = 2 * u3 - 3 * u2 + 1, h10 = u3 - 2 * u2 + u, h01 = -2 * u3 + 3 * u2, h11 = u3 - u2
        return CameraPose(values: (0..<7).map { h00 * pa[$0] + h10 * h * ma[$0] + h01 * pb[$0] + h11 * h * mb[$0] })
    }

    // MARK: path → motion channels

    /// The shot as motion samples in docs/motion-spec.md units — exactly what analysis produces for a real clip.
    /// `depth` gives the median scene depth seen from a pose (metres), which is what makes translation scale-free.
    public func samples(depth: (CameraPose) -> Float) -> [MotionSample] { samples { pose, _ in depth(pose) } }

    /// Same, with the time of each sample available — for callers that pre-compute depth along the path.
    public func samples(depthAt depth: (CameraPose, Double) -> Float) -> [MotionSample] {
        let step = 1 / MotionSpec.sampleRate
        let count = max(1, Int((duration / step).rounded(.down)))
        var out: [MotionSample] = []
        for k in 0..<count {
            let t0 = Double(k) * step, t1 = min(duration, t0 + step)
            guard t1 > t0 else { break }
            let a = pose(at: t0), b = pose(at: t1)
            let dt = Float(t1 - t0), deg = 180 / Float.pi
            // Relative rotation and translation expressed in the camera's own frame at the start of the step.
            let rel = a.orientation.inverse * b.orientation
            let angle = 2 * acos(max(-1, min(1, rel.real)))
            let axis = simd_length(rel.imag) > 1e-7 ? simd_normalize(rel.imag) : SIMD3<Float>(0, 0, 0)
            let omega = axis * (angle > .pi ? angle - 2 * .pi : angle) * deg / dt
            let move = a.orientation.inverse.act(b.position - a.position) / max(depth(a, t0), 0.5) / dt
            let rates: [Float] = [-omega.y, omega.x, -omega.z, log(b.focal / a.focal) / dt, move.x, move.y, -move.z]
            out.append(MotionSample(time: (t0 + t1) / 2, rates: rates, confidence: 1, usedParallax: true))
        }
        return out
    }

    public func segments(depth: (CameraPose) -> Float) -> [MotionSegment] {
        Segmenter.segments(from: samples(depth: depth), clipDuration: duration)
    }

    /// Median scene depth along the path, ray-cast once a second and interpolated: cheap enough to redo on every edit.
    public func depthProfile(on stage: ReferenceStage) -> (CameraPose, Double) -> Float {
        let length = duration
        let count = max(2, Int(length.rounded(.up)) + 1)
        let depths = (0..<count).map { stage.medianDepth(from: pose(at: length * Double($0) / Double(count - 1))) }
        return { _, t in
            let x = max(0, min(1, t / max(length, 0.001))) * Double(count - 1)
            let i = min(count - 2, Int(x)), f = Float(x - Double(i))
            return depths[i] * (1 - f) + depths[i + 1] * f
        }
    }
}

/// Starting points, so a first shot is one click and a drag rather than a blank stage.
public enum ShotTemplate: String, CaseIterable, Identifiable, Sendable {
    case pushIn = "Push-in", pullOut = "Pull-out", panRight = "Pan", tiltUp = "Tilt up", truckRight = "Truck"
    case craneUp = "Crane up", orbit = "Orbit", dollyZoom = "Dolly zoom", zoomIn = "Zoom in"
    public var id: String { rawValue }

    public func keyframes(duration: Double) -> [CameraKeyframe] {
        let start = CameraPose()
        func path(_ poses: [CameraPose]) -> [CameraKeyframe] {
            poses.enumerated().map { CameraKeyframe(time: duration * Double($0.offset) / Double(max(1, poses.count - 1)), pose: $0.element) }
        }
        var end = start
        switch self {
        case .pushIn: end.position.z -= 3
        case .pullOut: end.position.z += 3.5
        case .panRight: end.yaw += 35
        case .tiltUp: end.pitch += 18
        case .truckRight: end.position.x += 3.5
        case .craneUp: end.position.y += 2.4; end.pitch -= 16
        case .zoomIn: end.focal = 85
        case .dollyZoom: end.position.z -= 3.2; end.focal = 35 * (6.5 - 3.2) / 6.5
        case .orbit:
            // Quarter of the way round the subject at the origin, always looking at it.
            return path((0...4).map { i in
                let angle = Float(i) / 4 * (.pi / 3), radius: Float = 6.5
                var p = start
                p.position = [sin(angle) * radius, start.position.y, cos(angle) * radius]
                p.yaw = -angle * 180 / .pi
                return p
            })
        }
        return path([start, end])
    }
}

/// Saved shots live beside the app, not inside a project: a move you drew once finds shots in every project.
public enum ShotLibrary {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Motif/Shots", isDirectory: true)
    }

    public static func all() -> [DesignedShot] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(DesignedShot.self, from: Data(contentsOf: $0)) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public static func save(_ shot: DesignedShot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(shot).write(to: directory.appendingPathComponent("\(shot.id.uuidString).json"), options: .atomic)
    }

    public static func delete(_ shot: DesignedShot) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(shot.id.uuidString).json"))
    }
}
