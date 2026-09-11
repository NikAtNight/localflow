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

    func testStorageFailureIsReported() throws {
        let file = root.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        let archive = DiagnosticsArchive(directory: file)
        XCTAssertThrowsError(try archive.record(event(), environment: "timing_environment {}"))
        XCTAssertThrowsError(try archive.read())
    }
}
