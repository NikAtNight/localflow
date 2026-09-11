import XCTest
@testable import LocalFlow

@MainActor
final class DictationDeliveryTests: XCTestCase {
    func testQuitRemainsBlockedThroughDeliveryCompletionAndDuplicateCallbacks() async {
        let effects = Effects()
        let delivery = makeDelivery(effects: effects) { _ in "Delivered words." }
        let generation = delivery.begin(configuration())
        delivery.release(generation: generation, samples: speech(), hudGeneration: 7)
        XCTAssertTrue(delivery.isBusy)
        await waitUntil { effects.injected.count == 1 }
        XCTAssertEqual(effects.history, ["Delivered words."])
        XCTAssertEqual(effects.releases.first?.hudGeneration, 7)
        XCTAssertEqual(effects.processingCounts.last, 0)
        XCTAssertTrue(delivery.isBusy, "Dispatch is earlier than clipboard restoration")
        effects.completions[0]()
        effects.completions[0]()
        XCTAssertFalse(delivery.isBusy)
        XCTAssertEqual(delivery.retryCount, 0)
    }

    func testFailuresRetainLatestThreeAndRetryOldestFirstWithCurrentContext() async {
        let effects = Effects()
        var failing = true
        let delivery = makeDelivery(effects: effects) { request in
            if failing { throw DecodeError.failed }
            return "clip \(Int((request.samples.first ?? 0) * 10))"
        }
        for amplitude: Float in [0.1, 0.2, 0.3, 0.4] {
            let generation = delivery.begin(configuration())
            delivery.release(generation: generation, samples: speech(amplitude))
        }
        await waitUntil { effects.outcomes.count == 4 }
        XCTAssertEqual(delivery.retryCount, 3)
        XCTAssertTrue(effects.history.isEmpty)
        XCTAssertTrue(effects.injected.isEmpty)
        XCTAssertFalse(delivery.isBusy)

        failing = false
        var contextsRequested = 0
        delivery.retryFailedDictations {
            contextsRequested += 1
            return self.configuration(corrections: [("clip", "Recording")])
        }
        XCTAssertEqual(contextsRequested, 3)
        XCTAssertEqual(delivery.retryCount, 0)
        await waitUntil { effects.injected.count == 3 }
        XCTAssertEqual(effects.history, ["Recording 2", "Recording 3", "Recording 4"])
        XCTAssertEqual(effects.injected, effects.history)
        XCTAssertTrue(effects.releases.suffix(3).allSatisfy { $0.hudGeneration == nil })
        for complete in effects.completions { complete() }
        XCTAssertFalse(delivery.isBusy)
    }

    func testEmptyAutomaticRecoveryRetainsOneOriginalAndFailedManualRetryRetainsItOnce() async {
        let effects = Effects()
        var calls = 0
        let delivery = makeDelivery(effects: effects) { _ in calls += 1; return "" }
        let generation = delivery.begin(configuration())
        delivery.release(generation: generation, samples: speech())
        await waitUntil { effects.outcomes.count == 1 }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(delivery.retryCount, 1)
        delivery.retryFailedDictations { self.configuration() }
        await waitUntil { effects.outcomes.count == 2 }
        XCTAssertEqual(calls, 4)
        XCTAssertEqual(delivery.retryCount, 1)
        XCTAssertTrue(effects.history.isEmpty)
        XCTAssertTrue(effects.injected.isEmpty)
    }

    func testSilentReleaseIsRejectedImmediatelyWhileEarlierDictationWaits() async {
        let effects = Effects()
        var resume: CheckedContinuation<String, Never>?
        let delivery = makeDelivery(effects: effects) { _ in
            await withCheckedContinuation { resume = $0 }
        }
        let earlier = delivery.begin(configuration())
        delivery.release(generation: earlier, samples: speech())
        await waitUntil { resume != nil }
        let silent = delivery.begin(configuration())
        delivery.release(generation: silent, samples: speech(0))
        XCTAssertEqual(effects.outcomes, [.insufficientVoice(generation: silent)])
        XCTAssertEqual(delivery.retryCount, 0)
        XCTAssertTrue(effects.history.isEmpty)
        delivery.cancel(generation: earlier)
        resume?.resume(returning: "stale")
        await settle()
        XCTAssertTrue(effects.injected.isEmpty)
        XCTAssertFalse(delivery.isBusy)
    }

