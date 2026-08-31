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

    // A command or dictation should resolve in seconds. Once a later result
    // is waiting, cancel a stalled head so it cannot retain audio or block
    // every later paste forever.
    private static let injectionStallSeconds: TimeInterval = 90
    private lazy var injectionCoordinator = InjectionCoordinator(
        stallTimeout: Self.injectionStallSeconds,
        onInject: { [weak self] text in
            self?.injectCompletedText(text)
        },
        onCancel: { [weak self] sequence, kind in
            self?.cancelInjectionOperation(sequence, kind: kind)
        },
        onProcessingCountChange: { [weak self] count in
            self?.processingCountDidChange(count)
        }
    )
    private var commandTasks: [Int: Task<Void, Never>] = [:]
    private var commandHudGenerations: [Int: Int] = [:]

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
    private let textModelPolicy = LocalTextModelPolicy.shared

    private struct PendingDictation {
        let sequence: Int
        let releasedAt: Date
        let hudGeneration: Int?
        let duration: Double
        let samples: [Float]
        let cleanupEnabled: Bool
    }

    private var pendingDictations: [Int: PendingDictation] = [:]
    private var nextDictationGeneration = 0
    private var activeDictationGeneration: Int?
    private var incrementalTimer: DispatchWorkItem?
    private lazy var dictationPipeline = DictationSessionPipeline(
        transcribe: { [weak self] request in
            guard let self else { throw CancellationError() }
            let samples = AudioRecorder.trimmingSilence(request.samples)
            guard !samples.isEmpty else { return "" }
            let voice = AudioRecorder.voicedMetrics(of: samples)
            return try await self.transcriber.transcribe(
                samples: samples,
                lowEnergy: voice.voicedDBFS < Self.quietVoicedDBFS
            )
        },
        cleanup: { [weak self] request in
            guard let self else {
                return TranscriptCleanupResult(text: request.text, succeeded: false)
            }
            do {
                return try await self.cleanTranscriptResult(
                    request.text,
                    ollamaModel: request.context.ollamaModel,
                    profile: request.context.styleProfile
                )
            } catch is CancellationError {
                return TranscriptCleanupResult(text: request.text, succeeded: false)
            } catch {
                DiagLog.log("local text cleanup failed (%@); using raw transcript",
                      error.localizedDescription)
                return TranscriptCleanupResult(text: request.text, succeeded: false)
            }
        },
        onOutcome: { [weak self] outcome in
            self?.handleDictationOutcome(outcome)
        }
    )

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
            let model = Settings.ollamaModel
            Task { await textModelPolicy.prewarm(model: model) }
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
                self.cancelActiveDictationSession()
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
            guard let self, Settings.cleanupEnabled else { return }
            self.probeOllama()
            let model = Settings.ollamaModel
            Task { await self.textModelPolicy.prewarm(model: model) }
        }
        settingsModel.onVocabularyChange = { [weak self] terms in
            guard let transcriber = self?.transcriber else { return }
            Task { await transcriber.setVocabulary(terms) }
        }
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
            cancelActiveDictationSession()
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
        Task {
            settingsModel?.ollamaReachable = await textModelPolicy.probeOllama()
            // Reachability feeds Settings.commandModeActive, and the command
            // tap may have been skipped (or left running) on stale state.
            startCommandHotkey()
        }
    }

    private func mirrorOllamaReachability() {
        let reachable: Bool
        switch textModelPolicy.ollamaReachability {
        case .unknown:
            return
        case .reachable:
            reachable = true
        case .unreachable:
            reachable = false
        }

        guard settingsModel.ollamaReachable != reachable else { return }
        settingsModel.ollamaReachable = reachable
        if !textModelPolicy.isAppleAvailable {
            startCommandHotkey()
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
        if Settings.cleanupEnabled && !recordingIsCommand {
            let model = Settings.ollamaModel
            Task { await textModelPolicy.prewarm(model: model) }
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
            cancelActiveDictationSession()
        } else {
            beginDictationSession()
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
                    self.cancelActiveDictationSession()
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

    private func captureDictationContext() -> DictationSessionContext {
        DictationSessionContext(
            cleanupEnabled: Settings.cleanupEnabled,
            styleProfile: AppStyleProfile.current(),
            corrections: Settings.corrections,
            snippets: Settings.snippets,
            ollamaModel: Settings.ollamaModel
        )
    }

    private func beginDictationSession() {
        cancelActiveDictationSession()
        let generation = nextDictationGeneration
        nextDictationGeneration += 1
        activeDictationGeneration = generation
        dictationPipeline.begin(
            generation: generation,
            context: captureDictationContext()
        )
        scheduleIncrementalTick(generation: generation, after: Self.incrementalStartSeconds)
    }

    private func scheduleIncrementalTick(generation: Int, after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            self?.runIncrementalTick(generation: generation)
        }
        incrementalTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runIncrementalTick(generation: Int) {
        guard activeDictationGeneration == generation, isRecording else { return }
        scheduleIncrementalTick(generation: generation, after: Self.incrementalTickSeconds)
        guard dictationPipeline.canAcceptIncrementalChunk(generation: generation) else { return }

        recorder.snapshot { [weak self] samples in
            guard let self,
                  self.activeDictationGeneration == generation,
                  self.isRecording,
                  samples.count >= Int(Self.incrementalStartSeconds * AudioRecorder.sampleRate),
                  self.dictationPipeline.canAcceptIncrementalChunk(generation: generation) else { return }
            let start = self.dictationPipeline.incrementalSampleEnd(generation: generation) ?? 0
            guard let cut = AudioRecorder.incrementalCutPoint(in: samples, after: start) else { return }
            let chunk = AudioRecorder.trimmingSilence(Array(samples[start..<cut]))
            let voice = AudioRecorder.voicedMetrics(of: chunk)
            guard voice.voicedSeconds >= Self.minVoicedSeconds else { return }
            let pause = AudioRecorder.incrementalPauseSeconds(in: samples, around: cut)
            self.dictationPipeline.processIncrementalChunk(
                generation: generation,
                samples: chunk,
                pauseSecondsAfterChunk: pause,
                sourceEndIndex: cut
            )
        }
    }

    private func cancelActiveDictationSession() {
        incrementalTimer?.cancel()
        incrementalTimer = nil
        guard let generation = activeDictationGeneration else { return }
        activeDictationGeneration = nil
        dictationPipeline.cancel(generation: generation)
    }

    // MARK: - Command mode (hold, speak an instruction, edit in place)

    private func commandKeyPressed() {
        guard modelLoaded, !isRecording else { return }
        let model = Settings.ollamaCommandModel
        Task { await textModelPolicy.prewarm(model: model) }
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
        guard injectionCoordinator.isPending(seq) else { return }
        TextInjector.copySelection { [weak self] selection in
            guard let self, self.injectionCoordinator.isPending(seq) else { return }
            let task = Task {
                defer { self.mirrorOllamaReachability() }
                do {
                    let result = try await CommandMode.run(instruction: instruction, selection: selection)
                    guard self.injectionCoordinator.isPending(seq) else { return }
                    guard !result.isEmpty else {
                        self.completeCommand(seq, with: .skip)
                        self.dismissHud(hudGeneration)
                        return
                    }
                    self.recentTranscripts.insert(RecentDictation(text: result), at: 0)
                    if self.recentTranscripts.count > 5 { self.recentTranscripts.removeLast() }
                    self.settingsModel?.recentDictations = self.recentTranscripts
                    DictationHistory.record(result)
                    self.completeCommand(seq, with: .inject(result))
                    self.dismissHud(hudGeneration)
                    DiagLog.log("command mode applied (selection=%d chars, result=%d chars)",
                          selection?.count ?? 0, result.count)
                } catch {
                    guard self.injectionCoordinator.isPending(seq) else { return }
                    self.completeCommand(seq, with: .skip)
                    self.dismissHud(hudGeneration)
                    self.playCue("Basso")
                    self.state = .failed(UserFacingIssue(
                        summary: "Couldn't apply the voice edit",
                        details: error.localizedDescription
                    ))
                    self.scheduleFailureRecovery()
                }
            }
            self.commandTasks[seq] = task
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
        let dictationGeneration = asCommand ? nil : activeDictationGeneration
        activeDictationGeneration = nil
        incrementalTimer?.cancel()
        incrementalTimer = nil
        recorder.stop { [weak self] samples in
            guard let self else { return }
            if self.failedCaptureStarts.remove(generation) != nil {
                if let dictationGeneration {
                    self.dictationPipeline.cancel(generation: dictationGeneration)
                }
                self.dismissHud(generation)
                return
            }
            self.process(samples: samples, releasedAt: releasedAt,
                         hudGeneration: generation, asCommand: asCommand,
                         dictationGeneration: dictationGeneration)
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
        dictationGeneration: Int? = nil
    ) {
        // Silent bookends are Whisper's main hallucination trigger and pure
        // wasted encode time.
        let samples = AudioRecorder.trimmingSilence(rawSamples)
        let duration = Double(samples.count) / AudioRecorder.sampleRate
        let voice = AudioRecorder.voicedMetrics(of: samples)
        guard voice.voicedSeconds >= Self.minVoicedSeconds else {
            DiagLog.log("skipping transcription: %.2fs voiced (of %.2fs) at %.0f dBFS is below the gate",
                  voice.voicedSeconds, duration, voice.voicedDBFS)
            if let dictationGeneration {
                dictationPipeline.cancel(generation: dictationGeneration)
            }
            reportHeardNothing()
            dismissHud(hudGeneration)
            return
        }

        if asCommand {
            let seq = injectionCoordinator.begin(kind: .command)
            if let hudGeneration { commandHudGenerations[seq] = hudGeneration }
            let context = captureDictationContext()
            let task = Task {
                do {
                    let raw = try await transcriber.transcribe(
                        samples: samples,
                        lowEnergy: voice.voicedDBFS < Self.quietVoicedDBFS
                    )
                    guard self.injectionCoordinator.isPending(seq) else { return }
                    guard !raw.isEmpty else {
                        self.completeCommand(seq, with: .skip)
                        self.reportHeardNothing()
                        self.dismissHud(hudGeneration)
                        return
                    }
                    let instruction = TranscriptCorrections.apply(
                        raw,
                        corrections: context.corrections
                    )
                    self.runCommand(instruction: instruction, seq: seq, hudGeneration: hudGeneration)
                } catch {
                    guard self.injectionCoordinator.isPending(seq) else { return }
                    self.completeCommand(seq, with: .skip)
                    self.dismissHud(hudGeneration)
                    self.playCue("Basso")
                    self.state = .failed(UserFacingIssue(
                        summary: "Couldn't transcribe the command",
                        details: error.localizedDescription
                    ))
                    self.scheduleFailureRecovery()
                }
            }
            commandTasks[seq] = task
            return
        }

        let seq = injectionCoordinator.begin(kind: .dictation)
        let generation: Int
        if let dictationGeneration {
            generation = dictationGeneration
        } else {
            generation = nextDictationGeneration
            nextDictationGeneration += 1
            dictationPipeline.begin(
                generation: generation,
                context: captureDictationContext()
            )
        }
        pendingDictations[generation] = PendingDictation(
            sequence: seq,
            releasedAt: releasedAt,
            hudGeneration: hudGeneration,
            duration: duration,
            samples: samples,
            cleanupEnabled: Settings.cleanupEnabled
        )
        dictationPipeline.release(generation: generation, fullSamples: rawSamples)
    }

    private func handleDictationOutcome(_ outcome: DictationSessionOutcome) {
        let generation: Int
        switch outcome {
        case .finalTranscript(let value, _),
             .emptyTranscript(let value),
             .failed(let value, _):
            generation = value
        }
        guard let pending = pendingDictations.removeValue(forKey: generation) else { return }

        switch outcome {
        case .finalTranscript(_, let text):
            recentTranscripts.insert(RecentDictation(text: text), at: 0)
            if recentTranscripts.count > 5 { recentTranscripts.removeLast() }
            settingsModel?.recentDictations = recentTranscripts
            DictationHistory.record(text)
            injectionCoordinator.complete(pending.sequence, with: .inject(text))
            dismissHud(pending.hudGeneration)

            let ms = Int(Date().timeIntervalSince(pending.releasedAt) * 1000)
            lastLatencyMs = ms
            DiagLog.log(
                "end-to-end %dms (%.1fs audio, cleanup=%@, outputBytes=%d)",
                ms,
                pending.duration,
                pending.cleanupEnabled ? "on" : "off",
                text.utf8.count
            )

        case .emptyTranscript:
            DiagLog.log("transcription produced no text (%.1fs of audio)", pending.duration)
            injectionCoordinator.complete(pending.sequence, with: .skip)
            reportHeardNothing()
            dismissHud(pending.hudGeneration)

        case .failed(_, let message):
            injectionCoordinator.complete(pending.sequence, with: .skip)
            dismissHud(pending.hudGeneration)
            retrySamples.append(pending.samples)
            if retrySamples.count > 3 { retrySamples.removeFirst() }
            playCue("Basso")
            state = .failed(UserFacingIssue(
                summary: "Couldn't transcribe the recording",
                details: "\(message) The audio was kept. Use Retry Failed Dictation in the menu."
            ))
            scheduleFailureRecovery()
        }
    }

    /// Cleanup is a soft-failure boundary. Returning the original transcript
    /// keeps a local model or server error from losing the dictation.
    private func cleanTranscriptResult(
        _ text: String,
        ollamaModel: String,
        profile: AppStyleProfile
    ) async throws -> TranscriptCleanupResult {
        let result = try await textModelPolicy.cleanup(
            text,
            model: ollamaModel,
            profile: profile
        )
        mirrorOllamaReachability()
        if !result.succeeded {
            let reachability: String
            switch textModelPolicy.ollamaReachability {
            case .unknown: reachability = "unknown"
            case .reachable: reachability = "reachable"
            case .unreachable: reachability = "unreachable"
            }
            DiagLog.log(
                "local text cleanup returned no usable edit (ollama=%@); using raw transcript",
                reachability
            )
        }
        return result
    }

    private func completeCommand(_ sequence: Int, with outcome: InjectionCoordinator.Outcome) {
        commandTasks.removeValue(forKey: sequence)
        commandHudGenerations.removeValue(forKey: sequence)
        injectionCoordinator.complete(sequence, with: outcome)
    }

    private func cancelInjectionOperation(
        _ sequence: Int,
        kind: InjectionCoordinator.OperationKind
    ) {
        switch kind {
        case .command:
            commandTasks.removeValue(forKey: sequence)?.cancel()
            let hudGeneration = commandHudGenerations.removeValue(forKey: sequence)
            dismissHud(hudGeneration)
        case .dictation:
            guard let entry = pendingDictations.first(where: { $0.value.sequence == sequence }) else {
                break
            }
            pendingDictations.removeValue(forKey: entry.key)
            dictationPipeline.cancel(generation: entry.key)
            dismissHud(entry.value.hudGeneration)
        }
        DiagLog.log("%@ #%d stalled; cancelled to unblock later output",
              kind == .command ? "command" : "dictation", sequence)
    }

    private func injectCompletedText(_ text: String) {
        // The success cue waits for the injector's verdict. Hearing it while
        // nothing was pasted is worse than hearing it late.
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
    }

    private func processingCountDidChange(_ count: Int) {
        let increased = count > processingCount
        processingCount = count
        guard !isRecording else { return }
        if increased {
            state = .processing
        } else if count == 0 {
            if case .failed = state { return }
            state = restingState
        }
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
        // the same SettingsModel entry point as the settings window. Checkmarks
        // and the mic list are refreshed in menuWillOpen.
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
        settingsModel.corrections = stored.map { CorrectionPair(wrong: $0.wrong, right: $0.right) }
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

    // Quick-action selections name the menu as their source while sharing
    // persistence and live effects with the settings window.

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? HotkeyManager.Key else { return }
        settingsModel.apply(.hotkey(key), from: .menu)
    }

    @objc private func selectWhisperModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        settingsModel.apply(.whisperModel(name), from: .menu)
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        // A nil representedObject is the "System Default" row.
        settingsModel.apply(.microphone(sender.representedObject as? String), from: .menu)
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
