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

        XCTAssertEqual(status.title, "Preparing speech recognition… 0s")
        XCTAssertEqual(
            status.details,
            "Preparing speech recognition for this Mac. First-time preparation can take a few minutes; later launches usually reuse it.\nModel: openai_whisper-large-v3-v20240930_turbo"
        )
    }

    func testPreparationElapsedTimeIsReadableAndCannotBecomeNegative() {
        XCTAssertEqual(MenuStatusText.loadingModel(identifier: "model", elapsedSeconds: 98.9).title,
                       "Preparing speech recognition… 98s")
        XCTAssertEqual(MenuStatusText.loadingModel(identifier: "model", elapsedSeconds: -1).title,
                       "Preparing speech recognition… 0s")
    }

    func testEmptySummaryGetsAReadableFallback() {
        let issue = UserFacingIssue(summary: " \n ", details: "Full system error")

        XCTAssertEqual(issue.menuSummary, "Something went wrong")
    }
}
