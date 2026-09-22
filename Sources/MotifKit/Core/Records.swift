import Foundation
import GRDB

public enum StageState: String, Codable, Sendable {
    case pending, running, done, failed
    case unsupported        // analysis: not a decodable video
    case blocked            // describe: refused by the model's safety filter
    case skipped            // describe: project is never-upload
}

public struct ClipRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "clip"

    public var id: Int64?
    public var relPath: String
    public var fingerprint: String
    public var size: Int64
    public var mtime: Double
    public var addedAt: Date = Date()
    public var missing = false

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

    public var analysisState: StageState = .pending
    public var describeState: StageState = .pending
    public var error: String?

    public var chipsJSON: String?           // clip-level chips for the grid
    public var stability: String?
    public var spriteJSON: String?
    public var proxyFPS: Double?
    public var motionHint: String?

    public init(relPath: String, fingerprint: String, size: Int64, mtime: Double) {
        self.relPath = relPath; self.fingerprint = fingerprint; self.size = size; self.mtime = mtime
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var name: String { (relPath as NSString).lastPathComponent }
    public var chips: [Chip] { decode(chipsJSON) ?? [] }
    public var sprite: SpriteLayout? { decode(spriteJSON) }

    private func decode<T: Decodable>(_ json: String?) -> T? {
        json.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

public struct SegmentRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "segment"

    public var id: Int64?
    public var clipId: Int64
    public var idx: Int
    public var tStart: Double
    public var tEnd: Double
    public var summary: Data            // Float32[8]
    public var trajectory: Data         // Float32[T × 7] at MotionSpec.sampleRate
    public var confidence: Data         // Float32[T]
    public var translationSource: String
    public var stability: String
    public var chipsJSON: String

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public init(clipId: Int64, idx: Int, segment: MotionSegment) {
        self.clipId = clipId; self.idx = idx
        tStart = segment.start; tEnd = segment.end
        summary = segment.summary.floatData
        trajectory = segment.trajectory.flatMap { $0 }.floatData
        confidence = segment.confidence.floatData
        translationSource = segment.translationSource.rawValue
        stability = segment.stability.rawValue
        chipsJSON = String(data: (try? JSONEncoder().encode(segment.chips)) ?? Data("[]".utf8), encoding: .utf8)!
    }

    public var summaryVector: [Float] { [Float](floatData: summary) }
    public var chips: [Chip] { (try? JSONDecoder().decode([Chip].self, from: Data(chipsJSON.utf8))) ?? [] }
    public var stabilityValue: Stability { Stability(rawValue: stability) ?? .lockedOff }

    /// Rows of 7 channel rates.
    public var trajectoryRows: [[Float]] {
        let flat = [Float](floatData: trajectory)
        return stride(from: 0, to: flat.count - 6, by: 7).map { Array(flat[$0..<($0 + 7)]) }
    }
}

public struct TagRecord: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "tag"

    public var clipId: Int64
    public var description: String
    public var movementText: String
    public var shotSize: String?
    public var subjectRelation: String?
    public var model: String
    public var promptVersion: Int
    public var tokensIn: Int
    public var tokensOut: Int
    public var createdAt: Date = Date()
}

/// Everything a grid cell needs, in one fetch.
public struct ClipListItem: Decodable, FetchableRecord, Identifiable, Hashable, Sendable {
    public var clip: ClipRecord
    public var tag: TagRecord?
    public var id: Int64 { clip.id ?? -1 }
}
