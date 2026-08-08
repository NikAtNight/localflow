import Foundation

/// Deterministic spoken-command formatter, applied to the raw transcript
/// right after Whisper and before the optional Ollama cleanup pass (whose
/// prompt preserves the produced formatting), so commands behave identically
/// whether cleanup is on or off.
///
/// Supported commands (case-insensitive, tolerant of the punctuation Whisper
/// wraps around them):
///   "new line" / "newline"  -> line break
///   "new paragraph"         -> blank line
///   "bullet point"          -> starts/continues a "- " list item
///   "numbered list"         -> starts a "1. " list
///   "next item"             -> next "- " or "N. " item (only inside a list)
///   "<name> emoji"          -> the named emoji ("thumbs up emoji" -> 👍)
/// User-taught fixes for words Whisper keeps mishearing ("talex" ->
/// "Talix"). Applied to every raw transcript before formatting. The
/// right-hand sides also feed the recognition vocabulary (see
/// Settings.effectiveVocabulary) so the decoder gets a chance to hear the
/// word correctly at the source.
enum TranscriptCorrections {
    static func apply(_ text: String, corrections: [(wrong: String, right: String)]) -> String {
        var result = text
        for (wrong, right) in corrections {
            let heard = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacementBase = right.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heard.isEmpty, !replacementBase.isEmpty else { continue }
            let pattern = "\\b"
                + NSRegularExpression.escapedPattern(for: heard).replacingOccurrences(of: " ", with: "\\s+")
                + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let ns = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            var output = ""
            var cursor = 0
            for match in matches {
                output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                var replacement = replacementBase
                // "talex" -> "talix" at a sentence start was heard as
                // "Talex"; keep the sentence casing when the fix itself
                // isn't a cased word.
                if let first = ns.substring(with: match.range).first, first.isUppercase,
                   let replacementFirst = replacement.first, replacementFirst.isLowercase {
                    replacement = replacement.prefix(1).uppercased() + replacement.dropFirst()
                }
                output += replacement
                cursor = match.range.location + match.range.length
            }
            output += ns.substring(from: cursor)
            result = output
        }
        return result
    }
}

/// Voice-triggered text expansion: say the trigger phrase, get the block of
/// text. Applied after formatting so an expansion's own punctuation and line
/// breaks are inserted verbatim and never re-interpreted as commands.
enum Snippets {
    static func expand(_ text: String, snippets: [(trigger: String, expansion: String)]) -> String {
        var result = text
        for (trigger, expansion) in snippets {
            let phrase = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty, !expansion.isEmpty else { continue }
            // Trailing punctuation is the dictation's, not the trigger's:
            // "insert signature." must still fire.
            let pattern = "\\b"
                + NSRegularExpression.escapedPattern(for: phrase).replacingOccurrences(of: " ", with: "\\s+")
                + "\\b[.,;:!?]?"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: expansion)
            )
        }
        return result
    }
}

enum VoiceFormatter {

    // MARK: - Emoji vocabulary

    /// Spoken name -> emoji, matched as "<name> emoji". Aliases are separate
    /// keys. Extend freely; the regex is rebuilt from this table.
    static let emojiNames: [String: String] = [
        "thumbs up": "👍", "thumbs down": "👎",
        "smiley face": "😊", "smiling face": "😊", "smiley": "😊",
        "grinning face": "😀", "happy face": "😊",
        "laughing": "😂", "crying laughing": "😂", "joy": "😂",
        "winking face": "😉", "wink": "😉",
        "sad face": "😞", "crying face": "😢",
        "angry face": "😠",
        "thinking face": "🤔", "thinking": "🤔",
        "heart eyes": "😍", "sunglasses": "😎", "cool face": "😎",
        "heart": "❤️", "red heart": "❤️", "broken heart": "💔",
        "fire": "🔥", "party": "🎉", "party popper": "🎉", "tada": "🎉",
        "clapping": "👏", "clap": "👏", "rocket": "🚀",
        "check mark": "✅", "checkmark": "✅", "cross mark": "❌", "red x": "❌",
        "eyes": "👀", "ok hand": "👌",
        "waving hand": "👋", "wave": "👋",
        "star": "⭐", "sparkles": "✨", "warning": "⚠️",
        "hundred": "💯", "one hundred": "💯",
        "muscle": "💪", "flex": "💪",
        "folded hands": "🙏", "pray": "🙏", "raised hands": "🙌",
        "shrug": "🤷", "facepalm": "🤦", "skull": "💀",
        "light bulb": "💡", "coffee": "☕",
    ]

