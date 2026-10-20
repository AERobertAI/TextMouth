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
    /// (`document(fromMarkdown:book:cancellation:)`).
    static func document(
        fromContentBytes bytes: Data,
        at url: URL,
        book: ExportBookDetails,
        cancellation: BookExportCancellation? = nil
    ) throws -> ExportDocument {
        let markdown = try MarkdownCacheService.cacheText(from: bytes, at: url)
        return try document(fromMarkdown: markdown, book: book, cancellation: cancellation)
    }

    /// The document of `markdown`, a content.md, for `book`. The text is split
    /// into chapters at TextMouth's chapter markers exactly as the reader
    /// splits it (text before the first marker is left out, as the reader
    /// leaves it out); text without a marker is one chapter with no title.
    /// `cancellation` is checked before each chapter, and a cancelled export
    /// throws `CancellationError`.
    static func document(
        fromMarkdown markdown: String,
        book: ExportBookDetails,
        cancellation: BookExportCancellation? = nil
    ) throws -> ExportDocument {
        var sections = MarkdownCacheService.splitChapters(markdown)
        if sections.isEmpty {
            sections = [(title: "", content: markdown)]
        }

        var walk = Walk()
        var blocks: [ExportBlock] = []
        for section in sections {
            try cancellation?.checkCancelled()
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
        return ExportDocument(book: book, titleHeading: titleHeading, blocks: blocks)
    }
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
    /// The ids claimed so far, shared by every chapter of the document.
    var ids = ExportHeadingIDs()

    // MARK: Chapters

    /// The blocks of one chapter: `content` parsed as Markdown. A chapter that
    /// has a title but no heading of any depth begins with its title as a
    /// level-1 heading, as the reader gives such a chapter its title.
    mutating func blocks(ofSectionTitled title: String, content: String) -> [ExportBlock] {
        let parsed = Markdown.Document(parsing: content)
        var blocks = self.blocks(in: parsed, nesting: 0, listDepth: 0)
        // Claimed after the blocks are made: they hold no heading, so the
        // order of ids is still the order of reading.
        if !title.isEmpty, ExportBlock.headings(in: blocks).isEmpty {
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
            let runs = Self.runs(of: heading)
            // A heading with nothing to read is dropped, as the reader's
            // heading list drops it.
            guard !runs.isEmpty else { return [] }
            let level = min(max(heading.level, 1), 6)
            return [.heading(ExportHeading(level: level, runs: runs, id: ids.claim(runs.plainText)))]

        case let paragraph as Markdown.Paragraph:
            let runs = Self.runs(of: paragraph)
            return runs.isEmpty ? [] : [.paragraph(runs)]

        case let list as Markdown.UnorderedList:
            return listBlocks(of: list, isOrdered: false, start: 1, nesting: nesting, listDepth: listDepth)

        case let list as Markdown.OrderedList:
            // The start comes from the file, which is untrusted: keep it in
            // a range every writer can print.
            let start = min(max(Int(clamping: list.startIndex), 0), 1_000_000_000)
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
            return Self.table(of: table).map { [.table($0)] } ?? []

        case is Markdown.HTMLBlock:
            // TextMouth's marker comments, its heading annotations, and any
            // raw HTML: the reader never reads them, and nor does a writer.
            return []

        case let other as Markdown.BlockContainer:
            // Any other container is walked for its children; any other
            // block is dropped.
            return blocks(in: other, nesting: nesting, listDepth: listDepth)

        default:
            return []
        }
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
    private static func table(of table: Markdown.Table) -> ExportTable? {
        let head = Array(table.head.cells).map(cellText)
        let body = Array(table.body.rows).map { Array($0.cells).map(cellText) }
        let hasHeaderRow = head.contains { !$0.isEmpty }
        let rows = (hasHeaderRow ? [head] : []) + body
        return rows.isEmpty ? nil : ExportTable(rows: rows, hasHeaderRow: hasHeaderRow)
    }

    /// A cell's words as one line: its runs' plain text with every line feed
    /// a space, trimmed.
    private static func cellText(_ cell: Markdown.Markup) -> String {
        runs(of: cell).plainText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Runs

    /// The runs of `container`'s inline children, for a heading, a paragraph,
    /// or a table cell: neighbouring runs of one style joined, runs with no
    /// text dropped, and white space and line feeds trimmed from both ends.
    static func runs(of container: Markdown.Markup) -> [ExportRun] {
        var runs = joined(inlineRuns(of: container, style: ExportRun("")))
        // Trim the first run's start and the last run's end, dropping any
        // run that trimming empties, until each end has text.
        while let first = runs.first {
            let trimmed = first.text.drop { $0.isWhitespace || $0.isNewline }
            if trimmed.isEmpty {
                runs.removeFirst()
            } else {
                runs[0].text = String(trimmed)
                break
            }
        }
        while let last = runs.last {
            var text = last.text
            while let end = text.last, end.isWhitespace || end.isNewline {
                text.removeLast()
            }
            if text.isEmpty {
                runs.removeLast()
            } else {
                runs[runs.count - 1].text = text
                break
            }
        }
        return runs
    }

    /// The runs of `markup`'s children in `style` (an `ExportRun` with empty
    /// text, carrying the emphasis, strength, code, and link of the markup
    /// around them), before neighbours are joined.
    private static func inlineRuns(of markup: Markdown.Markup, style: ExportRun) -> [ExportRun] {
        markup.children.flatMap { child -> [ExportRun] in
            var inner = style
            switch child {
            case let text as Markdown.Text:
                return [styled(text.string, like: style)]
            case is Markdown.Emphasis:
                inner.isEmphasis = true
            case is Markdown.Strong:
                inner.isStrong = true
            case is Markdown.Strikethrough:
                break // keeps the style it is in
            case let code as Markdown.InlineCode:
                inner.isCode = true
                return [styled(code.code, like: inner)]
            case let link as Markdown.Link:
                // Only a web or mail address becomes a link; any other
                // link's words are plain text in the style they had.
                if let destination = link.destination, ExportRun.isAllowedLinkAddress(destination) {
                    inner.link = destination.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case is Markdown.Image:
                break // its alternative text, in the style it is in; never its source
            case is Markdown.SoftBreak:
                return [styled(" ", like: style)]
            case is Markdown.LineBreak:
                return [styled("\n", like: style)]
            case is Markdown.InlineHTML:
                return [] // dropped, ahead of the container case below
            case is Markdown.InlineContainer:
                break // any other container: its children
            default:
                return [] // any other inline: nothing
            }
            return inlineRuns(of: child, style: inner)
        }
    }

    /// A run of `text` in the style of `style`.
    private static func styled(_ text: String, like style: ExportRun) -> ExportRun {
        var run = style
        run.text = text
        return run
    }

    /// `runs` with neighbours of one style (`hasSameStyle(as:)`) joined into
    /// one run, and runs with no text dropped.
    private static func joined(_ runs: [ExportRun]) -> [ExportRun] {
        var result: [ExportRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = result.last, last.hasSameStyle(as: run) {
                result[result.count - 1].text += run.text
            } else {
                result.append(run)
            }
        }
        return result
    }
}
