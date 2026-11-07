import Foundation
import Markdown

// MARK: - The Walk of content.md (FMT18)

/// Turns a text book's content.md into the `ExportDocument` every text writer
/// reads.
///
/// Markdown is the base, and stays the base: every text book becomes
/// content.md, and every writer starts from it through this walk. HTML is the
/// first writer made from it, not a new base (the user's answer to Q21,
/// October 17, 2026).
///
/// The walk keeps and drops what the reader (`MarkdownDocParser`) keeps and
/// drops, so a writer's output holds the words a listener hears, hand edits
/// to content.md included, and none of TextMouth's own marker comments or
/// heading annotations, nor any other raw HTML. Nothing in the text is
/// rewritten.
enum ExportDocumentWalker {
    /// The document of the content.md whose bytes, read from `url`, are
    /// `bytes`, decoded as the reader decodes them
    /// (`MarkdownCacheService.cacheText(from:at:)`). Bytes that are not UTF-8
    /// throw the error reading the file as text throws; cancelling stops the
    /// walk with `CancellationError`
    /// (`document(fromMarkdown:book:options:cancellation:)`).
    static func document(
        fromContentBytes bytes: Data,
        at url: URL,
        book: ExportBookDetails,
        options: ExportWalkOptions = .plain,
        cancellation: BookExportCancellation? = nil
    ) throws -> ExportDocument {
        let markdown = try MarkdownCacheService.cacheText(from: bytes, at: url)
        return try document(fromMarkdown: markdown, book: book, options: options, cancellation: cancellation)
    }

    /// The document of `markdown`, a content.md, for `book`. The text is split
    /// into chapters at TextMouth's chapter markers exactly as the reader
    /// splits it (text before the first marker is left out, as the reader
    /// leaves it out); text without a marker is one chapter with no title.
    /// `options` say what besides the words the document keeps. `cancellation`
    /// is checked before each chapter, and a cancelled export throws
    /// `CancellationError`.
    static func document(
        fromMarkdown markdown: String,
        book: ExportBookDetails,
        options: ExportWalkOptions = .plain,
        cancellation: BookExportCancellation? = nil
    ) throws -> ExportDocument {
        var sections = MarkdownCacheService.splitChapters(markdown)
        if sections.isEmpty {
            sections = [(title: "", content: markdown)]
        }

        var walk = Walk(options: options)
        var blocks: [ExportBlock] = []
        var chapterStarts: [ExportChapterStart] = []
        for section in sections {
            try cancellation?.checkCancelled()
            if options.keepsChapters {
                chapterStarts.append(ExportChapterStart(blockIndex: blocks.count, title: section.title))
            }
            blocks += walk.blocks(ofSectionTitled: section.title, content: section.content)
        }

        // The book's title heads a document that has no level-1 heading of
        // its own, wherever in the text such a heading would be. It is
        // claimed last, so its id cannot take another heading's.
        let title = book.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var titleHeading: ExportHeading?
        if !title.isEmpty, !ExportBlock.headings(in: blocks).contains(where: { $0.level == 1 }) {
            titleHeading = walk.plainHeading(level: 1, title: title)
        }
        return ExportDocument(book: book, titleHeading: titleHeading, blocks: blocks, chapterStarts: chapterStarts)
    }
}

// MARK: - What a Walk Keeps

/// What a walk of content.md keeps besides the words: a writer that has a
/// place for chapters and pages asks for them, and every other writer's
/// document is the one it always was.
struct ExportWalkOptions: Equatable, Sendable {
    /// Whether the document says where each chapter of the book begins
    /// (`ExportDocument.chapterStarts`).
    var keepsChapters = false
    /// Whether the document keeps content.md's page markers, as page breaks
    /// between blocks (`ExportBlock.pageBreak`) and inside text
    /// (`ExportRun.pageBreak`), read where the reader reads them.
    var keepsPageMarkers = false

    /// The words alone: what HTML, RTF, Word, and braille write.
    static let plain = ExportWalkOptions()
    /// The book's chapters and pages as well, for a writer of an e-book.
    static let bookStructure = ExportWalkOptions(keepsChapters: true, keepsPageMarkers: true)
}

