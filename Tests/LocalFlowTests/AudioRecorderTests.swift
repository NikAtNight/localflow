import XCTest
@testable import LocalFlow

/// RMS energy measurement that AppDelegate uses to tell silence from speech.
final class AudioRecorderTests: XCTestCase {

    func testFullScaleSineIsAboutMinus3dBFS() {
        // A full-scale sine has RMS 1/√2, i.e. ~-3.01 dBFS.
        let n = 16_000
        let sine = (0..<n).map { Float(sin(2 * Double.pi * Double($0) / 128.0)) }
        XCTAssertEqual(AudioRecorder.rmsDBFS(of: sine), -3.01, accuracy: 0.05)
    }

    func testConstantAmplitudeMapsToExpectedDBFS() {
        // A constant signal's RMS equals its amplitude, so 0.001 → -60 dBFS.
        let quiet = [Float](repeating: 0.001, count: 4_000)
        XCTAssertEqual(AudioRecorder.rmsDBFS(of: quiet), -60, accuracy: 0.01)
    }

    func testEmptyBufferIsNegativeInfinity() {
        XCTAssertEqual(AudioRecorder.rmsDBFS(of: []), -.infinity)
    }

    func testAllZeroBufferIsNegativeInfinity() {
        XCTAssertEqual(AudioRecorder.rmsDBFS(of: [Float](repeating: 0, count: 1_000)), -.infinity)
    }

    func testStraddlesTheMinus55SilenceFloor() {
        // AppDelegate gates transcription on dBFS > -55. -55 dBFS ≈ 0.001778 RMS.
        let aboveFloor = [Float](repeating: 0.0025, count: 2_000) // ≈ -52 dBFS
        let belowFloor = [Float](repeating: 0.0012, count: 2_000) // ≈ -58 dBFS
        XCTAssertGreaterThan(AudioRecorder.rmsDBFS(of: aboveFloor), -55)
        XCTAssertLessThan(AudioRecorder.rmsDBFS(of: belowFloor), -55)
    }
}

/// Frame-level voiced-audio metrics and silence trimming: the gate that
/// replaced whole-capture RMS (which every thinking pause diluted).
final class VoicedAudioTests: XCTestCase {
    private let rate = Int(AudioRecorder.sampleRate)

    /// `seconds` of speech-loud signal (~-15 dBFS) between two silences.
    private func speechBetweenSilence(lead: Double, speech: Double, tail: Double) -> [Float] {
        [Float](repeating: 0, count: Int(lead * Double(rate)))
            + [Float](repeating: 0.18, count: Int(speech * Double(rate)))
            + [Float](repeating: 0, count: Int(tail * Double(rate)))
    }

    func testVoicedSecondsCountOnlyTheSpeech() {
        let samples = speechBetweenSilence(lead: 2, speech: 1, tail: 2)
        let metrics = AudioRecorder.voicedMetrics(of: samples)
        XCTAssertEqual(metrics.voicedSeconds, 1.0, accuracy: 0.05)
        // ~-15 dBFS: the pauses must not drag the level down.
        XCTAssertEqual(metrics.voicedDBFS, 20 * log10(0.18), accuracy: 0.5)
    }

    func testWholeCaptureRMSWouldHaveGatedThisDictationOut() {
        // 1s of quiet (-36.5 dBFS) speech inside 3 minutes of silence: the
        // old whole-capture RMS dilutes below the old -55 gate and would
        // have reported "heard nothing"; the voiced metrics see the speech.
        let samples = [Float](repeating: 0, count: 90 * rate)
            + [Float](repeating: 0.015, count: rate)
            + [Float](repeating: 0, count: 89 * rate)
        XCTAssertLessThan(AudioRecorder.rmsDBFS(of: samples), -55)
        let metrics = AudioRecorder.voicedMetrics(of: samples)
        XCTAssertGreaterThan(metrics.voicedSeconds, 0.9)
        XCTAssertGreaterThan(metrics.voicedDBFS, -40)
    }

    func testSilenceHasNoVoicedTime() {
        let silent = [Float](repeating: 0, count: rate)
        let metrics = AudioRecorder.voicedMetrics(of: silent)
        XCTAssertEqual(metrics.voicedSeconds, 0)
        XCTAssertEqual(metrics.voicedDBFS, -.infinity)
    }

    func testTrimmingKeepsSpeechPlusPadding() {
        let samples = speechBetweenSilence(lead: 3, speech: 1, tail: 3)
        let trimmed = AudioRecorder.trimmingSilence(samples)
        let seconds = Double(trimmed.count) / AudioRecorder.sampleRate
        // 1s speech + ≤0.25s padding each side (frame quantization slack).
        XCTAssertEqual(seconds, 1.5, accuracy: 0.1)
        // The loud region survives intact.
        XCTAssertEqual(trimmed.filter { $0 > 0.1 }.count, rate)
    }

    func testTrimmingLeavesAllSilentAudioUntouched() {
        let silent = [Float](repeating: 0, count: rate)
        XCTAssertEqual(AudioRecorder.trimmingSilence(silent).count, silent.count)
    }

    func testTrimmingLeavesWallToWallSpeechUntouched() {
        let speech = [Float](repeating: 0.2, count: rate)
        XCTAssertEqual(AudioRecorder.trimmingSilence(speech).count, speech.count)
    }
}
