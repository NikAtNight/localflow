import Foundation
import XCTest
@testable import LocalFlow

@MainActor
final class LocalTextModelPolicyFailureAndPrewarmTests: XCTestCase {
    func testCommandThrowsAUserVisibleErrorWhenBothBackendsFail() async {
        let apple = PolicyAppleBackendSpy(isAvailable: true)
        apple.commandResults = [.failure(TestTransportError.appleUnavailable)]
        let ollama = PolicyOllamaBackendSpy()
        ollama.commandResults = [.failure(URLError(.cannotConnectToHost))]
        let policy = LocalTextModelPolicy(apple: apple, ollama: ollama)

        do {
            _ = try await policy.command(
                system: "Shorten the text.",
                prompt: "A long passage",
                model: "gemma3:4b",
                reasoning: .off,
                fallback: "A long passage"
            )
            XCTFail("A transport failure from both command backends must be shown to the user")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Command mode needs Apple Intelligence or a running Ollama server."
            )
        }

        XCTAssertEqual(apple.commandCallCount, 1)
        XCTAssertEqual(ollama.commandCallCount, 1)
        XCTAssertEqual(policy.ollamaReachability, .unreachable)
    }

    func testCommandKeepsTheFallbackWhenBothBackendsProduceInvalidOutput() async throws {
        let apple = PolicyAppleBackendSpy(isAvailable: true)
        apple.commandResults = [.success(.init(text: "   ", finishReason: .complete))]
        let ollama = PolicyOllamaBackendSpy()
        ollama.commandResults = [.success(.init(text: "Partial rewrite", finishReason: .length))]
        let policy = LocalTextModelPolicy(apple: apple, ollama: ollama)

        let result = try await policy.command(
            system: "Shorten the text.",
            prompt: "A long passage",
            model: "gemma3:4b",
            reasoning: .off,
            fallback: "A long passage"
        )

        XCTAssertEqual(result, "A long passage")
        XCTAssertEqual(apple.commandCallCount, 1)
        XCTAssertEqual(ollama.commandCallCount, 1)
    }

    func testCompletedPrewarmForTheSameModelIsSuppressedDuringTheCooldown() async {
        let clock = PolicyTestClock(now: Date(timeIntervalSinceReferenceDate: 0))
        let apple = PolicyAppleBackendSpy(isAvailable: false)
        let ollama = PolicyOllamaBackendSpy()
        let policy = LocalTextModelPolicy(
            apple: apple,
            ollama: ollama,
            now: { clock.now },
            prewarmCooldown: 60
        )

        await policy.prewarm(model: "s1-mini")
        clock.now = Date(timeIntervalSinceReferenceDate: 59)
        await policy.prewarm(model: "s1-mini")

        XCTAssertEqual(ollama.prewarmModels, ["s1-mini"])
    }

    func testCompletedPrewarmRunsAgainAfterItsCooldownExpires() async {
        let clock = PolicyTestClock(now: Date(timeIntervalSinceReferenceDate: 0))
        let apple = PolicyAppleBackendSpy(isAvailable: false)
        let ollama = PolicyOllamaBackendSpy()
        let policy = LocalTextModelPolicy(
            apple: apple,
            ollama: ollama,
            now: { clock.now },
            prewarmCooldown: 60
        )

        await policy.prewarm(model: "s1-mini")
        clock.now = Date(timeIntervalSinceReferenceDate: 60)
        await policy.prewarm(model: "s1-mini")

        XCTAssertEqual(ollama.prewarmModels, ["s1-mini", "s1-mini"])
    }

    func testApplePrewarmForTheSameModelIsSuppressedDuringTheCooldown() async {
        let clock = PolicyTestClock(now: Date(timeIntervalSinceReferenceDate: 0))
        let apple = PolicyAppleBackendSpy(isAvailable: true)
        let ollama = PolicyOllamaBackendSpy()
        let policy = LocalTextModelPolicy(
            apple: apple,
            ollama: ollama,
            now: { clock.now },
            prewarmCooldown: 60
        )

        await policy.prewarm(model: "s1-mini")
        clock.now = Date(timeIntervalSinceReferenceDate: 59)
        await policy.prewarm(model: "s1-mini")

        XCTAssertEqual(apple.prewarmCallCount, 1)
        XCTAssertTrue(ollama.prewarmModels.isEmpty)
    }

    func testApplePrewarmForTheSameModelRunsAgainAfterTheCooldownExpires() async {
        let clock = PolicyTestClock(now: Date(timeIntervalSinceReferenceDate: 0))
        let apple = PolicyAppleBackendSpy(isAvailable: true)
        let ollama = PolicyOllamaBackendSpy()
        let policy = LocalTextModelPolicy(
            apple: apple,
            ollama: ollama,
            now: { clock.now },
            prewarmCooldown: 60
        )

        await policy.prewarm(model: "s1-mini")
        clock.now = Date(timeIntervalSinceReferenceDate: 60)
        await policy.prewarm(model: "s1-mini")

        XCTAssertEqual(apple.prewarmCallCount, 2)
        XCTAssertTrue(ollama.prewarmModels.isEmpty)
    }
}

@MainActor
private final class PolicyAppleBackendSpy: AppleTextModelBackend {
    var isAvailable: Bool
    var commandResults: [Result<TextModelGeneration, Error>] = []
    private(set) var commandCallCount = 0
    private(set) var prewarmCallCount = 0

    init(isAvailable: Bool) {
        self.isAvailable = isAvailable
    }

    func cleanup(_ text: String, profile: AppStyleProfile) async throws -> TextModelGeneration {
        throw TestTransportError.unused
    }

    func command(system: String, prompt: String) async throws -> TextModelGeneration {
        commandCallCount += 1
        return try commandResults.removeFirst().get()
    }

    func prewarm() {
        prewarmCallCount += 1
    }
}

@MainActor
private final class PolicyOllamaBackendSpy: OllamaTextModelBackend {
    var commandResults: [Result<TextModelGeneration, Error>] = []
    private(set) var commandCallCount = 0
    private(set) var prewarmModels: [String] = []

    func cleanup(
        _ text: String,
        model: String,
        profile: AppStyleProfile
    ) async throws -> TextModelGeneration {
        throw TestTransportError.unused
    }

    func command(
        system: String,
        prompt: String,
        model: String,
        reasoning: ReasoningLevel
    ) async throws -> TextModelGeneration {
        commandCallCount += 1
        return try commandResults.removeFirst().get()
    }

    func prewarm(model: String) async {
        prewarmModels.append(model)
    }
}

@MainActor
private final class PolicyTestClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private enum TestTransportError: Error {
    case appleUnavailable
    case unused
}
