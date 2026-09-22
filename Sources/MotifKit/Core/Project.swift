import Foundation
import GRDB
import CryptoKit

extension ClipRecord {
    static let tag = hasOne(TagRecord.self, using: ForeignKey(["clipId"]))
    static let segments = hasMany(SegmentRecord.self, using: ForeignKey(["clipId"]))
}

/// A `.motif` package: the catalog plus every derived file, so a project stays browsable with its source drive unplugged.
///
///     MyFilm.motif/
///       catalog.sqlite
///       cache/posters/<clipID>.heic
///       cache/sprites/<clipID>.heic
///       cache/proxies/<clipID>.mp4
public final class Project: @unchecked Sendable {
    public static let fileExtension = "motif"

    public let url: URL
    public let db: DatabasePool

    private init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        for dir in ["cache/posters", "cache/sprites", "cache/proxies"] {
            try fm.createDirectory(at: url.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        db = try DatabasePool(path: url.appendingPathComponent("catalog.sqlite").path)
        try Self.migrator.migrate(db)
        // Tagged under older motion conventions: measure again. Descriptions are kept — only the on-device pass reruns.
        if let stored = meta("motionSpecVersion"), stored != String(MotionSpec.version) {
            try db.write { try $0.execute(sql: "UPDATE clip SET analysisState = 'pending' WHERE analysisState = 'done'") }
            try setMeta("motionSpecVersion", String(MotionSpec.version))
        }
        // Anything mid-flight when the app last quit starts over.
        try db.write { db in
            try db.execute(sql: "UPDATE clip SET analysisState = 'pending' WHERE analysisState = 'running'")
            try db.execute(sql: "UPDATE clip SET describeState = 'pending' WHERE describeState = 'running'")
        }
    }

    public static func create(at url: URL, name: String, source: URL) throws -> Project {
        if FileManager.default.fileExists(atPath: url.path) { throw MotifError.project("\(url.lastPathComponent) already exists") }
        let project = try Project(url: url)
        try project.setMeta("name", name)
        try project.setMeta("sourcePath", source.path)
        try project.setMeta("sourceBookmark", try source.bookmarkData().base64EncodedString())
        try project.setMeta("motionSpecVersion", String(MotionSpec.version))
        return project
    }

    public static func open(at url: URL) throws -> Project {
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("catalog.sqlite").path) else {
            throw MotifError.project("\(url.lastPathComponent) is not a Motif project")
        }
        return try Project(url: url)
    }

    // MARK: meta

