import Foundation
import XCTest
@testable import LocalFlow

@MainActor
final class SettingsApplicationVocabularyTests: XCTestCase {
    private static let turboModel = "openai_whisper-large-v3-v20240930_turbo"

    private final class FakeLiveSystem {
        var decoderVocabulary: [String] = []
    }

    private var defaultsToRemove: [String] = []

    override func tearDown() {
        for name in defaultsToRemove {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        defaultsToRemove.removeAll()
        super.tearDown()
    }

    func testVocabularySettingsPersistInInjectedDefaultsAndRefreshTheDecoderOncePerChange() {
        let firstDefaults = makeDefaults()
        let secondDefaults = makeDefaults()
        let system = FakeLiveSystem()
        let application = makeApplication(defaults: firstDefaults, system: system)
        let corrections = [SettingsApplication.Correction(wrong: "talex", right: "Talix")]

        XCTAssertSuccess(application.apply(.customVocabulary("LocalFlow"), from: .settingsWindow))
        XCTAssertSuccess(application.apply(.corrections(corrections), from: .settingsWindow))
        XCTAssertSuccess(application.apply(.customVocabulary("LocalFlow"), from: .settingsWindow))
        XCTAssertSuccess(application.apply(.corrections(corrections), from: .settingsWindow))

        XCTAssertEqual(system.decoderVocabulary, ["LocalFlow", "LocalFlow, Talix"])
        XCTAssertEqual(firstDefaults.string(forKey: Settings.Key.customVocabulary), "LocalFlow")
        XCTAssertEqual(firstDefaults.stringArray(forKey: Settings.Key.corrections), ["talex\tTalix"])

        let restored = makeApplication(defaults: firstDefaults, system: FakeLiveSystem())
        XCTAssertEqual(restored.values.customVocabulary, "LocalFlow")
        XCTAssertEqual(restored.values.corrections, corrections)

        let unrelatedDefaults = makeApplication(defaults: secondDefaults, system: FakeLiveSystem())
        XCTAssertEqual(unrelatedDefaults.values.customVocabulary, "")
        XCTAssertEqual(unrelatedDefaults.values.corrections, [])
    }

    private func makeDefaults() -> UserDefaults {
        let name = "LocalFlow.SettingsApplicationVocabularyTests.\(UUID().uuidString)"
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
                refreshDecoderVocabulary: { system.decoderVocabulary.append($0) }
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
