import XCTest
@testable import LocalFlow

@MainActor
final class UpdateControllerTests: XCTestCase {
    func testMatchingAutomaticPreferencesAreNotWrittenAgain() {
        let changes = UpdateController.automaticPreferenceChanges(
            currentChecks: true,
            currentDownloads: true,
            desired: true
        )

        XCTAssertNil(changes.checks)
        XCTAssertNil(changes.downloads)
    }

    func testDifferentAutomaticPreferencesAreWritten() {
        let changes = UpdateController.automaticPreferenceChanges(
            currentChecks: true,
            currentDownloads: true,
            desired: false
        )

        XCTAssertEqual(changes.checks, false)
        XCTAssertEqual(changes.downloads, false)
    }

    func testBusyManualCheckIsReported() {
        XCTAssertEqual(
            UpdateController.manualCheckDisposition(
                canCheckForUpdates: false,
                sessionInProgress: true
            ),
            .busy
        )
    }

    func testVisibleUpdateSessionCanBeFocused() {
        XCTAssertEqual(
            UpdateController.manualCheckDisposition(
                canCheckForUpdates: true,
                sessionInProgress: true
            ),
            .perform
        )
    }

    func testUnavailableUpdaterIsNotReportedAsBusy() {
        XCTAssertEqual(
            UpdateController.manualCheckDisposition(
                canCheckForUpdates: false,
                sessionInProgress: false
            ),
            .unavailable
        )
    }
}
