import AppKit
import AVFoundation
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum State {
        case loadingModel
        case idle
        case recording
        case processing
        case failed(String)
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
    private var retrySamples: [Float]?

    private let hotkey = HotkeyManager()
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let overlay = WaveformOverlay()

    private var state: State = .loadingModel {
        didSet {
            // Failure banners self-clear after 3s; keep the last one
            // reachable in the menu until a dictation succeeds again.
            if case .failed(let message) = state { lastError = (message, Date()) }
            refreshStatusUI()
        }
    }
    private var lastError: (message: String, at: Date)?
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
        if Settings.cleanupEnabled { probeOllama() }
        // Called on the audio thread; overlay.push hops to main internally.
        let overlay = self.overlay
        recorder.onLevel = { level in overlay.push(level: level) }
        recorder.onSpectrum = { bands in overlay.push(spectrum: bands) }
        // The "speak now" cue fires on the first real audio buffer, not on
        // engine start — a Bluetooth mic can take a second to deliver.
        recorder.onCaptureLive = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isRecording else { return }
                self.overlay.captureLive()
                self.playCue("Pop")
            }
        }
        // Capture died mid-recording and recovery failed — stop pretending
        // the mic is live.
        recorder.onRuntimeFailure = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.isRecording else { return }
                self.isRecording = false
                self.recordingGeneration += 1
                self.overlay.hide()
                self.playCue("Basso")
                self.state = .failed("Mic error: \(error.localizedDescription)")
                self.scheduleFailureRecovery()
            }
        }
        recorder.deviceUID = Settings.inputDeviceUID
        recorder.keepWarm = Settings.keepMicWarm
        observeSystemTransitions()
        registerLoginItemOnce()
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
            if Settings.cleanupEnabled { self?.probeOllama() }
        }
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
        if isRecording {
            DiagLog.log("%@ while recording — discarding the recording", reason)
            isRecording = false
            recordingGeneration += 1
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
                self.state = .failed("Hotkey blocked: remove + re-add LocalFlow in Accessibility settings (menu below) — retrying…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.attemptHotkeyStart()
                }
            }
        }
    }

    private func loadModel() {
        modelLoadGeneration += 1
        let generation = modelLoadGeneration
        state = .loadingModel
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
                    state = .failed("Couldn't load \(model) — still on previous model, retrying…")
                } else {
                    state = .failed("Model load failed: \(error.localizedDescription) — retrying…")
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
            state = .idle
        case .idle, .recording, .processing:
            break
        }
    }

    private func probeOllama() {
        Task {
            settingsModel?.ollamaReachable = await OllamaCleaner.isAvailable()
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
        // A denied mic yields an engine that happily records silence —
        // every dictation would "succeed" with nothing to show. Fail loudly.
        let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        if micAuth == .denied || micAuth == .restricted {
            // This early-out was silent in the logs once — presses that
            // "did nothing" with no trace. Never again.
            DiagLog.log("hotkey press refused: microphone authorization is %d", micAuth.rawValue)
            playCue("Basso")
            state = .failed("Microphone access denied — enable it in System Settings → Privacy & Security → Microphone")
            scheduleFailureRecovery()
            return
        }
        isRecording = true
        recordingGeneration += 1
        let generation = recordingGeneration
        // Enqueue hardware startup before doing menu/HUD work on the main
        // thread. A warm microphone can now begin delivering immediately
        // while the visual state is updated in parallel.
        recorder.start { [weak self] error in
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
                self.state = .failed("Mic error: \(error.localizedDescription)")
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
        recorder.stop { [weak self] samples in
            guard let self else { return }
            if self.failedCaptureStarts.remove(generation) != nil {
                self.dismissHud(generation)
                return
            }
            self.process(samples: samples, releasedAt: releasedAt, hudGeneration: generation)
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
    // the focused app — gate on duration and energy before transcribing.
    private static let minDictationSeconds: TimeInterval = 0.4
    private static let silenceFloorDBFS: Float = -55
    // Above the silence floor but still too quiet to trust: transcribe, but
    // let the transcriber drop canonical hallucination phrases.
    private static let quietAudioDBFS: Float = -40

    private func process(samples: [Float], releasedAt: Date, hudGeneration: Int? = nil) {
        let duration = Double(samples.count) / AudioRecorder.sampleRate
        let dbfs = AudioRecorder.rmsDBFS(of: samples)
        guard duration >= Self.minDictationSeconds, dbfs > Self.silenceFloorDBFS else {
            DiagLog.log("skipping transcription — %.2fs at %.0f dBFS is too short or silent",
                  duration, dbfs)
            reportHeardNothing()
            dismissHud(hudGeneration)
            return
        }

        processingCount += 1
        if !isRecording { state = .processing }
        let cleanupWanted = Settings.cleanupEnabled
        let ollamaModel = Settings.ollamaModel

        Task {
            do {
                let raw = try await transcriber.transcribe(samples: samples,
                                                           lowEnergy: dbfs < Self.quietAudioDBFS)
                guard !raw.isEmpty else {
                    // Muted mic, wrong input, silence: without a cue the
                    // user only finds out nothing was pasted much later.
                    DiagLog.log("transcription produced no text (%.1fs of audio)", duration)
                    reportHeardNothing()
                    dismissHud(hudGeneration)
                    finishProcessing()
                    return
                }

                var text = raw
                if cleanupWanted {
                    do {
                        text = try await OllamaCleaner.clean(raw, model: ollamaModel)
                        settingsModel?.ollamaReachable = true
                    } catch {
                        // A transport error means the server is unavailable;
                        // HTTP/decoding failures still prove it was reached.
                        settingsModel?.ollamaReachable = !(error is URLError)
                        DiagLog.log("Ollama cleanup failed (%@) — pasting raw transcript", error.localizedDescription)
                    }
                }

                // Keep the transcript reachable even if the paste goes
                // wrong — "Recent Dictations" in the menu and the settings
                // window can re-copy it.
                recentTranscripts.insert(RecentDictation(text: text), at: 0)
                if recentTranscripts.count > 5 { recentTranscripts.removeLast() }
                settingsModel?.recentDictations = recentTranscripts

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
                        self.state = .failed("Paste may not have landed — see Recent Dictations")
                        self.scheduleFailureRecovery()
                    }
                }
                // The Cmd-V is posted synchronously inside inject — the HUD's
                // job ends here; the 2.5s paste-confirmation window runs on
                // cues/banners alone.
                dismissHud(hudGeneration)

                // The metric the plan says to watch: hotkey-release → pasted text.
                let ms = Int(Date().timeIntervalSince(releasedAt) * 1000)
                lastLatencyMs = ms
                DiagLog.log("end-to-end %dms (%.1fs audio, cleanup=%@, outputBytes=%d)",
                      ms, duration, cleanupWanted ? "on" : "off", text.utf8.count)
                finishProcessing()
            } catch {
                processingCount -= 1
                dismissHud(hudGeneration)
                // Don't discard the audio: the error may be transient, and
                // re-dictating a long passage from memory is the worst case.
                retrySamples = samples
                playCue("Basso")
                state = .failed("Transcription failed: \(error.localizedDescription) — audio kept (see Retry in menu)")
                scheduleFailureRecovery()
            }
        }
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
        state = .failed("Heard nothing — is the right microphone selected?")
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

        lastErrorMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        lastErrorMenuItem.isEnabled = false
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

        let quitItem = NSMenuItem(title: "Quit LocalFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
        refreshStatusUI()
    }

    private func refreshStatusUI() {
        let symbol: String
        let statusText: String
        switch state {
        case .loadingModel:
            symbol = "arrow.down.circle"
            statusText = "Loading \(Settings.whisperModel)…"
        case .idle:
            symbol = "waveform"
            var text = "Ready — hold \(hotkey.key.label) to dictate"
            if let ms = lastLatencyMs { text += "  (last: \(ms)ms)" }
            statusText = text
        case .recording:
            symbol = "record.circle.fill"
            statusText = "Recording… release to transcribe"
        case .processing:
            symbol = "hourglass"
            statusText = "Transcribing…"
        case .failed(let message):
            symbol = "exclamationmark.triangle"
            statusText = message
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "LocalFlow")
        statusMenuItem?.title = statusText
    }

    // MARK: - Menu actions

    @objc private func openSettings() {
        settingsController.show()
    }

    @objc private func retryFailedDictation() {
        guard let samples = retrySamples else { return }
        retrySamples = nil
        process(samples: samples, releasedAt: Date())
    }

    @objc private func copyRecentDictation(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
        if Settings.cleanupEnabled { probeOllama() }
        rebuildRecentDictationsMenu()
        rebuildMicrophoneMenu()
        refreshQuickActionChecks()
        retryMenuItem.isHidden = retrySamples == nil
        if let lastError {
            let ago = RelativeDateTimeFormatter().localizedString(for: lastError.at, relativeTo: Date())
            lastErrorMenuItem.title = "Last error (\(ago)): \(lastError.message)"
            lastErrorMenuItem.isHidden = false
        } else {
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
