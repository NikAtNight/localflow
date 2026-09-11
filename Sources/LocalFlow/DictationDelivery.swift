import Foundation

/// Owns released audio until it is retained for retry or its delivery completes.
/// The session pipeline and mixed-mode injection queue keep their own scheduling rules.
@MainActor
final class DictationDelivery {
    struct Configuration {
        let context: DictationSessionContext
        var trace: DictationTrace? = nil
        var diagnostics: DictationDiagnosticStore.Recording? = nil
        var personalVoice: PersonalVoiceStore.Recording? = nil
    }

    struct Release {
        let releasedAt: Date
        let hudGeneration: Int?
        let duration: Double
        let cleanupEnabled: Bool
    }

    private struct Pending {
        let sequence: Int?
        let samples: [Float]
        let release: Release
    }

    typealias Inject = (String, @escaping () -> Void) -> Void

    private let transcribe: DictationSessionPipeline.Transcribe
    private let cleanup: DictationSessionPipeline.Cleanup
    private let inject: Inject
    private let recordTranscript: (String) -> Void
    private let onOutcome: (DictationSessionOutcome, Release) -> Void
    private let onCancelled: (Release) -> Void
    private let onCommandCancelled: (Int) -> Void
    private let onProcessingCountChange: (Int) -> Void
    private let stallTimeout: TimeInterval
    private let injectionInterval: TimeInterval

    private var nextGeneration = 0
    private var configurations: [Int: Configuration] = [:]
    private var pending: [Int: Pending] = [:]
    private var generationsBySequence: [Int: Int] = [:]
    private var retrySamples: [[Float]] = []
    private var activeInjections: Set<UUID> = []
    private var pendingCommands: Set<Int> = []

    private lazy var pipeline = DictationSessionPipeline(
        transcribe: transcribe,
        cleanup: cleanup,
        onOutcome: { [weak self] in self?.finish($0) },
        stalledGenerationTimeout: stallTimeout
    )
    private lazy var injections = InjectionCoordinator(
        stallTimeout: stallTimeout,
        injectionInterval: injectionInterval,
        onInject: { [weak self] in self?.deliver($0) },
        onCancel: { [weak self] sequence, kind in
            guard let self else { return }
            switch kind {
            case .command:
                self.pendingCommands.remove(sequence)
                self.onCommandCancelled(sequence)
            case .dictation:
                guard let generation = self.generationsBySequence[sequence] else { return }
                self.cancel(generation: generation)
            }
        },
        onProcessingCountChange: { [weak self] in self?.onProcessingCountChange($0) }
    )

    init(
        transcribe: @escaping DictationSessionPipeline.Transcribe,
        cleanup: @escaping DictationSessionPipeline.Cleanup,
        inject: @escaping Inject,
        recordTranscript: @escaping (String) -> Void,
        onOutcome: @escaping (DictationSessionOutcome, Release) -> Void,
        onCancelled: @escaping (Release) -> Void,
        onCommandCancelled: @escaping (Int) -> Void,
        onProcessingCountChange: @escaping (Int) -> Void,
        stallTimeout: TimeInterval = 90,
        injectionInterval: TimeInterval = 0.4
    ) {
        self.transcribe = transcribe
        self.cleanup = cleanup
        self.inject = inject
        self.recordTranscript = recordTranscript
        self.onOutcome = onOutcome
        self.onCancelled = onCancelled
        self.onCommandCancelled = onCommandCancelled
        self.onProcessingCountChange = onProcessingCountChange
        self.stallTimeout = stallTimeout
        self.injectionInterval = injectionInterval
    }

    var retryCount: Int { retrySamples.count }
    var isBusy: Bool { !pending.isEmpty || injections.pendingCount > 0 || !activeInjections.isEmpty }

    func begin(_ configuration: Configuration) -> Int {
        let generation = nextGeneration
        nextGeneration += 1
        configurations[generation] = configuration
        pipeline.begin(generation: generation, context: configuration.context,
                       trace: configuration.trace, diagnostics: configuration.diagnostics,
                       personalVoice: configuration.personalVoice)
        return generation
    }

