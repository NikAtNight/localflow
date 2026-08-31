import Foundation

/// Validates, persists, and applies settings that change live app objects.
/// Both the settings window and menu actions use this path.
@MainActor
final class SettingsApplication {
    struct Values: Equatable {
        var hotkey: HotkeyManager.Key
        var whisperModel: String
        var microphoneUID: String?
        var automaticUpdates: Bool
        var startAtLogin: Bool
        var commandHotkey: HotkeyManager.Key
        var keepMicWarm: Bool
        var cleanupEnabled: Bool
        var commandModeEnabled: Bool
        var theme: HudTheme
        var soundCues: Bool
    }

    enum Change: Equatable {
        case hotkey(HotkeyManager.Key)
        case whisperModel(String)
        case microphone(String?)
        case automaticUpdates(Bool)
        case startAtLogin(Bool)
        case commandHotkey(HotkeyManager.Key)
        case keepMicWarm(Bool)
        case cleanupEnabled(Bool)
        case commandModeEnabled(Bool)
        case theme(HudTheme)
        case soundCues(Bool)
    }

    enum Source {
        case settingsWindow
        case menu
    }

    enum Failure: Error, Equatable {
        case unsupportedWhisperModel
        case loginItemChangeFailed
    }

    struct Effects {
        let applyHotkey: (HotkeyManager.Key) -> Void
        let reloadWhisperModel: (String) -> Void
        let selectMicrophone: (String?) -> Void
        let applyAutomaticUpdates: (Bool) -> Void
        let applyCommandHotkey: (HotkeyManager.Key) -> Void
        let applyKeepMicWarm: (Bool) -> Void
        let applyCleanupEnabled: (Bool) -> Void
        let applyCommandModeEnabled: (Bool) -> Void
        let applyTheme: (HudTheme) -> Void
        let applySoundCues: (Bool) -> Void

        init(
            applyHotkey: @escaping (HotkeyManager.Key) -> Void,
            reloadWhisperModel: @escaping (String) -> Void,
            selectMicrophone: @escaping (String?) -> Void,
            applyAutomaticUpdates: @escaping (Bool) -> Void,
            applyCommandHotkey: @escaping (HotkeyManager.Key) -> Void = { _ in },
            applyKeepMicWarm: @escaping (Bool) -> Void = { _ in },
            applyCleanupEnabled: @escaping (Bool) -> Void = { _ in },
            applyCommandModeEnabled: @escaping (Bool) -> Void = { _ in },
            applyTheme: @escaping (HudTheme) -> Void = { _ in },
            applySoundCues: @escaping (Bool) -> Void = { _ in }
        ) {
            self.applyHotkey = applyHotkey
            self.reloadWhisperModel = reloadWhisperModel
            self.selectMicrophone = selectMicrophone
            self.applyAutomaticUpdates = applyAutomaticUpdates
            self.applyCommandHotkey = applyCommandHotkey
            self.applyKeepMicWarm = applyKeepMicWarm
            self.applyCleanupEnabled = applyCleanupEnabled
            self.applyCommandModeEnabled = applyCommandModeEnabled
            self.applyTheme = applyTheme
            self.applySoundCues = applySoundCues
        }
    }

    struct LoginItem {
        let isEnabled: () -> Bool
        let setEnabled: (Bool) throws -> Void
    }

    private let defaults: UserDefaults
    private let supportedWhisperModels: Set<String>
    private let effects: Effects
    private let loginItem: LoginItem

    private(set) var values: Values

