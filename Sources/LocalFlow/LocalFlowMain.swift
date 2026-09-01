import AppKit

// LocalFlow — local push-to-talk dictation for macOS.
// Hold the hotkey, speak, release: WhisperKit transcribes on-device,
// optional local model cleanup prepares the text for the focused app.

@main
struct LocalFlowMain {
    // NSApplication.delegate is weak — hold the delegate for the app's lifetime.
    @MainActor private static var delegate: AppDelegate?

    static func main() {
        let arguments = CommandLine.arguments
        if let flagIndex = arguments.firstIndex(of: "--transcribe"), flagIndex + 1 < arguments.count {
            transcribeFile(
                arguments[flagIndex + 1],
                cleanupEnabled: !arguments.contains("--no-cleanup")
            )
            return
        }
        if let flagIndex = arguments.firstIndex(of: "--record-test") {
            // Optional trailing arg: a device UID to record from (defaults
            // to the saved setting / system default).
            let uid = flagIndex + 1 < arguments.count ? arguments[flagIndex + 1] : nil
            MainActor.assumeIsolated { recordTest(deviceUID: uid) }
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
    /// pipeline the app uses (including optional local model cleanup), and prints
    /// per-stage timings to stderr and the final text to stdout.
    private static func transcribeFile(_ path: String, cleanupEnabled: Bool) {
        let done = DispatchSemaphore(value: 0)
        Task {
            defer { done.signal() }
            do {
                let stderr = FileHandle.standardError
                let transcriber = Transcriber()

                var stageStart = Date()
                await transcriber.setVocabulary(Settings.effectiveVocabulary)
                try await transcriber.load(model: Settings.whisperModel)
                stderr.write(Data("model load: \(elapsedMs(since: stageStart))ms (\(Settings.whisperModel))\n".utf8))

                stageStart = Date()
                var text = try await transcriber.transcribe(file: path)
                stderr.write(Data("transcribe: \(elapsedMs(since: stageStart))ms\n".utf8))
                text = VoiceFormatter.apply(
                    TranscriptCorrections.apply(text, corrections: Settings.corrections)
                )

                if cleanupEnabled, Settings.cleanupEnabled {
                    stageStart = Date()
                    let result = try await LocalTextModelPolicy.shared.cleanup(
                        text,
                        model: Settings.ollamaModel,
                        profile: .general
                    )
                    text = result.text
                    let outcome = result.succeeded ? "complete" : "raw fallback"
                    stderr.write(Data("local cleanup: \(elapsedMs(since: stageStart))ms (\(outcome))\n".utf8))
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
    /// format resolution, fallback) — consecutive, because the second
    /// capture in a process behaves differently from the first, exactly
    /// like a user's second hotkey press: with keep-warm on it must reuse
    /// the warm session (near-zero start), without it it must survive
    /// teardown residue.
    @MainActor
    private static func recordTest(deviceUID: String?) {
        let stderr = FileHandle.standardError
        let recorder = AudioRecorder()
        recorder.deviceUID = deviceUID ?? Settings.inputDeviceUID
        recorder.keepWarm = Settings.keepMicWarm
        var failures = 0

        for round in 1...3 {
            var finished = false
            let startedAt = Date()
            recorder.start { error in
                stderr.write(Data("round \(round): start took \(Int(Date().timeIntervalSince(startedAt) * 1000))ms\n".utf8))
                if let error {
                    stderr.write(Data("round \(round): start FAILED: \(error.localizedDescription)\n".utf8))
                    failures += 1
                    finished = true
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
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