    func canAcceptIncrementalChunk(generation: Int) -> Bool {
        pipeline.canAcceptIncrementalChunk(generation: generation)
    }

    func processIncrementalSnapshot(generation: Int, samples: [Float]) {
        pipeline.processIncrementalSnapshot(generation: generation, samples: samples)
    }

    func release(generation: Int, samples: [Float], nativeAudio: NativeAudioRecording? = nil,
                 releasedAt: Date = Date(), hudGeneration: Int? = nil) {
        guard let configuration = configurations[generation], pending[generation] == nil else { return }
        let audio = DictationAudioPreparation(samples: samples)
        let sequence = audio.isAdmitted ? injections.begin(kind: .dictation, trace: configuration.trace) : nil
        pending[generation] = Pending(sequence: sequence, samples: samples, release: Release(
            releasedAt: releasedAt, hudGeneration: hudGeneration, duration: audio.duration,
            cleanupEnabled: configuration.context.cleanupEnabled
        ))
        if let sequence { generationsBySequence[sequence] = generation }
        pipeline.recordCapturedAudio(generation: generation, samples: samples, nativeAudio: nativeAudio)
        pipeline.release(generation: generation, fullSamples: samples)
    }

    func cancel(generation: Int) {
        configurations.removeValue(forKey: generation)
        let cancelled = pending.removeValue(forKey: generation)
        if let sequence = cancelled?.sequence { generationsBySequence.removeValue(forKey: sequence) }
        pipeline.cancel(generation: generation)
        if let cancelled {
            if let sequence = cancelled.sequence { injections.complete(sequence, with: .skip) }
            onCancelled(cancelled.release)
        }
    }

    func retryFailedDictations(configuration: () -> Configuration) {
        let samplesToRetry = retrySamples
        retrySamples.removeAll()
        for samples in samplesToRetry {
            var retryConfiguration = configuration()
            // A manual retry never creates another personal voice clip.
            retryConfiguration.personalVoice = nil
            let generation = begin(retryConfiguration)
            release(generation: generation, samples: samples)
        }
    }

    func beginCommand() -> Int {
        let sequence = injections.begin(kind: .command)
        pendingCommands.insert(sequence)
        return sequence
    }
    func isCommandPending(_ sequence: Int) -> Bool { pendingCommands.contains(sequence) }

    func completeCommand(_ sequence: Int, with outcome: InjectionCoordinator.Outcome) {
        guard pendingCommands.remove(sequence) != nil else { return }
        if case .inject(let text) = outcome { recordTranscript(text) }
        injections.complete(sequence, with: outcome)
    }

    private func finish(_ outcome: DictationSessionOutcome) {
        let generation: Int
        switch outcome {
        case .finalTranscript(let value, _), .emptyTranscript(let value),
             .failed(let value, _), .insufficientVoice(let value): generation = value
        }
        guard let completed = pending.removeValue(forKey: generation) else { return }
        configurations.removeValue(forKey: generation)
        if let sequence = completed.sequence { generationsBySequence.removeValue(forKey: sequence) }
        switch outcome {
        case .finalTranscript(_, let text):
            recordTranscript(text)
            if let sequence = completed.sequence { injections.complete(sequence, with: .inject(text)) }
        case .emptyTranscript, .failed:
            retrySamples.append(completed.samples)
            if retrySamples.count > 3 { retrySamples.removeFirst() }
            if let sequence = completed.sequence { injections.complete(sequence, with: .skip) }
        case .insufficientVoice:
            if let sequence = completed.sequence { injections.complete(sequence, with: .skip) }
        }
        onOutcome(outcome, completed.release)
    }

    private func deliver(_ text: String) {
        let id = UUID()
        activeInjections.insert(id)
        inject(text) { [weak self] in self?.activeInjections.remove(id) }
    }
}