// MARK: - Heading IDs

/// Makes the ids of a document's headings: each made from the heading's text
/// and unique among the ids claimed, so that a contents list and links within
/// the document can point to any heading. An id is a name XML accepts, of
/// ASCII letters, digits, and hyphens, beginning with a letter.
struct ExportHeadingIDs {
    /// The ids claimed so far.
    private var taken: Set<String> = []
    /// For each slug claimed more than once, the next number to try, so that
    /// claiming stays linear however many headings share a name.
    private var nextNumber: [String: Int] = [:]

    /// The longest slug, in characters.
    private static let maximumSlugLength = 64
    /// How many characters of a heading its slug is made from.
    private static let maximumSourceLength = 200

    /// The id for a heading of `text`: its slug when no heading has taken
    /// it, otherwise the first of "slug-2", "slug-3", and so on that no
    /// heading has taken. The id returned is taken from then on.
    mutating func claim(_ text: String) -> String {
        let slug = Self.slug(text)
        if taken.insert(slug).inserted {
            return slug
        }
        // Resume at the next number for this slug, passing any id a heading
        // of its own already has (such as "notes-2" from a heading "Notes 2").
        var number = nextNumber[slug, default: 2]
        var candidate = "\(slug)-\(number)"
        while taken.contains(candidate) {
            number += 1
            candidate = "\(slug)-\(number)"
        }
        nextNumber[slug] = number + 1
        taken.insert(candidate)
        return candidate
    }

    /// `text` as an id: the first 200 characters folded to ASCII (Latin
    /// letters without accents, other scripts transliterated), lowercased,
    /// each run of anything but ASCII letters and digits a single hyphen,
    /// hyphens at both ends dropped, and cut to 64 characters. Nothing left
    /// gives "heading", and a result that begins with a digit gets "heading-"
    /// before it so the id is a valid XML name.
    static func slug(_ text: String) -> String {
        let source = String(text.prefix(maximumSourceLength))
        let latin = source.applyingTransform(.toLatin, reverse: false) ?? source
        let folded = (latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin).lowercased()

        // Build the slug scalar by scalar, collapsing each run of other
        // characters into one hyphen (none at the start).
        var slug = ""
        var pendingHyphen = false
        for scalar in folded.unicodeScalars {
            let isLetter = ("a"..."z").contains(scalar)
            let isDigit = ("0"..."9").contains(scalar)
            if isLetter || isDigit {
                if pendingHyphen && !slug.isEmpty {
                    slug.append("-")
                }
                pendingHyphen = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }

        // Cutting may leave a hyphen at the end.
        slug = String(slug.prefix(maximumSlugLength))
        while slug.hasSuffix("-") {
            slug.removeLast()
        }
        if slug.isEmpty {
            return "heading"
        }
        return slug.first?.isNumber == true ? "heading-\(slug)" : slug
    }
}

// MARK: - The Walk's State

/// The state of one walk of a content.md: the ids its headings have taken,
/// and the functions that make blocks and runs from swift-markdown's tree.
/// Every swift-markdown type is written `Markdown.Name`, since TextMouth has
/// types of its own with some of the same names.
private struct Walk {
    /// What the walk keeps besides the words.
    let options: ExportWalkOptions
    /// The ids claimed so far, shared by every chapter of the document.
    var ids = ExportHeadingIDs()
    /// How many pages have been met, so each page's id is its number.
    var pageCount = 0
    /// Whether the rest of a marker-led HTML block is being walked: another
    /// marker-led block inside it is not read again (as the reader does not,
    /// so a crafted line cannot be re-parsed once per level).
    var isReadingRestOfMarkerLine = false

    init(options: ExportWalkOptions) {
        self.options = options
    }

    // MARK: Chapters

