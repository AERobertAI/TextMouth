import Foundation

// MARK: - What the Interpreter Reads from a Document

/// One piece of a paragraph's content (FMT47).
enum RTFInline: Equatable {
    /// Words, with the emphasis and the font size (in half points, `\fsN`)
    /// they were set in. The size is kept for the guess at headings in a
    /// document that names none (`RTFSizeHeadings`).
    case text(String, bold: Bool, italic: Bool, size: Int)
    /// `\line`: a line break inside the paragraph.
    case lineBreak
    /// The beginning of page `n`, written where the page's first letter or
    /// digit is (`TextutilPageBreaks`).
    case pageBreak(Int)
}

/// A paragraph's content.
struct RTFParagraph: Equatable {
    /// The paragraph's content, in order.
    var inlines: [RTFInline] = []

    /// The paragraph's words with no markup: what a listener hears.
    var plainText: String {
        inlines.reduce(into: "") { text, inline in
            switch inline {
            case .text(let words, _, _, _): text += words
            case .lineBreak: text += " "
            case .pageBreak: break
            }
        }
    }

    /// Whether the paragraph holds a character other than white space.
    var hasWords: Bool {
        inlines.contains { inline in
            if case .text(let words, _, _, _) = inline {
                return words.unicodeScalars.contains { !$0.properties.isWhitespace }
            }
            return false
        }
    }
}

/// A table: its rows of cells, each cell the paragraphs it holds.
struct RTFTable: Equatable {
    var rows: [[[RTFParagraph]]] = []
}

/// One block of the document's body, in order.
enum RTFBlock: Equatable {
    /// A paragraph of body text.
    case paragraph(RTFParagraph)
    /// A heading at `level`, 1 to 6.
    case heading(RTFParagraph, level: Int)
    /// A list item at nesting depth `level` (0 is the outermost list).
    case listItem(RTFParagraph, level: Int, numbered: Bool)
    /// A table.
    case table(RTFTable)
}

/// What a whole document read: its blocks and the names its `\info` gives.
struct RTFDocument {
    /// The body, in order.
    var blocks: [RTFBlock] = []
    /// The `\title` of the document's `\info`, empty when it has none.
    var title = ""
    /// The `\author` of the document's `\info`, empty when it has none.
    var author = ""
    /// How many page breaks the body holds (`\page` and the rest), counted
    /// even where no page begins after them. A document with more than
    /// `TextutilPageBreaks.maximumPages - 1` has no pages at all.
    var pageBreaks = 0
}
