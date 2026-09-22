import Foundation
import GRDB

public struct EmbeddingRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "embedding"
    public var clipId: Int64
    public var kind: String            // "description" | "movement"
    public var model: String
    public var vector: Data            // Float32, unit length
}

public struct SearchHit: Sendable, Equatable {
    public var clipID: Int64
    public var score: Float
    /// Segment that best matched a movement query, for looping in the inspector.
    public var segmentRange: ClosedRange<Double>?
}

/// Everything search needs, in memory. Brute force: at 10,000 clips a query is still a few milliseconds.
public struct SearchIndex: Sendable {
    struct Entry: Sendable {
        var clipID: Int64
        var duration: Double
        var words: Set<String>                 // description + file name, for the lexical half
        var wordVectors: [[Float]] = []        // of the description's words, for soft word matching
        var description: [Float]?
        var movement: [Float]?
        var relation: String?
        var segments: [(range: ClosedRange<Double>, summary: [Float], stability: Stability)]
        var track: [[Float]] = []              // whole-clip trajectory at 8 Hz, channels in units of their `slow` band
    }

    var entries: [Entry] = []
    /// Mean description / movement vector of this project. Sentence embeddings share a large common component, which makes
    /// some sentences match everything; removing the project mean from both sides before comparing undoes that.
    var descriptionMean: [Float]?, movementMean: [Float]?
    public var count: Int { entries.count }

    public init() {}

    public init(project: Project) throws {
        entries = try project.db.read { db in
            var vectors: [Int64: [String: [Float]]] = [:]
            for e in try EmbeddingRecord.filter(Column("model") == TextEmbedder.modelName).fetchAll(db) {
                vectors[e.clipId, default: [:]][e.kind] = [Float](floatData: e.vector)
            }
            var segments: [Int64: [(ClosedRange<Double>, [Float], Stability)]] = [:]
            var tracks: [Int64: [[Float]]] = [:]
            for s in try SegmentRecord.order(Column("clipId"), Column("idx")).fetchAll(db) {
                tracks[s.clipId, default: []] += s.trajectoryRows.map(ShotQuery.normalised)
                segments[s.clipId, default: []].append((s.tStart...max(s.tStart, s.tEnd), s.summaryVector, s.stabilityValue))
            }
            return try Project.listRequest().fetchAll(db).compactMap { item in
                guard let id = item.clip.id else { return nil }
                let text = [item.tag?.description, item.tag?.shotSize, item.clip.relPath].compactMap { $0 }.joined(separator: " ")
                return Entry(clipID: id, duration: item.clip.duration, words: Self.words(in: text),
                             description: vectors[id]?["description"], movement: vectors[id]?["movement"],
                             relation: item.tag?.subjectRelation, segments: segments[id] ?? [], track: tracks[id] ?? [])
            }
        }
        for i in entries.indices { entries[i].wordVectors = entries[i].words.compactMap { TextEmbedder.shared.wordVector(for: $0) } }
        descriptionMean = Self.mean(entries.compactMap(\.description))
        movementMean = Self.mean(entries.compactMap(\.movement))
        for i in entries.indices {
            entries[i].description = entries[i].description.map { Self.centred($0, descriptionMean) }
            entries[i].movement = entries[i].movement.map { Self.centred($0, movementMean) }
        }
    }

    static func mean(_ vectors: [[Float]]) -> [Float]? {
        guard vectors.count >= 40, let first = vectors.first else { return nil }     // too few clips: the mean is mostly signal
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == sum.count { for i in v.indices { sum[i] += v[i] } }
        return sum.map { $0 / Float(vectors.count) }
    }

    static func centred(_ v: [Float], _ mean: [Float]?) -> [Float] {
        guard let mean, mean.count == v.count else { return v }
        var out = zip(v, mean).map { $0 - $1 }
        let norm = out.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if norm > 0 { for i in out.indices { out[i] /= norm } }
        return out
    }

    // MARK: search

    /// Ranked hits. Either query may be empty; with both, a clip has to satisfy both.
    public func search(description: String, movement: MovementQuery, shot: ShotQuery? = nil) -> [SearchHit] {
        let wantsDescription = !description.trimmingCharacters(in: .whitespaces).isEmpty
        let descriptionScores = wantsDescription ? scoreDescriptions(description) : [:]
        var hits: [SearchHit] = []
        for entry in entries {
            var score: Float = 1, range: ClosedRange<Double>?
            if wantsDescription {
                guard let s = descriptionScores[entry.clipID], s >= 0.38 else { continue }
                score *= s
            }
            if !movement.isEmpty {
                let (s, r) = scoreMovement(entry, movement)
                guard s >= 0.3 else { continue }
                score = wantsDescription ? (score * s).squareRoot() : s
                range = r
            }
            if let shot {
                let (s, r) = shot.bestMatch(in: entry.track)
                guard s >= 0.45 else { continue }
                score = (wantsDescription || !movement.isEmpty) ? (score * s).squareRoot() : s
                range = r ?? range
            }
            hits.append(SearchHit(clipID: entry.clipID, score: score, segmentRange: range))
        }
        return hits.sorted { $0.score > $1.score }
    }

