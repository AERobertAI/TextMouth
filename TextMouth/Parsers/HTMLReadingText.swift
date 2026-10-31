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

/// How deep both HTML readers follow nested elements: the direct reader
/// (`HTMLReadingText`) and the Markdown converter (`HTMLToMarkdownConverter`)
/// each recurse once for every level of nesting, and SwiftSoup builds a tree
/// of any depth, so markup that opens thousands of elements without closing
/// them (a feed's item, a web page, a book's chapter) would overflow the
/// 512 KiB stack of the worker threads that imports and feed refreshes run
/// on, and end TextMouth. Past `deepestLevel`, each reader reads an
/// element's whole subtree as one paragraph of its words instead
/// (`words(of:)`), keeping every word and no structure.
///
/// SwiftSoup recurses too, while it builds that tree and when it first reads
/// an element's attributes: before a parse, `mayNest(_:deeperThan:as:)` says
/// whether markup may nest past `deepestParsedLevel`, too deep for that, and
/// the one parse of markup from outside TextMouth (`parse(_:baseURI:)`) reads
/// such markup as its words alone.
enum HTMLNesting {
    /// The deepest level of nested elements the readers follow, counted
    /// from where a reading begins. A book's chapter or a feed's item rarely
    /// nests half as deep, and below it the words are kept all the same.
    /// It is this low because the converter's every level costs several
    /// kilobytes of a 512 KiB stack in a debug build (100 levels overflowed
    /// it in the tests), and it keeps the Markdown the converter writes
    /// shallow enough for the Markdown parser, which recurses as well.
    static let deepestLevel = 32

    /// The deepest level of nested elements markup may reach and still be
    /// parsed into elements. SwiftSoup itself calls itself once for every
    /// ancestor of an element when it reads most end tags (`</li>`, `</p>`,
    /// `</span>`) and when an element's attributes are first read, at about
    /// 200 bytes of stack a level in a debug build: about 2,600 levels
    /// overflow the 512 KiB stack of a worker thread and end TextMouth.
    /// 1,000 levels need about 200 KiB, and the list items and the like that
    /// count no level of their own (`OpenElements`) at most double that. No
    /// real page comes within a tenth of it.
    static let deepestParsedLevel = 1_000

