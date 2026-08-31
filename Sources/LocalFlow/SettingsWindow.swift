import AppKit
import SwiftUI
import ServiceManagement

/// One finished dictation, kept in memory for this session only.
struct RecentDictation: Identifiable {
    let id = UUID()
    let text: String
    let at = Date()
}

/// One learned fix: what Whisper heard vs. what it should have written.
struct CorrectionPair: Identifiable, Equatable {
    let id = UUID()
    var wrong: String
    var right: String
}

/// One voice-triggered expansion: say the trigger, get the text.
struct SnippetPair: Identifiable, Equatable {
    let id = UUID()
    var trigger: String
    var expansion: String
}

// MARK: - Model

/// Observable mirror of Settings for the settings window. Writes persist
/// immediately; side effects that need the app's live objects (hotkey tap,
/// recorder, model load) run through hooks AppDelegate installs at launch.
@MainActor
final class SettingsModel: ObservableObject {
    var onHotkeyChange: ((HotkeyManager.Key) -> Void)?
    var onModelChange: (() -> Void)?
    var onMicChange: ((String?) -> Void)?
    var onCleanupToggle: (() -> Void)?
    var onKeepWarmChange: (() -> Void)?
    var onThemeChange: (() -> Void)?
    var onVocabularyChange: ((String) -> Void)?
    var onCorrectionsChange: (() -> Void)?
    var onCommandModeChange: (() -> Void)?
    var onAutomaticUpdatesChange: (() -> Void)?

    private let loginAgent = SMAppService.agent(plistName: "app.talix.localflow.plist")

    @Published var theme: HudTheme = HudTheme.current {
        didSet {
            guard oldValue != theme else { return }
            Settings.hudTheme = theme.rawValue
            onThemeChange?()
        }
    }

    @Published var hotkey: HotkeyManager.Key = Settings.hotkey {
        didSet {
            guard oldValue != hotkey else { return }
            Settings.hotkey = hotkey
            onHotkeyChange?(hotkey)
        }
    }

    @Published var whisperModel: String = Settings.whisperModel {
        didSet {
            guard oldValue != whisperModel else { return }
            Settings.whisperModel = whisperModel
            onModelChange?()
        }
    }

    @Published var micUID: String? = Settings.inputDeviceUID {
        didSet {
            guard oldValue != micUID else { return }
            Settings.inputDeviceUID = micUID
            onMicChange?(micUID)
        }
    }

    @Published var cleanupEnabled: Bool = Settings.cleanupEnabled {
        didSet {
            guard oldValue != cleanupEnabled else { return }
            Settings.cleanupEnabled = cleanupEnabled
            onCleanupToggle?()
        }
    }

    @Published var ollamaModel: String = Settings.ollamaModel {
        didSet {
            guard oldValue != ollamaModel else { return }
            Settings.ollamaModel = ollamaModel
        }
    }

    @Published var soundCues: Bool = Settings.soundCues {
        didSet { Settings.soundCues = soundCues }
    }

    @Published var saveHistory: Bool = Settings.saveHistory {
        didSet { Settings.saveHistory = saveHistory }
    }

    @Published var automaticUpdates: Bool = Settings.automaticUpdates {
        didSet {
            guard oldValue != automaticUpdates else { return }
            Settings.automaticUpdates = automaticUpdates
            onAutomaticUpdatesChange?()
        }
    }

    @Published var commandModeEnabled: Bool = Settings.commandModeEnabled {
        didSet {
            guard oldValue != commandModeEnabled else { return }
            Settings.commandModeEnabled = commandModeEnabled
            onCommandModeChange?()
        }
    }

    @Published var commandHotkey: HotkeyManager.Key = Settings.commandHotkey {
        didSet {
            guard oldValue != commandHotkey else { return }
            Settings.commandHotkey = commandHotkey
            onCommandModeChange?()
        }
    }

    @Published var ollamaCommandModel: String = Settings.ollamaCommandModel {
        didSet {
            guard oldValue != ollamaCommandModel else { return }
            Settings.ollamaCommandModel = ollamaCommandModel
        }
    }

    @Published var commandReasoning: ReasoningLevel = Settings.commandReasoning {
        didSet {
            guard oldValue != commandReasoning else { return }
            Settings.commandReasoning = commandReasoning
        }
    }

    @Published var snippets: [SnippetPair] = Settings.snippets.map {
        SnippetPair(trigger: $0.trigger, expansion: $0.expansion)
    } {
        didSet {
            guard oldValue != snippets else { return }
            Settings.snippets = snippets.map { ($0.trigger, $0.expansion) }
        }
    }