    // MARK: description — semantic + lexical

    private func scoreDescriptions(_ text: String) -> [Int64: Float] {
        let queryWords = Self.words(in: text)
        var queryWordVectors: [String: [Float]] = [:]
        for w in queryWords { queryWordVectors[w] = TextEmbedder.shared.wordVector(for: w) }
        let queryVector = TextEmbedder.shared.vector(for: text).map { Self.centred($0, descriptionMean) }

        // Sentence-embedding cosines sit in a narrow, corpus-dependent band, so they are rescaled against this project:
        // 0 at the project's mean similarity, 1 at its best match.
        var cosines: [Int64: Float] = [:]
        if let queryVector {
            for e in entries { if let v = e.description { cosines[e.clipID] = dot(queryVector, v) } }
        }
        let mean = cosines.isEmpty ? 0 : cosines.values.reduce(0, +) / Float(cosines.count)
        let best = cosines.values.max() ?? 0
        let spread = max(best - mean, 0.05)

        var scores: [Int64: Float] = [:]
        for e in entries {
            let semantic = cosines[e.clipID].map { max(0, min(1, ($0 - mean) / spread)) } ?? 0
            let lexical = queryWords.isEmpty ? 0 : Float(queryWords.filter { q in e.words.contains { Self.sameStem($0, q) } }.count) / Float(queryWords.count)
            // Soft word matching: each query word against its closest word in the description, so "dog" finds "retriever"
            // and "winter" finds "snow". Steadier than the sentence vector for short queries against literal descriptions.
            var soft: Float = 0
            if !queryWords.isEmpty, e.description != nil {
                for q in queryWords {
                    if e.words.contains(where: { Self.sameStem($0, q) }) { soft += 1; continue }
                    guard let qv = queryWordVectors[q] else { continue }
                    let best = e.wordVectors.reduce(Float(0)) { max($0, dot(qv, $1)) }
                    soft += max(0, min(1, (best - 0.3) / 0.4))
                }
                soft /= Float(queryWords.count)
            }
            // Every query word present is a strong answer on its own; otherwise meaning leads and exact words assist.
            scores[e.clipID] = max(lexical >= 1 ? 0.85 + 0.15 * semantic : 0, 0.55 * soft + 0.30 * semantic + 0.15 * lexical)
        }
        return scores
    }

    static let ignoredWords: Set<String> = ["a", "an", "the", "of", "in", "on", "at", "with", "and", "or", "to", "is", "are", "shot", "clip", "footage", "some", "someone", "something"]