    /// The blocks of one chapter: `content` parsed as Markdown. A chapter that
    /// has a title but no heading of any depth begins with its title as a
    /// level-1 heading, as the reader gives such a chapter its title. A walk
    /// that keeps the chapters adds none: it says where each chapter begins
    /// and what it is called (`ExportDocument.chapterStarts`), and the writer
    /// that asked names the chapter in its contents without adding words the
    /// book does not have.
    mutating func blocks(ofSectionTitled title: String, content: String) -> [ExportBlock] {
        let parsed = Markdown.Document(parsing: content)
        var blocks = self.blocks(in: parsed, nesting: 0, listDepth: 0)
        // Claimed after the blocks are made: they hold no heading, so the
        // order of ids is still the order of reading.
        if !options.keepsChapters, !title.isEmpty, ExportBlock.headings(in: blocks).isEmpty {
            blocks.insert(.heading(plainHeading(level: 1, title: title)), at: 0)
        }
        return blocks
    }

    /// A heading of `level` whose one plain run is `title`.
    mutating func plainHeading(level: Int, title: String) -> ExportHeading {
        ExportHeading(level: level, runs: [ExportRun(title)], id: ids.claim(title))
    }

    // MARK: Blocks

    /// The blocks of `container`'s children, in order. `nesting` counts the
    /// lists and quotes opened around the container and `listDepth` the lists;
    /// the document's body is 0 and 0.
    mutating func blocks(in container: Markdown.Markup, nesting: Int, listDepth: Int) -> [ExportBlock] {
        var made: [ExportBlock] = []
        for child in container.children {
            made += blocks(of: child, nesting: nesting, listDepth: listDepth)
        }
        return made
    }

    /// The blocks `block` makes: usually one, none for a block that is
    /// dropped, several for a list or quote past the nesting cap.
    private mutating func blocks(of block: Markdown.Markup, nesting: Int, listDepth: Int) -> [ExportBlock] {
        switch block {
        case let heading as Markdown.Heading:
            // A page that starts inside a heading starts where the heading
            // does (as the reader places it), so it is a break before it.
            let (pages, runs) = Self.splittingPages(from: self.runs(of: heading))
            let breaks = pages.map(ExportBlock.pageBreak)
            // A heading with nothing to read is dropped, as the reader's
            // heading list drops it.
            guard !runs.isEmpty else { return breaks }
            let level = min(max(heading.level, 1), 6)
            return breaks + [.heading(ExportHeading(level: level, runs: runs, id: ids.claim(runs.plainText)))]

        case let paragraph as Markdown.Paragraph:
            let runs = self.runs(of: paragraph)
            // A paragraph that is only the start of a page is that and no
            // paragraph.
            if !runs.isEmpty, runs.allSatisfy({ $0.pageBreak != nil }) {
                return runs.compactMap(\.pageBreak).map(ExportBlock.pageBreak)
            }
            return runs.isEmpty ? [] : [.paragraph(runs)]

        case let list as Markdown.UnorderedList:
            return listBlocks(of: list, isOrdered: false, start: 1, nesting: nesting, listDepth: listDepth)

        case let list as Markdown.OrderedList:
            // CommonMark allows a start of at most nine digits (a longer
            // number is no list), so the parser's start always fits; the
            // conversion clamps all the same, so it can never trap.
            let start = Int(clamping: list.startIndex)
            return listBlocks(of: list, isOrdered: true, start: start, nesting: nesting, listDepth: listDepth)

        case let quote as Markdown.BlockQuote:
            // Past the cap the quote is not opened: its blocks join the
            // container that holds it.
            if nesting >= ExportDocument.maximumNesting {
                return blocks(in: quote, nesting: nesting, listDepth: listDepth)
            }
            return [.blockQuote(blocks(in: quote, nesting: nesting + 1, listDepth: listDepth))]

        case let code as Markdown.CodeBlock:
            // The parser keeps the line feed that ends the code.
            var text = code.code
            if text.hasSuffix("\n") {
                text.removeLast()
            }
            return text.isEmpty ? [] : [.codeBlock(text)]

        case is Markdown.ThematicBreak:
            return [.thematicBreak]

        case let table as Markdown.Table:
            // A page that starts in a cell starts before the table: a table
            // cell's text is plain text here.
            let (pages, converted) = self.table(of: table)
            return pages.map(ExportBlock.pageBreak) + (converted.map { [.table($0)] } ?? [])

        case let html as Markdown.HTMLBlock:
            return blocks(ofHTML: html, nesting: nesting, listDepth: listDepth)

        case let other as Markdown.BlockContainer:
            // Any other container is walked for its children; any other
            // block is dropped.
            return blocks(in: other, nesting: nesting, listDepth: listDepth)

        default:
            return []
        }
    }

