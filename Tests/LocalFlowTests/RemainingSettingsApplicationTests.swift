import Foundation
import XCTest
@testable import LocalFlow

/// Contract for the live settings that must not retain a second persistence
/// and callback path in SettingsModel.
@MainActor
final class RemainingSettingsApplicationTests: XCTestCase {
    private static let turboModel = "openai_whisper-large-v3-v20240930_turbo"

    private enum Event: Equatable {
        case commandHotkey(HotkeyManager.Key)
        case keepMicWarm(Bool)
        case cleanupEnabled(Bool)
        case commandModeEnabled(Bool)
        case theme(HudTheme)
        case soundCues(Bool)
    }

    private final class FakeLiveSystem {
        var events: [Event] = []
    }

    private var defaultsToRemove: [String] = []

    override func tearDown() {
        for name in defaultsToRemove {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        defaultsToRemove.removeAll()
        super.tearDown()
    }

    func testApplicationPersistsAndAppliesEveryRemainingLiveSettingOnce() {
        let defaults = makeDefaults()
        let system = FakeLiveSystem()
        let application = makeApplication(defaults: defaults, system: system)

        applyChangedValues(to: application)
        applyChangedValues(to: application)

        XCTAssertEqual(system.events, [
            .commandHotkey(.rightCommand),
            .keepMicWarm(false),
            .cleanupEnabled(true),
            .commandModeEnabled(false),
            .theme(.aurora),
            .soundCues(false),
        ])
        XCTAssertEqual(application.values.commandHotkey, .rightCommand)
        XCTAssertFalse(application.values.keepMicWarm)
        XCTAssertTrue(application.values.cleanupEnabled)
        XCTAssertFalse(application.values.commandModeEnabled)
        XCTAssertEqual(application.values.theme, .aurora)
        XCTAssertFalse(application.values.soundCues)
        XCTAssertEqual(defaults.string(forKey: "commandHotkey"), HotkeyManager.Key.rightCommand.rawValue)
        XCTAssertEqual(defaults.object(forKey: "keepMicWarm") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "cleanupEnabled") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "commandModeEnabled") as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: "hudTheme"), HudTheme.aurora.rawValue)
        XCTAssertEqual(defaults.object(forKey: "soundCues") as? Bool, false)
    }

    func testApplicationDoesNotApplyEffectsForInitialValues() {
        let defaults = makeDefaults()
        let system = FakeLiveSystem()
        let application = makeApplication(defaults: defaults, system: system)

        XCTAssertSuccess(application.apply(.commandHotkey(.rightOption), from: .settingsWindow))
        XCTAssertSuccess(application.apply(.keepMicWarm(true), from: .settingsWindow))
        XCTAssertSuccess(application.apply(.cleanupEnabled(false), from: .settingsWindow))
        XCTAssertSuccess(application.apply(.commandModeEnabled(true), from: .settingsWindow))
        XCTAssertSuccess(application.apply(.theme(.classic), from: .settingsWindow))
        XCTAssertSuccess(application.apply(.soundCues(true), from: .settingsWindow))

        XCTAssertTrue(system.events.isEmpty)
    }

    func testSettingsModelRoutesEveryRemainingChangeThroughTheApplication() {
        let defaults = makeDefaults()
        let system = FakeLiveSystem()
        let application = makeApplication(defaults: defaults, system: system)
        let model = SettingsModel(settingsApplication: application)

        model.commandHotkey = .rightCommand
        model.keepMicWarm = false
        model.cleanupEnabled = true
        model.commandModeEnabled = false
        model.theme = .aurora
        model.soundCues = false

        XCTAssertEqual(system.events, [
            .commandHotkey(.rightCommand),
            .keepMicWarm(false),
            .cleanupEnabled(true),
            .commandModeEnabled(false),
            .theme(.aurora),
            .soundCues(false),
        ])
        XCTAssertEqual(application.values.commandHotkey, model.commandHotkey)
        XCTAssertEqual(application.values.keepMicWarm, model.keepMicWarm)
        XCTAssertEqual(application.values.cleanupEnabled, model.cleanupEnabled)
        XCTAssertEqual(application.values.commandModeEnabled, model.commandModeEnabled)
        XCTAssertEqual(application.values.theme, model.theme)
        XCTAssertEqual(application.values.soundCues, model.soundCues)
    }

    private func applyChangedValues(to application: SettingsApplication) {
        XCTAssertSuccess(application.apply(.commandHotkey(.rightCommand), from: .settingsWindow))
        XCTAssertSuccess(application.apply(.keepMicWarm(false), from: .settingsWindow))
        XCTAssertSuccess(application.apply(.cleanupEnabled(true), from: .settingsWindow))
        XCTAssertSuccess(application.apply(.commandModeEnabled(false), from: .settingsWindow))
        XCTAssertSuccess(application.apply(.theme(.aurora), from: .settingsWindow))
        XCTAssertSuccess(application.apply(.soundCues(false), from: .settingsWindow))
    }

    private func makeDefaults() -> UserDefaults {
        let name = "LocalFlow.RemainingSettingsApplicationTests.\(UUID().uuidString)"
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
            supportedWhisperModels: [Self.turboModel],
            defaultWhisperModel: Self.turboModel,
            effects: .init(
                applyHotkey: { _ in },
                reloadWhisperModel: { _ in },
                selectMicrophone: { _ in },
                applyAutomaticUpdates: { _ in },
                applyCommandHotkey: { system.events.append(.commandHotkey($0)) },
                applyKeepMicWarm: { system.events.append(.keepMicWarm($0)) },
                applyCleanupEnabled: { system.events.append(.cleanupEnabled($0)) },
                applyCommandModeEnabled: { system.events.append(.commandModeEnabled($0)) },
                applyTheme: { system.events.append(.theme($0)) },
                applySoundCues: { system.events.append(.soundCues($0)) }
            ),
            loginItem: .init(
                isEnabled: { false },
                setEnabled: { _ in }
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