    static func words(in text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 && !ignoredWords.contains($0) })
    }

    /// Cheap stemming: "running" finds "runs", "dogs" finds "dog".
    static func sameStem(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let n = min(a.count, b.count)
        guard n >= 3 else { return false }
        let shared = zip(a, b).prefix { $0 == $1 }.count
        return shared >= max(3, n - 1) && max(a.count, b.count) - shared <= 4
    }

    // MARK: movement — motion vectors first, words second

    private func scoreMovement(_ entry: Entry, _ query: MovementQuery) -> (Float, ClosedRange<Double>?) {
        var structured: Float = 0, range: ClosedRange<Double>?
        if query.isStructured {
            for segment in entry.segments {
                var s = Self.score(summary: segment.summary, stability: segment.stability, query: query)
                // A move that fills the clip beats the same move in passing.
                let share = entry.duration > 0 ? Float((segment.range.upperBound - segment.range.lowerBound) / entry.duration) : 1
                s *= 0.7 + 0.3 * min(1, share)
                if s > structured { structured = s; range = segment.range }
            }
            if !query.relations.isEmpty {
                let matches = entry.relation.map(query.relations.contains) ?? false
                let onlyRelations = query.moves.isEmpty && !query.wantsStatic && query.stability == nil && query.speed == nil
                structured = onlyRelations ? (matches ? 1 : 0) : structured * (matches ? 1 : 0.55)
            }
        }
        var semantic: Float = 0
        if !query.freeText.isEmpty, let raw = TextEmbedder.shared.vector(for: query.freeText), let v = entry.movement {
            let q = Self.centred(raw, movementMean)
            semantic = max(0, min(1, (dot(q, v) - (movementMean == nil ? 0.35 : 0.1)) / 0.4))
        }
        if query.isStructured && !query.freeText.isEmpty { return (0.8 * structured + 0.2 * semantic, range) }
        return (query.isStructured ? structured : semantic, range)
    }

    /// How well one segment's measured motion answers the structured part of a query, 0…1.
    public static func score(summary: [Float], stability: Stability, query: MovementQuery) -> Float {
        // Channels in units of their own `slow` band so degrees, log-zoom and scene-depths compare.
        let s = (0..<7).map { summary[$0] / MotionSpec.slowBelow[$0] }
        let magnitude = s.reduce(0) { $0 + $1 * $1 }.squareRoot()
        let activeLevel: Float = 0.25                // ≈ activeThreshold / slowBelow for every channel

        var score: Float = 1
        if !query.moves.isEmpty {
            var q = [Float](repeating: 0, count: 7)
            func want(_ channel: MotionChannel, _ sign: Float?) {
                let c = channel.rawValue
                q[c] += sign ?? (s[c] >= 0 ? 1 : -1)             // undirected: whichever way this segment went
            }
            for move in query.moves {
                switch (move.primitive, move.direction) {
                case ("pan", let d): want(.pan, d.map { $0 == "right" ? 1 : -1 })
                case ("tilt", let d): want(.tilt, d.map { $0 == "up" ? 1 : -1 })
                case ("roll", let d): want(.roll, d.map { $0 == "cw" ? 1 : -1 })
                case ("zoom", let d): want(.zoom, d.map { $0 == "in" ? 1 : -1 })
                case ("dolly", let d): want(.dolly, d.map { $0 == "in" ? 1 : -1 })
                case ("truck", let d): want(.truck, d.map { $0 == "right" ? 1 : -1 })
                case ("pedestal", let d): want(.pedestal, d.map { $0 == "up" ? 1 : -1 })
                case ("arc", let d):                                  // arc right = truck right with opposing pan
                    let sign: Float = d.map { $0 == "right" ? 1 : -1 } ?? (s[MotionChannel.truck.rawValue] >= 0 ? 1 : -1)
                    want(.truck, sign); want(.pan, -sign)
                default: break
                }
            }
            let qNorm = q.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard qNorm > 0, magnitude > 0 else { return 0 }
            var projection: Float = 0
            for c in 0..<7 { projection += s[c] * q[c] }
            projection /= qNorm
            let purity = max(0, projection / magnitude)                          // cosine: other motion dilutes the match
            // Each wanted channel must actually be moving, or "pan + push-in" would be satisfied by a pan alone.
            var weakest = Float.greatestFiniteMagnitude
            for c in 0..<7 where q[c] != 0 { weakest = min(weakest, q[c] > 0 ? s[c] : -s[c]) }
            score = pow(purity, 0.75) * min(1, max(0, weakest) / activeLevel)
        } else if query.wantsStatic {
            score = max(0, 1 - magnitude / (2 * activeLevel))
        }
        if query.wantsStatic && !query.moves.isEmpty { score = 0 }

        // On its own, stability is a filter; alongside a move it's a preference.
        if let wanted = query.stability, wanted != stability { score *= (query.moves.isEmpty && !query.wantsStatic) ? 0 : 0.35 }
        if let wanted = query.speed {
            let bands = ["slow", "medium", "fast"]
            // Speed of the fastest wanted channel, or of the fastest channel at all.
            let channels = query.moves.isEmpty ? Array(0..<7) : query.moves.flatMap { Self.channels(of: $0.primitive) }
            let c = channels.max { abs(s[$0]) < abs(s[$1]) } ?? 0
            let v = abs(summary[c])
            let band = v < MotionSpec.slowBelow[c] ? 0 : v < MotionSpec.mediumBelow[c] ? 1 : 2
            let distance = abs(band - (bands.firstIndex(of: wanted) ?? 0))
            if query.moves.isEmpty && !query.wantsStatic && magnitude < activeLevel { score = 0 }     // "fast" needs a move
            score *= distance == 0 ? 1 : distance == 1 ? 0.55 : 0.25
        }
        return score
    }

    static func channels(of primitive: String) -> [Int] {
        switch primitive {
        case "arc": return [MotionChannel.truck.rawValue, MotionChannel.pan.rawValue]
        default: return MotionChannel.allCases.filter { $0.name == primitive }.map(\.rawValue)
        }
    }
}

