import Foundation

public struct TagRequest: Sendable {
    public var proxy: URL
    public var proxyFPS: Double
    public var duration: Double
    public var motionHint: String

    public init(proxy: URL, proxyFPS: Double, duration: Double, motionHint: String) {
        self.proxy = proxy; self.proxyFPS = proxyFPS; self.duration = duration; self.motionHint = motionHint
    }
}

public struct TagResult: Codable, Sendable {
    public var description: String
    public var movementText: String
    public var shotSize: String?
    public var subjectRelation: String?
    public var model: String = ""
    public var tokensIn = 0
    public var tokensOut = 0

    enum CodingKeys: String, CodingKey {
        case description, movementText = "movement_text", shotSize = "shot_size", subjectRelation = "subject_relation"
    }
}

/// The description stage sits behind this so the pipeline can run against a fake, and later a local model.
public protocol Tagger: Sendable {
    func describe(_ request: TagRequest) async throws -> TagResult
}

public enum TagPrompt {
    /// Bump when the wording changes; stored per tag so clips can be selectively re-described.
    public static let version = 1

    public static let system = """
    You log footage for a film editor. You are given one clip as a low-frame-rate proxy (no audio), plus camera-motion \
    measurements computed from the full-rate original by a geometric solver.

    Treat the measurements as ground truth for what the CAMERA does: direction, type of move and speed. Do not contradict \
    them from what you see — the proxy's frame rate is too low to judge camera motion, and subject motion is easily \
    mistaken for it. Your job for movement is phrasing, and judging how the move relates to the subject.

    description: at most 40 words. Concrete and literal: who or what is in shot, what they do, where, the light and time of \
    day if evident. Name specific things an editor would search for. No "cinematic", no "a shot of", no mood adjectives, \
    no guessing at story.

    movement_text: at most 25 words, the way a cinematographer would say it, e.g. "Slow push-in on the driver as he turns, \
    handheld." If the measurements say static, say so plainly (locked-off, or handheld static).

    subject_relation: none · tracking (camera travels with a moving subject) · following (behind it) · leading (ahead of it) · \
    orbit (arcs around it) · reveal (the move uncovers the subject) · reframing (small corrective move to keep the subject framed).

    shot_size: judged on the main subject at the clip's midpoint.
    """

    public static func user(for request: TagRequest) -> String {
        """
        Clip length: \(String(format: "%.1f", request.duration)) s.
        Measured camera motion (segment times in seconds):
        \(request.motionHint.isEmpty ? "static" : request.motionHint)
        """
    }

    public static let schema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "description": ["type": "STRING"],
            "movement_text": ["type": "STRING"],
            "subject_relation": ["type": "STRING", "enum": ["none", "tracking", "following", "leading", "orbit", "reveal", "reframing"]],
            "shot_size": ["type": "STRING", "enum": ["ECU", "CU", "MCU", "MS", "MLS", "LS", "ELS", "insert", "aerial"]],
        ],
        "required": ["description", "movement_text", "subject_relation", "shot_size"],
        "propertyOrdering": ["description", "movement_text", "subject_relation", "shot_size"],
    ]
}
