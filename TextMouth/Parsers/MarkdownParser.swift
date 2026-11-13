import Foundation
import Markdown

enum MarkdownDocParser {

    static func parse(markdown: String, title: String = "Untitled") throws -> DocumentContent {
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
    /// the limit on the tree (`MarkupGuard.Limits.deepestParsedTree`).
    ///
    /// - Parameter includeNavigationHeadings: Whether the generated markers of
    ///   content.md are read: heading annotations, which add navigation
    ///   headings, and page markers (PG01), which add pages. Everywhere else
    ///   they are ordinary comments, unseen.
    /// - Throws: `MarkupRefusal.nestedTooDeeply` when the Markdown nests past the limit.
    static func parseChapter(
        markdown: String,
        title: String = "Untitled",
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
        let document = Document(parsing: markdown)

        // Capture headings while emitting their text. Searching for their
        // labels afterwards can bind a heading to an earlier body paragraph.
        var textExtractor = PlainTextExtractor(includeNavigationHeadings: includeNavigationHeadings, limits: limits)
        textExtractor.visit(document)
        // A tree deeper than the limit was not walked past it: the text read is partial, so refuse it.
        if textExtractor.exceededDepth { throw MarkupRefusal.nestedTooDeeply(limit: limits.deepestNesting) }
        let plainText = textExtractor.result.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstContent = textExtractor.result.rangeOfCharacter(from: .whitespacesAndNewlines.inverted)?.lowerBound
            ?? textExtractor.result.endIndex
        let trimmedPrefixLength = textExtractor.result.utf16Offset(of: firstContent)
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
        headings.sort { $0.characterOffset < $1.characterOffset }

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

private struct PlainTextExtractor: MarkupWalker {
    var includeNavigationHeadings = false
    var result = ""
    var headings: [(level: Int, text: String, offset: Int)] = []
    var navigationHeadings: [(level: Int, text: String, offset: Int)] = []
    /// The page markers met, in reading order, with the offset at which each
    /// stood in `result` (PG01). Read under the same rule as navigation headings.
    var pages: [(label: String, offset: Int)] = []
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

    /// The deepest tree the walk reads, the document at level 1. A list takes
    /// two levels (the list and its item), so the limit on the count of
    /// containers (`deepestNesting`) allows twice as many levels of tree, and a
    /// few more for the paragraph, its emphasis, and its text. A test that sets
    /// `Limits.deepestTree` lifts the count and sees the walk refuse.
    private var deepestTree: Int {
        limits.deepestTree ?? (2 * min(limits.deepestNesting, Int.max / 4) + Self.levelsBeyondContainers)
    }

    /// The levels a tree has beyond its containers: the document, a paragraph or
    /// heading, and some emphasis and a link around the text.
    private static let levelsBeyondContainers = 16

    /// Visits `markup` unless the walk is already at the deepest level it reads,
    /// so no level of a tree deeper than the limit is entered; the stop is
    /// recorded in `exceededDepth`. Every level the walk enters comes through
    /// here, since `descendInto` visits each child.
    mutating func visit(_ markup: Markup) {
        guard depth < deepestTree else {
            exceededDepth = true
            return
        }
        depth += 1
        defer { depth -= 1 }
        markup.accept(&self)
    }

    /// Append text to the reading. A table cell's first words are kept apart
    /// from the words of its row before them by one space, unless whitespace
    /// on either side already keeps them apart.
    private mutating func append(_ text: String) {
        if cellBoundaryIsPending, !text.isEmpty {
            cellBoundaryIsPending = false
            if runsOn(into: text) {
                write(" ")
            }
        }
        write(text)
    }

    /// Track offsets incrementally so books with many headings remain linear
    /// in size, including text containing emoji and combining characters.
    private mutating func write(_ text: String) {
        result += text
        utf16Length += text.utf16.count
    }

    /// Whether `text` would run on into the words written so far: there are
    /// some, and no whitespace (Unicode White_Space) on either side of the
    /// join. Scalars decide, as in `HTMLReadingText`, so a combining mark
    /// joined to a space cannot hide it.
    private func runsOn(into text: String) -> Bool {
        guard let last = result.unicodeScalars.last, let first = text.unicodeScalars.first else { return false }
        return !last.properties.isWhitespace && !first.properties.isWhitespace
    }

    /// Separate block elements while preserving the extractor's existing
    /// paragraph convention for navigation and speech pauses.
    private mutating func separateBlock() {
        if !result.isEmpty && !result.hasSuffix("\n\n") {
            append("\n\n")
        }
    }

    /// Text leaves provide ordinary prose and inline formatting contents.
    mutating func visitText(_ text: Markdown.Text) -> () {
        append(text.string)
    }

    /// Code is a leaf node, so the default walker would silently omit it.
    mutating func visitInlineCode(_ inlineCode: InlineCode) -> () {
        append(inlineCode.code)
    }

    /// Retain fenced and indented code, including its internal line breaks.
    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> () {
        separateBlock()
        append(codeBlock.code)
        separateBlock()
    }

    /// A wrapped Markdown source line is a space in the spoken paragraph.
    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> () {
        append(" ")
    }

    /// Explicit Markdown hard breaks retain a newline.
    mutating func visitLineBreak(_ lineBreak: LineBreak) -> () {
        append("\n")
    }

    /// Preserve paragraph boundaries without exposing Markdown syntax.
    mutating func visitParagraph(_ paragraph: Markdown.Paragraph) -> () {
        separateBlock()
        descendInto(paragraph)
    }

    /// A table reads as an HTML table does (`HTMLReadingText`, TODO T03): a
    /// block of its own, apart from the text before and after it, in which
    /// each row, the header row included, is a paragraph of its cells'
    /// words with one space between cells. Speech pauses after each row, as
    /// after any paragraph, and reads the cells of a row as distinct words.
    mutating func visitTable(_ table: Markdown.Table) -> () {
        separateBlock()
        descendInto(table)
        cellBoundaryIsPending = false
        separateBlock()
    }

    /// The header row is a paragraph like any other row.
    mutating func visitTableHead(_ tableHead: Markdown.Table.Head) -> () {
        readRow(tableHead)
    }

    /// Each body row is a paragraph of its own.
    mutating func visitTableRow(_ tableRow: Markdown.Table.Row) -> () {
        readRow(tableRow)
    }

    /// A cell's first words, when it has any, stand apart from the words
    /// before them in its row (`cellBoundaryIsPending`).
    mutating func visitTableCell(_ tableCell: Markdown.Table.Cell) -> () {
        cellBoundaryIsPending = true
        descendInto(tableCell)
    }

    /// Read a table row as a paragraph of its own, which its first cell's
    /// words begin.
    private mutating func readRow(_ row: Markup) {
        separateBlock()
        cellBoundaryIsPending = false
        descendInto(row)
    }

    /// Record the exact text position before walking the heading's children.
    mutating func visitHeading(_ heading: Markdown.Heading) -> () {
        separateBlock()
        headings.append((heading.level, Self.visibleLabel(of: heading), utf16Length))
        currentHeadingOffset = utf16Length
        descendInto(heading)
        currentHeadingOffset = nil
        append("\n\n")
    }

    /// Heading-list labels contain only visible words. HTML comments, such as
    /// annotations inside headings of caches written before format 3.0.5, are
    /// never displayed. Every other label keeps swift-markdown's plain text
    /// exactly, so existing labels and the heading IDs built from them hold;
    /// that includes a label whose literal text merely spells "<!--", which
    /// is not trimmed of characters such as U+200B at its ends.
    private static func visibleLabel(of heading: Markdown.Heading) -> String {
        let label = heading.plainText
        guard label.contains("<!--") else { return label }
        let visible = textExcludingComments(heading)
        guard visible != label else { return label }
        return visible.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mirror swift-markdown's inline plain text (containers join their
    /// children) while omitting HTML comments.
    private static func textExcludingComments(_ markup: Markup) -> String {
        markup.children.map { child -> String in
            if let html = child as? InlineHTML {
                return html.rawHTML.hasPrefix("<!--") ? "" : html.rawHTML
            }
            if child is InlineContainer {
                return textExcludingComments(child)
            }
            return (child as? InlineMarkup)?.plainText ?? ""
        }.joined()
    }

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
    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        if !isReadingRestOfMarkerLine, let (markers, rest) = MarkdownMarker.leading(of: html.rawHTML) {
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
            descendInto(Document(parsing: restText))
            isReadingRestOfMarkerLine = false
        } else if includeNavigationHeadings, let marker = MarkdownMarker.decode(html.rawHTML) {
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
    mutating func visitInlineHTML(_ html: InlineHTML) {
        guard includeNavigationHeadings else { return }
        if let annotation = MarkdownHeadingAnnotation.decode(html.rawHTML) {
            navigationHeadings.append((annotation.level, annotation.text, currentHeadingOffset ?? utf16Length))
        } else if let marker = MarkdownPageMarker.decode(html.rawHTML) {
            // Likewise a page marker: its exact place, or the heading's start.
            pages.append((marker.label, currentHeadingOffset ?? utf16Length))
        }
    }
}
