import Foundation
import CoreML
import Vision
import CoreVideo

/// Relative inverse depth (near = large) from Depth Anything V2 Small — Apple's Core ML package, Apache-2.0.
/// Downloaded on first use, revision-pinned, compiled on this machine, cached in Application Support.
public final class DepthEstimator {
    public struct Map {
        public var width: Int, height: Int, values: [Float]

        /// Bilinear-free nearest sample at normalised coordinates.
        public func sample(nx: Float, ny: Float) -> Float {
            let x = min(width - 1, max(0, Int(nx * Float(width)))), y = min(height - 1, max(0, Int(ny * Float(height))))
            return values[y * width + x]
        }
    }

    static let repo = "apple/coreml-depth-anything-v2-small"
    static let revision = "main"
    static let packageName = "DepthAnythingV2SmallF16.mlpackage"
    static let files = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]

    private let model: VNCoreMLModel

    private init(model: VNCoreMLModel) { self.model = model }

    public static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Motif/Models", isDirectory: true)
    }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: compiledURL.path)
    }

    static var compiledURL: URL { modelsDirectory.appendingPathComponent("DepthAnythingV2SmallF16.mlmodelc") }

    /// Loads the model, downloading (~50 MB) and compiling it the first time.
    public static func load(progress: ((String) -> Void)? = nil) async throws -> DepthEstimator {
        let fm = FileManager.default
        if !fm.fileExists(atPath: compiledURL.path) {
            try fm.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            let package = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(packageName)
            for file in files {
                progress?("Downloading depth model — \((file as NSString).lastPathComponent)")
                let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(packageName)/\(file)")!
                let (tmp, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw MotifError.analysis("depth model download failed: \(file)")
                }
                let dest = package.appendingPathComponent(file)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: tmp, to: dest)
            }
            progress?("Compiling depth model")
            let compiled = try await MLModel.compileModel(at: package)
            _ = try? fm.removeItem(at: compiledURL)
            try fm.moveItem(at: compiled, to: compiledURL)
            try? fm.removeItem(at: package.deletingLastPathComponent())
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var dir = modelsDirectory; try? dir.setResourceValues(values)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let ml = try MLModel(contentsOf: compiledURL, configuration: config)
        return DepthEstimator(model: try VNCoreMLModel(for: ml))
    }

    public func inverseDepth(for frame: CVPixelBuffer) throws -> Map {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cvPixelBuffer: frame, options: [:]).perform([request])
        if let obs = request.results?.first as? VNPixelBufferObservation {
            return try Self.map(from: obs.pixelBuffer)
        }
        if let obs = request.results?.first as? VNCoreMLFeatureValueObservation, let array = obs.featureValue.multiArrayValue {
            let shape = array.shape.map(\.intValue)
            let h = shape[shape.count - 2], w = shape[shape.count - 1]
            var values = [Float](repeating: 0, count: w * h)
            for i in 0..<(w * h) { values[i] = array[i].floatValue }
            return Map(width: w, height: h, values: values)
        }
        throw MotifError.analysis("depth model returned an unexpected output")
    }

    static func map(from buffer: CVPixelBuffer) throws -> Map {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw MotifError.analysis("depth buffer unreadable") }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        var values = [Float](repeating: 0, count: w * h)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent16Half:
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float16.self)
                for x in 0..<w { values[y * w + x] = Float(row[x]) }
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
                for x in 0..<w { values[y * w + x] = row[x] }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { values[y * w + x] = Float(row[x]) / 255 }
            }
        default:
            throw MotifError.analysis("unsupported depth pixel format \(CVPixelBufferGetPixelFormatType(buffer))")
        }
        return Map(width: w, height: h, values: values)
    }
}
