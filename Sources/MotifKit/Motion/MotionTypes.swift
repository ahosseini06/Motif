import Foundation

/// Conventions and thresholds from docs/motion-spec.md. Bump `version` when any of them change.
public enum MotionSpec {
    /// 2: shake is a robust percentile that ignores clip edges, not an RMS (a knock no longer makes a locked-off shot handheld).
    public static let version = 2
    public static let sampleRate: Double = 8
    public static let defaultHorizontalFOVDegrees: Double = 50

    /// Rate above which a channel counts as active, in spec units.
    public static let activeThreshold: [Float] = [1.5, 1.5, 1.0, 0.02, 0.012, 0.012, 0.012]
    /// Upper bounds of the `slow` and `medium` speed bands, per channel.
    public static let slowBelow: [Float] = [6, 6, 4, 0.08, 0.04, 0.04, 0.04]
    public static let mediumBelow: [Float] = [20, 20, 12, 0.25, 0.12, 0.12, 0.12]

    /// A move must also cover this much in total (degrees, log-zoom, scene-depths) within its segment; less than that is
    /// operator wobble or a reframe, not a camera move worth a chip.
    public static let minSweep: [Float] = [3, 3, 2.5, 0.05, 0.03, 0.03, 0.03]

    public static let lockedOffShakeBelow: Float = 0.15
    public static let stabilisedShakeBelow: Float = 0.6
    /// Start and end of a clip ignored when judging stability: where the record button gets pressed.
    public static let edgeGuardSeconds: Double = 0.5
    public static let trendWindowSeconds: Double = 0.6
    public static let minSegmentSeconds: Double = 1.0
}

public enum MotionChannel: Int, CaseIterable, Codable, Sendable {
    case pan, tilt, roll, zoom, truck, pedestal, dolly

    public var name: String { String(describing: self) }
    public var isRotation: Bool { rawValue <= 2 }
    public var isTranslation: Bool { rawValue >= 4 }
    public var unit: String {
        switch self {
        case .pan, .tilt, .roll: return "°/s"
        case .zoom: return "ln/s"
        default: return "depths/s"
        }
    }
}

/// Motion between two consecutive analysis frames, in spec units.
public struct MotionSample: Sendable {
    public var time: Double
    public var rates: [Float]          // 7 channels
    public var confidence: Float       // inlier ratio of the accepted fit
    public var usedParallax: Bool

    public init(time: Double, rates: [Float], confidence: Float, usedParallax: Bool) {
        self.time = time; self.rates = rates; self.confidence = confidence; self.usedParallax = usedParallax
    }
}

public enum Stability: String, Codable, Sendable {
    case lockedOff = "locked_off", stabilised, handheld

    public var label: String {
        switch self {
        case .lockedOff: return "locked-off"
        case .stabilised: return "stabilised"
        case .handheld: return "handheld"
        }
    }
}

public enum TranslationSource: String, Codable, Sendable { case none, parallax }

public struct Chip: Codable, Hashable, Sendable {
    public var primitive: String       // pan, tilt, roll, zoom, truck, pedestal, dolly, static, arc, crane, dolly zoom
    public var direction: String?      // left/right/up/down/in/out/cw/ccw
    public var speed: String?          // slow/medium/fast

    public init(primitive: String, direction: String? = nil, speed: String? = nil) {
        self.primitive = primitive; self.direction = direction; self.speed = speed
    }

    /// Cinematographer's wording: "push-in", "pan right".
    public var title: String {
        switch (primitive, direction) {
        case ("dolly", "in"): return "push-in"
        case ("dolly", "out"): return "pull-out"
        case ("roll", "cw"): return "roll clockwise"
        case ("roll", "ccw"): return "roll counter-clockwise"
        default: return [primitive, direction].compactMap { $0 }.joined(separator: " ")
        }
    }

    public var display: String { speed.map { "\(title) · \($0)" } ?? title }
}

public struct MotionSegment: Sendable {
    public var start: Double
    public var end: Double
    public var summary: [Float]        // 8: channels + shake
    public var trajectory: [[Float]]   // T × 7, smoothed rates at sampleRate
    public var confidence: [Float]     // T
    public var stability: Stability
    public var translationSource: TranslationSource
    public var chips: [Chip]

    public var duration: Double { end - start }
}

public struct MotionAnalysis: Sendable {
    public var samples: [MotionSample]
    public var segments: [MotionSegment]
    public var focalPixels: Double
    public var focalFromMetadata: Bool
}

extension Array where Element == Float {
    public var floatData: Data { withUnsafeBufferPointer { Data(buffer: $0) } }

    public init(floatData: Data) {
        self = floatData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
