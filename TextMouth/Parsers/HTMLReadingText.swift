import Foundation
import SwiftSoup

/// How an HTML element separates the words around it when a book is read.
///
/// Both HTML reading paths follow this one table, so a freshly opened HTML
/// book (`HTMLParser`) and its Markdown cache (`HTMLToMarkdownConverter`)
/// agree on where one word ends and the next begins. The boundaries are
/// SwiftSoup's block elements (`Element.isBlock()`, which include table
/// cells, list items, definition terms and descriptions, and captions) and
/// `br`.
enum HTMLReadingBoundary: Equatable {
    /// Phrasing content: its words run on into the words beside it, spaced
    /// exactly as the source spaces them.
    case none
    /// The words on either side stay separate words, with at least a space
    /// between them: a table cell within its row, a line break, and the edit
    /// elements SwiftSoup counts as blocks (`ins`, `del`, `s`) although they
    /// mark words inside running prose.
    case word
    /// A block of its own: the words before and after it belong to other
    /// paragraphs.
    case paragraph

    /// Boundaries that separate words without ending a paragraph.
    private static let wordTags: Set<String> = ["br", "td", "th", "ins", "del", "s"]

    /// The boundary `element` makes; `tag` is its lowercase tag name.
    static func of(_ element: Element, tag: String) -> HTMLReadingBoundary {
        if wordTags.contains(tag) {
            return .word
        }
        return element.isBlock() ? .paragraph : .none
    }
}

/// The words an HTML subtree contributes to a reading, in document order.
///
/// The direct HTML reader reads a whole book body with it. The Markdown
/// converter reads with it every part it writes as plain text rather than
/// as Markdown structure: heading labels, code spans, and preformatted
/// blocks. So both readings follow the same rules:
/// - `script` and `style`, and content outside the rendered reading flow
///   (`PublicationSemantics.isExcludedFromReadingFlow`), contribute nothing.
/// - An image contributes its alt text, read like any other text.
/// - In the flowing layout each run of whitespace in text is read as one
///   space (`collapsingWhitespace`), and a space never follows whitespace
///   already read. Text inside an element that preserves whitespace (`pre`,
///   `textarea`) is read exactly.
/// - At every boundary (`HTMLReadingBoundary`), before the element and again
///   after it, a space keeps the words on either side apart unless
///   whitespace already does.
struct HTMLReadingText {
    /// How text and boundaries are laid out.
    enum Layout {
        /// Running text: whitespace collapses and every boundary is a space.
        case flowing
        /// The text of a preformatted block: every character exactly, with a
        /// new line for each line break and before and after each block.
        case preformatted
    }

    /// The text read so far.
    private(set) var text = ""
    /// The headings read so far, when this reading records them.
    private(set) var headings: [Heading] = []
    /// The length of `text` in UTF-16 code units, the coordinates of heading
    /// offsets. It is counted as text grows so reading stays linear.
    private var utf16Length = 0
    private let layout: Layout
    private let recordsHeadings: Bool
    /// How many enclosing elements preserve the whitespace of their text.
    private var preservedWhitespaceDepth = 0
    /// How many enclosing elements the Markdown converter writes as plain
    /// text of their own: headings, `pre`, and `code`. A heading inside one
    /// of them is part of that text, so it is not a heading of the reading.
    private var flattenedDepth = 0

    /// Elements other than headings that the converter writes as plain text.
    private static let flattenedTags: Set<String> = ["pre", "code"]

    /// A reading laid out as `layout`. The direct reader also records the
    /// headings it passes, placing each where its label begins.
    init(layout: Layout = .flowing, recordsHeadings: Bool = false) {
        self.layout = layout
        self.recordsHeadings = recordsHeadings
    }

    // MARK: - Shared Readings

    /// Each run of whitespace as a single space. This is SwiftSoup's reading
    /// of HTML text: a character is whitespace when `Character.isWhitespace`
    /// says so, which includes no-break spaces and every line separator.
    static func collapsingWhitespace(_ text: String) -> String {
        StringUtil.normaliseWhitespace(text)
    }

