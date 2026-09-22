import Foundation
import GRDB

/// Scans the source folder and drives every clip through analysis (on-device) and description (API).
/// All state lives in the catalog, so quitting at any point loses at most the clips in flight.
public final class ProjectEngine: @unchecked Sendable {
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mxf", "avi", "mts", "m2ts", "3gp", "mkv", "braw", "r3d"]

    public let project: Project
    public var analysisConcurrency = 2
    public var describeConcurrency = 4
    /// Human-readable status lines (model download, scan progress).
    public var onStatus: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var tagger: Tagger?
    private var priority: [Int64] = []
    private var paused = false
    private var tasks: [Task<Void, Never>] = []
    private var depth: DepthEstimator?

    public init(project: Project, tagger: Tagger?) {
        self.project = project
        self.tagger = tagger
    }

    public func setTagger(_ tagger: Tagger?) {
        lock.withLock { self.tagger = tagger }
    }

    /// Clips on screen go first.
    public func prioritise(_ ids: [Int64]) {
        lock.withLock { priority = ids }
    }

    public var isPaused: Bool {
        get { lock.withLock { paused } }
        set { lock.withLock { paused = newValue } }
    }

    public func start() {
        stop()
        let runner = Task { [weak self] in
            guard let self else { return }
            await self.scan()
            try? self.project.embedMissingText()          // projects described before search existed
            if self.depth == nil {
                do { self.depth = try await DepthEstimator.load { [weak self] in self?.onStatus?($0) } }
                catch { self.onStatus?("Depth model unavailable — translation moves won't be detected (\(error.localizedDescription))") }
            }
            self.onStatus?("")
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<self.analysisConcurrency { group.addTask { await self.worker(stage: .analysis) } }
                for _ in 0..<self.describeConcurrency { group.addTask { await self.worker(stage: .describe) } }
            }
        }
        lock.withLock { tasks = [runner] }
    }

    public func stop() {
        let old = lock.withLock { () -> [Task<Void, Never>] in defer { tasks = [] }; return tasks }
        old.forEach { $0.cancel() }
    }

    /// Runs until nothing is pending. For the CLI and tests.
    public func runToCompletion() async {
        start()
        let runner = lock.withLock { tasks.first }
        await runner?.value
    }

    public func retryFailed() throws {
        try project.db.write { db in
            try db.execute(sql: "UPDATE clip SET analysisState = 'pending', error = NULL WHERE analysisState = 'failed'")
            try db.execute(sql: "UPDATE clip SET describeState = 'pending', error = NULL WHERE describeState IN ('failed', 'blocked') AND analysisState = 'done'")
        }
    }

    /// Queue every analysed clip that has no description yet — after a key is added or never-upload is switched off.
    public func requeueDescriptions() throws {
        try project.db.write { db in
            try db.execute(sql: "UPDATE clip SET describeState = 'pending', error = NULL WHERE describeState IN ('skipped', 'failed', 'blocked')")
            try db.execute(sql: "UPDATE clip SET describeState = 'pending' WHERE describeState = 'done' AND id IN (SELECT clipId FROM tag WHERE model = 'fake')")
        }
    }

    // MARK: - scan

    public func scan() async {
        guard let root = project.sourceURL, project.isSourceOnline else {
            onStatus?("Source folder is offline")
            return
        }
        onStatus?("Scanning \(root.lastPathComponent)…")
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var seen = Set<String>()
        let rootPath = root.standardizedFileURL.path
        while let url = walker?.nextObject() as? URL {
            if Task.isCancelled { return }
            guard Self.videoExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            let rel = String(path.dropFirst(rootPath.count).drop { $0 == "/" })
            let size = Int64(values.fileSize ?? 0), mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            seen.insert(rel)
            do {
                let existing = try await project.db.read { try ClipRecord.filter(Column("relPath") == rel).fetchOne($0) }
                if let existing, existing.size == size, abs(existing.mtime - mtime) < 1 {
                    if existing.missing { try await project.db.write { try $0.execute(sql: "UPDATE clip SET missing = 0 WHERE id = ?", arguments: [existing.id]) } }
                    continue
                }
                let fingerprint = try Fingerprint.of(url, size: size)
                try await project.db.write { db in
                    if var same = existing {
                        if same.fingerprint == fingerprint {            // touched, not changed
                            same.mtime = mtime; same.missing = false
                            try same.update(db)
                        } else {                                        // replaced in place: analyse again
                            try SegmentRecord.filter(Column("clipId") == same.id!).deleteAll(db)
                            try TagRecord.filter(Column("clipId") == same.id!).deleteAll(db)
                            var fresh = ClipRecord(relPath: rel, fingerprint: fingerprint, size: size, mtime: mtime)
                            fresh.id = same.id
                            try fresh.update(db)
                        }
                    } else if var moved = try ClipRecord.filter(Column("fingerprint") == fingerprint).fetchAll(db)
                        .first(where: { !FileManager.default.fileExists(atPath: root.appendingPathComponent($0.relPath).path) }) {
                        moved.relPath = rel; moved.mtime = mtime; moved.missing = false   // renamed or moved: keep its tags
                        try moved.update(db)
                    } else {
                        var clip = ClipRecord(relPath: rel, fingerprint: fingerprint, size: size, mtime: mtime)
                        try clip.insert(db)
                    }
                }
            } catch {
                onStatus?("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let present = seen
        _ = try? await project.db.write { db in
            for clip in try ClipRecord.fetchAll(db) where present.contains(clip.relPath) == clip.missing {
                try db.execute(sql: "UPDATE clip SET missing = ? WHERE id = ?", arguments: [!present.contains(clip.relPath), clip.id])
            }
        }
    }

    // MARK: - workers

    private enum Stage { case analysis, describe }

    private func worker(stage: Stage) async {
        var idleRounds = 0
        while !Task.isCancelled {
            if isPaused { try? await Task.sleep(for: .milliseconds(400)); continue }
            guard let clip = claim(stage) else {
                // Description work appears as analysis completes; stop once both queues are dry.
                idleRounds += 1
                if stage == .analysis || (idleRounds > 3 && !hasPendingAnalysis()) { return }
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            idleRounds = 0
            switch stage {
            case .analysis: await analyse(clip)
            case .describe: await describe(clip)
            }
        }
    }

    private func hasPendingAnalysis() -> Bool {
        let count = try? project.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM clip WHERE analysisState IN ('pending', 'running') AND missing = 0") }
        return (count ?? 0) > 0
    }

    private func claim(_ stage: Stage) -> ClipRecord? {
        let wanted = lock.withLock { priority }
        let tagger = lock.withLock { self.tagger }
        let neverUpload = project.neverUpload
        return try? project.db.write { db -> ClipRecord? in
            let column = stage == .analysis ? "analysisState" : "describeState"
            var filter = "\(column) = 'pending' AND missing = 0"
            if stage == .describe {
                filter += " AND analysisState = 'done'"
                if neverUpload {
                    try db.execute(sql: "UPDATE clip SET describeState = 'skipped' WHERE \(filter)")
                    return nil
                }
                if tagger == nil { return nil }
            }
            var clip: ClipRecord?
            if !wanted.isEmpty {
                let ids = wanted.map(String.init).joined(separator: ",")
                clip = try ClipRecord.fetchOne(db, sql: "SELECT * FROM clip WHERE \(filter) AND id IN (\(ids)) LIMIT 1")
            }
            if clip == nil { clip = try ClipRecord.fetchOne(db, sql: "SELECT * FROM clip WHERE \(filter) ORDER BY relPath LIMIT 1") }
            guard let claimed = clip else { return nil }
            try db.execute(sql: "UPDATE clip SET \(column) = 'running' WHERE id = ?", arguments: [claimed.id])
            return claimed
        }
    }

    private func analyse(_ clip: ClipRecord) async {
        guard let id = clip.id, let file = project.fileURL(for: clip) else { return }
        do {
            let outputs = ClipAnalyzer.Outputs(poster: project.posterURL(id), sprite: project.spriteURL(id), proxy: project.proxyURL(id))
            let result = try await ClipAnalyzer(depth: depth).analyze(url: file, outputs: outputs)
            try await project.db.write { db in
                guard var row = try ClipRecord.fetchOne(db, key: id) else { return }
                let m = result.metadata
                row.duration = m.duration; row.fps = m.fps; row.width = m.width; row.height = m.height
                row.codec = m.codec; row.transferFunction = m.transferFunction; row.rotation = m.rotation
                row.hasAudio = m.hasAudio; row.capturedAt = m.capturedAt
                row.cameraMake = m.cameraMake; row.cameraModel = m.cameraModel; row.focal35mm = m.focal35mm
                row.chipsJSON = String(data: try JSONEncoder().encode(result.motion.clipChips), encoding: .utf8)
                row.stability = result.motion.dominantStability.rawValue
                row.spriteJSON = try result.sprite.map { String(data: try JSONEncoder().encode($0), encoding: .utf8)! }
                row.proxyFPS = result.proxyFPS
                row.motionHint = result.motion.hint
                row.analysisState = .done
                row.error = nil
                try row.update(db)
                try SegmentRecord.filter(Column("clipId") == id).deleteAll(db)
                for (i, segment) in result.motion.segments.enumerated() {
                    var record = SegmentRecord(clipId: id, idx: i, segment: segment)
                    try record.insert(db)
                }
            }
        } catch {
            let unsupported = { if case MotifError.unsupported = error { return true } else { return false } }()
            _ = try? await project.db.write { db in
                try db.execute(sql: "UPDATE clip SET analysisState = ?, describeState = 'skipped', error = ? WHERE id = ?",
                               arguments: [unsupported ? StageState.unsupported.rawValue : StageState.failed.rawValue, error.localizedDescription, id])
            }
        }
    }

    private func describe(_ clip: ClipRecord) async {
        guard let id = clip.id, let tagger = lock.withLock({ self.tagger }) else { return }
        do {
            let request = TagRequest(proxy: project.proxyURL(id), proxyFPS: clip.proxyFPS ?? 1, duration: clip.duration, motionHint: clip.motionHint ?? "")
            let result = try await tagger.describe(request)
            try await project.db.write { db in
                try TagRecord(clipId: id, description: result.description, movementText: result.movementText, shotSize: result.shotSize,
                              subjectRelation: result.subjectRelation, model: result.model, promptVersion: TagPrompt.version,
                              tokensIn: result.tokensIn, tokensOut: result.tokensOut).save(db)
                try db.execute(sql: "UPDATE clip SET describeState = 'done', error = NULL WHERE id = ?", arguments: [id])
            }
            try? project.embedMissingText()
        } catch {
            let blocked = { if case MotifError.blocked = error { return true } else { return false } }()
            _ = try? await project.db.write { db in
                try db.execute(sql: "UPDATE clip SET describeState = ?, error = ? WHERE id = ?",
                               arguments: [blocked ? StageState.blocked.rawValue : StageState.failed.rawValue, error.localizedDescription, id])
            }
        }
    }
}
