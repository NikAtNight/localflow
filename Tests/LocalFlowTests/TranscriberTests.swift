import XCTest
@testable import LocalFlow

/// Pure-text logic that recently misfired: Whisper marker stripping and the
/// canonical-hallucination match used to drop invented filler for silent audio.
final class TranscriberTests: XCTestCase {

    func testInferenceGateSerializesWaitersInFIFOOrder() async {
        let gate = TranscriptionGate()
        let order = CompletionOrder()
        await gate.acquire()

        let first = Task {
            await gate.acquire()
            await order.append(1)
            await gate.release()
        }
        let firstQueued = await waitForWaiterCount(1, on: gate)
        XCTAssertTrue(firstQueued)

        let second = Task {
            await gate.acquire()
            await order.append(2)
            await gate.release()
        }
        let secondQueued = await waitForWaiterCount(2, on: gate)
        XCTAssertTrue(secondQueued)

        await gate.release()
        await first.value
        await second.value
        let completed = await order.values
        XCTAssertEqual(completed, [1, 2])
    }

    private func waitForWaiterCount(_ count: Int, on gate: TranscriptionGate) async -> Bool {
        for _ in 0..<10_000 {
            if await gate.waitingCount == count { return true }
            await Task.yield()
        }
        return false
    }

    // MARK: stripSpecialTokens

    func testStripsBlankAudioAndAllCapsBracketTokens() {
        XCTAssertEqual(Transcriber.stripSpecialTokens(from: "[BLANK_AUDIO]"), "")
        XCTAssertEqual(Transcriber.stripSpecialTokens(from: "[APPLAUSE]"), "")
        XCTAssertEqual(Transcriber.stripSpecialTokens(from: "hello [BLANK_AUDIO] world"),
                       "hello world")
    }

    func testStripsAngleTokens() {
        XCTAssertEqual(Transcriber.stripSpecialTokens(from: "hi <|endoftext|>"), "hi")
        XCTAssertEqual(Transcriber.stripSpecialTokens(from: "<|startoftranscript|>done"), "done")
    }

    func testStripsKnownNoiseParensCaseInsensitively() {
        XCTAssertEqual(Transcriber.stripSpecialTokens(from: "(music)"), "")
        XCTAssertEqual(Transcriber.stripSpecialTokens(from: "(Laughs)"), "")
        XCTAssertEqual(Transcriber.stripSpecialTokens(from: "(APPLAUSE)"), "")
        XCTAssertEqual(Transcriber.stripSpecialTokens(from: "well (laughter) then"), "well then")
    }

    func testRealContentSurvives() {
        // Math, references, ordinary parenthetical asides must not be stripped.
        XCTAssertEqual(Transcriber.stripSpecialTokens(from: "f(x)"), "f(x)")
        XCTAssertEqual(Transcriber.stripSpecialTokens(from: "[see figure 2]"), "[see figure 2]")
        XCTAssertEqual(Transcriber.stripSpecialTokens(from: "(maybe)"), "(maybe)")
        XCTAssertEqual(
            Transcriber.stripSpecialTokens(from: "the value f(x) is shown in [see figure 2]"),
            "the value f(x) is shown in [see figure 2]")
    }

    func testCollapsesRunsOfSpaces() {
        XCTAssertEqual(Transcriber.stripSpecialTokens(from: "a   b"), "a b")
        XCTAssertEqual(Transcriber.stripSpecialTokens(from: "a     b        c"), "a b c")
    }

    func testTrimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(Transcriber.stripSpecialTokens(from: "   padded   "), "padded")
        // A marker at the edge leaves whitespace that must be trimmed away.
        XCTAssertEqual(Transcriber.stripSpecialTokens(from: "(music) hello"), "hello")
        XCTAssertEqual(Transcriber.stripSpecialTokens(from: "hello (music)"), "hello")
    }

    // MARK: isCanonicalHallucination

    func testCanonicalPhrasesMatchIgnoringCaseAndPunctuation() {
        XCTAssertTrue(Transcriber.isCanonicalHallucination("Thank you."))
        XCTAssertTrue(Transcriber.isCanonicalHallucination("THANKS FOR WATCHING!"))
        XCTAssertTrue(Transcriber.isCanonicalHallucination("Bye!"))
        XCTAssertTrue(Transcriber.isCanonicalHallucination("  you  "))
        XCTAssertTrue(Transcriber.isCanonicalHallucination("Thank you for watching"))
    }

    func testNonHallucinationsDoNotMatch() {
        XCTAssertFalse(Transcriber.isCanonicalHallucination("Thank you so much for the help"))
        XCTAssertFalse(Transcriber.isCanonicalHallucination("see you"))
        // Empty transcript is not one of the canonical phrases.
        XCTAssertFalse(Transcriber.isCanonicalHallucination(""))
        XCTAssertFalse(Transcriber.isCanonicalHallucination("   "))
    }
}

private actor CompletionOrder {
    private(set) var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }
}
