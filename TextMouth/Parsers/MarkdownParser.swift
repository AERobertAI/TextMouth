import Foundation

enum MarkdownDocParser {

    static func parse(markdown: String, title: String = "Untitled") throws -> DocumentContent { // l10n: no (stored id: the placeholder title a book is saved with, question 9)
        let chapter = try parseChapter(markdown: markdown, title: title)
        return DocumentContent(
            title: chapter.title,
            author: Book.unknownAuthor,
            chapters: [chapter]
        )
    }

    /// Parse one chapter without constructing an intermediate DocumentContent.
    /// Multi-chapter cache loading uses this to avoid calculating book metrics
    /// once per chapter and then again for the assembled document.
    ///
    /// Markdown reaches the parser from untrusted files (a `.md`, a `.txt`,
    /// and the Markdown every other reader writes), and every part of reading
    /// it calls itself once per level of nesting, so it is held to the limits
    /// of `MarkupGuard` in two layers, as HTML is: the text's block quotes and
    /// lists are counted before anything is built (`MarkdownNesting`) and
    /// refused past `deepestNesting`; and the parse, the walk, and the release
    /// of the tree all run on `MarkupGuard.onLargeStack`, the walk stopping at
    /// the limit on the tree (`MarkdownNesting.deepestTree(under:)`: the limit's
    /// own `deepestTree` when set, else twice `deepestNesting` and 16 more,
    /// 272 levels by default).
    ///
    /// - Parameter includeNavigationHeadings: Whether the generated markers of
    ///   content.md are read: heading annotations, which add navigation
    ///   headings, and page markers (PG01), which add pages. Everywhere else
    ///   they are ordinary comments, unseen.
    /// - Throws: `MarkupRefusal.nestedTooDeeply` when the Markdown nests past the limit.
    static func parseChapter(
        markdown: String,
        title: String = "Untitled", // l10n: no (stored id: the placeholder title a book is saved with, question 9)
        includeNavigationHeadings: Bool = false
    ) throws -> Chapter {
        // The limits in force are task-local, which a thread of its own does not
        // inherit, so they are read here and handed on.
        let limits = MarkupGuard.limits
        guard !MarkdownNesting.isDeeper(markdown, than: limits.deepestNesting) else {
            throw MarkupRefusal.nestedTooDeeply(limit: limits.deepestNesting)
        }
        return try MarkupGuard.onLargeStack {
            try readChapter(markdown: markdown, title: title, includeNavigationHeadings: includeNavigationHeadings, limits: limits)
        }
    }

    /// `parseChapter`'s parse and walk, which its caller runs on the big stack
    /// after the nesting has been counted.
    /// - Throws: `MarkupRefusal.nestedTooDeeply` when the parsed tree is deeper than the limit on trees.
    private static func readChapter(
        markdown: String,
        title: String,
        includeNavigationHeadings: Bool,
        limits: MarkupGuard.Limits
    ) throws -> Chapter {
        // Capture headings while emitting their text. Searching for their
        // labels afterwards can bind a heading to an earlier body paragraph.
        var textExtractor = PlainTextExtractor(includeNavigationHeadings: includeNavigationHeadings, limits: limits)
        MarkdownTree.read(markdown) { document in textExtractor.visit(document) }
        // A tree deeper than the limit was not walked past it: the text read is partial, so refuse it.
        if textExtractor.exceededDepth { throw MarkupRefusal.nestedTooDeeply(limit: limits.deepestNesting) }
        let readingText = textExtractor.result
        let plainText = readingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstContent = readingText.rangeOfCharacter(from: .whitespacesAndNewlines.inverted)?.lowerBound
            ?? readingText.endIndex
        let trimmedPrefixLength = readingText.utf16Offset(of: firstContent)
        var headings = textExtractor.headings
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { heading in
                Heading(level: heading.level, text: heading.text,
                        characterOffset: max(0, heading.offset - trimmedPrefixLength))
            }

        // An anchor at an existing semantic heading must not create a duplicate
        // row. Keep semantic labels/levels, then merge other TOC destinations in
        // text order. Coordinates come from the same walk that produces speech.
        var occupiedOffsets = Set(headings.map(\.characterOffset))
        let textLength = plainText.utf16.count
        for heading in textExtractor.navigationHeadings {
            let offset = min(textLength, max(0, heading.offset - trimmedPrefixLength))
            if occupiedOffsets.insert(offset).inserted {
                headings.append(Heading(level: heading.level, text: heading.text, characterOffset: offset))
            }
        }
        headings.sortStably { $0.characterOffset < $1.characterOffset }

        // Use first heading as title if available
        let docTitle = headings.first?.text ?? title

        // Pages come from the same walk, so they are already in reading order.
        // A page that begins in whitespace or inside a word begins at the
        // nearest whole word (PG01), so a move by page and the page shown agree.
        let pages = textExtractor.pages.map { page in
            let offset = min(textLength, max(0, page.offset - trimmedPrefixLength))
            return PageBreak(
                label: page.label,
                characterOffset: PageBreak.firstWordStart(in: plainText, at: offset)
            )
        }

        return Chapter(title: docTitle, text: plainText, headings: headings, pages: pages)
    }
}

