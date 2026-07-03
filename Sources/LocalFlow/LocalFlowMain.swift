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
    /// Runs three consecutive ~1.5s captures through the exact AudioRecorder
    /// pipeline the hotkey uses (device selection, Bluetooth avoidance,
    /// format resolution, fallback) — consecutive, because engine teardown
    /// residue only bites the SECOND capture in a process, exactly like a
    /// user's second hotkey press.
    private static func recordTest() {
        let stderr = FileHandle.standardError
        let recorder = AudioRecorder()
        recorder.deviceUID = Settings.inputDeviceUID
        var failures = 0

        for round in 1...3 {
            var finished = false
            recorder.start { error in
                if let error {
                    stderr.write(Data("round \(round): start FAILED: \(error.localizedDescription)\n".utf8))
                    failures += 1
                    finished = true
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    recorder.stop { samples in
                        let seconds = Double(samples.count) / AudioRecorder.sampleRate
                        let peak = samples.map(abs).max() ?? 0
                        print("round \(round): captured \(samples.count) samples "
                              + "(\(String(format: "%.2f", seconds))s), peak \(String(format: "%.4f", peak))")
                        if seconds < 1.2 { failures += 1 }
                        finished = true
                    }
                }
            }
            let deadline = Date().addingTimeInterval(15)
            while !finished, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            if !finished {
                stderr.write(Data("round \(round): timed out\n".utf8))
                exit(1)
            }
            // A beat between rounds, like a user pausing between dictations.
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        print(failures == 0 ? "record test PASSED" : "record test FAILED (\(failures) bad rounds)")
        exit(failures == 0 ? 0 : 1)
    }
}
