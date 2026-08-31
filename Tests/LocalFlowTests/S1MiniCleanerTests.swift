import XCTest
@testable import LocalFlow

final class S1MiniCleanerTests: XCTestCase {
    func testCleanupModelIsS1Mini() {
        XCTAssertEqual(Settings.cleanupModel, "s1-mini")
    }

    func testCodeDestinationsBypassS1Mini() {
        XCTAssertFalse(S1MiniCleanup.shouldClean(profile: .code))
        XCTAssertTrue(S1MiniCleanup.shouldClean(profile: .general))
    }

    func testUsesExactRequiredSystemPrompt() {
        XCTAssertEqual(
            S1MiniCleanup.systemPrompt,
            "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."
        )
    }

    func testEmailUsesSemiFormalListCapableEmailControls() {
        XCTAssertEqual(
            S1MiniCleanup.controlLine(for: .email),
            "[Styling: semi-formal] [Structure: lists] [Context: email]"
        )
    }

    func testWorkChatUsesSemiCasualGeneralControls() {
        XCTAssertEqual(
            S1MiniCleanup.controlLine(for: .workChat),
            "[Styling: semi-casual] [Structure: lists] [Context: general]"
        )
    }

    func testPersonalChatUsesSemiCasualGeneralControls() {
        XCTAssertEqual(
            S1MiniCleanup.controlLine(for: .personalChat),
            "[Styling: semi-casual] [Structure: lists] [Context: general]"
        )
    }

    func testGeneralUsesSemiFormalListCapableControls() {
        XCTAssertEqual(
            S1MiniCleanup.controlLine(for: .general),
            "[Styling: semi-formal] [Structure: lists] [Context: general]"
        )
    }

    func testPromptPlacesControlLineBeforeTranscript() {
        XCTAssertEqual(
            S1MiniCleanup.prompt(for: "so um send it friday", profile: .general),
            "[Styling: semi-formal] [Structure: lists] [Context: general]\nso um send it friday"
        )
    }

    func testEmptyOutputIsValidForFillerOnlyInput() {
        XCTAssertEqual(S1MiniCleanup.validatedOutput("  \n", raw: "um uh"), "")
    }

    func testBalloonedOutputFallsBackToRawTranscript() {
        let raw = "Send it Friday."
        XCTAssertEqual(
            S1MiniCleanup.validatedOutput(String(repeating: "x", count: 200), raw: raw),
            raw
        )
    }
}
