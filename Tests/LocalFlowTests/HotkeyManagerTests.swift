import CoreGraphics
import XCTest
@testable import LocalFlow

/// The push-to-talk key enum. Keycodes are matched against live flagsChanged
/// events, so a silent change here would break hotkey detection.
final class HotkeyManagerTests: XCTestCase {

    func testKeyCodesAreStable() {
        XCTAssertEqual(HotkeyManager.Key.rightOption.keyCode, 61)
        XCTAssertEqual(HotkeyManager.Key.rightCommand.keyCode, 54)
        XCTAssertEqual(HotkeyManager.Key.fn.keyCode, 63)
    }

    func testRawValuesRoundTrip() {
        for key in HotkeyManager.Key.allCases {
            XCTAssertEqual(HotkeyManager.Key(rawValue: key.rawValue), key)
        }
    }

    func testAllCasesCovered() {
        XCTAssertEqual(HotkeyManager.Key.allCases.count, 3)
    }

    func testLabelsAreNonEmpty() {
        for key in HotkeyManager.Key.allCases {
            XCTAssertFalse(key.label.isEmpty)
        }
    }

    func testDeviceSpecificFlagMeansPressed() {
        for key in HotkeyManager.Key.allCases {
            XCTAssertTrue(HotkeyManager.pressedState(
                flags: key.deviceMask.union(key.genericMask), key: key, wasDown: false
            ))
            XCTAssertTrue(HotkeyManager.pressedState(
                flags: key.deviceMask.union(key.genericMask), key: key, wasDown: true
            ))
        }
    }

    func testMissingGenericFlagMeansReleased() {
        for key in HotkeyManager.Key.allCases {
            XCTAssertFalse(HotkeyManager.pressedState(flags: [], key: key, wasDown: false))
            XCTAssertFalse(HotkeyManager.pressedState(flags: [], key: key, wasDown: true))
        }
    }

    func testGenericOnlyModifierAlternatesForRemappedKeys() {
        for key in [HotkeyManager.Key.rightOption, .rightCommand] {
            XCTAssertTrue(HotkeyManager.pressedState(
                flags: key.genericMask, key: key, wasDown: false
            ))
            XCTAssertFalse(HotkeyManager.pressedState(
                flags: key.genericMask, key: key, wasDown: true
            ))
        }
    }
}
