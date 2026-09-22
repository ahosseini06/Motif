import Foundation

/// What a movement search asks for. Built from preset chips, from typed text, or both.
public struct MovementQuery: Equatable, Sendable {
    /// Wanted moves. A nil direction means either way ("pan").
    public var moves: [Chip] = []
    public var wantsStatic = false
    public var stability: Stability?
    public var speed: String?
    public var relations: Set<String> = []
    /// Whatever the phrase table didn't recognise; matched semantically against the movement sentence.
    public var freeText = ""

    public init() {}

    public var isStructured: Bool { !moves.isEmpty || wantsStatic || stability != nil || speed != nil || !relations.isEmpty }
    public var isEmpty: Bool { !isStructured && freeText.isEmpty }

    public mutating func merge(_ other: MovementQuery) {
        for move in other.moves where !moves.contains(where: { $0.primitive == move.primitive && $0.direction == move.direction }) { moves.append(move) }
        wantsStatic = wantsStatic || other.wantsStatic
        stability = stability ?? other.stability
        speed = speed ?? other.speed
        relations.formUnion(other.relations)
        if freeText.isEmpty { freeText = other.freeText }
    }

    // MARK: presets

    public static let movePresets: [Chip] = [
        Chip(primitive: "pan", direction: "left"), Chip(primitive: "pan", direction: "right"),
        Chip(primitive: "tilt", direction: "up"), Chip(primitive: "tilt", direction: "down"),
        Chip(primitive: "dolly", direction: "in"), Chip(primitive: "dolly", direction: "out"),
        Chip(primitive: "zoom", direction: "in"), Chip(primitive: "zoom", direction: "out"),
        Chip(primitive: "truck", direction: "left"), Chip(primitive: "truck", direction: "right"),
        Chip(primitive: "pedestal", direction: "up"), Chip(primitive: "pedestal", direction: "down"),
        Chip(primitive: "roll", direction: "cw"), Chip(primitive: "roll", direction: "ccw"),
        Chip(primitive: "arc", direction: "left"), Chip(primitive: "arc", direction: "right"),
    ]
    public static let speedPresets = ["slow", "medium", "fast"]
    public static let relationPresets = ["tracking", "following", "leading", "orbit", "reveal"]

    // MARK: text → query

    /// Recognises cinematographer's phrases ("slow push in, handheld", "whip pan left", "crane up") and leaves the rest as free text.
    public static func parse(_ text: String) -> MovementQuery {
        var query = MovementQuery()
        var rest = " " + text.lowercased().replacingOccurrences(of: "-", with: " ") + " "
        for punctuation in [",", ".", ";", ":", "+", "&", "/"] { rest = rest.replacingOccurrences(of: punctuation, with: " ") }

        // Longest phrases first so "track left" wins over "track" and "locked off" over "off".
        for (phrase, effect) in phraseTable where rest.contains(" \(phrase) ") {
            rest = rest.replacingOccurrences(of: " \(phrase) ", with: "  ")
            effect(&query)
        }
        let leftovers = rest.split(separator: " ").map(String.init).filter { !stopWords.contains($0) }
        query.freeText = leftovers.joined(separator: " ")
        return query
    }

    private typealias Effect = (inout MovementQuery) -> Void

    private static func move(_ primitive: String, _ direction: String?) -> Effect {
        { q in
            // A directed phrase replaces an earlier undirected one for the same primitive.
            q.moves.removeAll { $0.primitive == primitive && ($0.direction == nil || direction == nil) }
            if !q.moves.contains(where: { $0.primitive == primitive && $0.direction == direction }) {
                q.moves.append(Chip(primitive: primitive, direction: direction))
            }
        }
    }

    private static let stopWords: Set<String> = ["a", "an", "the", "with", "and", "on", "of", "to", "shot", "camera", "move", "movement",
                                                 "moves", "moving", "that", "is", "in", "at", "while", "then", "very", "bit", "slightly", "some"]

