import Foundation

/// Works out what a user changed after a dictation was pasted, so the fixes
/// they made by hand can be learned instead of retyped in Settings.
///
/// Word-level, substitution-only on purpose: rewording a sentence is
/// editing, not a mishearing, and must not be learned as a rule. Only
/// one-word-for-one-word swaps at the same position are proposed.
enum DictationDiff {
    /// Words too ordinary to be worth a permanent rule. Whisper getting
    /// "the"/"a" wrong is a one-off, not a vocabulary gap (Wispr Flow
    /// filters common words from auto-learning for the same reason).
    private static let commonWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "if", "then", "than",
        "is", "are", "was", "were", "be", "been", "am", "do", "does", "did",
        "have", "has", "had", "i", "you", "he", "she", "it", "we", "they",
        "me", "him", "her", "us", "them", "my", "your", "his", "its", "our",
        "their", "this", "that", "these", "those", "to", "of", "in", "on",
        "at", "for", "with", "from", "by", "as", "not", "no", "yes", "can",
        "will", "would", "should", "could", "just", "very", "really", "now",
        "up", "out", "one", "two", "too", "there", "here", "what", "when",
        "where", "who", "how", "why", "all", "any", "some", "more", "most",
    ]

    /// Proposed `wrong -> right` pairs, in reading order and de-duplicated.
    /// Empty when the edit was a rewrite rather than a set of word fixes.
    static func proposedCorrections(original: String, edited: String) -> [(wrong: String, right: String)] {
        let originalWords = words(in: original)
        let editedWords = words(in: edited)
        guard !originalWords.isEmpty, !editedWords.isEmpty else { return [] }

        var proposals: [(wrong: String, right: String)] = []
        var seen = Set<String>()
        for (before, after) in substitutions(originalWords, editedWords) {
            let wrong = trimPunctuation(before)
            let right = trimPunctuation(after)
            guard isLearnable(wrong: wrong, right: right) else { continue }
            let key = wrong.lowercased()
            guard seen.insert(key).inserted else { continue }
            proposals.append((wrong, right))
        }
        return proposals
    }

    private static func isLearnable(wrong: String, right: String) -> Bool {
        guard !wrong.isEmpty, !right.isEmpty else { return false }
        // Pure casing/punctuation differences are the formatter's job.
        guard wrong.lowercased() != right.lowercased() else { return false }
        guard !commonWords.contains(wrong.lowercased()) else { return false }
        // A "fix" that shares no letters is usually a reworded sentence
        // caught by the aligner, not a mishearing of the same sounds.
        guard wrong.count > 2, right.count > 1 else { return false }
        return true
    }

    /// Aligned one-for-one replacements, found from the longest common
    /// subsequence of the two word lists. A word only replaced (not
    /// inserted or deleted) is a candidate mishearing.
    private static func substitutions(_ before: [String], _ after: [String]) -> [(String, String)] {
        // Guard against pathological inputs: the LCS table is O(n*m).
        guard before.count <= 400, after.count <= 400 else { return [] }
        var lengths = Array(
            repeating: Array(repeating: 0, count: after.count + 1),
            count: before.count + 1
        )
        for i in stride(from: before.count - 1, through: 0, by: -1) {
            for j in stride(from: after.count - 1, through: 0, by: -1) {
                lengths[i][j] = before[i].lowercased() == after[j].lowercased()
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var result: [(String, String)] = []
        var i = 0, j = 0
        while i < before.count, j < after.count {
            if before[i].lowercased() == after[j].lowercased() {
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                // `before[i]` was dropped. If the very next edited word is
                // also unmatched, treat the pair as a substitution.
                if lengths[i + 1][j] == lengths[i][j + 1] {
                    result.append((before[i], after[j]))
                    i += 1
                    j += 1
                } else {
                    i += 1
                }
            } else {
                j += 1
            }
        }
        return result
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func trimPunctuation(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }
}
