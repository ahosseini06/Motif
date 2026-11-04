import SwiftUI
import GRDB
import MotifKit

enum ClipSort: String, CaseIterable, Identifiable {
    case name = "Name", duration = "Duration", shot = "Date Shot", movement = "Movement"
    var id: String { rawValue }
}

@MainActor @Observable
final class ProjectModel {
    let project: Project
    let engine: ProjectEngine

    private(set) var items: [ClipListItem] = []
    private(set) var counts = Project.Counts()
    private(set) var status = ""
    private(set) var sourceOnline = true
    /// Cached: asking the Keychain on every view update is slow and can prompt.
    private(set) var hasTagger = false
    private(set) var spend: (tokensIn: Int, tokensOut: Int) = (0, 0)
    /// Set when the description stage has stopped itself over a key problem. Shown as a banner; cleared by a new key.
    private(set) var describeIssue: String?

    /// The clip shown in the inspector. `selectedIDs` is everything highlighted — what a drag carries.
    var selection: Int64? { didSet { if let selection, !selectedIDs.contains(selection) { selectedIDs = [selection] } else if selection == nil { selectedIDs = [] } } }
    private(set) var selectedIDs: Set<Int64> = []
    var sort: ClipSort = .name

    // Search: two questions, asked separately. Presets and typed movement text are merged into one query.
    var descriptionQuery = "" { didSet { scheduleSearch() } }
    var movementText = "" { didSet { scheduleSearch() } }
    var presetMoves: [Chip] = [] { didSet { scheduleSearch() } }
    var presetStatic = false { didSet { scheduleSearch() } }
    var presetStability: Stability? { didSet { scheduleSearch() } }
    var presetSpeed: String? { didSet { scheduleSearch() } }
    var presetRelations: Set<String> = [] { didSet { scheduleSearch() } }
    /// A shot drawn in the designer, used as a query: clips are ranked by how closely a stretch of them moves like it.
    private(set) var activeShot: DesignedShot?
    private var shotQuery: ShotQuery?
    var designerOpen = false
    @ObservationIgnored private(set) lazy var designer = ShotDesignerModel()
    private(set) var hits: [Int64: SearchHit] = [:]
    private(set) var ranked: [Int64] = []
    private var index = SearchIndex()
    private var searchTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    var cellWidth: Double = 260
    var paused = false { didSet { engine.isPaused = paused } }
    var neverUpload: Bool { didSet { project.neverUpload = neverUpload; if !neverUpload { try? engine.requeueDescriptions(); engine.start() } } }

    private var observers: [AnyDatabaseCancellable] = []
    private var visible = Set<Int64>()
    private var priorityTask: Task<Void, Never>?

    init(project: Project) {
        self.project = project
        neverUpload = project.neverUpload
        sourceOnline = project.isSourceOnline
        let tagger = Self.makeTagger()
        hasTagger = tagger != nil
        engine = ProjectEngine(project: project, tagger: tagger)
        engine.onStatus = { [weak self] text in Task { @MainActor in self?.status = text } }
        engine.onDescribeHalted = { [weak self] reason in Task { @MainActor in self?.describeIssue = reason } }

        observers.append(ValueObservation.tracking { try Project.listRequest().fetchAll($0) }
            .start(in: project.db, scheduling: .async(onQueue: .main), onError: { _ in }, onChange: { [weak self] in self?.items = $0; self?.scheduleIndexRebuild() }))
        observers.append(ValueObservation.tracking { db -> (Project.Counts, Int, Int) in
            let row = try Row.fetchOne(db, sql: "SELECT COALESCE(SUM(tokensIn), 0) AS i, COALESCE(SUM(tokensOut), 0) AS o FROM tag")!
            return (try Project.counts(db), row["i"], row["o"])
        }.start(in: project.db, scheduling: .async(onQueue: .main), onError: { _ in }, onChange: { [weak self] in
            self?.counts = $0.0; self?.spend = ($0.1, $0.2)
        }))
        engine.start()
    }

    static func makeTagger() -> Tagger? {
        if ProcessInfo.processInfo.environment["MOTIF_FAKE_TAGGER"] == "1" { return FakeTagger() }
        return Settings.apiKey.map { GeminiTagger(apiKey: $0) }
    }

    func shutdown() {
        engine.stop()
        observers.removeAll()
    }

    func refreshTagger() {
        describeIssue = nil
        let tagger = Self.makeTagger()
        hasTagger = tagger != nil
        engine.setTagger(tagger)
        try? engine.requeueDescriptions()
        engine.start()
    }

    func rescan() {
        describeIssue = nil
        sourceOnline = project.isSourceOnline
        try? engine.retryFailed()
        engine.start()
    }

    // MARK: derived

    var displayed: [ClipListItem] {
        if isSearching {
            let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            return ranked.compactMap { byID[$0] }
        }
        switch sort {
        case .name: return items
        case .duration: return items.sorted { $0.clip.duration > $1.clip.duration }
        case .shot: return items.sorted { ($0.clip.capturedAt ?? .distantFuture) < ($1.clip.capturedAt ?? .distantFuture) }
        case .movement: return items.sorted { ($0.clip.chips.first?.title ?? "~") < ($1.clip.chips.first?.title ?? "~") }
        }
    }

