import XCTest
@testable import LocalFlow

/// Learning corrections from a hand-edited dictation. The bar is high on
/// purpose: a wrong rule fires on every future dictation, so anything that
/// isn't clearly a mishearing must be rejected.
final class DictationDiffTests: XCTestCase {

    func testLearnsASingleMisheardWord() {
        let proposals = DictationDiff.proposedCorrections(
            original: "I pushed the change to talex today",
            edited: "I pushed the change to Talix today")
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals.first?.wrong, "talex")
        XCTAssertEqual(proposals.first?.right, "Talix")
    }

    func testLearnsSeveralFixesInOnePass() {
        let proposals = DictationDiff.proposedCorrections(
            original: "deploy kubernets from get hub actions",
            edited: "deploy kubernetes from github actions")
        XCTAssertEqual(proposals.map(\.wrong), ["kubernets", "get"])
        XCTAssertEqual(proposals.map(\.right), ["kubernetes", "github"])
    }

    func testIgnoresCommonWords() {
        // "the" -> "a" is a one-off, not a vocabulary gap.
        let proposals = DictationDiff.proposedCorrections(
            original: "send the report to finance",
            edited: "send a report to finance")
        XCTAssertTrue(proposals.isEmpty, "\(proposals)")
    }

    func testIgnoresPureCasingAndPunctuationEdits() {
        XCTAssertTrue(DictationDiff.proposedCorrections(
            original: "shipped the release",
            edited: "Shipped the release.").isEmpty)
    }

    func testIdenticalTextLearnsNothing() {
        XCTAssertTrue(DictationDiff.proposedCorrections(
            original: "nothing changed here",
            edited: "nothing changed here").isEmpty)
    }

    func testPureInsertionIsNotAMishearing() {
        // Adding a word is editing, not a recognition error.
        let proposals = DictationDiff.proposedCorrections(
            original: "ship the feature",
            edited: "ship the whole feature")
        XCTAssertTrue(proposals.isEmpty, "\(proposals)")
    }

    func testEmptyInputIsSafe() {
        XCTAssertTrue(DictationDiff.proposedCorrections(original: "", edited: "anything").isEmpty)
        XCTAssertTrue(DictationDiff.proposedCorrections(original: "anything", edited: "").isEmpty)
    }

    func testDeduplicatesRepeatedMishearings() {
        let proposals = DictationDiff.proposedCorrections(
            original: "talex and talex again",
            edited: "Talix and Talix again")
        XCTAssertEqual(proposals.count, 1)
    }
}

/// Voice-triggered expansions.
final class SnippetTests: XCTestCase {
    private let signature = [(trigger: "insert my signature", expansion: "Nikhil Kapadia\nTalix")]

    func testExpandsTriggerAnywhereInTheText() {
        XCTAssertEqual(
            Snippets.expand("Thanks. insert my signature", snippets: signature),
            "Thanks. Nikhil Kapadia\nTalix")
    }

    func testTriggerIsCaseInsensitiveAndEatsTrailingPunctuation() {
        XCTAssertEqual(
            Snippets.expand("Insert my signature.", snippets: signature),
            "Nikhil Kapadia\nTalix")
    }

    func testUnrelatedTextIsUntouched() {
        XCTAssertEqual(
            Snippets.expand("please sign the document", snippets: signature),
            "please sign the document")
    }

    func testExpansionWithRegexCharactersIsInsertedLiterally() {
        let tricky = [(trigger: "insert regex", expansion: "$1 \\n [a-z]+")]
        XCTAssertEqual(Snippets.expand("insert regex", snippets: tricky), "$1 \\n [a-z]+")
    }

    func testNoSnippetsIsANoOp() {
        XCTAssertEqual(Snippets.expand("hello", snippets: []), "hello")
    }
}

/// App-aware writing style.
final class AppStyleProfileTests: XCTestCase {

    func testKnownAppsMapToTheirRegister() {
        XCTAssertEqual(AppStyleProfile.forBundleIdentifier("com.apple.mail"), .email)
        XCTAssertEqual(AppStyleProfile.forBundleIdentifier("com.tinyspeck.slackmacgap"), .workChat)
        XCTAssertEqual(AppStyleProfile.forBundleIdentifier("com.apple.MobileSMS"), .general)
        XCTAssertEqual(AppStyleProfile.forBundleIdentifier("com.microsoft.VSCode"), .code)
    }

    func testUnknownAppsFallBackToGeneralRatherThanGuessing() {
        XCTAssertEqual(AppStyleProfile.forBundleIdentifier("com.example.unknown"), .general)
        XCTAssertEqual(AppStyleProfile.forBundleIdentifier(nil), .general)
    }

    func testEveryProfileContributesStyleInstructions() {
        for profile in [AppStyleProfile.email, .workChat, .personalChat, .code, .general] {
            XCTAssertFalse(profile.styleInstruction.isEmpty, "\(profile)")
        }
    }

    func testInstructionsCombineBaseRulesWithTheProfile() {
        let combined = TranscriptCleanup.instructions(for: .email)
        XCTAssertTrue(combined.contains("speech-to-text"))
        XCTAssertTrue(combined.contains("email"))
    }
}
