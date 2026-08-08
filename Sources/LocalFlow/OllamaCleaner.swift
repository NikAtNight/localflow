import Foundation

/// Optional second stage: sends the raw transcript to a local Ollama server
/// for cleanup (punctuation, capitalization, filler removal). Mirrors
/// WhisperFlow's downstream fine-tuned-Llama pass, but fully local.
///
/// Degrades gracefully: if Ollama is unreachable or errors, callers fall
/// back to the raw transcript.
struct OllamaCleaner {
    static let baseURL = URL(string: "http://localhost:11434")!

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


    /// Quick reachability probe with a short timeout.
    static func isAvailable() async -> Bool {
        // /api/version is constant-size; /api/tags grows with every installed
        // model and needlessly downloads that list just to test the server.
        var request = URLRequest(url: baseURL.appendingPathComponent("api/version"))
        request.timeoutInterval = 2
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    static func clean(
        _ rawText: String,
        model: String,
        profile: AppStyleProfile = .general
    ) async throws -> String {
        struct GenerateRequest: Encodable {
            let model: String
            let system: String
            let prompt: String
            let stream: Bool
            let think: Bool
            let options: Options

            struct Options: Encodable {
                let temperature: Double
                let numPredict: Int

                enum CodingKeys: String, CodingKey {
                    case temperature
                    case numPredict = "num_predict"
                }
            }
        }
        struct GenerateResponse: Decodable {
            let response: String
            let doneReason: String?

            enum CodingKeys: String, CodingKey {
                case response
                case doneReason = "done_reason"
            }
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A cold Ollama model load routinely takes >20s with zero bytes. Keep
        // the idle timeout above that while still falling back to raw text if
        // the local server stalls; the session adds a 120s absolute ceiling.
        request.timeoutInterval = 45
        request.httpBody = try JSONEncoder().encode(GenerateRequest(
            model: model,
            system: TranscriptCleanup.instructions(for: profile),
            prompt: rawText,
            stream: false,
            think: false,
            options: .init(
                temperature: 0.1,
                // Cleanup should never need materially more tokens than the
                // source. This prevents a misbehaving model from generating
                // indefinitely; a length stop falls back to the raw transcript.
                numPredict: max(128, min(2_048, rawText.utf8.count / 2 + 64))
            )
        ))

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw CleanerError.httpStatus(status) }

        let result = try JSONDecoder().decode(GenerateResponse.self, from: data)
        guard result.doneReason != "length" else { return rawText }
        return TranscriptCleanup.validated(result.response, raw: rawText)
    }
}
