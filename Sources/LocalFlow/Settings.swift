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
        static let loginItemSetupDone = "loginItemSetupDone"
        static let hudTheme = "hudTheme"
        static let hudOrigin = "hudOrigin"
    }

    /// Whisper models available in the argmaxinc/whisperkit-coreml registry,
    /// ordered from development-speed models to the best dictation models.
    /// Small English remains the default latency/accuracy balance; the large
    /// variants are the quality choices on well-provisioned Apple silicon.
    static let whisperModels: [(name: String, label: String)] = [
        ("openai_whisper-tiny.en", "Tiny English (development only)"),
        ("openai_whisper-base.en", "Base English (fast, lower accuracy)"),
        ("openai_whisper-small.en", "Small English (balanced, current default)"),
        ("openai_whisper-large-v3-v20240930_626MB", "Large v3 626 MB (best compact accuracy)"),
        ("openai_whisper-large-v3-v20240930_turbo", "Large v3 Turbo (best Mac speed + accuracy)"),
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
        get { defaults.string(forKey: Key.whisperModel) ?? "openai_whisper-small.en" }
        set { defaults.set(newValue, forKey: Key.whisperModel) }
    }

    static var cleanupEnabled: Bool {
        get { defaults.bool(forKey: Key.cleanupEnabled) }
        set { defaults.set(newValue, forKey: Key.cleanupEnabled) }
    }

    static var ollamaModel: String {
        get { defaults.string(forKey: Key.ollamaModel) ?? "gemma3:4b" }
        set { defaults.set(newValue, forKey: Key.ollamaModel) }
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