    /// The words of everything `element` holds, on one line with its
    /// whitespace collapsed and a space wherever a block or a line break
    /// separated words. SwiftSoup's text walk (`NodeTraversor`) uses a loop,
    /// not recursion, so a subtree of any depth is safe. Unlike a reading,
    /// it keeps hidden content and reads no image's alt text, a difference
    /// only markup nested past `deepestLevel` ever meets.
    static func words(of element: Element) -> String {
        (try? element.text()) ?? ""
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
    /// How many elements enclose the node being read, counted from where
    /// this reading began; past `HTMLNesting.deepestLevel` an element's
    /// subtree is read as one paragraph of its words, without recursion.
    private var elementDepth = 0

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
        // the cache's reader keeps one: its label is not blank, and it is not
        // nested past the deepest level followed, where the converter writes
        // only words (`HTMLNesting`).
        if recordsHeadings, flattenedDepth == 0, elementDepth < HTMLNesting.deepestLevel, let headingLevel {
            let label = Self.label(of: element)
            if !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                headings.append(Heading(level: headingLevel, text: label, characterOffset: utf16Length))
            }
        }
        let preservesWhitespace = element.tag().preserveWhitespace()
        let flattens = headingLevel != nil || Self.flattenedTags.contains(tag)
        preservedWhitespaceDepth += preservesWhitespace ? 1 : 0
        flattenedDepth += flattens ? 1 : 0
        appendContents(of: element)
        preservedWhitespaceDepth -= preservesWhitespace ? 1 : 0
        flattenedDepth -= flattens ? 1 : 0
        separate(at: boundary)
    }

    /// Read what `element` holds: its children, one level deeper, or, at the
    /// deepest level the readers follow (`HTMLNesting`), all of its words as
    /// one paragraph, as the Markdown converter writes them there, so a
    /// deeply nested page never overflows the stack and both readings agree.
    private mutating func appendContents(of element: Element) {
        guard elementDepth < HTMLNesting.deepestLevel else {
            separate(at: .paragraph)
            appendFlowing(HTMLNesting.words(of: element))
            separate(at: .paragraph)
            return
        }
        elementDepth += 1
        appendChildren(of: element)
        elementDepth -= 1
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

// MARK: - The Parse of Untrusted Markup

extension HTMLNesting {
    /// `html` parsed exactly as `SwiftSoup.parse(html, baseURI)` parses it:
    /// by SwiftSoup's HTML tree builder or, when the markup begins with an
    /// XML declaration, its XML tree builder (`TreeBuilder`). Markup whose
    /// elements may nest past `deepestParsedLevel` reaches neither: it is
    /// read as its words alone, in one paragraph (`markupOfWords(in:as:)`),
    /// keeping every word and no heading, list, link, or page, and the log
    /// says so once. Every reader of markup from outside TextMouth parses
    /// through here: a feed's item, a fetched page, an EPUB or DAISY
    /// document, an HTML book or web archive, and textutil's HTML of a
    /// document.
    static func parse(_ html: String, baseURI: String = "") throws -> Document {
        try parse(html, readBy: TreeBuilder(reading: html)) { try SwiftSoup.parse($0, baseURI) }
    }

    /// `html` parsed exactly as `SwiftSoup.parseBodyFragment(html, baseURI)`
    /// parses it, as the body of an empty document, or, when its elements
    /// may nest past `deepestParsedLevel`, as its words alone, as
    /// `parse(_:baseURI:)` reads them. SwiftSoup reads a fragment with its
    /// HTML tree builder, whatever it begins with.
    static func parseBodyFragment(_ html: String, baseURI: String = "") throws -> Document {
        try parse(html, readBy: .html) { try SwiftSoup.parseBodyFragment($0, baseURI) }
    }

    /// `html` handed to `swiftSoup` as it is, when `builder` nests its
    /// elements within `deepestParsedLevel`, or else its words alone in one
    /// paragraph, with one event in the log naming only the markup's length.
    private static func parse(
        _ html: String,
        readBy builder: TreeBuilder,
        with swiftSoup: (String) throws -> Document
    ) throws -> Document {
        guard mayNest(html, deeperThan: deepestParsedLevel, as: builder) else {
            return try swiftSoup(html)
        }
        DiagnosticLog.event(
            .import,
            "HTML_TOO_DEEP: \(html.utf8.count) bytes of markup may nest past \(deepestParsedLevel) levels; read as plain words"
        )
        return try swiftSoup(markupOfWords(in: html, as: builder))
    }
}

// MARK: - Nesting Read Before SwiftSoup Parses

extension HTMLNesting {
    /// Which of SwiftSoup's two tree builders reads markup, which decides how
    /// deep its elements nest.
    enum TreeBuilder: Equatable {
        /// The HTML tree builder, which follows HTML's rules: a void element
        /// such as `br` holds nothing, an element such as `p` or `li` ends
        /// where the next of its kind begins, and the text of `script`,
        /// `style`, `noframes`, `title`, and `plaintext` is not markup.
        case html
        /// The XML tree builder, which `SwiftSoup.parse` reads markup with
        /// when it begins with an XML declaration, as most EPUB chapters and
        /// navigation documents do. Every element not closed by `/>` holds
        /// what follows it until an end tag of exactly its name, capitals and
        /// all, closes the nearest one open: no element is void and no text
        /// is raw, so a `<br>` or an unclosed `<p>` nests there.
        case xml

        /// The builder `SwiftSoup.parse(_:_:)` reads `markup` with, by
        /// SwiftSoup's own test: past any leading whitespace, the markup
        /// begins with `<?xml`.
        init(reading markup: String) {
            self = markup.drop(while: \.isWhitespace).hasPrefix("<?xml") ? .xml : .html
        }
    }

    /// Whether the elements `builder` makes of `html` may nest deeper than
    /// `limit` levels. It reads the markup's UTF-8 bytes once, in a loop,
    /// and stops as soon as the limit is passed: tags as SwiftSoup's
    /// tokenizer reads them (`MarkupTokens`), and the elements they open and
    /// close as SwiftSoup's tree builder keeps them (`OpenElements`).
    ///
    /// It may count more levels than SwiftSoup's tree holds, where markup is
    /// malformed (a `span` left open in every list item keeps levels that
    /// SwiftSoup closes), but it must never count fewer of the elements it
    /// counts: too few would hand SwiftSoup markup it recurses through too
    /// deeply (`deepestParsedLevel`).
    static func mayNest(_ html: String, deeperThan limit: Int, as builder: TreeBuilder) -> Bool {
        var markup = html
        return markup.withUTF8 { bytes in
            var tokens = MarkupTokens(bytes)
            var open = OpenElements(builder: builder)
            while let token = tokens.next() {
                switch token {
                case let .startTag(name, closesItself):
                    guard let text = open.open(tokens.name(at: name, as: builder), closesItself: closesItself) else {
                        break
                    }
                    // An element whose content is text holds it one level
                    // deeper than the elements open around it.
                    if open.depth + 1 > limit {
                        return true
                    }
                    if text == .plaintext {
                        // Everything after it is text: no tag follows.
                        return false
                    }
                    tokens.skipText(of: text)
                case let .endTag(name):
                    open.close(tokens.name(at: name, as: builder))
                case .text, .cdata, .nothing:
                    break
                }
                if open.depth > limit {
                    return true
                }
            }
            return false
        }
    }

    /// The words of `html` alone, as the markup of one paragraph: every tag
    /// a space, by the same reading of tags as `mayNest(_:deeperThan:as:)`;
    /// comments, doctypes, and the code of `script` and `style`, which no
    /// reading reads, left out; and every other word kept, with each `<` of
    /// the text escaped, so the paragraph holds no tag. Character references
    /// are left for SwiftSoup to read, as it reads them in the markup, but
    /// for those in the literal text of a CDATA section, `noframes`, or
    /// `plaintext`, which are escaped too. `builder` decides, as for
    /// SwiftSoup, which elements hold text rather than markup: under the
    /// XML tree builder, only the script and style left out.
    static func markupOfWords(in html: String, as builder: TreeBuilder) -> String {
        var markup = html
        return markup.withUTF8 { bytes in
            var tokens = MarkupTokens(bytes)
            var words = WordsMarkup(capacity: bytes.count)
            while let token = tokens.next() {
                switch token {
                case let .text(range):
                    words.append(range, of: bytes, literally: false)
                case let .cdata(range):
                    words.append(range, of: bytes, literally: true)
                case let .startTag(name, closesItself):
                    words.appendSpace()
                    let name = tokens.name(at: name, as: .html)
                    guard let element = RawTextElement(htmlName: name),
                          builder == .html || element == .script || element == .style,
                          element == .plaintext || !closesItself else { break }
                    let text = tokens.skipText(of: element)
                    switch element {
                    case .script, .style:
                        break
                    case .title:
                        words.append(text, of: bytes, literally: false)
                    case .noframes, .plaintext:
                        words.append(text, of: bytes, literally: true)
                    }
                case .endTag:
                    words.appendSpace()
                case .nothing:
                    break
                }
            }
            return words.paragraph
        }
    }
}

/// The markup `HTMLNesting.markupOfWords(in:as:)` writes: text in one
/// paragraph, with no tag in it.
private struct WordsMarkup {
    /// The markup so far, from the paragraph's start tag.
    private var bytes: [UInt8]

    /// How `<` and `&` are written in it as text.
    private static let lessThanReference = Array("&lt;".utf8)
    private static let ampersandReference = Array("&amp;".utf8)

    /// An empty paragraph, room made for `capacity` bytes of words.
    init(capacity: Int) {
        bytes = Array("<p>".utf8)
        bytes.reserveCapacity(capacity + 16)
    }

    /// A space where a tag stood, which keeps the words on either side apart.
    mutating func appendSpace() {
        bytes.append(0x20)
    }

    /// The text at `range` of `source`, each `<` escaped, and each `&` too
    /// when the text is literal, so SwiftSoup reads it as it is written.
    mutating func append(_ range: Range<Int>, of source: UnsafeBufferPointer<UInt8>, literally: Bool) {
        var runStart = range.lowerBound
        for index in range {
            let byte = source[index]
            guard byte == UInt8(ascii: "<") || (literally && byte == UInt8(ascii: "&")) else { continue }
            bytes.append(contentsOf: source[runStart..<index])
            bytes.append(contentsOf: byte == UInt8(ascii: "<") ? Self.lessThanReference : Self.ampersandReference)
            runStart = index + 1
        }
        bytes.append(contentsOf: source[runStart..<range.upperBound])
    }

    /// The finished paragraph.
    var paragraph: String {
        String(decoding: bytes + Array("</p>".utf8), as: UTF8.self)
    }
}

/// An element whose content SwiftSoup's HTML tokenizer reads as text rather
/// than markup, up to the element's own end tag. SwiftSoup 2.13.9 has only
/// these: it reads the contents of `textarea`, `xmp`, `iframe`, and
/// `noembed`, which HTML reads as text, as markup.
private enum RawTextElement: Equatable {
    /// Script data, where `<!--` and a `<script>` after it can hide an end
    /// tag (HTML's escaped and double-escaped states).
    case script
    /// Raw text, to the element's end tag.
    case style, noframes
    /// Escapable raw text (RCDATA): character references count. SwiftSoup
    /// also ends a title at a tag when no `</title` follows anywhere.
    case title
    /// Everything after the start tag, to the end of the markup.
    case plaintext

    /// The element named `name`, in small letters, when its content is text
    /// to SwiftSoup's HTML tokenizer.
    init?(htmlName name: String) {
        switch name {
        case "script": self = .script
        case "style": self = .style
        case "noframes": self = .noframes
        case "title": self = .title
        case "plaintext": self = .plaintext
        default: return nil
        }
    }
}

/// Markup's UTF-8 bytes, read piece by piece as SwiftSoup 2.13.9's tokenizer
/// (`TokeniserState`) reads them: text; start and end tags, whose attribute
/// values in quotes may hold `>`; comments, doctypes, processing
/// instructions, and CDATA sections; and, when asked (`skipText(of:)`), the
/// text of an element whose content is not markup. Each byte is read about
/// once, and no string is made but a tag's name.
private struct MarkupTokens {
    /// One piece of markup.
    enum Token {
        /// Character data up to the next `<`, or a `<` that begins no markup.
        case text(Range<Int>)
        /// The content of a CDATA section, which is text as it is written.
        case cdata(Range<Int>)
        /// A start tag: the bytes of its name, and whether it ends `/>`.
        case startTag(name: Range<Int>, closesItself: Bool)
        /// An end tag: the bytes of its name.
        case endTag(name: Range<Int>)
        /// A comment, a doctype, a processing instruction or another bogus
        /// comment, `</>`, or a tag the markup ends inside, which SwiftSoup
        /// drops: nothing of the document's text or elements.
        case nothing
    }

    /// The markup.
    let bytes: UnsafeBufferPointer<UInt8>
    /// Where the next piece begins.
    private(set) var position = 0

    /// The byte sequences the reader looks for.
    private static let scriptName = Array("script".utf8)
    private static let styleName = Array("style".utf8)
    private static let noframesName = Array("noframes".utf8)
    private static let titleName = Array("title".utf8)
    private static let commentStart = Array("--".utf8)
    private static let doctype = Array("doctype".utf8)
    private static let cdataStart = Array("[CDATA[".utf8)
    private static let cdataEnd = Array("]]>".utf8)
    private static let scriptEscape = Array("<!--".utf8)
    private static let titleEndTag = Array("</title".utf8)
    private static let capitalTitleEndTag = Array("</TITLE".utf8)

    init(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    // MARK: Bytes

    /// HTML's whitespace: tab, line feed, form feed, carriage return, space.
    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
    }

    /// An ASCII letter, the only character that begins a tag's name.
    static func isLetter(_ byte: UInt8) -> Bool {
        (byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A
    }

    /// `byte` with an ASCII capital made small.
    static func lowercased(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
    }

    /// The index of the first `byte` at or after `start`, or the end.
    func index(of byte: UInt8, from start: Int) -> Int {
        guard start < bytes.count, let base = bytes.baseAddress,
              let found = memchr(base + start, Int32(byte), bytes.count - start) else { return bytes.count }
        return UnsafeRawPointer(base).distance(to: UnsafeRawPointer(found))
    }

    /// Whether the markup holds exactly `expected` at `start`.
    func holds(_ expected: [UInt8], at start: Int) -> Bool {
        guard start + expected.count <= bytes.count else { return false }
        for offset in expected.indices where bytes[start + offset] != expected[offset] {
            return false
        }
        return true
    }

    /// Whether the markup holds `expected` (in small letters) at `start`,
    /// in any mix of capitals.
    func holds(ignoringCase expected: [UInt8], at start: Int) -> Bool {
        guard start + expected.count <= bytes.count else { return false }
        for offset in expected.indices where Self.lowercased(bytes[start + offset]) != expected[offset] {
            return false
        }
        return true
    }

    /// The tag name whose bytes are at `range`, as `builder` names its
    /// element: SwiftSoup's HTML tree builder makes ASCII capitals small,
    /// its XML tree builder keeps a name as written.
    func name(at range: Range<Int>, as builder: HTMLNesting.TreeBuilder) -> String {
        let name = UnsafeBufferPointer(rebasing: bytes[range])
        guard builder == .html, name.contains(where: { $0 >= 0x41 && $0 <= 0x5A }) else {
            return String(decoding: name, as: UTF8.self)
        }
        return String(decoding: name.map(Self.lowercased), as: UTF8.self)
    }

    // MARK: Pieces

    /// The next piece of markup, or nil at its end.
    mutating func next() -> Token? {
        let count = bytes.count
        guard position < count else { return nil }
        let start = position
        guard bytes[start] == UInt8(ascii: "<") else {
            position = index(of: UInt8(ascii: "<"), from: start + 1)
            return .text(start..<position)
        }
        let after = start + 1
        guard after < count else {
            position = count
            return .text(start..<count)
        }
        let byte = bytes[after]
        if Self.isLetter(byte) {
            return tag(nameAt: after, isEndTag: false)
        }
        switch byte {
        case UInt8(ascii: "!"):
            return declaration(at: after + 1)
        case UInt8(ascii: "?"):
            return bogusComment(at: after)
        case UInt8(ascii: "/"):
            return endTagOrBogusComment(at: after + 1)
        default:
            // "a < b", "<3": a `<` that begins no markup is text.
            position = after
            return .text(start..<after)
        }
    }

    /// What follows `</` at `start`: an end tag when a letter begins its
    /// name; `</>`, which SwiftSoup drops; `</` at the very end, which is
    /// text; and otherwise a bogus comment to the next `>`.
    private mutating func endTagOrBogusComment(at start: Int) -> Token {
        guard start < bytes.count else {
            position = bytes.count
            return .text((start - 2)..<bytes.count)
        }
        let byte = bytes[start]
        if Self.isLetter(byte) {
            return tag(nameAt: start, isEndTag: true)
        }
        if byte == UInt8(ascii: ">") {
            position = start + 1
            return .nothing
        }
        return bogusComment(at: start)
    }

    /// What follows `<!` at `start`: a comment, a doctype, a CDATA section,
    /// or a bogus comment.
    private mutating func declaration(at start: Int) -> Token {
        if holds(Self.commentStart, at: start) {
            return comment(at: start + 2)
        }
        if holds(ignoringCase: Self.doctype, at: start) {
            // A doctype ends at its first `>`, even one inside quotes.
            return bogusComment(at: start)
        }
        if holds(Self.cdataStart, at: start) {
            let content = start + Self.cdataStart.count
            var end = content
            while end < bytes.count, !holds(Self.cdataEnd, at: end) {
                end = index(of: UInt8(ascii: "]"), from: end + 1)
            }
            position = min(end + Self.cdataEnd.count, bytes.count)
            return .cdata(content..<min(end, bytes.count))
        }
        return bogusComment(at: start)
    }

    /// A bogus comment (`<?…>`, `<!…>`, `</1…>`) or a doctype, from `start`
    /// to the first `>`, or to the end.
    private mutating func bogusComment(at start: Int) -> Token {
        position = min(index(of: UInt8(ascii: ">"), from: start) + 1, bytes.count)
        return .nothing
    }

    /// A comment whose text begins at `start`, past its `<!--`. It ends at
    /// `-->` or `--!>`, any number of dashes before them, or at once when
    /// only dashes come before a `>` (`<!-->`, `<!--->`), as SwiftSoup's
    /// comment states have it; and at the end of the markup otherwise.
    private mutating func comment(at start: Int) -> Token {
        let count = bytes.count
        var index = start
        while index < count, bytes[index] == UInt8(ascii: "-") {
            index += 1
        }
        if index < count, bytes[index] == UInt8(ascii: ">") {
            position = index + 1
            return .nothing
        }
        var dashes = 0
        while index < count {
            let byte = bytes[index]
            index += 1
            if byte == UInt8(ascii: "-") {
                dashes += 1
                continue
            }
            if dashes >= 2, byte == UInt8(ascii: ">") {
                position = index
                return .nothing
            }
            if dashes >= 2, byte == UInt8(ascii: "!"), index < count, bytes[index] == UInt8(ascii: ">") {
                position = index + 1
                return .nothing
            }
            dashes = 0
        }
        position = count
        return .nothing
    }

    /// A tag whose name begins at `start`: its name runs to whitespace, `/`,
    /// or `>`, and its attributes to the `>` that ends it. A tag the markup
    /// ends inside is dropped, as SwiftSoup drops it.
    private mutating func tag(nameAt start: Int, isEndTag: Bool) -> Token {
        let count = bytes.count
        var nameEnd = start
        while nameEnd < count {
            let byte = bytes[nameEnd]
            if Self.isWhitespace(byte) || byte == UInt8(ascii: "/") || byte == UInt8(ascii: ">") {
                break
            }
            nameEnd += 1
        }
        guard let (end, closesItself) = endOfTag(from: nameEnd) else {
            position = count
            return .nothing
        }
        position = end
        let name = start..<nameEnd
        return isEndTag ? .endTag(name: name) : .startTag(name: name, closesItself: closesItself)
    }

    /// Where a tag whose name ends at `start` ends (just past its `>`), and
    /// whether it closes itself; nil when the markup ends first.
    ///
    /// SwiftSoup ends a tag with no attributes early: its name, any
    /// whitespace, then `>`; or then `/`, any whitespace, and `>`, which
    /// closes it as `/>` does. Otherwise its attributes are read as HTML's
    /// attribute states read them: a value begins after `=`, a quote there
    /// begins a quoted value that runs to the same quote (holding any `>`),
    /// a value without quotes runs to whitespace or `>` (holding any `/`),
    /// and only a `/` outside a value, straight before the `>`, closes the
    /// tag itself.
    private func endOfTag(from start: Int) -> (end: Int, closesItself: Bool)? {
        let count = bytes.count
        var index = start
        while index < count, Self.isWhitespace(bytes[index]) {
            index += 1
        }
        if index < count, bytes[index] == UInt8(ascii: ">") {
            return (index + 1, false)
        }
        if index < count, bytes[index] == UInt8(ascii: "/") {
            var next = index + 1
            while next < count, Self.isWhitespace(bytes[next]) {
                next += 1
            }
            if next < count, bytes[next] == UInt8(ascii: ">") {
                return (next + 1, true)
            }
        }
        return endOfAttributes(from: start)
    }

    /// The states of HTML's tokenizer between a tag's name and its `>`.
    private enum AttributeState {
        case beforeName, name, afterName, beforeValue, unquotedValue, afterQuotedValue, selfClosing
    }

    /// Where a tag's attributes, from `start`, end (just past the tag's
    /// `>`), and whether a `/` straight before that `>` closes it; nil when
    /// the markup ends first. See `endOfTag(from:)`.
    private func endOfAttributes(from start: Int) -> (end: Int, closesItself: Bool)? {
        let count = bytes.count
        var state = AttributeState.beforeName
        var index = start
        while index < count {
            let byte = bytes[index]
            index += 1
            let isWhitespace = Self.isWhitespace(byte)
            switch state {
            case .beforeName:
                if isWhitespace {
                    continue
                }
                switch byte {
                case UInt8(ascii: "/"): state = .selfClosing
                case UInt8(ascii: ">"): return (index, false)
                // Any other byte, even `=` or a quote, begins a name.
                default: state = .name
                }
            case .name, .afterName:
                if isWhitespace {
                    state = .afterName
                    continue
                }
                switch byte {
                case UInt8(ascii: "/"): state = .selfClosing
                case UInt8(ascii: "="): state = .beforeValue
                case UInt8(ascii: ">"): return (index, false)
                default: state = .name
                }
            case .beforeValue:
                if isWhitespace {
                    continue
                }
                switch byte {
                case UInt8(ascii: "\""), UInt8(ascii: "'"):
                    // A quoted value holds everything to its closing quote.
                    let close = self.index(of: byte, from: index)
                    guard close < count else { return nil }
                    index = close + 1
                    state = .afterQuotedValue
                case UInt8(ascii: ">"): return (index, false)
                default: state = .unquotedValue
                }
            case .unquotedValue:
                if isWhitespace {
                    state = .beforeName
                } else if byte == UInt8(ascii: ">") {
                    return (index, false)
                }
            case .afterQuotedValue:
                if isWhitespace {
                    state = .beforeName
                    continue
                }
                switch byte {
                case UInt8(ascii: "/"): state = .selfClosing
                case UInt8(ascii: ">"): return (index, false)
                default:
                    // Read again as the start of another attribute.
                    state = .beforeName
                    index -= 1
                }
            case .selfClosing:
                if byte == UInt8(ascii: ">") {
                    return (index, true)
                }
                // Read again as the start of an attribute.
                state = .beforeName
                index -= 1
            }
        }
        return nil
    }

    // MARK: Text That Is Not Markup

    /// Skip the content of `element`, which SwiftSoup's tokenizer reads as
    /// text, from the end of its start tag through its end tag, and return
    /// where that text lies.
    @discardableResult
    mutating func skipText(of element: RawTextElement) -> Range<Int> {
        let start = position
        let end: Int
        switch element {
        case .plaintext:
            end = bytes.count
            position = end
        case .script:
            end = endOfScript(from: start)
        case .style:
            end = endOfRawText(named: Self.styleName, from: start)
        case .noframes:
            end = endOfRawText(named: Self.noframesName, from: start)
        case .title:
            end = endOfTitle(from: start)
        }
        return start..<end
    }

    /// Whether `<` at `start` begins the end tag of the element named `name`
    /// in small letters: `</`, the name in any capitals, then whitespace,
    /// `/`, or `>`. Returns the index of that last byte.
    private func endTag(named name: [UInt8], at start: Int) -> Int? {
        let delimiter = start + 2 + name.count
        guard delimiter < bytes.count, bytes[start + 1] == UInt8(ascii: "/"),
              holds(ignoringCase: name, at: start + 2) else { return nil }
        let byte = bytes[delimiter]
        return Self.isWhitespace(byte) || byte == UInt8(ascii: "/") || byte == UInt8(ascii: ">") ? delimiter : nil
    }

    /// Move past the rest of an end tag whose name ends at `delimiter`, and
    /// return where its text ended, `textEnd`.
    private mutating func finishEndTag(at delimiter: Int, textEnd: Int) -> Int {
        position = endOfTag(from: delimiter)?.end ?? bytes.count
        return textEnd
    }

    /// Raw text from `start` to the end tag of the element named `name`
    /// (`style`, `noframes`): where the text ends.
    private mutating func endOfRawText(named name: [UInt8], from start: Int) -> Int {
        var index = self.index(of: UInt8(ascii: "<"), from: start)
        while index < bytes.count {
            if let delimiter = endTag(named: name, at: index) {
                return finishEndTag(at: delimiter, textEnd: index)
            }
            index = self.index(of: UInt8(ascii: "<"), from: index + 1)
        }
        position = bytes.count
        return bytes.count
    }

    /// A title's text from `start`: to `</title`, or, as SwiftSoup has it,
    /// to the first tag when no `</title` or `</TITLE` follows anywhere.
    private mutating func endOfTitle(from start: Int) -> Int {
        // Where a `</title` or `</TITLE` is known to lie ahead, once a tag in
        // the title's text made the reader look for one.
        var endTagAhead = start
        var index = self.index(of: UInt8(ascii: "<"), from: start)
        while index < bytes.count {
            if let delimiter = endTag(named: Self.titleName, at: index) {
                return finishEndTag(at: delimiter, textEnd: index)
            }
            if index + 1 < bytes.count, Self.isLetter(bytes[index + 1]) {
                if endTagAhead <= index {
                    endTagAhead = titleEndTagSpelling(after: index)
                }
                if endTagAhead == bytes.count {
                    // The tag is read as markup: the title ends before it.
                    position = index
                    return index
                }
            }
            index = self.index(of: UInt8(ascii: "<"), from: index + 1)
        }
        position = bytes.count
        return bytes.count
    }

    /// Where the first `</title` or `</TITLE` after `start` begins, or the
    /// end of the markup: SwiftSoup looks for exactly those two spellings.
    private func titleEndTagSpelling(after start: Int) -> Int {
        var index = self.index(of: UInt8(ascii: "<"), from: start + 1)
        while index < bytes.count {
            if holds(Self.titleEndTag, at: index) || holds(Self.capitalTitleEndTag, at: index) {
                return index
            }
            index = self.index(of: UInt8(ascii: "<"), from: index + 1)
        }
        return bytes.count
    }

    /// The states of script data in HTML's tokenizer: `<!--` escapes it, and
    /// a `<script>` inside an escape escapes it twice, where `</script>`
    /// only undoes the second escape.
    private enum ScriptState {
        case data, escaped, doubleEscaped
    }

    /// Script data from `start` to the `</script>` that ends it, following
    /// HTML's escaped states as SwiftSoup does: where the text ends. The
    /// word `script` that begins and ends a double escape is matched in
    /// small letters only, as SwiftSoup matches it.
    private mutating func endOfScript(from start: Int) -> Int {
        let count = bytes.count
        var state = ScriptState.data
        var dashes = 0
        var index = start
        while index < count {
            if state == .data {
                index = self.index(of: UInt8(ascii: "<"), from: index)
                guard index < count else { break }
                if let delimiter = endTag(named: Self.scriptName, at: index) {
                    return finishEndTag(at: delimiter, textEnd: index)
                }
                if holds(Self.scriptEscape, at: index) {
                    // `<!--` leaves two dashes read: a `>` next ends the escape.
                    state = .escaped
                    dashes = 2
                    index += 4
                } else {
                    index += 1
                }
                continue
            }
            let byte = bytes[index]
            if byte == UInt8(ascii: "-") {
                dashes += 1
                index += 1
                continue
            }
            if byte == UInt8(ascii: ">"), dashes >= 2 {
                state = .data
                dashes = 0
                index += 1
                continue
            }
            dashes = 0
            guard byte == UInt8(ascii: "<") else {
                index += 1
                continue
            }
            if state == .escaped {
                if let delimiter = endTag(named: Self.scriptName, at: index) {
                    return finishEndTag(at: delimiter, textEnd: index)
                }
                if let delimiter = scriptWord(at: index + 1) {
                    state = .doubleEscaped
                    index = delimiter + 1
                    continue
                }
            } else if index + 1 < count, bytes[index + 1] == UInt8(ascii: "/"), let delimiter = scriptWord(at: index + 2) {
                state = .escaped
                index = delimiter + 1
                continue
            }
            index += 1
        }
        position = count
        return count
    }

    /// Whether `script`, in small letters, is at `start` and followed by
    /// whitespace, `/`, or `>`: the index of that last byte.
    private func scriptWord(at start: Int) -> Int? {
        let delimiter = start + Self.scriptName.count
        guard delimiter < bytes.count, holds(Self.scriptName, at: start) else { return nil }
        let byte = bytes[delimiter]
        return Self.isWhitespace(byte) || byte == UInt8(ascii: "/") || byte == UInt8(ascii: ">") ? delimiter : nil
    }
}

/// What SwiftSoup 2.13.9's HTML tree builder does with an element of one
/// name, as far as the depth of its tree goes (see `OpenElements`). Names
/// are in small letters.
private struct HTMLElementTraits: OptionSet {
    let rawValue: UInt16

    /// Never left open: HTML's void elements, and the others SwiftSoup
    /// inserts empty (`keygen`, `command`…) or drops outside a table or a
    /// frameset (`col`, `frame`).
    static let neverOpen = HTMLElementTraits(rawValue: 1 << 0)
    /// Counts no level: an element SwiftSoup closes when the next of its
    /// kind begins (`p`, `li`, `dt`, `dd`, `option` outside a select), or a
    /// part of a table, which counts them (`table`).
    static let uncounted = HTMLElementTraits(rawValue: 1 << 1)
    /// `html`, `head`, and `body`: a document has each once, whatever its
    /// tags say, and SwiftSoup closes nothing at their end tags.
    static let documentElement = HTMLElementTraits(rawValue: 1 << 2)
    /// SwiftSoup's special elements (`HtmlTreeBuilder.isSpecial`): the end
    /// tag of another element never closes one, nor anything below it.
    static let special = HTMLElementTraits(rawValue: 1 << 3)
    /// The elements that bound a scope: the end tag of an element closed in
    /// scope never closes one, nor anything below it.
    static let scopeBoundary = HTMLElementTraits(rawValue: 1 << 4)
    /// The elements SwiftSoup closes at their end tags only while they are
    /// in scope: `div`, the lists, the sectioning elements, and the like.
    static let closedInScope = HTMLElementTraits(rawValue: 1 << 5)
    /// `h1` to `h6`: the end tag of any heading closes the nearest one.
    static let heading = HTMLElementTraits(rawValue: 1 << 6)
    /// `table`: four levels, for itself and the body, row, and cell that
    /// SwiftSoup nests in it, which count none of their own.
    static let table = HTMLElementTraits(rawValue: 1 << 7)
    /// `applet`, `marquee`, and `object`, closed in scope by their end tags
    /// unless an element named `name` is in scope.
    static let applet = HTMLElementTraits(rawValue: 1 << 8)

    /// The traits of the element named `name`.
    static func of(_ name: String) -> HTMLElementTraits {
        byName[name] ?? []
    }

    /// Every name with a trait, from SwiftSoup's own lists.
    private static let byName: [String: HTMLElementTraits] = {
        var traits: [String: HTMLElementTraits] = [:]
        func give(_ trait: HTMLElementTraits, to names: [String]) {
            for name in names {
                traits[name, default: []].insert(trait)
            }
        }
        let headings = ["h1", "h2", "h3", "h4", "h5", "h6"]
        give(.neverOpen, to: [
            "area", "base", "basefont", "bgsound", "br", "col", "command", "embed", "frame", "hr", "img", "input",
            "keygen", "link", "meta", "param", "source", "track", "wbr",
        ])
        give(.uncounted, to: [
            "p", "li", "dt", "dd", "option", "caption", "colgroup", "thead", "tbody", "tfoot", "tr", "td", "th",
        ])
        give(.documentElement, to: ["html", "head", "body"])
        // HtmlTreeBuilder's TagSets.special.
        give(.special, to: headings + [
            "address", "applet", "area", "article", "aside", "base", "basefont", "bgsound", "blockquote", "body", "br",
            "button", "caption", "center", "col", "colgroup", "command", "dd", "details", "dir", "div", "dl", "dt",
            "embed", "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset", "head", "header",
            "hgroup", "hr", "html", "iframe", "img", "input", "isindex", "li", "link", "listing", "marquee", "menu",
            "meta", "nav", "noembed", "noframes", "noscript", "object", "ol", "p", "param", "plaintext", "pre",
            "script", "section", "select", "style", "summary", "table", "tbody", "td", "textarea", "tfoot", "th",
            "thead", "title", "tr", "ul", "wbr", "xmp",
        ])
        // The elements of HtmlTreeBuilder's default scope that the scanner
        // counts: a caption or a table cell lies inside a table.
        give(.scopeBoundary, to: ["applet", "marquee", "object", "table"])
        // HtmlTreeBuilderState's InBodyEndClosers.
        give(.closedInScope, to: [
            "address", "article", "aside", "blockquote", "button", "center", "details", "dir", "div", "dl", "fieldset",
            "figcaption", "figure", "footer", "header", "hgroup", "listing", "menu", "nav", "ol", "pre", "section",
            "summary", "ul",
        ])
        give(.heading, to: headings)
        give(.table, to: ["table"])
        give(.applet, to: ["applet", "marquee", "object"])
        return traits
    }()
}

/// SwiftSoup's stack of open elements, kept only as far as the depth of its
/// tree goes, for `HTMLNesting.mayNest(_:deeperThan:as:)`.
///
/// For the XML tree builder it is exact: every start tag not closed by `/>`
/// opens an element, and an end tag closes the nearest open element of
/// exactly its name, and everything above it, or nothing.
///
/// For the HTML tree builder it follows what SwiftSoup's insertion modes do
/// to depth (`HtmlTreeBuilderState`), and where it cannot follow them, it
/// keeps more levels open, never fewer:
/// - A void element (`br`, `img`…), any other element SwiftSoup never leaves
///   open, and a tag ending `/>`, which SwiftSoup closes at once, open
///   nothing.
/// - The `html` and `body` elements every document has are its first two
///   levels, whatever its tags say; their end tags, and `head`'s, close
///   nothing, as SwiftSoup keeps its stack there.
/// - An element SwiftSoup closes when the next of its kind begins (`p`,
///   `li`, `dt`, `dd`, `option` outside a select) counts no level, so a long
///   chapter of unclosed paragraphs nests nothing. Such an element nests in
///   another only through an element counted between them, such as a list,
///   so the real depth is at most twice the count. A table's parts count
///   none either; a `table` counts four levels instead, for itself and the
///   body, row, and cell SwiftSoup nests in it. `rb`, `rt`, `rp`, and
///   `optgroup`, which SwiftSoup lets nest, count like any element.
/// - An end tag closes the nearest open element of its name and everything
///   above it, but never past a special element (`div`, `ol`, `li`…), where
///   SwiftSoup ignores it. The end tags SwiftSoup honors only in scope
///   (`div`, `ul`, `section`…) never close past a `table`, `object`,
///   `applet`, or `marquee`; those of `object`, `applet`, and `marquee`
///   close nothing while an element named `name` is in scope, as SwiftSoup
///   2.13.9 has it; a heading's end tag closes the nearest heading of any
///   level; `</form>` closes only a form on top, since SwiftSoup takes a form
///   off its stack but leaves what the form holds inside it; and an end tag
///   naming nothing open closes nothing.
/// - Inside a `select`, every tag is ignored except those SwiftSoup reads
///   there (`option`, `optgroup`, `select`, `input`, `keygen`, `textarea`,
///   `script`), and they do what they do there. SwiftSoup's `optgroup` closes
///   an open `optgroup` only when no `option` is open in it, so optgroups
///   can nest.
///
/// What it does not follow: the formatting elements (`b`, `font`…) that
/// SwiftSoup opens again, at the next text, after another element's end tag
/// closed them. It opens again at most three alike, so only markup leaving
/// open thousands of them, each with attributes of its own, could nest
/// deeper than this counts.
private struct OpenElements {
    /// An open element: its name, and the levels it counts.
    private struct Element {
        let name: String
        let levels: Int
        let traits: HTMLElementTraits
    }

    /// The tree builder whose stack this follows.
    let builder: HTMLNesting.TreeBuilder
    /// The open elements, outermost first.
    private var elements: [Element] = []
    /// The levels of the open elements: how deep an element opened now
    /// would lie, but for its own level.
    private(set) var depth: Int

    init(builder: HTMLNesting.TreeBuilder) {
        self.builder = builder
        // An HTML document's elements lie inside its `html` and `body`.
        depth = builder == .html ? 2 : 0
    }

    // MARK: Start Tags

    /// Open the element a start tag names, as the tree builder would. When
    /// its content is text to SwiftSoup's tokenizer, it opens nothing and
    /// returns that kind of text, which the caller reads past.
    mutating func open(_ name: String, closesItself: Bool) -> RawTextElement? {
        guard builder == .html else {
            if !closesItself {
                push(name, levels: 1, traits: [])
            }
            return nil
        }
        if isInSelect {
            return openInSelect(name, closesItself: closesItself)
        }
        if let text = RawTextElement(htmlName: name) {
            // `plaintext` makes everything after it text, even closed by `/>`.
            return text == .plaintext || !closesItself ? text : nil
        }
        let traits = HTMLElementTraits.of(name)
        guard !closesItself, traits.isDisjoint(with: [.neverOpen, .uncounted, .documentElement]) else { return nil }
        push(name, levels: traits.contains(.table) ? 4 : 1, traits: traits)
        return nil
    }

    /// A start tag inside a `select`, which SwiftSoup ignores but for a few
    /// (`HtmlTreeBuilderState.InSelect`).
    private mutating func openInSelect(_ name: String, closesItself: Bool) -> RawTextElement? {
        switch name {
        case "option":
            if elements.last?.name == "option" {
                pop(downTo: elements.count - 1)
            }
        case "optgroup":
            // SwiftSoup closes an open option, or else an open optgroup.
            if elements.last?.name == "option" || elements.last?.name == "optgroup" {
                pop(downTo: elements.count - 1)
            }
        case "select":
            closeSelect()
            return nil
        case "input", "keygen", "textarea":
            // They close the select, and are read again outside it.
            guard closeSelect() else { return nil }
            return open(name, closesItself: closesItself)
        case "script":
            return closesItself ? nil : .script
        default:
            return nil
        }
        if !closesItself {
            push(name, levels: 1, traits: [])
        }
        return nil
    }

    // MARK: End Tags

    /// Close what an end tag closes, as the tree builder would.
    mutating func close(_ name: String) {
        guard builder == .html else {
            if let index = elements.lastIndex(where: { $0.name == name }) {
                pop(downTo: index)
            }
            return
        }
        if isInSelect {
            closeInSelect(name)
            return
        }
        let traits = HTMLElementTraits.of(name)
        guard traits.isDisjoint(with: [.neverOpen, .uncounted, .documentElement]) else { return }
        if name == "form" {
            if elements.last?.name == "form" {
                pop(downTo: elements.count - 1)
            }
        } else if traits.contains(.heading) {
            closeNearest(where: { $0.traits.contains(.heading) }, notPast: .scopeBoundary)
        } else if traits.contains(.table) {
            closeNearest(where: { $0.traits.contains(.table) }, notPast: [])
        } else if traits.contains(.applet) {
            // SwiftSoup 2.13.9 first asks whether an element named `name`
            // is in scope, and closes nothing when one is.
            guard !isInScope(where: { $0.name == "name" }) else { return }
            closeNearest(where: { $0.name == name }, notPast: .scopeBoundary)
        } else if traits.contains(.closedInScope) {
            closeNearest(where: { $0.name == name }, notPast: .scopeBoundary)
        } else {
            closeNearest(where: { $0.name == name }, notPast: .special)
        }
    }

    /// An end tag inside a `select`, which SwiftSoup ignores but for a few.
    private mutating func closeInSelect(_ name: String) {
        switch name {
        case "optgroup":
            if elements.last?.name == "option", elements.dropLast().last?.name == "optgroup" {
                pop(downTo: elements.count - 1)
            }
            if elements.last?.name == "optgroup" {
                pop(downTo: elements.count - 1)
            }
        case "option":
            if elements.last?.name == "option" {
                pop(downTo: elements.count - 1)
            }
        case "select":
            closeSelect()
        default:
            break
        }
    }

    // MARK: The Stack

    /// Whether a `select` is open with only its options and optgroups above
    /// it: SwiftSoup's select insertion mode.
    private var isInSelect: Bool {
        guard builder == .html else { return false }
        for element in elements.reversed() where element.name != "option" && element.name != "optgroup" {
            return element.name == "select"
        }
        return false
    }

    /// Close the open `select` and the options and optgroups above it, if
    /// any; whether there was one.
    @discardableResult
    private mutating func closeSelect() -> Bool {
        var index = elements.count - 1
        while index >= 0, elements[index].name == "option" || elements[index].name == "optgroup" {
            index -= 1
        }
        guard index >= 0, elements[index].name == "select" else { return false }
        pop(downTo: index)
        return true
    }

    /// Where the nearest open element that `matches` lies, unless an element
    /// with a trait of `boundary` comes first, counting down from the top.
    private func nearestIndex(where matches: (Element) -> Bool, notPast boundary: HTMLElementTraits) -> Int? {
        var index = elements.count - 1
        while index >= 0 {
            let element = elements[index]
            if matches(element) {
                return index
            }
            if !element.traits.isDisjoint(with: boundary) {
                return nil
            }
            index -= 1
        }
        return nil
    }

    /// Close the nearest open element that `matches`, and everything above
    /// it, unless an element with a trait of `boundary` comes first.
    private mutating func closeNearest(where matches: (Element) -> Bool, notPast boundary: HTMLElementTraits) {
        if let index = nearestIndex(where: matches, notPast: boundary) {
            pop(downTo: index)
        }
    }

    /// Whether an open element that `matches` is in scope: no `table`,
    /// `object`, `applet`, or `marquee` lies above it.
    private func isInScope(where matches: (Element) -> Bool) -> Bool {
        nearestIndex(where: matches, notPast: .scopeBoundary) != nil
    }

    /// Open an element of `levels` levels.
    private mutating func push(_ name: String, levels: Int, traits: HTMLElementTraits) {
        elements.append(Element(name: name, levels: levels, traits: traits))
        depth += levels
    }

    /// Close the element at `index` and everything above it.
    private mutating func pop(downTo index: Int) {
        for element in elements[index...] {
            depth -= element.levels
        }
        elements.removeSubrange(index...)
    }
}
