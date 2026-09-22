import Foundation
import CoreVideo
import Vision

/// Streaming camera-motion estimator: feed analysis frames in order, read `samples` at the end.
public final class MotionTracker {
    public private(set) var samples: [MotionSample] = []
    public let focalPixels: Double

    private let flow = FlowEstimator()
    private let depth: DepthEstimator?
    private var previous: (buffer: CVPixelBuffer, time: Double)?
    private var cachedDepth: (map: DepthEstimator.Map, time: Double)?

    /// Depth maps change slowly; one is reused for pairs within this many seconds.
    private let depthReuseSeconds = 0.45

    public init(focalPixels: Double, depth: DepthEstimator?) {
        self.focalPixels = focalPixels
        self.depth = depth
    }

    public func push(_ frame: CVPixelBuffer, time: Double) throws {
        defer { previous = (frame, time) }
        guard let prev = previous, time > prev.time else { return }
        let dt = time - prev.time
        var grid = try flow.flow(from: prev.buffer, to: frame)

        var solution = MotionSolver.solveRotation(grid.points, focal: focalPixels, seed: UInt64(samples.count + 1))
        // The flow model is first-order in rotation. A large pan or tilt per pair leaves a second-order term that
        // stretches the image exactly like a zoom of ≈ θ²; remove it so fast pans don't read as zooming.
        let w2 = Double(grid.width * grid.width), h2 = Double(grid.height * grid.height)
        solution.zoom -= 1.1 * ((w2 + 0.5 * h2) / (w2 + h2) * solution.omega.y * solution.omega.y
                                + (h2 + 0.5 * w2) / (w2 + h2) * solution.omega.x * solution.omega.x)
        var usedParallax = false

        if let depth, parallaxGate(solution) {
            // People are the usual moving subject; when the simple fit isn't clean, take them out of the vote.
            if let mask = personMask(for: prev.buffer, time: prev.time), downweightPeople(mask, in: &grid) {
                solution = MotionSolver.solveRotation(grid.points, focal: focalPixels, seed: UInt64(samples.count + 1))
            }
            let map = try depthMap(for: prev.buffer, time: prev.time, using: depth)
            attach(map, to: &grid)
            let joint = MotionSolver.solveJoint(grid.points, focal: focalPixels, start: solution)
            // Translation has to earn its place: materially better fit, or the rotation-only answer stands.
            // A moving subject close to camera is, on its own, consistent with a camera translation — so the joint fit
            // must also win over more of the frame, not merely explain the subject.
            if let t = joint.translation, joint.cost < 0.7 * solution.cost, simd_length_(t) > 1e-4,
               joint.inlierRatio > min(0.9, solution.inlierRatio + 0.08) {
                solution = Self.resolvingDepthOffset(joint)
                usedParallax = true
            }
        }

        let perSecond = 1 / dt, deg = 180 / Double.pi
        let t = solution.translation ?? .zero
        let rates: [Float] = [
            Float(solution.omega.y * deg * perSecond),      // pan
            Float(solution.omega.x * deg * perSecond),      // tilt
            Float(solution.omega.z * deg * perSecond),      // roll
            Float(log(max(1e-6, 1 + solution.zoom)) * perSecond),
            Float(t.x * perSecond),                         // truck
            Float(-t.y * perSecond),                        // pedestal (camera y is down)
            Float(t.z * perSecond),                         // dolly
        ]
        samples.append(MotionSample(time: (prev.time + time) / 2, rates: rates,
                                    confidence: Float(solution.inlierRatio), usedParallax: usedParallax))
    }

    /// Monocular depth is only known up to an affine map: model inverse depth d = α·q + β for true normalised inverse
    /// depth q, and typically β < 0 (the farthest surface reads as zero). The β part of the translational flow is
    /// indistinguishable from rotation / zoom inside one frame pair, so a pure truck shows a little false pan and a pure
    /// push-in a little false zoom, while translation itself reads 1/α too small. β is chosen, within [−5, 0], to explain
    /// away as much rotation / zoom as the translation direction allows. The clamp keeps the real combinations intact:
    /// an arc (truck with opposing pan) and a dolly-zoom (dolly with opposing zoom) would need β > 0.
    static func resolvingDepthOffset(_ joint: PairSolution) -> PairSolution {
        guard let t = joint.translation else { return joint }
        let g = SIMD3(-t.x, t.y, -t.z)                       // false (pan, tilt, zoom) per unit β
        let m = SIMD3(joint.omega.y, joint.omega.x, joint.zoom)
        let gg = (g * g).sum()
        guard gg > 1e-12 else { return joint }
        let beta = min(0, max(-5, (m * g).sum() / gg))
        var out = joint
        out.omega.y -= beta * g.x
        out.omega.x -= beta * g.y
        out.zoom -= beta * g.z
        out.translation = t * (1 - beta)
        return out
    }

    private func parallaxGate(_ s: PairSolution) -> Bool {
        abs(s.zoom) > 0.0012 || s.inlierRatio < 0.85 || s.medianResidual > 0.25
    }

    private func depthMap(for buffer: CVPixelBuffer, time: Double, using depth: DepthEstimator) throws -> DepthEstimator.Map {
        if let cached = cachedDepth, abs(cached.time - time) < depthReuseSeconds { return cached.map }
        let map = try depth.inverseDepth(for: buffer)
        cachedDepth = (map, time)
        return map
    }

    private var cachedMask: (map: DepthEstimator.Map?, time: Double)?

    private func personMask(for buffer: CVPixelBuffer, time: Double) -> DepthEstimator.Map? {
        if let cached = cachedMask, abs(cached.time - time) < depthReuseSeconds { return cached.map }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .fast
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try? VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
        let map = request.results?.first.flatMap { try? DepthEstimator.map(from: $0.pixelBuffer) }
        cachedMask = (map, time)
        return map
    }

    /// Returns true when enough of the frame is people for the re-fit to matter.
    private func downweightPeople(_ mask: DepthEstimator.Map, in grid: inout FlowGrid) -> Bool {
        let w = Float(grid.width), h = Float(grid.height)
        var covered = 0
        for i in grid.points.indices {
            let p = grid.points[i]
            if mask.sample(nx: (p.x + w / 2) / w, ny: (p.y + h / 2) / h) > 0.5 { grid.points[i].weight = 0.1; covered += 1 }
        }
        return covered * 50 > grid.points.count && covered * 10 < grid.points.count * 9
    }

    private func attach(_ map: DepthEstimator.Map, to grid: inout FlowGrid) {
        let w = Float(grid.width), h = Float(grid.height)
        var values = grid.points.map { map.sample(nx: ($0.x + w / 2) / w, ny: ($0.y + h / 2) / h) }
        let sorted = values.sorted()
        let median = max(sorted[sorted.count / 2], 1e-6)
        for i in values.indices { values[i] = min(20, max(0.02, values[i] / median)) }
        for i in grid.points.indices { grid.points[i].inverseDepth = values[i] }
    }
}

@inline(__always) private func simd_length_(_ v: SIMD3<Double>) -> Double { (v * v).sum().squareRoot() }
