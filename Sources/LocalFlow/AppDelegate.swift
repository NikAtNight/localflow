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
    private var ollamaReachable = false
    private var lastLatencyMs: Int?

    // Recording and transcription are tracked separately from the UI `state`
    // so a new dictation can start while a previous one is still processing —
    // gating presses on `state == .idle` made the hotkey feel dead.
    private var isRecording = false
    private var processingCount = 0
    // Lets a stale async start-failure from an abandoned recording be
    // distinguished from the one currently in flight.
    private var recordingGeneration = 0
    // Same idea for model loads: switching models twice quickly must not
    // let the slower (older) load win after the newer one finished.
    private var modelLoadGeneration = 0
    private var modelRetryDelay: TimeInterval = 5

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildSettings()
        buildStatusItem()
        requestPermissions()
        startHotkey()
        loadModel()
        probeOllama()
        // Called on the audio thread; overlay.push hops to main internally.
        let overlay = self.overlay
        recorder.onLevel = { level in overlay.push(level: level) }
        recorder.onSpectrum = { bands in overlay.push(spectrum: bands) }
        // The "speak now" cue fires on the first real audio buffer, not on
        // engine start — a Bluetooth mic can take a second to deliver.
        recorder.onCaptureLive = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isRecording else { return }
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
        settingsModel.onMicChange = { [weak self] uid in self?.recorder.deviceUID = uid }
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
        guard isRecording else { return }
        NSLog("LocalFlow: %@ while recording — discarding the recording", reason)
        isRecording = false
        recordingGeneration += 1
        overlay.hide()
        recorder.stop { _ in }
        state = restingState
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
            NSLog("LocalFlow: registered login agent (relaunches after a crash)")
        } catch {
            NSLog("LocalFlow: login agent registration failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Permissions (the #1 friction point — surface issues clearly)

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                NSLog("LocalFlow: microphone access denied — grant it in System Settings → Privacy & Security → Microphone")
            }
        }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSLog("LocalFlow: Accessibility not yet granted — hotkey and paste need it (System Settings → Privacy & Security → Accessibility)")
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
        NSLog("LocalFlow: hotkey tap stopped delivering events — rebuilding it")
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
                NSLog("LocalFlow: hotkey tap active (%@)", self.hotkey.key.label)
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
        modelLoaded = false
        state = .loadingModel
        let model = Settings.whisperModel
        Task {
            do {
                try await transcriber.load(model: model)
                guard generation == modelLoadGeneration else { return } // superseded
                NSLog("LocalFlow: model %@ loaded — ready", model)
                modelRetryDelay = 5
                modelLoaded = true
                recomputeReadyState()
            } catch {
                guard generation == modelLoadGeneration else { return }
                NSLog("LocalFlow: model load failed: %@", error.localizedDescription)
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
        NSLog("LocalFlow: retrying model load in %.0fs", delay)
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
            ollamaReachable = await OllamaCleaner.isAvailable()
            settingsModel?.ollamaReachable = ollamaReachable
            refreshStatusUI()
        }
    }

    // MARK: - Push-to-talk pipeline

    private func hotkeyPressed() {
        // Gate only on the model and an active recording — never on the UI
        // state. Pressing while a previous dictation is still transcribing
        // (or after a transient mic error) must start a new recording.
        NSLog("LocalFlow: hotkey pressed (modelLoaded=%d recording=%d)", modelLoaded ? 1 : 0, isRecording ? 1 : 0)
        guard modelLoaded, !isRecording else {
            // The model recompiles for minutes after every binary change —
            // a press during that window must never be silently swallowed.
            if !modelLoaded { playCue("Basso") }
            return
        }
        // A denied mic yields an engine that happily records silence —
        // every dictation would "succeed" with nothing to show. Fail loudly.
        let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        if micAuth == .denied || micAuth == .restricted {
            playCue("Basso")
            state = .failed("Microphone access denied — enable it in System Settings → Privacy & Security → Microphone")
            scheduleFailureRecovery()
            return
        }
        isRecording = true
        recordingGeneration += 1
        let generation = recordingGeneration
        state = .recording
        overlay.show()
        recorder.start { [weak self] error in
            guard let self, generation == self.recordingGeneration else { return }
            if let error {
                if self.isRecording {
                    self.isRecording = false
                    self.overlay.hide()
                }
                self.playCue("Basso")
                self.state = .failed("Mic error: \(error.localizedDescription)")
                self.scheduleFailureRecovery()
            }
            // Success cue is handled by onCaptureLive — the first actual
            // audio buffer — not by engine start, which can precede flowing
            // audio by over a second on Bluetooth mics.
        }
        // Backstop against a hold that never ends (stuck key, pocket
        // dictation): cap the recording rather than run an open mic.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxRecordingSeconds) { [weak self] in
            guard let self, self.isRecording, generation == self.recordingGeneration else { return }
            NSLog("LocalFlow: recording reached the %.0fs cap — stopping", Self.maxRecordingSeconds)
            self.hotkeyReleased()
        }
    }

    private static let maxRecordingSeconds: TimeInterval = 300

    private func hotkeyReleased() {
        NSLog("LocalFlow: hotkey released (recording=%d)", isRecording ? 1 : 0)
        guard isRecording else { return }
        isRecording = false
        overlay.hide()
        let releasedAt = Date()
        recorder.stop { [weak self] samples in
            self?.process(samples: samples, releasedAt: releasedAt)
        }
    }

    private func process(samples: [Float], releasedAt: Date) {
        // Ignore taps shorter than ~0.3s of audio — accidental presses.
        guard samples.count > Int(AudioRecorder.sampleRate * 0.3) else {
            if !isRecording {
                if case .failed = state {
                    // let the banner linger; the recovery timer clears it
                } else {
                    state = restingState
                }
            }
            return
        }

        processingCount += 1
        if !isRecording { state = .processing }
        let cleanupWanted = Settings.cleanupEnabled
        let ollamaModel = Settings.ollamaModel

        Task {
            do {
                let raw = try await transcriber.transcribe(samples: samples)
                guard !raw.isEmpty else {
                    // Muted mic, wrong input, silence: without a cue the
                    // user only finds out nothing was pasted much later.
                    NSLog("LocalFlow: transcription produced no text (%.1fs of audio)",
                          Double(samples.count) / AudioRecorder.sampleRate)
                    playCue("Basso")
                    state = .failed("Heard nothing — is the right microphone selected?")
                    scheduleFailureRecovery()
                    finishProcessing()
                    return
                }

                var text = raw
                if cleanupWanted {
                    if await OllamaCleaner.isAvailable() {
                        ollamaReachable = true
                        do {
                            text = try await OllamaCleaner.clean(raw, model: ollamaModel)
                        } catch {
                            NSLog("LocalFlow: Ollama cleanup failed (%@) — pasting raw transcript", error.localizedDescription)
                        }
                    } else {
                        ollamaReachable = false
                        NSLog("LocalFlow: Ollama not reachable — pasting raw transcript")
                    }
                }

                // Keep the transcript reachable even if the paste goes
                // wrong — "Recent Dictations" in the menu and the settings
                // window can re-copy it.
                recentTranscripts.insert(RecentDictation(text: text), at: 0)
                if recentTranscripts.count > 5 { recentTranscripts.removeLast() }
                settingsModel?.recentDictations = recentTranscripts

                TextInjector.inject(text)
                playCue("Bottle")
                lastError = nil

                // The metric the plan says to watch: hotkey-release → pasted text.
                let ms = Int(Date().timeIntervalSince(releasedAt) * 1000)
                lastLatencyMs = ms
                NSLog("LocalFlow: end-to-end %dms (%.1fs audio, cleanup=%@) — \"%@\"",
                      ms, Double(samples.count) / AudioRecorder.sampleRate,
                      cleanupWanted ? "on" : "off", text)
                finishProcessing()
            } catch {
                processingCount -= 1
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
}

// MARK: - Menu state (checkmarks reflect current settings when menu opens)

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        probeOllama()
        rebuildRecentDictationsMenu()
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

}
