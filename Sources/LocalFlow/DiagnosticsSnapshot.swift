import Foundation

/// A bounded, content-free view of the existing timing log, not a second log store.
struct DiagnosticsSnapshot: Sendable {
    struct Trace: Identifiable, Sendable {
        let id: UUID
        let events: [DictationTrace.Event]
        let environment: [String: String]

        var startedAt: Date { events[0].startedAt }
        var source: DictationTrace.Source { events[0].source }

        var dispatchMs: Double? {
            events.first {
                ($0.name == .pasteDispatched || $0.name == .typingDispatched)
                    && $0.status == .success && $0.sinceReleaseMs != nil
            }?.sinceReleaseMs
        }

        var title: String {
            switch source {
            case .dictation: return "Dictation"
            case .replay: return "Audio replay"
            case .modelLoad: return "Model preparation"
            }
        }

        var summary: String {
            if let dispatchMs { return "Release to dispatch: \(Self.milliseconds(dispatchMs))" }
            if source == .modelLoad, let finished = events.last(where: { $0.name == .modelLoadFinished }) {
                return "\(finished.status?.rawValue ?? "Finished") · \(Self.milliseconds(finished.sinceStartMs))"
            }
            return "No successful dispatch recorded"
        }

        /// Render only the typed metadata. Never include unstructured log lines.
        var report: String {
            var lines = ["Trace: \(id.uuidString)", summary]
            if let live = events.first(where: { $0.name == .microphoneLive }) {
                lines.append("Hotkey to microphone audio: \(Self.milliseconds(live.sinceStartMs))")
            }
            if let handoff = events.first(where: { $0.name == .audioHandoff })?.sinceReleaseMs {
                lines.append("Release to audio handoff: \(Self.milliseconds(handoff))")
            }
            lines.append("\nRecorded environment")
            if environment.isEmpty { lines.append("Unavailable in the retained log") }
            lines += environment.keys.sorted().map { "\($0): \(environment[$0]!)" }
            lines.append("\nEvents · times in milliseconds")
            for event in events {
                var line = "\(event.ordinal). \(event.name.rawValue) · start \(Self.milliseconds(event.sinceStartMs))"
                if let released = event.sinceReleaseMs { line += " · release \(Self.milliseconds(released))" }
                if let status = event.status { line += " · \(status.rawValue)" }
                lines.append(line)
                if let model = event.model { lines.append("  Model: \(model)") }
                if let microphone = event.microphone { lines.append("  Microphone: \(microphone)") }
                if let segment = event.segment {
                    switch segment {
                    case .incrementalChunk(let index): lines.append("  Incremental chunk \(index)")
                    case .releaseTail: lines.append("  Release tail")
                    case .fullUtterance: lines.append("  Full utterance")
                    }
                }
                for key in event.fields.keys.sorted() {
                    lines.append("  \(key): \(event.fields[key]!.formatted(.number.precision(.fractionLength(0...2))))")
                }
            }
            return lines.joined(separator: "\n")
        }

        private static func milliseconds(_ value: Double) -> String {
            "\(value.formatted(.number.precision(.fractionLength(0...2)))) ms"
        }
    }

    var traces: [Trace] = []
    var environment: [String: String] = [:]
    var ignoredTimingLines = 0
    var wasTruncated = false

    static func parse(_ text: String) -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let environmentKeys: Set<String> = [
            "schemaVersion", "pid", "osVersion", "processorCount", "memoryBytes",
            "hardwareModel", "chip", "appVersion", "buildConfiguration", "buildCommit", "buildDirty"
        ]
        var result = Self()
        var grouped: [UUID: [DictationTrace.Event]] = [:]
        var environments: [UUID: [String: String]] = [:]
        for line in text.split(separator: "\n") {
            // Only the message immediately after the date/time stamp counts.
            // Quoted timing JSON inside an ordinary log message is not an event.
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let message = parts[2]
            if message.hasPrefix("timing_environment ") {
                let data = Data(message.dropFirst("timing_environment ".count).utf8)
                result.environment = ((try? decoder.decode([String: String].self, from: data)) ?? [:])
                    .filter { environmentKeys.contains($0.key) }
            } else if message.hasPrefix("timing ") {
                let data = Data(message.dropFirst("timing ".count).utf8)
                guard let event = try? decoder.decode(DictationTrace.Event.self, from: data),
                      event.schemaVersion == 1, event.ordinal >= 0 else {
                    result.ignoredTimingLines += 1
                    continue
                }
                if grouped[event.traceID] == nil { environments[event.traceID] = result.environment }
                let safeEvent = DictationTrace.Event(
                    schemaVersion: event.schemaVersion, traceID: event.traceID, source: event.source,
                    ordinal: event.ordinal, name: event.name, uptimeNs: event.uptimeNs,
                    sinceStartMs: event.sinceStartMs, sinceReleaseMs: event.sinceReleaseMs,
                    startedAt: event.startedAt, status: event.status,
                    fields: event.fields.filter { DictationTrace.Field(rawValue: $0.key) != nil },
                    model: event.model, segment: event.segment, microphone: event.microphone
                )
                grouped[event.traceID, default: []].append(safeEvent)
            }
        }
        result.traces = grouped.map { id, events in
            Trace(id: id, events: events.sorted { $0.ordinal < $1.ordinal }, environment: environments[id] ?? [:])
        }.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        return result
    }

    /// Use a single file handle so rotation cannot mix two files. Bound both I/O
    /// and parsing even if a long-running session exceeds the launch trim limit.
    static func read(from url: URL, maximumBytes: Int = 8_000_000) throws -> Self {
        precondition(maximumBytes > 0)
        let handle: FileHandle
        do {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw CocoaError(.fileReadUnknown)
            }
            handle = try FileHandle(forReadingFrom: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return Self()
        }
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        let offset = end > UInt64(maximumBytes) ? end - UInt64(maximumBytes) : 0
        try handle.seek(toOffset: offset)
        var data = try handle.read(upToCount: maximumBytes) ?? Data()
        if offset > 0 {
            if let newline = data.firstIndex(of: 10) { data = data.suffix(from: data.index(after: newline)) }
            else { data = Data() }
        }
        var result = parse(String(decoding: data, as: UTF8.self))
        result.wasTruncated = offset > 0
        return result
    }
}
