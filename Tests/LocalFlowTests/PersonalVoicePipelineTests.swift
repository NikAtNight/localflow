import AVFoundation
import XCTest
@testable import LocalFlow

@MainActor
final class PersonalVoicePipelineTests: XCTestCase {
    func testNativeOriginalAndRawTranscriptSurviveWithDiagnosticsDisabled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonalVoiceStore(folder: root)
        let context = DictationSessionContext(cleanupEnabled: true, styleProfile: .general, corrections: [], snippets: [])
        let recording = store.begin(.init(traceID: UUID(), context: context, whisperModel: "test", microphone: "test", vocabulary: ""))
        let completed = expectation(description: "dictation delivered")
        let pipeline = DictationSessionPipeline(transcribe: { _ in "Um, here are the words." },
            cleanup: { _ in .init(text: "Here are the words.", succeeded: true) },
            onOutcome: { outcome in
                XCTAssertEqual(outcome, .finalTranscript(generation: 1, text: "Here are the words."))
                completed.fulfill()
            })
        pipeline.begin(generation: 1, context: context, trace: nil, diagnostics: nil, personalVoice: recording)
        let native = NativeAudioRecording(samples: Array(repeating: 0.25, count: 48_000), sampleRate: 48_000, isComplete: true)
        let speech = Array(repeating: Float(0.2), count: 16_000)
        pipeline.recordCapturedAudio(generation: 1, samples: speech, nativeAudio: native)
        pipeline.release(generation: 1, fullSamples: speech)
        await fulfillment(of: [completed], timeout: 5)
        let snapshot = try await store.snapshot()
        let clip = try XCTUnwrap(snapshot.clips.first)
        XCTAssertEqual(clip.sampleRate, 48_000)
        XCTAssertEqual(clip.rawTranscript, "Um, here are the words.")
        XCTAssertEqual(clip.finalTranscript, "Here are the words.")
        XCTAssertFalse(clip.approved)
        let audio = try AVAudioFile(forReading: store.audioURL(for: clip.id))
        XCTAssertEqual(audio.length, 48_000)
        XCTAssertEqual(snapshot.clips.count, 1)
    }
}
