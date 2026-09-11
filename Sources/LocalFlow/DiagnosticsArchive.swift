import Foundation

/// Permanent local timing history. Call mutations on DiagLog's serial queue.
/// One file per trace lets the pane load older history without reading it all.
struct DiagnosticsArchive {
    static let local = DiagnosticsArchive(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LocalFlow Local/Diagnostics", isDirectory: true))
    let directory: URL

    func recover(log: URL, recordings: URL) throws {
        try createDirectory()
        let marker = directory.appendingPathComponent("migration-v1")
        if FileManager.default.fileExists(atPath: log.path) {
            try merge(DiagnosticsSnapshot.parse(String(contentsOf: log, encoding: .utf8)))
        }
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        if FileManager.default.fileExists(atPath: recordings.path) {
            for folder in try FileManager.default.contentsOfDirectory(at: recordings, includingPropertiesForKeys: nil) {
                let timing = folder.appendingPathComponent("timing.jsonl")
                guard FileManager.default.fileExists(atPath: timing.path) else { continue }
                let environmentURL = folder.appendingPathComponent("environment.txt")
                let environment = FileManager.default.fileExists(atPath: environmentURL.path)
                    ? try String(contentsOf: environmentURL, encoding: .utf8) : ""
                let events = try String(contentsOf: timing, encoding: .utf8)
                let text = "0 0 " + environment + "\n" + events.split(separator: "\n")
                    .map { "0 0 timing " + $0 }.joined(separator: "\n")
                try merge(DiagnosticsSnapshot.parse(text))
            }
        }
        try Data().write(to: marker, options: .atomic)
    }

    func record(_ event: DictationTrace.Event, environment: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(event), as: UTF8.self)
        let snapshot = DiagnosticsSnapshot.parse("0 0 " + environment + "\n0 0 timing " + json)
        guard let trace = snapshot.traces.first else { return }
        let url = traceURL(trace)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            let safeJSON = String(decoding: try encoder.encode(trace.events[0]), as: UTF8.self)
            try handle.write(contentsOf: Data(("\n0 0 timing " + safeJSON + "\n").utf8))
        } else {
            try merge(snapshot)
        }
    }

    /// Migration and live writes share deduplication and the content whitelist.
    func merge(_ snapshot: DiagnosticsSnapshot) throws {
        try createDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        for trace in snapshot.traces {
            let url = traceURL(trace)
            let existing = try DiagnosticsSnapshot.read(from: url, maximumBytes: Int.max).traces.first
            var events: [Int: DictationTrace.Event] = [:]
            for event in trace.events { events[event.ordinal] = event }
            for event in existing?.events ?? [] { events[event.ordinal] = event }
            let environment = existing.flatMap { $0.environment.isEmpty ? nil : $0.environment } ?? trace.environment
            var text = "0 0 timing_environment " + String(decoding: try encoder.encode(environment), as: UTF8.self) + "\n"
            for event in events.values.sorted(by: { $0.ordinal < $1.ordinal }) {
                text += "0 0 timing " + String(decoding: try encoder.encode(event), as: UTF8.self) + "\n"
            }
            try Data(text.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func read(maximumTraces: Int = 200) throws -> DiagnosticsSnapshot {
        guard FileManager.default.fileExists(atPath: directory.path) else { return DiagnosticsSnapshot() }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            .filter {
                guard $0.pathExtension == "log" else { return false }
                let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values.isRegularFile == true && values.isSymbolicLink != true
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var result = DiagnosticsSnapshot()
        result.hasOlderTraces = files.count > maximumTraces
        for file in files.prefix(maximumTraces) {
            let snapshot = try DiagnosticsSnapshot.read(from: file, maximumBytes: Int.max)
            result.traces += snapshot.traces
            result.ignoredTimingLines += snapshot.ignoredTimingLines
        }
        result.traces.sort { $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt }
        return result
    }

    private func traceURL(_ trace: DiagnosticsSnapshot.Trace) -> URL {
        let name = String(format: "%020.0f", trace.startedAt.timeIntervalSince1970) + "-" + trace.id.uuidString + ".log"
        return directory.appendingPathComponent(name)
    }

    private func createDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}
