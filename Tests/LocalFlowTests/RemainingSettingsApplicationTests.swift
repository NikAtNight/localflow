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
        XCTAssertEqual(application.values.ollamaModel, "cleanup-model")
        XCTAssertEqual(application.values.ollamaCommandModel, "command-model")
        XCTAssertEqual(application.values.commandReasoning, .high)
        XCTAssertFalse(application.values.saveHistory)
        XCTAssertEqual(defaults.string(forKey: "commandHotkey"), HotkeyManager.Key.rightCommand.rawValue)
        XCTAssertEqual(defaults.object(forKey: "keepMicWarm") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "cleanupEnabled") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "commandModeEnabled") as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: "hudTheme"), HudTheme.aurora.rawValue)
        XCTAssertEqual(defaults.object(forKey: "soundCues") as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: "ollamaModel"), "cleanup-model")
        XCTAssertEqual(defaults.string(forKey: "ollamaCommandModel"), "command-model")
        XCTAssertEqual(defaults.string(forKey: "commandReasoning"), ReasoningLevel.high.rawValue)
        XCTAssertEqual(defaults.object(forKey: "saveHistory") as? Bool, false)
    }

    func testApplicationDoesNotApplyEffectsForInitialValues() {
        let defaults = makeDefaults()
        let system = FakeLiveSystem()
        let application = makeApplication(defaults: defaults, system: system)

        XCTAssertSuccess(application.apply(.commandHotkey(.rightOption)))
        XCTAssertSuccess(application.apply(.keepMicWarm(true)))
        XCTAssertSuccess(application.apply(.cleanupEnabled(false)))
        XCTAssertSuccess(application.apply(.commandModeEnabled(true)))
        XCTAssertSuccess(application.apply(.theme(.classic)))
        XCTAssertSuccess(application.apply(.soundCues(true)))
        XCTAssertSuccess(application.apply(.ollamaModel("s1-mini")))
        XCTAssertSuccess(application.apply(.ollamaCommandModel("gemma3:4b")))
        XCTAssertSuccess(application.apply(.commandReasoning(.off)))
        XCTAssertSuccess(application.apply(.saveHistory(true)))

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
        model.ollamaModel = "cleanup-model"
        model.ollamaCommandModel = "command-model"
        model.commandReasoning = .high
        model.saveHistory = false

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
        XCTAssertEqual(application.values.ollamaModel, model.ollamaModel)
        XCTAssertEqual(application.values.ollamaCommandModel, model.ollamaCommandModel)
        XCTAssertEqual(application.values.commandReasoning, model.commandReasoning)
        XCTAssertEqual(application.values.saveHistory, model.saveHistory)
    }

    private func applyChangedValues(to application: SettingsApplication) {
        XCTAssertSuccess(application.apply(.commandHotkey(.rightCommand)))
        XCTAssertSuccess(application.apply(.keepMicWarm(false)))
        XCTAssertSuccess(application.apply(.cleanupEnabled(true)))
        XCTAssertSuccess(application.apply(.commandModeEnabled(false)))
        XCTAssertSuccess(application.apply(.theme(.aurora)))
        XCTAssertSuccess(application.apply(.soundCues(false)))
        XCTAssertSuccess(application.apply(.ollamaModel("cleanup-model")))
        XCTAssertSuccess(application.apply(.ollamaCommandModel("command-model")))
        XCTAssertSuccess(application.apply(.commandReasoning(.high)))
        XCTAssertSuccess(application.apply(.saveHistory(false)))
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
