import AppKit
import AVFoundation
import ServiceManagement

struct UserFacingIssue: Equatable {
    static let menuCharacterLimit = 48

    let summary: String
    let details: String
    let at: Date

    init(summary: String, details: String, at: Date = Date()) {
        self.summary = summary
        self.details = details
        self.at = at
    }

    var menuSummary: String {
        let normalized = summary.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let text = normalized.isEmpty ? "Something went wrong" : normalized
        guard text.count > Self.menuCharacterLimit else { return text }
        let prefix = text.prefix(Self.menuCharacterLimit - 1)
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

enum IncrementalCleanupPlan {
    static func shouldCleanTailOnly(
        incrementalTranscriptionSucceeded: Bool,
        chunkCleanupActive: Bool,
        allCommittedChunksCleaned: Bool,
        tailCleanupSucceeded: Bool,
        capturedProfile: AppStyleProfile,
        releaseProfile: AppStyleProfile,
        cleanupEnabledAtRelease: Bool
    ) -> Bool {
        incrementalTranscriptionSucceeded
            && chunkCleanupActive
            && allCommittedChunksCleaned
            && tailCleanupSucceeded
            && capturedProfile == releaseProfile
            && cleanupEnabledAtRelease
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum State {
        case loadingModel
        case idle
        case recording
        case processing
        case failed(UserFacingIssue)
    }

    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var recentMenuItem: NSMenuItem!
    private var retryMenuItem: NSMenuItem!
    // Quick-action submenus — the three most-changed settings, mirrored out
    // of the settings window so they're one click away.
    private var hotkeyMenuItem: NSMenuItem!
    private var modelMenuItem: NSMenuItem!
    private var micMenuItem: NSMenuItem!
    private var settingsModel: SettingsModel!
    private var settingsController: SettingsPanelController!

    // Safety nets: a paste can fail (secure input quirks, slow app) and a
    // transcription can error — neither should ever lose the user's words.
    private var recentTranscripts: [RecentDictation] = []
    // FIFO, bounded: two failures in a row must not discard the first
    // dictation's audio.
    private var retrySamples: [[Float]] = []

    // Dictations must paste in SPOKEN order, but cleanup time varies (a
    // short later dictation can clear the LLM before a long earlier one).
    // Every dictation takes a sequence number in `process`; its result
    // waits here until all earlier numbers have resolved.
    private enum DictationOutcome {
        case inject(String)
        case skip // silence, empty transcript, or a failed transcription
    }
    private var injectionQueue: [Int: DictationOutcome] = [:]
    private var injectionSeqCounter = 0
    private var nextInjectionSeq = 0
    // True while a between-pastes beat is pending; the delayed step owns
    // the next drain, so an outcome arriving mid-beat must not jump it.
    private var injectionDrainPending = false
    private var headStallTimeout: DispatchWorkItem?
    // A dictation should resolve in seconds; one stuck this long with later
    // results waiting behind it is hung (its text is in Recent Dictations
    // if it ever resolves), and must not dam every later paste forever.
    private static let injectionStallSeconds: TimeInterval = 90

    private let updates = UpdateController()
    private let hotkey = HotkeyManager()
    private let commandHotkey = HotkeyManager()
    private var commandHotkeyActive = false
    /// True while the in-flight recording is a command-mode utterance
    /// rather than a dictation. Both share one recorder, so only one can be
    /// held at a time.
    private var recordingIsCommand = false
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let overlay = WaveformOverlay()

    private struct DictationContext {
        let styleProfile: AppStyleProfile
        let cleanupEnabled: Bool
        let ollamaModel: String
        let corrections: [(wrong: String, right: String)]
        let snippets: [(trigger: String, expansion: String)]

        @MainActor
        static func capture() -> DictationContext {
            DictationContext(
                styleProfile: AppStyleProfile.current(),
                cleanupEnabled: Settings.cleanupEnabled,
                ollamaModel: Settings.ollamaModel,
                corrections: Settings.corrections,
                snippets: Settings.snippets
            )
        }
    }

    private final class IncrementalRecording {
        let generation: Int
        let context: DictationContext
        var committedEnd = 0
        var committedText = ""
        var cleanedCommittedText = ""
        var chunkCount = 0
        var cleanedChunkCount = 0
        var nextPauseSeconds = 0.0
        var failed = false
        var chunkCleanupFailed = false
        var pass: Task<Void, Never>?
        var cleanupTask: Task<Void, Never>?
        var cleanupTasks: [Task<Void, Never>] = []
        var timer: DispatchWorkItem?

        init(generation: Int, context: DictationContext) {
            self.generation = generation
            self.context = context
        }
    }

    private struct IncrementalStats {
        let chunkCount: Int
        let committedSeconds: Double
        let tailSeconds: Double
    }

    private enum IncrementalError: Error {
        case emptyVoicedTail
    }

    private var incrementalRecording: IncrementalRecording?

    private var state: State = .loadingModel {
        didSet {
            // Failure banners self-clear after 3s; keep the last one
            // reachable in the menu until a dictation succeeds again.
            if case .failed(let issue) = state { lastError = issue }
            refreshStatusUI()
        }
    }
    private var lastError: UserFacingIssue? {
        didSet { settingsModel?.lastIssue = lastError }
    }
    private var lastErrorMenuItem: NSMenuItem!

    /// What to show when nothing is recording and no failure banner is up.
    /// Never claims "Ready" while a model (re)load is in flight — the hotkey
    /// gates on `modelLoaded` and would just look dead.
    private var restingState: State {
        if !modelLoaded { return .loadingModel }
        return processingCount > 0 ? .processing : .idle
    }
    private var hotkeyActive = false
    private var modelLoaded = false
    private var lastLatencyMs: Int?

    // Recording and transcription are tracked separately from the UI `state`
    // so a new dictation can start while a previous one is still processing —
    // gating presses on `state == .idle` made the hotkey feel dead.
    private var isRecording = false
    private var processingCount = 0
    // Lets a stale async start-failure from an abandoned recording be
    // distinguished from the one currently in flight.
    private var recordingGeneration = 0
    // A start failure can arrive after release already queued stop(). Mark
    // that generation so its empty result is not misreported as silence.
    private var failedCaptureStarts: Set<Int> = []
    // Same idea for model loads: switching models twice quickly must not
    // let the slower (older) load win after the newer one finished.
    private var modelLoadGeneration = 0
    private var modelRetryDelay: TimeInterval = 5

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagLog.startSession()
        buildSettings()
        buildStatusItem()
        requestPermissions()
        startHotkey()
        loadModel()
        // Command mode's hotkey gate needs Ollama reachability even when
        // cleanup is off, so the probe runs for either feature.
        if Settings.cleanupEnabled || Settings.commandModeEnabled {
            probeOllama()
        }
        if Settings.cleanupEnabled {
            // Load the on-device model's weights now, not on the first
            // dictation's cleanup call.
            AppleIntelligenceCleaner.prewarm()
        }
        Task { await transcriber.setVocabulary(Settings.effectiveVocabulary) }
        // Called on the audio thread; overlay.push hops to main internally.
        let overlay = self.overlay
        recorder.onLevel = { level in overlay.push(level: level) }
        recorder.onSpectrum = { bands in overlay.push(spectrum: bands) }
        // The capture-live cue is passed to recorder.start per press, so it
        // carries that recording's generation and is installed on the
        // recorder's own queues — recording A's audio can't fire B's cue.
        // Capture died mid-recording and recovery failed — stop pretending
        // the mic is live.
        recorder.onRuntimeFailure = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.isRecording else { return }
                self.isRecording = false
                self.recordingGeneration += 1
                self.discardIncrementalRecording()
                self.overlay.hide()
                self.playCue("Basso")
                self.state = .failed(UserFacingIssue(
                    summary: "Microphone stopped",
                    details: error.localizedDescription
                ))
                self.scheduleFailureRecovery()
            }
        }
        recorder.deviceUID = Settings.inputDeviceUID
        recorder.keepWarm = Settings.keepMicWarm
        // Hot-plug: when the default input or the device list changes, an
        // idle warm session moves to whatever the next dictation would use,
        // instead of sitting on the stale device until the next press.
        AudioDevices.observeDeviceChanges { [weak self] in
            self?.recorder.reconcileRoute()
        }
        observeSystemTransitions()
        registerLoginItemOnce()
        updates.start()
        // Bundle icon matches whichever listening theme is active; the
        // make-app icon is only the classic-wave default.
        ThemeIcon.apply(HudTheme.current)
    }

