import Foundation
import WhisperKit

/// A one-permit FIFO gate. WhisperKit's inference entry point is async but
/// mutates shared decoder/progress state, so actor reentrancy alone is not a
/// sufficient serialization boundary.
actor TranscriptionGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !occupied {
            occupied = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else {
            occupied = false
            return
        }
        waiters.removeFirst().resume()
    }

    var waitingCount: Int { waiters.count }
}

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
    private let transcriptionGate = TranscriptionGate()

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

        // With only `model` and `downloadBase`, WhisperKit 0.18 downloads the
        // model but leaves CoreML unloaded until the first transcription.
        // Load now so the app's ready state is truthful and the first hotkey
        // release does not pay model initialization latency.
        let cachedFolder = Self.cachedModelFolder(for: model)
        let pipe: WhisperKit
        if let cachedFolder {
            do {
                pipe = try await WhisperKit(Self.config(modelFolder: cachedFolder))
            } catch {
                // Directory presence is only a fast completeness signal. If
                // CoreML or tokenizer loading finds corruption, let the Hub
                // path verify/repair the cache instead of stranding startup.
                guard generation == loadGeneration else { return }
                DiagLog.log(
                    "cached model %@ failed to load (%@) — resolving through model registry",
                    model,
                    error.localizedDescription
                )
                pipe = try await WhisperKit(Self.config(model: model))
            }
        } else {
            pipe = try await WhisperKit(Self.config(model: model))
        }

        // The actor is reentrant across that await: a later load may have
        // started (and even finished) meanwhile. Last requested wins.
        guard generation == loadGeneration else { return }
        whisperKit = pipe
        loadedModel = model
    }

    private static func config(model: String) -> WhisperKitConfig {
        WhisperKitConfig(
            model: model,
            downloadBase: modelDownloadBase,
            verbose: false,
            load: true
        )
    }

    private static func config(modelFolder: URL) -> WhisperKitConfig {
        WhisperKitConfig(
            downloadBase: modelDownloadBase,
            modelFolder: modelFolder.path,
            verbose: false,
            load: true
        )
    }

    /// Bypass Hub resolution when a complete model is already present. A
    /// partial/interrupted download falls through to WhisperKit's downloader.
    private static func cachedModelFolder(for model: String) -> URL? {
        let folder = modelDownloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(model, isDirectory: true)
        let requiredModels = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        let complete = requiredModels.allSatisfy { name in
            ["mlmodelc", "mlpackage"].contains { ext in
                FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent("\(name).\(ext)", isDirectory: true).path
                )
            }
        }
        return complete ? folder : nil
    }

    /// `lowEnergy` marks audio whose RMS was near silence: Whisper reliably
    /// invents filler for such clips, so canonical hallucination phrases are
    /// treated as an empty transcript. Never applied to normal-energy audio —
    /// people legitimately dictate "thank you".
    func transcribe(samples: [Float], lowEnergy: Bool = false) async throws -> String {
        guard let whisperKit else { throw TranscriberError.notLoaded }
        await transcriptionGate.acquire()
        let results: [TranscriptionResult]
        do {
            results = try await whisperKit.transcribe(
                audioArray: samples,
                decodeOptions: Self.decodingOptions
            )
            await transcriptionGate.release()
        } catch {
            await transcriptionGate.release()
            throw error
        }
        let text = Self.finalize(results)
        let isHallucination = lowEnergy && Self.isCanonicalHallucination(text)
        if text.isEmpty || isHallucination {
            // A healthy-audio dictation has produced an empty transcript in
            // the field; the raw hypothesis tells whether Whisper returned
            // nothing or post-processing ate a real result.
            let raw = results.map(\.text).joined(separator: " ")
            DiagLog.log("[diag] empty transcript: raw=\"%@\" segments=%d lowEnergy=%d",
                  String(raw.prefix(160)), results.count, lowEnergy ? 1 : 0)
        }
        if isHallucination { return "" }
        return text
    }

    /// Transcribes an audio file (any AVFoundation-readable format).
    /// Used by the `--transcribe` CLI mode for testing and benchmarking.
    func transcribe(file path: String) async throws -> String {
        guard let whisperKit else { throw TranscriberError.notLoaded }
        await transcriptionGate.acquire()
        let results: [TranscriptionResult]
        do {
            results = try await whisperKit.transcribe(
                audioPath: path,
                decodeOptions: Self.decodingOptions
            )
            await transcriptionGate.release()
        } catch {
            await transcriptionGate.release()
            throw error
        }
        return Self.finalize(results)
    }

    private static let decodingOptions: DecodingOptions = {
        var options = DecodingOptions()
        options.task = .transcribe
        options.temperature = 0
        options.language = "en"
        return options
    }()

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
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let withoutMarkers = specialTokenRegex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: ""
        )
        let cleanedRange = NSRange(withoutMarkers.startIndex..<withoutMarkers.endIndex, in: withoutMarkers)
        return repeatedSpacesRegex.stringByReplacingMatches(
            in: withoutMarkers,
            range: cleanedRange,
            withTemplate: " "
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let specialTokenRegex = try! NSRegularExpression(
        pattern: #"\[[A-Z_ ]+\]|(?i:\((?:music|laughs|laughter|applause|noise|silence|inaudible|coughs)\))|<[^>]*>"#
    )
    private static let repeatedSpacesRegex = try! NSRegularExpression(pattern: " {2,}")
}
