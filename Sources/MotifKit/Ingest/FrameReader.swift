import Foundation
import AVFoundation
import CoreImage

public enum MotifError: Error, LocalizedError {
    /// `auth` is a key-level problem — a wrong key, a model the key can't reach, an exhausted quota. It is not the
    /// clip's fault, so the pipeline stops the description stage instead of marking every clip failed in turn.
    case unsupported(String), analysis(String), tagging(String), blocked(String), auth(String), project(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let m), .analysis(let m), .tagging(let m), .blocked(let m), .auth(let m), .project(let m): return m
        }
    }
}

public struct ClipMetadata: Sendable {
    public var duration: Double = 0
    public var fps: Double = 0
    public var width: Int = 0
    public var height: Int = 0
    public var codec: String = ""
    public var transferFunction: String?
    public var rotation: Int = 0
    public var hasAudio = false
    public var capturedAt: Date?
    public var cameraMake: String?
    public var cameraModel: String?
    public var focal35mm: Double?

    /// Focal length in pixels for an analysis frame of the given width.
    public func focalPixels(analysisWidth: Int) -> (value: Double, fromMetadata: Bool) {
        if let f35 = focal35mm, f35 > 4 { return (f35 / 36.0 * Double(analysisWidth), true) }
        let half = MotionSpec.defaultHorizontalFOVDegrees / 2 * .pi / 180
        return (Double(analysisWidth) / 2 / tan(half), false)
    }
}

/// Sequential hardware-decoded, downscaled, uprighted BGRA frames from a video file.
public final class FrameReader {
    public let asset: AVURLAsset
    public private(set) var metadata = ClipMetadata()
    public private(set) var outputSize: CGSize = .zero

    private var track: AVAssetTrack!
    private var orientation: CGImagePropertyOrientation = .up
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])
    private var rotatedPool: CVPixelBufferPool?

    public init(url: URL) { asset = AVURLAsset(url: url) }

    public func prepare(maxDimension: Int = 640) async throws {
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw MotifError.unsupported("no video track")
        }
        track = video
        let (natural, transform, rate, formats) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
        let duration = try await asset.load(.duration)
        metadata.duration = duration.seconds.isFinite ? duration.seconds : 0
        metadata.fps = Double(rate)
        metadata.hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty

        let angle = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded())
        metadata.rotation = (angle + 360) % 360
        switch metadata.rotation {
        case 90: orientation = .right
        case 180: orientation = .down
        case 270: orientation = .left
        default: orientation = .up
        }
        let upright = (metadata.rotation == 90 || metadata.rotation == 270) ? CGSize(width: natural.height, height: natural.width) : natural
        metadata.width = Int(upright.width); metadata.height = Int(upright.height)

        if let format = formats.first {
            metadata.codec = fourCC(CMFormatDescriptionGetMediaSubType(format))
            if let tf = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
                metadata.transferFunction = tf
            }
        }
        await loadCameraMetadata()

        let scale = min(1, Double(maxDimension) / Double(max(natural.width, natural.height)))
        let w = max(16, Int(natural.width * scale) / 2 * 2), h = max(16, Int(natural.height * scale) / 2 * 2)
        decodeSize = CGSize(width: w, height: h)
        outputSize = orientation == .up || orientation == .down ? decodeSize : CGSize(width: h, height: w)
        guard metadata.duration > 0, w > 0, h > 0 else { throw MotifError.unsupported("empty video track") }
    }

    private var decodeSize: CGSize = .zero

    /// Calls `body` with every decoded frame in presentation order. Return `false` to stop early.
    public func readFrames(_ body: (CVPixelBuffer, Double) throws -> Bool) throws {
        var lastError: Error?
        for includeColour in [true, false] {
            let reader = try AVAssetReader(asset: asset)
            var settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(decodeSize.width),
                kCVPixelBufferHeightKey as String: Int(decodeSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            if includeColour {
                // Ask for Rec.709 so HLG / PQ sources arrive tone-mapped to something viewable.
                settings[AVVideoColorPropertiesKey] = [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ]
            }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { lastError = MotifError.unsupported("cannot decode this track"); continue }
            reader.add(output)
            guard reader.startReading() else { lastError = reader.error; continue }

            var delivered = 0
            while let sample = output.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard time.isFinite else { continue }
                delivered += 1
                let keepGoing = try autoreleasepool { try body(try upright(buffer), max(0, time)) }
                if !keepGoing { reader.cancelReading(); return }
            }
            // A decode error part-way through still leaves usable frames; only a total failure is fatal.
            if reader.status == .failed && delivered == 0 { lastError = reader.error; continue }
            return
        }
        throw MotifError.unsupported(lastError?.localizedDescription ?? "decode failed")
    }

    private func upright(_ buffer: CVPixelBuffer) throws -> CVPixelBuffer {
        guard orientation != .up else { return buffer }
        if rotatedPool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &rotatedPool)
        }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, rotatedPool!, &out)
        guard let out else { throw MotifError.analysis("pixel buffer allocation failed") }
        let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        ciContext.render(image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY)), to: out)
        return out
    }

    private func loadCameraMetadata() async {
        metadata.capturedAt = try? await asset.load(.creationDate)?.load(.dateValue)
        guard let items = try? await asset.load(.metadata) else { return }
        for item in items {
            guard let key = item.identifier?.rawValue ?? (item.key as? String) else { continue }
            let lower = key.lowercased()
            if lower.hasSuffix("make"), metadata.cameraMake == nil { metadata.cameraMake = try? await item.load(.stringValue) }
            else if lower.hasSuffix("model"), metadata.cameraModel == nil { metadata.cameraModel = try? await item.load(.stringValue) }
            else if lower.contains("focal_length.35mm") || lower.contains("focallengthin35mm") {
                metadata.focal35mm = try? await item.load(.numberValue)?.doubleValue
            }
        }
    }

    private func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(code)"
    }
}
