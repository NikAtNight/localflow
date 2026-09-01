import XCTest
@testable import LocalFlow

final class UserFacingIssueTests: XCTestCase {
    func testMenuSummaryCollapsesWhitespace() {
        let issue = UserFacingIssue(
            summary: "  Couldn't\nstart   the microphone  ",
            details: "Full system error"
        )

        XCTAssertEqual(issue.menuSummary, "Couldn't start the microphone")
    }

    func testMenuSummaryHasAHardCharacterLimit() {
        let issue = UserFacingIssue(
            summary: String(repeating: "🙂", count: 80),
            details: "Full system error"
        )

        XCTAssertEqual(UserFacingIssue.menuCharacterLimit, 32)
        XCTAssertEqual(issue.menuSummary.count, UserFacingIssue.menuCharacterLimit)
        XCTAssertTrue(issue.menuSummary.hasSuffix("…"))
    }

    func testBuiltInMenuSummariesFitTheCharacterLimit() {
        let summaries = [
            "Microphone stopped",
            "Dictation shortcut unavailable",
            "Couldn't switch Whisper model",
            "Couldn't load Whisper model",
            "Microphone access needed",
            "Couldn't start the microphone",
            "Couldn't apply the voice edit",
            "Couldn't transcribe the command",
            "Couldn't transcribe audio",
            "Paste may not have landed",
            "Didn't hear any speech",
        ]

        for summary in summaries {
            XCTAssertLessThanOrEqual(
                summary.count,
                UserFacingIssue.menuCharacterLimit,
                "Built-in menu summary is too long: \(summary)"
            )
        }
    }

    func testMenuSummaryTruncatesAtAWordBoundary() {
        let issue = UserFacingIssue(
            summary: "Unexpected transcription service failure message",
            details: "Full system error"
        )

        XCTAssertEqual(issue.menuSummary, "Unexpected transcription…")
    }

    func testLoadingStatusDoesNotExposeTheRegistryModelIdentifier() {
        let status = MenuStatusText.loadingModel(
            identifier: "openai_whisper-large-v3-v20240930_turbo"
        )

        XCTAssertEqual(status.title, "Loading Whisper model…")
        XCTAssertEqual(
            status.details,
            "Loading openai_whisper-large-v3-v20240930_turbo"
        )
    }

    func testEmptySummaryGetsAReadableFallback() {
        let issue = UserFacingIssue(summary: " \n ", details: "Full system error")

        XCTAssertEqual(issue.menuSummary, "Something went wrong")
    }
}
