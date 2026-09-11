import XCTest
@testable import LocalFlow

@MainActor
final class DictationDiagnosticPipelineTests: XCTestCase {
    private let speech = [Float](repeating: 0.2, count: 16_000)
    private let context = DictationSessionContext(
        cleanupEnabled: true, styleProfile: .general,
        corrections: [(wrong: "teh", right: "the")], snippets: []
    )

    func testArchiveKeepsEmptyRetryRawFormattedAndCleanedStages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationDiagnosticStore(folder: root)
        let trace = DictationTrace(sink: { _ in })
        let recording = store.begin(.init(traceID: trace.id, context: context, whisperModel: "test",
                                          microphone: "test", vocabulary: ""))
        var calls = 0
        let delivered = expectation(description: "Delivered cleaned text")
        let pipeline = DictationSessionPipeline(transcribe: { _ in
            XCTAssertEqual(DictationDiagnosticStore.Recording.current?.id, trace.id)
            calls += 1
            return calls == 1 ? "" : "teh final five words"
        }, cleanup: { request in
            XCTAssertEqual(DictationDiagnosticStore.Recording.current?.id, trace.id)
            XCTAssertEqual(request.text, "the final five words")
            return TranscriptCleanupResult(text: "The final five words.", succeeded: true)
        }, onOutcome: { outcome in
            XCTAssertEqual(outcome, .finalTranscript(generation: 1, text: "The final five words."))
            delivered.fulfill()
        })
        pipeline.begin(generation: 1, context: context, trace: trace, diagnostics: recording)
        pipeline.release(generation: 1, fullSamples: speech)
        await fulfillment(of: [delivered], timeout: 5)
        store.flush()
        let events = try readEvents(root, id: trace.id)
        XCTAssertEqual(events.filter { $0.stage == "transcriptionResult" }.map(\.text), ["", "teh final five words"])
        XCTAssertEqual(events.first { $0.stage == "assembledTranscript" }?.text, "teh final five words")
        XCTAssertEqual(events.first { $0.stage == "cleanupInput" }?.text, "the final five words")
        XCTAssertEqual(events.first { $0.stage == "cleanupOutput" }?.text, "The final five words.")
        XCTAssertEqual(events.last?.stage, "finalTranscript")
        let directory = root.appendingPathComponent(trace.id.uuidString)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("original.wav").path))
        let timing = try String(contentsOf: directory.appendingPathComponent("timing.jsonl"))
        XCTAssertTrue(timing.contains("fullRetry"))
        XCTAssertFalse(timing.contains("final five words"))
    }

    func testFailedAndCancelledSessionsRetainCapturedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationDiagnosticStore(folder: root)
        let id = UUID()
        let recording = store.begin(.init(traceID: id, context: context, whisperModel: "test",
                                          microphone: "test", vocabulary: ""))
        let delivered = expectation(description: "Failure delivered")
        let pipeline = DictationSessionPipeline(transcribe: { _ in throw CocoaError(.fileReadUnknown) },
            cleanup: { _ in XCTFail("Failure must skip cleanup"); return .init(text: "", succeeded: false) },
            onOutcome: { outcome in
                guard case .failed = outcome else { return XCTFail("Expected failure") }
                delivered.fulfill()
            })
        pipeline.begin(generation: 1, context: context, diagnostics: recording)
        pipeline.release(generation: 1, fullSamples: speech)
        await fulfillment(of: [delivered], timeout: 5)
        store.flush()
        XCTAssertEqual(try readEvents(root, id: id).last?.status, "failed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(id)/original.wav").path))

        let cancelledID = UUID()
        let cancelledRecording = store.begin(.init(traceID: cancelledID, context: context, whisperModel: "test",
                                                   microphone: "test", vocabulary: ""))
        pipeline.begin(generation: 2, context: context, diagnostics: cancelledRecording)
        // Capture may finish before cancellation arrives.
        pipeline.recordCapturedAudio(generation: 2, samples: [Float](repeating: 0, count: 8000))
        pipeline.cancel(generation: 2)
        store.flush()
        XCTAssertEqual(try readEvents(root, id: cancelledID).last?.status, "cancelled")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(cancelledID)/original.wav").path))
    }

    func testNoRecordingIsAttachedByDefault() async {
        let delivered = expectation(description: "Delivered without archive")
        let pipeline = DictationSessionPipeline(transcribe: { _ in
            XCTAssertNil(DictationDiagnosticStore.Recording.current)
            return "hello"
        }, cleanup: { request in
            XCTAssertNil(DictationDiagnosticStore.Recording.current)
            return .init(text: request.text, succeeded: true)
        }, onOutcome: { _ in delivered.fulfill() })
        pipeline.begin(generation: 1, context: context)
        pipeline.release(generation: 1, fullSamples: speech)
        await fulfillment(of: [delivered], timeout: 5)
    }

    private func readEvents(_ root: URL, id: UUID) throws -> [DictationDiagnosticStore.Event] {
        let data = try Data(contentsOf: root.appendingPathComponent("\(id)/events.jsonl"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try data.split(separator: 0x0a).map { try decoder.decode(DictationDiagnosticStore.Event.self, from: Data($0)) }
    }
}
