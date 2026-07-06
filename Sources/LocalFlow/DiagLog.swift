import Foundation

/// Diagnostic sink that works regardless of how the app was launched.
/// NSLog is redacted in the unified log and only visible when the binary
/// runs from a terminal — which also changes TCC attribution and has
/// broken the mic. Lines land in ~/Library/Logs/LocalFlow-diag.log
/// (transcript CONTENT must never be logged here except the raw-Whisper
/// line for empty transcripts, which by definition carries none).
enum DiagLog {
    private static let queue = DispatchQueue(label: "app.talix.localflow.diaglog", qos: .utility)
    private static let path = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Logs/LocalFlow-diag.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Trim on launch so the log can't grow without bound.
    static func startSession() {
        queue.async {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            if let size = attrs?[.size] as? Int, size > 5_000_000 {
                try? FileManager.default.removeItem(atPath: path)
            }
            write("=== LocalFlow session start (pid \(ProcessInfo.processInfo.processIdentifier)) ===")
        }
    }

    /// NSLog-compatible signature so existing call sites convert mechanically.
    static func log(_ format: String, _ args: CVarArg...) {
        let message = String(format: format, arguments: args)
        NSLog("LocalFlow: %@", message)
        queue.async { write(message) }
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
