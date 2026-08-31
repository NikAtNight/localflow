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
    }

    enum Change: Equatable {
        case hotkey(HotkeyManager.Key)
        case whisperModel(String)
        case microphone(String?)
        case automaticUpdates(Bool)
        case startAtLogin(Bool)
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

        values = Values(
            hotkey: hotkey,
            whisperModel: whisperModel,
            microphoneUID: microphoneUID,
            automaticUpdates: automaticUpdates,
            startAtLogin: loginItem.isEnabled()
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
}
