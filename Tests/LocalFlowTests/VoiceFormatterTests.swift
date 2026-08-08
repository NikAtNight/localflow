import XCTest
@testable import LocalFlow

/// Spoken-command formatting: line breaks, lists, and emoji produced from
/// the phrasing Whisper actually emits (capitalized, comma/period-wrapped).
final class VoiceFormatterTests: XCTestCase {

    // MARK: - Line breaks

    func testNewLineAndNewParagraph() {
        XCTAssertEqual(VoiceFormatter.apply("first line new line second line"),
                       "first line\nSecond line")
        XCTAssertEqual(VoiceFormatter.apply("First part. New paragraph. Second part."),
                       "First part.\n\nSecond part.")
        XCTAssertEqual(VoiceFormatter.apply("one newline two"), "one\nTwo")
    }

    func testWhisperPunctuationAroundCommandsIsConsumed() {
        XCTAssertEqual(VoiceFormatter.apply("Hello, new line, world."), "Hello\nWorld.")
    }

    func testTrailingNewLineCommandKeepsTheBreak() {
        XCTAssertEqual(VoiceFormatter.apply("Done. New line."), "Done.\n")
    }

    // MARK: - Bullet lists

    func testBulletList() {
        XCTAssertEqual(VoiceFormatter.apply("Bullet point apples bullet point bananas"),
                       "- Apples\n- Bananas")
        XCTAssertEqual(VoiceFormatter.apply("Groceries. Bullet point, milk. Bullet point, eggs."),
                       "Groceries.\n- Milk.\n- Eggs.")
    }

    func testNextItemContinuesBulletList() {
        XCTAssertEqual(VoiceFormatter.apply("bullet point apples next item bananas"),
                       "- Apples\n- Bananas")
    }

    // MARK: - Numbered lists

    func testNumberedListCountsUp() {
        XCTAssertEqual(
            VoiceFormatter.apply("numbered list apples next item bananas next item cherries"),
            "1. Apples\n2. Bananas\n3. Cherries")
    }

    func testNewParagraphEndsListMode() {
        XCTAssertEqual(
            VoiceFormatter.apply("numbered list apples new paragraph next item on the agenda"),
            "1. Apples\n\nNext item on the agenda")
    }

    func testNextItemOutsideAListIsPlainText() {
        XCTAssertEqual(VoiceFormatter.apply("the next item on the agenda is budget"),
                       "the next item on the agenda is budget")
    }

    // MARK: - Emoji

    func testEmojiInsertion() {
        XCTAssertEqual(VoiceFormatter.apply("sounds good thumbs up emoji"), "sounds good 👍")
        XCTAssertEqual(VoiceFormatter.apply("Thumbs up emoji, see you tomorrow."),
                       "👍 see you tomorrow.")
        XCTAssertEqual(VoiceFormatter.apply("ship it rocket emoji fire emoji"), "ship it 🚀 🔥")
    }

    func testMultiWordEmojiNamesPreferLongestMatch() {
        XCTAssertEqual(VoiceFormatter.apply("that was great heart eyes emoji"),
                       "that was great 😍")
        XCTAssertEqual(VoiceFormatter.apply("love it heart emoji"), "love it ❤️")
    }

    func testUnknownEmojiNameIsLeftAlone() {
        XCTAssertEqual(VoiceFormatter.apply("the flux capacitor emoji is not real"),
                       "the flux capacitor emoji is not real")
    }

    // MARK: - Non-command text

    func testTextWithoutCommandsIsUntouched() {
        let text = "The value f(x) is shown in [see figure 2], thanks."
        XCTAssertEqual(VoiceFormatter.apply(text), text)
    }

    func testOrdinaryProseMentioningBulletsIsAffectedOnlyAtTheCommand() {
        // Known tradeoff: "bullet point" is always a command. Document the
        // behavior so a future guard (e.g. an escape phrase) has a baseline.
        XCTAssertEqual(VoiceFormatter.apply("add a bullet point about pricing"),
                       "add a\n- About pricing")
    }

    func testLeadingCommandDoesNotCreateBlankFirstLine() {
        XCTAssertEqual(VoiceFormatter.apply("New paragraph hello"), "Hello")
        XCTAssertEqual(VoiceFormatter.apply("bullet point first thing"), "- First thing")
    }

    // MARK: - Automatic numbered lists (no command spoken)

    func testSpokenOrdinalsBecomeANumberedList() {
        XCTAssertEqual(
            VoiceFormatter.apply("First, buy milk. Second, get eggs. Third, walk the dog."),
            "1. Buy milk.\n2. Get eggs.\n3. Walk the dog.")
    }

