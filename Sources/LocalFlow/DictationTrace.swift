import Foundation

/// Content-free timing events. A trace follows one dictation across tasks and
/// queues; the sink does serialization and disk I/O away from capture threads.
final class DictationTrace: @unchecked Sendable {
    @TaskLocal static var current: DictationTrace?

    enum Source: String, Codable { case dictation, replay, modelLoad }

    enum Name: String, Codable {
        case modelLoadRequested, modelLoadWaitStarted, modelLoadAcquired, modelCacheChecked
        case modelAttemptStarted, modelAttemptFinished, modelLoadFallback, modelLoadFinished
        case modelInitializationStarted, modelInitializationFinished, tokenizerLoadStarted, tokenizerLoadFinished
        case sessionStarted, hotkeyPressed, hotkeyReleased
        case captureEnqueued, captureStarted, captureReady, captureFailed, microphoneLive
        case stopEnqueued, stopStarted, audioDetached, audioHandoff
        case incrementalAttempt, incrementalSkipped, chunkSubmitted, chunkCompleted
        case audioReleased, transcriptionRequested, transcriptionFinished, fullRetry
        case engineWaitStarted, engineAcquired, inferenceStarted, inferenceFinished
        case cleanupStarted, cleanupFinished, cleanupSkipped
        case appleStarted, appleFinished, ollamaDiscoveryStarted, ollamaDiscoveryFinished
        case ollamaStarted, ollamaFinished, cleanupFallback
        case ollamaServerMetrics
        case prewarmStarted, prewarmReturned
        case resultReady, resultDelivered, cancellationRequested
        case injectionQueued, injectionStarted, injectionSkipped
        case pasteDispatched, typingStarted, typingDispatched, clipboardWindowResolved
    }

    enum Status: String, Codable {
        case success, failed, cancelled, empty, skipped, warm, cold
        case busy, tooShort, noBoundary, insufficientVoice, stale, fallback
        case unchangedClipboard, changedClipboard, unavailable, apple, ollama, cooldown, shared
        case synthetic
    }

    enum Field: String, Codable {
        case samples, submittedEnd, completedEnd, tailSamples, chunkIndex
        case sequence, pendingCount, cleanupEnabled, keepMicWarm, durationMs
        case runIndex, cachePresent, decoderLoadMs, encoderLoadMs, tokenizerLoadMs
        case ollamaLoadMs, ollamaTotalMs, ollamaPromptMs, ollamaEvalMs
        case ollamaPromptTokens, ollamaOutputTokens
    }

    struct Event: Codable, Sendable {
        let schemaVersion: Int
        let traceID: UUID
        let source: Source
        let ordinal: Int
        let name: Name
        let uptimeNs: UInt64
        let sinceStartMs: Double
        let sinceReleaseMs: Double?
        let startedAt: Date
        let status: Status?
        let fields: [String: Double]
        /// Model identity is permitted metadata, never a prompt or response.
        let model: String?
        let segment: DictationTranscriptionSegment?
        let microphone: String?
    }

    let id = UUID()
    private let startedAt = Date()
    private let origin: UInt64
    private let source: Source
    private let now: @Sendable () -> UInt64
    private let sink: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var ordinal = 0
    private var releasedAt: UInt64?

    var millisecondsSinceRelease: Double? {
        lock.lock()
        defer { lock.unlock() }
        return releasedAt.map { Self.milliseconds(from: $0, to: now()) }
    }

    init(
        start: UInt64? = nil,
        source: Source = .dictation,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sink: @escaping @Sendable (Event) -> Void = { DiagLog.timing($0) }
    ) {
        self.now = now
        self.source = source
        self.origin = start ?? now()
        self.sink = sink
    }

    @discardableResult
    func record(
        _ name: Name,
        at timestamp: UInt64? = nil,
        status: Status? = nil,
        fields: [Field: Double] = [:],
        model: String? = nil,
        segment: DictationTranscriptionSegment? = nil,
        microphone: String? = nil
    ) -> Event {
        lock.lock()
        defer { lock.unlock() }
        let time = timestamp ?? now()
        if name == .hotkeyReleased, releasedAt == nil { releasedAt = time }
        let event = Event(
            schemaVersion: 1, traceID: id, source: source, ordinal: ordinal, name: name,
            uptimeNs: time, sinceStartMs: Self.milliseconds(from: origin, to: time),
            sinceReleaseMs: releasedAt.map { Self.milliseconds(from: $0, to: time) },
            startedAt: startedAt, status: status,
            fields: Dictionary(uniqueKeysWithValues: fields.map { ($0.key.rawValue, $0.value) }),
            model: model, segment: segment, microphone: microphone
        )
        ordinal += 1
        sink(event)
        return event
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        // Avoid unsigned underflow for an externally captured earlier event.
        end >= start ? Double(end - start) / 1_000_000 : -Double(start - end) / 1_000_000
    }
}
