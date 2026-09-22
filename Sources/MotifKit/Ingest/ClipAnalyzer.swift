import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public struct SpriteLayout: Codable, Sendable, Equatable {
    public var tiles: Int, columns: Int, tileWidth: Int, tileHeight: Int
    public var rows: Int { (tiles + columns - 1) / columns }
}

public struct AnalysisResult: Sendable {
    public var metadata: ClipMetadata
    public var motion: MotionAnalysis
    public var sprite: SpriteLayout?
    public var proxyFPS: Double?
    public var proxyNormalised = false
    public var decodeSeconds: Double = 0
    public var framesDecoded = 0
}

/// One decode pass per clip: motion analysis, poster, hover filmstrip, and the low-rate proxy for the description model.
public final class ClipAnalyzer {
    public struct Outputs {
        public var poster: URL, sprite: URL, proxy: URL
        public init(poster: URL, sprite: URL, proxy: URL) { self.poster = poster; self.sprite = sprite; self.proxy = proxy }
    }

    public static let spriteTiles = 48, spriteColumns = 8, spriteTileWidth = 240
    public static let maxProxyFrames = 64.0

    private let depth: DepthEstimator?
    private let ci = CIContext(options: [.cacheIntermediates: false])

    public init(depth: DepthEstimator?) { self.depth = depth }

    /// Proxy frame rate: ~24 frames for any clip, so short clips aren't starved and long ones aren't expensive.
    public static func proxyFPS(duration: Double) -> Double {
        let fps = min(4, max(0.25, 24 / max(duration, 0.1)))
        return min(fps, maxProxyFrames / max(duration, 0.1))
    }

    public func analyze(url: URL, outputs: Outputs? = nil) async throws -> AnalysisResult {
        let reader = FrameReader(url: url)
        try await reader.prepare()
        let meta = reader.metadata
        let size = reader.outputSize
        let width = Int(size.width), height = Int(size.height)
        let focal = meta.focalPixels(analysisWidth: width)
        let tracker = MotionTracker(focalPixels: focal.value, depth: depth)

        let motionStep = 1 / MotionSpec.sampleRate
        var nextMotion = 0.0

        var proxyWriter: VideoWriter?, proxyStep = 0.0, nextProxy = 0.0
        var normaliser: CIFilter?, normaliseDecided = false, proxyPool: CVPixelBufferPool?
        var spriteContext: CGContext?, layout: SpriteLayout?, nextTile = 0
        var posterWritten = false
        if let outputs {
            proxyStep = 1 / Self.proxyFPS(duration: meta.duration)
            proxyWriter = try VideoWriter(url: outputs.proxy, width: width, height: height, bitrate: 700_000)
            let tileHeight = max(2, Int((Double(Self.spriteTileWidth) * Double(height) / Double(width)).rounded()))
            let l = SpriteLayout(tiles: Self.spriteTiles, columns: Self.spriteColumns, tileWidth: Self.spriteTileWidth, tileHeight: tileHeight)
            layout = l
            spriteContext = CGContext(data: nil, width: l.columns * l.tileWidth, height: l.rows * l.tileHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        }

        let started = Date()
        var frames = 0
        try reader.readFrames { buffer, time in
            frames += 1
            if time >= nextMotion - 1e-4 {
                try tracker.push(buffer, time: time)
                nextMotion = max(nextMotion + motionStep, time + motionStep * 0.5)
            }
            guard let outputs, let layout, let spriteContext else { return true }

            if !posterWritten, time >= meta.duration * 0.1 {
                try writeImage(CIImage(cvPixelBuffer: buffer), to: outputs.poster, quality: 0.75)
                posterWritten = true
            }
            while nextTile < layout.tiles, time >= meta.duration * Double(nextTile) / Double(layout.tiles) - 1e-4 {
                if let cg = ci.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: width, height: height)) {
                    let col = nextTile % layout.columns, row = nextTile / layout.columns
                    // CoreGraphics origin is bottom-left; tile 0 belongs top-left.
                    let y = (layout.rows - 1 - row) * layout.tileHeight
                    spriteContext.draw(cg, in: CGRect(x: col * layout.tileWidth, y: y, width: layout.tileWidth, height: layout.tileHeight))
                }
                nextTile += 1
            }
            if time >= nextProxy - 1e-4 {
                if !normaliseDecided {
                    switch Self.flatFootageDecision(for: buffer) {
                    case .undecided: break
                    case .normal: normaliseDecided = true
                    case .flat(let filter): normaliseDecided = true; normaliser = filter
                    }
                }
                if let normaliser {
                    normaliser.setValue(CIImage(cvPixelBuffer: buffer), forKey: kCIInputImageKey)
                    let out = try Self.pooledBuffer(&proxyPool, width: width, height: height)
                    ci.render(normaliser.outputImage!, to: out)
                    try proxyWriter?.append(out, time: time)
                } else {
                    try proxyWriter?.append(buffer, time: time)
                }
                nextProxy = max(nextProxy + proxyStep, time + proxyStep * 0.5)
            }
            return true
        }
        let decodeSeconds = Date().timeIntervalSince(started)

