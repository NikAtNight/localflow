import WhisperKit

/// Uses WhisperKit's existing load timings without changing its model setup,
/// compute configuration, loading order, or tokenizer fallback behavior.
final class StartupMeasuredWhisperKit: WhisperKit {
    override func loadModels(prewarmMode: Bool = false) async throws {
        let trace = DictationTrace.current
        trace?.record(.modelInitializationStarted)
        do {
            try await super.loadModels(prewarmMode: prewarmMode)
            trace?.record(.modelInitializationFinished, status: .success, fields: [
                .decoderLoadMs: currentTimings.decoderLoadTime * 1_000,
                .encoderLoadMs: currentTimings.encoderLoadTime * 1_000,
                .tokenizerLoadMs: currentTimings.tokenizerLoadTime * 1_000
            ])
        } catch {
            trace?.record(.modelInitializationFinished, status: error is CancellationError ? .cancelled : .failed)
            throw error
        }
    }

    override func loadTokenizerIfNeeded() async throws {
        let trace = DictationTrace.current
        trace?.record(.tokenizerLoadStarted)
        do {
            try await super.loadTokenizerIfNeeded()
            trace?.record(.tokenizerLoadFinished, status: .success)
        } catch {
            trace?.record(.tokenizerLoadFinished, status: error is CancellationError ? .cancelled : .failed)
            throw error
        }
    }
}
