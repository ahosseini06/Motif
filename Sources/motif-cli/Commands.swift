import Foundation
import MotifKit

enum Commands {
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mxf", "avi", "mts", "m2ts", "3gp"]

    static func videoFiles(at path: String) -> [URL] {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue { return [url] }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return (walker?.allObjects as? [URL] ?? []).filter { videoExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
    }

    static func loadDepth(_ use: Bool) async -> DepthEstimator? {
        guard use else { return nil }
        do { return try await DepthEstimator.load { print($0) } }
        catch { print("depth model unavailable (\(error.localizedDescription)) — translation channels disabled"); return nil }
    }

    // MARK: selftest

    static func selftest() async throws {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(name)  \(detail)")
            if !ok { failures += 1 }
        }

        // Solver recovers known motion through noise and a 30% block of outliers (a moving subject).
        let f = 686.0
        let truth = (wx: 0.004, wy: -0.012, wz: 0.006, s: 0.01)
        var rng = SystemRandomNumberGenerator()
        var pts: [FlowPoint] = []
        for i in 0..<900 {
            let x = Double.random(in: -300...300, using: &rng), y = Double.random(in: -170...170, using: &rng)
            let xn = x / f, yn = y / f
            var u = f * (xn * yn * truth.wx - (1 + xn * xn) * truth.wy + yn * truth.wz + xn * truth.s)
            var v = f * ((1 + yn * yn) * truth.wx - xn * yn * truth.wy - xn * truth.wz + yn * truth.s)
            u += Double.random(in: -0.15...0.15, using: &rng); v += Double.random(in: -0.15...0.15, using: &rng)
            if i % 10 < 3 { u += 9; v -= 4 }
            pts.append(FlowPoint(x: Float(x), y: Float(y), u: Float(u), v: Float(v)))
        }
        let sol = MotionSolver.solveRotation(pts, focal: f)
        let err = max(abs(sol.omega.x - truth.wx), abs(sol.omega.y - truth.wy), abs(sol.omega.z - truth.wz), abs(sol.zoom - truth.s))
        check("solver: rotation+zoom with 30% outliers", err < 4e-4, String(format: "max error %.2e, inliers %.2f", err, sol.inlierRatio))

        // Optical-flow sign: content shifted right and down must read as +u, +v.
        let texture = SynthRenderer.texture(seed: 42, size: 512)
        let a = try SynthRenderer.pixelBuffer(from: texture.cropping(to: CGRect(x: 40, y: 40, width: 400, height: 240))!, width: 400, height: 240)
        let b = try SynthRenderer.pixelBuffer(from: texture.cropping(to: CGRect(x: 34, y: 37, width: 400, height: 240))!, width: 400, height: 240)
        let grid = try FlowEstimator().flow(from: a, to: b)
        let us = grid.points.map(\.u).sorted(), vs = grid.points.map(\.v).sorted()
        let mu = us[us.count / 2], mv = vs[vs.count / 2]
        check("flow: +6 px right, +3 px down", abs(mu - 6) < 0.6 && abs(mv - 3) < 0.6, String(format: "median u %.2f v %.2f", mu, mv))

        // Chips
        let chips = Segmenter.chips(for: [8, 0, 0, 0, 0, 0, 0.09, 0.1])
        check("chips: pan right + push-in", Set(chips.map(\.title)) == ["pan right", "push-in"], chips.map(\.display).joined(separator: ", "))

        print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: synth + eval

    static func synth(dir: String) async throws {
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let renderer = try SynthRenderer()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for move in SynthMove.standardSet {
            let started = Date()
            var move = move
            move.medianDepth = try await renderer.render(move, to: out.appendingPathComponent("\(move.name).mp4"))
            try encoder.encode(move).write(to: out.appendingPathComponent("\(move.name).json"))
            print(String(format: "rendered %@ (%.1fs)", move.name, Date().timeIntervalSince(started)))
        }
    }

    static func eval(dir: String, useDepth: Bool, verbose: Bool) async throws {
        let depth = await loadDepth(useDepth)
        let analyzer = ClipAnalyzer(depth: depth)
        let files = videoFiles(at: dir)
        guard !files.isEmpty else { throw MotifError.project("no synthetic clips in \(dir) — run `motif-cli synth` first") }

        var passed = 0, signChecks = 0, signOK = 0
        var rateErrors: [Double] = []
        print("clip".padding(toLength: 18, withPad: " ", startingAt: 0) + "result  chips / problems")
        for file in files {
            let truthURL = file.deletingPathExtension().appendingPathExtension("json")
            guard let data = try? Data(contentsOf: truthURL), let move = try? JSONDecoder().decode(SynthMove.self, from: data) else { continue }
            let result = try await analyzer.analyze(url: file)
            let samples = result.motion.samples.filter { $0.time > 0.3 && $0.time < move.duration - 0.3 }
            var mean = [Float](repeating: 0, count: 7)
            for s in samples { for c in 0..<7 { mean[c] += s.rates[c] / Float(samples.count) } }

            var problems: [String] = []
            for channel in MotionChannel.allCases {
                let c = channel.rawValue, m = mean[c]
                // Nominal translation rates assume `nominalDepth`; the scene's measured median depth gives the true rate.
                let t = move.rates[c] * (channel.isTranslation ? SynthRenderer.nominalDepth / (move.medianDepth ?? SynthRenderer.nominalDepth) : 1)
                // Translation only counts when depth was available.
                if channel.isTranslation && depth == nil { continue }
                if abs(t) > 0 {
                    signChecks += 1
                    if (m > 0) == (t > 0) && abs(m) > MotionSpec.activeThreshold[c] * 0.5 { signOK += 1 } else { problems.append("\(channel.name) sign/miss (\(fmt(m)) vs \(fmt(t)))") ; continue }
                    let rel = Double(abs(m - t) / abs(t))
                    if channel.isTranslation { if rel > 0.6 { problems.append("\(channel.name) magnitude \(fmt(m)) vs \(fmt(t))") } }
                    else { rateErrors.append(rel); if rel > 0.15 { problems.append("\(channel.name) rate \(fmt(m)) vs \(fmt(t))") } }
                } else if abs(m) > MotionSpec.activeThreshold[c] {
                    problems.append("false \(channel.name) \(fmt(m))")
                }
            }
            // Stability is part of the ground truth too: jitter was either rendered in or it wasn't, and a knock at the end is neither.
            let expected: Stability = move.handheldDegrees > 0 ? .handheld : .lockedOff
            if result.motion.dominantStability != expected {
                problems.append("stability \(result.motion.dominantStability.label), expected \(expected.label)")
            }
            let chips = result.motion.segments.map { "[" + $0.chips.map(\.display).joined(separator: ", ") + " | \($0.stability.label)]" }.joined(separator: " ")
            if problems.isEmpty { passed += 1 }
            print(move.name.padding(toLength: 18, withPad: " ", startingAt: 0) + (problems.isEmpty ? "ok      " : "FAIL    ") + chips
                  + (problems.isEmpty ? "" : "\n" + String(repeating: " ", count: 26) + problems.joined(separator: "; ")))
            if verbose { print("    mean: " + mean.map(fmt).joined(separator: " ")) }
        }
        let medianError = rateErrors.sorted()[safe: rateErrors.count / 2] ?? 0
        print(String(format: "\n%d / %d clips pass · direction %d / %d · median rate error %.1f%%", passed, files.count, signOK, signChecks, medianError * 100))
    }

    // MARK: analyze / bench

    static func analyze(path: String, useDepth: Bool, verbose: Bool, bench: Bool) async throws {
        let depth = await loadDepth(useDepth)
        let analyzer = ClipAnalyzer(depth: depth)
        var totalDuration = 0.0, totalTime = 0.0
        for file in videoFiles(at: path) {
            let started = Date()
            do {
                let r = try await analyzer.analyze(url: file)
                let elapsed = Date().timeIntervalSince(started)
                totalDuration += r.metadata.duration; totalTime += elapsed
                print("\n\(file.lastPathComponent)  \(r.metadata.width)×\(r.metadata.height) \(r.metadata.codec) " +
                      String(format: "%.1fs @ %.2f fps — analysed in %.2fs (%.1f× realtime)", r.metadata.duration, r.metadata.fps, elapsed, r.metadata.duration / elapsed))
                if bench { continue }
                for s in r.motion.segments {
                    print(String(format: "  %5.1f–%5.1fs  ", s.start, s.end) + s.chips.map(\.display).joined(separator: " + ") + "  [\(s.stability.label), shake \(fmt(s.summary[7]))]")
                    print("               vector " + s.summary.prefix(7).map(fmt).joined(separator: " ") + "  translation: \(s.translationSource.rawValue)")
                }
                if verbose { for s in r.motion.samples { print(String(format: "    %.2f  ", s.time) + s.rates.map(fmt).joined(separator: " ") + String(format: "  conf %.2f%@", s.confidence, s.usedParallax ? " P" : "")) } }
            } catch {
                print("\n\(file.lastPathComponent)  — \(error.localizedDescription)")
            }
        }
        if totalTime > 0 { print(String(format: "\ntotal: %.1fs of footage in %.1fs — %.1f× realtime", totalDuration, totalTime, totalDuration / totalTime)) }
    }

    static func fmt(_ v: Float) -> String { String(format: "%+.3f", v) }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
