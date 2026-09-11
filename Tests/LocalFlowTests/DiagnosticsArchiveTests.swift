import XCTest
@testable import LocalFlow

final class DiagnosticsArchiveTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func event(_ id: UUID = UUID(), ordinal: Int = 0, startedAt: TimeInterval = 100) -> DictationTrace.Event {
        DictationTrace.Event(schemaVersion: 1, traceID: id, source: .dictation, ordinal: ordinal,
                             name: .sessionStarted, uptimeNs: 0, sinceStartMs: 0, sinceReleaseMs: nil,
                             startedAt: Date(timeIntervalSince1970: startedAt), status: nil,
                             fields: [:], model: nil, segment: nil, microphone: nil)
    }

    func testRestartAndDeletedDebugLogPreserveHistoryAndEnvironment() throws {
        let archive = DiagnosticsArchive(directory: root.appendingPathComponent("history"))
        let id = UUID()
        try archive.record(event(id), environment: "timing_environment {\"buildCommit\":\"old\"}")
        let restarted = DiagnosticsArchive(directory: archive.directory)
        try restarted.recover(log: root.appendingPathComponent("missing.log"), recordings: root.appendingPathComponent("missing"))
        try restarted.record(event(id, ordinal: 1), environment: "timing_environment {\"buildCommit\":\"new\"}")
        let trace = try XCTUnwrap(restarted.read().traces.first)
        XCTAssertEqual(trace.events.map(\.ordinal), [0, 1])
        XCTAssertEqual(trace.environment["buildCommit"], "old")
    }

    func testRecoveryMergesSidecarsDeduplicatesAndExcludesContent() throws {
        let archive = DiagnosticsArchive(directory: root.appendingPathComponent("history"))
        let recordings = root.appendingPathComponent("recordings")
        let folder = recordings.appendingPathComponent("one")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let first = event()
        let json = String(decoding: try encoder.encode(first), as: UTF8.self)
        try Data((json + "\n").utf8).write(to: folder.appendingPathComponent("timing.jsonl"))
        try Data("timing_environment {\"buildCommit\":\"old\",\"transcript\":\"secret\"}\n".utf8)
            .write(to: folder.appendingPathComponent("environment.txt"))
        try Data("secret".utf8).write(to: folder.appendingPathComponent("events.jsonl"))
        let log = root.appendingPathComponent("debug.log")
        try Data(("0 0 ordinary secret\n0 0 timing " + json + "\n").utf8).write(to: log)
        try archive.recover(log: log, recordings: recordings)
        try archive.recover(log: log, recordings: recordings)
        let trace = try XCTUnwrap(archive.read().traces.first)
        XCTAssertEqual(trace.events.count, 1)
        XCTAssertEqual(trace.environment, ["buildCommit": "old"])
        for file in try FileManager.default.contentsOfDirectory(at: archive.directory, includingPropertiesForKeys: nil) {
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("secret"))
        }
        // Retry log recovery even after migration, so a failed live write can be recovered next launch.
        let second = String(decoding: try encoder.encode(event()), as: UTF8.self)
        try Data(("0 0 timing " + second).utf8).write(to: log)
        try archive.recover(log: log, recordings: recordings)
        XCTAssertEqual(try archive.read().traces.count, 2)
    }

    func testOlderHistoryRemainsAvailableAndFilesArePrivate() throws {
        let archive = DiagnosticsArchive(directory: root.appendingPathComponent("history"))
        for time in [100.0, 200.0, 300.0] {
            try archive.record(event(startedAt: time), environment: "timing_environment {}")
        }
        let page = try archive.read(maximumTraces: 2)
        XCTAssertEqual(page.traces.map { $0.startedAt.timeIntervalSince1970 }, [300, 200])
        XCTAssertTrue(page.hasOlderTraces)
        XCTAssertEqual(try archive.read(maximumTraces: 3).traces.count, 3)
        XCTAssertFalse(try archive.read(maximumTraces: 3).hasOlderTraces)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: archive.directory, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
    }

    func testOversizedLegacyLogCanBeDeletedAfterRecovery() throws {
        let archive = DiagnosticsArchive(directory: root.appendingPathComponent("history"))
        let log = root.appendingPathComponent("debug.log")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(event()), as: UTF8.self)
        try Data((String(repeating: "x", count: 5_000_001) + "\n0 0 timing " + json).utf8).write(to: log)
        try archive.recover(log: log, recordings: root.appendingPathComponent("missing"))
        try FileManager.default.removeItem(at: log)
        let restarted = DiagnosticsArchive(directory: archive.directory)
        try restarted.recover(log: log, recordings: root.appendingPathComponent("missing"))
        XCTAssertEqual(try restarted.read().traces.count, 1)
    }

    func testProductionRetentionBoundaryAndRecoveryDoNotResurrectExpiredTraces() throws {
        let now = Date(timeIntervalSince1970: 4_000_000)
        let cutoff = now.timeIntervalSince1970 - 30 * 86_400
        let directory = root.appendingPathComponent("history")
        let unlimited = DiagnosticsArchive(directory: directory)
        for time in [cutoff - 1, cutoff, cutoff + 1] {
            try unlimited.record(event(startedAt: time), environment: "timing_environment {}")
        }
        let archive = DiagnosticsArchive(directory: directory, retentionDays: 30)
        let unrelated = directory.appendingPathComponent("notes.log")
        try Data("keep me".utf8).write(to: unrelated)
        let old = event(startedAt: cutoff - 1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let log = root.appendingPathComponent("debug.log")
        try Data(("0 0 timing " + String(decoding: encoder.encode(old), as: UTF8.self)).utf8).write(to: log)
        try archive.recover(log: log, recordings: root.appendingPathComponent("missing"), now: now)
        try archive.record(old, environment: "timing_environment {}", now: now)
        XCTAssertEqual(try archive.read(now: now).traces.map { $0.startedAt.timeIntervalSince1970 }, [cutoff + 1, cutoff])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        try archive.prune(now: now.addingTimeInterval(2))
        XCTAssertTrue(try archive.read(now: now.addingTimeInterval(2)).traces.isEmpty)
    }

    func testChannelPoliciesKeepLocalHistoryUnlimitedAndSeparate() {
        let production = DiagnosticsArchive.forIdentity(AppIdentity(bundleIdentifier: AppIdentity.productionID))
        let local = DiagnosticsArchive.forIdentity(AppIdentity(bundleIdentifier: AppIdentity.localID))
        XCTAssertEqual(production.retentionDays, 30)
        XCTAssertNil(local.retentionDays)
        XCTAssertNotEqual(production.directory, local.directory)
    }

    func testExportIncludesAllPagesAndOnlyTypedRetainedMetadata() throws {
        let archive = DiagnosticsArchive(directory: root.appendingPathComponent("history"))
        for time in 1...201 {
            try archive.record(event(startedAt: Double(time)), environment: "timing_environment {\"buildCommit\":\"original-build\",\"transcript\":\"private-fixture\"}")
        }
        let files = try FileManager.default.contentsOfDirectory(at: archive.directory, includingPropertiesForKeys: nil)
        let handle = try FileHandle(forWritingTo: XCTUnwrap(files.first))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n0 0 raw private-fixture\n".utf8))
        try handle.close()
        let destination = root.appendingPathComponent("export.txt")
        try Data("old export".utf8).write(to: destination)
        try archive.export(to: destination)
        let text = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "Trace: ").count - 1, 201)
        XCTAssertTrue(text.contains("original-build"))
        XCTAssertFalse(text.contains("private-fixture"))
        XCTAssertFalse(text.contains("old export"))
        let production = DiagnosticsArchive(directory: archive.directory, retentionDays: 30)
        try production.export(to: destination, now: Date(timeIntervalSince1970: 4_000_000))
        XCTAssertFalse(try String(contentsOf: destination, encoding: .utf8).contains("Trace: "))
        XCTAssertThrowsError(try archive.export(to: root.appendingPathComponent("missing/export.txt")))
    }

    func testStorageFailureIsReported() throws {
        let file = root.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        let archive = DiagnosticsArchive(directory: file)
        XCTAssertThrowsError(try archive.record(event(), environment: "timing_environment {}"))
        XCTAssertThrowsError(try archive.read())
    }
}
