import Foundation
import XCTest
@testable import LocalFlow

final class TraceEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DictationTrace.Event] = []
    var onEvent: (@Sendable (DictationTrace.Event) -> Void)?

    var events: [DictationTrace.Event] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ event: DictationTrace.Event) {
        lock.lock()
        stored.append(event)
        lock.unlock()
        onEvent?(event)
    }
}

private final class TraceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: UInt64 = 0
    func now() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return time
    }
    func advance(milliseconds: UInt64) {
        lock.lock()
        time += milliseconds * 1_000_000
        lock.unlock()
    }
}

@MainActor
final class DictationTraceTests: XCTestCase {
    func testReleaseAnchorDoesNotMoveAndClipboardTimeIsSeparate() {
        let clock = TraceClock()
        let events = TraceEvents()
        let trace = DictationTrace(now: { clock.now() }, sink: { events.append($0) })
        trace.record(.hotkeyPressed)
        clock.advance(milliseconds: 5_000)
        trace.record(.hotkeyReleased)
        clock.advance(milliseconds: 100)
        trace.record(.resultReady)
        clock.advance(milliseconds: 400)
        let dispatched = trace.record(.pasteDispatched)
        clock.advance(milliseconds: 2_500)
        let restored = trace.record(.clipboardWindowResolved)
        trace.record(.hotkeyReleased)

        XCTAssertEqual(dispatched.sinceReleaseMs, 500)
        XCTAssertEqual(restored.sinceReleaseMs, 3_000)
        XCTAssertEqual(trace.millisecondsSinceRelease, 3_000)
        XCTAssertEqual(events.events.map(\.ordinal), Array(0..<6))
    }

