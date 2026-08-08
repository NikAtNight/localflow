import Foundation

/// Appends every finished dictation to a daily Markdown file under
/// ~/Library/Application Support/LocalFlow/History.
///
/// Application Support rather than ~/Documents on purpose: Documents is
/// iCloud-synced on most Macs (the Whisper model cache had to be moved out
/// of it for the same reason), and dictation transcripts must not leave the
/// machine. Nothing is pruned — plain text is tiny and the history is the
/// user's record.
enum DictationHistory {
    /// Serial and off the main thread: the paste path must never wait on disk.
    private static let queue = DispatchQueue(label: "app.talix.localflow.history", qos: .utility)

    static let folder: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LocalFlow/History", isDirectory: true)

    /// Records one dictation. Fire-and-forget; failures are logged, never
    /// surfaced — losing a history line must not disturb a good dictation.
    static func record(_ text: String, at date: Date = Date()) {
        guard Settings.saveHistory else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.async { append(entry(for: trimmed, at: date), toFileFor: date) }
    }

    /// `## 14:32:07` followed by the dictation, verbatim. Text is never
    /// escaped: this is a record of what was written, and fidelity beats
    /// Markdown purity for the rare dictation that starts with "#".
    static func entry(for text: String, at date: Date) -> String {
        "## \(timeFormatter.string(from: date))\n\n\(text)\n\n"
    }

    static func fileName(for date: Date) -> String {
        "\(dayFormatter.string(from: date)).md"
    }

    /// Deletes every stored transcript. Used by the Settings button.
    static func deleteAll() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private static func append(_ entry: String, toFileFor date: Date) {
        let fm = FileManager.default
        let file = folder.appendingPathComponent(fileName(for: date))
        do {
            if !fm.fileExists(atPath: folder.path) {
                // Owner-only: a dictation log is as private as the dictations.
                try fm.createDirectory(
                    at: folder,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            guard fm.fileExists(atPath: file.path) else {
                let header = "# Dictations \(dayFormatter.string(from: date))\n\n"
                try (header + entry).write(to: file, atomically: true, encoding: .utf8)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                return
            }
            // Append without reading the whole day back into memory.
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(entry.utf8))
        } catch {
            DiagLog.log("could not write dictation history: %@", error.localizedDescription)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