    private static let phraseTable: [(String, Effect)] = {
        var table: [(String, Effect)] = []
        func add(_ phrases: [String], _ effect: @escaping Effect) { for p in phrases { table.append((p, effect)) } }
        func verbs(_ stems: [String], _ suffixes: [String]) -> [String] { stems.flatMap { s in suffixes.map { "\(s) \($0)" } } }

        let pan = ["pan", "pans", "panning", "panned"], tilt = ["tilt", "tilts", "tilting", "tilted"]
        add(verbs(pan, ["left", "to the left"]), move("pan", "left")); add(verbs(pan, ["right", "to the right"]), move("pan", "right"))
        add(verbs(tilt, ["up", "upward", "upwards"]), move("tilt", "up")); add(verbs(tilt, ["down", "downward", "downwards"]), move("tilt", "down"))
        add(pan, move("pan", nil)); add(tilt, move("tilt", nil))

        add(["push in", "pushes in", "pushing in", "push", "dolly in", "dollies in", "dolly forward", "move in", "moves in", "moving in",
             "moving toward", "moves toward", "moving towards", "moves towards", "creep in", "creeps in", "creeping in", "track in", "tracks in"], move("dolly", "in"))
        add(["pull out", "pulls out", "pulling out", "pull back", "pulls back", "pulling back", "dolly out", "dolly back", "dollies out",
             "moving away", "moves away", "backs away", "track out", "tracks out"], move("dolly", "out"))
        add(["dolly", "dollies"], move("dolly", nil))

        add(["zoom in", "zooms in", "zooming in", "zoom into", "zooms into"], move("zoom", "in"))
        add(["zoom out", "zooms out", "zooming out"], move("zoom", "out"))
        add(["zoom", "zooms", "zooming"], move("zoom", nil))

        let lateral = ["truck", "trucks", "trucking", "track", "tracks", "slide", "slides", "sliding", "crab", "crabs", "lateral", "sideways"]
        add(verbs(lateral, ["left", "to the left"]), move("truck", "left")); add(verbs(lateral, ["right", "to the right"]), move("truck", "right"))
        add(["truck", "trucks", "trucking", "slide", "slides", "sliding", "slider", "lateral", "sideways", "crab"], move("truck", nil))

        add(["pedestal up", "crane up", "cranes up", "boom up", "booms up", "jib up", "rise", "rises", "rising", "ascend", "ascends", "ascending", "lifts", "lifting"], move("pedestal", "up"))
        add(["pedestal down", "crane down", "cranes down", "boom down", "booms down", "jib down", "descend", "descends", "descending", "lowers", "lowering", "sinks", "sinking"], move("pedestal", "down"))
        add(["pedestal", "crane", "jib", "boom"], move("pedestal", nil))

        add(["roll clockwise", "rolls clockwise", "roll right", "rolls right"], move("roll", "cw"))
        add(["roll counter clockwise", "roll counterclockwise", "roll anticlockwise", "roll left", "rolls left"], move("roll", "ccw"))
        add(["roll", "rolls", "rolling", "dutch", "dutch angle", "barrel roll"], move("roll", nil))

        add(["arc left", "arcs left", "orbit left", "orbits left"], move("arc", "left"))
        add(["arc right", "arcs right", "orbit right", "orbits right"], move("arc", "right"))
        add(["arc", "arcs", "arcing"], move("arc", nil))
        add(["orbit", "orbits", "orbiting", "circles", "circling", "circle around"]) { q in move("arc", nil)(&q); q.relations.insert("orbit") }

        add(["static", "still", "no movement", "not moving", "stationary", "fixed"]) { $0.wantsStatic = true }
        add(["locked off", "lock off", "tripod", "on sticks"]) { $0.wantsStatic = true; $0.stability = .lockedOff }
        add(["handheld", "hand held", "shaky", "shaky cam", "shoulder"]) { $0.stability = .handheld }
        add(["gimbal", "steadicam", "stabilised", "stabilized", "smooth", "drone"]) { $0.stability = .stabilised }

        add(["slow", "slowly", "gentle", "gently", "subtle", "creeping"]) { $0.speed = "slow" }
        add(["medium", "moderate", "steady"]) { $0.speed = "medium" }
        add(["fast", "quick", "quickly", "rapid", "rapidly", "whip", "snap"]) { $0.speed = "fast" }

        add(["tracking", "tracking shot"]) { $0.relations.insert("tracking") }
        add(["following", "follows", "follow", "follow shot"]) { $0.relations.insert("following") }
        add(["leading", "leads"]) { $0.relations.insert("leading") }
        add(["reveal", "reveals", "revealing"]) { $0.relations.insert("reveal") }
        add(["reframe", "reframes", "reframing"]) { $0.relations.insert("reframing") }

        return table.sorted { $0.0.count > $1.0.count }
    }()
}
