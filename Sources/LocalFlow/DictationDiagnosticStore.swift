import AVFoundation
import Foundation

/// Optional content archives, separate from the content-free timing log.
/// All disk work runs on one queue. Deletion never recreates an in-flight archive.
final class DictationDiagnosticStore: @unchecked Sendable {
    static let writeFailedNotification = Notification.Name("LocalFlowDiagnosticRecordingWriteFailed")
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(AppIdentity.current.name)/DiagnosticRecordings", isDirectory: true)
    static let shared = DictationDiagnosticStore(folder: folder)

    struct Metadata: Codable {
        let schemaVersion: Int
        let traceID: UUID
        let startedAt: Date
        let version: String
        let revision: String
        let builtAt: String
        let whisperModel: String
        let microphone: String
        let vocabulary: String
        let cleanupEnabled: Bool
        let cleanupModel: String
        let styleProfile: String
        let corrections: [[String]]
        let snippets: [[String]]

        init(traceID: UUID, context: DictationSessionContext, whisperModel: String,
             microphone: String, vocabulary: String) {
            schemaVersion = 1
            self.traceID = traceID
            startedAt = Date()
            version = AppBuildInfo.current.versionLabel
            revision = AppBuildInfo.current.revisionLabel
            builtAt = AppBuildInfo.current.builtAt
            self.whisperModel = whisperModel
            self.microphone = microphone
            self.vocabulary = vocabulary
            cleanupEnabled = context.cleanupEnabled
            cleanupModel = context.ollamaModel
            styleProfile = context.styleProfile.rawValue
            corrections = context.corrections.map { [$0.wrong, $0.right] }
            snippets = context.snippets.map { [$0.trigger, $0.expansion] }
        }
    }

    struct Event: Codable {
        struct Segment: Codable {
            let text: String
            let start: Float
            let end: Float
        }

        var at = Date()
        let stage: String
        var text: String? = nil
        var status: String? = nil
        var model: String? = nil
        var segment: DictationTranscriptionSegment? = nil
        var audioFile: String? = nil
        var sampleCount: Int? = nil
        var segments: [Segment]? = nil
    }

    final class Recording: @unchecked Sendable {
        @TaskLocal static var current: Recording?
        let id: UUID
        private let store: DictationDiagnosticStore

        fileprivate init(id: UUID, store: DictationDiagnosticStore) {
            self.id = id
            self.store = store
        }

        func record(_ event: Event) { store.append(event, id: id) }

        func recordTiming(_ event: DictationTrace.Event) {
            store.append(event, id: id, filename: "timing.jsonl")
        }

        func saveAudio(_ samples: [Float], named name: String = "original.wav") {
            store.saveAudio(samples, named: name, id: id)
        }
    }

    private let root: URL
    private let maxAge: TimeInterval
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "app.talix.localflow.diagnostic-recordings", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var writeFailed = false

    var hasWriteFailure: Bool { queue.sync { writeFailed } }

    init(folder: URL, maxAge: TimeInterval = 7 * 24 * 60 * 60, maxBytes: Int = 1_000_000_000) {
        root = folder
        self.maxAge = maxAge
        self.maxBytes = maxBytes
    }

    func begin(_ metadata: Metadata) -> Recording {
        queue.async {
            self.performWrite {
                let fm = FileManager.default
                try fm.createDirectory(at: self.root, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
                let directory = self.directory(metadata.traceID)
                try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try self.write(encoder.encode(metadata), to: directory.appendingPathComponent("metadata.json"))
                try self.write(Data((DiagLog.environmentLine() + "\n").utf8),
                               to: directory.appendingPathComponent("environment.txt"))
                try self.pruneNow()
            }
        }
        return Recording(id: metadata.traceID, store: self)
    }

    func startMaintenance() {
        queue.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 3600)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.performWrite { try self.pruneNow() }
            }
            self.timer = timer
            timer.resume()
        }
    }

    func deleteAll(completion: @escaping (Bool) -> Void) {
        queue.async {
            let success: Bool
            do {
                for directory in try self.managedDirectories() {
                    try FileManager.default.removeItem(at: directory)
                }
                success = true
            } catch {
                success = false
            }
            DispatchQueue.main.async { completion(success) }
        }
    }

    /// Used on orderly shutdown and by tests, never on the capture thread.
    func flush() { queue.sync {} }

    func prune() { queue.async { self.performWrite { try self.pruneNow() } } }

    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func append<T: Encodable>(_ event: T, id: UUID, filename: String = "events.jsonl") {
        queue.async {
            guard FileManager.default.fileExists(atPath: self.directory(id).path) else { return }
            self.performWrite {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                var data = try encoder.encode(event)
                data.append(0x0a)
                let url = self.directory(id).appendingPathComponent(filename)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try self.write(data, to: url)
                } else {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                }
                try self.pruneNow()
            }
        }
    }

    private func saveAudio(_ samples: [Float], named name: String, id: UUID) {
        // Filenames are internal constants or generated UUIDs, never transcript content.
        guard name == URL(fileURLWithPath: name).lastPathComponent else { return }
        queue.async {
            guard FileManager.default.fileExists(atPath: self.directory(id).path) else { return }
            self.performWrite {
                let url = self.directory(id).appendingPathComponent(name)
                try self.write(Data(), to: url)
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate,
                                           channels: 1, interleaved: false)!
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                if !samples.isEmpty {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                          let channel = buffer.floatChannelData?[0] else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    buffer.frameLength = AVAudioFrameCount(samples.count)
                    samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
                    try file.write(from: buffer)
                }
            }
            // Close the WAV before measuring size or pruning it.
            self.performWrite { try self.pruneNow() }
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func managedDirectories() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).filter {
                guard UUID(uuidString: $0.lastPathComponent) != nil else { return false }
                let values = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values.isDirectory == true && values.isSymbolicLink != true
            }
    }

    private func pruneNow() throws {
        let fm = FileManager.default
        var entries: [(url: URL, date: Date, bytes: Int)] = []
        for url in try managedDirectories() {
            let date = try url.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
            if date < Date().addingTimeInterval(-maxAge) {
                try fm.removeItem(at: url)
                continue
            }
            let files = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])
            let bytes = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            entries.append((url, date, bytes))
        }
        var total = entries.reduce(0) { $0 + $1.bytes }
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > maxBytes {
            try fm.removeItem(at: entry.url)
            total -= entry.bytes
        }
    }

    private func performWrite(_ operation: () throws -> Void) {
        do { try operation() }
        catch {
            writeFailed = true
            // Error descriptions can contain private paths. Keep the timing log content-free.
            DiagLog.log("diagnostic recording save or retention failed; archive may be incomplete")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.writeFailedNotification, object: nil)
            }
        }
    }
}