    /// The blocks an HTML block makes. TextMouth's marker comments, its
    /// heading annotations, and any raw HTML make none, as the reader never
    /// reads them, but for what follows a line's markers (ST05, read as the
    /// reader reads it, `MarkdownMarker.leading(of:)`): that is Markdown, and
    /// its blocks are walked, preceded by the page breaks of the markers.
    private mutating func blocks(ofHTML html: Markdown.HTMLBlock, nesting: Int, listDepth: Int) -> [ExportBlock] {
        if !isReadingRestOfMarkerLine, let (markers, rest) = MarkdownMarker.leading(of: html.rawHTML) {
            var made = markers.compactMap { pageBreak(of: $0) }.map(ExportBlock.pageBreak)
            isReadingRestOfMarkerLine = true
            made += blocks(in: Markdown.Document(parsing: String(rest)), nesting: nesting, listDepth: listDepth)
            isReadingRestOfMarkerLine = false
            return made
        }
        if let marker = MarkdownMarker.decode(html.rawHTML), let page = pageBreak(of: marker) {
            return [.pageBreak(page)]
        }
        return []
    }

    // MARK: Pages

    /// The page `marker` starts, with the next id, when the walk keeps page
    /// markers and `marker` is one; nil otherwise (a heading annotation, or a
    /// walk of the words alone).
    private mutating func pageBreak(of marker: MarkdownMarker) -> ExportPageBreak? {
        guard options.keepsPageMarkers, case .page(let page) = marker else { return nil }
        pageCount += 1
        return ExportPageBreak(label: page.label, id: "page_\(pageCount)")
    }

    /// `runs` as the starts of pages they hold, in order, and the runs that
    /// are text, neighbours of one style joined again where a page was
    /// between them.
    private static func splittingPages(from runs: [ExportRun]) -> (pages: [ExportPageBreak], text: [ExportRun]) {
        (runs.compactMap(\.pageBreak), joined(runs.filter { $0.pageBreak == nil }))
    }

    /// The blocks of a list whose items are `list`'s children. Past the
    /// nesting cap the list is not opened: each item's blocks, in turn, join
    /// the container that holds it.
    private mutating func listBlocks(
        of list: Markdown.Markup,
        isOrdered: Bool,
        start: Int,
        nesting: Int,
        listDepth: Int
    ) -> [ExportBlock] {
        let items = list.children.compactMap { $0 as? Markdown.ListItem }
        if nesting >= ExportDocument.maximumNesting {
            var joined: [ExportBlock] = []
            for item in items {
                joined += blocks(in: item, nesting: nesting, listDepth: listDepth)
            }
            return joined
        }
        // A task-list checkbox is ignored: the item's words are all it keeps.
        var exportItems: [ExportListItem] = []
        for item in items {
            exportItems.append(ExportListItem(blocks: blocks(in: item, nesting: nesting + 1, listDepth: listDepth + 1)))
        }
        return [.list(ExportList(isOrdered: isOrdered, start: start, depth: listDepth, items: exportItems))]
    }

    // MARK: Tables

    /// `table` as an `ExportTable`, its cells as plain text, or nil when it
    /// has no row left. A head row whose cells are all empty is left out, and
    /// the table has no header row.
    /// Also the pages that start in its cells, in reading order.
    private mutating func table(of table: Markdown.Table) -> (pages: [ExportPageBreak], table: ExportTable?) {
        var pages: [ExportPageBreak] = []
        let head = Array(table.head.cells).map { cellText($0, pages: &pages) }
        let body = Array(table.body.rows).map { row in Array(row.cells).map { cellText($0, pages: &pages) } }
        let hasHeaderRow = head.contains { !$0.isEmpty }
        let rows = (hasHeaderRow ? [head] : []) + body
        return (pages, rows.isEmpty ? nil : ExportTable(rows: rows, hasHeaderRow: hasHeaderRow))
    }

