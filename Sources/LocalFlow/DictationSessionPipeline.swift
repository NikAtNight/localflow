import Foundation

struct DictationSessionContext {
    let cleanupEnabled: Bool
    let styleProfile: AppStyleProfile
    let corrections: [(wrong: String, right: String)]
    let snippets: [(trigger: String, expansion: String)]
    let ollamaModel: String

    init(
        cleanupEnabled: Bool,
        styleProfile: AppStyleProfile,
        corrections: [(wrong: String, right: String)],
        snippets: [(trigger: String, expansion: String)],
        ollamaModel: String = ""
    ) {
        self.cleanupEnabled = cleanupEnabled
        self.styleProfile = styleProfile
        self.corrections = corrections
        self.snippets = snippets
        self.ollamaModel = ollamaModel
    }
}

enum DictationTranscriptionSegment: Equatable, Codable, Sendable {
    case incrementalChunk(index: Int)
    case releaseTail
    case fullUtterance
}

struct DictationTranscriptionRequest {
    let generation: Int
    let segment: DictationTranscriptionSegment
    let samples: [Float]
}

struct DictationCleanupRequest {
    let generation: Int
    let text: String
    let context: DictationSessionContext
}

enum DictationSessionOutcome: Equatable {
    case finalTranscript(generation: Int, text: String)
    case emptyTranscript(generation: Int)
    case failed(generation: Int, message: String)
}

/// Owns the asynchronous lifetime of dictations after recording begins.
/// AppKit supplies audio snapshots and handles the eventual paste, while this
/// coordinator keeps chunking, fallback, cleanup, cancellation, and delivery
/// order consistent across overlapping generations.
@MainActor
final class DictationSessionPipeline {
    static let incrementalStartSeconds: TimeInterval = 8
    static let incrementalTickSeconds: TimeInterval = 4
    typealias Transcribe = (DictationTranscriptionRequest) async throws -> String
    typealias Cleanup = (DictationCleanupRequest) async -> TranscriptCleanupResult
    typealias OutcomeHandler = (DictationSessionOutcome) -> Void

    private struct IncrementalChunk {
        let index: Int
        let samples: [Float]
        let pauseSecondsBefore: Double
        let sourceEndIndex: Int?
    }

    private struct ReleaseAudio {
        let fullSamples: [Float]
        let tailSamples: [Float]
    }

    private final class Session {
        let generation: Int
        let context: DictationSessionContext
        let trace: DictationTrace?
        var pendingChunks: [IncrementalChunk] = []
        var activeTask: Task<Void, Never>?
        var releaseAudio: ReleaseAudio?
        var committedText = ""
        var chunkCount = 0
        var nextChunkIndex = 0
        var nextPauseSeconds = 0.0
        var incrementalSampleEnd = 0
        var completedSampleEnd = 0
        var incrementalFailed = false
        var cancelled = false

        init(generation: Int, context: DictationSessionContext, trace: DictationTrace?) {
            self.generation = generation
            self.context = context
            self.trace = trace
        }
    }

    private let transcribe: Transcribe
    private let cleanup: Cleanup
    private let onOutcome: OutcomeHandler
    private let stalledGenerationTimeout: TimeInterval
    private var sessions: [Int: Session] = [:]
    private var generationOrder: [Int] = []
    private var completed: [Int: (outcome: DictationSessionOutcome, trace: DictationTrace?)] = [:]
    private var cancelled: Set<Int> = []
    private var stallTimer: DispatchWorkItem?
    private var stalledGeneration: Int?

    init(
        transcribe: @escaping Transcribe,
        cleanup: @escaping Cleanup,
        onOutcome: @escaping OutcomeHandler,
        stalledGenerationTimeout: TimeInterval = 90
    ) {
        self.transcribe = transcribe
        self.cleanup = cleanup
        self.onOutcome = onOutcome
        self.stalledGenerationTimeout = stalledGenerationTimeout
    }

