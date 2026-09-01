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

@MainActor
final class S1MiniCleanupTests: XCTestCase {

    func testDetectsS1MiniUnderAnySpelling() {
        XCTAssertTrue(S1MiniCleanup.matches(model: "s1-mini"))
        XCTAssertTrue(S1MiniCleanup.matches(model: "hf.co/superwhisper/S1-mini-GGUF:Q4_K_M"))
        XCTAssertFalse(S1MiniCleanup.matches(model: "gemma3:4b"))
    }

    /// The normalizer was trained on a closed vocabulary of control values;
    /// anything outside it silently degrades output.
    func testControlLinesUseOnlyTrainedValues() {
        let pattern = #"^\[Styling: (casual|semi-casual|semi-formal|formal)\] "# +
            #"\[Structure: (prose|lists)\] \[Context: (general|email)\]$"#
        for profile in [AppStyleProfile.email, .workChat, .personalChat, .code, .general] {
            let line = S1MiniCleanup.controlLine(for: profile)
            XCTAssertNotNil(line.range(of: pattern, options: .regularExpression), line)
        }
    }

    func testOnlyEmailDictationsGetTheEmailContext() {
        XCTAssertTrue(S1MiniCleanup.controlLine(for: .email).contains("[Context: email]"))
        for profile in [AppStyleProfile.workChat, .personalChat, .code, .general] {
            XCTAssertTrue(S1MiniCleanup.controlLine(for: profile).contains("[Context: general]"))
        }
    }

    func testPromptIsControlLineThenTranscript() {
        let prompt = S1MiniCleanup.prompt(for: "hello world", profile: .general)
        XCTAssertTrue(prompt.hasPrefix("[Styling: "))
        XCTAssertTrue(prompt.hasSuffix("]\nhello world"))
    }

    /// Regression: Ollama derives the thinking capability from the qwen3
    /// architecture, so the request must always disable it explicitly.
    /// Omitting the flag made s1-mini return an empty response or paste a
    /// literal "<think>" tag as the whole dictation.
    func testEveryCleanupRequestExplicitlyDisablesThinking() {
        for model in ["s1-mini", "gemma3:4b"] {
            let body = OllamaCleaner.generateRequest("hello", model: model, profile: .general)
            XCTAssertEqual(body.think, .bool(false), model)
            XCTAssertEqual(body.keepAlive, "30m", model)
        }
    }

    func testS1MiniRequestUsesItsTrainedProtocol() {
        let body = OllamaCleaner.generateRequest("hello", model: "s1-mini", profile: .email)
        XCTAssertEqual(body.system, S1MiniCleanup.systemPrompt)
        XCTAssertTrue(body.prompt.hasPrefix("[Styling: "))
        XCTAssertEqual(body.options.temperature, 0)
    }

    func testInstructModelsKeepTheInstructPrompt() {
        let body = OllamaCleaner.generateRequest("hello", model: "gemma3:4b", profile: .email)
        XCTAssertTrue(body.system.contains("speech-to-text"))
        XCTAssertEqual(body.prompt, "hello")
    }

    /// Command mode's Ollama fallback must never route to the normalizer:
    /// its request goes to a dedicated instruct model, thinking still off
    /// by default.
    func testCommandRequestsAreInstructShapedWithThinkingOff() {
        let body = OllamaCleaner.respondRequest(
            system: "sys", prompt: "Instruction: shorten", model: "gemma3:4b", reasoning: .off)
        XCTAssertEqual(body.think, .bool(false))
        XCTAssertEqual(body.keepAlive, "30m")
        XCTAssertEqual(body.prompt, "Instruction: shorten")
        XCTAssertEqual(body.options.numPredict, 2_048)
    }

    /// The reasoning setting maps onto whatever `think` shape the model
    /// family understands; a level string sent to a toggle-only model would
    /// be rejected by the server.
    func testReasoningLevelsMapToTheModelFamily() {
        func think(_ model: String, _ level: ReasoningLevel) -> OllamaCleaner.ThinkValue {
            OllamaCleaner.respondRequest(system: "s", prompt: "p", model: model, reasoning: level).think
        }
        XCTAssertEqual(think("gpt-oss:20b", .medium), .level("medium"))
        XCTAssertEqual(think("gpt-oss:20b", .off), .bool(false))
        XCTAssertEqual(think("qwen3:8b", .high), .bool(true))
        XCTAssertEqual(think("gemma3:4b", .off), .bool(false))
    }

    func testLeakedThinkTagIsNeverPasted() {
        XCTAssertEqual(TranscriptCleanup.validationResult("<think>", raw: "raw words").text, "raw words")
        XCTAssertEqual(TranscriptCleanup.validationResult("<think>\nstuff", raw: "raw words").text, "raw words")
        XCTAssertEqual(TranscriptCleanup.validationResult("clean words", raw: "raw words").text, "clean words")
    }

    func testUnchangedCleanupOutputIsAValidCompletion() {
        let result = TranscriptCleanup.validationResult("Already clean.", raw: "Already clean.")

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.text, "Already clean.")
    }

    func testRejectedCleanupOutputIsNotAValidCompletion() {
        let result = TranscriptCleanup.validationResult("<think>\nstuff", raw: "raw words")

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.text, "raw words")
    }
}
