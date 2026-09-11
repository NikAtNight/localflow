import AVFoundation
import XCTest
@testable import LocalFlow

@MainActor
final class DictationAudioPreparationTests: XCTestCase {
    private let context = DictationSessionContext(
        cleanupEnabled: false, styleProfile: .general, corrections: [], snippets: []
    )

    func testQuietReleaseRetainsOriginalBeforeDecoderAndReusesPreparedAudioForRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationDiagnosticStore(folder: root)
        let id = UUID()
        let recording = store.begin(.init(traceID: id, context: context, whisperModel: "test",
                                          microphone: "synthetic-input", vocabulary: ""))
        let quiet = audio(0.005, seconds: 1)
        let original = audio(0, seconds: 1) + quiet + audio(0, seconds: 1)
        let delivered = expectation(description: "retry delivered")
        var requests: [DictationTranscriptionRequest] = []
        let pipeline = DictationSessionPipeline(transcribe: { request in
            store.flush()
            let file = try AVAudioFile(forReading: root.appendingPathComponent("\(id)/original.wav"))
            XCTAssertEqual(file.length, AVAudioFramePosition(original.count))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
            ))
            var retained: [Float] = []
            // AVAudioFile can return fewer frames than requested.
            while file.framePosition < file.length {
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                let channel = try XCTUnwrap(buffer.floatChannelData?[0])
                retained.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
            XCTAssertEqual(retained.count, original.count)
            XCTAssertTrue(retained == original, "The archive retains every original sample before trimming")
            requests.append(request)
            return requests.count == 1 ? "" : "recovered"
        }, cleanup: { request in
            XCTFail("Cleanup is disabled")
            return .init(text: request.text, succeeded: true)
        }, onOutcome: { outcome in
            XCTAssertEqual(outcome, .finalTranscript(generation: 1, text: "recovered"))
            delivered.fulfill()
        })
        pipeline.begin(generation: 1, context: context, diagnostics: recording)
        pipeline.release(generation: 1, fullSamples: original)
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(requests.map(\.segment), [.fullUtterance, .fullUtterance])
        for request in requests {
            XCTAssertEqual(request.samples.count, 24_000)
            XCTAssertEqual(request.samples.firstIndex { $0 != 0 }, 4_000)
            XCTAssertEqual(request.samples.lastIndex { $0 != 0 }, 19_999)
            XCTAssertTrue(request.samples.filter { $0 != 0 }.allSatisfy { $0 == 0.005 })
        }
        XCTAssertTrue(requests.first?.samples == requests.last?.samples, "Retry uses the same prepared audio")
        XCTAssertEqual(requests.map(\.lowEnergy), [true, true])
    }

    func testReleaseAdmissionUsesVoicedTimeAndPreservesQuietThreshold() async {
        let delivered = expectation(description: "admitted and rejected outcomes")
        delivered.expectedFulfillmentCount = 5
        var requests: [DictationTranscriptionRequest] = []
        var outcomes: [DictationSessionOutcome] = []
        let pipeline = DictationSessionPipeline(transcribe: { request in
            requests.append(request)
            return "accepted"
        }, cleanup: { request in .init(text: request.text, succeeded: true) }, onOutcome: { outcome in
            outcomes.append(outcome)
            delivered.fulfill()
        })
        // Bare captures align speech to 20 ms frames for the exact duration gate.
        // Trim padding can shift windows by 10 ms, making 280 ms span 15 voiced frames.
        // The last capture checks that long pauses do not dilute voiced energy.
        let samples = [
            audio(0.2, seconds: 0.28),
            audio(0.005, seconds: 0.3),
            audio(0.01, seconds: 0.3),
            audio(0.02, seconds: 0.3),
            audio(0, seconds: 1) + audio(0.005, seconds: 0.3) + audio(0, seconds: 1)
        ]
        for (generation, sample) in samples.enumerated() {
            pipeline.begin(generation: generation, context: context)
            pipeline.release(generation: generation, fullSamples: sample)
        }
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(outcomes, [
            .insufficientVoice(generation: 0),
            .finalTranscript(generation: 1, text: "accepted"),
            .finalTranscript(generation: 2, text: "accepted"),
            .finalTranscript(generation: 3, text: "accepted"),
            .finalTranscript(generation: 4, text: "accepted")
        ])
        XCTAssertEqual(requests.map(\.generation).sorted(), [1, 2, 3, 4])
        XCTAssertEqual(requests.first { $0.generation == 1 }?.lowEnergy, true)
        XCTAssertEqual(requests.first { $0.generation == 2 }?.lowEnergy, false)
        XCTAssertEqual(requests.first { $0.generation == 3 }?.lowEnergy, false)
        XCTAssertEqual(requests.first { $0.generation == 4 }?.lowEnergy, true)
    }

    func testIncrementalSnapshotAndReleaseTailUseSamePreparation() async {
        let quiet = audio(0.005, seconds: 2)
        let loud = audio(0.2, seconds: 3.5)
        let original = audio(0, seconds: 0.5) + quiet + audio(0, seconds: 2) + loud
        let chunkStarted = expectation(description: "incremental snapshot admitted")
        let delivered = expectation(description: "chunk and tail delivered")
        var requests: [DictationTranscriptionRequest] = []
        let pipeline = DictationSessionPipeline(transcribe: { request in
            requests.append(request)
            if case .incrementalChunk = request.segment {
                chunkStarted.fulfill()
                return "first"
            }
            return "second"
        }, cleanup: { request in .init(text: request.text, succeeded: true) }, onOutcome: { outcome in
            XCTAssertEqual(outcome, .finalTranscript(generation: 1, text: "first second"))
            delivered.fulfill()
        })
        pipeline.begin(generation: 1, context: context)
        pipeline.processIncrementalSnapshot(generation: 1, samples: original)
        await fulfillment(of: [chunkStarted], timeout: 2)
        pipeline.release(generation: 1, fullSamples: original)
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(requests.map(\.segment), [.incrementalChunk(index: 0), .releaseTail])
        XCTAssertEqual(requests.first?.samples.count, 40_000)
        XCTAssertEqual(requests.first?.samples.firstIndex { $0 != 0 }, 4_000)
        XCTAssertEqual(requests.first?.samples.lastIndex { $0 != 0 }, 35_999)
        XCTAssertTrue(requests.first?.samples.filter { $0 != 0 }.allSatisfy { $0 == 0.005 } == true)
        XCTAssertEqual(requests.first?.lowEnergy, true)
        XCTAssertEqual(requests.last?.lowEnergy, false)
        XCTAssertTrue(requests.last?.samples.suffix(loud.count).elementsEqual(loud) == true)
    }

    func testTrimmedAdmissionKeepsOriginalWindowRuleForEmptyRetry() async {
        // A 250 ms trim pad shifts 20 ms windows by half a frame. This capture
        // passes trimmed admission but has only 280 ms of voice in the original.
        let original = audio(0, seconds: 1) + audio(0.2, seconds: 0.28) + audio(0, seconds: 1)
        var requests = 0
        let delivered = expectation(description: "empty result without extra retry")
        let pipeline = DictationSessionPipeline(transcribe: { _ in
            requests += 1
            return ""
        }, cleanup: { request in .init(text: request.text, succeeded: true) }, onOutcome: { outcome in
            XCTAssertEqual(outcome, .emptyTranscript(generation: 1))
            delivered.fulfill()
        })
        pipeline.begin(generation: 1, context: context)
        pipeline.release(generation: 1, fullSamples: original)
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(requests, 1)
    }

    func testEmptyTailPreservesCommittedTranscriptWithoutDecoderOrFallback() async {
        let speech = audio(0.2, seconds: 1)
        var segments: [DictationTranscriptionSegment] = []
        let delivered = expectation(description: "committed transcript delivered")
        let pipeline = DictationSessionPipeline(transcribe: { request in
            segments.append(request.segment)
            return "committed text"
        }, cleanup: { request in .init(text: request.text, succeeded: true) }, onOutcome: { outcome in
            XCTAssertEqual(outcome, .finalTranscript(generation: 1, text: "committed text"))
            delivered.fulfill()
        })
        pipeline.begin(generation: 1, context: context)
        pipeline.processIncrementalChunk(generation: 1, samples: speech, pauseSecondsAfterChunk: 0,
                                         sourceEndIndex: speech.count)
        pipeline.release(generation: 1, fullSamples: speech)
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(segments, [.incrementalChunk(index: 0)])
    }

    func testRejectedReleaseRetainsAudioAndCancelledArchiveStatus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationDiagnosticStore(folder: root)
        let id = UUID()
        let recording = store.begin(.init(traceID: id, context: context, whisperModel: "test",
                                          microphone: "synthetic-input", vocabulary: ""))
        var outcomes: [DictationSessionOutcome] = []
        let pipeline = DictationSessionPipeline(transcribe: { _ in
            XCTFail("Rejected audio must not reach inference")
            return ""
        }, cleanup: { request in
            XCTFail("Rejected audio must not reach cleanup")
            return .init(text: request.text, succeeded: true)
        }, onOutcome: { outcomes.append($0) })
        pipeline.begin(generation: 1, context: context, diagnostics: recording)
        pipeline.release(generation: 1, fullSamples: audio(0, seconds: 1))
        store.flush()
        XCTAssertEqual(outcomes, [.insufficientVoice(generation: 1)])
        let file = try AVAudioFile(forReading: root.appendingPathComponent("\(id)/original.wav"))
        XCTAssertEqual(file.length, 16_000)
        let data = try Data(contentsOf: root.appendingPathComponent("\(id)/events.jsonl"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = try data.split(separator: 0x0a).map {
            try decoder.decode(DictationDiagnosticStore.Event.self, from: Data($0))
        }
        XCTAssertEqual(events.map(\.stage), ["capture", "outcome"])
        XCTAssertEqual(events.last?.status, "cancelled")
    }

    private func audio(_ amplitude: Float, seconds: Double) -> [Float] {
        Array(repeating: amplitude, count: Int(seconds * AudioRecorder.sampleRate))
    }
}