    func begin(generation: Int, context: DictationSessionContext, trace: DictationTrace? = DictationTrace.current) {
        if sessions[generation] != nil || generationOrder.contains(generation) {
            cancel(generation: generation)
        }
        sessions[generation] = Session(generation: generation, context: context, trace: trace)
        trace?.record(.sessionStarted, fields: [.cleanupEnabled: context.cleanupEnabled ? 1 : 0], model: context.ollamaModel)
        generationOrder.append(generation)
    }

    func canAcceptIncrementalChunk(generation: Int) -> Bool {
        guard let session = sessions[generation] else { return false }
        return !session.cancelled
            && !session.incrementalFailed
            && session.releaseAudio == nil
            && session.activeTask == nil
            && session.pendingChunks.isEmpty
    }

    func incrementalSampleEnd(generation: Int) -> Int? {
        sessions[generation]?.incrementalSampleEnd
    }

    /// Shared by live capture and file replay so benchmarks use the same
    /// thresholds and chunk acceptance rules as dictation.
    func processIncrementalSnapshot(generation: Int, samples: [Float]) {
        let trace = sessions[generation]?.trace
        trace?.record(.incrementalAttempt, fields: [.samples: Double(samples.count)])
        guard samples.count >= Int(Self.incrementalStartSeconds * AudioRecorder.sampleRate) else {
            trace?.record(.incrementalSkipped, status: .tooShort)
            return
        }
        guard canAcceptIncrementalChunk(generation: generation) else {
            trace?.record(.incrementalSkipped, status: .busy)
            return
        }
        let start = incrementalSampleEnd(generation: generation) ?? 0
        guard let cut = AudioRecorder.incrementalCutPoint(in: samples, after: start) else {
            trace?.record(.incrementalSkipped, status: .noBoundary)
            return
        }
        let chunk = AudioRecorder.trimmingSilence(Array(samples[start..<cut]))
        guard AudioRecorder.voicedMetrics(of: chunk).voicedSeconds >= 0.3 else {
            trace?.record(.incrementalSkipped, status: .insufficientVoice)
            return
        }
        processIncrementalChunk(
            generation: generation, samples: chunk,
            pauseSecondsAfterChunk: AudioRecorder.incrementalPauseSeconds(in: samples, around: cut),
            sourceEndIndex: cut
        )
    }

    func processIncrementalChunk(
        generation: Int,
        samples: [Float],
        pauseSecondsAfterChunk: Double,
        sourceEndIndex: Int? = nil
    ) {
        guard let session = sessions[generation],
              !session.cancelled,
              !session.incrementalFailed,
              session.releaseAudio == nil else { return }

        let chunk = IncrementalChunk(
            index: session.nextChunkIndex,
            samples: samples,
            pauseSecondsBefore: session.nextPauseSeconds,
            sourceEndIndex: sourceEndIndex
        )
        session.nextChunkIndex += 1
        session.nextPauseSeconds = pauseSecondsAfterChunk
        if let sourceEndIndex {
            session.incrementalSampleEnd = sourceEndIndex
        }
        session.pendingChunks.append(chunk)
        session.trace?.record(.chunkSubmitted, fields: [
            .chunkIndex: Double(chunk.index), .samples: Double(samples.count),
            .submittedEnd: Double(session.incrementalSampleEnd)
        ])
        advance(session)
    }

    func release(
        generation: Int,
        fullSamples: [Float],
        tailSamples: [Float]? = nil
    ) {
        guard let session = sessions[generation],
              !session.cancelled,
              session.releaseAudio == nil else { return }

        let derivedTail: [Float]
        if let tailSamples {
            derivedTail = tailSamples
        } else if session.incrementalSampleEnd <= fullSamples.count {
            derivedTail = Array(fullSamples[session.incrementalSampleEnd...])
        } else {
            derivedTail = []
            session.incrementalFailed = true
        }
        session.releaseAudio = ReleaseAudio(
            fullSamples: fullSamples,
            tailSamples: derivedTail
        )
        session.trace?.record(.audioReleased, fields: [
            .samples: Double(fullSamples.count), .tailSamples: Double(derivedTail.count),
            .submittedEnd: Double(session.incrementalSampleEnd),
            .completedEnd: Double(session.completedSampleEnd)
        ])
        advance(session)
    }

