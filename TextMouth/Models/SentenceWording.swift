import Foundation

/// The one place TextMouth joins whole sentences into a longer text, as a
/// spoken summary or an announcement is made of several (FR34).
///
/// English separates sentences with a space. Japanese and Chinese write them
/// with none, so the separator is part of a localized pattern instead of a
/// `" "` typed at each call site: a translator changes it once for every
/// text that joins sentences.
enum SentenceWording {
    /// `sentences` joined into one text, each already ended with its own
    /// full stop, in order. Nothing is joined to nothing: an empty list is
    /// "" and a single sentence is returned as it is, so no stray separator
    /// is ever spoken or brailled. Empty sentences are not skipped here;
    /// the caller leaves out what it does not say.
    static func joined(_ sentences: [String]) -> String {
        guard let first = sentences.first else { return "" }
        // Fold pairwise, so each pair is joined by the language's own
        // pattern, whichever number of sentences there are.
        return sentences.dropFirst().reduce(first) { text, next in
            pair(text, next)
        }
    }

    // MARK: - Labels and Parts

    /// A label and its value on one line, "Elapsed: 1:04". English puts a
    /// colon and a space between them; another language may change it (French
    /// puts a space before the colon).
    static func labelled(_ label: String, _ value: String) -> String {
        // Translators: A label and its value on one line, such as "Elapsed: 1:04". %1$@ is the label and %2$@ its value. English puts a colon and a space between them.
        InterfaceText.line("common.valueColonValue", "\(label): \(value)")
    }

    /// `parts` of a spoken or shown label, in order, joined with commas:
    /// "Mr., Pattern: Mr, Case sensitive". One part is returned as it is.
    static func commaJoined(_ parts: [String]) -> String {
        parts.dropFirst().reduce(parts.first ?? "") { text, next in
            // Translators: Joins two parts of a label with a comma. %1$@ is the text so far and %2$@ the next part. English puts a comma and a space between them.
            InterfaceText.line("sentence.commaJoined", "\(text), \(next)")
        }
    }

    /// `parts` of a status line, in order, joined with semicolons: "212
    /// matches in 31 books; showing up to 20 in each book". One part is
    /// returned as it is.
    static func semicolonJoined(_ parts: [String]) -> String {
        parts.dropFirst().reduce(parts.first ?? "") { text, next in
            // Translators: Joins two parts of a status line with a semicolon. %1$@ is the text so far and %2$@ the next part. English puts a semicolon and a space between them.
            InterfaceText.line("common.valueSemicolonValue", "\(text); \(next)")
        }
    }

    // MARK: - Pairs

    /// `first` and `second` as two sentences of one text.
    private static func pair(_ first: String, _ second: String) -> String {
        // Translators: Joins two whole sentences into one text. %1$@ is the first sentence and %2$@ the second. English puts a space between them; Japanese and Chinese join sentences with no space at all, so change only the separator.
        InterfaceText.line("sentence.pair", "\(first) \(second)")
    }
}
