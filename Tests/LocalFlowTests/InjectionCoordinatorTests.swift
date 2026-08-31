import XCTest
@testable import LocalFlow

@MainActor
final class InjectionCoordinatorTests: XCTestCase {
    func testMixedModeStallCancelsHeadAndDeliversLaterResultOnce() async {
        var pasted: [String] = []
        var cancelled: [(sequence: Int, kind: InjectionCoordinator.OperationKind)] = []
        var pendingSamples: [Int: RetainedSamples] = [:]
        var processingCounts: [Int] = []
        let laterPasted = expectation(description: "later dictation pasted")

        let coordinator = InjectionCoordinator(
            stallTimeout: 0,
            onInject: { text in
                pasted.append(text)
                laterPasted.fulfill()
            },
            onCancel: { sequence, kind in
                cancelled.append((sequence, kind))
                pendingSamples.removeValue(forKey: sequence)
            },
            onProcessingCountChange: { count in
                processingCounts.append(count)
            }
        )

        let stalledCommand = coordinator.begin(kind: .command)
        var samples: RetainedSamples? = RetainedSamples()
        weak var retainedSamples = samples
        pendingSamples[stalledCommand] = samples
        samples = nil

        let laterDictation = coordinator.begin(kind: .dictation)
        coordinator.complete(
            laterDictation,
            with: .inject("later dictation")
        )

        await fulfillment(of: [laterPasted], timeout: 0.5)

        XCTAssertEqual(cancelled.count, 1)
        XCTAssertEqual(cancelled.first?.sequence, stalledCommand)
        XCTAssertEqual(cancelled.first?.kind, .command)
        XCTAssertNil(retainedSamples)
        XCTAssertEqual(coordinator.pendingCount, 0)
        XCTAssertEqual(coordinator.processingCount, 0)
        XCTAssertFalse(coordinator.isProcessing)
        XCTAssertEqual(processingCounts, [1, 2, 1, 0])
        XCTAssertEqual(pasted, ["later dictation"])

        coordinator.complete(
            stalledCommand,
            with: .inject("late command")
        )
        await settleAsyncWork()

        XCTAssertEqual(pasted, ["later dictation"])
        XCTAssertEqual(coordinator.processingCount, 0)
    }

    private func settleAsyncWork() async {
        for _ in 0..<100 { await Task.yield() }
    }
}

private final class RetainedSamples {
    let values = [Float](repeating: 0.2, count: 1_024)
}
