import Foundation
import XCTest
@testable import LocalFlow

final class DiagnosticsSnapshotTests: XCTestCase {
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    func testInterleavedTracesKeepTheirOwnEventsInOrdinalOrder() throws {
        let text = try [
            line(event(firstID, ordinal: 2, name: .transcriptionFinished)),
            line(event(secondID, ordinal: 1, name: .hotkeyReleased, startedAt: 200)),
            line(event(firstID, ordinal: 0, name: .sessionStarted)),
            line(event(secondID, ordinal: 0, name: .sessionStarted, startedAt: 200)),
            line(event(firstID, ordinal: 1, name: .hotkeyReleased))
        ].joined(separator: "\n")

        let snapshot = DiagnosticsSnapshot.parse(text)
        XCTAssertEqual(snapshot.traces.map(\.id), [secondID, firstID])
        XCTAssertEqual(snapshot.traces[0].events.map(\.ordinal), [0, 1])
        XCTAssertEqual(snapshot.traces[1].events.map(\.ordinal), [0, 1, 2])
        XCTAssertTrue(snapshot.traces[0].events.allSatisfy { $0.traceID == secondID })
        XCTAssertTrue(snapshot.traces[1].events.allSatisfy { $0.traceID == firstID })
        XCTAssertEqual(snapshot.ignoredTimingLines, 0)
    }

    func testEqualStartTimesHaveStableUUIDOrdering() throws {
        let first = try line(event(firstID))
        let second = try line(event(secondID))
        let forward = DiagnosticsSnapshot.parse(first + "\n" + second)
        let reverse = DiagnosticsSnapshot.parse(second + "\n" + first)

        XCTAssertEqual(forward.traces.map(\.id), reverse.traces.map(\.id))
        XCTAssertEqual(Set(forward.traces.map(\.id)), [firstID, secondID])
    }

    func testEachTraceRetainsEnvironmentFromWhenItWasFirstSeen() throws {
        let text = try [
            environmentLine(["schemaVersion": "1", "pid": "100", "buildCommit": "old-build"]),
            line(event(firstID)),
            environmentLine(["schemaVersion": "1", "pid": "200", "buildCommit": "new-build"]),
            line(event(secondID, startedAt: 200)),
            line(event(firstID, ordinal: 1, name: .transcriptionFinished))
        ].joined(separator: "\n")

        let snapshot = DiagnosticsSnapshot.parse(text)
        XCTAssertEqual(snapshot.environment["buildCommit"], "new-build")
        XCTAssertEqual(snapshot.traces.first { $0.id == firstID }?.environment["pid"], "100")
        XCTAssertEqual(snapshot.traces.first { $0.id == firstID }?.environment["buildCommit"], "old-build")
        XCTAssertEqual(snapshot.traces.first { $0.id == secondID }?.environment["pid"], "200")
    }

    func testEnvironmentAndEventFieldsExcludeUnknownContent() throws {
        let allowed = [
            "schemaVersion": "1", "pid": "42", "osVersion": "test OS",
            "processorCount": "8", "memoryBytes": "1024", "hardwareModel": "test hardware",
            "chip": "test chip", "appVersion": "1.2.3", "buildConfiguration": "release",
            "buildCommit": "test-commit", "buildDirty": "true"
        ]
        var environment = allowed
        environment["transcript"] = "private transcript fixture"
        environment["username"] = "private username fixture"
        environment["clipboard"] = "private clipboard fixture"
        let fixture = event(firstID, fields: ["durationMs": 250, "tailSamples": 160, "transcript": 8675309],
                            model: "test-whisper-model", microphone: "test microphone")
        let snapshot = DiagnosticsSnapshot.parse(try environmentLine(environment) + "\n" + line(fixture))
        let trace = try XCTUnwrap(snapshot.traces.first)
        let parsedEvent = try XCTUnwrap(trace.events.first)

        XCTAssertEqual(snapshot.environment, allowed)
        XCTAssertEqual(trace.environment, allowed)
        XCTAssertEqual(parsedEvent.fields, ["durationMs": 250, "tailSamples": 160])
        XCTAssertEqual(parsedEvent.model, "test-whisper-model")
        XCTAssertEqual(parsedEvent.microphone, "test microphone")
        let serialized = String(decoding: try JSONEncoder().encode(trace.events), as: UTF8.self)
        XCTAssertFalse(serialized.contains("8675309"))
        XCTAssertFalse(serialized.contains("private"))
    }

