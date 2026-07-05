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
