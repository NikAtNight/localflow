import Foundation
import XCTest
@testable import LocalFlow

@MainActor
final class LocalTextModelPolicyTests: XCTestCase {
    func testCleanupPrefersAppleWithoutCallingOllama() async throws {
        let apple = AppleBackendSpy(isAvailable: true)
        apple.cleanupResults = [.success(.init(text: "Cleaned by Apple.", finishReason: .complete))]
        let ollama = OllamaBackendSpy()
        let policy = LocalTextModelPolicy(apple: apple, ollama: ollama)

        let result = try await policy.cleanup(
            "cleaned by apple",
            model: "s1-mini",
            profile: .general
        )

        XCTAssertEqual(result.text, "Cleaned by Apple.")
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(apple.cleanupCallCount, 1)
        XCTAssertEqual(ollama.cleanupCallCount, 0)
        XCTAssertEqual(policy.ollamaReachability, .unknown)
    }

    func testCleanupUsesOllamaWhenAppleIsUnavailable() async throws {
        let apple = AppleBackendSpy(isAvailable: false)
        let ollama = OllamaBackendSpy()
        ollama.cleanupResults = [.success(.init(text: "Cleaned by Ollama.", finishReason: .complete))]
        let policy = LocalTextModelPolicy(apple: apple, ollama: ollama)

        let result = try await policy.cleanup(
            "cleaned by ollama",
            model: "s1-mini",
            profile: .email
        )

        XCTAssertEqual(result.text, "Cleaned by Ollama.")
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(apple.cleanupCallCount, 0)
        XCTAssertEqual(ollama.cleanupCallCount, 1)
        XCTAssertEqual(ollama.cleanupRequests.first?.model, "s1-mini")
        XCTAssertEqual(ollama.cleanupRequests.first?.profile, .email)
        XCTAssertEqual(policy.ollamaReachability, .reachable)
    }

    func testCleanupFallsBackToOllamaWhenAppleFailsAtRuntime() async throws {
        let apple = AppleBackendSpy(isAvailable: true)
        apple.cleanupResults = [.failure(TestError.appleFailed)]
        let ollama = OllamaBackendSpy()
        ollama.cleanupResults = [.success(.init(text: "Fallback result.", finishReason: .complete))]
        let policy = LocalTextModelPolicy(apple: apple, ollama: ollama)

        let result = try await policy.cleanup(
            "fallback result",
            model: "gemma3:4b",
            profile: .workChat
        )

        XCTAssertEqual(result.text, "Fallback result.")
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(apple.cleanupCallCount, 1)
        XCTAssertEqual(ollama.cleanupCallCount, 1)
    }

    func testInvalidCleanupOutputReturnsTheRawTranscriptAsFailure() async throws {
        let apple = AppleBackendSpy(isAvailable: false)
        let ollama = OllamaBackendSpy()
        ollama.cleanupResults = [.success(.init(text: "<think>\ninternal reasoning", finishReason: .complete))]
        let policy = LocalTextModelPolicy(apple: apple, ollama: ollama)

        let result = try await policy.cleanup("raw words", model: "s1-mini", profile: .general)

        XCTAssertEqual(result.text, "raw words")
        XCTAssertFalse(result.succeeded)
    }

    func testUnchangedCleanupOutputIsStillSuccessful() async throws {
        let apple = AppleBackendSpy(isAvailable: false)
        let ollama = OllamaBackendSpy()
        ollama.cleanupResults = [.success(.init(text: "Already clean.", finishReason: .complete))]
        let policy = LocalTextModelPolicy(apple: apple, ollama: ollama)

        let result = try await policy.cleanup("Already clean.", model: "s1-mini", profile: .general)

        XCTAssertEqual(result.text, "Already clean.")
        XCTAssertTrue(result.succeeded)
    }

    func testLengthLimitedCleanupReturnsTheRawTranscriptAsFailure() async throws {
        let apple = AppleBackendSpy(isAvailable: false)
        let ollama = OllamaBackendSpy()
        ollama.cleanupResults = [.success(.init(text: "Partial", finishReason: .length))]
        let policy = LocalTextModelPolicy(apple: apple, ollama: ollama)

        let result = try await policy.cleanup("Complete raw text", model: "s1-mini", profile: .general)

        XCTAssertEqual(result.text, "Complete raw text")
        XCTAssertFalse(result.succeeded)
    }