// MARK: - Plain Text Extractor

/// The walk of a Markdown tree that makes a chapter's reading text, and notes
/// where its headings, its navigation targets, and its pages stand in it.
///
/// It reads cmark's own tree (`MarkdownTree`). Until November 15, 2026 it
/// walked the tree swift-markdown built from cmark's, and it still reads
/// every node as it read that tree's, down to the count of levels: there a
/// table held a head and a body, and the body held the rows, so a body row is
/// counted one level deeper than cmark's tree has it (`readTable`).
private struct PlainTextExtractor {
    var includeNavigationHeadings = false
    /// The reading text so far, as UTF-8. cmark hands a node's text as bytes,
    /// and they are gathered as bytes, so no string is made for each node;
    /// the text is made from them once, at the end (`result`).
    private var bytes: [UInt8] = []
    var headings: [(level: Int, text: String, offset: Int)] = []
    var navigationHeadings: [(level: Int, text: String, offset: Int)] = []
    /// The page markers met, in reading order, with the offset at which each
    /// stood in `result` (PG01). Read under the same rule as navigation headings.
    var pages: [(label: String, offset: Int)] = []
    /// The length of the text so far in UTF-16 units, which every offset is in.
    private var utf16Length = 0
    /// Start of the heading being walked, if any. Caches written before format
    /// 3.0.5 could place an annotation inside a heading line; it names that
    /// heading, so it takes the heading's offset rather than a later one.
    private var currentHeadingOffset: Int?
    /// Whether a table cell has begun and written none of its words yet.
    /// Its first words are kept apart from the words before them in its row
    /// (`append(_:)`), so an empty cell writes nothing, not even a space.
    private var cellBoundaryIsPending = false
    /// Whether the rest of a marker-led HTML block (ST05) is being visited.
    /// A container in that rest (a block quote or a list item) can hold
    /// another marker-led block, and a crafted line such as
    /// `<!-- page: 1 -->> <!-- page: 2 -->> ...` would then re-parse the rest
    /// of the line once per level. While this is set an HTML block reads
    /// exactly as before ST05 (one marker alone is taken, anything else is
    /// nothing), which bounds the re-parsing to one level.
    private var isReadingRestOfMarkerLine = false

    /// The limits the walk keeps to.
    private let limits: MarkupGuard.Limits
    /// How many levels of the tree the walk is inside.
    private var depth = 0
    /// Whether the walk met a level deeper than the limit on trees (or a
    /// marker line's rest nested past the limit on nesting) and did not read it.
    private(set) var exceededDepth = false

    /// Only generated cache/EPUB Markdown opts into navigation annotations
    /// and page markers (PG01).
    init(includeNavigationHeadings: Bool, limits: MarkupGuard.Limits) {
        self.includeNavigationHeadings = includeNavigationHeadings
        self.limits = limits
    }

    /// The reading text the walk made, built from its bytes: ask once and
    /// keep it. The bytes are the Markdown's own UTF-8 or UTF-8 that cmark
    /// wrote, so nothing in them is repaired.
    var result: String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// The deepest tree the walk reads, the document at level 1: the limit
    /// every walk of Markdown shares (`MarkdownNesting.deepestTree(under:)`).
    private var deepestTree: Int {
        MarkdownNesting.deepestTree(under: limits)
    }

    // MARK: Levels

    /// Enters one more level of the tree, unless the walk is already at the
    /// deepest level it reads: then the level is not entered, and the stop is
    /// recorded in `exceededDepth`. Every level entered is left with `leaveLevel()`.
    private mutating func enterLevel() -> Bool {
        guard depth < deepestTree else {
            exceededDepth = true
            return false
        }
        depth += 1
        return true
    }

    /// Leaves the level `enterLevel()` entered.
    private mutating func leaveLevel() {
        depth -= 1
    }

