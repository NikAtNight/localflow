import XCTest
@testable import LocalFlow

/// Validation that keeps the dictation HUD from restoring to a position on a
/// screen that is no longer connected. Pure geometry — no live NSScreen needed.
final class WaveformOverlayTests: XCTestCase {
    private let size = NSSize(width: 200, height: 60)

    func testOriginFullyInsideAScreenIsVisible() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        XCTAssertTrue(WaveformOverlay.isVisible(origin: NSPoint(x: 100, y: 100),
                                                size: size, on: screens))
    }

    func testPartialOverlapCountsAsVisible() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        // Straddling the right edge — still grabbable, so still "visible".
        XCTAssertTrue(WaveformOverlay.isVisible(origin: NSPoint(x: 1400, y: 100),
                                                size: size, on: screens))
    }

    func testOriginOffAllScreensIsNotVisible() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        XCTAssertFalse(WaveformOverlay.isVisible(origin: NSPoint(x: 5000, y: 5000),
                                                 size: size, on: screens))
    }

    func testNoScreensIsNotVisible() {
        XCTAssertFalse(WaveformOverlay.isVisible(origin: NSPoint(x: 100, y: 100),
                                                 size: size, on: []))
    }

    func testLandsOnSecondScreenIsVisible() {
        let screens = [
            NSRect(x: 0, y: 0, width: 1440, height: 900),
            NSRect(x: 1440, y: 0, width: 2560, height: 1440),
        ]
        XCTAssertTrue(WaveformOverlay.isVisible(origin: NSPoint(x: 3000, y: 700),
                                                size: size, on: screens))
    }
}
