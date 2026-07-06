import Foundation
import WhisperKit

/// Wraps WhisperKit: loads a CoreML Whisper model (downloaded on first use
/// from the argmaxinc/whisperkit-coreml registry) and transcribes 16 kHz
/// mono Float32 sample buffers.
actor Transcriber {
    enum TranscriberError: Error, LocalizedError {
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notLoaded: return "Whisper model is not loaded yet."
            }
        }
    }

    private var whisperKit: WhisperKit?
    private(set) var loadedModel: String?
    private var loadGeneration = 0

    var isLoaded: Bool { whisperKit != nil }

    /// Where models are downloaded to. ~/Documents (WhisperKit's default) is
    /// iCloud-synced on many Macs, and "Optimize Mac Storage" can evict the
    /// 500 MB model files to dataless stubs — mysterious load failures.
    /// Migrates the pre-existing cache out of Documents once.
    private static let modelDownloadBase: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalFlow", isDirectory: true)
        let repoPath = "models/argmaxinc/whisperkit-coreml"
        let old = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/\(repoPath)")
        let new = base.appendingPathComponent(repoPath)
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
            do {
                try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: old, to: new)
                DiagLog.log("moved model cache out of ~/Documents to %@", new.path)
            } catch {
                DiagLog.log("model cache migration failed (%@) — will download fresh", error.localizedDescription)
            }
        }
        return base
    }()

    /// Loads (and if needed downloads) the given model. Safe to call again
    /// with a different model name to switch models: the previous pipeline
    /// keeps serving transcriptions until the replacement is actually ready,
    /// so a failed download never strands the app with no model.
    func load(model: String) async throws {
        if loadedModel == model, whisperKit != nil { return }
        loadGeneration += 1
        let generation = loadGeneration

        let config = WhisperKitConfig(model: model, downloadBase: Self.modelDownloadBase)
        let pipe = try await WhisperKit(config)

        // The actor is reentrant across that await: a later load may have
        // started (and even finished) meanwhile. Last requested wins.
        guard generation == loadGeneration else { return }
        whisperKit = pipe
        loadedModel = model
    }

    /// `lowEnergy` marks audio whose RMS was near silence: Whisper reliably
    /// invents filler for such clips, so canonical hallucination phrases are
    /// treated as an empty transcript. Never applied to normal-energy audio —
    /// people legitimately dictate "thank you".
    func transcribe(samples: [Float], lowEnergy: Bool = false) async throws -> String {
        guard let whisperKit else { throw TranscriberError.notLoaded }
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: Self.decodingOptions)
        let text = Self.finalize(results)
        if text.isEmpty || (lowEnergy && Self.isCanonicalHallucination(text)) {
            // A healthy-audio dictation has produced an empty transcript in
            // the field; the raw hypothesis tells whether Whisper returned
            // nothing or post-processing ate a real result.
            let raw = results.map(\.text).joined(separator: " ")
            DiagLog.log("[diag] empty transcript: raw=\"%@\" segments=%d lowEnergy=%d",
                  String(raw.prefix(160)), results.count, lowEnergy ? 1 : 0)
        }
        if lowEnergy, Self.isCanonicalHallucination(text) { return "" }
        return text
    }

    /// Transcribes an audio file (any AVFoundation-readable format).
    /// Used by the `--transcribe` CLI mode for testing and benchmarking.
    func transcribe(file path: String) async throws -> String {
        guard let whisperKit else { throw TranscriberError.notLoaded }
        let results = try await whisperKit.transcribe(audioPath: path, decodeOptions: Self.decodingOptions)
        return Self.finalize(results)
    }

    private static var decodingOptions: DecodingOptions {
        var options = DecodingOptions()
        options.task = .transcribe
        options.temperature = 0
        options.language = "en"
        return options
    }

    /// The transcripts Whisper canonically hallucinates for (near-)silent
    /// audio — trained-in YouTube outro artifacts. Whole-transcript match,
    /// case- and punctuation-insensitive.
    private static let hallucinationPhrases: Set<String> = [
        "thank you", "thanks for watching", "thank you for watching",
        "you", "bye", "thanks",
    ]

    static func isCanonicalHallucination(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return hallucinationPhrases.contains(normalized)
    }

    private static func finalize(_ results: [TranscriptionResult]) -> String {
        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripSpecialTokens(from: text)
    }

    /// Whisper sometimes emits bracketed markers like [BLANK_AUDIO] or (music).
    /// Only strip what looks like a marker — dictated text legitimately
    /// contains brackets and parentheses (e.g. "f(x)").
    static func stripSpecialTokens(from text: String) -> String {
        var result = text
        let patterns = [
            "\\[[A-Z_ ]+\\]",
            "(?i)\\((?:music|laughs|laughter|applause|noise|silence|inaudible|coughs)\\)",
            "<[^>]*>",
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