    func addSnippet(trigger: String, expansion: String) {
        let trigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let expansion = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty, !expansion.isEmpty else { return }
        snippets.removeAll { $0.trigger.caseInsensitiveCompare(trigger) == .orderedSame }
        snippets.append(SnippetPair(trigger: trigger, expansion: expansion))
    }

    func removeSnippet(_ id: UUID) {
        snippets.removeAll { $0.id == id }
    }

    @Published var customVocabulary: String = Settings.customVocabulary {
        didSet {
            guard oldValue != customVocabulary else { return }
            Settings.customVocabulary = customVocabulary
            onVocabularyChange?(customVocabulary)
        }
    }

    @Published var corrections: [CorrectionPair] = Settings.corrections.map {
        CorrectionPair(wrong: $0.wrong, right: $0.right)
    } {
        didSet {
            guard oldValue != corrections else { return }
            Settings.corrections = corrections.map { ($0.wrong, $0.right) }
            onCorrectionsChange?()
        }
    }

    func addCorrection(wrong: String, right: String) {
        let wrong = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wrong.isEmpty, !right.isEmpty else { return }
        // Re-teaching a word replaces the old fix instead of stacking a
        // duplicate rule.
        corrections.removeAll { $0.wrong.caseInsensitiveCompare(wrong) == .orderedSame }
        corrections.append(CorrectionPair(wrong: wrong, right: right))
    }

    func removeCorrection(_ id: UUID) {
        corrections.removeAll { $0.id == id }
    }

    @Published var keepMicWarm: Bool = Settings.keepMicWarm {
        didSet {
            guard oldValue != keepMicWarm else { return }
            Settings.keepMicWarm = keepMicWarm
            onKeepWarmChange?()
        }
    }

    private var suppressLoginSideEffect = false

    @Published var startAtLogin: Bool = false {
        didSet {
            guard oldValue != startAtLogin, !suppressLoginSideEffect else { return }
            do {
                if startAtLogin {
                    try loginAgent.register()
                } else {
                    try loginAgent.unregister()
                }
                Settings.loginItemSetupDone = true
            } catch {
                DiagLog.log("login item toggle failed: %@", error.localizedDescription)
                setStartAtLoginWithoutRegistering(loginAgent.status == .enabled)
            }
        }
    }

    @Published var ollamaReachable = true
    @Published var availableOllamaModels: [String] = []
    @Published var devices: [AudioInputDevice] = []
    @Published var systemDefaultName: String?
    @Published var recentDictations: [RecentDictation] = []
    @Published var lastIssue: UserFacingIssue?

    init() {
        // Seed from current status without re-registering the agent on every launch.
        setStartAtLoginWithoutRegistering(loginAgent.status == .enabled)
    }

    private func setStartAtLoginWithoutRegistering(_ enabled: Bool) {
        suppressLoginSideEffect = true
        startAtLogin = enabled
        suppressLoginSideEffect = false
    }

    func refresh() {
        devices = AudioDevices.inputDevices()
        if let defaultID = AudioDevices.defaultInputDeviceID() {
            systemDefaultName = devices.first(where: { $0.id == defaultID })?.name
        } else {
            systemDefaultName = nil
        }
        // Reflect changes made elsewhere (first-run auto-registration, etc.).
        let enabled = loginAgent.status == .enabled
        if startAtLogin != enabled { setStartAtLoginWithoutRegistering(enabled) }
        // Feed the model pickers whatever is installed right now; models
        // pulled while the window was closed appear on the next open.
        Task { [weak self] in
            let models = await OllamaCleaner.installedModels()
            self?.availableOllamaModels = models
        }
    }
}

// MARK: - Window controller

@MainActor
final class SettingsPanelController {
    private let model: SettingsModel
    private var window: NSWindow?
    private var moveObserver: NSObjectProtocol?
    private var hasBeenShown = false

    init(model: SettingsModel) {
        self.model = model
    }