    func testCommandUsesOllamaWhenAppleIsUnavailable() async throws {
        let apple = AppleBackendSpy(isAvailable: false)
        let ollama = OllamaBackendSpy()
        ollama.commandResults = [.success(.init(text: "  Shortened text.  ", finishReason: .complete))]
        let policy = LocalTextModelPolicy(apple: apple, ollama: ollama)

        let result = try await policy.command(
            system: "Shorten the text.",
            prompt: "A long passage",
            model: "gemma3:4b",
            reasoning: .off,
            fallback: "A long passage"
        )

        XCTAssertEqual(result, "Shortened text.")
        XCTAssertEqual(ollama.commandRequests.first?.model, "gemma3:4b")
        XCTAssertEqual(ollama.commandRequests.first?.reasoning, .off)
        XCTAssertEqual(policy.ollamaReachability, .reachable)
    }

    func testEmptyOrLengthLimitedCommandKeepsTheFallbackText() async throws {
        let apple = AppleBackendSpy(isAvailable: false)
        let ollama = OllamaBackendSpy()
        ollama.commandResults = [
            .success(.init(text: "   ", finishReason: .complete)),
            .success(.init(text: "Partial rewrite", finishReason: .length)),
        ]
        let policy = LocalTextModelPolicy(apple: apple, ollama: ollama)

        let emptyResult = try await policy.command(
            system: "Edit", prompt: "Text", model: "gemma3:4b", reasoning: .off, fallback: "Text"
        )
        let lengthResult = try await policy.command(
            system: "Edit", prompt: "Text", model: "gemma3:4b", reasoning: .off, fallback: "Text"
        )

        XCTAssertEqual(emptyResult, "Text")
        XCTAssertEqual(lengthResult, "Text")
    }

    func testTransportFailureMarksOllamaUnreachableAndKeepsRawText() async throws {
        let apple = AppleBackendSpy(isAvailable: false)
        let ollama = OllamaBackendSpy()
        ollama.cleanupResults = [.failure(URLError(.cannotConnectToHost))]
        let policy = LocalTextModelPolicy(apple: apple, ollama: ollama)

        let result = try await policy.cleanup("raw text", model: "s1-mini", profile: .general)

        XCTAssertEqual(result.text, "raw text")
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(policy.ollamaReachability, .unreachable)
    }

    func testHTTPFailureProvesOllamaIsReachableAndKeepsRawText() async throws {
        let apple = AppleBackendSpy(isAvailable: false)
        let ollama = OllamaBackendSpy()
        ollama.cleanupResults = [.failure(OllamaClientError.httpStatus(503))]
        let policy = LocalTextModelPolicy(apple: apple, ollama: ollama)

        let result = try await policy.cleanup("raw text", model: "s1-mini", profile: .general)

        XCTAssertEqual(result.text, "raw text")
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(policy.ollamaReachability, .reachable)
    }

    func testReachabilityCanRecoverAfterATransportFailure() async throws {
        let apple = AppleBackendSpy(isAvailable: false)
        let ollama = OllamaBackendSpy()
        ollama.cleanupResults = [
            .failure(URLError(.timedOut)),
            .success(.init(text: "Recovered.", finishReason: .complete)),
        ]
        let policy = LocalTextModelPolicy(apple: apple, ollama: ollama)

        _ = try await policy.cleanup("first", model: "s1-mini", profile: .general)
        XCTAssertEqual(policy.ollamaReachability, .unreachable)

        _ = try await policy.cleanup("second", model: "s1-mini", profile: .general)
        XCTAssertEqual(policy.ollamaReachability, .reachable)
    }