    init(
        defaults: UserDefaults,
        supportedWhisperModels: [String],
        defaultWhisperModel: String,
        effects: Effects,
        loginItem: LoginItem
    ) {
        precondition(supportedWhisperModels.contains(defaultWhisperModel))

        self.defaults = defaults
        self.supportedWhisperModels = Set(supportedWhisperModels)
        self.effects = effects
        self.loginItem = loginItem

        let hotkey = Self.loadHotkey(from: defaults)
        let whisperModel = Self.loadWhisperModel(
            from: defaults,
            supported: self.supportedWhisperModels,
            defaultModel: defaultWhisperModel
        )
        let microphoneUID = Self.loadMicrophone(from: defaults)
        let automaticUpdates = Self.loadAutomaticUpdates(from: defaults)
        let commandHotkey = Self.loadCommandHotkey(from: defaults)
        let keepMicWarm = Self.loadBool(from: defaults, key: Settings.Key.keepMicWarm, default: true)
        let cleanupEnabled = Self.loadBool(from: defaults, key: Settings.Key.cleanupEnabled, default: false)
        let commandModeEnabled = Self.loadBool(
            from: defaults,
            key: Settings.Key.commandModeEnabled,
            default: true
        )
        let theme = Self.loadTheme(from: defaults)
        let soundCues = Self.loadBool(from: defaults, key: Settings.Key.soundCues, default: true)

        values = Values(
            hotkey: hotkey,
            whisperModel: whisperModel,
            microphoneUID: microphoneUID,
            automaticUpdates: automaticUpdates,
            startAtLogin: loginItem.isEnabled(),
            commandHotkey: commandHotkey,
            keepMicWarm: keepMicWarm,
            cleanupEnabled: cleanupEnabled,
            commandModeEnabled: commandModeEnabled,
            theme: theme,
            soundCues: soundCues
        )

        // Repair missing or malformed values without treating startup as a
        // user change. Live effects run only through apply(_:from:).
        defaults.set(hotkey.rawValue, forKey: Settings.Key.hotkey)
        defaults.set(whisperModel, forKey: Settings.Key.whisperModel)
        if let microphoneUID {
            defaults.set(microphoneUID, forKey: Settings.Key.inputDeviceUID)
        } else {
            defaults.removeObject(forKey: Settings.Key.inputDeviceUID)
        }
        defaults.set(automaticUpdates, forKey: Settings.Key.automaticUpdates)
        defaults.set(commandHotkey.rawValue, forKey: Settings.Key.commandHotkey)
        defaults.set(keepMicWarm, forKey: Settings.Key.keepMicWarm)
        defaults.set(cleanupEnabled, forKey: Settings.Key.cleanupEnabled)
        defaults.set(commandModeEnabled, forKey: Settings.Key.commandModeEnabled)
        defaults.set(theme.rawValue, forKey: Settings.Key.hudTheme)
        defaults.set(soundCues, forKey: Settings.Key.soundCues)
    }

