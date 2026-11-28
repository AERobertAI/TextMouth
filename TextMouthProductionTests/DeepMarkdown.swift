import Foundation
@testable import TextMouth

/// The shapes of deeply nested Markdown that the tests of the nesting limit
/// (`MarkdownDepthLimitTests`, `ExportDocumentWalkerNestingTests`,
/// `BookExportNestingTests`, and Edit Text's) write, one source for all of
/// them. Each takes how many levels it nests, and says where its words are.
///
/// A shape's depth is what the limit counts, so each has one edge where a
/// text is read and one level more is refused: `edge(of:)`.
enum DeepMarkdown {

    // MARK: - The Shapes

    /// `count` block quotes around some words, written `> > > words`.
    static func quotes(_ count: Int) -> String {
        String(repeating: "> ", count: count) + "Quoted words"
    }

    /// `count` nested lists, each indented two columns deeper than the one before.
    static func lists(_ count: Int) -> String {
        (0..<count).map { String(repeating: " ", count: 2 * $0) + "- " + ($0 == count - 1 ? "Listed words" : "item") }
            .joined(separator: "\n")
    }

    /// `count` levels of emphasis and strong text around some words, one
    /// inside the other, written `*w **w *w core w* w** w*`.
    static func emphasis(_ count: Int) -> String {
        let delimiters = (0..<count).map { $0.isMultiple(of: 2) ? "*" : "**" }
        return delimiters.map { "\($0)w " }.joined() + "core" + delimiters.reversed().map { " w\($0)" }.joined()
    }

    /// One link around `count` images, each inside the description of the one before.
    static func links(_ count: Int) -> String {
        "[" + String(repeating: "![w ", count: count) + "core" + String(repeating: "](u)", count: count)
            + "](https://example.org/)"
    }

    /// A table inside `count` block quotes, each line of it quoted.
    static func quotedTable(_ count: Int) -> String {
        let prefix = String(repeating: "> ", count: count)
        return ["| a | b |", "|---|---|", "| c | d |"].map { prefix + $0 }.joined(separator: "\n")
    }

    // MARK: - The Edges

    /// A shape that nests, with the words it holds.
    struct Shape {
        /// What the shape is called, for a failure's message.
        let name: String
        /// The Markdown of the shape `count` levels deep.
        let text: (Int) -> String
        /// A word of the text that every walk keeps.
        let word: String
        /// The most levels the shape nests and is still read, under the
        /// standard limits: the count of containers for quotes and lists, the
        /// tree's depth for emphasis and links (a tree of 272 levels, whose
        /// document, paragraph, and text are three of them, and a link's
        /// own is a fourth).
        let edge: Int
    }

    /// Every shape, with its edge under `limits`.
    static func shapes(under limits: MarkupGuard.Limits = .standard) -> [Shape] {
        let tree = MarkdownNesting.deepestTree(under: limits)
        return [
            Shape(name: "quotes", text: quotes, word: "Quoted words", edge: limits.deepestNesting),
            Shape(name: "lists", text: lists, word: "Listed words", edge: limits.deepestNesting),
            Shape(name: "emphasis", text: emphasis, word: "core", edge: tree - 3),
            Shape(name: "links", text: links, word: "core", edge: tree - 4),
        ]
    }
}
