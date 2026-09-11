import Foundation
import XCTest
@testable import LocalFlow

@MainActor
final class SettingsModelCorrectionTests: XCTestCase {
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

    func testReplacingCorrectionAppliesOnlyTheFinalCorrectionsValue() {
        let defaults = makeDefaults()
        defaults.set("LocalFlow", forKey: Settings.Key.customVocabulary)
        defaults.set(["talex\tOld Talix"], forKey: Settings.Key.corrections)
        let system = FakeLiveSystem()
        let application = makeApplication(defaults: defaults, system: system)
        let model = SettingsModel(settingsApplication: application)

        model.addCorrection(wrong: "talex", right: "Talix")

        XCTAssertEqual(
            application.values.corrections,
            [SettingsApplication.Correction(wrong: "talex", right: "Talix")]
        )
        XCTAssertEqual(defaults.stringArray(forKey: Settings.Key.corrections), ["talex\tTalix"])
        XCTAssertEqual(system.decoderVocabulary, ["LocalFlow, Talix"])
    }

    func testSynchronizingAnUnrelatedChangePreservesCorrectionIdentityAndRemoval() {
        let defaults = makeDefaults()
        defaults.set("LocalFlow", forKey: Settings.Key.customVocabulary)
        defaults.set(["talex\tTalix"], forKey: Settings.Key.corrections)
        let system = FakeLiveSystem()
        let application = makeApplication(defaults: defaults, system: system)
        let model = SettingsModel(settingsApplication: application)
        let correctionID = model.corrections[0].id

        model.automaticUpdates = false

        XCTAssertEqual(model.corrections[0].id, correctionID)
        XCTAssertTrue(system.decoderVocabulary.isEmpty)

        model.removeCorrection(correctionID)

        XCTAssertTrue(model.corrections.isEmpty)
        XCTAssertTrue(application.values.corrections.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: Settings.Key.corrections), [])
        XCTAssertEqual(system.decoderVocabulary, ["LocalFlow"])
    }

    private func makeDefaults() -> UserDefaults {
        let name = "LocalFlow.SettingsModelCorrectionTests.\(UUID().uuidString)"
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
}