    /// The window is built once and reused. It used to be destroyed on
    /// close (to stop the theme previews animating) and rebuilt on the next
    /// open, which is why it never came back where you left it: the
    /// restored frame was overwritten by SwiftUI's own sizing pass on the
    /// fresh window. The previews now stop on their own when the window
    /// isn't visible (see PreviewHudView), so the window can simply live on.
    func show() {
        model.refresh()
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let w = NSWindow(contentViewController: hosting)
            w.title = "LocalFlow Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isOpaque = false
            w.backgroundColor = .clear
            w.isReleasedWhenClosed = false
            window = w
            // Position is persisted explicitly rather than through
            // setFrameAutosaveName: the SwiftUI content resizes the window
            // after the frame is restored, and the autosave machinery hands
            // back a frame whose height no longer matches, moving it.
            moveObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: w, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    guard w.isVisible else { return }
                    Settings.settingsWindowOrigin = w.frame.origin
                }
            }
        }
        guard let window else { return }
        let isFirstOpen = !hasBeenShown
        hasBeenShown = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        restorePosition(of: window, centeringIfUnplaced: isFirstOpen)
    }

    /// Applies the saved origin after AppKit has finished sizing the window
    /// to its SwiftUI content; doing it earlier lets that layout pass move
    /// the window again. Off-screen origins (a display that is no longer
    /// attached) fall back to centering.
    private func restorePosition(of window: NSWindow, centeringIfUnplaced: Bool) {
        guard let origin = Settings.settingsWindowOrigin else {
            if centeringIfUnplaced { window.center() }
            return
        }
        DispatchQueue.main.async {
            let candidate = NSRect(origin: origin, size: window.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(candidate) }) {
                window.setFrameOrigin(origin)
            } else {
                window.center()
            }
        }
    }
}

// MARK: - Views

