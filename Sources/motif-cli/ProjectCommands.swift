import Foundation
import MotifKit
import GRDB

extension Commands {
    static func tagger(fake: Bool) -> Tagger? {
        if fake { return FakeTagger() }
        return Settings.apiKey.map { GeminiTagger(apiKey: $0) }
    }

    /// Builds (or resumes) a project package headlessly.
    static func ingest(folder: String, project path: String, describe: Bool, fake: Bool = false) async throws {
        let url = URL(fileURLWithPath: path), source = URL(fileURLWithPath: folder)
        let project = FileManager.default.fileExists(atPath: url.path)
            ? try Project.open(at: url)
            : try Project.create(at: url, name: url.deletingPathExtension().lastPathComponent, source: source)
        let tagger = describe ? tagger(fake: fake) : nil
        if describe && tagger == nil { print("no GEMINI_API_KEY — analysing only") }
        let engine = ProjectEngine(project: project, tagger: tagger)
        engine.onStatus = { if !$0.isEmpty { print($0) } }
        let started = Date()
        await engine.runToCompletion()
        try report(project, elapsed: Date().timeIntervalSince(started))
    }

    static func describe(project path: String, fake: Bool = false) async throws {
        let project = try Project.open(at: URL(fileURLWithPath: path))
        guard let tagger = tagger(fake: fake) else { throw MotifError.tagging("set GEMINI_API_KEY") }
        let engine = ProjectEngine(project: project, tagger: tagger)
        try engine.requeueDescriptions()
        let started = Date()
        await engine.runToCompletion()
        try report(project, elapsed: Date().timeIntervalSince(started))
        if let halt = engine.describeHalted { print("\ndescriptions stopped — \(halt)\nthe clips are still pending: fix the key and run describe again") }
    }

    static func report(_ project: Project, elapsed: Double) throws {
        let items = try project.db.read { try Project.listRequest().fetchAll($0) }
        var footage = 0.0, tokensIn = 0, tokensOut = 0
        for item in items {
            let c = item.clip
            footage += c.duration
            print("\n\(c.relPath)  [\(c.analysisState.rawValue) / \(c.describeState.rawValue)]" + (c.error.map { "  ⚠︎ \($0)" } ?? ""))
            if c.analysisState == .done { print("  chips: " + c.chips.map(\.display).joined(separator: ", ") + "  · \(c.stability ?? "")") }
            if let tag = item.tag {
                tokensIn += tag.tokensIn; tokensOut += tag.tokensOut
                print("  \(tag.shotSize ?? "?") · \(tag.subjectRelation ?? "?") — \(tag.description)\n  movement: \(tag.movementText)")
            }
        }
        print(String(format: "\n%d clips · %.0fs of footage · %.1fs elapsed (%.1f× realtime)", items.count, footage, elapsed, footage / max(elapsed, 0.01)))
        if tokensIn > 0 {
            // gemini-3.5-flash-lite list price, USD per million tokens — see PLAN.md §6.
            let cost = Double(tokensIn) * 0.30 / 1e6 + Double(tokensOut) * 2.50 / 1e6
            print(String(format: "tokens: %d in / %d out — ≈ $%.4f (≈ $%.2f per 1,000 clips)", tokensIn, tokensOut, cost, cost / Double(max(items.count, 1)) * 1000))
        }
    }

    static func search(project path: String, description: String, movement: String) throws {
        let project = try Project.open(at: URL(fileURLWithPath: path))
        try project.embedMissingText()
        let index = try SearchIndex(project: project)
        let query = MovementQuery.parse(movement)
        if !movement.isEmpty {
            print("movement query → moves: \(query.moves.map(\.title)), static: \(query.wantsStatic), stability: \(query.stability?.label ?? "-"), "
                  + "speed: \(query.speed ?? "-"), relations: \(query.relations.sorted()), free text: “\(query.freeText)”")
        }
        let started = Date()
        let hits = index.search(description: description, movement: query)
        let names = try project.db.read { db in Dictionary(uniqueKeysWithValues: try ClipRecord.fetchAll(db).map { ($0.id!, $0) }) }
        print(String(format: "%d hits of %d clips in %.1f ms", hits.count, index.count, Date().timeIntervalSince(started) * 1000))
        for hit in hits.prefix(12) {
            let clip = names[hit.clipID]!
            let range = hit.segmentRange.map { String(format: "  %.1f–%.1fs", $0.lowerBound, $0.upperBound) } ?? ""
            print(String(format: "  %.2f  ", hit.score) + clip.relPath + range + "   [" + clip.chips.map(\.display).joined(separator: ", ") + "]")
        }
    }