    /// Reads `node` and everything under it, unless it stands deeper than the
    /// walk reads. Every node the walk reads comes through here, since
    /// `descend(into:)` visits each child, so no level of a tree deeper than
    /// the limit is entered.
    mutating func visit(_ node: MarkdownNode) {
        guard enterLevel() else { return }
        defer { leaveLevel() }
        switch node.kind {
        case .text, .inlineCode:
            // Text leaves provide ordinary prose and inline formatting
            // contents; inline code is read as its characters.
            append(node.literalBytes)
        case .softBreak:
            // A wrapped Markdown source line is a space in the spoken paragraph.
            append(" ")
        case .lineBreak:
            // Explicit Markdown hard breaks retain a newline.
            append("\n")
        case .paragraph:
            // Preserve paragraph boundaries without exposing Markdown syntax.
            separateBlock()
            descend(into: node)
        case .heading:
            readHeading(node)
        case .codeBlock:
            // Retain fenced and indented code, including its internal line breaks.
            separateBlock()
            append(node.literalBytes)
            separateBlock()
        case .htmlBlock:
            readHTMLBlock(node.literal)
        case .inlineHTML:
            readInlineHTML(node)
        case .table:
            readTable(node)
        case .tableHeader, .tableRow:
            readRow(node)
        case .tableCell:
            // A cell's first words, when it has any, stand apart from the
            // words before them in its row (`cellBoundaryIsPending`).
            cellBoundaryIsPending = true
            descend(into: node)
        case .document, .blockQuote, .list, .listItem, .thematicBreak, .emphasis, .strong, .strikethrough, .link,
             .image, .inlineAttributes, .other:
            // A container is read as what it holds (an image as its
            // alternative text), and a thematic break holds nothing.
            descend(into: node)
        }
    }

    /// Visits each child of `node`, in order.
    private mutating func descend(into node: MarkdownNode) {
        for child in node.children {
            visit(child)
        }
    }

    // MARK: Writing

    /// Append text to the reading. A table cell's first words are kept apart
    /// from the words of its row before them by one space, unless whitespace
    /// on either side already keeps them apart.
    private mutating func append(_ text: UnsafeRawBufferPointer) {
        if cellBoundaryIsPending, !text.isEmpty {
            cellBoundaryIsPending = false
            if runsOn(into: text) {
                write(Self.space)
            }
        }
        write(text)
    }

    /// Append `text`, a few characters the walk itself writes, as `append(_:)` does.
    private mutating func append(_ text: StaticString) {
        text.withUTF8Buffer { append(UnsafeRawBufferPointer($0)) }
    }

    /// The space that keeps two cells' words apart.
    private static let space: StaticString = " "

    /// Writes `text` with no regard to a cell's boundary.
    private mutating func write(_ text: StaticString) {
        text.withUTF8Buffer { write(UnsafeRawBufferPointer($0)) }
    }

    /// Writes the UTF-8 bytes `text`, and counts them. The length is kept in
    /// UTF-16 units as the bytes arrive, so books with many headings remain
    /// linear in size, including text containing emoji and combining
    /// characters: one unit for each scalar, and one more for each scalar of
    /// four bytes, which UTF-16 writes as a pair.
    private mutating func write(_ text: UnsafeRawBufferPointer) {
        bytes.append(contentsOf: text)
        var units = 0
        for byte in text {
            // Every byte but a continuation byte (10xxxxxx) begins a scalar.
            if byte & 0xC0 != 0x80 { units += 1 }
            // A lead byte of 11110xxx begins a scalar of four bytes.
            if byte >= 0xF0 { units += 1 }
        }
        utf16Length += units
    }

    /// Whether `text` would run on into the words written so far: there are
    /// some, and no whitespace (Unicode White_Space) on either side of the
    /// join. Scalars decide, as in `HTMLReadingText`, so a combining mark
    /// joined to a space cannot hide it.
    private func runsOn(into text: UnsafeRawBufferPointer) -> Bool {
        // The last scalar written begins at the last byte that is no
        // continuation byte, and the first of `text` ends within four bytes.
        guard let lastStart = bytes.lastIndex(where: { $0 & 0xC0 != 0x80 }),
              let last = String(decoding: bytes[lastStart...], as: UTF8.self).unicodeScalars.last,
              let first = String(decoding: text.prefix(4), as: UTF8.self).unicodeScalars.first else { return false }
        return !last.properties.isWhitespace && !first.properties.isWhitespace
    }

    /// Separate block elements while preserving the extractor's existing
    /// paragraph convention for navigation and speech pauses.
    private mutating func separateBlock() {
        if !bytes.isEmpty && !endsWithBlankLine {
            append("\n\n")
        }
    }

