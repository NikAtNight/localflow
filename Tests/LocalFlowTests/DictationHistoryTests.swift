import XCTest
@testable import LocalFlow

/// Daily-log naming and entry rendering. The append path itself writes to
/// the real Application Support folder, so it isn't exercised here; these
/// cover the pure pieces the file layout depends on.
final class DictationHistoryTests: XCTestCase {
    private func date(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: iso)!
    }

    func testFileNameIsOnePerCalendarDay() {
        XCTAssertEqual(DictationHistory.fileName(for: date("2026-08-08 09:14:22")), "2026-08-08.md")
        XCTAssertEqual(DictationHistory.fileName(for: date("2026-08-08 23:59:59")), "2026-08-08.md")
        XCTAssertEqual(DictationHistory.fileName(for: date("2026-12-31 00:00:01")), "2026-12-31.md")
    }

    func testEntryIsATimestampedMarkdownSection() {
        XCTAssertEqual(
            DictationHistory.entry(for: "Ship it.", at: date("2026-08-08 09:14:22")),
            "## 09:14:22\n\nShip it.\n\n")
    }

    func testEntryPreservesMultiLineFormattingVerbatim() {
        let dictation = "1. Review the PR.\n2. Merge it."
        XCTAssertEqual(
            DictationHistory.entry(for: dictation, at: date("2026-08-08 14:02:00")),
            "## 14:02:00\n\n1. Review the PR.\n2. Merge it.\n\n")
    }

    func testHistoryFolderStaysOutOfICloudSyncedDocuments() {
        // ~/Documents is iCloud-synced on most Macs; transcripts must not
        // leave the machine.
        let path = DictationHistory.folder.path
        XCTAssertTrue(path.contains("Application Support/LocalFlow/History"), path)
        XCTAssertFalse(path.contains("/Documents/"), path)
    }
}
