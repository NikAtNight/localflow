import Foundation

/// Timing history with channel-specific retention. Call mutations on DiagLog's serial queue.
/// One file per trace lets the pane load older history without reading it all.
struct DiagnosticsArchive {
    static let current = forIdentity(.current)
    static func forIdentity(_ identity: AppIdentity) -> Self {
        Self(directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(identity.name)/Diagnostics", isDirectory: true),
             retentionDays: identity.isLocal ? nil : 30)
    }
    let directory: URL
    var retentionDays: Int? = nil

    func recover(log: URL, recordings: URL, now: Date = Date()) throws {
        try prune(now: now)
        try createDirectory()
        let marker = directory.appendingPathComponent("migration-v1")
        if FileManager.default.fileExists(atPath: log.path) {
            try merge(DiagnosticsSnapshot.parse(String(contentsOf: log, encoding: .utf8)), now: now)
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
                try merge(DiagnosticsSnapshot.parse(text), now: now)
            }
        }
        try Data().write(to: marker, options: .atomic)
    }

    func record(_ event: DictationTrace.Event, environment: String, now: Date = Date()) throws {
        guard isRetained(event.startedAt, now: now) else { return }
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
            try merge(snapshot, now: now)
        }
    }

    /// Migration and live writes share deduplication and the content whitelist.
    func merge(_ snapshot: DiagnosticsSnapshot, now: Date = Date()) throws {
        try createDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        for trace in snapshot.traces where isRetained(trace.startedAt, now: now) {
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

    func read(maximumTraces: Int = 200, now: Date = Date()) throws -> DiagnosticsSnapshot {
        try prune(now: now)
        let files = try traceFiles()
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

    private func traceFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            .filter {
                guard $0.pathExtension == "log" else { return false }
                let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values.isRegularFile == true && values.isSymbolicLink != true
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func prune(now: Date = Date()) throws {
        guard retentionDays != nil else { return }
        for file in try traceFiles() {
            let name = file.deletingPathExtension().lastPathComponent
            // Only remove files owned by this archive, never arbitrary neighbors.
            guard name.count == 57, name[name.index(name.startIndex, offsetBy: 20)] == "-",
                  UUID(uuidString: String(name.suffix(36))) != nil,
                  let seconds = TimeInterval(name.prefix(20)), seconds.isFinite else { continue }
            if !isRetained(Date(timeIntervalSince1970: seconds), now: now) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Export parsed reports, never raw archive files or recording sidecars.
    func export(to destination: URL, now: Date = Date()) throws {
        try prune(now: now)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".diagnostics-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: Data("LocalFlow diagnostics\nTiming and build/device metadata only. No transcripts or audio.\n".utf8))
            for file in try traceFiles() {
                let snapshot = try DiagnosticsSnapshot.read(from: file, maximumBytes: Int.max)
                for trace in snapshot.traces where isRetained(trace.startedAt, now: now) {
                    let text = "\n\n\(trace.title) · \(trace.startedAt.ISO8601Format())\n" + trace.report
                    try handle.write(contentsOf: Data(text.utf8))
                }
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    private func isRetained(_ date: Date, now: Date) -> Bool {
        guard let retentionDays else { return true }
        return date >= now.addingTimeInterval(-Double(retentionDays) * 86_400)
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