    /// A cell's words as one line: its runs' plain text with every line feed
    /// a space, trimmed. The pages that start in it join `pages`.
    private mutating func cellText(_ cell: Markdown.Markup, pages: inout [ExportPageBreak]) -> String {
        let (cellPages, text) = Self.splittingPages(from: runs(of: cell))
        pages += cellPages
        return text.plainText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Runs

    /// The runs of `container`'s inline children, for a heading, a paragraph,
    /// or a table cell: neighbouring runs of one style joined, runs with no
    /// text dropped (but for the start of a page), and white space and line
    /// feeds trimmed from both ends of the text.
    mutating func runs(of container: Markdown.Markup) -> [ExportRun] {
        var runs = Self.joined(inlineRuns(of: container, style: ExportRun("")))
        // Trim the first run that has text at its start and the last at its
        // end, dropping any run that trimming empties, until each end has
        // text. A page that starts there stays where it is.
        var index = 0
        while index < runs.count {
            if runs[index].pageBreak != nil {
                index += 1
                continue
            }
            let trimmed = runs[index].text.drop { $0.isWhitespace || $0.isNewline }
            if trimmed.isEmpty {
                runs.remove(at: index)
            } else {
                runs[index].text = String(trimmed)
                break
            }
        }
        index = runs.count - 1
        while index >= 0 {
            if runs[index].pageBreak != nil {
                index -= 1
                continue
            }
            var text = runs[index].text
            while let end = text.last, end.isWhitespace || end.isNewline {
                text.removeLast()
            }
            if text.isEmpty {
                runs.remove(at: index)
                index -= 1
            } else {
                runs[index].text = text
                break
            }
        }
        return runs
    }

    /// The runs of `markup`'s children in `style` (an `ExportRun` with empty
    /// text, carrying the emphasis, strength, code, and link of the markup
    /// around them), before neighbours are joined.
    private mutating func inlineRuns(of markup: Markdown.Markup, style: ExportRun) -> [ExportRun] {
        var made: [ExportRun] = []
        for child in markup.children {
            var inner = style
            switch child {
            case let text as Markdown.Text:
                made.append(Self.styled(text.string, like: style))
                continue
            case is Markdown.Emphasis:
                inner.isEmphasis = true
            case is Markdown.Strong:
                inner.isStrong = true
            case is Markdown.Strikethrough:
                break // keeps the style it is in
            case let code as Markdown.InlineCode:
                inner.isCode = true
                made.append(Self.styled(code.code, like: inner))
                continue
            case let link as Markdown.Link:
                // Only a web or mail address becomes a link; any other
                // link's words are plain text in the style they had.
                if let destination = link.destination, ExportRun.isAllowedLinkAddress(destination) {
                    inner.link = destination.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case is Markdown.Image:
                break // its alternative text, in the style it is in; never its source
            case is Markdown.SoftBreak:
                made.append(Self.styled(" ", like: style))
                continue
            case is Markdown.LineBreak:
                made.append(Self.styled("\n", like: style))
                continue
            case let html as Markdown.InlineHTML:
                // Dropped, ahead of the container case below, but for the
                // start of a page where the walk keeps them: a run of its own
                // at its exact place in the text, in the style it is in.
                if let marker = MarkdownMarker.decode(html.rawHTML), let page = pageBreak(of: marker) {
                    var run = Self.styled("", like: style)
                    run.pageBreak = page
                    made.append(run)
                }
                continue
            case is Markdown.InlineContainer:
                break // any other container: its children
            default:
                continue // any other inline: nothing
            }
            made += inlineRuns(of: child, style: inner)
        }
        return made
    }

    /// A run of `text` in the style of `style`.
    private static func styled(_ text: String, like style: ExportRun) -> ExportRun {
        var run = style
        run.text = text
        return run
    }

    /// `runs` with neighbours of one style (`hasSameStyle(as:)`) joined into
    /// one run, and runs with no text dropped, but for the start of a page.
    private static func joined(_ runs: [ExportRun]) -> [ExportRun] {
        var result: [ExportRun] = []
        for run in runs where !run.text.isEmpty || run.pageBreak != nil {
            if let last = result.last, last.hasSameStyle(as: run) {
                result[result.count - 1].text += run.text
            } else {
                result.append(run)
            }
        }
        return result
    }
}