        if let outputs, let spriteContext, let layout {
            try await proxyWriter?.finish()
            if !posterWritten { throw MotifError.unsupported("no decodable frames") }
            if let image = spriteContext.makeImage() { try writeImage(CIImage(cgImage: image), to: outputs.sprite, quality: 0.55) }
            _ = layout
        }
        guard frames > 0 else { throw MotifError.unsupported("no decodable frames") }

        let segments = Segmenter.segments(from: tracker.samples, clipDuration: meta.duration)
        let motion = MotionAnalysis(samples: tracker.samples, segments: segments,
                                    focalPixels: focal.value, focalFromMetadata: focal.fromMetadata)
        return AnalysisResult(metadata: meta, motion: motion, sprite: layout,
                              proxyFPS: outputs == nil ? nil : 1 / proxyStep, proxyNormalised: normaliser != nil,
                              decodeSeconds: decodeSeconds, framesDecoded: frames)
    }

    private func writeImage(_ image: CIImage, to url: URL, quality: Double) throws {
        guard let cg = ci.createCGImage(image, from: image.extent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw MotifError.analysis("cannot write \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw MotifError.analysis("cannot write \(url.lastPathComponent)") }
    }

    static func pooledBuffer(_ pool: inout CVPixelBufferPool?, width: Int, height: Int) throws -> CVPixelBuffer {
        if pool == nil {
            let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &out)
        guard let out else { throw MotifError.analysis("pixel buffer allocation failed") }
        return out
    }

    /// Log footage is rarely flagged in metadata. If a frame is lifted and low-contrast, the proxy (only the proxy —
    /// thumbnails stay faithful to the file) is stretched to a normal range so the description model sees a viewable image.
    /// `.undecided` while frames are too dark to judge (slates, fades).
    enum FlatDecision { case undecided, normal, flat(CIFilter) }

    static func flatFootageDecision(for buffer: CVPixelBuffer) -> FlatDecision {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return .normal }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        var histogram = [Int](repeating: 0, count: 256), count = 0, sum = 0
        for y in Swift.stride(from: 0, to: h, by: 6) {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in Swift.stride(from: 0, to: w, by: 6) {
                let p = row.advanced(by: x * 4)
                let luma = (Int(p[0]) * 29 + Int(p[1]) * 150 + Int(p[2]) * 77) >> 8
                histogram[luma] += 1; count += 1; sum += luma
            }
        }
        guard count > 0, Double(sum) / Double(count) > 16 else { return .undecided }
        func percentile(_ q: Double) -> Double {
            var acc = 0
            for (i, n) in histogram.enumerated() { acc += n; if Double(acc) >= q * Double(count) { return Double(i) / 255 } }
            return 1
        }
        let lo = percentile(0.01), hi = percentile(0.99)
        guard lo > 0.07, hi < 0.90, hi - lo < 0.6, hi - lo > 0.05 else { return .normal }
        let gain = 0.94 / (hi - lo), bias = 0.03 - lo * gain
        let matrix = CIFilter(name: "CIColorMatrix")!
        matrix.setValue(CIVector(x: gain, y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrix.setValue(CIVector(x: 0, y: gain, z: 0, w: 0), forKey: "inputGVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: gain, w: 0), forKey: "inputBVector")
        matrix.setValue(CIVector(x: bias, y: bias, z: bias, w: 0), forKey: "inputBiasVector")
        return .flat(matrix)
    }
}
