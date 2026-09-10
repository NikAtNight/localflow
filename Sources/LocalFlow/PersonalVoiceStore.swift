import AVFoundation
import Darwin
import Foundation

/// Permanent, reviewed voice data. Only the local app opts into collecting it.
/// The serial writer preserves existing clips when the quota is reached.
final class PersonalVoiceStore: @unchecked Sendable {
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LocalFlow Local/PersonalVoice", isDirectory: true)
    static let shared = PersonalVoiceStore(folder: folder)

    struct Clip: Codable, Identifiable {
        let id: UUID
        let createdAt: Date
        var duration: Double = 0
        var sampleRate: Double = 16_000
        var audioSource = "dictation16k"
        var rawTranscript = ""
        var finalTranscript: String?
        var reviewedTranscript: String?
        var approved = false
        var failureReason: String?
        var metadata: DictationDiagnosticStore.Metadata?
    }

    struct Snapshot {
        let clips: [Clip]
        let usedBytes: Int64
        let maxBytes: Int64
        let issue: String?
    }

    enum ArchiveError: LocalizedError {
        case full, invalidTranscript, missingClip, noApprovedClips, invalidAudio
        var errorDescription: String? {
            switch self {
            case .full: return "Personal voice storage is full. New saves are paused; existing clips are kept. Delete unwanted clips to resume."
            case .invalidTranscript: return "Enter a verbatim transcript before approving this clip. Transcripts must be under 200,000 characters."
            case .missingClip: return "The selected voice clip is no longer available."
            case .noApprovedClips: return "Review and approve at least one clip before exporting."
            case .invalidAudio: return "The recording has no usable audio."
            }
        }
    }

    final class Recording: @unchecked Sendable {
        let id: UUID
        private let store: PersonalVoiceStore
        fileprivate init(id: UUID, store: PersonalVoiceStore) { self.id = id; self.store = store }

        func capture(native: NativeAudioRecording?, fallback: [Float]) {
            store.enqueue {
                guard var clip = self.store.pending[self.id] else { return }
                defer { self.store.pending.removeValue(forKey: self.id) }
                let useNative = native?.isComplete == true && native?.samples.isEmpty == false
                let samples = useNative ? native!.samples : fallback
                clip.sampleRate = useNative ? native!.sampleRate : AudioRecorder.sampleRate
                clip.audioSource = useNative ? "nativeMono" : "dictation16k"
                if native != nil && !useNative {
                    clip.failureReason = "Native audio was incomplete; saved the 16 kHz dictation audio instead."
                }
                guard clip.sampleRate.isFinite, clip.sampleRate > 0,
                      !samples.isEmpty, samples.allSatisfy(\.isFinite) else { throw ArchiveError.invalidAudio }
                clip.duration = Double(samples.count) / clip.sampleRate
                try self.store.save(clip, samples: samples)
            }
        }

        func setRawTranscript(_ text: String) {
            store.enqueue { try self.store.update(self.id) { $0.rawTranscript = text } }
        }

        func setFinalTranscript(_ text: String) {
            store.enqueue { try self.store.update(self.id) { $0.finalTranscript = text } }
        }

        func finish(status: String) {
            store.enqueue {
                defer { self.store.pending.removeValue(forKey: self.id) }
                if status != "success" {
                    try self.store.update(self.id) { $0.failureReason = "Dictation ended with status: \(status). Review the audio and transcript." }
                }
            }
        }
    }

    private let root: URL
    private let maxBytes: Int64
    private let diagnosticsFolder: URL
    private let queue = DispatchQueue(label: "app.talix.localflow.personal-voice", qos: .utility)
    private var pending: [UUID: Clip] = [:]
    private var issue: String?

    init(folder: URL, maxBytes: Int64 = 20_000_000_000,
         diagnosticsFolder: URL = DictationDiagnosticStore.folder) {
        root = folder
        self.maxBytes = maxBytes
        self.diagnosticsFolder = diagnosticsFolder
    }

    func begin(_ metadata: DictationDiagnosticStore.Metadata) -> Recording {
        queue.async {
            self.pending[metadata.traceID] = Clip(id: metadata.traceID, createdAt: metadata.startedAt, metadata: metadata)
        }
        return Recording(id: metadata.traceID, store: self)
    }