private struct SettingsWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General"
    case dictation = "Dictation"
    case cleanup = "Cleanup"
    case commandMode = "Command mode"
    case text = "Text"
    case history = "History"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .dictation: return "mic"
        case .cleanup: return "sparkles"
        case .commandMode: return "wand.and.stars"
        case .text: return "keyboard"
        case .history: return "clock"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var selectedPane: SettingsPane = .general
    @State private var newCorrectionWrong = ""
    @State private var newCorrectionRight = ""
    @State private var confirmingHistoryDeletion = false
    @State private var newSnippetTrigger = ""
    @State private var newSnippetExpansion = ""

    private var cleanupLabel: String {
        AppleIntelligenceCleaner.isAvailable
            ? "Clean up with Apple Intelligence (on-device)"
            : "Clean up with Ollama (\(model.ollamaModel))"
    }

    var body: some View {
        ZStack {
            SettingsWindowBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                paneSwitcher
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)

                Divider()
                if let issue = model.lastIssue {
                    lastIssueBanner(issue)
                    Divider()
                }
                selectedPaneView
            }
            .padding(.top, 28)
        }
        .frame(width: 700, height: 680)
    }

    @ViewBuilder
    private var paneSwitcher: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(SettingsPane.allCases) { pane in
                        if pane == selectedPane {
                            paneButton(for: pane)
                                .glassEffect(
                                    .clear.tint(Color.accentColor.opacity(0.18)).interactive(),
                                    in: Capsule()
                                )
                        } else {
                            paneButton(for: pane)
                        }
                    }
                }
                .padding(5)
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
            }
        } else {
            fallbackPaneSwitcher
        }
        #else
        fallbackPaneSwitcher
        #endif
    }

    private var fallbackPaneSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(SettingsPane.allCases) { pane in
                paneButton(for: pane)
                    .background(
                        pane == selectedPane ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
            }
        }
        .padding(5)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
    }

    private func paneButton(for pane: SettingsPane) -> some View {
        Button {
            selectedPane = pane
        } label: {
            VStack(spacing: 4) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 17, weight: .medium))
                Text(pane.rawValue)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(pane == selectedPane ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(pane.rawValue) settings")
        .accessibilityAddTraits(pane == selectedPane ? .isSelected : [])
    }

    private func lastIssueBanner(_ issue: UserFacingIssue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(issue.summary)
                        .font(.callout.weight(.semibold))
                    Text(issue.at, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(issue.details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .help(issue.details)
            }

            Spacer(minLength: 8)

            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString("\(issue.summary)\n\(issue.details)", forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy error details")
            .accessibilityLabel("Copy error details")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.07))
    }

    @ViewBuilder
    private var selectedPaneView: some View {
        switch selectedPane {
        case .general: generalPane
        case .dictation: dictationPane
        case .cleanup: cleanupPane
        case .commandMode: commandModePane
        case .text: textPane
        case .history: historyPane
        }
    }

    private var generalPane: some View {
        Form {
            Section {
                HelpRow(symbol: "mic.fill", title: "Dictate anywhere") {
                    Text("Hold **\(model.hotkey.label)**, speak, let go. The text is pasted where your cursor is. You can start the next dictation while the last one is still working.")
                }
                HelpRow(symbol: "text.badge.plus", title: "Say the formatting") {
                    Text("\u{201C}new line\u{201D}, \u{201C}new paragraph\u{201D}, \u{201C}bullet point\u{201D}, \u{201C}numbered list\u{201D}, \u{201C}next item\u{201D}, and \u{201C}thumbs up emoji\u{201D} (and ~45 other emoji names) become real formatting.")
                }
                HelpRow(symbol: "wand.and.stars", title: "Or don't") {
                    Text("Pause a beat after a finished sentence and you get a new paragraph. Counting off items (\u{201C}First\u{2026} Second\u{2026} Finally\u{2026}\u{201D}) becomes a numbered list on its own.")
                }
                if Settings.commandModeActive {
                    HelpRow(symbol: "pencil.and.outline", title: "Edit with your voice") {
                        Text("Select text, hold **\(model.commandHotkey.label)** and say what to change (\u{201C}make this shorter\u{201D}). With nothing selected, what you ask for is written at the cursor.")
                    }
                }
                HelpRow(symbol: "arrow.uturn.backward", title: "When it gets a word wrong") {
                    Text("Fix it in your app, copy it, then pick **Fix Last Dictation\u{2026}** in the menubar. LocalFlow learns the word and starts hearing it correctly.")
                }
                HelpRow(symbol: "lock.fill", title: "Everything stays here") {
                    Text("Speech never leaves this Mac. Transcription and cleanup both run locally, and the history is a plain folder you own.")
                }
            } header: {
                Text("How it works")
            }

            Section("Keyboard shortcut") {
                Picker("Hold to dictate", selection: $model.hotkey) {
                    ForEach(HotkeyManager.Key.allCases, id: \.self) { key in
                        Text(key.label).tag(key)
                    }
                }
            }

            Section("Startup") {
                Toggle("Start at login", isOn: $model.startAtLogin)
            }

            Section {
                Toggle("Install updates automatically", isOn: $model.automaticUpdates)
                    .disabled(!UpdateController.isSupported)
                if !UpdateController.isSupported {
                    Text("This is a locally built copy, so it can't self-update. Released builds check daily and install in the background.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Updates")
            } footer: {
                if UpdateController.isSupported {
                    Text("Checks once a day and installs the next time you quit. Updates are signed, and one that fails verification is discarded rather than installed. \u{201C}Check for Updates\u{2026}\u{201D} in the menubar looks right now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var dictationPane: some View {
        Form {
            Section("Transcription") {
                Picker("Whisper model", selection: $model.whisperModel) {
                    ForEach(Settings.whisperModels, id: \.name) { entry in
                        Text(entry.label).tag(entry.name)
                    }
                }

                Picker("Microphone", selection: $model.micUID) {
                    Text(systemDefaultMicrophoneLabel).tag(nil as String?)
                    ForEach(model.devices, id: \.uid) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
            }

            Section {
                Toggle("Keep microphone warm between dictations", isOn: $model.keepMicWarm)
                Toggle("Sound cues", isOn: $model.soundCues)
            } footer: {
                Text("Holds the mic open for 2 minutes after each dictation so the next press is live instantly. While warm, the mic-in-use indicator stays on and Bluetooth headphones stay in call-quality audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ThemeGallery(selection: $model.theme)
            } header: {
                Text("Listening theme")
            } footer: {
                Text("Shown while you hold the dictation key. Picking one plays a short preview on screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var cleanupPane: some View {
        Form {
            Section("Transcript cleanup") {
                Toggle(cleanupLabel, isOn: $model.cleanupEnabled)
                if model.cleanupEnabled && !AppleIntelligenceCleaner.isAvailable && !model.ollamaReachable {
                    Label {
                        Text("Ollama isn't running — raw transcripts will be pasted until it's back.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section {
                ollamaModelPicker("Cleanup model", selection: $model.ollamaModel)
            } header: {
                Text("Ollama")
            } footer: {
                Text("s1-mini is a small model built specifically for cleaning up dictation. Any other model works as a general cleaner.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// Installed Ollama models as a menu; falls back to a free text field
    /// when the server is unreachable so a model can still be named before
    /// Ollama is set up. A saved name that's no longer installed stays
    /// selectable rather than being silently swapped.
    @ViewBuilder
    private func ollamaModelPicker(_ title: String, selection: Binding<String>) -> some View {
        if model.availableOllamaModels.isEmpty {
            TextField(title, text: selection)
        } else {
            let names = model.availableOllamaModels.contains(selection.wrappedValue)
                ? model.availableOllamaModels
                : model.availableOllamaModels + [selection.wrappedValue]
            Picker(title, selection: selection) {
                ForEach(names, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
        }
    }

    private var commandModePane: some View {
        Form {
            Section {
                Toggle("Enable command mode", isOn: $model.commandModeEnabled)
                Picker("Hold to edit", selection: $model.commandHotkey) {
                    ForEach(HotkeyManager.Key.allCases, id: \.self) { key in
                        Text(key.label).tag(key)
                    }
                }
                .disabled(!model.commandModeEnabled)

                if model.commandModeEnabled, model.commandHotkey == model.hotkey {
                    Label {
                        Text("This is the same key as dictation. Pick a different one for command mode.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else if model.commandModeEnabled, !CommandMode.isAvailable {
                    Label {
                        Text("Command mode needs Apple Intelligence (System Settings) or a running Ollama server.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            } header: {
                Text("Command mode")
            } footer: {
                Text("Select text, hold the key and say what to do with it (\u{201C}make this shorter\u{201D}, \u{201C}turn this into bullets\u{201D}) and it's rewritten in place. With nothing selected, what you ask for is written at the cursor. Runs on-device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ollamaModelPicker("Command model", selection: $model.ollamaCommandModel)
                Picker("Reasoning effort", selection: $model.commandReasoning) {
                    ForEach(ReasoningLevel.allCases, id: \.self) { level in
                        Text(level.label).tag(level)
                    }
                }
            } header: {
                Text("Ollama")
            } footer: {
                Text("Reasoning effort only affects models with a thinking mode. qwen3 toggles it, gpt-oss takes a level, and the default gemma3:4b ignores it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var textPane: some View {
        Form {
            Section {
                ForEach(model.snippets) { snippet in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("“\(snippet.trigger)”")
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(snippet.expansion)
                            .lineLimit(3)
                        Spacer()
                        Button {
                            model.removeSnippet(snippet.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this snippet")
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Say this…", text: $newSnippetTrigger)
                    TextField("…to insert this", text: $newSnippetExpansion, axis: .vertical)
                        .lineLimit(2...5)
                    HStack {
                        Spacer()
                        Button("Add snippet") {
                            model.addSnippet(trigger: newSnippetTrigger, expansion: newSnippetExpansion)
                            newSnippetTrigger = ""
                            newSnippetExpansion = ""
                        }
                        .disabled(
                            newSnippetTrigger.trimmingCharacters(in: .whitespaces).isEmpty
                                || newSnippetExpansion.trimmingCharacters(in: .whitespaces).isEmpty
                        )
                    }
                }
            } header: {
                Text("Snippets")
            } footer: {
                Text("Voice shortcuts for text you type often. Say the trigger anywhere in a dictation (\u{201C}insert my signature\u{201D}) and it's replaced with the full text, verbatim.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Names, products, acronyms…", text: $model.customVocabulary, axis: .vertical)
                    .lineLimit(2...4)
            } header: {
                Text("Custom vocabulary")
            } footer: {
                Text("Comma-separated terms Whisper keeps mishearing (people, projects, jargon). They bias recognition on every dictation. Keep it short, a couple dozen terms at most; heavy bias can backfire.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(model.corrections) { pair in
                    HStack(spacing: 8) {
                        Text("“\(pair.wrong)”")
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(pair.right)
                        Spacer()
                        Button {
                            model.removeCorrection(pair.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this correction")
                    }
                }
                HStack(spacing: 8) {
                    TextField("Whisper wrote…", text: $newCorrectionWrong)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Should be…", text: $newCorrectionRight)
                    Button("Add") {
                        model.addCorrection(wrong: newCorrectionWrong, right: newCorrectionRight)
                        newCorrectionWrong = ""
                        newCorrectionRight = ""
                    }
                    .disabled(
                        newCorrectionWrong.trimmingCharacters(in: .whitespaces).isEmpty
                            || newCorrectionRight.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                }
            } header: {
                Text("Corrections")
            } footer: {
                Text("When a dictation comes out wrong, teach the fix here. It's applied to every future transcript, and the corrected word also joins the recognition vocabulary so Whisper starts hearing it right.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var historyPane: some View {
        Form {
            Section {
                if model.recentDictations.isEmpty {
                    Text("Nothing dictated yet this session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.recentDictations) { dictation in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(dictation.text)
                                    .lineLimit(4)
                                    .textSelection(.enabled)
                                Text(dictation.at, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                + Text(" ago")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button("Copy") {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.setString(dictation.text, forType: .string)
                            }
                        }
                    }
                }
            } header: {
                Text("Recent dictations")
            } footer: {
                Text("The last five this session. The full history lives in the daily log below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Save every dictation to a daily log", isOn: $model.saveHistory)
                HStack {
                    Button("Open history folder") {
                        try? FileManager.default.createDirectory(
                            at: DictationHistory.folder,
                            withIntermediateDirectories: true,
                            attributes: [.posixPermissions: 0o700]
                        )
                        NSWorkspace.shared.open(DictationHistory.folder)
                    }
                    Spacer()
                    Button("Delete all history…", role: .destructive) {
                        confirmingHistoryDeletion = true
                    }
                }
            } header: {
                Text("History")
            } footer: {
                Text("One Markdown file per day in Application Support, on this Mac only (not iCloud-synced). Nothing is deleted automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .confirmationDialog(
                "Delete all saved dictations?",
                isPresented: $confirmingHistoryDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete all history", role: .destructive) {
                    try? DictationHistory.deleteAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every daily log file is removed. This can't be undone.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var systemDefaultMicrophoneLabel: String {
        guard let systemDefaultName = model.systemDefaultName else { return "System default" }
        return "System default (\(systemDefaultName))"
    }
}

/// One line of the "How it works" section: an icon, a short title, and a
/// sentence of explanation.
struct HelpRow<Detail: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 1)
    }
}

struct ThemeGallery: View {
    @Binding var selection: HudTheme
    private let columns = [GridItem(.adaptive(minimum: 186), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(HudTheme.allCases, id: \.self) { theme in
                ThemeTile(theme: theme, selected: theme == selection) {
                    selection = theme
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ThemeTile: View {
    let theme: HudTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ThemePreview(theme: theme)
                    .frame(height: 58)
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.09, green: 0.10, blue: 0.14),
                                     Color(red: 0.05, green: 0.06, blue: 0.09)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(selected ? Color.accentColor : Color.primary.opacity(0.12),
                                    lineWidth: selected ? 2 : 1)
                    )
                Text(theme.label)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Hosts one theme renderer, self-driven by synthesized speech.
struct ThemePreview: NSViewRepresentable {
    let theme: HudTheme

    func makeNSView(context: Context) -> PreviewHudView {
        PreviewHudView(theme: theme)
    }

    func updateNSView(_ nsView: PreviewHudView, context: Context) {}

    static func dismantleNSView(_ nsView: PreviewHudView, coordinator: ()) {
        nsView.stopAnimating()
    }
}

final class PreviewHudView: NSView {
    override var isFlipped: Bool { true }

    private let renderer: HudRenderer
    private var time: CGFloat = 0
    private var timer: Timer?
    private var visibilityObservers: [NSObjectProtocol] = []

    init(theme: HudTheme) {
        renderer = theme.makeRenderer()
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        visibilityObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// The settings window outlives a close now, so "am I in a window" is no
    /// longer the right animation trigger: 16 renderers must not keep
    /// running at 30fps behind a closed window. Follow actual visibility.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        visibilityObservers.forEach(NotificationCenter.default.removeObserver)
        visibilityObservers = []
        guard let window else {
            stopAnimating()
            return
        }
        let center = NotificationCenter.default
        for name: NSNotification.Name in [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ] {
            let closing = name == NSWindow.willCloseNotification
            visibilityObservers.append(
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        // willClose fires while the window still reports
                        // itself visible, so treat it as "gone" outright.
                        self?.syncAnimation(forcedOff: closing)
                    }
                }
            )
        }
        syncAnimation(forcedOff: false)
    }

    private func syncAnimation(forcedOff: Bool) {
        let visible = !forcedOff
            && (window?.isVisible ?? false)
            && (window?.occlusionState.contains(.visible) ?? false)
        if visible { startAnimating() } else { stopAnimating() }
    }

    private func startAnimating() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time += 1.0 / 30.0
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 20, bounds.height > 10,
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t = Double(time)
        let level = SyntheticSpeech.level(at: t)
        let spectrum = SyntheticSpeech.spectrum(at: t, level: level)
        renderer.render(in: ctx, bounds: bounds, t: time, dt: 1.0 / 30.0,
                        level: CGFloat(level), spectrum: spectrum.map { CGFloat($0) })
    }
}
