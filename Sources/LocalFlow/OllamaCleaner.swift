import Foundation

enum OllamaClientError: Error, Equatable, LocalizedError {
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status):
            return "Ollama returned HTTP \(status)"
        }
    }
}

/// The Ollama HTTP boundary. The URL session is injected so tests can run the
/// real request encoding, status handling, decoding, and timeout behavior.
final class OllamaClient: @unchecked Sendable {
    private struct GenerateResponse: Decodable {
        let response: String
        let doneReason: String?

        enum CodingKeys: String, CodingKey {
            case response
            case doneReason = "done_reason"
        }
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable {
            let name: String
        }

        let models: [Model]
    }

    private struct PrewarmRequest: Encodable {
        let model: String
        let keepAlive: String

        enum CodingKeys: String, CodingKey {
            case model
            case keepAlive = "keep_alive"
        }
    }

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession) {
        self.baseURL = baseURL
        self.session = session
    }

    convenience init(baseURL: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 120
        self.init(baseURL: baseURL, session: URLSession(configuration: configuration))
    }

    func generate(_ body: OllamaCleaner.GenerateRequest) async throws -> TextModelGeneration {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        let encodedBody = try JSONEncoder().encode(body)
        request.httpBody = encodedBody

        let (data, response) = try await session.data(for: request)
        try requireSuccess(response)
        let result = try JSONDecoder().decode(GenerateResponse.self, from: data)
        return TextModelGeneration(
            text: result.response,
            finishReason: result.doneReason == "length" ? .length : .complete
        )
    }

    func probe() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/version"))
        request.timeoutInterval = 2
        let (_, response) = try await session.data(for: request)
        try requireSuccess(response)
    }

    func isAvailable() async -> Bool {
        do {
            try await probe()
            return true
        } catch {
            return false
        }
    }

    func installedModels() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        let (data, response) = try await session.data(for: request)
        try requireSuccess(response)
        let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
        return tags.models
            .map { $0.name.hasSuffix(":latest") ? String($0.name.dropLast(":latest".count)) : $0.name }
            .sorted { first, second in
                if first == "s1-mini" { return true }
                if second == "s1-mini" { return false }
                return first < second
            }
    }

    func prewarm(model: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        request.httpBody = try JSONEncoder().encode(
            PrewarmRequest(model: model, keepAlive: OllamaCleaner.keepAlive)
        )
        let (_, response) = try await session.data(for: request)
        try requireSuccess(response)
    }

    private func requireSuccess(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw OllamaClientError.httpStatus(status) }
    }
}

@MainActor
final class OllamaLocalTextModelBackend: OllamaTextModelBackend {
    private let client: OllamaClient

    init(client: OllamaClient = OllamaClient(baseURL: OllamaCleaner.baseURL)) {
        self.client = client
    }

    func cleanup(
        _ text: String,
        model: String,
        profile: AppStyleProfile
    ) async throws -> TextModelGeneration {
        try await client.generate(OllamaCleaner.generateRequest(text, model: model, profile: profile))
    }

    func command(
        system: String,
        prompt: String,
        model: String,
        reasoning: ReasoningLevel
    ) async throws -> TextModelGeneration {
        try await client.generate(OllamaCleaner.respondRequest(
            system: system,
            prompt: prompt,
            model: model,
            reasoning: reasoning
        ))
    }

    func prewarm(model: String) async {
        try? await client.prewarm(model: model)
    }

    func probe() async throws {
        try await client.probe()
    }

    func installedModels() async throws -> [String] {
        try await client.installedModels()
    }
}

/// Compatibility entry points for existing UI and command-line callers. New
/// backend choice and fallback decisions belong in `LocalTextModelPolicy`.
@MainActor
struct OllamaCleaner {
    nonisolated static let baseURL = URL(string: "http://localhost:11434")!
    nonisolated static let keepAlive = "30m"

    static var lastKnownReachable: Bool {
        LocalTextModelPolicy.shared.ollamaReachability == .reachable
    }

    static func installedModels() async -> [String] {
        await LocalTextModelPolicy.shared.installedOllamaModels()
    }

    static func isAvailable() async -> Bool {
        await LocalTextModelPolicy.shared.probeOllama()
    }

    /// Ollama's `think` takes a bool for toggle-based models or a level string
    /// for models such as gpt-oss.
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

    /// s1-mini gets its trained normalization protocol. Other models get the
    /// general cleanup instructions.
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
                numPredict: max(128, min(2_048, rawText.utf8.count / 2 + 64))
            )
        )
    }

    static func respondRequest(
        system: String,
        prompt: String,
        model: String,
        reasoning: ReasoningLevel
    ) -> GenerateRequest {
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
        try await LocalTextModelPolicy.shared.ollamaCleanup(
            rawText,
            model: model,
            profile: profile
        )
    }

    static func prewarm(model: String) async {
        await LocalTextModelPolicy.shared.prewarm(model: model)
    }

    static func respond(
        system: String,
        prompt: String,
        model: String,
        reasoning: ReasoningLevel
    ) async throws -> String {
        try await LocalTextModelPolicy.shared.ollamaCommand(
            system: system,
            prompt: prompt,
            model: model,
            reasoning: reasoning
        ) ?? ""
    }
}
