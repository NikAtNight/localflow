import XCTest
@testable import LocalFlow

@MainActor
final class DictationSessionStallTests: XCTestCase {
    func testHungHeadTimesOutBeforeCompletedLaterTranscriptIsDelivered() async {
        let hungGeneration = 60
        let laterGeneration = 61
        let transcriber = StallCaseTranscriber(
            hungGeneration: hungGeneration,
            completedText: "later transcript"
        )
        var outcomes: [DictationSessionOutcome] = []
        let delivered = expectation(description: "stalled head and later transcript delivered")
        delivered.expectedFulfillmentCount = 2
        let pipeline = DictationSessionPipeline(
            transcribe: { request in
                try await transcriber.transcribe(request)
            },
            cleanup: { request in
                TranscriptCleanupResult(text: request.text, succeeded: true)
            },
            onOutcome: { outcome in
                outcomes.append(outcome)
                delivered.fulfill()
            },
            stalledGenerationTimeout: 0
        )
        defer {
            pipeline.cancel(generation: hungGeneration)
            pipeline.cancel(generation: laterGeneration)
        }

        pipeline.begin(generation: hungGeneration, context: context)
        pipeline.release(
            generation: hungGeneration,
            fullSamples: speech,
            tailSamples: speech
        )
        let headStarted = await waitForCall(generation: hungGeneration, in: transcriber)
        XCTAssertTrue(headStarted)

        pipeline.begin(generation: laterGeneration, context: context)
        pipeline.release(
            generation: laterGeneration,
            fullSamples: speech,
            tailSamples: speech
        )
        let laterCompleted = await waitForCall(generation: laterGeneration, in: transcriber)
        XCTAssertTrue(laterCompleted)

        await fulfillment(of: [delivered], timeout: 0.5)
        XCTAssertEqual(outcomes, [
            .failed(
                generation: hungGeneration,
                message: "Transcription timed out while a later dictation was waiting."
            ),
            .finalTranscript(generation: laterGeneration, text: "later transcript")
        ])
    }

    func testLaterCompletionDoesNotRestartArmedStallDeadline() async {
        let hungGeneration = 70
        let firstLaterGeneration = 71
        let secondLaterGeneration = 72
        let transcriber = StallCaseTranscriber(
            hungGeneration: hungGeneration,
            completedText: "later transcript"
        )
        var outcomes: [DictationSessionOutcome] = []
        let delivered = expectation(description: "original stall deadline delivers queued outcomes")
        delivered.expectedFulfillmentCount = 3
        let pipeline = DictationSessionPipeline(
            transcribe: { request in
                try await transcriber.transcribe(request)
            },
            cleanup: { request in
                TranscriptCleanupResult(text: request.text, succeeded: true)
            },
            onOutcome: { outcome in
                outcomes.append(outcome)
                delivered.fulfill()
            },
            stalledGenerationTimeout: 0.4
        )
        defer {
            pipeline.cancel(generation: hungGeneration)
            pipeline.cancel(generation: firstLaterGeneration)
            pipeline.cancel(generation: secondLaterGeneration)
        }

        pipeline.begin(generation: hungGeneration, context: context)
        pipeline.release(
            generation: hungGeneration,
            fullSamples: speech,
            tailSamples: speech
        )
        let headStarted = await waitForCall(generation: hungGeneration, in: transcriber)
        XCTAssertTrue(headStarted)

        pipeline.begin(generation: firstLaterGeneration, context: context)
        pipeline.release(
            generation: firstLaterGeneration,
            fullSamples: speech,
            tailSamples: speech
        )
        let firstLaterCompleted = await waitForCall(
            generation: firstLaterGeneration,
            in: transcriber
        )
        XCTAssertTrue(firstLaterCompleted)
        await settleAsyncWork()

        // The first later result arms a 400 ms deadline for the hung head.
        // Complete another queued result 250 ms into that same interval.
        try? await Task.sleep(nanoseconds: 250_000_000)
        pipeline.begin(generation: secondLaterGeneration, context: context)
        pipeline.release(
            generation: secondLaterGeneration,
            fullSamples: speech,
            tailSamples: speech
        )
        let secondLaterCompleted = await waitForCall(
            generation: secondLaterGeneration,
            in: transcriber
        )
        XCTAssertTrue(secondLaterCompleted)
        await settleAsyncWork()

        // The original deadline has about 150 ms left. A restarted timer
        // needs another 400 ms and cannot satisfy this 250 ms window.
        await fulfillment(of: [delivered], timeout: 0.25)
        XCTAssertEqual(outcomes, [
            .failed(
                generation: hungGeneration,
                message: "Transcription timed out while a later dictation was waiting."
            ),
            .finalTranscript(generation: firstLaterGeneration, text: "later transcript"),
            .finalTranscript(generation: secondLaterGeneration, text: "later transcript")
        ])
    }

    private var speech: [Float] {
        [Float](repeating: 0.2, count: Int(AudioRecorder.sampleRate))
    }

    private var context: DictationSessionContext {
        DictationSessionContext(
            cleanupEnabled: false,
            styleProfile: .general,
            corrections: [],
            snippets: []
        )
    }

    private func waitForCall(
        generation: Int,
        in transcriber: StallCaseTranscriber
    ) async -> Bool {
        for _ in 0..<10_000 {
            if await transcriber.hasCall(generation: generation) { return true }
            await Task.yield()
        }
        return false
    }

    private func settleAsyncWork() async {
        for _ in 0..<100 { await Task.yield() }
    }
}

private actor StallCaseTranscriber {
    private let hungGeneration: Int
    private let completedText: String
    private var calls: Set<Int> = []
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]
    private var cancellationRequested: Set<Int> = []

    init(hungGeneration: Int, completedText: String) {
        self.hungGeneration = hungGeneration
        self.completedText = completedText
    }

    func transcribe(_ request: DictationTranscriptionRequest) async throws -> String {
        calls.insert(request.generation)
        guard request.generation == hungGeneration else { return completedText }
        let generation = request.generation
        return try await withTaskCancellationHandler {
            try await suspend(generation: generation)
        } onCancel: {
            Task { await self.cancel(generation: generation) }
        }
    }

    func hasCall(generation: Int) -> Bool {
        calls.contains(generation)
    }

    private func suspend(generation: Int) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            if cancellationRequested.remove(generation) != nil {
                continuation.resume(throwing: CancellationError())
            } else {
                pending[generation] = continuation
            }
        }
    }

    private func cancel(generation: Int) {
        if let continuation = pending.removeValue(forKey: generation) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancellationRequested.insert(generation)
        }
    }
}
