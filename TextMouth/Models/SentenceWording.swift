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

    /// `first` and `second` as two sentences of one text.
    private static func pair(_ first: String, _ second: String) -> String {
        String(localized: "\(first) \(second)",
               comment: "Joins two whole sentences into one text. %1$@ is the first sentence and %2$@ the second. English puts a space between them; Japanese and Chinese join sentences with no space at all, so change only the separator.")
    }
}
