import AppKit
import XCTest
@testable import LocalFlow

@MainActor
final class AppTerminationTests: XCTestCase {
    func testQuitWaitsThroughEveryDictationPhase() {
        // Release clears recording before the asynchronous audio handoff;
        // dispatch clears processing before typing or clipboard restoration.
        let phases: [(Bool, Int, Bool)] = [
            (true, 0, false),
            (false, 1, false),
            (false, 0, true),
            (true, 1, true)
        ]
        for (recording, handoffs, deliveryIsBusy) in phases {
            XCTAssertEqual(AppDelegate.terminationReply(
                isRecording: recording, pendingAudioHandoffs: handoffs,
                deliveryIsBusy: deliveryIsBusy
            ), .terminateCancel)
        }
    }

    func testIdleAppCanQuit() {
        XCTAssertEqual(AppDelegate.terminationReply(
            isRecording: false, pendingAudioHandoffs: 0,
            deliveryIsBusy: false
        ), .terminateNow)
    }
}
