import AppKit

// LocalFlow — local push-to-talk dictation for macOS.
// Hold the hotkey, speak, release: WhisperKit transcribes on-device,
// optional Ollama pass cleans the text, result is pasted into the focused app.

@main
struct LocalFlowMain {
    // NSApplication.delegate is weak — hold the delegate for the app's lifetime.
    @MainActor private static var delegate: AppDelegate?

    static func main() {
        let arguments = CommandLine.arguments
        if let flagIndex = arguments.firstIndex(of: "--transcribe"), flagIndex + 1 < arguments.count {
            transcribeFile(arguments[flagIndex + 1])
            return
        }
        if arguments.contains("--record-test") {
            recordTest()
            return
        }

        // A second instance means two event taps and every dictation pasted
        // twice — easy to hit by launching a fresh build while the login
        // item is still running. (Checked after --transcribe: the CLI mode
        // may run alongside the app.)
        let alreadyRunning = NSRunningApplication
            .runningApplications(withBundleIdentifier: "app.talix.localflow")
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if alreadyRunning {
            FileHandle.standardError.write(Data("LocalFlow is already running — exiting this instance.\n".utf8))
            return
        }

        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let appDelegate = AppDelegate()
            delegate = appDelegate
            app.delegate = appDelegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }

    /// Headless mode for testing and latency benchmarking:
    ///   LocalFlow --transcribe recording.wav
    /// Loads the configured Whisper model, transcribes the file with the same
    /// pipeline the app uses (including optional Ollama cleanup), and prints
    /// per-stage timings to stderr and the final text to stdout.
    private static func transcribeFile(_ path: String) {
        let done = DispatchSemaphore(value: 0)
        Task {
            defer { done.signal() }
            do {
                let stderr = FileHandle.standardError
                let transcriber = Transcriber()

                var stageStart = Date()
                try await transcriber.load(model: Settings.whisperModel)
                stderr.write(Data("model load: \(elapsedMs(since: stageStart))ms (\(Settings.whisperModel))\n".utf8))

                stageStart = Date()
                var text = try await transcriber.transcribe(file: path)
                stderr.write(Data("transcribe: \(elapsedMs(since: stageStart))ms\n".utf8))

                if Settings.cleanupEnabled, await OllamaCleaner.isAvailable() {
                    stageStart = Date()
                    text = try await OllamaCleaner.clean(text, model: Settings.ollamaModel)
                    stderr.write(Data("ollama cleanup: \(elapsedMs(since: stageStart))ms (\(Settings.ollamaModel))\n".utf8))
                }

                print(text)
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        done.wait()
    }

    private static func elapsedMs(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// Headless capture check:
    ///   LocalFlow --record-test
    /// Records ~2s through the exact AudioRecorder pipeline the hotkey uses
    /// (device selection, Bluetooth avoidance, format resolution, fallback)
    /// and reports the outcome — the piece `--transcribe` can't exercise.
    private static func recordTest() {
        let stderr = FileHandle.standardError
        let recorder = AudioRecorder()
        recorder.deviceUID = Settings.inputDeviceUID
        var finished = false

        recorder.start { error in
            if let error {
                stderr.write(Data("record start FAILED: \(error.localizedDescription)\n".utf8))
                finished = true
                return
            }
            stderr.write(Data("record started OK — capturing 2s…\n".utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                recorder.stop { samples in
                    let seconds = Double(samples.count) / AudioRecorder.sampleRate
                    let peak = samples.map(abs).max() ?? 0
                    print("captured \(samples.count) samples (\(String(format: "%.2f", seconds))s), peak level \(String(format: "%.4f", peak))")
                    finished = true
                }
            }
        }

        let deadline = Date().addingTimeInterval(15)
        while !finished, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        if !finished {
            stderr.write(Data("record test timed out\n".utf8))
            exit(1)
        }
    }
}
