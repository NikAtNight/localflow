import Foundation

/// Optional second stage: sends the raw transcript to a local Ollama server
/// for cleanup (punctuation, capitalization, filler removal). Mirrors
/// WhisperFlow's downstream fine-tuned-Llama pass, but fully local.
///
/// Degrades gracefully: if Ollama is unreachable or errors, callers fall
/// back to the raw transcript.
@MainActor
struct OllamaCleaner {
    static let baseURL = URL(string: "http://localhost:11434")!
    private static let keepAlive = "30m"
    private static var lastPrewarmByModel: [String: Date] = [:]

    private enum CleanerError: LocalizedError {
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .httpStatus(let status):
                return "Ollama returned HTTP \(status)"
            }
        }
    }

    // Reuse the local connection, fail a server that stops making progress,
    // and put an absolute ceiling on cleanup. The resource timeout matters
    // because URLSession.shared otherwise permits a request to live for days.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()


    /// Last observed server state, updated by probes and by every real
    /// request. Synchronous availability checks (the command-mode hotkey
    /// gate) need an answer without a network round trip; false only means
    /// "not seen yet", and callers still handle a server dying mid-call.
    private(set) static var lastKnownReachable = false

    /// Installed models, for the settings pickers. Empty when the server is
    /// unreachable; the UI falls back to a plain text field so a model can
    /// still be named before Ollama is set up.
    static func installedModels() async -> [String] {
        struct TagsResponse: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let tags = try? JSONDecoder().decode(TagsResponse.self, from: data)
        else { return [] }
        // ":latest" is noise in a picker, and Ollama resolves the bare name
        // to the same model. s1-mini leads because it's the shipped default.
        return tags.models
            .map { $0.name.hasSuffix(":latest") ? String($0.name.dropLast(":latest".count)) : $0.name }
            .sorted { a, b in
                if a == "s1-mini" { return true }
                if b == "s1-mini" { return false }
                return a < b
            }
    }

    /// Quick reachability probe with a short timeout.
    static func isAvailable() async -> Bool {
        // /api/version is constant-size; /api/tags grows with every installed
        // model and needlessly downloads that list just to test the server.
        var request = URLRequest(url: baseURL.appendingPathComponent("api/version"))
        request.timeoutInterval = 2
        do {
            let (_, response) = try await session.data(for: request)
            lastKnownReachable = (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            lastKnownReachable = false
        }
        return lastKnownReachable
    }

    /// Ollama's `think` takes a bool (qwen3-style toggle) or a level string
    /// ("low"/"medium"/"high", gpt-oss style).
    enum ThinkValue: Encodable, Equatable {
        case bool(Bool)
        case level(String)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .bool(let flag): try container.encode(flag)
            case .level(let level): try container.encode(level)
            }
        }
    }

    struct GenerateRequest: Encodable {
        let model: String
        let keepAlive: String
        let system: String
        let prompt: String
        let stream: Bool
        // Always present, never omitted: Ollama classifies s1-mini as a
        // thinking model from its qwen3 architecture (the Modelfile's
        // baked-in empty think block doesn't override that), and without
        // an explicit false the server's think handling yields an empty
        // response or a leaked "<think>" tag as the whole transcript.
        let think: ThinkValue
        let options: Options

        enum CodingKeys: String, CodingKey {
            case model
            case keepAlive = "keep_alive"
            case system
            case prompt
            case stream
            case think
            case options
        }

        struct Options: Encodable {
            let temperature: Double
            let numPredict: Int

            enum CodingKeys: String, CodingKey {
                case temperature
                case numPredict = "num_predict"
            }
        }
    }

    /// The request body, split out so tests can pin the shape each model
    /// class requires. s1-mini gets its trained protocol (fixed system
    /// prompt, control line, greedy decoding); everything else gets the
    /// instruct-style cleanup prompt.
    static func generateRequest(
        _ rawText: String,
        model: String,
        profile: AppStyleProfile
    ) -> GenerateRequest {
        let isS1Mini = S1MiniCleanup.matches(model: model)
        return GenerateRequest(
            model: model,
            keepAlive: keepAlive,
            system: isS1Mini ? S1MiniCleanup.systemPrompt : TranscriptCleanup.instructions(for: profile),
            prompt: isS1Mini ? S1MiniCleanup.prompt(for: rawText, profile: profile) : rawText,
            stream: false,
            think: .bool(false),
            options: .init(
                temperature: isS1Mini ? 0 : 0.1,
                // Cleanup should never need materially more tokens than the
                // source. This prevents a misbehaving model from generating
                // indefinitely; a length stop falls back to the raw transcript.
                numPredict: max(128, min(2_048, rawText.utf8.count / 2 + 64))
            )
        )
    }

    static func clean(
        _ rawText: String,
        model: String,
        profile: AppStyleProfile = .general
    ) async throws -> String {
        try await cleanResult(rawText, model: model, profile: profile).text
    }

    static func cleanResult(
        _ rawText: String,
        model: String,
        profile: AppStyleProfile = .general
    ) async throws -> TranscriptCleanupResult {
        let result = try await send(generateRequest(rawText, model: model, profile: profile))
        guard result.doneReason != "length" else {
            return TranscriptCleanupResult(text: rawText, succeeded: false)
        }
        return TranscriptCleanup.validationResult(result.response, raw: rawText)
    }

    /// The command-mode request: an arbitrary instruction against a general
    /// instruct model (s1-mini can't serve this; it only understands its
    /// control line). Generated text can legitimately outgrow the prompt
    /// ("write a thank-you note"), so the budget is a flat cap.
    static func respondRequest(
        system: String,
        prompt: String,
        model: String,
        reasoning: ReasoningLevel
    ) -> GenerateRequest {
        // gpt-oss models take a level string; other thinking models (qwen3
        // family) only take a toggle, so any level short of off means "on".
        // Models without a thinking mode ignore a false but reject levels,
        // so off must stay the safe default.
        let think: ThinkValue
        switch reasoning {
        case .off:
            think = .bool(false)
        case .low, .medium, .high:
            think = model.lowercased().contains("gpt-oss")
                ? .level(reasoning.rawValue)
                : .bool(true)
        }
        return GenerateRequest(
            model: model,
            keepAlive: keepAlive,
            system: system,
            prompt: prompt,
            stream: false,
            think: think,
            options: .init(temperature: 0.3, numPredict: 2_048)
        )
    }

    /// Starts loading the model before the user finishes speaking. Failed
    /// prewarms stay silent because the real request reports reachability.
    static func prewarm(model: String) async {
        let now = Date()
        guard lastPrewarmByModel[model].map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
        lastPrewarmByModel[model] = now

        struct PrewarmRequest: Encodable {
            let model: String
            let keepAlive: String

            enum CodingKeys: String, CodingKey {
                case model
                case keepAlive = "keep_alive"
            }
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        request.httpBody = try? JSONEncoder().encode(
            PrewarmRequest(model: model, keepAlive: keepAlive))

        _ = try? await session.data(for: request)
    }

    /// Runs a command-mode instruction. Returns "" when the model stopped at
    /// the length cap: half a rewrite pasted over a selection is worse than
    /// the caller's fallback (the untouched selection).
    static func respond(
        system: String,
        prompt: String,
        model: String,
        reasoning: ReasoningLevel
    ) async throws -> String {
        let result = try await send(respondRequest(
            system: system, prompt: prompt, model: model, reasoning: reasoning))
        guard result.doneReason != "length" else { return "" }
        return result.response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct GenerateResponse: Decodable {
        let response: String
        let doneReason: String?

        enum CodingKeys: String, CodingKey {
            case response
            case doneReason = "done_reason"
        }
    }

    private static func send(_ body: GenerateRequest) async throws -> GenerateResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A cold Ollama model load routinely takes >20s with zero bytes. Keep
        // the idle timeout above that while still falling back to raw text if
        // the local server stalls; the session adds a 120s absolute ceiling.
        request.timeoutInterval = 45
        request.httpBody = try JSONEncoder().encode(body)

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw CleanerError.httpStatus(status) }
            lastKnownReachable = true
            return try JSONDecoder().decode(GenerateResponse.self, from: data)
        } catch let error as URLError {
            if error.code != .cancelled {
                lastKnownReachable = false
            }
            throw error
        }
    }
}