    @discardableResult
    func apply(_ change: Change, from _: Source) -> Result<Void, Failure> {
        switch change {
        case .hotkey(let hotkey):
            guard hotkey != values.hotkey else { return .success(()) }
            defaults.set(hotkey.rawValue, forKey: Settings.Key.hotkey)
            values.hotkey = hotkey
            effects.applyHotkey(hotkey)

        case .whisperModel(let model):
            guard supportedWhisperModels.contains(model) else {
                return .failure(.unsupportedWhisperModel)
            }
            guard model != values.whisperModel else { return .success(()) }
            defaults.set(model, forKey: Settings.Key.whisperModel)
            values.whisperModel = model
            effects.reloadWhisperModel(model)

        case .microphone(let uid):
            let uid = Self.normalizedMicrophone(uid)
            guard uid != values.microphoneUID else { return .success(()) }
            if let uid {
                defaults.set(uid, forKey: Settings.Key.inputDeviceUID)
            } else {
                defaults.removeObject(forKey: Settings.Key.inputDeviceUID)
            }
            values.microphoneUID = uid
            effects.selectMicrophone(uid)

        case .automaticUpdates(let enabled):
            guard enabled != values.automaticUpdates else { return .success(()) }
            defaults.set(enabled, forKey: Settings.Key.automaticUpdates)
            values.automaticUpdates = enabled
            effects.applyAutomaticUpdates(enabled)

        case .startAtLogin(let enabled):
            values.startAtLogin = loginItem.isEnabled()
            guard enabled != values.startAtLogin else { return .success(()) }
            do {
                try loginItem.setEnabled(enabled)
                values.startAtLogin = loginItem.isEnabled()
                defaults.set(true, forKey: Settings.Key.loginItemSetupDone)
            } catch {
                values.startAtLogin = loginItem.isEnabled()
                return .failure(.loginItemChangeFailed)
            }

        case .commandHotkey(let hotkey):
            guard hotkey != values.commandHotkey else { return .success(()) }
            defaults.set(hotkey.rawValue, forKey: Settings.Key.commandHotkey)
            values.commandHotkey = hotkey
            effects.applyCommandHotkey(hotkey)

        case .keepMicWarm(let enabled):
            guard enabled != values.keepMicWarm else { return .success(()) }
            defaults.set(enabled, forKey: Settings.Key.keepMicWarm)
            values.keepMicWarm = enabled
            effects.applyKeepMicWarm(enabled)

        case .cleanupEnabled(let enabled):
            guard enabled != values.cleanupEnabled else { return .success(()) }
            defaults.set(enabled, forKey: Settings.Key.cleanupEnabled)
            values.cleanupEnabled = enabled
            effects.applyCleanupEnabled(enabled)

        case .commandModeEnabled(let enabled):
            guard enabled != values.commandModeEnabled else { return .success(()) }
            defaults.set(enabled, forKey: Settings.Key.commandModeEnabled)
            values.commandModeEnabled = enabled
            effects.applyCommandModeEnabled(enabled)

        case .theme(let theme):
            guard theme != values.theme else { return .success(()) }
            defaults.set(theme.rawValue, forKey: Settings.Key.hudTheme)
            values.theme = theme
            effects.applyTheme(theme)

        case .soundCues(let enabled):
            guard enabled != values.soundCues else { return .success(()) }
            defaults.set(enabled, forKey: Settings.Key.soundCues)
            values.soundCues = enabled
            effects.applySoundCues(enabled)
        }

        return .success(())
    }

    /// Pulls in login-item changes made outside the settings window, such as
    /// first-run registration. This does not persist or fire a live effect.
    func refreshLoginItemState() {
        values.startAtLogin = loginItem.isEnabled()
    }

    private static func loadHotkey(from defaults: UserDefaults) -> HotkeyManager.Key {
        guard let rawValue = defaults.string(forKey: Settings.Key.hotkey),
              let hotkey = HotkeyManager.Key(rawValue: rawValue) else {
            return .rightOption
        }
        return hotkey
    }

    private static func loadWhisperModel(
        from defaults: UserDefaults,
        supported: Set<String>,
        defaultModel: String
    ) -> String {
        guard let model = defaults.string(forKey: Settings.Key.whisperModel),
              supported.contains(model) else {
            return defaultModel
        }
        return model
    }

    private static func loadMicrophone(from defaults: UserDefaults) -> String? {
        normalizedMicrophone(defaults.string(forKey: Settings.Key.inputDeviceUID))
    }

    private static func normalizedMicrophone(_ uid: String?) -> String? {
        guard let uid else { return nil }
        let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func loadAutomaticUpdates(from defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Settings.Key.automaticUpdates) as? Bool ?? true
    }

    private static func loadCommandHotkey(from defaults: UserDefaults) -> HotkeyManager.Key {
        guard let rawValue = defaults.string(forKey: Settings.Key.commandHotkey),
              let hotkey = HotkeyManager.Key(rawValue: rawValue) else {
            return .rightOption
        }
        return hotkey
    }

    private static func loadBool(
        from defaults: UserDefaults,
        key: String,
        default defaultValue: Bool
    ) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    private static func loadTheme(from defaults: UserDefaults) -> HudTheme {
        guard let rawValue = defaults.string(forKey: Settings.Key.hudTheme),
              let theme = HudTheme(rawValue: rawValue) else {
            return .classic
        }
        return theme
    }
}