    func testMalformedAndUnsupportedTimingLinesAreCountedWithoutDiscardingValidEvents() throws {
        let text = try [
            "2026-09-08 12:00:00.000 ordinary diagnostic message",
            "2026-09-08 12:00:00.000 timing {broken-json",
            "2026-09-08 12:00:00.000 timing {}",
            line(event(firstID, schemaVersion: 2)),
            "2026-09-08 12:00:00.000 timing_environment {broken-json",
            line(event(secondID))
        ].joined(separator: "\n")

        let snapshot = DiagnosticsSnapshot.parse(text)
        XCTAssertEqual(snapshot.ignoredTimingLines, 3)
        XCTAssertEqual(snapshot.traces.map(\.id), [secondID])
        XCTAssertTrue(snapshot.environment.isEmpty)
    }

    func testRawLogMessagesAndEmbeddedTimingPayloadsDoNotBecomeTraces() throws {
        let timingLine = try line(event(firstID))
        let text = "2026-09-08 12:00:00.000 transcript private fixture\n"
            + "2026-09-08 12:00:00.000 diagnostic quoted payload: " + timingLine
        let snapshot = DiagnosticsSnapshot.parse(text)

        XCTAssertTrue(snapshot.traces.isEmpty)
        XCTAssertTrue(snapshot.environment.isEmpty)
        XCTAssertEqual(snapshot.ignoredTimingLines, 0)
    }

    func testDispatchUsesFirstSuccessfulDispatchNotQueueReadinessOrClipboardRestoration() throws {
        let text = try [
            line(event(firstID, ordinal: 4, name: .clipboardWindowResolved, releaseMs: 3000, status: .unchangedClipboard)),
            line(event(firstID, ordinal: 3, name: .pasteDispatched, releaseMs: 700, status: .success)),
            line(event(firstID, ordinal: 0, name: .resultReady, releaseMs: 100, status: .success)),
            line(event(firstID, ordinal: 1, name: .pasteDispatched, releaseMs: 200, status: .failed)),
            line(event(firstID, ordinal: 2, name: .pasteDispatched, releaseMs: 500, status: .success))
        ].joined(separator: "\n")

        XCTAssertEqual(DiagnosticsSnapshot.parse(text).traces.first?.dispatchMs, 500)
    }

    func testSuccessfulTypingDispatchCountsAfterPasteFailure() throws {
        let text = try [
            line(event(firstID, ordinal: 0, name: .pasteDispatched, releaseMs: 100, status: .failed)),
            line(event(firstID, ordinal: 1, name: .typingStarted, releaseMs: 150)),
            line(event(firstID, ordinal: 2, name: .typingDispatched, releaseMs: 600, status: .success))
        ].joined(separator: "\n")

        XCTAssertEqual(DiagnosticsSnapshot.parse(text).traces.first?.dispatchMs, 600)
    }

    func testMissingOrUnsuccessfulDispatchHasNoReleaseToDispatchMeasurement() throws {
        let cases: [[DictationTrace.Event]] = [
            [event(firstID, name: .resultReady, releaseMs: 100, status: .success),
             event(firstID, ordinal: 1, name: .clipboardWindowResolved, releaseMs: 2600, status: .unchangedClipboard)],
            [event(firstID, name: .pasteDispatched, releaseMs: 100, status: .failed)],
            [event(firstID, name: .typingDispatched, releaseMs: 100, status: .failed)],
            [event(firstID, name: .pasteDispatched, releaseMs: 100)],
            [event(firstID, name: .pasteDispatched, status: .success)]
        ]
        for events in cases {
            let snapshot = DiagnosticsSnapshot.parse(try events.map(line).joined(separator: "\n"))
            XCTAssertEqual(snapshot.traces.count, 1)
            XCTAssertNil(snapshot.traces.first?.dispatchMs)
        }
    }

    private func event(
        _ id: UUID, ordinal: Int = 0, name: DictationTrace.Name = .sessionStarted,
        startedAt: TimeInterval = 100, releaseMs: Double? = nil,
        status: DictationTrace.Status? = nil, fields: [String: Double] = [:],
        model: String? = nil, microphone: String? = nil, schemaVersion: Int = 1
    ) -> DictationTrace.Event {
        .init(schemaVersion: schemaVersion, traceID: id, source: .dictation, ordinal: ordinal,
              name: name, uptimeNs: UInt64(ordinal + 1) * 1_000_000,
              sinceStartMs: Double(ordinal), sinceReleaseMs: releaseMs,
              startedAt: Date(timeIntervalSince1970: startedAt), status: status,
              fields: fields, model: model, segment: nil, microphone: microphone)
    }

    private func line(_ event: DictationTrace.Event) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return "2026-09-08 12:00:00.000 timing " + String(decoding: try encoder.encode(event), as: UTF8.self)
    }

    private func environmentLine(_ values: [String: String]) throws -> String {
        "2026-09-08 12:00:00.000 timing_environment " + String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
    }
}