    /// A heading's label: the words of its subtree on one line, with no
    /// whitespace at either end. The Markdown converter writes exactly this
    /// label, so both readings list the same heading.
    static func label(of element: Element) -> String {
        inlineText(of: element).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The words of an element read inline, with whitespace collapsed. One
    /// space remains at either end when whitespace or a boundary begins or
    /// ends the element, so a caller can keep it apart from its neighbors.
    static func inlineText(of element: Element) -> String {
        var reading = HTMLReadingText()
        reading.appendChildren(of: element)
        return collapsingWhitespace(reading.text)
    }

    /// The text of a preformatted element exactly as it is laid out.
    static func preformattedText(of element: Element) -> String {
        var reading = HTMLReadingText(layout: .preformatted)
        reading.appendChildren(of: element)
        return reading.text
    }

    /// The level of a heading tag (`h1` through `h6`), or nil for any other tag.
    static func headingLevel(of tag: String) -> Int? {
        guard tag.count == 2, tag.hasPrefix("h"),
              let level = tag.last?.wholeNumberValue, (1...6).contains(level) else { return nil }
        return level
    }

    // MARK: - Reading Nodes

    /// Read every child of `node` in document order.
    mutating func appendChildren(of node: Node) {
        for child in node.getChildNodes() {
            append(child)
        }
    }

    /// Read one node and everything inside it.
    mutating func append(_ node: Node) {
        if let textNode = node as? TextNode {
            appendText(textNode.getWholeText())
            return
        }
        // Comments, doctypes, and the data inside script and style elements
        // are never read.
        guard let element = node as? Element else { return }
        let tag = element.tagName().lowercased()
        guard tag != "script", tag != "style",
              !PublicationSemantics.isExcludedFromReadingFlow(element) else { return }
        switch tag {
        case "br":
            breakLine()
        case "img":
            appendFlowing(Self.collapsingWhitespace((try? element.attr("alt")) ?? ""))
        default:
            appendElement(element, tag: tag)
        }
    }

    /// Read an element between its boundaries, recording it first when it
    /// is a heading of this reading.
    private mutating func appendElement(_ element: Element, tag: String) {
        let boundary = HTMLReadingBoundary.of(element, tag: tag)
        separate(at: boundary)
        let headingLevel = Self.headingLevel(of: tag)
        // The separator is already written, so the offset is where the
        // label's first word will begin.
        if recordsHeadings, flattenedDepth == 0, let headingLevel {
            let label = Self.label(of: element)
            if !label.isEmpty {
                headings.append(Heading(level: headingLevel, text: label, characterOffset: utf16Length))
            }
        }
        let preservesWhitespace = element.tag().preserveWhitespace()
        let flattens = headingLevel != nil || Self.flattenedTags.contains(tag)
        preservedWhitespaceDepth += preservesWhitespace ? 1 : 0
        flattenedDepth += flattens ? 1 : 0
        appendChildren(of: element)
        preservedWhitespaceDepth -= preservesWhitespace ? 1 : 0
        flattenedDepth -= flattens ? 1 : 0
        separate(at: boundary)
    }

    // MARK: - Writing Text

    /// Read a text node: exactly where whitespace is preserved, otherwise
    /// with its whitespace collapsed.
    private mutating func appendText(_ raw: String) {
        if layout == .preformatted || preservedWhitespaceDepth > 0 {
            write(raw)
        } else {
            appendFlowing(Self.collapsingWhitespace(raw))
        }
    }

    /// Append collapsed text. A leading space is dropped after whitespace, so
    /// neighboring text nodes never read as two spaces.
    private mutating func appendFlowing(_ collapsed: String) {
        var value = collapsed
        if value.hasPrefix(" "), endsWithWhitespace {
            value.removeFirst()
        }
        write(value)
    }

    /// Keep the words on either side of a boundary apart.
    private mutating func separate(at boundary: HTMLReadingBoundary) {
        switch (boundary, layout) {
        case (.none, _):
            return
        case (.paragraph, .preformatted):
            // A block inside preformatted text sits on lines of its own.
            if !text.isEmpty, !text.hasSuffix("\n") {
                write("\n")
            }
        default:
            if !endsWithWhitespace {
                write(" ")
            }
        }
    }

    /// A line break: a new line in preformatted text, otherwise a space
    /// between the words it separates.
    private mutating func breakLine() {
        if layout == .preformatted {
            write("\n")
        } else if !endsWithWhitespace {
            write(" ")
        }
    }

    /// Whether the text read so far ends with whitespace.
    private var endsWithWhitespace: Bool {
        text.unicodeScalars.last?.properties.isWhitespace ?? false
    }

    /// Append to the text and advance its UTF-16 length.
    private mutating func write(_ value: String) {
        text += value
        utf16Length += value.utf16.count
    }
}
