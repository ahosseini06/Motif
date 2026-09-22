import Foundation

/// Turns raw per-pair samples into segments, summary vectors and chips (docs/motion-spec.md).
public enum Segmenter {
    public static func segments(from samples: [MotionSample], clipDuration: Double) -> [MotionSegment] {
        guard !samples.isEmpty else { return [] }
        let raw = repaired(samples)
        let trend = smoothed(raw, window: MotionSpec.trendWindowSeconds)

        // Per-sample signature of active channels, with hysteresis so a rate hovering at the threshold doesn't flicker.
        var active = [Int](repeating: 0, count: 7)      // -1, 0, +1
        var signatures: [[Int]] = []
        for row in trend {
            for c in 0..<7 {
                let on = MotionSpec.activeThreshold[c], off = on * 0.6
                let v = row[c]
                if active[c] == 0 { if abs(v) > on { active[c] = v > 0 ? 1 : -1 } }
                else if abs(v) < off || (v > 0) != (active[c] > 0) { active[c] = abs(v) > on ? (v > 0 ? 1 : -1) : 0 }
            }
            signatures.append(active)
        }

        // Run-length encode, then fold runs shorter than the minimum into their longer neighbour.
        var runs: [(start: Int, end: Int, sig: [Int])] = []
        for (i, sig) in signatures.enumerated() {
            if let last = runs.last, last.sig == sig { runs[runs.count - 1].end = i + 1 }
            else { runs.append((i, i + 1, sig)) }
        }
        func mergeEqualNeighbours() {
            var i = 1
            while i < runs.count {
                if runs[i].sig == runs[i - 1].sig { runs[i - 1].end = runs[i].end; runs.remove(at: i) } else { i += 1 }
            }
        }
        // Drop channels that were active but swept too little to be a move (wobble, a small reframe).
        func pruneBySweep() {
            for r in runs.indices {
                let n = Float(runs[r].end - runs[r].start), seconds = n / Float(MotionSpec.sampleRate)
                for c in 0..<7 where runs[r].sig[c] != 0 {
                    let mean = (runs[r].start..<runs[r].end).reduce(Float(0)) { $0 + trend[$1][c] } / n
                    if abs(mean) * seconds < MotionSpec.minSweep[c] { runs[r].sig[c] = 0 }
                }
            }
            mergeEqualNeighbours()
        }
        pruneBySweep()
        let minSamples = max(1, Int(MotionSpec.minSegmentSeconds * MotionSpec.sampleRate))
        while runs.count > 1, let shortest = runs.indices.min(by: { runs[$0].end - runs[$0].start < runs[$1].end - runs[$1].start }),
              runs[shortest].end - runs[shortest].start < minSamples {
            let left = shortest > 0 ? shortest - 1 : nil, right = shortest < runs.count - 1 ? shortest + 1 : nil
            let into: Int
            if let l = left, let r = right { into = (runs[l].end - runs[l].start) >= (runs[r].end - runs[r].start) ? l : r }
            else { into = left ?? right! }
            runs[into].start = min(runs[into].start, runs[shortest].start)
            runs[into].end = max(runs[into].end, runs[shortest].end)
            runs.remove(at: shortest)
            mergeEqualNeighbours()
        }
        pruneBySweep()

        return runs.enumerated().map { index, run in
            let range = run.start..<run.end
            let start = index == 0 ? 0 : samples[run.start].time - 0.5 / MotionSpec.sampleRate
            let end = index == runs.count - 1 ? max(clipDuration, samples[run.end - 1].time)
                                              : samples[run.end - 1].time + 0.5 / MotionSpec.sampleRate
            var summary = [Float](repeating: 0, count: 8)
            for c in 0..<7 { summary[c] = range.reduce(0) { $0 + trend[$1][c] } / Float(range.count) }
            summary[7] = shake(raw: raw, trend: trend, samples: samples, range: range, clipDuration: clipDuration)

            let stability: Stability = summary[7] < MotionSpec.lockedOffShakeBelow ? .lockedOff
                : summary[7] < MotionSpec.stabilisedShakeBelow ? .stabilised : .handheld
            let parallaxShare = Float(range.filter { samples[$0].usedParallax }.count) / Float(range.count)
            // Translation measured on a minority of pairs is noise, not a move.
            if parallaxShare < 0.35 { for c in 4..<7 { summary[c] = 0 } }
            return MotionSegment(start: start, end: end, summary: summary,
                                 trajectory: range.map { trend[$0] },
                                 confidence: range.map { samples[$0].confidence },
                                 stability: stability,
                                 translationSource: parallaxShare >= 0.35 ? .parallax : .none,
                                 chips: chips(for: summary, duration: end - start))
        }
    }

    /// Steady shake level of a segment, deg/s — deliberately not an RMS. A locked-off shot with one knock (the record button,
    /// a bumped tripod) is still locked-off, and an RMS lets half a second of knock outweigh ten seconds of stillness.
    /// This takes the 60th percentile of per-sample shake energy: for continuous shake that equals the mean, so handheld
    /// footage reads exactly as before, while anything affecting under ~40% of the segment is ignored. The first and last
    /// half-second of the clip — where button presses live — are left out when enough of the segment remains.
    static func shake(raw: [[Float]], trend: [[Float]], samples: [MotionSample], range: Range<Int>, clipDuration: Double) -> Float {
        func energy(_ i: Int) -> Float { (0..<3).reduce(Float(0)) { let d = raw[i][$1] - trend[i][$1]; return $0 + d * d } / 3 }
        let interior = range.filter { samples[$0].time > MotionSpec.edgeGuardSeconds && samples[$0].time < clipDuration - MotionSpec.edgeGuardSeconds }
        let used = interior.count >= 8 ? interior : Array(range)
        let energies = used.map(energy).sorted()
        guard !energies.isEmpty else { return 0 }
        return energies[min(energies.count - 1, Int(Float(energies.count) * 0.6))].squareRoot()
    }