    /// Settings live in a window (see SettingsWindow.swift); these hooks let
    /// changes there reach the live hotkey tap, recorder, and transcriber.
    private func buildSettings() {
        settingsModel = SettingsModel()
        settingsModel.onHotkeyChange = { [weak self] key in
            self?.hotkey.key = key
            self?.refreshStatusUI()
        }
        settingsModel.onModelChange = { [weak self] in self?.loadModel() }
        settingsModel.onMicChange = { [weak self] uid in
            // Release the old warm route and pre-open the new one so its
            // Bluetooth hands-free transition is paid at selection time,
            // rather than during the first dictation.
            self?.recorder.selectDevice(uid)
        }
        settingsModel.onKeepWarmChange = { [weak self] in
            self?.recorder.keepWarm = Settings.keepMicWarm
            if !Settings.keepMicWarm { self?.recorder.releaseWarmSession() }
        }
        settingsModel.onCleanupToggle = { [weak self] in
            guard Settings.cleanupEnabled else { return }
            self?.probeOllama()
            AppleIntelligenceCleaner.prewarm()
        }
        // Vocabulary and corrections feed the same decoder bias; either
        // changing rebuilds the effective term list.
        let refreshVocabulary = { [weak self] in
            guard let self else { return }
            let transcriber = self.transcriber
            let terms = Settings.effectiveVocabulary
            Task { await transcriber.setVocabulary(terms) }
        }
        settingsModel.onVocabularyChange = { _ in refreshVocabulary() }
        settingsModel.onCorrectionsChange = { refreshVocabulary() }
        settingsModel.onCommandModeChange = { [weak self] in
            // Enabling may hinge on Ollama; the probe re-runs the hotkey
            // start once reachability is known.
            if Settings.commandModeEnabled { self?.probeOllama() }
            self?.startCommandHotkey()
        }
        settingsModel.onAutomaticUpdatesChange = { [weak self] in self?.updates.applyAutomaticPreference() }
        settingsModel.onThemeChange = { [weak self] in
            guard let self else { return }
            if !self.isRecording { self.overlay.preview() }
            ThemeIcon.apply(HudTheme.current)
        }
        settingsController = SettingsPanelController(model: settingsModel)
    }