/// A designed shot as a search query: its trajectory, compared against windows of every clip's trajectory.
public struct ShotQuery: Sendable, Equatable {
    static let steps = 16
    /// Window lengths tried, relative to the shot's own duration: the same move a little faster or slower still counts.
    static let scales: [Double] = [0.5, 0.75, 1, 1.5, 2]

    public let duration: Double
    let sequence: [Float]              // steps × 7, normalised
    let energy: Float                  // RMS of the sequence; ≈ 0 for a locked-off shot

    public init(samples: [MotionSample], duration: Double) {
        self.duration = duration
        sequence = Self.resample(samples.map { Self.normalised($0.rates) }, from: 0, to: samples.count)
        energy = Self.rms(sequence)
    }

    /// Channels in units of their own `slow` band so degrees, log-zoom and scene-depths compare; clamped so one whip pan
    /// can't drown everything else.
    static func normalised(_ rates: [Float]) -> [Float] {
        (0..<7).map { max(-4, min(4, rates[$0] / MotionSpec.slowBelow[$0])) }
    }

    static func rms(_ v: [Float]) -> Float { v.isEmpty ? 0 : (v.reduce(0) { $0 + $1 * $1 } / Float(v.count)).squareRoot() }

    /// Average rows [from, to) down to `steps` rows, flattened.
    static func resample(_ rows: [[Float]], from: Int, to: Int) -> [Float] {
        var out = [Float](repeating: 0, count: steps * 7)
        let n = to - from
        guard n > 0 else { return out }
        for step in 0..<steps {
            let lo = from + step * n / steps, hi = max(lo + 1, from + (step + 1) * n / steps)
            for i in lo..<min(hi, to) { for c in 0..<7 { out[step * 7 + c] += rows[i][c] / Float(min(hi, to) - lo) } }
        }
        return out
    }

    /// Best-matching window of a clip's track: similarity 0…1 and where it is.
    func bestMatch(in track: [[Float]]) -> (Float, ClosedRange<Double>?) {
        guard track.count >= 4 else { return (0, nil) }
        let rate = MotionSpec.sampleRate
        var best: Float = 0, bestRange: ClosedRange<Double>?
        var lengths = Set(Self.scales.map { max(8, Int(($0 * duration * rate).rounded())) }.filter { $0 <= track.count })
        lengths.insert(track.count)                                   // the clip as a whole is always a candidate
        for length in lengths.sorted() {
            let stride = max(2, length / 8)
            var start = 0
            while start + length <= track.count {
                let window = Self.resample(track, from: start, to: start + length)
                var s = similarity(to: window)
                // Mild preference for the speed the shot was drawn at.
                let scale = Double(length) / max(1, duration * rate)
                s *= Float(1 - 0.12 * min(2, abs(log2(scale))))
                if s > best { best = s; bestRange = (Double(start) / rate)...(Double(start + length) / rate) }
                start += stride
            }
        }
        return (best, bestRange)
    }

    func similarity(to window: [Float]) -> Float {
        let windowEnergy = Self.rms(window)
        if energy < 0.12 { return max(0, 1 - windowEnergy / 0.3) }               // a locked-off shot matches stillness
        guard windowEnergy > 0 else { return 0 }
        var d: Float = 0
        for i in sequence.indices { d += sequence[i] * window[i] }
        let cosine = d / (Float(sequence.count) * energy * windowEnergy)            // shape and direction, over time
        let magnitude = min(energy, windowEnergy) / max(energy, windowEnergy)       // and how big the move is
        return max(0, cosine) * (0.55 + 0.45 * magnitude) * min(1, windowEnergy / 0.2)
    }
}

extension Project {
    /// Embeds any description / movement sentence that doesn't have a current vector yet. Cheap and idempotent.
    public func embedMissingText() throws {
        guard TextEmbedder.shared.isAvailable else { return }
        let pending = try db.read { db in
            try TagRecord.fetchAll(db, sql: """
                SELECT tag.* FROM tag WHERE model != 'fake' AND
                  (SELECT COUNT(*) FROM embedding e WHERE e.clipId = tag.clipId AND e.model = ?) < 2
                """, arguments: [TextEmbedder.modelName])
        }
        guard !pending.isEmpty else { return }
        var records: [EmbeddingRecord] = []
        for tag in pending {
            for (kind, text) in [("description", tag.description), ("movement", tag.movementText)] {
                if let v = TextEmbedder.shared.vector(for: text) {
                    records.append(EmbeddingRecord(clipId: tag.clipId, kind: kind, model: TextEmbedder.modelName, vector: v.floatData))
                }
            }
        }
        try db.write { db in for r in records { try r.save(db) } }
    }
}
