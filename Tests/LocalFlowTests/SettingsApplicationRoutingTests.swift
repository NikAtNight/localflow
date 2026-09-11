import Foundation
import XCTest
@testable import LocalFlow

@MainActor
final class SettingsApplicationRoutingTests: XCTestCase {
    private static let turboModel = "openai_whisper-large-v3-v20240930_turbo"
    private static let smallModel = "openai_whisper-small.en"

    private enum Event: Equatable {
        case hotkey(HotkeyManager.Key)
        case commandHotkey(HotkeyManager.Key)
        case whisperModel(String)
        case microphone(String?)
        case automaticUpdates(Bool)
    }

    private final class FakeLiveSystem {
        var events: [Event] = []
        var loginItemEnabled = false
        var loginItemChanges: [Bool] = []
        var loginItemError: Error?

        func setLoginItemEnabled(_ enabled: Bool) throws {
            loginItemChanges.append(enabled)
            if let loginItemError { throw loginItemError }
            loginItemEnabled = enabled
        }
    }

    private struct LoginItemError: Error {}

    private var defaultsToRemove: [String] = []

    override func tearDown() {
        for name in defaultsToRemove {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        defaultsToRemove.removeAll()
        super.tearDown()
    }

    func testChangingDictationHotkeyReconcilesTheLiveCommandHotkey() {
        let system = FakeLiveSystem()
        let application = makeApplication(defaults: makeDefaults(), system: system)

        XCTAssertSuccess(application.apply(.commandHotkey(.rightCommand)))
        system.events.removeAll()

        XCTAssertSuccess(application.apply(.hotkey(.rightCommand)))

        XCTAssertEqual(system.events, [
            .hotkey(.rightCommand),
            .commandHotkey(.rightCommand),
        ])
    }

    /// SettingsModel exposes an explicit menu entry point. AppDelegate menu
    /// actions must call this rather than assign the published property.
    func testSettingsModelAppliesMenuChangesThroughTheApplication() {
        let system = FakeLiveSystem()
        let application = makeApplication(defaults: makeDefaults(), system: system)
        let model = SettingsModel(settingsApplication: application)

        XCTAssertSuccess(model.apply(.hotkey(.rightCommand)))

        XCTAssertEqual(model.hotkey, .rightCommand)
        XCTAssertEqual(application.values.hotkey, .rightCommand)
        XCTAssertEqual(system.events, [
            .hotkey(.rightCommand),
            .commandHotkey(.rightOption),
        ])
    }

    func testWindowAndMenuRouteValidatedValuesToTheSameEffectsWithoutRepeatingThem() {
        let windowSystem = FakeLiveSystem()
        let menuSystem = FakeLiveSystem()
        let windowDefaults = makeDefaults()
        let menuDefaults = makeDefaults()
        let windowApplication = makeApplication(defaults: windowDefaults, system: windowSystem)
        let menuApplication = makeApplication(defaults: menuDefaults, system: menuSystem)
        let window = SettingsModel(settingsApplication: windowApplication)
        let menu = SettingsModel(settingsApplication: menuApplication)
        XCTAssertTrue(windowSystem.events.isEmpty)
        XCTAssertTrue(menuSystem.events.isEmpty)

        window.hotkey = .rightCommand
        window.whisperModel = Self.smallModel
        window.micUID = "  desk-mic  "
        window.automaticUpdates = false
        let menuChanges: [SettingsApplication.Change] = [
            .hotkey(.rightCommand),
            .whisperModel(Self.smallModel),
            .microphone("  desk-mic  "),
            .automaticUpdates(false),
        ]
        for change in menuChanges { XCTAssertSuccess(menu.apply(change)) }

        let expected: [Event] = [
            .hotkey(.rightCommand),
            .commandHotkey(.rightOption),
            .whisperModel(Self.smallModel),
            .microphone("desk-mic"),
            .automaticUpdates(false),
        ]
        XCTAssertEqual(windowSystem.events, expected)
        XCTAssertEqual(menuSystem.events, expected)
        XCTAssertEqual(windowApplication.values, menuApplication.values)
        XCTAssertEqual(window.micUID, "desk-mic")
        XCTAssertEqual(menu.micUID, "desk-mic")
        XCTAssertEqual(windowDefaults.string(forKey: Settings.Key.inputDeviceUID), "desk-mic")
        XCTAssertEqual(menuDefaults.string(forKey: Settings.Key.inputDeviceUID), "desk-mic")

        windowSystem.events.removeAll()
        menuSystem.events.removeAll()
        window.hotkey = .rightCommand
        window.whisperModel = Self.smallModel
        window.micUID = "  desk-mic  "
        window.automaticUpdates = false
        for change in menuChanges { XCTAssertSuccess(menu.apply(change)) }

        XCTAssertTrue(windowSystem.events.isEmpty)
        XCTAssertTrue(menuSystem.events.isEmpty)
        XCTAssertEqual(window.micUID, "desk-mic")
    }

    func testUnsupportedModelRestoresPublishedValueWithoutFiringAnEffect() {
        let defaults = makeDefaults()
        let system = FakeLiveSystem()
        let application = makeApplication(defaults: defaults, system: system)
        let model = SettingsModel(settingsApplication: application)

        model.whisperModel = "unsupported-model"

        XCTAssertEqual(model.whisperModel, Self.turboModel)
        XCTAssertEqual(application.values.whisperModel, Self.turboModel)
        XCTAssertEqual(defaults.string(forKey: Settings.Key.whisperModel), Self.turboModel)
        XCTAssertTrue(system.events.isEmpty)
    }

    func testLoginFailureRestoresPublishedStateAndAllowsALaterRetry() {
        let defaults = makeDefaults()
        let system = FakeLiveSystem()
        system.loginItemError = LoginItemError()
        let application = makeApplication(defaults: defaults, system: system)
        let model = SettingsModel(settingsApplication: application)

        model.startAtLogin = true

        XCTAssertFalse(model.startAtLogin)
        XCTAssertFalse(application.values.startAtLogin)
        XCTAssertEqual(system.loginItemChanges, [true])
        XCTAssertFalse(defaults.bool(forKey: Settings.Key.loginItemSetupDone))

        system.loginItemError = nil
        model.startAtLogin = true
        XCTAssertTrue(model.startAtLogin)
        XCTAssertTrue(application.values.startAtLogin)
        XCTAssertEqual(system.loginItemChanges, [true, true])
        XCTAssertTrue(defaults.bool(forKey: Settings.Key.loginItemSetupDone))
        XCTAssertTrue(system.events.isEmpty)
    }

    func testDiagnosticRetentionDefaultsOffAndPersistsThroughSettingsModel() {
        let defaults = makeDefaults()
        let system = FakeLiveSystem()
        let application = makeApplication(defaults: defaults, system: system)
        let model = SettingsModel(settingsApplication: application)

        XCTAssertFalse(model.saveDiagnosticRecordings)
        XCTAssertFalse(application.values.saveDiagnosticRecordings)

        model.saveDiagnosticRecordings = true

        XCTAssertTrue(application.values.saveDiagnosticRecordings)
        XCTAssertEqual(defaults.object(forKey: Settings.Key.saveDiagnosticRecordings) as? Bool, true)
        let reloaded = makeApplication(defaults: defaults, system: system)
        XCTAssertTrue(reloaded.values.saveDiagnosticRecordings)
        XCTAssertTrue(SettingsModel(settingsApplication: reloaded).saveDiagnosticRecordings)

        XCTAssertSuccess(model.apply(.saveDiagnosticRecordings(false)))

        XCTAssertFalse(model.saveDiagnosticRecordings)
        XCTAssertFalse(application.values.saveDiagnosticRecordings)
        XCTAssertEqual(defaults.object(forKey: Settings.Key.saveDiagnosticRecordings) as? Bool, false)
        XCTAssertTrue(application.values.saveHistory)
        XCTAssertTrue(system.events.isEmpty)
    }

    func testPersonalVoiceCollectionDefaultsOffAndPersistsSeparatelyFromDiagnostics() {
        let defaults = makeDefaults()
        let system = FakeLiveSystem()
        let application = makeApplication(defaults: defaults, system: system)
        let model = SettingsModel(settingsApplication: application)

        XCTAssertFalse(model.savePersonalVoice)
        XCTAssertFalse(application.values.savePersonalVoice)
        model.savePersonalVoice = true

        XCTAssertTrue(application.values.savePersonalVoice)
        XCTAssertEqual(defaults.object(forKey: Settings.Key.savePersonalVoice) as? Bool, true)
        let reloaded = makeApplication(defaults: defaults, system: system)
        XCTAssertTrue(SettingsModel(settingsApplication: reloaded).savePersonalVoice)
        XCTAssertFalse(reloaded.values.saveDiagnosticRecordings)

        XCTAssertSuccess(model.apply(.savePersonalVoice(false)))
        XCTAssertFalse(model.savePersonalVoice)
        XCTAssertFalse(application.values.savePersonalVoice)
        XCTAssertEqual(defaults.object(forKey: Settings.Key.savePersonalVoice) as? Bool, false)
        XCTAssertTrue(application.values.saveHistory)
        XCTAssertTrue(system.events.isEmpty)
    }

    func testPersonalVoicePaneIsAvailableOnlyInLocalBuilds() {
        XCTAssertTrue(SettingsPane.available(for: AppIdentity(bundleIdentifier: AppIdentity.localID))
            .contains(.personalVoice))
        for id in [AppIdentity.productionID, "other.bundle", nil] {
            XCTAssertFalse(SettingsPane.available(for: AppIdentity(bundleIdentifier: id))
                .contains(.personalVoice))
        }
    }

    private func makeDefaults() -> UserDefaults {
        let name = "LocalFlow.SettingsApplicationRoutingTests.\(UUID().uuidString)"
        defaultsToRemove.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeApplication(
        defaults: UserDefaults,
        system: FakeLiveSystem
    ) -> SettingsApplication {
        SettingsApplication(
            defaults: defaults,
            supportedWhisperModels: [Self.turboModel, Self.smallModel],
            defaultWhisperModel: Self.turboModel,
            effects: .init(
                applyHotkey: { system.events.append(.hotkey($0)) },
                reloadWhisperModel: { system.events.append(.whisperModel($0)) },
                selectMicrophone: { system.events.append(.microphone($0)) },
                applyAutomaticUpdates: { system.events.append(.automaticUpdates($0)) },
                applyCommandHotkey: { system.events.append(.commandHotkey($0)) }
            ),
            loginItem: .init(
                isEnabled: { system.loginItemEnabled },
                setEnabled: { try system.setLoginItemEnabled($0) }
            )
        )
    }

    private func XCTAssertSuccess(
        _ result: Result<Void, SettingsApplication.Failure>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .failure(let error) = result {
            XCTFail("Expected success, got \(error)", file: file, line: line)
        }
    }
}
