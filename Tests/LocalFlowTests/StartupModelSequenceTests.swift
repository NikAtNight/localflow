import XCTest
@testable import LocalFlow

final class StartupModelSequenceTests: XCTestCase {
    func testApplicationRunLoopUsesSynchronousEntryPoint() {
        let entryPoint: () -> Void = LocalFlowMain.main
        withExtendedLifetime(entryPoint) {}
    }

    func testWhisperLoadDoesNotWaitForStalledHotkeyStartup() async throws {
        let stalledHotkey = AsyncGate()
        let hotkeyTask = Task { await stalledHotkey.wait() }
        let loadStarted = expectation(description: "Whisper load started")

        try await StartupModelSequence.run(
            loadWhisper: { loadStarted.fulfill() },
            prewarmCleanup: {}
        )

        await fulfillment(of: [loadStarted], timeout: 1)
        await stalledHotkey.open()
        await hotkeyTask.value
    }

    func testStalledWhisperLoadReportsTimeoutAndRecovers() async {
        let loadStarted = expectation(description: "Whisper load started")
        let loadReleased = expectation(description: "Stalled Whisper load released")
        let stalledLoad = AsyncGate()
        let deadline = AsyncGate()
        let recorder = StartupEventRecorder()

        let task = Task {
            try await StartupModelSequence.run(
                loadWhisper: {
                    loadStarted.fulfill()
                    await stalledLoad.wait()
                    loadReleased.fulfill()
                },
                prewarmCleanup: { await recorder.append("prewarm") },
                waitForDeadline: { await deadline.wait() },
                onTimeout: { await recorder.append("timeout-recovered") }
            )
        }

        await fulfillment(of: [loadStarted], timeout: 1)
        await deadline.open()

        do {
            try await task.value
            XCTFail("A stalled Whisper load must time out")
        } catch {
            XCTAssertEqual(error as? StartupModelSequence.Error, .timedOut)
        }

        let events = await recorder.snapshot()
        XCTAssertEqual(events, ["timeout-recovered"])
        await stalledLoad.open()
        await fulfillment(of: [loadReleased], timeout: 1)
    }

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
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
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
