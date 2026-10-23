import Foundation

/// The experimental transcript cleanup (FR05): a transcript's sentences
/// rewritten by rule (`TranscriptCleanupRule`), so the words the recognizer
/// writes differently from books are written as books write them.
///
/// The rules apply in order, each to the text the rules before it left. A
/// whole-word rule matches the words of its pattern, in any case and with
/// any apostrophe, wherever they stand as whole words in a sentence, the
/// punctuation around them aside: the pattern "alright" matches "Alright,"
/// and writes "All right,". Its last word matches the word with a
/// possessive "'s" too, which stays: the pattern "Bennett" writes "Bennet's"
/// for "Bennett's". A rule matching inside words matches its pattern's
/// letters in any case wherever they stand. Either way the replacement
/// takes the case the sentence wrote the match in: all capitals, a capital
/// first letter, or as the rule writes it.
///
/// A sentence the cleanup changes keeps its time in the audio and drops
/// its words' timings (`TranscriptSentence.rewrite(as:)`), as an edit in
/// the user's editor does. Nothing here reads or writes a file; saving a
/// cleanup is `TranscriptStore.cleanUp`.
struct TranscriptCleanup: Sendable {
    /// The rules, applied in order.
    let rules: [TranscriptCleanupRule]

    /// How many examples of each rule's changes a preview keeps.
    static let examplesPerRule = 3
    /// How many words around a change an example shows on each side.
    static let contextWords = 4

    // MARK: - What a Cleanup Changes

    /// One change a rule made in one sentence, as the Clean Up sheet shows
    /// it: the words around it, before and after.
    struct Example: Equatable, Sendable {
        /// The words as the recognizer wrote them.
        let before: String
        /// The words as the rule writes them.
        let after: String
    }

    /// What one rule changed in a transcript.
    struct RuleChanges: Equatable, Sendable {
        /// The rule.
        let rule: TranscriptCleanupRule
        /// How many corrections it made.
        var corrections: Int
        /// Examples of them, from the first sentences it changed.
        var examples: [Example]
    }

    /// What cleaning up a transcript changes.
    struct Preview: Equatable, Sendable {
        /// The transcript as it was.
        let original: Transcript
        /// The transcript cleaned up: each sentence a rule changed rewritten.
        /// It records no cleanup yet; saving it does.
        let cleaned: Transcript
        /// What each rule that changed something changed, in the rules' order.
        let changes: [RuleChanges]
        /// How many sentences changed.
        let changedSentences: Int

        /// How many corrections the rules made in all.
        var corrections: Int {
            changes.reduce(0) { $0 + $1.corrections }
        }
    }

    /// What cleaning up `transcript` changes: every sentence of every file
    /// run through the rules, a sentence they changed rewritten.
    func preview(of transcript: Transcript) -> Preview {
        var rewritten = transcript
        var corrections = [Int](repeating: 0, count: rules.count)
        var examples = [[Example]](repeating: [], count: rules.count)
        var changedSentences = 0
        for file in rewritten.files.indices {
            for sentence in rewritten.files[file].sentences.indices {
                let original = rewritten.files[file].sentences[sentence].text
                let result = cleaned(original)
                guard result.text != original else { continue }
                rewritten.files[file].sentences[sentence].rewrite(as: result.text)
                changedSentences += 1
                for rule in rules.indices {
                    corrections[rule] += result.corrections[rule]
                    examples[rule] = Array((examples[rule] + result.examples[rule]).prefix(Self.examplesPerRule))
                }
            }
        }
        let changes = rules.indices.filter { corrections[$0] > 0 }.map {
            RuleChanges(rule: rules[$0], corrections: corrections[$0], examples: examples[$0])
        }
        return Preview(original: transcript, cleaned: rewritten, changes: changes, changedSentences: changedSentences)
    }

