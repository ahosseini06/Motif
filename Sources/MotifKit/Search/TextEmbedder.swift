import Foundation
import NaturalLanguage

/// Apple's on-device sentence embedding: free, instant, offline. Vectors are unit length.
public final class TextEmbedder: @unchecked Sendable {
    public static let shared = TextEmbedder()
    public static let modelName = "apple-nl-sentence-en"

    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)
    private let lock = NSLock()

    public var isAvailable: Bool { embedding != nil }

    private let words = NLEmbedding.wordEmbedding(for: .english)
    private var wordCache: [String: [Float]?] = [:]

    /// Unit word vector, or nil for words the model doesn't know (names, jargon).
    public func wordVector(for word: String) -> [Float]? {
        lock.withLock {
            if let cached = wordCache[word] { return cached }
            var result: [Float]?
            if let raw = words?.vector(for: word) {
                let norm = raw.reduce(0) { $0 + $1 * $1 }.squareRoot()
                if norm > 0 { result = raw.map { Float($0 / norm) } }
            }
            wordCache[word] = result
            return result
        }
    }

    public func vector(for text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let embedding else { return nil }
        guard let raw = lock.withLock({ embedding.vector(for: trimmed) }) else { return nil }
        var norm = 0.0
        for v in raw { norm += v * v }
        norm = norm.squareRoot()
        guard norm > 0 else { return nil }
        return raw.map { Float($0 / norm) }
    }
}

func dot(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count else { return 0 }
    var sum: Float = 0
    for i in a.indices { sum += a[i] * b[i] }
    return sum
}
