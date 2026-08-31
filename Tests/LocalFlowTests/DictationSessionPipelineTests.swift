import XCTest
@testable import LocalFlow

/// Behavioral contract for the async path between captured audio and a
/// transcript that AppDelegate may paste. These tests intentionally target the
/// coordinator, not AppDelegate's old boolean planning helper.
///
/// The production type is expected to own concurrent recording generations,
/// incremental transcription, release fallback, whole-utterance cleanup, and
/// ordered outcome delivery. AppKit remains responsible for the actual paste.
@MainActor
final class DictationSessionPipelineTests: XCTestCase {
    private let speech = [Float](repeating: 0.2, count: Int(AudioRecorder.sampleRate))

    func testReleaseWaitsForActiveChunkBeforeTranscribingTailAndEmitting() async {
        let transcriber = ControlledTranscriber()
        let cleaner = RecordingCleaner(mode: .unchanged)
        let outcomes = OutcomeRecorder()
        let pipeline = makePipeline(transcriber: transcriber, cleaner: cleaner, outcomes: outcomes)

        pipeline.begin(generation: 1, context: context())
        pipeline.processIncrementalChunk(
            generation: 1,
            samples: speech,
            pauseSecondsAfterChunk: 0.4
        )
        expectTrue(await waitForCall(.incrementalChunk(index: 0), generation: 1, in: transcriber))

        pipeline.release(
            generation: 1,
            fullSamples: speech + speech,
            tailSamples: speech
        )
        await settleAsyncWork()

        expectFalse(await transcriber.hasCall(.releaseTail, generation: 1))
        XCTAssertTrue(outcomes.values.isEmpty)

        expectTrue(await transcriber.succeed(
            "first thought",
            segment: .incrementalChunk(index: 0),
            generation: 1
        ))
        expectTrue(await waitForCall(.releaseTail, generation: 1, in: transcriber))
        expectTrue(await transcriber.succeed(
            "second thought",
            segment: .releaseTail,
            generation: 1
        ))

        expectTrue(await waitForOutcomes(1, in: outcomes))
        XCTAssertEqual(outcomes.values, [
            .finalTranscript(generation: 1, text: "first thought second thought")
        ])
    }

    func testCompletedDictationsEmitInSpokenOrderWhenSecondFinishesFirst() async {
        let transcriber = ControlledTranscriber()
        let cleaner = RecordingCleaner(mode: .unchanged)
        let outcomes = OutcomeRecorder()
        let pipeline = makePipeline(transcriber: transcriber, cleaner: cleaner, outcomes: outcomes)

        pipeline.begin(generation: 10, context: context())
        pipeline.release(generation: 10, fullSamples: speech, tailSamples: speech)
        pipeline.begin(generation: 11, context: context())
        pipeline.release(generation: 11, fullSamples: speech, tailSamples: speech)

        expectTrue(await waitForCall(.fullUtterance, generation: 10, in: transcriber))
        expectTrue(await waitForCall(.fullUtterance, generation: 11, in: transcriber))

        expectTrue(await transcriber.succeed(
            "spoken second",
            segment: .fullUtterance,
            generation: 11
        ))
        await settleAsyncWork()
        XCTAssertTrue(outcomes.values.isEmpty)

        expectTrue(await transcriber.succeed(
            "spoken first",
            segment: .fullUtterance,
            generation: 10
        ))
        expectTrue(await waitForOutcomes(2, in: outcomes))
        XCTAssertEqual(outcomes.values, [
            .finalTranscript(generation: 10, text: "spoken first"),
            .finalTranscript(generation: 11, text: "spoken second")
        ])
    }

    func testCancelledGenerationDropsLateCallbackAndDoesNotBlockNextOutcome() async {
        let transcriber = ControlledTranscriber()
        let cleaner = RecordingCleaner(mode: .unchanged)
        let outcomes = OutcomeRecorder()
        let pipeline = makePipeline(transcriber: transcriber, cleaner: cleaner, outcomes: outcomes)

        pipeline.begin(generation: 20, context: context())
        pipeline.release(generation: 20, fullSamples: speech, tailSamples: speech)
        expectTrue(await waitForCall(.fullUtterance, generation: 20, in: transcriber))

        pipeline.cancel(generation: 20)
        pipeline.begin(generation: 21, context: context())
        pipeline.release(generation: 21, fullSamples: speech, tailSamples: speech)
        expectTrue(await waitForCall(.fullUtterance, generation: 21, in: transcriber))
        expectTrue(await transcriber.succeed(
            "current result",
            segment: .fullUtterance,
            generation: 21
        ))
        expectTrue(await waitForOutcomes(1, in: outcomes))
        XCTAssertEqual(outcomes.values, [
            .finalTranscript(generation: 21, text: "current result")
        ])

        expectTrue(await transcriber.succeed(
            "stale result",
            segment: .fullUtterance,
            generation: 20
        ))
        await settleAsyncWork()
        XCTAssertEqual(outcomes.values, [
            .finalTranscript(generation: 21, text: "current result")
        ])
    }

