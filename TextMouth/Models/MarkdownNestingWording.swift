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
        "nests quotes, lists, or emphasis more than \(limit.formatted()) levels deep"
    }
}
