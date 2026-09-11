import Foundation
import Darwin

/// Diagnostic sink that works regardless of how the app was launched.
/// NSLog is redacted in the unified log and only visible when the binary
/// runs from a terminal — which also changes TCC attribution and has
/// broken the mic. Lines land in ~/Library/Logs/LocalFlow-diag.log
/// Transcript content must never be logged here.
enum DiagLog {
    private static let queue = DispatchQueue(label: "app.talix.localflow.diaglog", qos: .utility)
    private static let path = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Logs/\(AppIdentity.current.logFilename)")
    static var fileURL: URL { URL(fileURLWithPath: path) }
    private static var archiveFailed = false
    private static let sessionEnvironment = environmentLine()
    static func readHistory(maximumTraces: Int) throws -> DiagnosticsSnapshot {
        try queue.sync {
            guard !archiveFailed else { throw CocoaError(.fileWriteUnknown) }
            return try DiagnosticsArchive.local.read(maximumTraces: maximumTraces)
        }
    }
    private static let privacyLogVersionKey = "diagLogPrivacyVersion"
    private static let currentPrivacyLogVersion = 1
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Trim on launch so the log can't grow without bound.
    static func startSession(afterRecovery: () -> Void = {}) {
        queue.sync {
            if AppIdentity.current.isLocal {
                do {
                    try DiagnosticsArchive.local.recover(log: fileURL, recordings: DiagnosticsArchive.local.directory
                        .deletingLastPathComponent().appendingPathComponent("DiagnosticRecordings"))
                } catch {
                    archiveFailed = true
                    NSLog("LocalFlow: timing history recovery failed: %@", String(describing: type(of: error)))
                }
            }
            // Older builds logged transcript content. Purge that legacy file
            // once so upgrading also removes text already written to disk.
            let defaults = UserDefaults.standard
            if defaults.integer(forKey: privacyLogVersionKey) < currentPrivacyLogVersion {
                let manager = FileManager.default
                if manager.fileExists(atPath: path) {
                    try? manager.removeItem(atPath: path)
                }
                if !manager.fileExists(atPath: path) {
                    defaults.set(currentPrivacyLogVersion, forKey: privacyLogVersionKey)
                }
            }

            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            if let size = attrs?[.size] as? Int, size > 5_000_000, !archiveFailed {
                try? FileManager.default.removeItem(atPath: path)
            }
            write("=== LocalFlow session start (pid \(ProcessInfo.processInfo.processIdentifier)) ===")
            write(sessionEnvironment)
            if !archiveFailed { afterRecovery() }
        }
    }

    /// NSLog-compatible signature so existing call sites convert mechanically.
    static func log(_ format: String, _ args: CVarArg...) {
        let message = String(format: format, arguments: args)
        queue.async {
            // Event-tap and audio callbacks log here. Keep unified and file I/O
            // off those latency-sensitive threads.
            NSLog("LocalFlow: %@", message)
            write(message)
        }
    }

    static func timing(_ event: DictationTrace.Event) {
        queue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(event),
                  let json = String(data: data, encoding: .utf8) else { return }
            write("timing " + json)
            if AppIdentity.current.isLocal {
                do { try DiagnosticsArchive.local.record(event, environment: sessionEnvironment) }
                catch {
                    archiveFailed = true
                    NSLog("LocalFlow: timing history write failed: %@", String(describing: type(of: error)))
                }
            }
        }
    }

    /// Build and host metadata only. Excludes usernames, serial numbers,
    /// vocabulary, corrections, snippets, and clipboard contents.
    static func environmentLine() -> String {
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let process = ProcessInfo.processInfo
        let bundle = Bundle.main
        let values: [String: String] = [
            "schemaVersion": "1", "pid": String(process.processIdentifier),
            "osVersion": process.operatingSystemVersionString,
            "processorCount": String(process.processorCount),
            "memoryBytes": String(process.physicalMemory),
            "hardwareModel": systemString("hw.model"),
            "chip": systemString("machdep.cpu.brand_string"),
            "appVersion": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unbundled",
            "buildConfiguration": configuration,
            "buildCommit": bundle.object(forInfoDictionaryKey: "LFBuildCommit") as? String ?? "unknown",
            "buildDirty": bundle.object(forInfoDictionaryKey: "LFBuildDirty") as? String ?? "unknown"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "timing_environment unavailable" }
        return "timing_environment " + json
    }

    private static func systemString(_ name: String) -> String {
        var length = 0
        guard sysctlbyname(name, nil, &length, nil, 0) == 0, length > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname(name, &bytes, &length, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }

    private static func write(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
