import XCTest
@testable import LocalFlow

final class DiagnosticsReaderTests: XCTestCase {
    func testMissingFileIsAnEmptySnapshot() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(try DiagnosticsSnapshot.read(from: url).traces.isEmpty)
    }

    func testBoundedReadDiscardsPartialLeadingRecord() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let content = String(repeating: "x", count: 100) + "\n2026-09-08 22:00:00.000 timing_environment {\"appVersion\":\"test\"}\n"
        try Data(content.utf8).write(to: url)
        let snapshot = try DiagnosticsSnapshot.read(from: url, maximumBytes: 90)
        XCTAssertTrue(snapshot.wasTruncated)
        XCTAssertEqual(snapshot.environment["appVersion"], "test")
        XCTAssertEqual(snapshot.ignoredTimingLines, 0)
    }

    func testFileReadErrorsAreNotShownAsEmptyLogs() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try DiagnosticsSnapshot.read(from: url))
    }

    func testDiagnosticsOnlyAvailableInLocalBuilds() {
        XCTAssertTrue(SettingsPane.available(for: AppIdentity(bundleIdentifier: AppIdentity.localID)).contains(.diagnostics))
        for id in [AppIdentity.productionID, nil] {
            let panes = SettingsPane.available(for: AppIdentity(bundleIdentifier: id))
            XCTAssertFalse(panes.contains(.diagnostics))
            XCTAssertEqual(panes.count, 6)
        }
    }

    func testVersionAndLocalProvenanceComeFromBundleMetadata() {
        let info = AppBuildInfo(info: [
            "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45",
            "LFBuildCommit": "1234567890abcdef", "LFBuildDirty": "true",
            "LFBuildDate": "2026-09-09T02:00:00Z"
        ])
        XCTAssertEqual(info.versionLabel, "Version 1.2.3 (45)")
        XCTAssertEqual(info.revisionLabel, "12345678 · modified")
        XCTAssertEqual(info.builtAt, "2026-09-09T02:00:00Z")
        XCTAssertEqual(AppBuildInfo(info: ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "1.2.3"]).versionLabel, "Version 1.2.3")
        XCTAssertEqual(AppBuildInfo(info: [:]).versionLabel, "Version Unknown")
    }
}