    func testCancellationPropagatesWithoutChangingReachability() async {
        let apple = AppleBackendSpy(isAvailable: false)
        let ollama = OllamaBackendSpy()
        ollama.cleanupResults = [
            .success(.init(text: "Initial success.", finishReason: .complete)),
        ]
        let policy = LocalTextModelPolicy(apple: apple, ollama: ollama)
        _ = try? await policy.cleanup("initial", model: "s1-mini", profile: .general)
        XCTAssertEqual(policy.ollamaReachability, .reachable)

        let started = expectation(description: "Ollama cleanup started")
        ollama.cleanupHandler = { _ in
            started.fulfill()
            try await Task.sleep(for: .seconds(30))
            return .init(text: "too late", finishReason: .complete)
        }

        let task = Task { @MainActor in
            try await policy.cleanup("raw text", model: "s1-mini", profile: .general)
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancellation must leave the pipeline instead of returning raw text")
        } catch is CancellationError {
            XCTAssertEqual(policy.ollamaReachability, .reachable)
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testConcurrentPrewarmsForTheSameModelAreCoalesced() async {
        let firstPrewarmStarted = expectation(description: "First prewarm started")
        let releasePrewarm = AsyncGate()
        let apple = AppleBackendSpy(isAvailable: false)
        let ollama = OllamaBackendSpy()
        ollama.prewarmHandler = { _ in
            firstPrewarmStarted.fulfill()
            await releasePrewarm.wait()
        }
        let policy = LocalTextModelPolicy(apple: apple, ollama: ollama)

        async let first: Void = policy.prewarm(model: "s1-mini")
        await fulfillment(of: [firstPrewarmStarted], timeout: 1)
        async let duplicate: Void = policy.prewarm(model: "s1-mini")
        await Task.yield()

        XCTAssertEqual(ollama.prewarmModels, ["s1-mini"])
        await releasePrewarm.open()
        _ = await (first, duplicate)
    }

    func testDifferentModelsHaveIndependentPrewarms() async {
        let apple = AppleBackendSpy(isAvailable: false)
        let ollama = OllamaBackendSpy()
        let policy = LocalTextModelPolicy(apple: apple, ollama: ollama)

        await policy.prewarm(model: "s1-mini")
        await policy.prewarm(model: "gemma3:4b")

        XCTAssertEqual(ollama.prewarmModels, ["s1-mini", "gemma3:4b"])
    }
}

@MainActor
final class OllamaClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testGenerateUsesTheOllamaEndpointAndJSONProtocol() async throws {
        let client = makeClient { request in
            URLProtocolStub.record(request)
            return Self.response(
                for: request,
                status: 200,
                json: #"{"response":"Cleaned.","done_reason":"stop"}"#
            )
        }
        let body = OllamaCleaner.generateRequest("raw", model: "s1-mini", profile: .email)

        let output = try await client.generate(body)

        XCTAssertEqual(output, .init(text: "Cleaned.", finishReason: .complete))
        let request = try XCTUnwrap(URLProtocolStub.recordedRequests.first)
        XCTAssertEqual(request.url?.path, "/api/generate")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 45, accuracy: 0.001)

        let json = try Self.bodyData(from: request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "s1-mini")
        XCTAssertEqual(object["keep_alive"] as? String, "30m")
        XCTAssertEqual(object["stream"] as? Bool, false)
        XCTAssertEqual(object["think"] as? Bool, false)
        XCTAssertNotNil(object["system"] as? String)
        XCTAssertNotNil(object["prompt"] as? String)
        XCTAssertNotNil(object["options"] as? [String: Any])
    }

