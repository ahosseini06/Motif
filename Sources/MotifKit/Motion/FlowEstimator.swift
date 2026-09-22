import Foundation
import Vision
import CoreVideo

/// Dense flow sampled on a sparse grid. Displacements are in pixels of the *input* frame and describe how
/// content moves from the first frame to the second.
public struct FlowGrid {
    public var points: [FlowPoint]
    public var width: Int, height: Int
}

public final class FlowEstimator {
    public var columns = 44
    public var accuracy: VNGenerateOpticalFlowRequest.ComputationAccuracy = .medium

    public init() {}

    public func flow(from first: CVPixelBuffer, to second: CVPixelBuffer) throws -> FlowGrid {
        let scale = try calibration(width: CVPixelBufferGetWidth(first), height: CVPixelBufferGetHeight(first))
        return try rawFlow(from: first, to: second, scaleX: scale.x, scaleY: scale.y)
    }

    /// Vision reports displacement in the pixels of its internal network resolution, not of the input: a factor that
    /// depends on frame size and accuracy level but not on content (measured: identical to 0.2% across textures,
    /// linear from 2 to 24 px). It is measured once per frame size with a known synthetic shift.
    private func calibration(width: Int, height: Int) throws -> (x: Float, y: Float) {
        let key = "\(width)x\(height)@\(accuracy.rawValue)"
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if let cached = Self.calibrations[key] { return cached }
        let shift = 8
        let texture = SynthRenderer.texture(seed: 42, size: max(width, height) + 4 * shift)
        func crop(_ dx: Int, _ dy: Int) throws -> CVPixelBuffer {
            let rect = CGRect(x: 2 * shift - dx, y: 2 * shift - dy, width: width, height: height)
            return try SynthRenderer.pixelBuffer(from: texture.cropping(to: rect)!, width: width, height: height)
        }
        func median(_ values: [Float]) -> Float { values.sorted()[values.count / 2] }
        let origin = try crop(0, 0)
        let mx = median(try rawFlow(from: origin, to: try crop(shift, 0), scaleX: 1, scaleY: 1).points.map(\.u))
        let my = median(try rawFlow(from: origin, to: try crop(0, shift), scaleX: 1, scaleY: 1).points.map(\.v))
        guard mx > 0.5, my > 0.5 else { throw MotifError.analysis("optical-flow calibration failed (\(mx), \(my))") }
        let result = (Float(shift) / mx, Float(shift) / my)
        Self.calibrations[key] = result
        return result
    }

    private static let lock = NSLock()
    private static var calibrations: [String: (x: Float, y: Float)] = [:]

    /// Flow of content from `first` to `second`; positive u = content moved right, positive v = moved down.
    private func rawFlow(from first: CVPixelBuffer, to second: CVPixelBuffer, scaleX: Float, scaleY: Float) throws -> FlowGrid {
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: second, options: [:])
        request.computationAccuracy = accuracy
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        try VNImageRequestHandler(cvPixelBuffer: first, options: [:]).perform([request])
        guard let buffer = (request.results?.first)?.pixelBuffer else {
            throw MotifError.analysis("optical flow returned no result")
        }

        let w = CVPixelBufferGetWidth(first), h = CVPixelBufferGetHeight(first)
        let fw = CVPixelBufferGetWidth(buffer), fh = CVPixelBufferGetHeight(buffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw MotifError.analysis("flow buffer unreadable") }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let sx = scaleX, sy = scaleY

        let rows = max(8, Int((Float(columns) * Float(h) / Float(w)).rounded()))
        var points: [FlowPoint] = []
        points.reserveCapacity(columns * rows)
        let margin: Float = 0.06
        for r in 0..<rows {
            for c in 0..<columns {
                let nx = margin + (1 - 2 * margin) * (Float(c) + 0.5) / Float(columns)
                let ny = margin + (1 - 2 * margin) * (Float(r) + 0.5) / Float(rows)
                let px = min(fw - 1, Int(nx * Float(fw))), py = min(fh - 1, Int(ny * Float(fh)))
                let p = base.advanced(by: py * stride + px * 8).assumingMemoryBound(to: Float.self)
                let u = p[0] * sx, v = p[1] * sy
                if !u.isFinite || !v.isFinite { continue }
                points.append(FlowPoint(x: nx * Float(w) - Float(w) / 2, y: ny * Float(h) - Float(h) / 2, u: u, v: v))
            }
        }
        return FlowGrid(points: points, width: w, height: h)
    }
}
