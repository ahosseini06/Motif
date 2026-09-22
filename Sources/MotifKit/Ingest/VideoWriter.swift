import Foundation
import AVFoundation
import CoreVideo

/// Minimal H.264 writer for BGRA pixel buffers with explicit presentation times.
public final class VideoWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var started = false
    private var lastTime = -1.0
    public private(set) var frameCount = 0

    public init(url: URL, width: Int, height: Int, bitrate: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw MotifError.analysis("cannot configure video writer") }
        writer.add(input)
    }

    public func append(_ buffer: CVPixelBuffer, time: Double) throws {
        guard time > lastTime else { return }
        let pts = CMTime(seconds: time, preferredTimescale: 600)
        if !started {
            guard writer.startWriting() else { throw writer.error ?? MotifError.analysis("writer failed to start") }
            writer.startSession(atSourceTime: pts)
            started = true
        }
        var waited = 0
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.002)
            waited += 1
            if waited > 5000 { throw MotifError.analysis("video writer stalled") }
        }
        guard adaptor.append(buffer, withPresentationTime: pts) else {
            throw writer.error ?? MotifError.analysis("frame append failed")
        }
        lastTime = time
        frameCount += 1
    }

    public func finish() async throws {
        guard started else { writer.cancelWriting(); return }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? MotifError.analysis("writer did not complete") }
    }
}