    /// `text`, one sentence, run through the rules in order: the text they
    /// leave, single-spaced, and, for each rule, how many corrections it
    /// made and an example of them, when it made any. A text no rule
    /// changes comes back exactly as it was.
    func cleaned(_ text: String) -> (text: String, corrections: [Int], examples: [[Example]]) {
        var current = text
        var corrections: [Int] = []
        var examples: [[Example]] = []
        for rule in rules {
            let (rewritten, count) = rule.wholeWord ? Self.replacingWholeWords(of: rule, in: current) : Self.replacingLetters(of: rule, in: current)
            corrections.append(count)
            examples.append(count > 0 ? [Self.example(from: current, to: rewritten)] : [])
            current = rewritten
        }
        guard current != text else { return (text, corrections, examples) }
        let spaced = TranscriptCleanupRule.singleSpaced(current)
        // A sentence with no text is not a usable transcript (a rule turning
        // "um" into nothing would leave one of "Um"), and the install would
        // refuse it after Apply was offered. Such a sentence keeps its text,
        // and its changes are neither listed nor counted, so the preview
        // offers nothing for it. `singleSpaced` is empty for white space alone.
        guard !spaced.isEmpty else {
            return (text, [Int](repeating: 0, count: rules.count), [[Example]](repeating: [], count: rules.count))
        }
        return (spaced, corrections, examples)
    }

    // MARK: - Whole Words

    /// One run of a sentence between spaces: the punctuation and symbols
    /// before its letters, the letters (and what stands between them, as in
    /// "rabbit-hole" or "don't"), and the punctuation and symbols after.
    private struct Token {
        let leading: String
        let core: String
        let trailing: String

        /// What the core is matched by: lower case, every apostrophe straight.
        var key: String {
            TranscriptAccuracy.foldingApostrophes(core).lowercased()
        }

        /// The core's possessive ending, "'s" as written, when the core is a
        /// word before it; "" otherwise.
        var possessive: String {
            let folded = key
            guard folded.count > 2, folded.hasSuffix("'s") else { return "" }
            return String(core.suffix(2))
        }

        /// How the token's word matches `key`, a pattern's last word: whole,
        /// or, for a pattern word that is no small word and holds no
        /// apostrophe, with a possessive ending left over; nil when it does
        /// not match. ("it's" is "it is", never the possessive of "it".)
        func ending(matching key: String) -> String? {
            if self.key == key { return "" }
            guard !possessive.isEmpty, !key.contains("'"), !TranscriptAccuracy.smallWords.contains(key),
                  self.key.dropLast(2) == key[...] else { return nil }
            return possessive
        }
    }

    /// The punctuation and symbols a word is matched without at its ends,
    /// as the transcript's words are compared (`TranscriptEditAlignment`).
    private static let edgeMarks = CharacterSet.punctuationCharacters.union(.symbols)

    /// `text`'s runs between spaces, each split around its letters.
    private static func tokens(of text: String) -> [Token] {
        text.split(whereSeparator: \.isWhitespace).map { run in
            let isMark = { (character: Character) in character.unicodeScalars.allSatisfy(edgeMarks.contains) }
            let leading = run.prefix(while: isMark)
            let rest = run.dropFirst(leading.count)
            let trailingCount = rest.reversed().prefix(while: isMark).count
            return Token(
                leading: String(leading),
                core: String(rest.dropLast(trailingCount)),
                trailing: String(rest.suffix(trailingCount))
            )
        }
    }