    func testEmptyVoicedTailFallsBackToFullUtterance() async {
        let transcriber = ControlledTranscriber()
        let cleaner = RecordingCleaner(mode: .unchanged)
        let outcomes = OutcomeRecorder()
        let pipeline = makePipeline(transcriber: transcriber, cleaner: cleaner, outcomes: outcomes)

        pipeline.begin(generation: 30, context: context())
        pipeline.processIncrementalChunk(
            generation: 30,
            samples: speech,
            pauseSecondsAfterChunk: 0.2
        )
        expectTrue(await waitForCall(.incrementalChunk(index: 0), generation: 30, in: transcriber))
        pipeline.release(
            generation: 30,
            fullSamples: speech + speech,
            tailSamples: speech
        )
        expectTrue(await transcriber.succeed(
            "partial result",
            segment: .incrementalChunk(index: 0),
            generation: 30
        ))
        expectTrue(await waitForCall(.releaseTail, generation: 30, in: transcriber))
        expectTrue(await transcriber.succeed(
            "",
            segment: .releaseTail,
            generation: 30
        ))

        expectTrue(await waitForCall(.fullUtterance, generation: 30, in: transcriber))
        expectTrue(await transcriber.succeed(
            "complete recovered result",
            segment: .fullUtterance,
            generation: 30
        ))

        expectTrue(await waitForOutcomes(1, in: outcomes))
        XCTAssertEqual(outcomes.values, [
            .finalTranscript(generation: 30, text: "complete recovered result")
        ])
    }

    func testFailedTailFallsBackToFullUtterance() async {
        let transcriber = ControlledTranscriber()
        let cleaner = RecordingCleaner(mode: .unchanged)
        let outcomes = OutcomeRecorder()
        let pipeline = makePipeline(transcriber: transcriber, cleaner: cleaner, outcomes: outcomes)

        pipeline.begin(generation: 31, context: context())
        pipeline.processIncrementalChunk(
            generation: 31,
            samples: speech,
            pauseSecondsAfterChunk: 0.2
        )
        expectTrue(await waitForCall(.incrementalChunk(index: 0), generation: 31, in: transcriber))
        pipeline.release(
            generation: 31,
            fullSamples: speech + speech,
            tailSamples: speech
        )
        expectTrue(await transcriber.succeed(
            "partial result",
            segment: .incrementalChunk(index: 0),
            generation: 31
        ))
        expectTrue(await waitForCall(.releaseTail, generation: 31, in: transcriber))
        expectTrue(await transcriber.fail(
            TestError.decodeFailed,
            segment: .releaseTail,
            generation: 31
        ))

        expectTrue(await waitForCall(.fullUtterance, generation: 31, in: transcriber))
        expectTrue(await transcriber.succeed(
            "complete recovered result",
            segment: .fullUtterance,
            generation: 31
        ))

        expectTrue(await waitForOutcomes(1, in: outcomes))
        XCTAssertEqual(outcomes.values, [
            .finalTranscript(generation: 31, text: "complete recovered result")
        ])
    }

    func testSuccessfulUnchangedCleanupEmitsWithoutRetry() async {
        let transcriber = ControlledTranscriber()
        let cleaner = RecordingCleaner(mode: .unchanged)
        let outcomes = OutcomeRecorder()
        let pipeline = makePipeline(transcriber: transcriber, cleaner: cleaner, outcomes: outcomes)

        pipeline.begin(generation: 40, context: context())
        pipeline.release(generation: 40, fullSamples: speech, tailSamples: speech)
        expectTrue(await waitForCall(.fullUtterance, generation: 40, in: transcriber))
        expectTrue(await transcriber.succeed(
            "Already clean.",
            segment: .fullUtterance,
            generation: 40
        ))

        expectTrue(await waitForOutcomes(1, in: outcomes))
        XCTAssertEqual(outcomes.values, [
            .finalTranscript(generation: 40, text: "Already clean.")
        ])
        expectEqual(await cleaner.requestTexts(), ["Already clean."])
        expectEqual(await transcriber.callCount(.fullUtterance, generation: 40), 1)
    }

