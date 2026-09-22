import Foundation

/// Gemini `generateContent` with the proxy inlined as native video.
public struct GeminiTagger: Tagger {
    public var apiKey: String
    public var model: String
    public var session: URLSession

    public init(apiKey: String, model: String = Settings.model, session: URLSession = .shared) {
        self.apiKey = apiKey; self.model = model; self.session = session
    }

    public func describe(_ request: TagRequest) async throws -> TagResult {
        let video = try Data(contentsOf: request.proxy)
        guard video.count < 14_000_000 else { throw MotifError.tagging("proxy too large to inline (\(video.count / 1_000_000) MB)") }

        // Optional tuning fields are dropped one at a time if the API rejects them, so a renamed knob degrades cost,
        // not function.
        var optional: Set<String> = ["thinking", "mediaResolution", "fps"]
        var attempt = 0
        while true {
            attempt += 1
            let (data, status) = try await post(body(video: video, request: request, optional: optional))
            switch status {
            case 200:
                return try parse(data)
            case 400:
                let message = Self.errorMessage(data)
                let lower = message.lowercased()
                if let drop = [("thinking", "thinking"), ("mediaresolution", "mediaResolution"), ("media_resolution", "mediaResolution"),
                               ("videometadata", "fps"), ("video_metadata", "fps"), ("fps", "fps")]
                    .first(where: { lower.contains($0.0) && optional.contains($0.1) })?.1 {
                    optional.remove(drop)
                    continue
                }
                throw MotifError.tagging("Gemini rejected the request: \(message)")
            case 429, 500, 502, 503, 504:
                if attempt >= 6 { throw MotifError.tagging("Gemini unavailable (HTTP \(status)): \(Self.errorMessage(data))") }
                try await Task.sleep(for: .seconds(min(60, pow(2, Double(attempt))) + Double.random(in: 0...1)))
            case 401, 403:
                throw MotifError.tagging("Gemini refused the API key (HTTP \(status)): \(Self.errorMessage(data))")
            default:
                throw MotifError.tagging("Gemini HTTP \(status): \(Self.errorMessage(data))")
            }
        }
    }

    func body(video: Data, request: TagRequest, optional: Set<String>) -> [String: Any] {
        var videoPart: [String: Any] = ["inlineData": ["mimeType": "video/mp4", "data": video.base64EncodedString()]]
        // The proxy is already thinned to ~24 frames; ask for every one of them rather than the default 1 fps.
        if optional.contains("fps") { videoPart["videoMetadata"] = ["fps": max(0.25, min(8, request.proxyFPS))] }

        var generation: [String: Any] = [
            "responseMimeType": "application/json",
            "responseSchema": TagPrompt.schema,
            "temperature": 0.2,
            "maxOutputTokens": 400,
        ]
        if optional.contains("mediaResolution") { generation["mediaResolution"] = "MEDIA_RESOLUTION_LOW" }
        // Thinking tokens are billed as output, and output dominates the cost of a clip.
        if optional.contains("thinking") { generation["thinkingConfig"] = ["thinkingLevel": "minimal"] }

        // Footage legitimately contains violence, blood and nudity; a filter hit must not leave a clip unlogged.
        let safety = ["HARM_CATEGORY_HARASSMENT", "HARM_CATEGORY_HATE_SPEECH", "HARM_CATEGORY_SEXUALLY_EXPLICIT", "HARM_CATEGORY_DANGEROUS_CONTENT"]
            .map { ["category": $0, "threshold": "BLOCK_NONE"] }

        return [
            "systemInstruction": ["parts": [["text": TagPrompt.system]]],
            "contents": [["role": "user", "parts": [videoPart, ["text": TagPrompt.user(for: request)]]]],
            "generationConfig": generation,
            "safetySettings": safety,
        ]
    }

    func post(_ body: [String: Any]) async throws -> (Data, Int) {
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func parse(_ data: Data) throws -> TagResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MotifError.tagging("unreadable response")
        }
        if let feedback = root["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
            throw MotifError.blocked("blocked by the model's safety filter (\(reason))")
        }
        let candidate = (root["candidates"] as? [[String: Any]])?.first
        let finish = candidate?["finishReason"] as? String ?? ""
        let text = ((candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]])?
            .compactMap { $0["text"] as? String }.joined() ?? ""
        if text.isEmpty {
            if ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "IMAGE_SAFETY"].contains(finish) {
                throw MotifError.blocked("blocked by the model's safety filter (\(finish))")
            }
            throw MotifError.tagging("empty response (finishReason: \(finish.isEmpty ? "none" : finish))")
        }
        guard var result = try? JSONDecoder().decode(TagResult.self, from: Data(text.utf8)) else {
            throw MotifError.tagging("response was not the expected JSON: \(text.prefix(200))")
        }
        let usage = root["usageMetadata"] as? [String: Any]
        result.model = model
        result.tokensIn = usage?["promptTokenCount"] as? Int ?? 0
        result.tokensOut = (usage?["candidatesTokenCount"] as? Int ?? 0) + (usage?["thoughtsTokenCount"] as? Int ?? 0)
        return result
    }

    static func errorMessage(_ data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = root["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return String(data: data.prefix(300), encoding: .utf8) ?? "no detail"
    }

    /// A one-token request that proves the key and model ID work.
    public func verify() async throws {
        let body: [String: Any] = ["contents": [["parts": [["text": "Reply with OK."]]]], "generationConfig": ["maxOutputTokens": 8]]
        let (data, status) = try await post(body)
        guard status == 200 else { throw MotifError.tagging("HTTP \(status): \(Self.errorMessage(data))") }
    }
}

/// Deterministic stand-in so the pipeline and the UI can be exercised without a key or a network.
public struct FakeTagger: Tagger {
    public init() {}

    public func describe(_ request: TagRequest) async throws -> TagResult {
        try await Task.sleep(for: .milliseconds(150))
        let first = request.motionHint.split(separator: "\n").first.map(String.init) ?? "static"
        return TagResult(description: "Placeholder description — add a Gemini API key in Settings to describe this clip.",
                         movementText: first, shotSize: "MS", subjectRelation: "none", model: "fake", tokensIn: 0, tokensOut: 0)
    }
}