    /// Draws known moves as keyframed shots, checks the derived channels against the rates that were drawn, and — given a
    /// project built from `motif-cli synth` — that each shot finds its own clip.
    static func shotTest(project path: String?) throws {
        let stage = ReferenceStage()
        let start = CameraPose()
        let depth = stage.medianDepth(from: start)
        print(String(format: "reference set: median depth from the start pose %.1f m", depth))

        func shot(_ name: String, _ edit: (inout CameraPose) -> Void, duration: Double = 4) -> DesignedShot {
            var s = DesignedShot(); s.name = name; s.duration = duration
            var end = start; edit(&end)
            s.keyframes = [CameraKeyframe(time: 0, pose: start), CameraKeyframe(time: duration, pose: end)]
            return s
        }
        // (shot, expected mean rates on the channels it should move, clip it should find)
        let cases: [(DesignedShot, [MotionChannel: Float], String)] = [
            (shot("pan right 8°/s") { $0.yaw += 32 }, [.pan: 8], "pan_pos.mp4"),
            (shot("pan left 8°/s") { $0.yaw -= 32 }, [.pan: -8], "pan_neg.mp4"),
            (shot("tilt up 5°/s") { $0.pitch += 20 }, [.tilt: 5], "tilt_pos.mp4"),
            (shot("roll clockwise 6°/s") { $0.roll += 24 }, [.roll: 6], "roll_pos.mp4"),
            (shot("zoom in 0.12/s") { $0.focal *= exp(0.48) }, [.zoom: 0.12], "zoom_pos.mp4"),
            (shot("pan right + tilt down") { $0.yaw += 24; $0.pitch -= 16 }, [.pan: 6, .tilt: -4], "pan_tilt.mp4"),
            (shot("whip pan right") { $0.yaw += 140 }, [.pan: 35], "pan_fast.mp4"),
            (shot("push-in") { $0.position += start.forward * (0.045 * depth * 4) }, [.dolly: 0.045], "dolly_pos.mp4"),
            (shot("truck right") { $0.position += start.right * (0.04 * depth * 4) }, [.truck: 0.04], "truck_pos.mp4"),
            (DesignedShot(), [:], "static"),                       // any locked-off clip: there are several, all equally right
        ]
        let index = try path.map { try SearchIndex(project: try Project.open(at: URL(fileURLWithPath: $0))) }
        let names = try path.map { p in try Project.open(at: URL(fileURLWithPath: p)).db.read { db in
            Dictionary(uniqueKeysWithValues: try ClipRecord.fetchAll(db).map { ($0.id!, $0.relPath) }) } } ?? [:]

        var failures = 0
        for (design, expected, clip) in cases {
            let samples = design.samples { stage.medianDepth(from: $0) }
            var mean = [Float](repeating: 0, count: 7)
            for s in samples { for c in 0..<7 { mean[c] += s.rates[c] / Float(samples.count) } }
            var problems: [String] = []
            for channel in MotionChannel.allCases {
                let want = expected[channel] ?? 0, got = mean[channel.rawValue]
                var tolerance = max(abs(want) * (channel.isTranslation ? 0.25 : 0.03), MotionSpec.activeThreshold[channel.rawValue] * 0.3)
                // The designer pans about the world's vertical, like a tripod head: panning while tilted really does roll the image
                // by pan · sin(tilt). Shots here tilt at most ~20°.
                if channel == .roll { tolerance += abs(mean[MotionChannel.pan.rawValue]) * sin(20 * .pi / 180) }
                if abs(got - want) > tolerance { problems.append("\(channel.name) \(fmt(got)) vs \(fmt(want))") }
            }
            let chips = design.segments { stage.medianDepth(from: $0) }.map { $0.chips.map(\.display).joined(separator: " + ") }.joined(separator: " | ")
            var line = (design.name.isEmpty ? "static" : design.name).padding(toLength: 26, withPad: " ", startingAt: 0) + "[\(chips)]"
            if let index {
                let hits = index.search(description: "", movement: MovementQuery(), shot: ShotQuery(samples: samples, duration: design.duration))
                let top = hits.prefix(3).map { String(format: "%.2f %@", $0.score, names[$0.clipID] ?? "?") }.joined(separator: ", ")
                let rank = hits.firstIndex { (names[$0.clipID] ?? "").hasPrefix(clip) }
                line += "  → " + top
                if rank == nil || rank! > 1 { problems.append("expected \(clip) in the top 2, rank \(rank.map { String($0 + 1) } ?? "none")") }
            }
            if !problems.isEmpty { failures += 1; line += "\n" + String(repeating: " ", count: 26) + "FAIL: " + problems.joined(separator: "; ") }
            print(line)
        }
        print(failures == 0 ? "\nall shots pass" : "\n\(failures) shot(s) failed")
        if failures > 0 { exit(1) }
    }
}
