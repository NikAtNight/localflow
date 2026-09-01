import XCTest
@testable import LocalFlow

final class StartupModelSequenceTests: XCTestCase {
    func testCleanupPrewarmWaitsUntilWhisperLoadFinishes() async throws {
        let loadStarted = expectation(description: "Whisper load started")
        let allowLoadToFinish = AsyncGate()
        let recorder = StartupEventRecorder()

        let task = Task {
            try await StartupModelSequence.run(
                loadWhisper: {
                    await recorder.append("load-started")
                    loadStarted.fulfill()
                    await allowLoadToFinish.wait()
                    await recorder.append("load-finished")
                },
                onWhisperLoaded: { await recorder.append("ready") },
                prewarmCleanup: { await recorder.append("prewarm") }
            )
        }

        await fulfillment(of: [loadStarted], timeout: 1)
        let pendingEvents = await recorder.snapshot()
        XCTAssertEqual(pendingEvents, ["load-started"])
        await allowLoadToFinish.open()
        try await task.value
        let completedEvents = await recorder.snapshot()
        XCTAssertEqual(completedEvents, ["load-started", "load-finished", "ready", "prewarm"])
    }

    func testCleanupPrewarmDoesNotRunWhenWhisperLoadFails() async {
        let recorder = StartupEventRecorder()

        do {
            try await StartupModelSequence.run(
                loadWhisper: { throw StartupSequenceTestError.loadFailed },
                prewarmCleanup: { await recorder.append("prewarm") }
            )
            XCTFail("The Whisper load failure must propagate")
        } catch {
            XCTAssertEqual(error as? StartupSequenceTestError, .loadFailed)
        }

        let events = await recorder.snapshot()
        XCTAssertEqual(events, [])
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private actor StartupEventRecorder {
    private var events: [String] = []
    func append(_ event: String) { events.append(event) }
    func snapshot() -> [String] { events }
}

private enum StartupSequenceTestError: Error, Equatable {
    case loadFailed
}