    func testNumberCuesAndTerminatorBecomeAList() {
        XCTAssertEqual(
            VoiceFormatter.apply("Number one, review the PR. Number two, merge it. Finally, deploy."),
            "1. Review the PR.\n2. Merge it.\n3. Deploy.")
    }

    func testLoneOrdinalIsNotAList() {
        XCTAssertEqual(VoiceFormatter.apply("First, some context about the project."),
                       "First, some context about the project.")
        // "Second" with no preceding "First" stays prose.
        XCTAssertEqual(VoiceFormatter.apply("Second, I want to say thanks."),
                       "Second, I want to say thanks.")
    }

    func testMidSentenceOrdinalsAreNotItems() {
        XCTAssertEqual(
            VoiceFormatter.apply("At first, I was unsure, but the second time it worked."),
            "At first, I was unsure, but the second time it worked.")
    }

    func testOrdinalListAfterAnIntroSentence() {
        XCTAssertEqual(
            VoiceFormatter.apply("Two things. First, the tests pass. Second, the docs are updated."),
            "Two things.\n1. The tests pass.\n2. The docs are updated.")
    }

    // MARK: - Learned corrections

    func testCorrectionReplacesWholeWordsCaseInsensitively() {
        let fixes = [(wrong: "talex", right: "Talix")]
        XCTAssertEqual(TranscriptCorrections.apply("I work on talex now.", corrections: fixes),
                       "I work on Talix now.")
        XCTAssertEqual(TranscriptCorrections.apply("Talex is my project.", corrections: fixes),
                       "Talix is my project.")
    }

    func testCorrectionNeverTouchesPartialWords() {
        let fixes = [(wrong: "cat", right: "Kat")]
        XCTAssertEqual(TranscriptCorrections.apply("the catalog has a cat in it", corrections: fixes),
                       "the catalog has a Kat in it")
    }

    func testCorrectionKeepsSentenceCasingForLowercaseFixes() {
        let fixes = [(wrong: "get hub", right: "github")]
        XCTAssertEqual(TranscriptCorrections.apply("Get hub is down. I checked get hub twice.", corrections: fixes),
                       "Github is down. I checked github twice.")
    }

    func testEmptyCorrectionsLeaveTextAlone() {
        XCTAssertEqual(TranscriptCorrections.apply("hello world", corrections: []), "hello world")
    }

    func testFarApartOrdinalsAreNarrationNotAList() {
        // "First," and "Second," separated by paragraphs of prose must not
        // be stitched into a numbered list.
        let filler = String(repeating: "Then a lot of other things happened over the years. ", count: 12)
        let text = "First, I joined Acme. \(filler)Second, I moved on to something new."
        XCTAssertEqual(VoiceFormatter.apply(text), text)
    }
}

/// Pause-based paragraphing: a long silence between Whisper segments starts
/// a new paragraph, but only after a finished sentence.
final class SegmentJoinTests: XCTestCase {

    func testLongPauseAfterSentenceStartsAParagraph() {
        let joined = Transcriber.joinSegments([
            (text: " This is the first thought.", start: 0, end: 3.0),
            (text: " And a new topic entirely.", start: 5.2, end: 8.0),
        ])
        XCTAssertEqual(joined, "This is the first thought.\n\nAnd a new topic entirely.")
    }

    func testShortPauseJoinsWithASpace() {
        let joined = Transcriber.joinSegments([
            (text: " Quick sentence.", start: 0, end: 1.0),
            (text: " Followed closely.", start: 1.8, end: 3.0),
        ])
        XCTAssertEqual(joined, "Quick sentence. Followed closely.")
    }

    func testMidSentencePauseNeverSplits() {
        // Thinking pause: no sentence-final punctuation before the gap.
        let joined = Transcriber.joinSegments([
            (text: " So the thing is", start: 0, end: 2.0),
            (text: " we should ship it.", start: 5.0, end: 7.0),
        ])
        XCTAssertEqual(joined, "So the thing is we should ship it.")
    }

    func testEmptyAndMarkerSegmentsAreSkipped() {
        let joined = Transcriber.joinSegments([
            (text: " Hello there.", start: 0, end: 1.0),
            (text: " [BLANK_AUDIO]", start: 1.0, end: 4.0),
            (text: " New paragraph topic.", start: 4.0, end: 6.0),
        ])
        // The marker's span counts as silence, so the pause still splits.
        XCTAssertEqual(joined, "Hello there.\n\nNew paragraph topic.")
    }
}
