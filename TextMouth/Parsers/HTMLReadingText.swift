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
/// - An element the caller leaves out (`leavingOut`) contributes no words
///   either, though it keeps the words on either side apart as any element
///   of its kind does. The converter leaves out, from a heading's label, the
///   page-break elements whose text is no more than their page's number,
///   which it leaves out of the body text too (PG05, ST02).
/// - An image contributes its alt text, read like any other text.
/// - In the flowing layout each run of ASCII whitespace in text is read as
///   one space (`collapsingWhitespace`), and a space never follows
///   whitespace already read. Text inside an element that preserves
///   whitespace (`pre`, `textarea`) is read exactly.
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
    /// The elements whose words this reading leaves out (`leavingOut`),
    /// compared by identity: two elements with the same markup are two.
    private let leftOut: Set<ObjectIdentifier>
    /// How many enclosing elements preserve the whitespace of their text.
    private var preservedWhitespaceDepth = 0
    /// How many enclosing elements the Markdown converter writes as plain
    /// text of their own: headings, `pre`, and `code`. A heading inside one
    /// of them is part of that text, so it is not a heading of the reading.
    private var flattenedDepth = 0

    /// Elements other than headings that the converter writes as plain text.
    private static let flattenedTags: Set<String> = ["pre", "code"]

    /// A reading laid out as `layout`. The direct reader also records the
    /// headings it passes, placing each where its label begins. A reading
    /// that is given `leavingOut` skips those elements (and what they
    /// hold), wherever they stand below the node it reads.
    init(layout: Layout = .flowing, recordsHeadings: Bool = false, leavingOut: [Element] = []) {
        self.layout = layout
        self.recordsHeadings = recordsHeadings
        leftOut = Set(leavingOut.map(ObjectIdentifier.init))
    }

    // MARK: - Shared Readings

    /// Each run of HTML's ASCII whitespace (tab, line feed, form feed,
    /// carriage return, and space) as a single space. Every other character,
    /// including a no-break space, the Unicode space separators, and U+2028,
    /// is text and is kept. This is SwiftSoup's reading of HTML text
    /// (`StringUtil.normaliseWhitespace`, which the tests hold it to), done
    /// byte by byte: every character it collapses is a single ASCII byte in
    /// UTF-8, where no byte of a longer character can be mistaken for one.
    /// It runs several times faster, and it runs for every text node of every
    /// book a cache rebuild converts.
    static func collapsingWhitespace(_ text: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        var inWhitespace = false
        for byte in text.utf8 {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0C, 0x0D:
                if !inWhitespace {
                    bytes.append(0x20)
                }
                inWhitespace = true
            default:
                bytes.append(byte)
                inWhitespace = false
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A heading's label: the words of its subtree on one line, with no
    /// whitespace (Unicode White_Space) at either end. Only whitespace is
    /// trimmed; `CharacterSet.whitespaces` also holds characters such as
    /// U+200B that are words of the reading. The Markdown converter writes
    /// exactly this label, so both readings list the same heading.
    ///
    /// `leavingOut` names the elements below the heading whose words are not
    /// part of its label. The converter names the page-break elements whose
    /// text is only their page's number: a heading "Part <page 9>Two" is the
    /// label "Part Two", the number being the page's, not the heading's, and
    /// the page itself written before the heading.
    static func label(of element: Element, leavingOut: [Element] = []) -> String {
        let scalars = inlineText(of: element, leavingOut: leavingOut).unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
              let last = scalars.lastIndex(where: { !$0.properties.isWhitespace }) else { return "" }
        return String(String.UnicodeScalarView(scalars[first...last]))
    }

    /// The words of an element read inline, with whitespace collapsed. One
    /// space remains at either end when whitespace or a boundary begins or
    /// ends the element, so a caller can keep it apart from its neighbors.
    /// The elements in `leavingOut`, wherever they stand below `element`,
    /// add no words.
    static func inlineText(of element: Element, leavingOut: [Element] = []) -> String {
        var reading = HTMLReadingText(leavingOut: leavingOut)
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
        // An element left out adds no words, nor does anything it holds, but
        // it still keeps the words on either side apart as the converter
        // keeps them apart around an element it does not read: a block is a
        // paragraph boundary, a table cell a word boundary, and a line
        // break none of its own. Most readings leave nothing out, and this
        // runs for every element of every book, so the lookup is skipped
        // for them.
        if !leftOut.isEmpty, leftOut.contains(ObjectIdentifier(element)) {
            separate(at: tag == "br" ? .none : HTMLReadingBoundary.of(element, tag: tag))
            return
        }
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
        // label's first word will begin. A heading is recorded exactly when
        // the cache's reader keeps one: its label is not blank.
        if recordsHeadings, flattenedDepth == 0, let headingLevel {
            let label = Self.label(of: element)
            if !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
    /// neighboring text nodes never read as two spaces. Scalars decide, since
    /// a combining mark after a space joins it into one Character that
    /// `hasPrefix(" ")` would not match; only the space itself is dropped.
    private mutating func appendFlowing(_ collapsed: String) {
        var value = collapsed
        if value.unicodeScalars.first == " ", endsWithWhitespace {
            value.unicodeScalars.removeFirst()
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
            if !text.isEmpty, text.unicodeScalars.last != "\n" {
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
