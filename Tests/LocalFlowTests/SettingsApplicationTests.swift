import Foundation
import XCTest
@testable import LocalFlow

/// Contract for the single path that validates, persists, and applies live
/// settings changes from both the settings window and the menu bar.
@MainActor
final class SettingsApplicationTests: XCTestCase {
    private static let turboModel = "openai_whisper-large-v3-v20240930_turbo"
    private static let smallModel = "openai_whisper-small.en"

    private enum Event: Equatable {
        case hotkey(HotkeyManager.Key)
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

    private struct TestError: Error {}

    private var defaultsToRemove: [String] = []

    override func tearDown() {
        for name in defaultsToRemove {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        defaultsToRemove.removeAll()
        super.tearDown()
    }

    func testPersistenceStaysInsideTheInjectedDefaultsSuite() {
        let firstDefaults = makeDefaults()
        let secondDefaults = makeDefaults()
        let firstSystem = FakeLiveSystem()
        let secondSystem = FakeLiveSystem()
        let first = makeApplication(defaults: firstDefaults, system: firstSystem)
        let second = makeApplication(defaults: secondDefaults, system: secondSystem)

        XCTAssertSuccess(first.apply(.hotkey(.rightCommand), from: .settingsWindow))
        XCTAssertSuccess(first.apply(.whisperModel(Self.smallModel), from: .settingsWindow))
        XCTAssertSuccess(first.apply(.microphone("studio-mic"), from: .settingsWindow))
        XCTAssertSuccess(first.apply(.automaticUpdates(false), from: .settingsWindow))

        let restored = makeApplication(defaults: firstDefaults, system: FakeLiveSystem())
        XCTAssertEqual(restored.values.hotkey, .rightCommand)
        XCTAssertEqual(restored.values.whisperModel, Self.smallModel)
        XCTAssertEqual(restored.values.microphoneUID, "studio-mic")
        XCTAssertFalse(restored.values.automaticUpdates)

        XCTAssertEqual(second.values.hotkey, .rightOption)
        XCTAssertEqual(second.values.whisperModel, Self.turboModel)
        XCTAssertNil(second.values.microphoneUID)
        XCTAssertTrue(second.values.automaticUpdates)
        XCTAssertTrue(secondSystem.events.isEmpty)
    }

    func testMalformedStoredValuesAreRepairedWithoutFiringLiveEffects() {
        let defaults = makeDefaults()
        defaults.set("left-shift", forKey: "hotkey")
        defaults.set("missing-model", forKey: "whisperModel")
        defaults.set("  ", forKey: "inputDeviceUID")
        defaults.set("sometimes", forKey: "automaticUpdates")
        let system = FakeLiveSystem()

        let application = makeApplication(defaults: defaults, system: system)

        XCTAssertEqual(application.values.hotkey, .rightOption)
        XCTAssertEqual(application.values.whisperModel, Self.turboModel)
        XCTAssertNil(application.values.microphoneUID)
        XCTAssertTrue(application.values.automaticUpdates)
        XCTAssertEqual(defaults.string(forKey: "hotkey"), HotkeyManager.Key.rightOption.rawValue)
        XCTAssertEqual(defaults.string(forKey: "whisperModel"), Self.turboModel)
        XCTAssertNil(defaults.object(forKey: "inputDeviceUID"))
        XCTAssertEqual(defaults.object(forKey: "automaticUpdates") as? Bool, true)
        XCTAssertTrue(system.events.isEmpty)
    }

    func testEveryChangedValuePersistsAndFiresItsLiveEffectOnce() {
        let defaults = makeDefaults()
        let system = FakeLiveSystem()
        let application = makeApplication(defaults: defaults, system: system)

        XCTAssertSuccess(application.apply(.hotkey(.rightCommand), from: .settingsWindow))
        XCTAssertSuccess(application.apply(.whisperModel(Self.smallModel), from: .settingsWindow))
        XCTAssertSuccess(application.apply(.microphone("usb-mic"), from: .settingsWindow))
        XCTAssertSuccess(application.apply(.automaticUpdates(false), from: .settingsWindow))

        XCTAssertEqual(system.events, [
            .hotkey(.rightCommand),
            .whisperModel(Self.smallModel),
            .microphone("usb-mic"),
            .automaticUpdates(false),
        ])
        XCTAssertEqual(defaults.string(forKey: "hotkey"), HotkeyManager.Key.rightCommand.rawValue)
        XCTAssertEqual(defaults.string(forKey: "whisperModel"), Self.smallModel)
        XCTAssertEqual(defaults.string(forKey: "inputDeviceUID"), "usb-mic")
        XCTAssertEqual(defaults.object(forKey: "automaticUpdates") as? Bool, false)
    }

    func testApplyingTheCurrentValueDoesNotRepeatPersistenceOrLiveEffects() {
        let defaults = makeDefaults()
        let system = FakeLiveSystem()
        let application = makeApplication(defaults: defaults, system: system)

        XCTAssertSuccess(application.apply(.hotkey(.rightCommand), from: .settingsWindow))
        XCTAssertSuccess(application.apply(.whisperModel(Self.smallModel), from: .settingsWindow))
        XCTAssertSuccess(application.apply(.microphone("usb-mic"), from: .settingsWindow))
        XCTAssertSuccess(application.apply(.automaticUpdates(false), from: .settingsWindow))
        system.events.removeAll()

        XCTAssertSuccess(application.apply(.hotkey(.rightCommand), from: .menu))
        XCTAssertSuccess(application.apply(.whisperModel(Self.smallModel), from: .menu))
        XCTAssertSuccess(application.apply(.microphone("usb-mic"), from: .menu))
        XCTAssertSuccess(application.apply(.automaticUpdates(false), from: .menu))

        XCTAssertTrue(system.events.isEmpty)
    }

    func testSettingsWindowAndMenuProduceTheSameValuesAndEffects() {
        let changes: [SettingsApplication.Change] = [
            .hotkey(.rightCommand),
            .whisperModel(Self.smallModel),
            .microphone("desk-mic"),
            .automaticUpdates(false),
        ]

        for change in changes {
            let windowSystem = FakeLiveSystem()
            let menuSystem = FakeLiveSystem()
            let windowApplication = makeApplication(defaults: makeDefaults(), system: windowSystem)
            let menuApplication = makeApplication(defaults: makeDefaults(), system: menuSystem)

            XCTAssertSuccess(windowApplication.apply(change, from: .settingsWindow))
            XCTAssertSuccess(menuApplication.apply(change, from: .menu))

            XCTAssertEqual(windowApplication.values, menuApplication.values)
            XCTAssertEqual(windowSystem.events, menuSystem.events)
        }
    }

    func testUnsupportedWhisperModelIsRejectedWithoutChangingState() {
        let defaults = makeDefaults()
        let system = FakeLiveSystem()
        let application = makeApplication(defaults: defaults, system: system)

        let result = application.apply(.whisperModel("unknown-model"), from: .settingsWindow)

        XCTAssertFailure(result, equals: .unsupportedWhisperModel)
        XCTAssertEqual(application.values.whisperModel, Self.turboModel)
        XCTAssertEqual(defaults.string(forKey: "whisperModel"), Self.turboModel)
        XCTAssertTrue(system.events.isEmpty)
    }

    func testSuccessfulLoginItemChangeCommitsTheActualServiceState() {
        let defaults = makeDefaults()
        let system = FakeLiveSystem()
        let application = makeApplication(defaults: defaults, system: system)

        XCTAssertSuccess(application.apply(.startAtLogin(true), from: .settingsWindow))

        XCTAssertEqual(system.loginItemChanges, [true])
        XCTAssertTrue(application.values.startAtLogin)
        XCTAssertEqual(defaults.object(forKey: "loginItemSetupDone") as? Bool, true)
    }

    func testLoginItemFailureRollsBackToTheActualServiceState() {
        let defaults = makeDefaults()
        let system = FakeLiveSystem()
        system.loginItemError = TestError()
        let application = makeApplication(defaults: defaults, system: system)

        let result = application.apply(.startAtLogin(true), from: .settingsWindow)

        XCTAssertFailure(result, equals: .loginItemChangeFailed)
        XCTAssertEqual(system.loginItemChanges, [true])
        XCTAssertFalse(application.values.startAtLogin)
        XCTAssertFalse(defaults.bool(forKey: "loginItemSetupDone"))
        XCTAssertTrue(system.events.isEmpty)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "LocalFlow.SettingsApplicationTests.\(UUID().uuidString)"
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
                applyAutomaticUpdates: { system.events.append(.automaticUpdates($0)) }
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

    private func XCTAssertFailure(
        _ result: Result<Void, SettingsApplication.Failure>,
        equals expected: SettingsApplication.Failure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success:
            XCTFail("Expected failure \(expected)", file: file, line: line)
        case .failure(let actual):
            XCTAssertEqual(actual, expected, file: file, line: line)
        }
    }
}
