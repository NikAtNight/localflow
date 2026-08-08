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
    // One CoreML pipeline construction at a time: rapid model switches could
    // otherwise build several multi-hundred-MB pipelines concurrently.
    private let loadGate = TranscriptionGate()
    private var vocabularyText = ""
    private var vocabularyTokens: [Int]?

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

        await loadGate.acquire()
        // A newer load was requested while this one queued; let it win
        // without building (and briefly double-retaining) a stale pipeline.
        guard generation == loadGeneration else {
            await loadGate.release()
            return
        }

        // With only `model` and `downloadBase`, WhisperKit 0.18 downloads the
        // model but leaves CoreML unloaded until the first transcription.
        // Load now so the app's ready state is truthful and the first hotkey
        // release does not pay model initialization latency.
        let cachedFolder = Self.cachedModelFolder(for: model)
        let pipe: WhisperKit
        do {
            if let cachedFolder {
                do {
                    pipe = try await WhisperKit(Self.config(modelFolder: cachedFolder))
                } catch {
                    // Directory presence is only a fast completeness signal. If
                    // CoreML or tokenizer loading finds corruption, let the Hub
                    // path verify/repair the cache instead of stranding startup.
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
        } catch {
            await loadGate.release()
            throw error
        }
        await loadGate.release()

        // The actor is reentrant across those awaits: a later load may have
        // started (and even finished) meanwhile. Last requested wins.
        guard generation == loadGeneration else { return }
        whisperKit = pipe
        loadedModel = model
        refreshVocabularyTokens()
    }

    /// Names and jargon to bias decoding toward (people, products,
    /// acronyms). Encoded with the loaded model's tokenizer and fed to the
    /// decoder as preceding context on every transcription.
    func setVocabulary(_ terms: String) {
        vocabularyText = terms
        refreshVocabularyTokens()
    }

    private func refreshVocabularyTokens() {
        let trimmed = vocabularyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let tokenizer = whisperKit?.tokenizer else {
            vocabularyTokens = nil
            return
        }
        // Whisper treats promptTokens as text that came before, so phrase
        // the vocabulary as prose it might continue. Capped: heavy bias
        // makes the decoder hallucinate the vocabulary into silence.
        let tokens = tokenizer.encode(text: " Glossary: \(trimmed).")
        vocabularyTokens = tokens.isEmpty ? nil : Array(tokens.prefix(96))
    }

    private func currentDecodingOptions() -> DecodingOptions {
        var options = Self.decodingOptions
        if let vocabularyTokens {
            options.promptTokens = vocabularyTokens
        }
        return options
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
        guard whisperKit != nil else { throw TranscriberError.notLoaded }
        await transcriptionGate.acquire()
        // Snapshot pipeline + options together AFTER the gate: a model
        // switch while queued regenerates the vocabulary tokens, and the
        // old pipeline must never decode with the new model's token IDs.
        guard let whisperKit else {
            await transcriptionGate.release()
            throw TranscriberError.notLoaded
        }
        let options = currentDecodingOptions()
        let results: [TranscriptionResult]
        do {
            results = try await whisperKit.transcribe(
                audioArray: samples,
                decodeOptions: options
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
            // the field; the raw hypothesis SIZE tells whether Whisper
            // returned nothing or post-processing ate a real result. Never
            // log the content itself — the diag file must stay free of
            // dictated text.
            let raw = results.map(\.text).joined(separator: " ")
            DiagLog.log("[diag] empty transcript: rawChars=%d segments=%d lowEnergy=%d",
                  raw.count, results.count, lowEnergy ? 1 : 0)
        }
        if isHallucination { return "" }
        return text
    }

    /// Transcribes an audio file (any AVFoundation-readable format).
    /// Used by the `--transcribe` CLI mode for testing and benchmarking.
    func transcribe(file path: String) async throws -> String {
        guard whisperKit != nil else { throw TranscriberError.notLoaded }
        await transcriptionGate.acquire()
        guard let whisperKit else {
            await transcriptionGate.release()
            throw TranscriberError.notLoaded
        }
        let options = currentDecodingOptions()
        let results: [TranscriptionResult]
        do {
            results = try await whisperKit.transcribe(
                audioPath: path,
                decodeOptions: options
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
        // Don't decode <|...|> markers into the transcript at all (the
        // regex stripper below stays as a second line of defense).
        options.skipSpecialTokens = true
        options.suppressBlank = true
        // Chunk long captures at detected speech gaps instead of blind 30s
        // windows: fewer mid-word window boundaries on multi-minute
        // dictations. Timestamps stay ON: paragraph detection needs them.
        options.chunkingStrategy = .vad
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
        joinSegments(results.flatMap { result in
            result.segments.map { (text: $0.text, start: $0.start, end: $0.end) }
        })
    }

    /// A long silence between segments is the speaker moving to a new
    /// thought, so insert a paragraph break there so dictated text doesn't
    /// come out as one wall of prose. Conservative on purpose: the previous
    /// segment must end a sentence (a thinking pause mid-sentence is not a
    /// paragraph), and the gap must be well beyond a breath.
    static let paragraphPauseSeconds: Float = 1.75

    static func joinSegments(_ segments: [(text: String, start: Float, end: Float)]) -> String {
        var output = ""
        var previousEnd: Float?
        for segment in segments {
            let text = stripSpecialTokens(from: segment.text)
            // Empty segments (markers, silence) don't move `previousEnd`:
            // the silence they span still counts toward the pause.
            guard !text.isEmpty else { continue }
            if !output.isEmpty {
                if let previousEnd,
                   segment.start - previousEnd >= paragraphPauseSeconds,
                   endsSentence(output) {
                    output += "\n\n"
                } else {
                    output += " "
                }
            }
            output += text
            previousEnd = segment.end
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last == "." || last == "!" || last == "?" || last == "…"
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
