import Foundation

/// Optional second stage: sends the raw transcript to a local Ollama server
/// for cleanup (punctuation, capitalization, filler removal). Mirrors
/// WhisperFlow's downstream fine-tuned-Llama pass, but fully local.
///
/// Degrades gracefully: if Ollama is unreachable or errors, callers fall
/// back to the raw transcript.
struct OllamaCleaner {
    static let baseURL = URL(string: "http://localhost:11434")!

    private static let systemPrompt = """
    You are a transcript cleaner. You receive raw speech-to-text output. \
    Fix punctuation and capitalization, remove filler words (um, uh, like, you know), \
    remove false starts and repeated words, and format lists as lists when the speaker \
    clearly dictates one. Do not change the meaning, do not add content, do not answer \
    questions in the transcript. Output ONLY the cleaned text, with no commentary, \
    no quotes, and no preamble.
    """

    /// Quick reachability probe with a short timeout.
    static func isAvailable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    static func clean(_ rawText: String, model: String) async throws -> String {
        struct GenerateRequest: Encodable {
            let model: String
            let system: String
            let prompt: String
            let stream: Bool
            let options: Options

            struct Options: Encodable {
                let temperature: Double
            }
        }
        struct GenerateResponse: Decodable {
            let response: String
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A cold Ollama model load routinely takes >20s with zero bytes; this
        // is an idle timeout, so keep it generous or cleanup silently drops out.
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(GenerateRequest(
            model: model,
            system: systemPrompt,
            prompt: rawText,
            stream: false,
            options: .init(temperature: 0.1)
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let cleaned = try JSONDecoder().decode(GenerateResponse.self, from: data)
            .response
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A cleaner that returns nothing (or balloons the text) has misfired.
        guard !cleaned.isEmpty, cleaned.count < rawText.count * 3 + 64 else {
            return rawText
        }
        return cleaned
    }
}