    /// Whether the text so far ends with a blank line, by the rule the text
    /// has always been kept apart with: `String.hasSuffix("\n\n")` of the
    /// text as a string.
    ///
    /// That rule is not simply "the last two bytes are line feeds": it
    /// compares whole Characters, and a carriage return with the line feed
    /// after it is one Character, which is not a line feed. So a blank line
    /// right after a carriage return does not count, and another blank line
    /// follows it. Only the entity `&#13;` puts a carriage return in the
    /// text: cmark reads one that ends a line, in code too, as a line feed.
    /// The rule is kept as it was, so every book reads as it did (400,000
    /// generated texts read by both walks found it, November 15, 2026).
    private var endsWithBlankLine: Bool {
        let count = bytes.count
        guard count >= 2, bytes[count - 1] == Self.lineFeed, bytes[count - 2] == Self.lineFeed else { return false }
        return count == 2 || bytes[count - 3] != Self.carriageReturn
    }

    /// A line feed, in UTF-8.
    private static let lineFeed: UInt8 = 0x0A
    /// A carriage return, in UTF-8.
    private static let carriageReturn: UInt8 = 0x0D

    // MARK: Tables

    /// A table reads as an HTML table does (`HTMLReadingText`, TODO T03): a
    /// block of its own, apart from the text before and after it, in which
    /// each row, the header row included, is a paragraph of its cells'
    /// words with one space between cells. Speech pauses after each row, as
    /// after any paragraph, and reads the cells of a row as distinct words.
    ///
    /// cmark's table holds its rows, the header row first. The tree this walk
    /// read before held a head and a body under the table, and the rows under
    /// the body: a level of their own that held nothing else. The count of
    /// levels keeps that shape, so a tree at the limit is refused exactly
    /// where it was: the body is a level entered even with no row in it.
    /// `MarkdownNode.levels(stopAbove:)` counts the same body level, for
    /// the walks that do not count their own.
    private mutating func readTable(_ table: MarkdownNode) {
        separateBlock()
        var row = table.firstChild
        if let head = row, head.kind == .tableHeader {
            visit(head)
            row = head.next
        } else if enterLevel() {
            // No header row (cmark always makes one): the head read then was
            // an empty row, a paragraph that holds no word.
            separateBlock()
            cellBoundaryIsPending = false
            leaveLevel()
        }
        if enterLevel() {
            while let bodyRow = row {
                visit(bodyRow)
                row = bodyRow.next
            }
            leaveLevel()
        }
        cellBoundaryIsPending = false
        separateBlock()
    }

    /// Read a table row, the header row or a body row, as a paragraph of its
    /// own, which its first cell's words begin.
    private mutating func readRow(_ row: MarkdownNode) {
        separateBlock()
        cellBoundaryIsPending = false
        descend(into: row)
    }

    // MARK: Headings

    /// Record the exact text position before walking the heading's children.
    private mutating func readHeading(_ heading: MarkdownNode) {
        separateBlock()
        let offset = utf16Length
        currentHeadingOffset = offset
        descend(into: heading)
        currentHeadingOffset = nil
        // The label is made once the heading has been walked, and not at all
        // when the walk met a level deeper than it reads: the text is then
        // refused whole, so the label is never seen, and making a label
        // never goes deeper than the walk did. Nothing else adds to
        // `headings` meanwhile, so their order is the order of reading.
        headings.append((heading.headingLevel, exceededDepth ? "" : Self.visibleLabel(of: heading), offset))
        append("\n\n")
    }

