import Foundation

/// UserDefaults-backed app settings.
enum Settings {
    // A computed accessor avoids storing Foundation's non-Sendable singleton
    // as global state; UserDefaults itself provides synchronized access.
    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let hotkey = "hotkey"
        static let whisperModel = "whisperModel"
        static let cleanupEnabled = "cleanupEnabled"
        static let ollamaModel = "ollamaModel"
        static let soundCues = "soundCues"
        static let keepMicWarm = "keepMicWarm"
        static let inputDeviceUID = "inputDeviceUID"
        static let customVocabulary = "customVocabulary"
        static let corrections = "corrections"
        static let saveHistory = "saveHistory"
        static let commandHotkey = "commandHotkey"
        static let commandModeEnabled = "commandModeEnabled"
        static let snippets = "snippets"
        static let automaticUpdates = "automaticUpdates"
        static let loginItemSetupDone = "loginItemSetupDone"
        static let hudTheme = "hudTheme"
        static let hudOrigin = "hudOrigin"
        static let settingsWindowOrigin = "settingsWindowOrigin"
    }

    /// Whisper models available in the argmaxinc/whisperkit-coreml registry,
    /// ordered from development-speed models to the best dictation models.
    /// Large v3 Turbo is the default: on Apple silicon it decodes fast
    /// enough for dictation and is the single biggest accuracy lever.
    static let whisperModels: [(name: String, label: String)] = [
        ("openai_whisper-tiny.en", "Tiny English (development only)"),
        ("openai_whisper-base.en", "Base English (fast, lower accuracy)"),
        ("openai_whisper-small.en", "Small English (fastest useful)"),
        ("openai_whisper-large-v3-v20240930_626MB", "Large v3 626 MB (compact, high accuracy)"),
        ("openai_whisper-large-v3-v20240930_turbo", "Large v3 Turbo (best accuracy, default)"),
    ]

    static var hotkey: HotkeyManager.Key {
        get {
            if let raw = defaults.string(forKey: Key.hotkey),
               let key = HotkeyManager.Key(rawValue: raw) {
                return key
            }
            return .rightOption
        }
        set { defaults.set(newValue.rawValue, forKey: Key.hotkey) }
    }

    static var whisperModel: String {
        get { defaults.string(forKey: Key.whisperModel) ?? "openai_whisper-large-v3-v20240930_turbo" }
        set { defaults.set(newValue, forKey: Key.whisperModel) }
    }

    /// Comma-separated names and jargon (people, products, acronyms) to
    /// bias Whisper's decoder toward. Empty = no biasing.
    static var customVocabulary: String {
        get { defaults.string(forKey: Key.customVocabulary) ?? "" }
        set { defaults.set(newValue, forKey: Key.customVocabulary) }
    }

    /// User-taught fixes for words Whisper keeps getting wrong: what it
    /// heard paired with what it should have written. Stored as
    /// tab-separated "wrong\tright" strings.
    static var corrections: [(wrong: String, right: String)] {
        get {
            (defaults.stringArray(forKey: Key.corrections) ?? []).compactMap { entry in
                let parts = entry.components(separatedBy: "\t")
                guard parts.count == 2 else { return nil }
                return (parts[0], parts[1])
            }
        }
        set { defaults.set(newValue.map { "\($0.wrong)\t\($0.right)" }, forKey: Key.corrections) }
    }

    /// The recognition-bias vocabulary Whisper actually receives: the
    /// free-form custom terms plus every correction's right-hand side. A
    /// word the user had to fix is by definition a word worth biasing toward.
    static var effectiveVocabulary: String {
        let base = customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = corrections.map(\.right)
        return ((base.isEmpty ? [] : [base]) + corrected).joined(separator: ", ")
    }

    static var cleanupEnabled: Bool {
        get { defaults.bool(forKey: Key.cleanupEnabled) }
        set { defaults.set(newValue, forKey: Key.cleanupEnabled) }
    }

    static var ollamaModel: String {
        get { defaults.string(forKey: Key.ollamaModel) ?? "gemma3:4b" }
        set { defaults.set(newValue, forKey: Key.ollamaModel) }
    }

    /// Hold-to-edit key for command mode. Must differ from `hotkey`;
    /// `commandModeActive` enforces that.
    static var commandHotkey: HotkeyManager.Key {
        get {
            if let raw = defaults.string(forKey: Key.commandHotkey),
               let key = HotkeyManager.Key(rawValue: raw) {
                return key
            }
            return .rightOption
        }
        set { defaults.set(newValue.rawValue, forKey: Key.commandHotkey) }
    }

    static var commandModeEnabled: Bool {
        get { defaults.object(forKey: Key.commandModeEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.commandModeEnabled) }
    }

    /// Command mode only runs when it's enabled, its key doesn't collide
    /// with the dictation key, and the on-device model can actually serve it.
    static var commandModeActive: Bool {
        commandModeEnabled && commandHotkey != hotkey && CommandMode.isAvailable
    }

    /// Voice-triggered text expansions, stored as "trigger\texpansion"
    /// (newlines inside an expansion are escaped as \n).
    static var snippets: [(trigger: String, expansion: String)] {
        get {
            (defaults.stringArray(forKey: Key.snippets) ?? []).compactMap { entry in
                let parts = entry.components(separatedBy: "\t")
                guard parts.count == 2 else { return nil }
                return (parts[0], parts[1].replacingOccurrences(of: "\\n", with: "\n"))
            }
        }
        set {
            defaults.set(
                newValue.map { "\($0.trigger)\t\($0.expansion.replacingOccurrences(of: "\n", with: "\\n"))" },
                forKey: Key.snippets
            )
        }
    }

    /// Check for and install new versions in the background. Sparkle keeps
    /// its own copy of this in SUEnableAutomaticChecks; this is the value
    /// the Settings toggle reads and writes.
    static var automaticUpdates: Bool {
        get { defaults.object(forKey: Key.automaticUpdates) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.automaticUpdates) }
    }

    /// Append every dictation to the daily Markdown log (see
    /// DictationHistory). On by default: it stays on this Mac.
    static var saveHistory: Bool {
        get { defaults.object(forKey: Key.saveHistory) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.saveHistory) }
    }

    static var soundCues: Bool {
        get { defaults.object(forKey: Key.soundCues) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.soundCues) }
    }

    /// Keep the capture session open for a while after each dictation so the
    /// next press is live immediately (a cold Bluetooth mic takes ~2s to
    /// wake). Costs: the mic-in-use indicator stays on through the window,
    /// and Bluetooth headphones stay in call-quality audio until it expires.
    static var keepMicWarm: Bool {
        get { defaults.object(forKey: Key.keepMicWarm) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.keepMicWarm) }
    }

    /// CoreAudio device UID of the microphone to record from; nil = system default.
    static var inputDeviceUID: String? {
        get { defaults.string(forKey: Key.inputDeviceUID) }
        set { defaults.set(newValue, forKey: Key.inputDeviceUID) }
    }

    /// Screen origin (global bottom-left coordinates) the user dragged the
    /// recording HUD to; nil = default bottom-center placement.
    static var hudOrigin: CGPoint? {
        get {
            let parts = (defaults.string(forKey: Key.hudOrigin) ?? "")
                .split(separator: ",")
                .compactMap { Double($0) }
            guard parts.count == 2 else { return nil }
            return CGPoint(x: parts[0], y: parts[1])
        }
        set {
            if let origin = newValue {
                defaults.set("\(origin.x),\(origin.y)", forKey: Key.hudOrigin)
            } else {
                defaults.removeObject(forKey: Key.hudOrigin)
            }
        }
    }

    /// Where the settings window was last dragged to, so reopening it puts
    /// it back. Same encoding as `hudOrigin`.
    static var settingsWindowOrigin: CGPoint? {
        get {
            let parts = (defaults.string(forKey: Key.settingsWindowOrigin) ?? "")
                .split(separator: ",")
                .compactMap { Double($0) }
            guard parts.count == 2 else { return nil }
            return CGPoint(x: parts[0], y: parts[1])
        }
        set {
            if let origin = newValue {
                defaults.set("\(origin.x),\(origin.y)", forKey: Key.settingsWindowOrigin)
            } else {
                defaults.removeObject(forKey: Key.settingsWindowOrigin)
            }
        }
    }

    /// Raw value of the HudTheme drawn while dictating; see HudThemes.swift.
    static var hudTheme: String {
        get { defaults.string(forKey: Key.hudTheme) ?? "classic" }
        set { defaults.set(newValue, forKey: Key.hudTheme) }
    }

    /// True once start-at-login has been auto-registered (or the user has
    /// toggled it themselves) — first-run registration must happen only once.
    static var loginItemSetupDone: Bool {
        get { defaults.bool(forKey: Key.loginItemSetupDone) }
        set { defaults.set(newValue, forKey: Key.loginItemSetupDone) }
    }
}