    public static func chips(for summary: [Float], duration: Double? = nil) -> [Chip] {
        var chips: [Chip] = []
        func speed(_ c: Int) -> String {
            let v = abs(summary[c])
            return v < MotionSpec.slowBelow[c] ? "slow" : v < MotionSpec.mediumBelow[c] ? "medium" : "fast"
        }
        func on(_ c: MotionChannel) -> Bool {
            let v = abs(summary[c.rawValue])
            if let duration, v * Float(duration) < MotionSpec.minSweep[c.rawValue] { return false }
            return v > MotionSpec.activeThreshold[c.rawValue]
        }
        func positive(_ c: MotionChannel) -> Bool { summary[c.rawValue] > 0 }

        var consumed = Set<MotionChannel>()
        if on(.truck), on(.pan), positive(.truck) != positive(.pan) {
            chips.append(Chip(primitive: "arc", direction: positive(.truck) ? "right" : "left", speed: speed(MotionChannel.truck.rawValue)))
            consumed.formUnion([.truck, .pan])
        }
        if on(.dolly), on(.zoom), positive(.dolly) != positive(.zoom) {
            chips.append(Chip(primitive: "dolly zoom", direction: positive(.dolly) ? "in" : "out", speed: speed(MotionChannel.dolly.rawValue)))
            consumed.formUnion([.dolly, .zoom])
        }
        if on(.pedestal), on(.tilt) {
            chips.append(Chip(primitive: "crane", direction: positive(.pedestal) ? "up" : "down", speed: speed(MotionChannel.pedestal.rawValue)))
            consumed.formUnion([.pedestal, .tilt])
        }
        let directions: [MotionChannel: (String, String)] = [
            .pan: ("right", "left"), .tilt: ("up", "down"), .roll: ("cw", "ccw"), .zoom: ("in", "out"),
            .truck: ("right", "left"), .pedestal: ("up", "down"), .dolly: ("in", "out"),
        ]
        // Strongest first, measured against each channel's own threshold.
        let ordered = MotionChannel.allCases.filter { on($0) && !consumed.contains($0) }.sorted {
            abs(summary[$0.rawValue]) / MotionSpec.activeThreshold[$0.rawValue] > abs(summary[$1.rawValue]) / MotionSpec.activeThreshold[$1.rawValue]
        }
        for c in ordered {
            let d = directions[c]!
            chips.append(Chip(primitive: c.name, direction: positive(c) ? d.0 : d.1, speed: speed(c.rawValue)))
        }
        if chips.isEmpty { chips.append(Chip(primitive: "static")) }
        return chips
    }

    /// Low-confidence pairs (blur, flat walls, water) are replaced by their neighbours rather than trusted.
    static func repaired(_ samples: [MotionSample]) -> [[Float]] {
        var rows = samples.map(\.rates)
        let good = samples.map { $0.confidence >= 0.5 }
        guard good.contains(true) else { return rows.map { _ in [Float](repeating: 0, count: 7) } }
        for i in rows.indices where !good[i] {
            let before = (0..<i).last { good[$0] }, after = ((i + 1)..<rows.count).first { good[$0] }
            switch (before, after) {
            case let (b?, a?):
                let t = Float(i - b) / Float(a - b)
                rows[i] = (0..<7).map { rows[b][$0] * (1 - t) + rows[a][$0] * t }
            case let (b?, nil): rows[i] = rows[b]
            case let (nil, a?): rows[i] = rows[a]
            default: break
            }
        }
        return rows
    }

    static func smoothed(_ rows: [[Float]], window: Double) -> [[Float]] {
        let half = max(1, Int((window * MotionSpec.sampleRate / 2).rounded()))
        return rows.indices.map { i in
            let lo = max(0, i - half), hi = min(rows.count - 1, i + half)
            return (0..<7).map { c in
                // Median-of-window guards the trend against single-pair spikes.
                let values = (lo...hi).map { rows[$0][c] }.sorted()
                let mean = values.reduce(0, +) / Float(values.count)
                return values.count >= 3 ? (mean + values[values.count / 2]) / 2 : mean
            }
        }
    }
}

extension MotionAnalysis {
    /// Chips for the grid: those of the longest segments, de-duplicated, plus the dominant stability.
    public var clipChips: [Chip] {
        var seen = Set<String>(), result: [Chip] = []
        for segment in segments.sorted(by: { $0.duration > $1.duration }) {
            for chip in segment.chips where chip.primitive != "static" && seen.insert(chip.title).inserted { result.append(chip) }
        }
        return result.isEmpty ? [Chip(primitive: "static")] : Array(result.prefix(4))
    }

    public var dominantStability: Stability {
        var totals: [Stability: Double] = [:]
        for s in segments { totals[s.stability, default: 0] += s.duration }
        return totals.max { $0.value < $1.value }?.key ?? .lockedOff
    }

    /// One line per segment, fed to the description model as ground truth.
    public var hint: String {
        segments.map { s in
            let moves = s.chips.map(\.display).joined(separator: " + ")
            return String(format: "%.1f–%.1fs: %@ (%@)", s.start, s.end, moves, s.stability.label)
        }.joined(separator: "\n")
    }
}