    /// Heading-list labels contain only visible words. HTML comments, such as
    /// annotations inside headings of caches written before format 3.0.5, are
    /// never displayed. Every other label keeps the plain text swift-markdown
    /// gave it exactly (`plainText(of:style:)`), so existing labels and the
    /// heading IDs built from them hold; that includes a label whose literal
    /// text merely spells "<!--", which is not trimmed of characters such as
    /// U+200B at its ends.
    private static func visibleLabel(of heading: MarkdownNode) -> String {
        let label = plainText(ofChildrenOf: heading, style: .plain)
        guard label.contains("<!--") else { return label }
        let visible = plainText(ofChildrenOf: heading, style: .withoutComments)
        guard visible != label else { return label }
        return visible.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The two ways a heading's inline nodes are joined into a label.
    private enum LabelStyle {
        /// swift-markdown's `plainText`: every node's own plain text.
        case plain
        /// The same without HTML comments, and with every container read as
        /// what it holds, so struck-through words have no tildes around them.
        case withoutComments
    }

    /// The plain text of `node`'s children, joined, as swift-markdown's
    /// `InlineContainer.plainText` joined them.
    private static func plainText(ofChildrenOf node: MarkdownNode, style: LabelStyle) -> String {
        var text = ""
        for child in node.children {
            text += plainText(of: child, style: style)
        }
        return text
    }

    /// The plain text of one inline node, as swift-markdown 0.9.0 defined it
    /// for each kind: a text's characters; code between backticks; a soft
    /// break as a space and a hard one as a line feed; raw HTML as it is;
    /// emphasis, strong text, a link, an image, and inline attributes as what
    /// they hold; and struck-through text as what it holds between tildes.
    /// A block, which a heading never holds, has none.
    private static func plainText(of node: MarkdownNode, style: LabelStyle) -> String {
        switch node.kind {
        case .text:
            return node.literal
        case .inlineCode:
            return "`\(node.literal)`"
        case .softBreak:
            return " "
        case .lineBreak:
            return "\n"
        case .inlineHTML:
            let raw = node.literal
            return style == .withoutComments && raw.hasPrefix("<!--") ? "" : raw
        case .strikethrough:
            let held = plainText(ofChildrenOf: node, style: style)
            return style == .plain ? "~\(held)~" : held
        case .emphasis, .strong, .link, .image, .inlineAttributes:
            return plainText(ofChildrenOf: node, style: style)
        case .document, .blockQuote, .list, .listItem, .codeBlock, .htmlBlock, .paragraph, .heading, .thematicBreak,
             .table, .tableHeader, .tableRow, .tableCell, .other:
            return ""
        }
    }

    // MARK: Raw HTML and Markers

    /// Block annotations precede a chapter or block target; establish the same
    /// paragraph boundary as the following block without adding label text.
    ///
    /// CommonMark makes a line that begins with `<!--` an HTML block, the whole
    /// line included, so words that follow a marker on that line (ST05) belong
    /// to the block and would be lost, with the page or heading they begin. The
    /// writers never write such a line (`MarkdownMarkerWriter` keeps a marker
    /// off the start of a line that holds words), so nothing they wrote parses
    /// differently; an Edit Text change can make one, by deleting the text
    /// before an inline marker or by joining lines. A block that begins with
    /// one or more of our complete markers and then holds words is therefore
    /// read as its markers followed by the Markdown of the rest, whose words,
    /// emphasis, and offsets are read in place. Those words are read whether
    /// or not the markers are (`includeNavigationHeadings`). A block that is
    /// exactly one marker, or that begins with any other comment, reads as it
    /// always has. So does any HTML block inside such a rest
    /// (`isReadingRestOfMarkerLine`): the re-parsing goes one level deep.
    private mutating func readHTMLBlock(_ rawHTML: String) {
        if !isReadingRestOfMarkerLine, let (markers, rest) = MarkdownMarker.leading(of: rawHTML) {
            if includeNavigationHeadings {
                for marker in markers { record(marker) }
            }
            // The rest is ordinary Markdown on its own: visit each block as
            // any block is, so a paragraph, a list, or emphasis reads in place.
            // The rest is a text of its own, so it is counted like one before it is parsed.
            let restText = String(rest)
            guard !MarkdownNesting.isDeeper(restText, than: limits.deepestNesting) else {
                exceededDepth = true
                return
            }
            isReadingRestOfMarkerLine = true
            MarkdownTree.read(restText) { document in descend(into: document) }
            isReadingRestOfMarkerLine = false
        } else if includeNavigationHeadings, let marker = MarkdownMarker.decode(rawHTML) {
            record(marker)
        }
    }

    /// Note `marker` at the current place in the reading. It names the same
    /// place as the block after it (PG01), so the block boundary comes first.
    private mutating func record(_ marker: MarkdownMarker) {
        separateBlock()
        switch marker {
        case .heading(let annotation):
            navigationHeadings.append((annotation.level, annotation.text, utf16Length))
        case .page(let page):
            pages.append((page.label, utf16Length))
        }
    }

    /// Inline anchors and page markers keep their precise location within the
    /// current paragraph.
    /// Inside a heading an anchor names the heading itself, so it shares the
    /// heading's offset instead of adding a row partway through its label.
    private mutating func readInlineHTML(_ html: MarkdownNode) {
        // Raw HTML is read only for the markers it may be: no string is made
        // of it for a reader that reads none.
        guard includeNavigationHeadings else { return }
        let rawHTML = html.literal
        if let annotation = MarkdownHeadingAnnotation.decode(rawHTML) {
            navigationHeadings.append((annotation.level, annotation.text, currentHeadingOffset ?? utf16Length))
        } else if let marker = MarkdownPageMarker.decode(rawHTML) {
            // Likewise a page marker: its exact place, or the heading's start.
            pages.append((marker.label, currentHeadingOffset ?? utf16Length))
        }
    }
}