    func testCleanupReceivesWholeUtteranceSoCorrectionCanCrossChunkBoundary() async {
        let transcriber = ControlledTranscriber()
        let cleaner = RecordingCleaner(mode: .replaceWith("Meet on Wednesday at two."))
        let outcomes = OutcomeRecorder()
        let pipeline = makePipeline(transcriber: transcriber, cleaner: cleaner, outcomes: outcomes)

        pipeline.begin(generation: 50, context: context())
        pipeline.processIncrementalChunk(
            generation: 50,
            samples: speech,
            pauseSecondsAfterChunk: 0.2
        )
        expectTrue(await waitForCall(.incrementalChunk(index: 0), generation: 50, in: transcriber))
        pipeline.release(
            generation: 50,
            fullSamples: speech + speech,
            tailSamples: speech
        )
        expectTrue(await transcriber.succeed(
            "Meet on Tuesday at two,",
            segment: .incrementalChunk(index: 0),
            generation: 50
        ))
        expectTrue(await waitForCall(.releaseTail, generation: 50, in: transcriber))
        expectTrue(await transcriber.succeed(
            "actually Wednesday.",
            segment: .releaseTail,
            generation: 50
        ))

        expectTrue(await waitForOutcomes(1, in: outcomes))
        expectEqual(await cleaner.requestTexts(), [
            "Meet on Tuesday at two, actually Wednesday."
        ])
        XCTAssertEqual(outcomes.values, [
            .finalTranscript(generation: 50, text: "Meet on Wednesday at two.")
        ])
    }

    private func makePipeline(
        transcriber: ControlledTranscriber,
        cleaner: RecordingCleaner,
        outcomes: OutcomeRecorder
    ) -> DictationSessionPipeline {
        DictationSessionPipeline(
            transcribe: { request in
                try await transcriber.transcribe(request)
            },
            cleanup: { request in
                await cleaner.clean(request)
            },
            onOutcome: { outcome in
                outcomes.append(outcome)
            }
        )
    }

    private func context(cleanupEnabled: Bool = true) -> DictationSessionContext {
        DictationSessionContext(
            cleanupEnabled: cleanupEnabled,
            styleProfile: .general,
            corrections: [],
            snippets: []
        )
    }

    private func waitForCall(
        _ segment: DictationTranscriptionSegment,
        generation: Int,
        in transcriber: ControlledTranscriber
    ) async -> Bool {
        for _ in 0..<10_000 {
            if await transcriber.hasCall(segment, generation: generation) { return true }
            await Task.yield()
        }
        return false
    }

    private func waitForOutcomes(_ count: Int, in recorder: OutcomeRecorder) async -> Bool {
        for _ in 0..<10_000 {
            if recorder.values.count == count { return true }
            await Task.yield()
        }
        return false
    }

    private func settleAsyncWork() async {
        for _ in 0..<100 { await Task.yield() }
    }

    private func expectTrue(
        _ value: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(value, file: file, line: line)
    }

    private func expectFalse(
        _ value: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(value, file: file, line: line)
    }

    private func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

private enum TestError: Error {
    case decodeFailed
}

private actor ControlledTranscriber {
    private struct PendingCall {
        let request: DictationTranscriptionRequest
        let continuation: CheckedContinuation<String, Error>
    }

    private var calls: [DictationTranscriptionRequest] = []
    private var pending: [PendingCall] = []

    func transcribe(_ request: DictationTranscriptionRequest) async throws -> String {
        calls.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(PendingCall(request: request, continuation: continuation))
        }
    }

    func hasCall(_ segment: DictationTranscriptionSegment, generation: Int) -> Bool {
        calls.contains { $0.generation == generation && $0.segment == segment }
    }

    func callCount(_ segment: DictationTranscriptionSegment, generation: Int) -> Int {
        calls.filter { $0.generation == generation && $0.segment == segment }.count
    }

    func succeed(
        _ text: String,
        segment: DictationTranscriptionSegment,
        generation: Int
    ) -> Bool {
        resolve(segment: segment, generation: generation, with: .success(text))
    }

    func fail(
        _ error: Error,
        segment: DictationTranscriptionSegment,
        generation: Int
    ) -> Bool {
        resolve(segment: segment, generation: generation, with: .failure(error))
    }

    private func resolve(
        segment: DictationTranscriptionSegment,
        generation: Int,
        with result: Result<String, Error>
    ) -> Bool {
        guard let index = pending.firstIndex(where: {
            $0.request.generation == generation && $0.request.segment == segment
        }) else { return false }
        let call = pending.remove(at: index)
        call.continuation.resume(with: result)
        return true
    }
}

private actor RecordingCleaner {
    enum Mode {
        case unchanged
        case replaceWith(String)
    }

    private let mode: Mode
    private var requests: [DictationCleanupRequest] = []

    init(mode: Mode) {
        self.mode = mode
    }

    func clean(_ request: DictationCleanupRequest) -> TranscriptCleanupResult {
        requests.append(request)
        switch mode {
        case .unchanged:
            return TranscriptCleanupResult(text: request.text, succeeded: true)
        case .replaceWith(let text):
            return TranscriptCleanupResult(text: text, succeeded: true)
        }
    }

    func requestTexts() -> [String] {
        requests.map(\.text)
    }
}

@MainActor
private final class OutcomeRecorder {
    private(set) var values: [DictationSessionOutcome] = []

    func append(_ outcome: DictationSessionOutcome) {
        values.append(outcome)
    }
}