    func testConcurrentWritersKeepOneTraceAndUniqueOrdinals() async {
        let events = TraceEvents()
        let trace = DictationTrace(sink: { events.append($0) })
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { trace.record(.engineWaitStarted) }
            }
        }
        XCTAssertEqual(events.events.map(\.ordinal), Array(0..<100))
        XCTAssertEqual(Set(events.events.map(\.traceID)), [trace.id])
        XCTAssertEqual(events.events.map(\.uptimeNs), events.events.map(\.uptimeNs).sorted())
    }

    func testInjectionWaitingDoesNotMasqueradeAsProcessingTime() async {
        let clock = TraceClock()
        let events = TraceEvents()
        let trace = DictationTrace(now: { clock.now() }, sink: { events.append($0) })
        trace.record(.hotkeyReleased)
        trace.record(.resultReady)
        let dispatched = expectation(description: "second output dispatched")
        var outputs: [String] = []
        let queue = InjectionCoordinator(
            stallTimeout: 1, injectionInterval: 0.01,
            onInject: { text in
                outputs.append(text)
                DictationTrace.current?.record(.pasteDispatched)
                if text == "second" { dispatched.fulfill() }
            }, onCancel: { _, _ in XCTFail("unexpected cancellation") },
            onProcessingCountChange: { _ in }
        )
        let first = queue.begin(kind: .dictation)
        let second = queue.begin(kind: .dictation, trace: trace)
        queue.complete(second, with: .inject("second"))
        XCTAssertFalse(events.events.contains { $0.name == .pasteDispatched })
        clock.advance(milliseconds: 300)
        queue.complete(first, with: .inject("first"))
        clock.advance(milliseconds: 400)
        await fulfillment(of: [dispatched], timeout: 1)

        XCTAssertEqual(outputs, ["first", "second"])
        XCTAssertEqual(events.events.first { $0.name == .resultReady }?.sinceReleaseMs, 0)
        XCTAssertEqual(events.events.first { $0.name == .injectionQueued }?.sinceReleaseMs, 0)
        XCTAssertEqual(events.events.first { $0.name == .pasteDispatched }?.sinceReleaseMs, 700)
    }

    func testTracePreservesFormattingAndDoesNotSerializeTranscriptContent() async throws {
        let events = TraceEvents()
        let trace = DictationTrace(sink: { events.append($0) })
        let secret = "private-reference-8675309"
        let context = DictationSessionContext(
            cleanupEnabled: false, styleProfile: .general,
            corrections: [(wrong: "helo", right: "hello")],
            snippets: [(trigger: "insert secret", expansion: secret)]
        )
        let untraced = await output(context: context, trace: nil)
        let traced = await output(context: context, trace: trace)
        XCTAssertEqual(traced, untraced)
        XCTAssertTrue(traced.contains(secret))
        XCTAssertTrue(traced.contains("\n\n"))
        let encoded = String(decoding: try JSONEncoder().encode(events.events), as: UTF8.self)
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains("helo"))
        XCTAssertFalse(encoded.contains("insert secret"))
        XCTAssertEqual(events.events.filter { $0.name == .resultDelivered }.count, 1)
    }

    private func output(context: DictationSessionContext, trace: DictationTrace?) async -> String {
        let finished = expectation(description: "pipeline completed")
        var output = ""
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in "helo new paragraph insert secret" },
            cleanup: { _ in XCTFail("cleanup disabled"); return .init(text: "", succeeded: false) },
            onOutcome: { outcome in
                if case .finalTranscript(_, let text) = outcome { output = text }
                else { XCTFail("expected transcript") }
                finished.fulfill()
            }
        )
        pipeline.begin(generation: 0, context: context, trace: trace)
        pipeline.release(generation: 0, fullSamples: Array(repeating: 0.2, count: 16_000))
        await fulfillment(of: [finished], timeout: 1)
        withExtendedLifetime(pipeline) {}
        return output
    }

    func testReleaseReportsSubmittedButNotYetCompletedAudio() async {
        let events = TraceEvents()
        let trace = DictationTrace(sink: { events.append($0) })
        let chunkStarted = expectation(description: "chunk started")
        let finished = expectation(description: "pipeline completed")
        var chunk: CheckedContinuation<String, Never>?
        let pipeline = DictationSessionPipeline(
            transcribe: { request in
                if case .incrementalChunk = request.segment {
                    return await withCheckedContinuation { continuation in
                        chunk = continuation
                        chunkStarted.fulfill()
                    }
                }
                return "tail"
            }, cleanup: { request in .init(text: request.text, succeeded: true) },
            onOutcome: { _ in finished.fulfill() }
        )
        pipeline.begin(generation: 0, context: .init(cleanupEnabled: false, styleProfile: .general, corrections: [], snippets: []), trace: trace)
        pipeline.processIncrementalChunk(generation: 0, samples: Array(repeating: 0.2, count: 6_400), pauseSecondsAfterChunk: 0, sourceEndIndex: 6_400)
        await fulfillment(of: [chunkStarted], timeout: 1)
        trace.record(.hotkeyReleased)
        pipeline.release(generation: 0, fullSamples: Array(repeating: 0.2, count: 16_000))
        let release = events.events.first { $0.name == .audioReleased }
        XCTAssertEqual(release?.fields["submittedEnd"], 6_400)
        XCTAssertEqual(release?.fields["completedEnd"], 0)
        XCTAssertEqual(release?.fields["tailSamples"], 9_600)
        chunk?.resume(returning: "chunk")
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(events.events.first { $0.name == .chunkCompleted }?.fields["completedEnd"], 6_400)
    }

    func testCancelledWorkRecordsItsActualReturnButNeverDeliversText() async {
        let events = TraceEvents()
        let trace = DictationTrace(sink: { events.append($0) })
        let started = expectation(description: "inference started")
        let returned = expectation(description: "cancelled operation returned")
        events.onEvent = { event in
            if event.name == .transcriptionFinished { returned.fulfill() }
        }
        var operation: CheckedContinuation<String, Never>?
        let pipeline = DictationSessionPipeline(
            transcribe: { _ in
                await withCheckedContinuation { continuation in
                    operation = continuation
                    started.fulfill()
                }
            }, cleanup: { request in .init(text: request.text, succeeded: true) },
            onOutcome: { _ in XCTFail("cancelled output delivered") }
        )
        pipeline.begin(generation: 0, context: .init(cleanupEnabled: false, styleProfile: .general, corrections: [], snippets: []), trace: trace)
        pipeline.release(generation: 0, fullSamples: Array(repeating: 0.2, count: 16_000))
        await fulfillment(of: [started], timeout: 1)
        pipeline.cancel(generation: 0)
        XCTAssertEqual(events.events.last?.name, .cancellationRequested)
        XCTAssertFalse(events.events.contains { $0.name == .transcriptionFinished })
        operation?.resume(returning: "late result")
        await fulfillment(of: [returned], timeout: 1)
        XCTAssertEqual(events.events.last?.status, .cancelled)
        XCTAssertFalse(events.events.contains { $0.name == .resultDelivered })
    }
}
