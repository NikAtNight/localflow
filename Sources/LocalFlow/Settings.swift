import Foundation

/// UserDefaults-backed app settings.
enum Settings {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let hotkey = "hotkey"
        static let whisperModel = "whisperModel"
        static let cleanupEnabled = "cleanupEnabled"
        static let ollamaModel = "ollamaModel"
        static let soundCues = "soundCues"
        static let inputDeviceUID = "inputDeviceUID"
        static let loginItemSetupDone = "loginItemSetupDone"
    }

    /// Whisper models available in the argmaxinc/whisperkit-coreml registry,
    /// ordered smallest → largest. Small models are the right default for
    /// dictation latency (see plan: ~0.3–0.5s per sentence).
    static let whisperModels: [(name: String, label: String)] = [
        ("openai_whisper-tiny.en", "Tiny (fastest, least accurate)"),
        ("openai_whisper-base.en", "Base (fast)"),
        ("openai_whisper-small.en", "Small (recommended)"),
        ("openai_whisper-large-v3-v20240930_turbo", "Large v3 Turbo (most accurate)"),
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

    /// CoreAudio device UID of the microphone to record from; nil = system default.
    static var inputDeviceUID: String? {
        get { defaults.string(forKey: Key.inputDeviceUID) }
        set { defaults.set(newValue, forKey: Key.inputDeviceUID) }
    }

    /// True once start-at-login has been auto-registered (or the user has
    /// toggled it themselves) — first-run registration must happen only once.
    static var loginItemSetupDone: Bool {
        get { defaults.bool(forKey: Key.loginItemSetupDone) }
        set { defaults.set(newValue, forKey: Key.loginItemSetupDone) }
    }
}
