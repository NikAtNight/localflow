import Foundation
import WhisperKit

/// Replays one saved recording through the dictation pipeline without opening
/// capture hardware or changing any persisted settings.
@MainActor
enum DictationReplay {
    struct Options: Equatable {
        let path: String
        let runs: Int
        let cleanupEnabled: Bool
        let whisperModel: String
        let ollamaModel: String
        let timingsEnabled: Bool
    }

    enum ReplayError: LocalizedError, Equatable {
        case usage(String)
        case audioTooLong(Double)
        case insufficientVoice
        case timedOut
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .usage(let message): return message
            case .audioTooLong(let seconds):
                return String(format: "Replay input is %.1fs; the limit is 300s.", seconds)
            case .insufficientVoice:
                return "Replay input has less than 0.3 seconds of voiced audio."
            case .timedOut:
                return "Replay did not finish within 180 seconds of release."
            case .failed(let message): return message
            }
        }
    }

    static func parse(arguments: [String]) throws -> Options {
        guard arguments.count >= 2 else {
            throw ReplayError.usage(usage)
        }

        let path = arguments[0]
        guard !path.hasPrefix("--") else { throw ReplayError.usage(usage) }

        var index = 1
        var runs: Int?
        var cleanupEnabled = Settings.cleanupEnabled
        var whisperModel = Settings.whisperModel
        var ollamaModel = Settings.ollamaModel
        var timingsEnabled = true
        var seen = Set<String>()

        while index < arguments.count {
            let option = arguments[index]
            guard seen.insert(option).inserted else { throw ReplayError.usage(usage) }
            switch option {
            case "--no-timing":
                timingsEnabled = false
                index += 1
            case "--no-cleanup", "--cleanup":
                guard !(seen.contains("--no-cleanup") && seen.contains("--cleanup")) else {
                    throw ReplayError.usage(usage)
                }
                cleanupEnabled = option == "--cleanup"
                index += 1
            case "--runs", "--whisper-model", "--ollama-model":
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw ReplayError.usage(usage)
                }
                let value = arguments[index + 1]
                switch option {
                case "--runs":
                    guard let parsed = Int(value), (1...100).contains(parsed) else {
                        throw ReplayError.usage("--runs must be an integer from 1 through 100.\n\(usage)")
                    }
                    runs = parsed
                case "--whisper-model": whisperModel = value
                case "--ollama-model": ollamaModel = value
                default: break
                }
                index += 2
            default:
                throw ReplayError.usage(usage)
            }
        }

        guard let runs else { throw ReplayError.usage(usage) }
        return Options(
            path: path,
            runs: runs,
            cleanupEnabled: cleanupEnabled,
            whisperModel: whisperModel,
            ollamaModel: ollamaModel,
            timingsEnabled: timingsEnabled
        )
    }

    static func run(arguments: [String]) async throws {
        defer { ReplayTimingSink.flush() }
        let options = try parse(arguments: arguments)
        writeStderr(DiagLog.environmentLine() + "\n")
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: options.path)
        let duration = Double(samples.count) / AudioRecorder.sampleRate
        guard duration <= 300 else { throw ReplayError.audioTooLong(duration) }

        let gatedSamples = AudioRecorder.trimmingSilence(samples)
        guard AudioRecorder.voicedMetrics(of: gatedSamples).voicedSeconds >= 0.3 else {
            throw ReplayError.insufficientVoice
        }

        let transcriber = Transcriber()
        let loadStarted = DispatchTime.now().uptimeNanoseconds
        await transcriber.setVocabulary(Settings.effectiveVocabulary)
        try await transcriber.load(model: options.whisperModel)
        writeStderr(
            "replay model load: \(milliseconds(since: loadStarted))ms (\(options.whisperModel))\n"
        )

        let receiver = OutcomeReceiver()
        let pipeline = DictationSessionPipeline(
            transcribe: { request in
                let trimmed = AudioRecorder.trimmingSilence(request.samples)
                guard !trimmed.isEmpty else { return "" }
                let voice = AudioRecorder.voicedMetrics(of: trimmed)
                return try await transcriber.transcribe(
                    samples: trimmed,
                    lowEnergy: voice.voicedDBFS < -40
                )
            },
            cleanup: { request in
                do {
                    return try await LocalTextModelPolicy.shared.cleanup(
                        request.text,
                        model: request.context.ollamaModel,
                        profile: request.context.styleProfile
                    )
                } catch is CancellationError {
                    return TranscriptCleanupResult(text: request.text, succeeded: false)
                } catch {
                    return TranscriptCleanupResult(text: request.text, succeeded: false)
                }
            },
            onOutcome: { outcome in receiver.receive(outcome) }
        )
        let context = DictationSessionContext(
            cleanupEnabled: options.cleanupEnabled,
            styleProfile: .general,
            corrections: Settings.corrections,
            snippets: Settings.snippets,
            ollamaModel: options.ollamaModel
        )

        // Structured prewarm tasks finish before the final log flush, including
        // on failure. They run alongside audio, never in front of its start.
        try await withThrowingTaskGroup(of: Void.self) { prewarms in
            for generation in 1...options.runs {
                let phase = generation == 1
                    ? "first inference in this process; cache state is not asserted"
                    : "later inference in this process; cache state is not asserted"
                writeStderr("replay run \(generation)/\(options.runs): \(phase)\n")
                let trace = options.timingsEnabled
                    ? DictationTrace(source: .replay, sink: { ReplayTimingSink.write($0) }) : nil
                trace?.record(.hotkeyPressed, fields: [.runIndex: Double(generation)], model: options.whisperModel)
                if options.cleanupEnabled {
                    prewarms.addTask {
                        await DictationTrace.$current.withValue(trace) {
                            await LocalTextModelPolicy.shared.prewarm(model: options.ollamaModel)
                        }
                    }
                }
                pipeline.begin(generation: generation, context: context, trace: trace)

                do {
                    try await deliverRealtimeAudio(samples: samples, generation: generation, pipeline: pipeline)
                } catch {
                    pipeline.cancel(generation: generation)
                    throw error
                }
                let releasedAt = DispatchTime.now().uptimeNanoseconds
                trace?.record(.hotkeyReleased, at: releasedAt)
                pipeline.release(generation: generation, fullSamples: samples)

                let timeout = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(180))
                    guard !Task.isCancelled else { return }
                    pipeline.cancel(generation: generation)
                    receiver.fail(generation: generation, error: ReplayError.timedOut)
                }
                let outcome: DictationSessionOutcome
                do {
                    outcome = try await receiver.wait(for: generation)
                } catch {
                    timeout.cancel()
                    throw error
                }
                timeout.cancel()
                switch outcome {
                case .finalTranscript(_, let text):
                    // JSON lines preserve paragraph breaks and identify each run
                    // for accuracy scoring. Transcript data goes only to stdout.
                    var output: [String: Any] = [
                        "run": generation, "text": text,
                        "releaseToResultMs": milliseconds(since: releasedAt)
                    ]
                    if let trace { output["traceID"] = trace.id.uuidString }
                    let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
                    print(String(decoding: data, as: UTF8.self))
                    writeStderr("replay run \(generation)/\(options.runs): complete\n")
                case .emptyTranscript:
                    writeStderr("replay run \(generation)/\(options.runs): empty transcript\n")
                case .failed(_, let message):
                    throw ReplayError.failed(message)
                }
            }
        }
    }

    private static func deliverRealtimeAudio(
        samples: [Float],
        generation: Int,
        pipeline: DictationSessionPipeline
    ) async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        let totalDuration = Double(samples.count) / AudioRecorder.sampleRate
        var tick = DictationSessionPipeline.incrementalStartSeconds
        while tick < totalDuration {
            let target = started + UInt64(tick * 1_000_000_000)
            let now = DispatchTime.now().uptimeNanoseconds
            if now < target {
                try await Task.sleep(nanoseconds: target - now)
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            guard elapsed < totalDuration else { break }
            let available = min(samples.count, Int(elapsed * AudioRecorder.sampleRate))
            pipeline.processIncrementalSnapshot(
                generation: generation,
                samples: Array(samples.prefix(available))
            )
            // Live capture schedules the next tick from the actual callback,
            // not the original deadline. Do not catch up with extra passes.
            tick = elapsed + DictationSessionPipeline.incrementalTickSeconds
        }

        let target = started + UInt64(totalDuration * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        if now < target { try await Task.sleep(nanoseconds: target - now) }
    }

    private static func milliseconds(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    private static func writeStderr(_ text: String) {
        ReplayTimingSink.message(text)
    }

    private static let usage = "Usage: LocalFlow --replay FILE --runs N [--cleanup | --no-cleanup] [--whisper-model NAME] [--ollama-model NAME] [--no-timing]"
}

@MainActor
private final class OutcomeReceiver {
    private var continuations: [Int: CheckedContinuation<DictationSessionOutcome, Error>] = [:]
    private var outcomes: [Int: Result<DictationSessionOutcome, Error>] = [:]

    func wait(for generation: Int) async throws -> DictationSessionOutcome {
        if let result = outcomes.removeValue(forKey: generation) { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[generation] = continuation
        }
    }

    func receive(_ outcome: DictationSessionOutcome) {
        let generation: Int
        switch outcome {
        case .finalTranscript(let value, _), .emptyTranscript(let value), .failed(let value, _):
            generation = value
        }
        resolve(generation: generation, result: .success(outcome))
    }

    func fail(generation: Int, error: Error) {
        resolve(generation: generation, result: .failure(error))
    }

    private func resolve(generation: Int, result: Result<DictationSessionOutcome, Error>) {
        if let continuation = continuations.removeValue(forKey: generation) {
            continuation.resume(with: result)
        } else {
            outcomes[generation] = result
        }
    }
}

private enum ReplayTimingSink {
    private static let queue = DispatchQueue(label: "app.talix.localflow.replay-timing", qos: .utility)

    static func write(_ event: DictationTrace.Event) {
        queue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(event) else { return }
            var line = Data("timing ".utf8)
            line.append(data)
            line.append(Data("\n".utf8))
            FileHandle.standardError.write(line)
        }
    }

    static func message(_ text: String) {
        queue.async { FileHandle.standardError.write(Data(text.utf8)) }
    }

    static func flush() { queue.sync {} }
}