    func testInjectionTimeoutCancelsMappedDictationAndRejectsItsLateResult() async {
        let effects = Effects()
        var resume: CheckedContinuation<String, Never>?
        let delivery = makeDelivery(effects: effects, stallTimeout: 0.04) { _ in
            await withCheckedContinuation { resume = $0 }
        }
        let dictation = delivery.begin(configuration())
        delivery.release(generation: dictation, samples: speech(), hudGeneration: 12)
        await waitUntil { resume != nil }
        let command = delivery.beginCommand()
        delivery.completeCommand(command, with: .inject("later command"))
        await waitUntil { effects.injected == ["later command"] }
        XCTAssertEqual(effects.cancelled.map(\.hudGeneration), [12])
        XCTAssertEqual(delivery.retryCount, 0)
        resume?.resume(returning: "cancelled dictation")
        await settle()
        XCTAssertEqual(effects.history, ["later command"])
        XCTAssertEqual(effects.injected, ["later command"])
        effects.completions[0]()
        XCTAssertFalse(delivery.isBusy)
    }

    func testStalledCommandUnblocksDictationAndCannotCompleteTwice() async {
        let effects = Effects()
        let delivery = makeDelivery(effects: effects, stallTimeout: 0.04) { _ in "later dictation" }
        let command = delivery.beginCommand()
        let dictation = delivery.begin(configuration())
        delivery.release(generation: dictation, samples: speech())
        await waitUntil { effects.injected.count == 1 }
        XCTAssertEqual(effects.cancelledCommands, [command])
        XCTAssertFalse(delivery.isCommandPending(command))
        delivery.completeCommand(command, with: .inject("late command"))
        XCTAssertEqual(effects.history, ["later dictation"])
        let next = delivery.beginCommand()
        delivery.completeCommand(next, with: .inject("next command"))
        delivery.completeCommand(next, with: .inject("duplicate command"))
        await waitUntil { effects.injected.count == 2 }
        XCTAssertEqual(effects.history, ["later dictation", "next command"])
        for complete in effects.completions { complete() }
        XCTAssertFalse(delivery.isBusy)
    }

    func testPipelineTimeoutRetainsFailedAudioAndDeliversFollowingDictation() async {
        let effects = Effects()
        var resume: CheckedContinuation<String, Never>?
        let delivery = makeDelivery(effects: effects, stallTimeout: 0.04) { request in
            if request.generation == 0 {
                return await withCheckedContinuation { resume = $0 }
            }
            return "following dictation"
        }
        let first = delivery.begin(configuration())
        delivery.release(generation: first, samples: speech())
        await waitUntil { resume != nil }
        let second = delivery.begin(configuration())
        delivery.release(generation: second, samples: speech())
        await waitUntil { effects.injected.count == 1 }
        XCTAssertEqual(delivery.retryCount, 1)
        XCTAssertEqual(effects.history, ["following dictation"])
        XCTAssertTrue(effects.cancelled.isEmpty)
        resume?.resume(returning: "late timed-out result")
        await settle()
        XCTAssertEqual(effects.injected, ["following dictation"])
        effects.completions[0]()
        XCTAssertFalse(delivery.isBusy)
    }

    private enum DecodeError: Error { case failed }

    private final class Effects {
        var history: [String] = []
        var injected: [String] = []
        var completions: [() -> Void] = []
        var outcomes: [DictationSessionOutcome] = []
        var releases: [DictationDelivery.Release] = []
        var cancelled: [DictationDelivery.Release] = []
        var cancelledCommands: [Int] = []
        var processingCounts: [Int] = []
    }

    private func makeDelivery(effects: Effects, stallTimeout: TimeInterval = 90,
                              transcribe: @escaping DictationSessionPipeline.Transcribe) -> DictationDelivery {
        DictationDelivery(
            transcribe: transcribe,
            cleanup: { .init(text: $0.text, succeeded: true) },
            inject: { text, completion in effects.injected.append(text); effects.completions.append(completion) },
            recordTranscript: { effects.history.append($0) },
            onOutcome: { outcome, release in effects.outcomes.append(outcome); effects.releases.append(release) },
            onCancelled: { effects.cancelled.append($0) },
            onCommandCancelled: { effects.cancelledCommands.append($0) },
            onProcessingCountChange: { effects.processingCounts.append($0) },
            stallTimeout: stallTimeout, injectionInterval: 0
        )
    }

    private func configuration(corrections: [(wrong: String, right: String)] = []) -> DictationDelivery.Configuration {
        .init(context: .init(cleanupEnabled: false, styleProfile: .general, corrections: corrections, snippets: []))
    }

    private func speech(_ amplitude: Float = 0.2) -> [Float] {
        Array(repeating: amplitude, count: 16_000)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for delivery", file: file, line: line)
    }

    private func settle() async { try? await Task.sleep(nanoseconds: 20_000_000) }
}