    func cancel(generation: Int) {
        let trace = sessions[generation]?.trace ?? completed[generation]?.trace
        trace?.record(.cancellationRequested)
        if let session = sessions.removeValue(forKey: generation) {
            session.cancelled = true
            session.pendingChunks.removeAll()
            session.activeTask?.cancel()
            session.activeTask = nil
        }
        guard generationOrder.contains(generation) else { return }
        completed.removeValue(forKey: generation)
        cancelled.insert(generation)
        drainCompletedOutcomes()
    }

    private func advance(_ session: Session) {
        guard !session.cancelled, session.activeTask == nil else { return }

        if session.incrementalFailed {
            guard let release = session.releaseAudio else { return }
            session.trace?.record(.fullRetry, fields: [.samples: Double(release.fullSamples.count)])
            transcribeFullUtterance(session, samples: release.fullSamples)
            return
        }

        if !session.pendingChunks.isEmpty {
            transcribeNextChunk(session)
            return
        }

        guard let release = session.releaseAudio else { return }
        if session.chunkCount == 0 {
            transcribeFullUtterance(session, samples: release.fullSamples)
        } else {
            transcribeTail(session, release: release)
        }
    }

    private func transcribeNextChunk(_ session: Session) {
        let chunk = session.pendingChunks.removeFirst()
        let request = DictationTranscriptionRequest(
            generation: session.generation,
            segment: .incrementalChunk(index: chunk.index),
            samples: chunk.samples
        )
        session.activeTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            do {
                let text = try await runTranscription(request, session: session)
                guard isCurrent(session) else { return }
                session.activeTask = nil
                guard !text.isEmpty else {
                    session.incrementalFailed = true
                    session.pendingChunks.removeAll()
                    advance(session)
                    return
                }
                session.committedText = Transcriber.joinTranscriptParts(
                    session.committedText,
                    text,
                    pauseSeconds: chunk.pauseSecondsBefore
                )
                session.chunkCount += 1
                session.completedSampleEnd = chunk.sourceEndIndex ?? session.completedSampleEnd
                session.trace?.record(.chunkCompleted, fields: [
                    .chunkIndex: Double(chunk.index), .completedEnd: Double(session.completedSampleEnd)
                ])
                advance(session)
            } catch {
                guard isCurrent(session) else { return }
                session.activeTask = nil
                session.incrementalFailed = true
                session.pendingChunks.removeAll()
                advance(session)
            }
        }
    }

    private func transcribeTail(_ session: Session, release: ReleaseAudio) {
        let request = DictationTranscriptionRequest(
            generation: session.generation,
            segment: .releaseTail,
            samples: release.tailSamples
        )
        session.activeTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            do {
                let tailText = try await runTranscription(request, session: session)
                guard isCurrent(session) else { return }
                session.activeTask = nil
                let voicedTail = AudioRecorder.voicedMetrics(of: release.tailSamples).voicedSeconds > 0
                guard !tailText.isEmpty || !voicedTail else {
                    session.incrementalFailed = true
                    advance(session)
                    return
                }
                let wholeText = Transcriber.joinTranscriptParts(
                    session.committedText,
                    tailText,
                    pauseSeconds: session.nextPauseSeconds
                )
                finalize(session, transcript: wholeText)
            } catch {
                guard isCurrent(session) else { return }
                session.activeTask = nil
                session.incrementalFailed = true
                advance(session)
            }
        }
    }

    private func transcribeFullUtterance(_ session: Session, samples: [Float]) {
        let request = DictationTranscriptionRequest(
            generation: session.generation,
            segment: .fullUtterance,
            samples: samples
        )
        session.activeTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            do {
                let text = try await runTranscription(request, session: session)
                guard isCurrent(session) else { return }
                session.activeTask = nil
                if text.isEmpty {
                    complete(session, with: .emptyTranscript(generation: session.generation))
                } else {
                    finalize(session, transcript: text)
                }
            } catch {
                guard isCurrent(session) else { return }
                session.activeTask = nil
                complete(
                    session,
                    with: .failed(generation: session.generation, message: error.localizedDescription)
                )
            }
        }
    }

    private func finalize(_ session: Session, transcript: String) {
        let composed = Snippets.expand(
            VoiceFormatter.apply(
                TranscriptCorrections.apply(
                    transcript,
                    corrections: session.context.corrections
                )
            ),
            snippets: session.context.snippets
        )
        guard !composed.isEmpty else {
            complete(session, with: .emptyTranscript(generation: session.generation))
            return
        }
        guard session.context.cleanupEnabled else {
            session.trace?.record(.cleanupSkipped)
            complete(
                session,
                with: .finalTranscript(generation: session.generation, text: composed)
            )
            return
        }

        let request = DictationCleanupRequest(
            generation: session.generation,
            text: composed,
            context: session.context
        )
        session.activeTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            session.trace?.record(.cleanupStarted)
            let result = await DictationTrace.$current.withValue(session.trace) {
                await self.cleanup(request)
            }
            session.trace?.record(.cleanupFinished, status: Task.isCancelled ? .cancelled : (result.succeeded ? .success : .fallback))
            guard isCurrent(session) else { return }
            session.activeTask = nil
            complete(
                session,
                with: .finalTranscript(generation: session.generation, text: result.text)
            )
        }
    }

    private func complete(_ session: Session, with outcome: DictationSessionOutcome) {
        guard isCurrent(session) else { return }
        let status: DictationTrace.Status
        switch outcome {
        case .finalTranscript: status = .success
        case .emptyTranscript: status = .empty
        case .failed: status = .failed
        }
        session.trace?.record(.resultReady, status: status)
        sessions.removeValue(forKey: session.generation)
        completed[session.generation] = (outcome, session.trace)
        drainCompletedOutcomes()
    }

    private func isCurrent(_ session: Session) -> Bool {
        !session.cancelled && sessions[session.generation] === session
    }

    private func drainCompletedOutcomes() {
        while let generation = generationOrder.first {
            if cancelled.remove(generation) != nil {
                generationOrder.removeFirst()
                if stalledGeneration == generation {
                    cancelStallTimeout()
                }
                continue
            }
            guard let outcome = completed.removeValue(forKey: generation) else {
                if !completed.isEmpty {
                    scheduleStallTimeout(for: generation)
                } else {
                    cancelStallTimeout()
                }
                return
            }
            generationOrder.removeFirst()
            if stalledGeneration == generation {
                cancelStallTimeout()
            }
            outcome.trace?.record(.resultDelivered)
            DictationTrace.$current.withValue(outcome.trace) { onOutcome(outcome.outcome) }
        }
        cancelStallTimeout()
    }

    private func runTranscription(_ request: DictationTranscriptionRequest, session: Session) async throws -> String {
        session.trace?.record(.transcriptionRequested, fields: [.samples: Double(request.samples.count)], segment: request.segment)
        do {
            let text = try await DictationTrace.$current.withValue(session.trace) {
                try await transcribe(request)
            }
            session.trace?.record(.transcriptionFinished, status: Task.isCancelled ? .cancelled : (text.isEmpty ? .empty : .success))
            return text
        } catch {
            session.trace?.record(.transcriptionFinished, status: Task.isCancelled || error is CancellationError ? .cancelled : .failed)
            throw error
        }
    }

    private func scheduleStallTimeout(for generation: Int) {
        guard stalledGeneration != generation || stallTimer == nil else { return }
        cancelStallTimeout()
        stalledGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.generationOrder.first == generation,
                  !self.completed.isEmpty else { return }
            self.stallTimer = nil
            self.stalledGeneration = nil
            let session = self.sessions.removeValue(forKey: generation)
            if let session {
                session.trace?.record(.cancellationRequested)
                session.cancelled = true
                session.activeTask?.cancel()
            }
            session?.trace?.record(.resultReady, status: .failed)
            self.completed[generation] = (.failed(
                generation: generation,
                message: "Transcription timed out while a later dictation was waiting."
            ), session?.trace)
            self.drainCompletedOutcomes()
        }
        stallTimer = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + stalledGenerationTimeout,
            execute: work
        )
    }

    private func cancelStallTimeout() {
        stallTimer?.cancel()
        stallTimer = nil
        stalledGeneration = nil
    }
}
