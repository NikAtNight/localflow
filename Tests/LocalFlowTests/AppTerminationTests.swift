import AppKit
import XCTest
@testable import LocalFlow

@MainActor
final class AppTerminationTests: XCTestCase {
    func testQuitWaitsThroughEveryDictationPhase() {
        // Release clears recording before the asynchronous audio handoff;
        // dispatch clears processing before typing or clipboard restoration.
        let phases: [(Bool, Int, Int, Int)] = [
            (true, 0, 0, 0),
            (false, 1, 0, 0),
            (false, 0, 1, 0),
            (false, 0, 0, 1),
            (true, 1, 2, 1)
        ]
        for (recording, handoffs, processing, injections) in phases {
            XCTAssertEqual(AppDelegate.terminationReply(
                isRecording: recording, pendingAudioHandoffs: handoffs,
                processingCount: processing, pendingInjections: injections
            ), .terminateCancel)
        }
    }

    func testIdleAppCanQuit() {
        XCTAssertEqual(AppDelegate.terminationReply(
            isRecording: false, pendingAudioHandoffs: 0,
            processingCount: 0, pendingInjections: 0
        ), .terminateNow)
    }
}
