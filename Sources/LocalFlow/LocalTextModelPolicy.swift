import Foundation

struct TextModelGeneration: Equatable {
    enum FinishReason: Equatable {
        case complete
        case length
    }

    let text: String
    let finishReason: FinishReason
}

@MainActor
protocol AppleTextModelBackend: AnyObject {
    var isAvailable: Bool { get }

    func cleanup(_ text: String, profile: AppStyleProfile) async throws -> TextModelGeneration
    func command(system: String, prompt: String) async throws -> TextModelGeneration
    func prewarm()
}

@MainActor
protocol OllamaTextModelBackend: AnyObject {
    func cleanup(
        _ text: String,
        model: String,
        profile: AppStyleProfile
    ) async throws -> TextModelGeneration

    func command(
        system: String,
        prompt: String,
        model: String,
        reasoning: ReasoningLevel
    ) async throws -> TextModelGeneration

    func prewarm(model: String) async
    func probe() async throws
    func installedModels() async throws -> [String]
}

extension OllamaTextModelBackend {
    func probe() async throws { throw URLError(.unsupportedURL) }
    func installedModels() async throws -> [String] { throw URLError(.unsupportedURL) }
}

enum OllamaReachability: Equatable {
    case unknown
    case reachable
    case unreachable
}

/// Chooses the local text backend and applies the same failure rules to
/// dictation cleanup and command mode. All mutable backend state lives on the
/// main actor because menu availability reads it synchronously.
@MainActor
final class LocalTextModelPolicy {
    static let shared = LocalTextModelPolicy(
        apple: AppleIntelligenceTextModelBackend(),
        ollama: OllamaLocalTextModelBackend()
    )

    private struct PrewarmOperation {
        let id: UUID
        let task: Task<Void, Never>
    }

    private enum PrewarmKey: Hashable {
        case apple
        case ollama(String)
    }

    private let apple: any AppleTextModelBackend
    private let ollama: any OllamaTextModelBackend
    private let now: @MainActor () -> Date
    private let prewarmCooldown: TimeInterval
    private var prewarmOperations: [PrewarmKey: PrewarmOperation] = [:]
    private var lastPrewarmByKey: [PrewarmKey: Date] = [:]

    private(set) var ollamaReachability = OllamaReachability.unknown

    var isAppleAvailable: Bool {
        apple.isAvailable
    }

    var isCommandAvailable: Bool {
        isAppleAvailable || ollamaReachability == .reachable
    }

    init(
        apple: any AppleTextModelBackend,
        ollama: any OllamaTextModelBackend,
        now: @escaping @MainActor () -> Date = { Date() },
        prewarmCooldown: TimeInterval = 60
    ) {
        self.apple = apple
        self.ollama = ollama
        self.now = now
        self.prewarmCooldown = prewarmCooldown
    }

    func cleanup(
        _ rawText: String,
        model: String,
        profile: AppStyleProfile
    ) async throws -> TranscriptCleanupResult {
        if apple.isAvailable {
            do {
                let generation = try await apple.cleanup(rawText, profile: profile)
                try Task.checkCancellation()
                let result = validatedCleanup(generation, raw: rawText)
                if result.succeeded { return result }
            } catch {
                if isCancellation(error) || Task.isCancelled {
                    throw CancellationError()
                }
                try Task.checkCancellation()
            }
        }

        do {
            return try await ollamaCleanup(rawText, model: model, profile: profile)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return TranscriptCleanupResult(text: rawText, succeeded: false)
        }
    }

    func command(
        system: String,
        prompt: String,
        model: String,
        reasoning: ReasoningLevel,
        fallback: String
    ) async throws -> String {
        if apple.isAvailable {
            do {
                let generation = try await apple.command(system: system, prompt: prompt)
                try Task.checkCancellation()
                if let text = validatedCommand(generation) { return text }
            } catch {
                if isCancellation(error) || Task.isCancelled {
                    throw CancellationError()
                }
                try Task.checkCancellation()
            }
        }

        do {
            return try await ollamaCommand(
                system: system,
                prompt: prompt,
                model: model,
                reasoning: reasoning
            ) ?? fallback
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CommandMode.CommandError.unavailable
        }
    }

    /// Keeps Ollama generation and reachability transitions together after
    /// the preferred Apple backend is unavailable or rejects a result.
    private func ollamaCleanup(
        _ rawText: String,
        model: String,
        profile: AppStyleProfile
    ) async throws -> TranscriptCleanupResult {
        let generation: TextModelGeneration
        do {
            generation = try await ollama.cleanup(rawText, model: model, profile: profile)
            try Task.checkCancellation()
            ollamaReachability = .reachable
        } catch {
            try handleOllamaFailure(error)
        }
        return validatedCleanup(generation, raw: rawText)
    }

    private func ollamaCommand(
        system: String,
        prompt: String,
        model: String,
        reasoning: ReasoningLevel
    ) async throws -> String? {
        let generation: TextModelGeneration
        do {
            generation = try await ollama.command(
                system: system,
                prompt: prompt,
                model: model,
                reasoning: reasoning
            )
            try Task.checkCancellation()
            ollamaReachability = .reachable
        } catch {
            try handleOllamaFailure(error)
        }
        return validatedCommand(generation)
    }

    func prewarm(model: String) async {
        let key = isAppleAvailable ? PrewarmKey.apple : .ollama(model)

        if let operation = prewarmOperations[key] {
            await operation.task.value
            return
        }

        let now = now()
        if let lastPrewarm = lastPrewarmByKey[key],
           now.timeIntervalSince(lastPrewarm) < prewarmCooldown {
            return
        }
        lastPrewarmByKey[key] = now

        if key == .apple {
            apple.prewarm()
            return
        }

        let id = UUID()
        let task = Task { [ollama] in
            await ollama.prewarm(model: model)
        }
        prewarmOperations[key] = PrewarmOperation(id: id, task: task)
        await task.value
        if prewarmOperations[key]?.id == id {
            prewarmOperations[key] = nil
        }
    }

    func probeOllama() async -> Bool {
        do {
            try await ollama.probe()
            try Task.checkCancellation()
            ollamaReachability = .reachable
            return true
        } catch {
            if isCancellation(error) || Task.isCancelled {
                return ollamaReachability == .reachable
            }
            updateReachability(after: error)
            return false
        }
    }

    func installedOllamaModels() async -> [String] {
        do {
            let models = try await ollama.installedModels()
            try Task.checkCancellation()
            ollamaReachability = .reachable
            return models
        } catch {
            if isCancellation(error) || Task.isCancelled { return [] }
            updateReachability(after: error)
            return []
        }
    }

    private func validatedCleanup(
        _ generation: TextModelGeneration,
        raw: String
    ) -> TranscriptCleanupResult {
        guard generation.finishReason == .complete else {
            return TranscriptCleanupResult(text: raw, succeeded: false)
        }
        return TranscriptCleanup.validationResult(generation.text, raw: raw)
    }

    private func validatedCommand(_ generation: TextModelGeneration) -> String? {
        guard generation.finishReason == .complete else { return nil }
        let text = generation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func handleOllamaFailure(_ error: Error) throws -> Never {
        if isCancellation(error) || Task.isCancelled {
            throw CancellationError()
        }
        updateReachability(after: error)
        throw error
    }

    private func updateReachability(after error: Error) {
        if isCancellation(error) { return }
        if error is URLError {
            ollamaReachability = .unreachable
        } else {
            ollamaReachability = .reachable
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        error is CancellationError
            || (error as? URLError)?.code == .cancelled
    }
}
