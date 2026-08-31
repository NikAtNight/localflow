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

enum DictationTranscriptionSegment: Equatable {
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
    typealias Transcribe = (DictationTranscriptionRequest) async throws -> String
    typealias Cleanup = (DictationCleanupRequest) async -> TranscriptCleanupResult
    typealias OutcomeHandler = (DictationSessionOutcome) -> Void

    private struct IncrementalChunk {
        let index: Int
        let samples: [Float]
        let pauseSecondsBefore: Double
    }

    private struct ReleaseAudio {
        let fullSamples: [Float]
        let tailSamples: [Float]
    }

    private final class Session {
        let generation: Int
        let context: DictationSessionContext
        var pendingChunks: [IncrementalChunk] = []
        var activeTask: Task<Void, Never>?
        var releaseAudio: ReleaseAudio?
        var committedText = ""
        var chunkCount = 0
        var nextChunkIndex = 0
        var nextPauseSeconds = 0.0
        var incrementalSampleEnd = 0
        var incrementalFailed = false
        var cancelled = false

        init(generation: Int, context: DictationSessionContext) {
            self.generation = generation
            self.context = context
        }
    }

    private let transcribe: Transcribe
    private let cleanup: Cleanup
    private let onOutcome: OutcomeHandler
    private let stalledGenerationTimeout: TimeInterval
    private var sessions: [Int: Session] = [:]
    private var generationOrder: [Int] = []
    private var completed: [Int: DictationSessionOutcome] = [:]
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

    func begin(generation: Int, context: DictationSessionContext) {
        if sessions[generation] != nil || generationOrder.contains(generation) {
            cancel(generation: generation)
        }
        sessions[generation] = Session(generation: generation, context: context)
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
            pauseSecondsBefore: session.nextPauseSeconds
        )
        session.nextChunkIndex += 1
        session.nextPauseSeconds = pauseSecondsAfterChunk
        if let sourceEndIndex {
            session.incrementalSampleEnd = sourceEndIndex
        }
        session.pendingChunks.append(chunk)
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
        advance(session)
    }

    func cancel(generation: Int) {
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
                let text = try await transcribe(request)
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
                let tailText = try await transcribe(request)
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
                let text = try await transcribe(request)
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
            let result = await cleanup(request)
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
        sessions.removeValue(forKey: session.generation)
        completed[session.generation] = outcome
        drainCompletedOutcomes()
    }

    private func isCurrent(_ session: Session) -> Bool {
        !session.cancelled && sessions[session.generation] === session
    }

    private func drainCompletedOutcomes() {
        stallTimer?.cancel()
        stallTimer = nil
        stalledGeneration = nil
        while let generation = generationOrder.first {
            if cancelled.remove(generation) != nil {
                generationOrder.removeFirst()
                continue
            }
            guard let outcome = completed.removeValue(forKey: generation) else {
                if !completed.isEmpty {
                    scheduleStallTimeout(for: generation)
                }
                return
            }
            generationOrder.removeFirst()
            onOutcome(outcome)
        }
    }

    private func scheduleStallTimeout(for generation: Int) {
        guard stalledGeneration != generation else { return }
        stalledGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.generationOrder.first == generation,
                  !self.completed.isEmpty else { return }
            if let session = self.sessions.removeValue(forKey: generation) {
                session.cancelled = true
                session.activeTask?.cancel()
            }
            self.completed[generation] = .failed(
                generation: generation,
                message: "Transcription timed out while a later dictation was waiting."
            )
            self.drainCompletedOutcomes()
        }
        stallTimer = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + stalledGenerationTimeout,
            execute: work
        )
    }
}
