import AppKit
import SwiftUI
import ServiceManagement

/// One finished dictation, kept in memory for this session only.
struct RecentDictation: Identifiable {
    let id = UUID()
    let text: String
    let at = Date()
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
    var onThemeChange: (() -> Void)?

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

    @Published var soundCues: Bool = Settings.soundCues {
        didSet { Settings.soundCues = soundCues }
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
                NSLog("LocalFlow: login item toggle failed: %@", error.localizedDescription)
            }
        }
    }

    @Published var ollamaReachable = true
    @Published var devices: [AudioInputDevice] = []
    @Published var systemDefaultName: String?
    @Published var recentDictations: [RecentDictation] = []

    init() {
        // Seed from current status without re-registering the agent on every launch.
        suppressLoginSideEffect = true
        startAtLogin = loginAgent.status == .enabled
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
        if startAtLogin != enabled { startAtLogin = enabled }
    }
}

// MARK: - Window controller

@MainActor
final class SettingsPanelController {
    private let model: SettingsModel
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    init(model: SettingsModel) {
        self.model = model
    }

    func show() {
        model.refresh()
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let w = NSWindow(contentViewController: hosting)
            w.title = "LocalFlow Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            // Drop the window on close so the 16 animating previews stop.
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: w, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.window = nil
                    if let observer = self.closeObserver {
                        NotificationCenter.default.removeObserver(observer)
                        self.closeObserver = nil
                    }
                }
            }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Views

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Hold to talk", selection: $model.hotkey) {
                    ForEach(HotkeyManager.Key.allCases, id: \.self) { key in
                        Text(key.label).tag(key)
                    }
                }
                Picker("Whisper model", selection: $model.whisperModel) {
                    ForEach(Settings.whisperModels, id: \.name) { entry in
                        Text(entry.label).tag(entry.name)
                    }
                }
                Picker("Microphone", selection: $model.micUID) {
                    Text(model.systemDefaultName.map { "System Default (\($0))" } ?? "System Default")
                        .tag(String?.none)
                    ForEach(model.devices, id: \.uid) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                    if let uid = model.micUID, !model.devices.contains(where: { $0.uid == uid }) {
                        Text("Saved mic (not connected)").tag(Optional(uid))
                    }
                }
            }

            Section("After transcribing") {
                Toggle("Clean up with Ollama (\(Settings.ollamaModel))", isOn: $model.cleanupEnabled)
                if model.cleanupEnabled && !model.ollamaReachable {
                    Text("Ollama isn't running — raw transcripts will be pasted until it's back.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Toggle("Sound cues", isOn: $model.soundCues)
                Toggle("Start at login", isOn: $model.startAtLogin)
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
                Text("The last five, kept in memory only — cleared when LocalFlow quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 660)
        .frame(minHeight: 560, idealHeight: 720)
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

    init(theme: HudTheme) {
        renderer = theme.makeRenderer()
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimating()
        } else {
            startAnimating()
        }
    }

    private func startAnimating() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.time += 1.0 / 30.0
            self.needsDisplay = true
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