    func testGenerateSurfacesHTTPStatusErrors() async throws {
        let client = makeClient { request in
            Self.response(for: request, status: 503, json: #"{"error":"loading"}"#)
        }
        let body = OllamaCleaner.generateRequest("raw", model: "s1-mini", profile: .general)

        do {
            _ = try await client.generate(body)
            XCTFail("Expected the non-200 response to fail")
        } catch let error as OllamaClientError {
            XCTAssertEqual(error, .httpStatus(503))
        }
    }

    func testProbeUsesVersionEndpointAndTracksRecovery() async {
        var attempts = 0
        let client = makeClient { request in
            attempts += 1
            URLProtocolStub.record(request)
            if attempts == 1 { throw URLError(.cannotConnectToHost) }
            return Self.response(for: request, status: 200, json: #"{"version":"0.11.0"}"#)
        }

        let unavailable = await client.isAvailable()
        let recovered = await client.isAvailable()
        XCTAssertFalse(unavailable)
        XCTAssertTrue(recovered)
        XCTAssertEqual(URLProtocolStub.recordedRequests.map(\.url?.path), ["/api/version", "/api/version"])
        XCTAssertEqual(URLProtocolStub.recordedRequests.map(\.timeoutInterval), [2, 2])
    }

    func testGeneratePropagatesTimeoutAndCancellation() async {
        var errors = [URLError(.timedOut), URLError(.cancelled)]
        let client = makeClient { _ in throw errors.removeFirst() }
        let body = OllamaCleaner.generateRequest("raw", model: "s1-mini", profile: .general)

        for expectedCode in [URLError.timedOut, .cancelled] {
            do {
                _ = try await client.generate(body)
                XCTFail("Expected \(expectedCode)")
            } catch let error as URLError {
                XCTAssertEqual(error.code, expectedCode)
            } catch {
                XCTFail("Expected URLError, got \(error)")
            }
        }
    }

    private func makeClient(
        handler: @escaping (URLRequest) throws -> URLProtocolStub.StubbedResponse
    ) -> OllamaClient {
        URLProtocolStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 120
        return OllamaClient(
            baseURL: URL(string: "http://localhost:11434")!,
            session: URLSession(configuration: configuration)
        )
    }

    private static func response(
        for request: URLRequest,
        status: Int,
        json: String
    ) -> URLProtocolStub.StubbedResponse {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }

    private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }

        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                stream.read(
                    bytes.bindMemory(to: UInt8.self).baseAddress!,
                    maxLength: bytes.count
                )
            }
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { return body }
            body.append(contentsOf: buffer.prefix(count))
        }
    }
}

@MainActor
private final class AppleBackendSpy: AppleTextModelBackend {
    var isAvailable: Bool
    var cleanupResults: [Result<TextModelGeneration, Error>] = []
    var commandResults: [Result<TextModelGeneration, Error>] = []
    private(set) var cleanupCallCount = 0
    private(set) var commandCallCount = 0
    private(set) var prewarmCallCount = 0

    init(isAvailable: Bool) {
        self.isAvailable = isAvailable
    }

    func cleanup(_ text: String, profile: AppStyleProfile) async throws -> TextModelGeneration {
        cleanupCallCount += 1
        return try cleanupResults.removeFirst().get()
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
private final class OllamaBackendSpy: OllamaTextModelBackend {
    struct CleanupRequest: Equatable {
        let text: String
        let model: String
        let profile: AppStyleProfile
    }

    struct CommandRequest: Equatable {
        let system: String
        let prompt: String
        let model: String
        let reasoning: ReasoningLevel
    }

    var cleanupResults: [Result<TextModelGeneration, Error>] = []
    var commandResults: [Result<TextModelGeneration, Error>] = []
    var cleanupHandler: ((CleanupRequest) async throws -> TextModelGeneration)?
    var prewarmHandler: ((String) async -> Void)?
    private(set) var cleanupRequests: [CleanupRequest] = []
    private(set) var commandRequests: [CommandRequest] = []
    private(set) var prewarmModels: [String] = []
    var cleanupCallCount: Int { cleanupRequests.count }

    func cleanup(
        _ text: String,
        model: String,
        profile: AppStyleProfile
    ) async throws -> TextModelGeneration {
        let request = CleanupRequest(text: text, model: model, profile: profile)
        cleanupRequests.append(request)
        if let cleanupHandler { return try await cleanupHandler(request) }
        return try cleanupResults.removeFirst().get()
    }

    func command(
        system: String,
        prompt: String,
        model: String,
        reasoning: ReasoningLevel
    ) async throws -> TextModelGeneration {
        commandRequests.append(.init(
            system: system,
            prompt: prompt,
            model: model,
            reasoning: reasoning
        ))
        return try commandResults.removeFirst().get()
    }

    func prewarm(model: String) async {
        prewarmModels.append(model)
        await prewarmHandler?(model)
    }
}

private actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

private enum TestError: Error {
    case appleFailed
}

private final class URLProtocolStub: URLProtocol {
    typealias StubbedResponse = (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) throws -> StubbedResponse)?
    private static var storedRequests: [URLRequest] = []

    static var handler: ((URLRequest) throws -> StubbedResponse)? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }

    static var recordedRequests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    static func record(_ request: URLRequest) {
        lock.withLock { storedRequests.append(request) }
    }

    static func reset() {
        lock.withLock {
            storedHandler = nil
            storedRequests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
