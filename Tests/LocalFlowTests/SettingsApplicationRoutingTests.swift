import Foundation
import XCTest
@testable import LocalFlow

@MainActor
final class SettingsApplicationRoutingTests: XCTestCase {
    private static let turboModel = "openai_whisper-large-v3-v20240930_turbo"

    private enum Event: Equatable {
        case hotkey(HotkeyManager.Key)
        case commandHotkey(HotkeyManager.Key)
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
            supportedWhisperModels: [Self.turboModel],
            defaultWhisperModel: Self.turboModel,
            effects: .init(
                applyHotkey: { system.events.append(.hotkey($0)) },
                reloadWhisperModel: { _ in },
                selectMicrophone: { _ in },
                applyAutomaticUpdates: { _ in },
                applyCommandHotkey: { system.events.append(.commandHotkey($0)) }
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
