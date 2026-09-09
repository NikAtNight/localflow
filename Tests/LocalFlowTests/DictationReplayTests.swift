import XCTest
@testable import LocalFlow

@MainActor
final class DictationReplayTests: XCTestCase {
    func testParsesValidOverridesWithoutWritingSettings() throws {
        let defaults = UserDefaults.standard
        let keys = [Settings.Key.cleanupEnabled, Settings.Key.whisperModel, Settings.Key.ollamaModel]
        let before = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, String(describing: defaults.object(forKey: $0)))
        })

        let options = try DictationReplay.parse(arguments: [
            "/tmp/sample.wav", "--runs", "2", "--no-cleanup",
            "--whisper-model", "test-whisper", "--ollama-model", "test-ollama"
        ])

        XCTAssertEqual(options.path, "/tmp/sample.wav")
        XCTAssertEqual(options.runs, 2)
        XCTAssertFalse(options.cleanupEnabled)
        XCTAssertEqual(options.whisperModel, "test-whisper")
        XCTAssertEqual(options.ollamaModel, "test-ollama")
        for key in keys {
            XCTAssertEqual(String(describing: defaults.object(forKey: key)), before[key])
        }
    }

    func testRejectsMissingOrInvalidArguments() {
        XCTAssertThrowsError(try DictationReplay.parse(arguments: []))
        XCTAssertThrowsError(try DictationReplay.parse(arguments: ["file.wav"]))
        XCTAssertThrowsError(try DictationReplay.parse(arguments: ["file.wav", "--runs", "0"]))
        XCTAssertThrowsError(try DictationReplay.parse(arguments: ["file.wav", "--runs", "101"]))
        XCTAssertThrowsError(try DictationReplay.parse(arguments: ["file.wav", "--runs", "1", "--unknown"]))
        XCTAssertThrowsError(try DictationReplay.parse(arguments: ["--runs", "1"]))
        XCTAssertThrowsError(try DictationReplay.parse(arguments: ["file.wav", "--runs", "1", "--cleanup", "--no-cleanup"]))
        XCTAssertThrowsError(try DictationReplay.parse(arguments: ["file.wav", "--runs", "1", "--runs", "2"]))
        XCTAssertThrowsError(try DictationReplay.parse(arguments: ["file.wav", "--runs", "1", "--whisper-model"]))
    }

    func testCleanupCanBeEnabledWithoutChangingSavedSettings() throws {
        let before = Settings.cleanupEnabled
        let options = try DictationReplay.parse(arguments: ["file.wav", "--runs", "1", "--cleanup"])
        XCTAssertTrue(options.cleanupEnabled)
        XCTAssertEqual(Settings.cleanupEnabled, before)
    }

    func testDetailedTimingsCanBeDisabledForOverheadComparisons() throws {
        let enabled = try DictationReplay.parse(arguments: ["file.wav", "--runs", "1"])
        let disabled = try DictationReplay.parse(arguments: ["file.wav", "--runs", "1", "--no-timing"])
        XCTAssertTrue(enabled.timingsEnabled)
        XCTAssertFalse(disabled.timingsEnabled)
        XCTAssertEqual(enabled.cleanupEnabled, disabled.cleanupEnabled)
        XCTAssertEqual(enabled.whisperModel, disabled.whisperModel)
    }
}