    /// Sleep or a fast-user-switch mid-hold means the key release will never
    /// arrive: without this, the mic keeps recording after wake and the next
    /// press is swallowed by stale hold state.
    private func observeSystemTransitions() {
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, "sleep"),
            (NSWorkspace.sessionDidResignActiveNotification, "session switch"),
        ]
        for (name, label) in events {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.abortRecording(reason: label) }
            }
        }
    }

    /// Ends an in-flight recording *without* transcribing it — pasting the
    /// result minutes later at wake, into whatever happens to have focus,
    /// would be worse than losing a dictation the user watched get cut off.
    private func abortRecording(reason: String) {
        hotkey.cancelHold()
        commandHotkey.cancelHold()
        recordingIsCommand = false
        if isRecording {
            DiagLog.log("%@ while recording — discarding the recording", reason)
            isRecording = false
            recordingGeneration += 1
            discardIncrementalRecording()
            overlay.hide()
            recorder.stop { _ in }
            state = restingState
        }
        // Sleep must not carry an open mic through the nap — release any
        // warm session too (queued after stop, so it sees the idle state).
        recorder.releaseWarmSession()
    }

    /// Login is handled by a LaunchAgent rather than a plain login item so
    /// launchd relaunches the app after a crash (KeepAlive on unsuccessful
    /// exit); a menu-bar Quit exits cleanly and stays quit.
    private static let loginAgent = SMAppService.agent(plistName: "app.talix.localflow.plist")

    /// Registers the app to start at login the first time it runs; the
    /// "Start at Login" menu toggle rules after that. Retries next launch
    /// if registration fails.
    private func registerLoginItemOnce() {
        // v1 registered as a plain login item, which macOS never relaunches
        // after a crash — migrate to the LaunchAgent once.
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
            Settings.loginItemSetupDone = false
        }
        guard !Settings.loginItemSetupDone else { return }
        do {
            try Self.loginAgent.register()
            Settings.loginItemSetupDone = true
            DiagLog.log("registered login agent (relaunches after a crash)")
        } catch {
            DiagLog.log("login agent registration failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Permissions (the #1 friction point — surface issues clearly)

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                DiagLog.log("microphone access denied — grant it in System Settings → Privacy & Security → Microphone")
            }
        }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            DiagLog.log("Accessibility not yet granted — hotkey and paste need it (System Settings → Privacy & Security → Accessibility)")
        }
    }

    private func startHotkey() {
        hotkey.key = Settings.hotkey
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkey.onTapDied = { [weak self] in self?.hotkeyTapDied() }
        attemptHotkeyStart()
        startCommandHotkey()
    }

    /// Command mode runs a second, independent tap so its key is watched
    /// exactly like the dictation key. Silently absent when command mode is
    /// off, the keys collide, or no backend (Apple Intelligence or a
    /// reachable Ollama server) can serve it.
    private func startCommandHotkey() {
        guard Settings.commandModeActive else {
            if commandHotkeyActive {
                commandHotkey.stop()
                commandHotkeyActive = false
            }
            return
        }
        commandHotkey.key = Settings.commandHotkey
        commandHotkey.onPress = { [weak self] in self?.commandKeyPressed() }
        commandHotkey.onRelease = { [weak self] in self?.commandKeyReleased() }
        commandHotkey.onTapDied = { [weak self] in
            guard let self else { return }
            if self.recordingIsCommand { self.commandKeyReleased() }
            self.commandHotkeyActive = false
            self.startCommandHotkey()
        }
        commandHotkey.start { [weak self] verified in
            guard let self else { return }
            self.commandHotkeyActive = verified
            DiagLog.log("command-mode tap %@ (%@)",
                  verified ? "active" : "unavailable", self.commandHotkey.key.label)
        }
    }

    /// The watchdog found the tap dead. A release can't arrive through a
    /// dead tap, so end any recording in progress, then rebuild the tap.
    private func hotkeyTapDied() {
        DiagLog.log("hotkey tap stopped delivering events — rebuilding it")
        if isRecording { hotkeyReleased() }
        hotkeyActive = false
        attemptHotkeyStart()
    }

    /// The tap can't be created — or can be created but receives nothing —
    /// until Accessibility is (re-)granted. Keep retrying so the grant
    /// takes effect without a relaunch.
    private func attemptHotkeyStart() {
        hotkey.start { [weak self] verified in
            guard let self else { return }
            if verified {
                self.hotkeyActive = true
                DiagLog.log("hotkey tap active (%@)", self.hotkey.key.label)
                self.recomputeReadyState()
            } else {
                self.hotkeyActive = false
                self.state = .failed(UserFacingIssue(
                    summary: "Dictation shortcut unavailable",
                    details: "Remove and re-add LocalFlow in Accessibility settings. LocalFlow will keep retrying."
                ))
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.attemptHotkeyStart()
                }
            }
        }
    }

    private func loadModel() {
        modelLoadGeneration += 1
        let generation = modelLoadGeneration
        // A model switch mid-recording must not repaint the recording UI.
        if !isRecording { state = .loadingModel }
        let model = Settings.whisperModel
        Task {
            // Only gate the hotkey when nothing can transcribe: during a
            // switch or retry the previous model keeps serving, and clearing
            // `modelLoaded` would make dictation look dead for the attempt.
            if !(await transcriber.isLoaded) {
                guard generation == modelLoadGeneration else { return }
                modelLoaded = false
            }
            do {
                try await transcriber.load(model: model)
                guard generation == modelLoadGeneration else { return } // superseded
                DiagLog.log("model %@ loaded — ready", model)
                modelRetryDelay = 5
                modelLoaded = true
                recomputeReadyState()
            } catch {
                guard generation == modelLoadGeneration else { return }
                DiagLog.log("model load failed: %@", error.localizedDescription)
                // A failed *switch* leaves the previous model loaded and
                // serving — keep dictation alive on it while retries run.
                if await transcriber.isLoaded {
                    // No recomputeReadyState() here — it would flip straight
                    // back to .idle and the banner would never appear.
                    modelLoaded = true
                    state = .failed(UserFacingIssue(
                        summary: "Couldn't switch Whisper model",
                        details: "Couldn't load \(model): \(error.localizedDescription) "
                            + "The previous model is still active, and LocalFlow will retry."
                    ))
                } else {
                    state = .failed(UserFacingIssue(
                        summary: "Couldn't load Whisper model",
                        details: "\(error.localizedDescription) LocalFlow will retry."
                    ))
                }
                scheduleModelRetry(generation: generation)
            }
        }
    }

    /// A model load failure is usually transient (launch-at-boot racing
    /// Wi-Fi, a Hugging Face hiccup) — retry with backoff instead of leaving
    /// dictation dead until a relaunch.
    private func scheduleModelRetry(generation: Int) {
        let delay = modelRetryDelay
        modelRetryDelay = min(modelRetryDelay * 2, 60)
        DiagLog.log("retrying model load in %.0fs", delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.modelLoadGeneration else { return }
            self.loadModel()
        }
    }

    /// Moves to .idle once both the hotkey tap and the model are ready.
    /// Only transitions out of startup states — never interrupts an active
    /// recording or processing run.
    private func recomputeReadyState() {
        guard hotkeyActive, modelLoaded else { return }
        switch state {
        case .loadingModel, .failed:
            // restingState, not .idle: transcriptions may still be in
            // flight after a model switch finished loading.
            state = isRecording ? .recording : restingState
        case .idle, .recording, .processing:
            break
        }
    }

    private func probeOllama() {
        // Ollama is only the fallback backend, so no point probing (or
        // warning about) it when the on-device model handles everything.
        guard !AppleIntelligenceCleaner.isAvailable else { return }
        Task {
            settingsModel?.ollamaReachable = await OllamaCleaner.isAvailable()
            // Reachability feeds Settings.commandModeActive, and the command
            // tap may have been skipped (or left running) on stale state.
            await MainActor.run { self.startCommandHotkey() }
        }
    }

    // MARK: - Push-to-talk pipeline

    private func hotkeyPressed() {
        // Gate only on the model and an active recording — never on the UI
        // state. Pressing while a previous dictation is still transcribing
        // (or after a transient mic error) must start a new recording.
        guard modelLoaded, !isRecording else {
            // The model recompiles for minutes after every binary change —
            // a press during that window must never be silently swallowed.
            if !modelLoaded {
                DiagLog.log("hotkey press refused: model is not loaded")
                playCue("Basso")
            }
            return
        }
        if Settings.cleanupEnabled && !AppleIntelligenceCleaner.isAvailable {
            Task { await OllamaCleaner.prewarm(model: Settings.ollamaModel) }
        }
        // A denied mic yields an engine that happily records silence —
        // every dictation would "succeed" with nothing to show. Fail loudly.
        let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        if micAuth == .denied || micAuth == .restricted {
            // This early-out was silent in the logs once — presses that
            // "did nothing" with no trace. Never again.
            DiagLog.log("hotkey press refused: microphone authorization is %d", micAuth.rawValue)
            playCue("Basso")
            state = .failed(UserFacingIssue(
                summary: "Microphone access needed",
                details: "Enable LocalFlow in System Settings > Privacy & Security > Microphone."
            ))
            scheduleFailureRecovery()
            return
        }
        isRecording = true
        recordingGeneration += 1
        let generation = recordingGeneration
        if recordingIsCommand {
            discardIncrementalRecording()
        } else {
            beginIncrementalRecording(generation: generation)
        }
        // Enqueue hardware startup before doing menu/HUD work on the main
        // thread. A warm microphone can now begin delivering immediately
        // while the visual state is updated in parallel. The "speak now"
        // cue fires on the first sustained audio, not on engine start, and
        // only for THIS recording's generation.
        recorder.start(onCaptureLive: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isRecording, generation == self.recordingGeneration else { return }
                self.overlay.captureLive()
                self.playCue("Pop")
            }
        }) { [weak self] error in
            guard let self else { return }
            if let error {
                // A newer recording owns the UI, but the failed older start
                // still has a queued stop completion that must be discarded.
                guard generation == self.recordingGeneration else {
                    self.failedCaptureStarts.insert(generation)
                    return
                }
                if self.isRecording {
                    self.isRecording = false
                    self.discardIncrementalRecording()
                    // Release may never call stop now that the active flag is
                    // clear, so finish recorder-side cleanup here.
                    self.recorder.stop { _ in }
                } else {
                    // Release already queued stop; let that completion close
                    // the HUD without treating the empty capture as silence.
                    self.failedCaptureStarts.insert(generation)
                }
                self.overlay.hide()
                self.playCue("Basso")
                self.state = .failed(UserFacingIssue(
                    summary: "Couldn't start the microphone",
                    details: error.localizedDescription
                ))
                self.scheduleFailureRecovery()
                return
            }
            guard generation == self.recordingGeneration else { return }
            // Success cue is handled by onCaptureLive — the first actual
            // audio buffer — not by engine start, which can precede flowing
            // audio by over a second on Bluetooth mics.
        }
        state = .recording
        overlay.show()
        // Backstop against a hold that never ends (stuck key, pocket
        // dictation): cap the recording rather than run an open mic.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxRecordingSeconds) { [weak self] in
            guard let self, self.isRecording, generation == self.recordingGeneration else { return }
            DiagLog.log("recording reached the %.0fs cap — stopping", Self.maxRecordingSeconds)
            self.hotkeyReleased()
        }
    }

    private static let maxRecordingSeconds: TimeInterval = 300
    private static let incrementalStartSeconds: TimeInterval = 8
    private static let incrementalTickSeconds: TimeInterval = 4

    private func beginIncrementalRecording(generation: Int) {
        discardIncrementalRecording()
        let incremental = IncrementalRecording(
            generation: generation,
            context: DictationContext.capture()
        )
        incrementalRecording = incremental
        scheduleIncrementalTick(incremental, after: Self.incrementalStartSeconds)
    }

    private func scheduleIncrementalTick(
        _ incremental: IncrementalRecording,
        after delay: TimeInterval
    ) {
        let work = DispatchWorkItem { [weak self, weak incremental] in
            guard let self, let incremental else { return }
            self.runIncrementalTick(incremental)
        }
        incremental.timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runIncrementalTick(_ incremental: IncrementalRecording) {
        guard incrementalRecording === incremental,
              isRecording,
              recordingGeneration == incremental.generation else { return }
        scheduleIncrementalTick(incremental, after: Self.incrementalTickSeconds)
        guard incremental.pass == nil, !incremental.failed else { return }

        recorder.snapshot { [weak self, weak incremental] samples in
            guard let self, let incremental,
                  self.incrementalRecording === incremental,
                  self.isRecording,
                  samples.count >= Int(Self.incrementalStartSeconds * AudioRecorder.sampleRate),
                  incremental.pass == nil,
                  !incremental.failed else { return }
            self.startIncrementalPass(incremental, samples: samples)
        }
    }

    private func startIncrementalPass(
        _ incremental: IncrementalRecording,
        samples: [Float]
    ) {
        guard let cut = AudioRecorder.incrementalCutPoint(
            in: samples,
            after: incremental.committedEnd
        ) else { return }

        let chunk = AudioRecorder.trimmingSilence(
            Array(samples[incremental.committedEnd..<cut])
        )
        let voice = AudioRecorder.voicedMetrics(of: chunk)
        guard voice.voicedSeconds >= Self.minVoicedSeconds else { return }

        let pauseBeforeChunk = incremental.nextPauseSeconds
        let pauseAfterChunk = AudioRecorder.incrementalPauseSeconds(in: samples, around: cut)
        let chunkSeconds = Double(chunk.count) / AudioRecorder.sampleRate
        incremental.pass = Task { [weak self, weak incremental] in
            guard let self, let incremental else { return }
            let startedAt = Date()
            do {
                let text = try await self.transcriber.transcribe(
                    samples: chunk,
                    lowEnergy: voice.voicedDBFS < Self.quietVoicedDBFS
                )
                guard !Task.isCancelled else {
                    incremental.pass = nil
                    return
                }
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                DiagLog.log("[diag] incremental chunk: audio=%.1fs decode=%dms outputBytes=%d",
                      chunkSeconds, elapsedMs, text.utf8.count)
                guard !text.isEmpty else {
                    incremental.failed = true
                    incremental.committedEnd = 0
                    incremental.committedText = ""
                    incremental.chunkCount = 0
                    self.cancelIncrementalCleanup(incremental)
                    incremental.cleanedCommittedText = ""
                    incremental.cleanedChunkCount = 0
                    incremental.chunkCleanupFailed = true
                    incremental.pass = nil
                    DiagLog.log("[diag] incremental chunk returned empty; full-pass fallback armed")
                    return
                }
                incremental.committedText = Transcriber.joinTranscriptParts(
                    incremental.committedText,
                    text,
                    pauseSeconds: incremental.nextPauseSeconds
                )
                incremental.committedEnd = cut
                incremental.chunkCount += 1
                incremental.nextPauseSeconds = pauseAfterChunk
                self.startIncrementalCleanup(
                    incremental,
                    chunkText: text,
                    pauseBeforeChunk: pauseBeforeChunk
                )
            } catch {
                guard !Task.isCancelled else {
                    incremental.pass = nil
                    return
                }
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                incremental.failed = true
                incremental.committedEnd = 0
                incremental.committedText = ""
                incremental.chunkCount = 0
                self.cancelIncrementalCleanup(incremental)
                incremental.cleanedCommittedText = ""
                incremental.cleanedChunkCount = 0
                incremental.chunkCleanupFailed = true
                DiagLog.log("[diag] incremental chunk failed after %dms (%@); full-pass fallback armed",
                      elapsedMs, error.localizedDescription)
            }
            incremental.pass = nil
        }
    }

    private func startIncrementalCleanup(
        _ incremental: IncrementalRecording,
        chunkText: String,
        pauseBeforeChunk: Double
    ) {
        guard incremental.context.cleanupEnabled else { return }
        let previousCleanup = incremental.cleanupTask
        let cleanupTask = Task { [weak self, weak incremental] in
            if let previousCleanup { await previousCleanup.value }
            guard let self, let incremental,
                  !Task.isCancelled,
                  !incremental.chunkCleanupFailed else { return }

            let context = incremental.context
            let composed = Self.composeTranscript(chunkText, context: context)
            let result = await self.cleanTranscriptResult(
                composed,
                ollamaModel: context.ollamaModel,
                profile: context.styleProfile
            )
            guard result.succeeded else {
                incremental.chunkCleanupFailed = true
                DiagLog.log("[diag] incremental cleanup returned input; full cleanup fallback armed")
                return
            }
            incremental.cleanedCommittedText = Transcriber.joinTranscriptParts(
                incremental.cleanedCommittedText,
                result.text,
                pauseSeconds: pauseBeforeChunk
            )
            incremental.cleanedChunkCount += 1
        }
        incremental.cleanupTask = cleanupTask
        incremental.cleanupTasks.append(cleanupTask)
    }

    private func cancelIncrementalCleanup(_ incremental: IncrementalRecording) {
        incremental.cleanupTasks.forEach { $0.cancel() }
        incremental.cleanupTasks.removeAll()
        incremental.cleanupTask = nil
    }

    private func discardIncrementalRecording() {
        if let incremental = incrementalRecording {
            incremental.timer?.cancel()
            incremental.pass?.cancel()
            cancelIncrementalCleanup(incremental)
            incremental.timer = nil
        }
        incrementalRecording = nil
    }

    // MARK: - Command mode (hold, speak an instruction, edit in place)

    private func commandKeyPressed() {
        guard modelLoaded, !isRecording else { return }
        if !AppleIntelligenceCleaner.isAvailable {
            Task { await OllamaCleaner.prewarm(model: Settings.ollamaCommandModel) }
        }
        recordingIsCommand = true
        hotkeyPressed()
    }

    private func commandKeyReleased() {
        guard recordingIsCommand else { return }
        hotkeyReleased()
    }

    /// The spoken instruction is in; grab whatever is selected in the
    /// frontmost app and run the edit. Ordered through the same injection
    /// queue as dictations so results never overtake each other.
    private func runCommand(instruction: String, seq: Int, hudGeneration: Int?) {
        TextInjector.copySelection { [weak self] selection in
            guard let self else { return }
            Task {
                do {
                    let result = try await CommandMode.run(instruction: instruction, selection: selection)
                    guard !result.isEmpty else {
                        self.finishDictation(seq, with: .skip)
                        self.dismissHud(hudGeneration)
                        self.finishProcessing()
                        return
                    }
                    self.recentTranscripts.insert(RecentDictation(text: result), at: 0)
                    if self.recentTranscripts.count > 5 { self.recentTranscripts.removeLast() }
                    self.settingsModel?.recentDictations = self.recentTranscripts
                    DictationHistory.record(result)
                    self.finishDictation(seq, with: .inject(result))
                    self.dismissHud(hudGeneration)
                    DiagLog.log("command mode applied (selection=%d chars, result=%d chars)",
                          selection?.count ?? 0, result.count)
                    self.finishProcessing()
                } catch {
                    self.finishDictation(seq, with: .skip)
                    self.dismissHud(hudGeneration)
                    self.playCue("Basso")
                    self.state = .failed(UserFacingIssue(
                        summary: "Couldn't apply the voice edit",
                        details: error.localizedDescription
                    ))
                    self.scheduleFailureRecovery()
                    self.finishProcessing()
                }
            }
        }
    }

    private func hotkeyReleased() {
        let releasedAt = Date()
        guard isRecording else { return }
        isRecording = false
        // The HUD stays up as a loading state until this dictation resolves;
        // the generation ties the eventual dismissHud to this dictation so a
        // newer press's HUD is never torn down by a stale completion.
        let generation = recordingGeneration
        // Queue capture stop before updating the HUD. This timestamp and
        // ordering include all release-side work in the latency metric and
        // let sample handoff start as soon as possible.
        // Whether this hold was a command must be latched here, at release:
        // the next press can flip the flag before the stop completion runs.
        let asCommand = recordingIsCommand
        recordingIsCommand = false
        let releaseContext = asCommand ? nil : DictationContext.capture()
        let incremental = asCommand ? nil : incrementalRecording
        incremental?.timer?.cancel()
        incremental?.timer = nil
        incrementalRecording = nil
        recorder.stop { [weak self] samples in
            guard let self else { return }
            if self.failedCaptureStarts.remove(generation) != nil {
                self.dismissHud(generation)
                return
            }
            self.process(samples: samples, releasedAt: releasedAt,
                         hudGeneration: generation, asCommand: asCommand,
                         incremental: incremental, releaseContext: releaseContext)
        }
        overlay.beginProcessing()
    }

    /// Hides the processing HUD for the dictation identified by `generation`
    /// — unless a newer press has taken the panel over (recording/warming
    /// always wins over processing). `nil` means no HUD was attached (menu
    /// retry).
    private func dismissHud(_ generation: Int?) {
        guard let generation, generation == recordingGeneration else { return }
        overlay.hide()
    }

    // An accidental hotkey brush captures a sliver of near-silence, and
    // Whisper hallucinates text for it ("Thank you.") that gets pasted into
    // the focused app. Gate on VOICED time before transcribing (whole-
    // capture RMS diluted real speech with every thinking pause).
    private static let minVoicedSeconds: TimeInterval = 0.3
    // Voiced but still too quiet to trust: transcribe, but let the
    // transcriber drop canonical hallucination phrases.
    private static let quietVoicedDBFS: Float = -40

    private func process(
        samples rawSamples: [Float],
        releasedAt: Date,
        hudGeneration: Int? = nil,
        asCommand: Bool = false,
        incremental: IncrementalRecording? = nil,
        releaseContext: DictationContext? = nil
    ) {
        let seq = injectionSeqCounter
        injectionSeqCounter += 1

        // Silent bookends are Whisper's main hallucination trigger and pure
        // wasted encode time.
        let samples = AudioRecorder.trimmingSilence(rawSamples)
        let duration = Double(samples.count) / AudioRecorder.sampleRate
        let voice = AudioRecorder.voicedMetrics(of: samples)
        guard voice.voicedSeconds >= Self.minVoicedSeconds else {
            DiagLog.log("skipping transcription: %.2fs voiced (of %.2fs) at %.0f dBFS is below the gate",
                  voice.voicedSeconds, duration, voice.voicedDBFS)
            finishDictation(seq, with: .skip)
            reportHeardNothing()
            dismissHud(hudGeneration)
            return
        }

        processingCount += 1
        if !isRecording { state = .processing }
        let context = releaseContext ?? DictationContext.capture()

        Task {
            do {
                let transcription = try await transcribeReleasedAudio(
                    rawSamples: rawSamples,
                    trimmedSamples: samples,
                    voice: voice,
                    incremental: asCommand ? nil : incremental
                )
                let raw = transcription.text
                guard !raw.isEmpty else {
                    // Muted mic, wrong input, silence: without a cue the
                    // user only finds out nothing was pasted much later.
                    DiagLog.log("transcription produced no text (%.1fs of audio)", duration)
                    finishDictation(seq, with: .skip)
                    reportHeardNothing()
                    dismissHud(hudGeneration)
                    finishProcessing()
                    return
                }

                // A command-mode utterance is an instruction, not text to
                // paste: corrections still apply (names get misheard the
                // same way), but no formatting, snippets, or cleanup.
                if asCommand {
                    let instruction = TranscriptCorrections.apply(
                        raw,
                        corrections: context.corrections
                    )
                    runCommand(instruction: instruction, seq: seq, hudGeneration: hudGeneration)
                    return
                }

                var usedTailOnlyCleanup = false
                var text: String?
                if let incremental,
                   let stats = transcription.incrementalStats {
                    let canAttemptTailOnly = IncrementalCleanupPlan.shouldCleanTailOnly(
                        incrementalTranscriptionSucceeded: true,
                        chunkCleanupActive: incremental.context.cleanupEnabled,
                        allCommittedChunksCleaned: true,
                        tailCleanupSucceeded: true,
                        capturedProfile: incremental.context.styleProfile,
                        releaseProfile: context.styleProfile,
                        cleanupEnabledAtRelease: context.cleanupEnabled
                    )
                    if canAttemptTailOnly {
                        if let cleanupTask = incremental.cleanupTask { await cleanupTask.value }
                        let allCommittedChunksCleaned = !incremental.chunkCleanupFailed
                            && incremental.cleanedChunkCount == stats.chunkCount
                        if allCommittedChunksCleaned,
                           let tailText = transcription.incrementalTailText {
                            let tail = Self.composeTranscript(tailText, context: incremental.context)
                            let cleanedTail: TranscriptCleanupResult
                            if tail.isEmpty {
                                cleanedTail = TranscriptCleanupResult(text: "", succeeded: true)
                            } else {
                                cleanedTail = await cleanTranscriptResult(
                                    tail,
                                    ollamaModel: incremental.context.ollamaModel,
                                    profile: incremental.context.styleProfile
                                )
                            }
                            if IncrementalCleanupPlan.shouldCleanTailOnly(
                                incrementalTranscriptionSucceeded: true,
                                chunkCleanupActive: incremental.context.cleanupEnabled,
                                allCommittedChunksCleaned: allCommittedChunksCleaned,
                                tailCleanupSucceeded: cleanedTail.succeeded,
                                capturedProfile: incremental.context.styleProfile,
                                releaseProfile: context.styleProfile,
                                cleanupEnabledAtRelease: context.cleanupEnabled
                            ) {
                                text = Transcriber.joinTranscriptParts(
                                    incremental.cleanedCommittedText,
                                    cleanedTail.text,
                                    pauseSeconds: incremental.nextPauseSeconds
                                )
                                usedTailOnlyCleanup = true
                            } else {
                                DiagLog.log("[diag] incremental tail cleanup returned input; full cleanup fallback armed")
                            }
                        }
                    } else {
                        cancelIncrementalCleanup(incremental)
                    }
                } else {
                    if let incremental { cancelIncrementalCleanup(incremental) }
                }

                let finalText: String
                if let text {
                    finalText = text
                } else {
                    // The release snapshot preserves the old all-at-once path
                    // whenever incremental cleanup cannot prove consistency.
                    let composed = Self.composeTranscript(raw, context: context)
                    if context.cleanupEnabled {
                        finalText = await cleanTranscript(
                            composed,
                            ollamaModel: context.ollamaModel,
                            profile: context.styleProfile
                        )
                    } else {
                        finalText = composed
                    }
                }

                // Keep the transcript reachable even if the paste goes
                // wrong — "Recent Dictations" in the menu and the settings
                // window can re-copy it. The daily history file keeps it
                // past this session.
                recentTranscripts.insert(RecentDictation(text: finalText), at: 0)
                if recentTranscripts.count > 5 { recentTranscripts.removeLast() }
                settingsModel?.recentDictations = recentTranscripts
                DictationHistory.record(finalText)

                finishDictation(seq, with: .inject(finalText))
                // The Cmd-V is posted synchronously inside inject (once the
                // queue reaches this dictation); the HUD's job ends here;
                // the paste-confirmation window runs on cues/banners alone.
                dismissHud(hudGeneration)

                // The metric the plan says to watch: hotkey-release → pasted text.
                let ms = Int(Date().timeIntervalSince(releasedAt) * 1000)
                lastLatencyMs = ms
                DiagLog.log("end-to-end %dms (%.1fs audio, cleanup=%@, outputBytes=%d)",
                      ms, duration, context.cleanupEnabled ? "on" : "off", finalText.utf8.count)
                if let stats = transcription.incrementalStats {
                    DiagLog.log("[diag] incremental transcription: chunks=%d committed=%.1fs tail=%.1fs",
                          stats.chunkCount, stats.committedSeconds, stats.tailSeconds)
                    DiagLog.log("[diag] incremental cleanup: chunks=%d tailOnly=%d",
                          stats.chunkCount, usedTailOnlyCleanup ? 1 : 0)
                }
                finishProcessing()
            } catch {
                processingCount -= 1
                finishDictation(seq, with: .skip)
                dismissHud(hudGeneration)
                // Don't discard the audio: the error may be transient, and
                // re-dictating a long passage from memory is the worst case.
                retrySamples.append(samples)
                if retrySamples.count > 3 { retrySamples.removeFirst() }
                playCue("Basso")
                state = .failed(UserFacingIssue(
                    summary: "Couldn't transcribe the recording",
                    details: "\(error.localizedDescription) The audio was kept. Use Retry Failed Dictation in the menu."
                ))
                scheduleFailureRecovery()
            }
        }
    }

    private func transcribeReleasedAudio(
        rawSamples: [Float],
        trimmedSamples: [Float],
        voice: (voicedSeconds: Double, voicedDBFS: Float),
        incremental: IncrementalRecording?
    ) async throws -> (
        text: String,
        incrementalStats: IncrementalStats?,
        incrementalTailText: String?
    ) {
        guard let incremental else {
            let text = try await transcriber.transcribe(
                samples: trimmedSamples,
                lowEnergy: voice.voicedDBFS < Self.quietVoicedDBFS
            )
            return (text, nil, nil)
        }

        if let pass = incremental.pass {
            let waitStartedAt = Date()
            await pass.value
            let waitMs = Int(Date().timeIntervalSince(waitStartedAt) * 1000)
            DiagLog.log("[diag] release waited %dms for active incremental pass", waitMs)
        }
        guard !incremental.failed,
              incremental.chunkCount > 0,
              incremental.committedEnd <= rawSamples.count else {
            let text = try await transcriber.transcribe(
                samples: trimmedSamples,
                lowEnergy: voice.voicedDBFS < Self.quietVoicedDBFS
            )
            return (text, nil, nil)
        }

        let tailRange = incremental.committedEnd..<rawSamples.count
        let tail = AudioRecorder.trimmingSilence(Array(rawSamples[tailRange]))
        let tailVoice = AudioRecorder.voicedMetrics(of: tail)
        do {
            let tailStartedAt = Date()
            let tailText: String
            if tail.isEmpty || tailVoice.voicedSeconds == 0 {
                tailText = ""
            } else {
                tailText = try await transcriber.transcribe(
                    samples: tail,
                    lowEnergy: tailVoice.voicedDBFS < Self.quietVoicedDBFS
                )
            }
            let tailMs = Int(Date().timeIntervalSince(tailStartedAt) * 1000)
            DiagLog.log("[diag] incremental tail: audio=%.1fs decode=%dms outputBytes=%d",
                  Double(tail.count) / AudioRecorder.sampleRate, tailMs, tailText.utf8.count)
            if tailText.isEmpty, tailVoice.voicedSeconds > 0 {
                throw IncrementalError.emptyVoicedTail
            }
            let text = Transcriber.joinTranscriptParts(
                incremental.committedText,
                tailText,
                pauseSeconds: incremental.nextPauseSeconds
            )
            let rate = AudioRecorder.sampleRate
            return (
                text,
                IncrementalStats(
                    chunkCount: incremental.chunkCount,
                    committedSeconds: Double(incremental.committedEnd) / rate,
                    tailSeconds: Double(rawSamples.count - incremental.committedEnd) / rate
                ),
                tailText
            )
        } catch {
            DiagLog.log("[diag] incremental tail failed (%@); retrying full utterance",
                  error.localizedDescription)
            let retryStartedAt = Date()
            let text = try await transcriber.transcribe(
                samples: trimmedSamples,
                lowEnergy: voice.voicedDBFS < Self.quietVoicedDBFS
            )
            let retryMs = Int(Date().timeIntervalSince(retryStartedAt) * 1000)
            DiagLog.log("[diag] full-utterance retry: audio=%.1fs decode=%dms outputBytes=%d",
                  Double(trimmedSamples.count) / AudioRecorder.sampleRate,
                  retryMs,
                  text.utf8.count)
            return (text, nil, nil)
        }
    }

    private static func composeTranscript(
        _ text: String,
        context: DictationContext
    ) -> String {
        Snippets.expand(
            VoiceFormatter.apply(
                TranscriptCorrections.apply(text, corrections: context.corrections)
            ),
            snippets: context.snippets
        )
    }

    /// Runs the enabled cleanup backend; any failure returns the input so a
    /// dictation is never lost to the cleanup stage. Apple's on-device model
    /// is preferred; Ollama is the fallback for systems without it.
    private func cleanTranscript(
        _ text: String,
        ollamaModel: String,
        profile: AppStyleProfile
    ) async -> String {
        (await cleanTranscriptResult(
            text,
            ollamaModel: ollamaModel,
            profile: profile
        )).text
    }

    /// Chunk cleanup needs the same soft-failure behavior as the release
    /// path, plus a signal that it is safe to combine independently cleaned
    /// parts. Validation distinguishes a legitimate no-op from a rejected
    /// response so clean chunks do not force a full cleanup retry at release.
    private func cleanTranscriptResult(
        _ text: String,
        ollamaModel: String,
        profile: AppStyleProfile
    ) async -> TranscriptCleanupResult {
        if AppleIntelligenceCleaner.isAvailable {
            do {
                return try await AppleIntelligenceCleaner.cleanResult(text, profile: profile)
            } catch {
                DiagLog.log("Apple Intelligence cleanup failed (%@), pasting uncleaned text",
                      error.localizedDescription)
                return TranscriptCleanupResult(text: text, succeeded: false)
            }
        }
        do {
            let result = try await OllamaCleaner.cleanResult(
                text,
                model: ollamaModel,
                profile: profile
            )
            settingsModel?.ollamaReachable = true
            return result
        } catch {
            // A transport error means the server is unavailable;
            // HTTP/decoding failures still prove it was reached.
            if let urlError = error as? URLError {
                if urlError.code != .cancelled {
                    settingsModel?.ollamaReachable = false
                }
            } else if !(error is CancellationError) {
                settingsModel?.ollamaReachable = true
            }
            DiagLog.log("Ollama cleanup failed (%@) — pasting raw transcript", error.localizedDescription)
            return TranscriptCleanupResult(text: text, succeeded: false)
        }
    }

    /// Records a dictation's outcome and drains everything now unblocked,
    /// in sequence order. The paste itself happens in the drain (never
    /// directly from `process`), so spoken order is always paste order,
    /// even when a later dictation clears cleanup before an earlier one.
    private func finishDictation(_ seq: Int, with outcome: DictationOutcome) {
        guard seq >= nextInjectionSeq else {
            // Resolved after the stall timeout already skipped past it.
            // Pasting minutes late into whatever has focus is worse than
            // not pasting; the text is in Recent Dictations.
            DiagLog.log("dictation #%d resolved after being skipped, not pasting", seq)
            return
        }
        injectionQueue[seq] = outcome
        drainInjectionQueue()
    }

    /// Pastes resolved dictations from the queue head, one per beat: firing
    /// two Cmd-Vs back-to-back replaces the clipboard before the frontmost
    /// app services the first, which pastes the second text twice and loses
    /// the first. Skip outcomes drain instantly. When later results are
    /// waiting behind an unresolved head (a hung transcription or cleanup
    /// call), a stall timeout eventually skips it so the queue never dams.
    private func drainInjectionQueue() {
        guard !injectionDrainPending else { return }
        headStallTimeout?.cancel()
        headStallTimeout = nil
        while let next = injectionQueue.removeValue(forKey: nextInjectionSeq) {
            nextInjectionSeq += 1
            guard case .inject(let text) = next else { continue }
            // The success cue waits for the injector's verdict — hearing
            // it while nothing was pasted is worse than hearing it late.
            TextInjector.inject(text) { [weak self] landed in
                guard let self else { return }
                if landed {
                    self.playCue("Bottle")
                    self.lastError = nil
                } else {
                    DiagLog.log("paste may not have landed — transcript kept in Recent Dictations")
                    self.playCue("Basso")
                    self.state = .failed(UserFacingIssue(
                        summary: "Paste may not have landed",
                        details: "The transcript is available under Recent Dictations in the menu."
                    ))
                    self.scheduleFailureRecovery()
                }
            }
            injectionDrainPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                self.injectionDrainPending = false
                self.drainInjectionQueue()
            }
            return
        }
        guard !injectionQueue.isEmpty else { return }
        let stalled = nextInjectionSeq
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.nextInjectionSeq == stalled, !self.injectionQueue.isEmpty else { return }
            DiagLog.log("dictation #%d never resolved, skipping it to unblock %d queued paste(s)",
                  stalled, self.injectionQueue.count)
            self.nextInjectionSeq += 1
            self.drainInjectionQueue()
        }
        headStallTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.injectionStallSeconds, execute: work)
    }

    /// A transcription task ended — return the UI to idle unless something
    /// else (a new recording, another in-flight transcription) is going on.
    private func finishProcessing() {
        processingCount -= 1
        guard processingCount == 0, !isRecording else { return }
        if case .failed = state { return } // let a failure message linger
        state = restingState
    }

    /// Nothing worth pasting was captured (too short, silence, or an empty
    /// transcript) — one cue/banner path for all of them.
    private func reportHeardNothing() {
        playCue("Basso")
        state = .failed(UserFacingIssue(
            summary: "Didn't hear any speech",
            details: "Check the selected microphone in Settings > Dictation."
        ))
        scheduleFailureRecovery()
    }

    /// Show a failure message briefly, then return to idle. The hotkey no
    /// longer gates on state, but without this the icon stayed ⚠️ forever.
    private func scheduleFailureRecovery() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, case .failed = self.state else { return }
            self.state = self.isRecording ? .recording : self.restingState
        }
    }

    private func playCue(_ name: String) {
        guard Settings.soundCues else { return }
        NSSound(named: name)?.play()
    }

    // MARK: - Menubar UI

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Loading model…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        lastErrorMenuItem = NSMenuItem(
            title: "View Last Error…",
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        lastErrorMenuItem.target = self
        lastErrorMenuItem.isHidden = true
        menu.addItem(lastErrorMenuItem)
        menu.addItem(.separator())

        // Safety nets: re-copy past transcripts, retry a failed one.
        recentMenuItem = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
        recentMenuItem.submenu = NSMenu()
        menu.addItem(recentMenuItem)

        retryMenuItem = NSMenuItem(
            title: "Retry Failed Dictation",
            action: #selector(retryFailedDictation),
            keyEquivalent: ""
        )
        retryMenuItem.target = self
        retryMenuItem.isHidden = true
        menu.addItem(retryMenuItem)

        let fixItem = NSMenuItem(
            title: "Fix Last Dictation…",
            action: #selector(fixLastDictation),
            keyEquivalent: ""
        )
        fixItem.target = self
        fixItem.toolTip = "Copy your corrected text, then pick this to teach LocalFlow the fix"
        menu.addItem(fixItem)

        let historyItem = NSMenuItem(
            title: "Open Dictation History",
            action: #selector(openDictationHistory),
            keyEquivalent: ""
        )
        historyItem.target = self
        historyItem.toolTip = "Daily Markdown log of every dictation, stored on this Mac"
        menu.addItem(historyItem)
        menu.addItem(.separator())

        // Quick actions: the settings people flip most often, applied through
        // the SAME live paths the settings window uses (SettingsModel setters
        // persist and fire the AppDelegate hooks). Checkmarks and the mic list
        // are refreshed in menuWillOpen.
        hotkeyMenuItem = NSMenuItem(title: "Hold to Talk", action: nil, keyEquivalent: "")
        let hotkeyMenu = NSMenu()
        for key in HotkeyManager.Key.allCases {
            let item = NSMenuItem(title: key.label, action: #selector(selectHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            hotkeyMenu.addItem(item)
        }
        hotkeyMenuItem.submenu = hotkeyMenu
        menu.addItem(hotkeyMenuItem)

        modelMenuItem = NSMenuItem(title: "Whisper Model", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        for entry in Settings.whisperModels {
            let item = NSMenuItem(title: entry.label, action: #selector(selectWhisperModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.name
            modelMenu.addItem(item)
        }
        modelMenuItem.submenu = modelMenu
        menu.addItem(modelMenuItem)

        // Rebuilt fresh each open so plugging/unplugging a mic is reflected.
        micMenuItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micMenuItem.submenu = NSMenu()
        menu.addItem(micMenuItem)
        menu.addItem(.separator())

        // Everything configurable lives in the settings window.
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Kept in the menu (not just Settings): it's the recovery path the
        // hotkey-failure banner points at.
        let permissionsItem = NSMenuItem(
            title: "Open Accessibility Settings…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(UpdateController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = updates
        menu.addItem(updateItem)

        let quitItem = NSMenuItem(title: "Quit LocalFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
        refreshStatusUI()
    }

    private func refreshStatusUI() {
        let symbol: String
        let statusText: String
        statusMenuItem?.toolTip = nil
        switch state {
        case .loadingModel:
            symbol = "arrow.down.circle"
            statusText = "Loading \(Settings.whisperModel)…"
        case .idle:
            symbol = "waveform"
            var text = "Ready"
            if let ms = lastLatencyMs { text += " · \(ms)ms" }
            statusText = text
            statusMenuItem?.toolTip = "Hold \(hotkey.key.label) to dictate"
        case .recording:
            symbol = "record.circle.fill"
            statusText = "Recording… release to transcribe"
        case .processing:
            symbol = "hourglass"
            statusText = "Transcribing…"
        case .failed(let issue):
            symbol = "exclamationmark.triangle"
            statusText = issue.menuSummary
            statusMenuItem?.toolTip = issue.details
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "LocalFlow")
        statusMenuItem?.title = statusText
    }

    // MARK: - Menu actions

    @objc private func openSettings() {
        settingsController.show()
    }

    @objc private func retryFailedDictation() {
        guard !retrySamples.isEmpty else { return }
        let pending = retrySamples
        retrySamples = []
        // Oldest first, so a multi-failure backlog pastes in spoken order
        // (the injection queue preserves this ordering downstream too).
        for samples in pending {
            process(samples: samples, releasedAt: Date())
        }
    }

    @objc private func copyRecentDictation(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Learns from an edit the user made by hand: they fix the pasted text
    /// in their app, copy it, and pick this. The clipboard is diffed against
    /// what LocalFlow actually pasted and the word-level swaps become
    /// correction rules, so the same mishearing stops recurring.
    @objc private func fixLastDictation() {
        guard let original = recentTranscripts.first?.text else {
            presentFixAlert(title: "Nothing to fix yet",
                            message: "Dictate something first, then correct it and try again.")
            return
        }
        guard let edited = NSPasteboard.general.string(forType: .string),
              !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            presentFixAlert(title: "Copy your corrected text first",
                            message: "Fix the text in your app, select it and press ⌘C, then pick this again.")
            return
        }
        guard edited != original else {
            presentFixAlert(title: "That's the same text",
                            message: "The clipboard matches the last dictation, so there's nothing to learn.")
            return
        }
        let proposals = DictationDiff.proposedCorrections(original: original, edited: edited)
        guard !proposals.isEmpty else {
            presentFixAlert(
                title: "No word fixes found",
                message: "The clipboard differs from the last dictation, but not by simple word swaps. "
                    + "reworded text isn't learned. Add the fix by hand in Settings if you want it."
            )
            return
        }

        let summary = proposals.map { "“\($0.wrong)” → \($0.right)" }.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = proposals.count == 1 ? "Learn this correction?" : "Learn these \(proposals.count) corrections?"
        alert.informativeText = summary
            + "\n\nThese will be applied to future dictations, and the corrected words "
            + "join the recognition vocabulary."
        alert.addButton(withTitle: "Learn")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var stored = Settings.corrections
        for proposal in proposals {
            stored.removeAll { $0.wrong.caseInsensitiveCompare(proposal.wrong) == .orderedSame }
            stored.append(proposal)
        }
        Settings.corrections = stored
        settingsModel?.corrections = stored.map { CorrectionPair(wrong: $0.wrong, right: $0.right) }
        DiagLog.log("learned %d correction(s) from an edited dictation", proposals.count)
    }

    private func presentFixAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Opens today's log when there is one, otherwise the folder (created
    /// on demand so the menu item is never a dead end).
    @objc private func openDictationHistory() {
        let today = DictationHistory.folder
            .appendingPathComponent(DictationHistory.fileName(for: Date()))
        if FileManager.default.fileExists(atPath: today.path) {
            NSWorkspace.shared.activateFileViewerSelecting([today])
            return
        }
        try? FileManager.default.createDirectory(
            at: DictationHistory.folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        NSWorkspace.shared.open(DictationHistory.folder)
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // Quick-action selections route through SettingsModel so persistence and
    // the live-apply hooks are shared with the settings window — no duplicated
    // apply logic.

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? HotkeyManager.Key else { return }
        settingsModel.hotkey = key
    }

    @objc private func selectWhisperModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        settingsModel.whisperModel = name
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        // A nil representedObject is the "System Default" row.
        settingsModel.micUID = sender.representedObject as? String
    }
}

// MARK: - Menu state (checkmarks reflect current settings when menu opens)

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if Settings.cleanupEnabled || Settings.commandModeEnabled { probeOllama() }
        rebuildRecentDictationsMenu()
        rebuildMicrophoneMenu()
        refreshQuickActionChecks()
        retryMenuItem.isHidden = retrySamples.isEmpty
        retryMenuItem.title = retrySamples.count > 1
            ? "Retry \(retrySamples.count) Failed Dictations"
            : "Retry Failed Dictation"
        if let lastError {
            lastErrorMenuItem.title = "View Last Error…"
            lastErrorMenuItem.toolTip = lastError.details
            lastErrorMenuItem.isHidden = false
        } else {
            lastErrorMenuItem.toolTip = nil
            lastErrorMenuItem.isHidden = true
        }
    }

    private func rebuildRecentDictationsMenu() {
        guard let submenu = recentMenuItem.submenu else { return }
        submenu.removeAllItems()
        recentMenuItem.isEnabled = !recentTranscripts.isEmpty
        for dictation in recentTranscripts {
            let text = dictation.text
            let title = text.count > 45 ? String(text.prefix(45)) + "…" : text
            let item = NSMenuItem(title: title, action: #selector(copyRecentDictation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = text
            item.toolTip = "Copy to clipboard"
            submenu.addItem(item)
        }
    }

    /// Checkmark the currently-selected hotkey and model. Both submenus are
    /// static, so only the `state` needs refreshing when the menu opens.
    private func refreshQuickActionChecks() {
        for item in hotkeyMenuItem.submenu?.items ?? [] {
            item.state = (item.representedObject as? HotkeyManager.Key) == settingsModel.hotkey ? .on : .off
        }
        for item in modelMenuItem.submenu?.items ?? [] {
            item.state = (item.representedObject as? String) == settingsModel.whisperModel ? .on : .off
        }
    }

    /// Rebuilt each open so device plug/unplug is reflected. Mirrors the
    /// settings picker: "System Default" (named when resolvable) plus every
    /// live input device, and a placeholder row for a saved-but-absent mic so
    /// its checkmark isn't orphaned.
    private func rebuildMicrophoneMenu() {
        guard let submenu = micMenuItem.submenu else { return }
        submenu.removeAllItems()
        let devices = AudioDevices.inputDevices()
        let currentUID = settingsModel.micUID

        let defaultName = AudioDevices.defaultInputDeviceID().flatMap { id in
            devices.first(where: { $0.id == id })?.name
        }
        let defaultItem = NSMenuItem(
            title: defaultName.map { "System Default (\($0))" } ?? "System Default",
            action: #selector(selectMicrophone(_:)), keyEquivalent: ""
        )
        defaultItem.target = self
        defaultItem.representedObject = nil
        defaultItem.state = currentUID == nil ? .on : .off
        submenu.addItem(defaultItem)

        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = currentUID == device.uid ? .on : .off
            submenu.addItem(item)
        }

        if let uid = currentUID, !devices.contains(where: { $0.uid == uid }) {
            let item = NSMenuItem(title: "Saved mic (not connected)", action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = uid
            item.state = .on
            submenu.addItem(item)
        }
    }

}