    // MARK: search

    var movementQuery: MovementQuery {
        var query = MovementQuery.parse(movementText)
        var presets = MovementQuery()
        presets.moves = presetMoves; presets.wantsStatic = presetStatic; presets.stability = presetStability
        presets.speed = presetSpeed; presets.relations = presetRelations
        query.merge(presets)
        return query
    }

    var isSearching: Bool { !descriptionQuery.trimmingCharacters(in: .whitespaces).isEmpty || !movementQuery.isEmpty || shotQuery != nil }

    func searchByShot(_ shot: DesignedShot, query: ShotQuery) {
        activeShot = shot; shotQuery = query
        designerOpen = false
        scheduleSearch()
    }

    func searchBySavedShot(_ shot: DesignedShot) { searchByShot(shot, query: ShotDesignerModel.query(for: shot)) }

    func clearShot() { activeShot = nil; shotQuery = nil; scheduleSearch() }

    func editActiveShot() {
        if let activeShot, designer.shot.id != activeShot.id { designer.load(activeShot) }
        designerOpen = true
    }
    var hasDescriptions: Bool { items.contains { $0.tag != nil } }

    func clearSearch() {
        descriptionQuery = ""; movementText = ""
        activeShot = nil; shotQuery = nil
        presetMoves = []; presetStatic = false; presetStability = nil; presetSpeed = nil; presetRelations = []
    }

    /// One move per primitive: choosing "pan right" replaces "pan left". Static excludes moves, and the reverse.
    func toggle(_ move: Chip) {
        if presetMoves.contains(move) { presetMoves.removeAll { $0 == move } }
        else { presetStatic = false; presetMoves = presetMoves.filter { $0.primitive != move.primitive } + [move] }
    }

    func toggleStatic() {
        presetStatic.toggle()
        if presetStatic { presetMoves = [] }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        guard isSearching else { hits = [:]; ranked = []; return }
        let description = descriptionQuery, movement = movementQuery, index = index, shot = shotQuery
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) { index.search(description: description, movement: movement, shot: shot) }.value
            guard let self, !Task.isCancelled else { return }
            self.hits = Dictionary(uniqueKeysWithValues: results.map { ($0.clipID, $0) })
            self.ranked = results.map(\.clipID)
        }
    }

    /// The index follows the catalog: new segments and descriptions become searchable as they land.
    private func scheduleIndexRebuild() {
        indexTask?.cancel()
        let project = project
        indexTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let fresh = await Task.detached(priority: .utility) { try? SearchIndex(project: project) }.value
            guard let self, !Task.isCancelled, let fresh else { return }
            self.index = fresh
            if self.isSearching { self.scheduleSearch() }
        }
    }

    var selected: ClipListItem? { selection.flatMap { id in items.first { $0.id == id } } }


    /// List price of gemini-3.5-flash-lite, USD per million tokens (PLAN.md §6).
    var spendUSD: Double { Double(spend.tokensIn) * 0.30 / 1e6 + Double(spend.tokensOut) * 2.50 / 1e6 }

    // MARK: visibility → priority

    func setVisible(_ id: Int64, _ isVisible: Bool) {
        if isVisible { visible.insert(id) } else { visible.remove(id) }
        priorityTask?.cancel()
        priorityTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.engine.prioritise(Array(self.visible))
        }
    }

    /// Click with Finder's rules: plain selects one, ⌘ toggles, ⇧ extends from the inspector's clip.
    func click(_ id: Int64, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selectedIDs.contains(id), selectedIDs.count > 1 {
                selectedIDs.remove(id)
                if selection == id { selection = displayed.first { selectedIDs.contains($0.id) }?.id }
            } else { selectedIDs.insert(id); selection = id }
        } else if modifiers.contains(.shift), let anchor = selection {
            let ids = displayed.map(\.id)
            if let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: id) { selectedIDs.formUnion(ids[min(a, b)...max(a, b)]) }
        } else {
            selectedIDs = [id]
            selection = id
        }
    }

    /// Mouse-down on a clip: select it, unless it's already part of a selection that may be about to be dragged.
    func press(_ id: Int64) {
        if !selectedIDs.contains(id) { selectedIDs = [id]; selection = id }
    }

    func selectAll() {
        selectedIDs = Set(displayed.map(\.id))
        if selection == nil { selection = displayed.first?.id }
    }

    /// Original media files for a drag that starts on `id`: the whole selection if `id` is in it, in grid order.
    func dragFiles(startingAt id: Int64) -> [(id: Int64, url: URL)] {
        guard sourceOnline else { return [] }
        let ids = selectedIDs.contains(id) ? selectedIDs : [id]
        return displayed.filter { ids.contains($0.id) && !$0.clip.missing && $0.clip.analysisState != .unsupported }
            .compactMap { item in project.fileURL(for: item.clip).map { (item.id, $0) } }
            .filter { FileManager.default.fileExists(atPath: $0.1.path) }
    }

    func move(_ delta: Int) {
        let list = displayed
        guard !list.isEmpty else { return }
        let index = selection.flatMap { id in list.firstIndex { $0.id == id } } ?? -1
        let next = list[min(list.count - 1, max(0, index + delta))].id
        selectedIDs = [next]
        selection = next
    }
}