    func audioURL(for id: UUID) -> URL { directory(id).appendingPathComponent("audio.wav") }
    func flush() { queue.sync {} }

    func snapshot() async throws -> Snapshot {
        try await perform {
            var clips: [Clip] = []
            let directories = try self.directories()
            if try self.directories(includePending: true).count > directories.count {
                self.issue = "Unfinished recordings from an interrupted save are kept in hidden .pending folders in the archive. They count toward storage and may need manual recovery."
            }
            for directory in directories {
                do { clips.append(try self.readClip(directory)) }
                catch { self.issue = "Some voice clips could not be read. Their files have been kept." }
            }
            return Snapshot(clips: clips.sorted { $0.createdAt > $1.createdAt },
                            usedBytes: try self.usedBytes(), maxBytes: self.maxBytes, issue: self.issue)
        }
    }

    func updateReview(id: UUID, transcript: String, approved: Bool) async throws {
        try await perform {
            guard transcript.count < 200_000,
                  !approved || !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ArchiveError.invalidTranscript
            }
            guard FileManager.default.fileExists(atPath: self.audioURL(for: id).path) else { throw ArchiveError.missingClip }
            try self.update(id) {
                $0.reviewedTranscript = transcript
                $0.approved = approved
            }
        }
    }

    func delete(id: UUID) async throws {
        try await perform {
            self.pending.removeValue(forKey: id)
            let directory = self.directory(id)
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            try FileManager.default.removeItem(at: directory)
            self.issue = nil
        }
    }

    func importDiagnostics() async throws -> Int {
        try await perform {
            let fm = FileManager.default
            guard fm.fileExists(atPath: self.diagnosticsFolder.path) else { return 0 }
            let sources = try fm.contentsOfDirectory(at: self.diagnosticsFolder, includingPropertiesForKeys: [.isSymbolicLinkKey])
            var imported = 0
            for source in sources.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let id = UUID(uuidString: source.lastPathComponent),
                      try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                      !fm.fileExists(atPath: self.directory(id).path) else { continue }
                let original = source.appendingPathComponent("original.wav")
                guard fm.fileExists(atPath: original.path) else { continue }
                let metadata = try self.decoder().decode(DictationDiagnosticStore.Metadata.self,
                    from: Data(contentsOf: source.appendingPathComponent("metadata.json")))
                guard metadata.traceID == id else { throw ArchiveError.missingClip }
                var clip = Clip(id: id, createdAt: metadata.startedAt, metadata: metadata)
                let eventsURL = source.appendingPathComponent("events.jsonl")
                var captureComplete = false
                if let events = try? Data(contentsOf: eventsURL) {
                    for line in events.split(separator: 0x0a) {
                        guard let event = try? self.decoder().decode(DictationDiagnosticStore.Event.self, from: Data(line)) else { continue }
                        if event.stage == "capture" { captureComplete = true }
                        if event.stage == "assembledTranscript" { clip.rawTranscript = event.text ?? "" }
                        if event.stage == "finalTranscript" { clip.finalTranscript = event.text }
                    }
                }
                // Capture is recorded on the diagnostic queue after the WAV closes.
                guard captureComplete else { continue }
                let audio = try AVAudioFile(forReading: original)
                guard audio.length > 0 else { continue }
                clip.duration = Double(audio.length) / audio.fileFormat.sampleRate
                clip.sampleRate = audio.fileFormat.sampleRate
                let metadataData = try self.encoder().encode(clip)
                let bytes = try original.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                try self.checkCapacity(additional: Int64(bytes + metadataData.count))
                let staging = self.root.appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
                try self.createDirectory(staging)
                defer { try? fm.removeItem(at: staging) }
                let targetAudio = staging.appendingPathComponent("audio.wav")
                try fm.copyItem(at: original, to: targetAudio)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetAudio.path)
                try self.write(metadataData, to: staging.appendingPathComponent("clip.json"))
                try fm.moveItem(at: staging, to: self.directory(id))
                imported += 1
            }
            return imported
        }
    }

    func exportApproved(to parent: URL) async throws -> Int {
        try await perform {
            let clips = try self.directories().map { try self.readClip($0) }.filter {
                $0.approved && !($0.reviewedTranscript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard !clips.isEmpty else { throw ArchiveError.noApprovedClips }
            let destination = parent.appendingPathComponent("LocalFlow-Voice-\(UUID().uuidString)", isDirectory: true)
            try self.createDirectory(destination.appendingPathComponent("wavs"))
            do {
                var manifest = Data()
                for clip in clips {
                    let relative = "wavs/\(clip.id.uuidString).wav"
                    let target = destination.appendingPathComponent(relative)
                    try FileManager.default.copyItem(at: self.audioURL(for: clip.id), to: target)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                    let row: [String: Any] = ["id": clip.id.uuidString, "audio_path": relative,
                                            "text": clip.reviewedTranscript!, "sample_rate": clip.sampleRate,
                                            "speaker": "localflow-user"]
                    manifest.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
                    manifest.append(0x0a)
                }
                try self.write(manifest, to: destination.appendingPathComponent("manifest.jsonl"))
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            return clips.count
        }
    }

    private func save(_ clip: Clip, samples: [Float]) throws {
        let data = try encoder().encode(clip)
        try checkCapacity(additional: Int64(samples.count) * 4 + Int64(data.count))
        let destination = directory(clip.id)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        let staging = root.appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
        try createDirectory(staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let audio = staging.appendingPathComponent("audio.wav")
        try RetainedAudioFile.write(samples: samples, sampleRate: clip.sampleRate, to: audio)
        // WAV headers vary. Check the completed file size before publishing it.
        // The staged audio already counts toward usage, including after a crash.
        try checkCapacity(additional: Int64(data.count))
        try write(data, to: staging.appendingPathComponent("clip.json"))
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    private func update(_ id: UUID, mutation: (inout Clip) -> Void) throws {
        if var clip = pending[id] {
            mutation(&clip)
            pending[id] = clip
        } else if FileManager.default.fileExists(atPath: directory(id).path) {
            var clip = try readClip(directory(id))
            mutation(&clip)
            let data = try encoder().encode(clip)
            let url = directory(id).appendingPathComponent("clip.json")
            // The limit pauses new audio. Existing clips must remain reviewable,
            // and an admitted recording must still receive its transcript.
            try write(data, to: url)
        }
    }

    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func directories(includePending: Bool = false) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).filter {
            let values = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let name = $0.lastPathComponent
            let managed = UUID(uuidString: name) != nil || (includePending && name.hasPrefix(".pending-") && UUID(uuidString: String(name.dropFirst(9))) != nil)
            return managed && values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    private func readClip(_ directory: URL) throws -> Clip {
        let clip = try decoder().decode(Clip.self, from: Data(contentsOf: directory.appendingPathComponent("clip.json")))
        guard clip.id == UUID(uuidString: directory.lastPathComponent),
              clip.metadata == nil || clip.metadata?.traceID == clip.id else { throw ArchiveError.missingClip }
        return clip
    }

    private func usedBytes() throws -> Int64 {
        try directories(includePending: true).reduce(0) { total, directory in
            try total + FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
                .reduce(0) { try $0 + Int64($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        }
    }

    private func checkCapacity(additional: Int64) throws {
        guard try usedBytes() + max(0, additional) <= maxBytes else { throw ArchiveError.full }
    }

    private func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if url.path.hasPrefix(root.path + "/") {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func enqueue(_ operation: @escaping () throws -> Void) {
        queue.async {
            do { try self.withFileLock(operation) }
            catch { self.issue = error.localizedDescription }
        }
    }

    private func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.withFileLock(operation)) }
                catch { self.issue = error.localizedDescription; continuation.resume(throwing: error) }
            }
        }
    }

    // The serial queue orders one store's callbacks. The file lock also covers
    // CLI imports and other store instances sharing this archive.
    private func withFileLock<T>(_ operation: () throws -> T) throws -> T {
        try createDirectory(root)
        let descriptor = open(root.appendingPathComponent(".archive.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