    public func meta(_ key: String) -> String? {
        try? db.read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) }
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try db.write { try $0.execute(sql: "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value]) }
    }

    public var name: String { meta("name") ?? url.deletingPathExtension().lastPathComponent }

    public var neverUpload: Bool {
        get { meta("neverUpload") == "1" }
        set { try? setMeta("neverUpload", newValue ? "1" : "0") }
    }

    /// The footage folder. The bookmark follows it if it's renamed or moved on the same volume.
    public var sourceURL: URL? {
        if let b64 = meta("sourceBookmark"), let data = Data(base64Encoded: b64) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale) {
                if stale, let fresh = try? url.bookmarkData() { try? setMeta("sourceBookmark", fresh.base64EncodedString()) }
                return url
            }
        }
        return meta("sourcePath").map { URL(fileURLWithPath: $0) }
    }

    public var isSourceOnline: Bool {
        guard let url = sourceURL else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    public func fileURL(for clip: ClipRecord) -> URL? { sourceURL?.appendingPathComponent(clip.relPath) }

    // MARK: cache

    public func posterURL(_ id: Int64) -> URL { url.appendingPathComponent("cache/posters/\(id).heic") }
    public func spriteURL(_ id: Int64) -> URL { url.appendingPathComponent("cache/sprites/\(id).heic") }
    public func proxyURL(_ id: Int64) -> URL { url.appendingPathComponent("cache/proxies/\(id).mp4") }

    // MARK: queries

    public static func listRequest() -> QueryInterfaceRequest<ClipListItem> {
        ClipRecord.including(optional: ClipRecord.tag).order(Column("relPath").collating(.localizedStandardCompare)).asRequest(of: ClipListItem.self)
    }

    public func segments(for clipID: Int64) -> [SegmentRecord] {
        (try? db.read { try SegmentRecord.filter(Column("clipId") == clipID).order(Column("idx")).fetchAll($0) }) ?? []
    }

    public struct Counts: Equatable, Sendable {
        public var total = 0, analysed = 0, described = 0, failed = 0, describable = 0

        public init(total: Int = 0, analysed: Int = 0, described: Int = 0, failed: Int = 0, describable: Int = 0) {
            self.total = total; self.analysed = analysed; self.described = described; self.failed = failed; self.describable = describable
        }
    }

    public static func counts(_ db: Database) throws -> Counts {
        let row = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS total,
                   SUM(analysisState = 'done') AS analysed,
                   SUM(describeState = 'done') AS described,
                   SUM(analysisState = 'failed' OR describeState = 'failed') AS failed,
                   SUM(analysisState = 'done' AND describeState IN ('pending', 'running', 'done', 'failed')) AS describable
            FROM clip WHERE analysisState != 'unsupported'
            """)!
        return Counts(total: row["total"] ?? 0, analysed: row["analysed"] ?? 0, described: row["described"] ?? 0,
                      failed: row["failed"] ?? 0, describable: row["describable"] ?? 0)
    }

    // MARK: schema

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            try db.create(table: "clip") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("relPath", .text).notNull().unique()
                t.column("fingerprint", .text).notNull().indexed()
                t.column("size", .integer).notNull()
                t.column("mtime", .double).notNull()
                t.column("addedAt", .datetime).notNull()
                t.column("missing", .boolean).notNull().defaults(to: false)
                t.column("duration", .double).notNull().defaults(to: 0)
                t.column("fps", .double).notNull().defaults(to: 0)
                t.column("width", .integer).notNull().defaults(to: 0)
                t.column("height", .integer).notNull().defaults(to: 0)
                t.column("codec", .text).notNull().defaults(to: "")
                t.column("transferFunction", .text)
                t.column("rotation", .integer).notNull().defaults(to: 0)
                t.column("hasAudio", .boolean).notNull().defaults(to: false)
                t.column("capturedAt", .datetime)
                t.column("cameraMake", .text)
                t.column("cameraModel", .text)
                t.column("focal35mm", .double)
                t.column("analysisState", .text).notNull().indexed()
                t.column("describeState", .text).notNull().indexed()
                t.column("error", .text)
                t.column("chipsJSON", .text)
                t.column("stability", .text)
                t.column("spriteJSON", .text)
                t.column("proxyFPS", .double)
                t.column("motionHint", .text)
            }
            try db.create(table: "segment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("clipId", .integer).notNull().indexed().references("clip", onDelete: .cascade)
                t.column("idx", .integer).notNull()
                t.column("tStart", .double).notNull()
                t.column("tEnd", .double).notNull()
                t.column("summary", .blob).notNull()
                t.column("trajectory", .blob).notNull()
                t.column("confidence", .blob).notNull()
                t.column("translationSource", .text).notNull()
                t.column("stability", .text).notNull()
                t.column("chipsJSON", .text).notNull()
            }
            try db.create(table: "tag") { t in
                t.primaryKey("clipId", .integer).references("clip", onDelete: .cascade)
                t.column("description", .text).notNull()
                t.column("movementText", .text).notNull()
                t.column("shotSize", .text)
                t.column("subjectRelation", .text)
                t.column("model", .text).notNull()
                t.column("promptVersion", .integer).notNull()
                t.column("tokensIn", .integer).notNull()
                t.column("tokensOut", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }
        m.registerMigration("v2-embeddings") { db in
            try db.create(table: "embedding") { t in
                t.column("clipId", .integer).notNull().references("clip", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("model", .text).notNull()
                t.column("vector", .blob).notNull()
                t.primaryKey(["clipId", "kind", "model"])
            }
        }
        return m
    }
}

/// File size + SHA-256 of the first and last MiB — survives renames, moves and touched mtimes.
/// Hashing whole camera files would take longer than analysing them.
public enum Fingerprint {
    public static func of(_ url: URL, size: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunk = 1 << 20
        hasher.update(data: try handle.read(upToCount: chunk) ?? Data())
        if size > Int64(chunk) * 2 {
            try handle.seek(toOffset: UInt64(size) - UInt64(chunk))
            hasher.update(data: try handle.read(upToCount: chunk) ?? Data())
        }
        withUnsafeBytes(of: size) { hasher.update(bufferPointer: $0) }
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
