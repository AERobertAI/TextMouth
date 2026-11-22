import Foundation

/// The words that say a text of Markdown nests too deeply, for every sentence
/// that says it (the export's refusal, `BookExportWording.nestedTooDeeply`, and
/// Edit Text's, `BookTextEditWording`): one phrase, so that the two cannot
/// drift apart.
enum MarkdownNestingWording {
    /// The verb phrase of every such sentence: "nests quotes, lists, or
    /// emphasis more than 128 levels deep". `limit` is the deepest nesting
    /// read (`MarkupGuard.Limits.deepestNesting`).
    static func nestsTooDeeply(limit: Int) -> String {
        // Translators: Verb phrase inside the sentences that refuse a text of Markdown that nests too deeply. %lld is the deepest nesting read, a count of levels. The subject comes before it and a clause follows.
        InterfaceText.line("markdownNesting.nestsTooDeeply", "nests quotes, lists, or emphasis more than \(number: limit) levels deep")
    }
}