    /// `text` with `rule`'s pattern replaced wherever its words stand whole,
    /// one after another, with no punctuation between them, and how many
    /// times. The words around a match keep their punctuation, and the last
    /// keeps a possessive ending.
    private static func replacingWholeWords(of rule: TranscriptCleanupRule, in text: String) -> (String, Int) {
        let pattern = tokens(of: rule.pattern).map(\.key)
        let tokens = tokens(of: text)
        guard !pattern.isEmpty, tokens.count >= pattern.count else { return (text, 0) }
        var output: [String] = []
        var count = 0
        var index = 0
        while index < tokens.count {
            let end = index + pattern.count
            guard end <= tokens.count, let ending = ending(of: pattern, matching: tokens[index..<end]) else {
                output.append(tokens[index].leading + tokens[index].core + tokens[index].trailing)
                index += 1
                continue
            }
            let matched = tokens[index..<end].map(\.core).joined(separator: " ")
            output.append(tokens[index].leading + adapted(rule.replacement, toMatch: matched) + ending + tokens[end - 1].trailing)
            count += 1
            index = end
        }
        return count == 0 ? (text, 0) : (output.joined(separator: " "), count)
    }

    /// The ending the last of `words`, as many tokens as `pattern` has
    /// words, keeps when they are the pattern's words with nothing but
    /// spaces between them: "" for the pattern's very words, a possessive
    /// "'s" left over (`Token.ending(matching:)`); nil when they are not.
    private static func ending(of pattern: [String], matching words: ArraySlice<Token>) -> String? {
        var ending = ""
        for (offset, (key, word)) in zip(pattern, words).enumerated() {
            guard !word.core.isEmpty else { return nil }
            if offset > 0, !word.leading.isEmpty { return nil }
            if offset < pattern.count - 1 {
                guard word.key == key, word.trailing.isEmpty else { return nil }
            } else {
                guard let left = word.ending(matching: key) else { return nil }
                ending = left
            }
        }
        return ending
    }

    // MARK: - Letters Inside Words

    /// `text` with `rule`'s pattern replaced wherever its letters stand, in
    /// any case, and how many times.
    private static func replacingLetters(of rule: TranscriptCleanupRule, in text: String) -> (String, Int) {
        var output = ""
        var rest = text[...]
        var count = 0
        while let range = rest.range(of: rule.pattern, options: .caseInsensitive) {
            output += rest[..<range.lowerBound]
            output += adapted(rule.replacement, toMatch: String(rest[range]))
            rest = rest[range.upperBound...]
            count += 1
        }
        return count == 0 ? (text, 0) : (output + rest, count)
    }

    // MARK: - Case and Examples

    /// `replacement` in the case of `matched`, the text it replaces: all
    /// capitals for a match of more than one letter in capitals alone, a
    /// capital first letter for a match that begins with one, and as the
    /// rule writes it otherwise.
    static func adapted(_ replacement: String, toMatch matched: String) -> String {
        let letters = matched.filter(\.isLetter)
        if letters.count > 1, letters.allSatisfy(\.isUppercase) {
            return replacement.uppercased()
        }
        guard letters.first?.isUppercase == true, let first = replacement.firstIndex(where: \.isLetter) else {
            return replacement
        }
        return String(replacement[..<first]) + replacement[first].uppercased() + String(replacement[replacement.index(after: first)...])
    }

    /// An example of the change from `before` to `after`, one sentence
    /// before and after a rule: the words that changed, with up to
    /// `contextWords` words on each side, and "…" where words were left out.
    private static func example(from before: String, to after: String) -> Example {
        let old = before.split(whereSeparator: \.isWhitespace).map(String.init)
        let new = after.split(whereSeparator: \.isWhitespace).map(String.init)
        // The words both begin with, and then end with, apart from those.
        let prefix = zip(old, new).prefix(while: { $0 == $1 }).count
        let suffix = zip(old.dropFirst(prefix).reversed(), new.dropFirst(prefix).reversed()).prefix(while: { $0 == $1 }).count
        /// The changed words of `words` with their context.
        func window(_ words: [String]) -> String {
            let start = max(0, prefix - contextWords)
            let end = min(words.count, words.count - suffix + contextWords)
            let shown = words[start..<end].joined(separator: " ")
            return (start > 0 ? "…" : "") + shown + (end < words.count ? "…" : "")
        }
        return Example(before: window(old), after: window(new))
    }
}
