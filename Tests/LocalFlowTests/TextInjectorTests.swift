import Carbon.HIToolbox
import XCTest
@testable import LocalFlow

final class TextInjectorTests: XCTestCase {
    @MainActor
    func testEmptyInputReportsFailureOnceWithoutDispatching() {
        var results: [TextInjector.InjectionResult] = []
        var dispatchCount = 0

        TextInjector.inject("", onDispatch: { dispatchCount += 1 }) {
            results.append($0)
        }

        XCTAssertEqual(results, [.dispatchFailed])
        XCTAssertEqual(dispatchCount, 0)
    }

    @MainActor
    func testDeliveryWarningsFitMenuWithoutTruncation() throws {
        XCTAssertNil(TextInjector.InjectionResult.dispatched.userFacingIssue)
        for result in [TextInjector.InjectionResult.clipboardChanged, .dispatchFailed] {
            let issue = try XCTUnwrap(result.userFacingIssue)
            XCTAssertEqual(issue.menuSummary, issue.summary)
            XCTAssertFalse(issue.details.isEmpty)
        }
    }

    // MARK: - Clipboard restore around copySelection

    /// Points TextInjector at a private pasteboard and a fake target app. On
    /// Cmd-C the fake app copies `selection` (nothing when nil), after
    /// `copyDelay` if one is given; Cmd-V is a no-op.
    @MainActor
    private func installFakes(
        selection: @escaping () -> String?,
        copyDelay: TimeInterval? = nil,
        restoreDelay: TimeInterval = 0.6
    ) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("LocalFlowTests-\(UUID().uuidString)"))
        let original = (TextInjector.pasteboard, TextInjector.postKeystroke,
                        TextInjector.isSecureInputEnabled, TextInjector.restoreDelay)
        TextInjector.pasteboard = pasteboard
        TextInjector.isSecureInputEnabled = { false }
        TextInjector.restoreDelay = restoreDelay
        TextInjector.postKeystroke = { key, _ in
            guard Int(key) == kVK_ANSI_C, let text = selection() else { return true }
            let copy = {
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
            if let copyDelay {
                DispatchQueue.main.asyncAfter(deadline: .now() + copyDelay, execute: copy)
            } else {
                copy()
            }
            return true
        }
        addTeardownBlock { @MainActor in
            (TextInjector.pasteboard, TextInjector.postKeystroke,
             TextInjector.isSecureInputEnabled, TextInjector.restoreDelay) = original
            pasteboard.releaseGlobally()
        }
        return pasteboard
    }

    @MainActor
    private func setClipboard(_ pasteboard: NSPasteboard, _ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// User clipboard U, inject A, copySelection inside the restore window,
    /// then let the restore fire.
    @MainActor
    private func injectThenCopySelection(
        selection: String?,
        copyDelay: TimeInterval? = nil,
        restoreDelay: TimeInterval = 0.6,
        betweenCopyAndRestore: ((NSPasteboard) -> Void)? = nil
    ) -> (copied: String?, result: TextInjector.InjectionResult?, clipboard: String?) {
        let pasteboard = installFakes(selection: { selection }, copyDelay: copyDelay, restoreDelay: restoreDelay)
        setClipboard(pasteboard, "user clipboard")

        let resolved = expectation(description: "paste completion")
        var result: TextInjector.InjectionResult?
        TextInjector.inject("dictated") {
            result = $0
            resolved.fulfill()
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated")

        let copiedExpectation = expectation(description: "copySelection completion")
        var copied: String?
        TextInjector.copySelection {
            copied = $0
            copiedExpectation.fulfill()
        }
        wait(for: [copiedExpectation], timeout: 2)
        betweenCopyAndRestore?(pasteboard)
        wait(for: [resolved], timeout: 3)
        return (copied, result, pasteboard.string(forType: .string))
    }

    @MainActor
    func testCopySelectionDuringPasteWindowKeepsUserClipboard() {
        let outcome = injectThenCopySelection(selection: "selected text")

        XCTAssertEqual(outcome.copied, "selected text")
        XCTAssertEqual(outcome.clipboard, "user clipboard")
        XCTAssertEqual(outcome.result, .dispatched)
    }

    /// Nothing selected polls for ~300ms, so a 50ms restore always comes due
    /// mid-poll. It must wait for the round trip, not hand the user's
    /// clipboard back as the "selection".
    @MainActor
    func testCopySelectionWithNothingSelectedHoldsRestoreDueMidPoll() {
        let outcome = injectThenCopySelection(selection: nil, restoreDelay: 0.05)

        XCTAssertNil(outcome.copied)
        XCTAssertEqual(outcome.clipboard, "user clipboard")
        XCTAssertEqual(outcome.result, .dispatched)
    }

    /// The target app answers Cmd-C after the restore came due. The restore
    /// must not mistake the copy for the user's and drop their clipboard.
    @MainActor
    func testSlowCopyHoldsRestoreDueMidPoll() {
        let outcome = injectThenCopySelection(selection: "selected text", copyDelay: 0.15, restoreDelay: 0.05)

        XCTAssertEqual(outcome.copied, "selected text")
        XCTAssertEqual(outcome.clipboard, "user clipboard")
        XCTAssertEqual(outcome.result, .dispatched)
    }

    /// A non-text selection (an image) moves changeCount without ending the
    /// poll, so the restore comes due after the copy landed. It must not
    /// read the copy as the user's and drop their clipboard.
    @MainActor
    func testNonTextCopyHoldsRestoreDueMidPoll() {
        let pasteboard = installFakes(selection: { nil }, restoreDelay: 0.05)
        TextInjector.postKeystroke = { key, _ in
            if Int(key) == kVK_ANSI_C {
                pasteboard.clearContents()
                pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
            }
            return true
        }
        setClipboard(pasteboard, "user clipboard")
        let resolved = expectation(description: "paste completion")
        var result: TextInjector.InjectionResult?
        TextInjector.inject("dictated") {
            result = $0
            resolved.fulfill()
        }

        let copiedExpectation = expectation(description: "copySelection completion")
        var copied: String? = "unset"
        TextInjector.copySelection {
            copied = $0
            copiedExpectation.fulfill()
        }
        wait(for: [copiedExpectation, resolved], timeout: 3, enforceOrder: true)

        XCTAssertNil(copied)
        XCTAssertEqual(pasteboard.string(forType: .string), "user clipboard")
        XCTAssertEqual(result, .dispatched)
    }

    @MainActor
    func testFailedCopyKeystrokeLeavesPendingRestoreInPlace() {
        let pasteboard = installFakes(selection: { nil }, restoreDelay: 0.05)
        TextInjector.postKeystroke = { key, _ in Int(key) != kVK_ANSI_C }
        setClipboard(pasteboard, "user clipboard")
        let resolved = expectation(description: "paste completion")
        var result: TextInjector.InjectionResult?
        TextInjector.inject("dictated") {
            result = $0
            resolved.fulfill()
        }

        var copied: String? = "unset"
        TextInjector.copySelection { copied = $0 }
        wait(for: [resolved], timeout: 2)

        XCTAssertNil(copied)
        XCTAssertEqual(pasteboard.string(forType: .string), "user clipboard")
        XCTAssertEqual(result, .dispatched)
    }

    @MainActor
    func testUserCopyAfterCopySelectionStillWinsOverRestore() {
        let outcome = injectThenCopySelection(selection: "selected text") { pasteboard in
            self.setClipboard(pasteboard, "user copied later")
        }

        XCTAssertEqual(outcome.clipboard, "user copied later")
        XCTAssertEqual(outcome.result, .clipboardChanged)
    }

    @MainActor
    func testUserCopyBeforeCopySelectionStillWinsOverRestore() {
        let pasteboard = installFakes(selection: { "selected text" })
        setClipboard(pasteboard, "user clipboard")
        let resolved = expectation(description: "paste completion")
        var result: TextInjector.InjectionResult?
        TextInjector.inject("dictated") {
            result = $0
            resolved.fulfill()
        }
        setClipboard(pasteboard, "user copied later")

        let copiedExpectation = expectation(description: "copySelection completion")
        TextInjector.copySelection { _ in copiedExpectation.fulfill() }
        wait(for: [copiedExpectation, resolved], timeout: 3)

        XCTAssertEqual(pasteboard.string(forType: .string), "user copied later")
        XCTAssertEqual(result, .clipboardChanged)
    }

    @MainActor
    func testCopySelectionWithoutPendingPastePutsClipboardBack() {
        let pasteboard = installFakes(selection: { "selected text" })
        setClipboard(pasteboard, "user clipboard")

        let copiedExpectation = expectation(description: "copySelection completion")
        var copied: String?
        TextInjector.copySelection {
            copied = $0
            copiedExpectation.fulfill()
        }
        wait(for: [copiedExpectation], timeout: 2)

        XCTAssertEqual(copied, "selected text")
        XCTAssertEqual(pasteboard.string(forType: .string), "user clipboard")
    }

    func testUTF16ChunksRoundTripWithoutSplittingSurrogatePairs() async {
        // Nine ASCII units followed by an emoji puts the high surrogate exactly
        // at a naive ten-unit boundary.
        let text = "123456789😀tail"
        let chunks = await TextInjector.utf16Chunks(text, maxUnits: 10)

        XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 10 })
        for chunk in chunks {
            XCTAssertFalse((0xD800 ... 0xDBFF).contains(chunk.last!))
            XCTAssertFalse((0xDC00 ... 0xDFFF).contains(chunk.first!))
        }
    }

    func testUTF16ChunksHandlesEmptyAndASCIIText() async {
        let empty = await TextInjector.utf16Chunks("")
        let ascii = await TextInjector.utf16Chunks("abcdefgh", maxUnits: 3)

        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(ascii.map(\.count), [3, 3, 2])
        XCTAssertEqual(ascii.flatMap { $0 }, Array("abcdefgh".utf16))
    }
}