    private enum ListMode {
        case bullet
        case numbered(next: Int)
    }

    // Leading `,?` eats the comma Whisper tends to place before a command
    // ("apples, bullet point, bananas"); a preceding period stays with its
    // sentence. Trailing punctuation and spaces belong to the command and
    // are consumed with it.
    private static let commandRegex: NSRegularExpression = {
        let emojiAlternation = emojiNames.keys
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: "\\s+") }
            .joined(separator: "|")
        let pattern = "[ \\t]*,?[ \\t]*\\b(?:"
            + "(?<para>new\\s+paragraph)"
            + "|(?<line>new\\s+line|newline)"
            + "|(?<bullet>bullet\\s+point)"
            + "|(?<numlist>numbered\\s+list)"
            + "|(?<next>next\\s+item)"
            + "|(?<emoji>\(emojiAlternation))\\s+emoji"
            + ")\\b[.,;:!?]?[ \\t]*"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    static func apply(_ text: String) -> String {
        autoNumberLists(applyCommands(text))
    }

    private static func applyCommands(_ text: String) -> String {
        let ns = text as NSString
        let matches = commandRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var output = ""
        var cursor = 0
        var listMode: ListMode?
        var capitalizeNext = false

        for match in matches {
            let between = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            appendText(between, to: &output, capitalizeNext: &capitalizeNext)
            cursor = match.range.location + match.range.length

            if match.range(withName: "para").location != NSNotFound {
                ensureTrailingNewlines(2, in: &output)
                listMode = nil
                capitalizeNext = true
            } else if match.range(withName: "line").location != NSNotFound {
                ensureTrailingNewlines(1, in: &output)
                capitalizeNext = true
            } else if match.range(withName: "bullet").location != NSNotFound {
                listMode = .bullet
                ensureTrailingNewlines(1, in: &output)
                output += "- "
                capitalizeNext = true
            } else if match.range(withName: "numlist").location != NSNotFound {
                listMode = .numbered(next: 2)
                ensureTrailingNewlines(1, in: &output)
                output += "1. "
                capitalizeNext = true
            } else if match.range(withName: "next").location != NSNotFound {
                switch listMode {
                case .bullet:
                    ensureTrailingNewlines(1, in: &output)
                    output += "- "
                    capitalizeNext = true
                case .numbered(let n):
                    listMode = .numbered(next: n + 1)
                    ensureTrailingNewlines(1, in: &output)
                    output += "\(n). "
                    capitalizeNext = true
                case nil:
                    // "the next item on the agenda" is not a command outside
                    // a list; put the matched text back verbatim.
                    appendText(ns.substring(with: match.range), to: &output, capitalizeNext: &capitalizeNext)
                }
            } else if match.range(withName: "emoji").location != NSNotFound {
                let spoken = ns.substring(with: match.range(withName: "emoji"))
                    .lowercased()
                    .split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
                if let emoji = emojiNames[spoken] {
                    if let last = output.last, !last.isWhitespace { output += " " }
                    output += emoji
                } else {
                    appendText(ns.substring(with: match.range), to: &output, capitalizeNext: &capitalizeNext)
                }
            }
        }
        appendText(ns.substring(from: cursor), to: &output, capitalizeNext: &capitalizeNext)
        return output
    }

    // MARK: - Automatic numbered lists

    /// "First, … Second, … Third, …" spoken enumerations become a numbered
    /// list with no explicit command. Conservative on purpose: cues must be
    /// sentence-initial AND punctuated ("First," / "Number two:"), ascending
    /// from one, and at least two items long. "Second, I want to say" or a
    /// lone "First, some context" never converts. "Finally"/"Lastly" closes
    /// a run as its last item.
    private static let ordinalCueRegex = try! NSRegularExpression(
        pattern: "(^|[.!?…]\\s+|\\n\\s*)"
            + "(first(?:ly)?|second(?:ly)?|third(?:ly)?|fourth|fifth|sixth|seventh|eighth|ninth|tenth"
            + "|(?:number|step)\\s+(?:one|two|three|four|five|six|seven|eight|nine|ten|10|[1-9])"
            + "|finally|lastly)"
            + "\\s*[,:]\\s*",
        options: [.caseInsensitive]
    )

    private static let ordinalValues: [String: Int] = [
        "first": 1, "firstly": 1, "one": 1,
        "second": 2, "secondly": 2, "two": 2,
        "third": 3, "thirdly": 3, "three": 3,
        "fourth": 4, "four": 4, "fifth": 5, "five": 5,
        "sixth": 6, "six": 6, "seventh": 7, "seven": 7,
        "eighth": 8, "eight": 8, "ninth": 9, "nine": 9,
        "tenth": 10, "ten": 10,
    ]

    /// nil = "finally"/"lastly" (a terminator that takes the next number).
    private static func ordinalIndex(of cue: String) -> Int? {
        let words = cue.lowercased().split(whereSeparator: { $0.isWhitespace })
        guard let last = words.last, last != "finally", last != "lastly" else { return nil }
        return ordinalValues[String(last)] ?? Int(last)
    }

    static func autoNumberLists(_ text: String) -> String {
        let ns = text as NSString
        let matches = ordinalCueRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 2 else { return text }

        // First pass: find ascending runs starting at 1; only they convert.
        // Consecutive cues must also be CLOSE: "First, I joined Acme."
        // followed by "Second, I moved on." three paragraphs later is
        // narration, not a list.
        let maxGapBetweenItems = 400 // characters of prose between cues
        var itemNumber: [Int: Int] = [:] // match index -> list number
        var run: [Int] = []
        var expected = 1
        var previousCueEnd = 0
        func commitRun() {
            if run.count >= 2 {
                for (position, matchIndex) in run.enumerated() {
                    itemNumber[matchIndex] = position + 1
                }
            }
            run = []
            expected = 1
        }
        for (i, match) in matches.enumerated() {
            let cue = ns.substring(with: match.range(at: 2))
            let isTerminator = ["finally", "lastly"].contains(cue.lowercased())
            let index = ordinalIndex(of: cue)
            let tooFar = !run.isEmpty && match.range.location - previousCueEnd > maxGapBetweenItems
            if run.isEmpty || tooFar {
                commitRun()
                if index == 1 { run = [i]; expected = 2 }
            } else if isTerminator {
                run.append(i)
                commitRun()
            } else if index == expected {
                run.append(i)
                expected += 1
            } else {
                commitRun()
                if index == 1 { run = [i]; expected = 2 }
            }
            previousCueEnd = match.range.location + match.range.length
        }
        commitRun()
        guard !itemNumber.isEmpty else { return text }

        // Second pass: rewrite each converted cue as "\nN. ", keeping the
        // sentence punctuation that preceded it.
        var output = ""
        var cursor = 0
        var capitalizeNext = false
        for (i, match) in matches.enumerated() {
            guard let number = itemNumber[i] else { continue }
            let between = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            appendText(between, to: &output, capitalizeNext: &capitalizeNext)
            cursor = match.range.location + match.range.length
            let prefix = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            output += prefix
            ensureTrailingNewlines(1, in: &output)
            output += "\(number). "
            capitalizeNext = true
        }
        appendText(ns.substring(from: cursor), to: &output, capitalizeNext: &capitalizeNext)
        return output
    }

    /// Appends plain transcript text, sentence-casing the first word after a
    /// break command and spacing it off an emoji it directly follows.
    private static func appendText(_ segment: String, to output: inout String, capitalizeNext: inout Bool) {
        guard !segment.isEmpty else { return }
        var seg = segment
        if capitalizeNext, let idx = seg.firstIndex(where: { $0.isLetter || $0.isNumber }) {
            if seg[idx].isLetter {
                seg.replaceSubrange(idx...idx, with: String(seg[idx]).uppercased())
            }
            capitalizeNext = false
        }
        if let last = output.last, !last.isWhitespace,
           let first = seg.first, first.isLetter || first.isNumber {
            output += " "
        }
        output += seg
    }

    /// Trims trailing spaces and guarantees the output ends with at least
    /// `count` newlines (no-op at the very start of the text, so a leading
    /// command never produces a blank first line).
    private static func ensureTrailingNewlines(_ count: Int, in output: inout String) {
        while let last = output.last, last == " " || last == "\t" { output.removeLast() }
        guard !output.isEmpty else { return }
        var existing = 0
        for char in output.reversed() {
            guard char == "\n" else { break }
            existing += 1
        }
        if existing < count {
            output += String(repeating: "\n", count: count - existing)
        }
    }
}
