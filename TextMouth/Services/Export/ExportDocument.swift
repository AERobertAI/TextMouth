import Foundation

// MARK: - The Document Every Text Writer Reads (FMT18)

/// A text book's content.md as every text writer reads it (FMT18): its
/// headings, paragraphs, lists, quotes, code, breaks, and tables, walked once
/// from the Markdown by `ExportDocumentWalker`.
///
/// Markdown is the base, and stays the base. Every text book becomes
/// content.md, the Markdown TextMouth reads it from, and every writer starts
/// from that Markdown through this model: HTML is the first writer made from
/// it, not a new base (the user's answer to Q21 of the formats research,
/// October 17, 2026: "I thought markdown was the base"), RTF and Word 97-2003
/// come next, and braille's BRF and PEF after them. No writer parses Markdown
/// itself.
///
/// What the model leaves out: content.md's own marker lines (the
/// `<!-- chapter: Title -->` line before each chapter, and the annotations
/// that place navigation headings) and any other raw HTML, none of which the
/// reader reads aloud either. What it keeps is the book's text as the reader
/// reads it, the user's hand edits included.
struct ExportDocument: Equatable, Sendable {
    /// What the document says of its book besides its text.
    var book: ExportBookDetails
    /// The book's title as a level-1 heading, for a book whose text has no
    /// level-1 heading of its own; nil when it has one, or has no title.
    /// Writers that open with a title (HTML, RTF, and Word) write it first.
    /// Its id is unique among the ids of the headings in `blocks`.
    var titleHeading: ExportHeading?
    /// The book's text, block by block, in reading order.
    var blocks: [ExportBlock]
    /// Where the book's chapters begin in `blocks`, in order: kept only when
    /// the writer asks for the book's structure
    /// (`ExportWalkOptions.keepsChapters`), and empty otherwise, as it is
    /// for a book with no chapter marker, which is one chapter. A writer
    /// that makes a file of each chapter (EPUB) reads it; every other
    /// writer ignores it.
    var chapterStarts: [ExportChapterStart]

    /// The deepest nesting of lists and block quotes the model holds: a list
    /// or quote met deeper in content.md, which is untrusted, is not opened,
    /// and its blocks join the container that holds it. Every writer can
    /// therefore recurse through the blocks without bound checks of its own.
    static let maximumNesting = 8

    /// A document of `blocks` for the book `book`, with `titleHeading`, and
    /// the chapters `chapterStarts` begin.
    init(
        book: ExportBookDetails,
        titleHeading: ExportHeading? = nil,
        blocks: [ExportBlock],
        chapterStarts: [ExportChapterStart] = []
    ) {
        self.book = book
        self.titleHeading = titleHeading
        self.blocks = blocks
        self.chapterStarts = chapterStarts
    }

    /// Every heading in `blocks`, at any depth, in reading order: the
    /// headings a contents list links. `titleHeading` is not among them.
    var headings: [ExportHeading] {
        ExportBlock.headings(in: blocks)
    }
}

// MARK: - Chapters and Pages

/// Where a chapter of an exported document begins (EPUB makes a file of each).
struct ExportChapterStart: Equatable, Sendable {
    /// The index in the document's `blocks` of the chapter's first block.
    var blockIndex: Int
    /// The chapter's title, as its marker in content.md gives it; empty for
    /// a chapter with none.
    var title: String
}

/// The start of a page of the book (PG01), kept when the writer asks for the
/// book's structure (`ExportWalkOptions.keepsPageMarkers`): a writer that has
/// a place for pages (EPUB) makes a target of each one.
struct ExportPageBreak: Equatable, Sendable {
    /// The page's label as content.md gives it: "12", "xii", "A-3".
    var label: String
    /// The page's id: "page_" and the page's number among the book's pages,
    /// unique in the document. Heading ids (`ExportHeadingIDs`) hold no
    /// underscore, so no page's id is a heading's.
    var id: String
}

/// A place the book's contents point at that is no heading (B3): a heading
/// annotation of content.md, which a converted book carries for a contents
/// entry that names a styled paragraph, an anchor, or a deeper entry of a
/// Kindle book. Kept with the pages (`ExportWalkOptions.keepsPageMarkers`):
/// the writer makes an empty target of it and a contents entry at its level.
struct ExportNavigationTarget: Equatable, Sendable {
    /// The entry's level, 1 to 6.
    var level: Int
    /// The entry's words.
    var text: String
    /// The target's id, unique among the document's heading ids and targets'
    /// (`ExportHeadingIDs`).
    var id: String
}

/// One entry of a book's contents as the model finds it: a heading, or a
/// target that is none (`ExportNavigationTarget`).
struct ExportContentsItem: Equatable, Sendable {
    /// The entry's level, 1 to 6.
    var level: Int
    /// The entry's words, as plain text.
    var text: String
    /// The id of the heading or the target.
    var id: String
    /// Whether it is a heading of the text, rather than a target.
    var isHeading: Bool
}

// MARK: - The Book

/// What an exported document says of its book besides its text: the title,
/// author, and language that writers put in their metadata.
struct ExportBookDetails: Equatable, Sendable {
    /// The book's title, as the library lists it.
    var title: String
    /// The book's author, or nil when the library does not know it.
    var author: String?
    /// The book's language as a language tag, such as "en" or "fr-CA", or
    /// nil when the book names none or names one that is not a tag
    /// (`languageTag(_:)`).
    var language: String?
    /// The book's identity in the library, which a writer that gives its
    /// file an identifier (EPUB) derives it from, so the same book exported
    /// twice has the same one; nil for details made without a book.
    var identifier: UUID?

    /// The details given, as they are: a test's, or a caller's that has
    /// already checked them.
    init(title: String, author: String? = nil, language: String? = nil, identifier: UUID? = nil) {
        self.title = title
        self.author = author
        self.language = language
        self.identifier = identifier
    }

    /// The details of `book` as the library holds them: its title, its
    /// author unless it is the placeholder for none (`Book.isUnknownAuthor`),
    /// and the language its metadata names when that is a language tag.
    init(_ book: Book) {
        self.init(
            title: book.title,
            author: Book.isUnknownAuthor(book.author) ? nil : book.author,
            language: book.epubLanguage.flatMap(Self.languageTag),
            identifier: book.id
        )
    }

    /// The longest language tag accepted, in characters.
    static let maximumLanguageTagLength = 35

    /// `text` as a language tag, or nil when it is not one: trimmed, with an
    /// underscore read as a hyphen ("en_US" is "en-US"), at most
    /// `maximumLanguageTagLength` characters, and well-formed by the grammar
    /// of BCP 47 (RFC 5646, section 2.1) for a language of two or three
    /// letters: up to three three-letter extended language subtags, a script
    /// of four letters, a region of two letters or three digits, variants,
    /// extensions (a singleton other than "x" and one or more subtags of two
    /// to eight letters or digits), and a private use part ("x" and one or
    /// more subtags of one to eight). A book's language comes from its file,
    /// which is untrusted, goes into attributes and metadata, and is checked
    /// by EPUB's validator, so a tag that is not well-formed is left out
    /// rather than escaped: HTML, EPUB, and PEF all say none.
    static func languageTag(_ text: String) -> String? {
        let tag = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
        guard !tag.isEmpty, tag.count <= maximumLanguageTagLength else { return nil }
        let subtags = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard let primary = subtags.first,
              (2...3).contains(primary.count),
              primary.allSatisfy({ $0.isASCII && $0.isLetter })
        else { return nil }

        /// Whether every character of `subtag` is an ASCII letter or digit.
        func isAlphanumeric(_ subtag: Substring) -> Bool {
            subtag.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
        /// Whether every character of `subtag` is an ASCII letter.
        func isLetters(_ subtag: Substring) -> Bool {
            subtag.allSatisfy { $0.isASCII && $0.isLetter }
        }
        var index = 1
        /// The subtag at `index`, when it has `lengths` characters and `kind`.
        func next(_ lengths: ClosedRange<Int>, _ kind: (Substring) -> Bool) -> Bool {
            guard index < subtags.count, lengths.contains(subtags[index].count), kind(subtags[index]) else {
                return false
            }
            index += 1
            return true
        }
        // Extended language subtags, then script and region.
        var extensions = 0
        while extensions < 3, next(3...3, isLetters) { extensions += 1 }
        _ = next(4...4, isLetters)
        if !next(2...2, isLetters) {
            _ = next(3...3) { $0.allSatisfy { $0.isASCII && $0.isNumber } }
        }
        // Variants: five to eight letters or digits, or a digit and three.
        while next(5...8, isAlphanumeric) || next(4...4, { isAlphanumeric($0) && $0.first?.isNumber == true }) {}
        // Extensions: a singleton other than "x" and at least one subtag.
        while index < subtags.count, subtags[index].count == 1, subtags[index].lowercased() != "x" {
            guard isAlphanumeric(subtags[index]) else { return nil }
            index += 1
            guard next(2...8, isAlphanumeric) else { return nil }
            while next(2...8, isAlphanumeric) {}
        }
        // Private use: "x" and at least one subtag.
        if index < subtags.count, subtags[index].lowercased() == "x" {
            index += 1
            guard next(1...8, isAlphanumeric) else { return nil }
            while next(1...8, isAlphanumeric) {}
        }
        return index == subtags.count ? tag : nil
    }
}

// MARK: - Blocks

/// One block of an exported document, in the order the book reads it.
enum ExportBlock: Equatable, Sendable {
    /// A heading.
    case heading(ExportHeading)
    /// A paragraph: its runs, in order, never none.
    case paragraph([ExportRun])
    /// An ordered or unordered list.
    case list(ExportList)
    /// A block quote: the blocks it quotes.
    case blockQuote([ExportBlock])
    /// A block of code: its lines exactly as content.md has them, joined by
    /// line feeds, with none at the end.
    case codeBlock(String)
    /// A thematic break between two parts of the text.
    case thematicBreak
    /// A table.
    case table(ExportTable)
    /// The start of a page, between two blocks (PG01): only in a document
    /// walked with `ExportWalkOptions.keepsPageMarkers`. A page that starts
    /// inside a paragraph is a run of it instead (`ExportRun.pageBreak`).
    case pageBreak(ExportPageBreak)
    /// A place the contents point at, between two blocks (B3): only in a
    /// document walked with `ExportWalkOptions.keepsPageMarkers`. One inside a
    /// paragraph is a run of it instead (`ExportRun.navigationTarget`).
    case navigationTarget(ExportNavigationTarget)

    /// The block's plain text, in reading order, as braille and any writer
    /// without styles read it:
    /// - a heading's or a paragraph's runs, joined;
    /// - a list's items' text (`ExportListItem.plainText`), each item's in
    ///   order with the lists inside it where they stand, apart by a line
    ///   feed, an item with no text left out;
    /// - a quote's blocks' text, apart by a blank line;
    /// - a code block's code, as it is;
    /// - nothing for a thematic break or the start of a page;
    /// - a table's rows, a row a line, its cells that have words apart by a
    ///   space, as the reader reads a row.
    ///
    /// No text is ever moved out of the order the book reads it in. A
    /// writer that sets a list inside an item apart, indenting it as braille
    /// and RTF do, walks the item's `blocks` instead.
    var plainText: String {
        switch self {
        case .heading(let heading):
            return heading.plainText
        case .paragraph(let runs):
            return runs.plainText
        case .list(let list):
            return list.items.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n")
        case .blockQuote(let blocks):
            return blocks.map(\.plainText).joined(separator: "\n\n")
        case .codeBlock(let code):
            return code
        case .thematicBreak, .pageBreak, .navigationTarget:
            return ""
        case .table(let table):
            return table.rows.map { row in
                row.filter { !$0.isEmpty }.joined(separator: " ")
            }.joined(separator: "\n")
        }
    }

    /// Every heading in `blocks`, at any depth (inside quotes and list items
    /// too), in reading order.
    static func headings(in blocks: [ExportBlock]) -> [ExportHeading] {
        blocks.flatMap { block -> [ExportHeading] in
            switch block {
            case .heading(let heading):
                return [heading]
            case .blockQuote(let quoted):
                return headings(in: quoted)
            case .list(let list):
                return list.items.flatMap { headings(in: $0.blocks) }
            case .paragraph, .codeBlock, .thematicBreak, .table, .pageBreak, .navigationTarget:
                return []
            }
        }
    }

    /// Every start of a page in `blocks`, at any depth (as a block, inside a
    /// paragraph or heading as a run, or in a table's cell), in reading order.
    static func pageBreaks(in blocks: [ExportBlock]) -> [ExportPageBreak] {
        blocks.flatMap { block -> [ExportPageBreak] in
            switch block {
            case .pageBreak(let page):
                return [page]
            case .heading(let heading):
                return heading.runs.compactMap(\.pageBreak)
            case .paragraph(let runs):
                return runs.compactMap(\.pageBreak)
            case .blockQuote(let quoted):
                return pageBreaks(in: quoted)
            case .list(let list):
                return list.items.flatMap { pageBreaks(in: $0.blocks) }
            case .table(let table):
                return table.cellPages.map(\.page)
            case .codeBlock, .thematicBreak, .navigationTarget:
                return []
            }
        }
    }

    /// Every entry of the contents in `blocks`, at any depth: headings, and
    /// the targets that are none (as blocks or inside a paragraph as runs),
    /// in reading order.
    static func contentsItems(in blocks: [ExportBlock]) -> [ExportContentsItem] {
        /// The entry of the contents that `target` makes.
        func item(_ target: ExportNavigationTarget) -> ExportContentsItem {
            ExportContentsItem(level: target.level, text: target.text, id: target.id, isHeading: false)
        }
        return blocks.flatMap { block -> [ExportContentsItem] in
            switch block {
            case .heading(let heading):
                return [ExportContentsItem(level: heading.level, text: heading.plainText, id: heading.id, isHeading: true)]
            case .navigationTarget(let target):
                return [item(target)]
            case .paragraph(let runs):
                return runs.compactMap(\.navigationTarget).map(item)
            case .blockQuote(let quoted):
                return contentsItems(in: quoted)
            case .list(let list):
                return list.items.flatMap { contentsItems(in: $0.blocks) }
            case .codeBlock, .thematicBreak, .table, .pageBreak:
                return []
            }
        }
    }
}

/// A heading of an exported document.
struct ExportHeading: Equatable, Sendable {
    /// Its level, 1 to 6, as content.md gives it.
    var level: Int
    /// Its runs, in order.
    var runs: [ExportRun]
    /// Its id: made from its text, unique among the ids of its document's
    /// headings, and a name XML accepts, of ASCII letters, digits, and
    /// hyphens, beginning with a letter (`ExportHeadingIDs`). Contents lists
    /// and links within the document point to it.
    var id: String

    /// The heading's plain text: its runs, joined.
    var plainText: String {
        runs.plainText
    }
}

/// An ordered or unordered list of an exported document.
struct ExportList: Equatable, Sendable {
    /// Whether the items are numbered.
    var isOrdered: Bool
    /// The number of the first item of an ordered list, as content.md gives
    /// it; 1 for an unordered list.
    var start: Int
    /// How many lists hold this one: 0 for a list in no other list's item, 1
    /// for a list inside an item of such a list, and so on. Quotes do not
    /// count, and it is never more than `ExportDocument.maximumNesting`.
    var depth: Int
    /// The items, in order.
    var items: [ExportListItem]
}

/// One item of a list.
struct ExportListItem: Equatable, Sendable {
    /// The item's blocks, in order: its paragraphs, and any list inside it.
    var blocks: [ExportBlock]

    /// The item's text in reading order: the plain text of each of its
    /// blocks, the lists inside it included where they stand, apart by a
    /// line feed, a block with no text left out. So the item "Alpha", a list
    /// inside it of "Xray" and "Yankee", and then "Bravo" reads "Alpha",
    /// "Xray", "Yankee", "Bravo", one a line. A writer that indents the list
    /// inside an item walks `blocks`, recursing into each `.list`.
    var plainText: String {
        blocks.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// A table of an exported document, its cells as plain text.
struct ExportTable: Equatable, Sendable {
    /// The rows, in order, each its cells' plain text: the header row first
    /// when there is one.
    var rows: [[String]]
    /// Whether the first row is the table's header row.
    var hasHeaderRow: Bool
    /// The pages that start inside a cell's words, in reading order (S3):
    /// only in a document walked with `ExportWalkOptions.keepsPageMarkers`.
    var cellPages: [ExportCellPage]

    /// A table of `rows`, with the pages that start in its cells.
    init(rows: [[String]], hasHeaderRow: Bool, cellPages: [ExportCellPage] = []) {
        self.rows = rows
        self.hasHeaderRow = hasHeaderRow
        self.cellPages = cellPages
    }
}

/// The start of a page inside a table cell's words.
struct ExportCellPage: Equatable, Sendable {
    /// The cell's row, an index into `ExportTable.rows`.
    var row: Int
    /// The cell's column.
    var column: Int
    /// How many Characters of the cell's text come before the page starts.
    var offset: Int
    /// The page.
    var page: ExportPageBreak
}

// MARK: - Runs

/// A stretch of a block's text in one style: plain, emphasis, strong, code,
/// part of a link, or a mix of them.
struct ExportRun: Equatable, Sendable {
    /// The run's text. A line feed in it is a hard line break of
    /// content.md, which writers turn into their own line break; a soft
    /// break is already a space.
    var text: String
    /// Whether the run is emphasis (Markdown's `*text*`).
    var isEmphasis: Bool
    /// Whether the run is strong (Markdown's `**text**`).
    var isStrong: Bool
    /// Whether the run is code (Markdown's `` `text` ``).
    var isCode: Bool
    /// The address the run links to, when it is part of a link whose
    /// address may be a link (`isAllowedLinkAddress(_:)`); nil otherwise. The
    /// text of any other link is plain text.
    var link: String?
    /// The start of a page at this place in the block's text, for a run that
    /// is only that: its text is empty. Only in a document walked with
    /// `ExportWalkOptions.keepsPageMarkers`. A run that starts a page is never
    /// joined with its neighbours.
    var pageBreak: ExportPageBreak?
    /// A place the contents point at, at this place in the block's text, for
    /// a run that is only that: its text is empty (`ExportNavigationTarget`).
    var navigationTarget: ExportNavigationTarget?

    /// Whether the run only marks a place in the text (a page start or a
    /// contents target) and holds no words.
    var isPlace: Bool {
        pageBreak != nil || navigationTarget != nil
    }

    /// A run of `text` in the style given; plain by default. `pageBreak`
    /// makes the run the start of a page, and `navigationTarget` a place the
    /// contents point at; `text` is then empty.
    init(
        _ text: String,
        isEmphasis: Bool = false,
        isStrong: Bool = false,
        isCode: Bool = false,
        link: String? = nil,
        pageBreak: ExportPageBreak? = nil,
        navigationTarget: ExportNavigationTarget? = nil
    ) {
        self.text = text
        self.isEmphasis = isEmphasis
        self.isStrong = isStrong
        self.isCode = isCode
        self.link = link
        self.pageBreak = pageBreak
        self.navigationTarget = navigationTarget
    }

    /// Whether `other` has this run's style and link, so the two, side by
    /// side, are one run. A run that marks a place has no such neighbour:
    /// two pages that follow each other are two pages.
    func hasSameStyle(as other: ExportRun) -> Bool {
        !isPlace && !other.isPlace
            && isEmphasis == other.isEmphasis && isStrong == other.isStrong && isCode == other.isCode
            && link == other.link
    }

    /// The schemes of the only addresses that become links: the web's and
    /// mail's. A `javascript:`, `file:`, or relative address never does.
    static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

    /// Whether `address` may be a link: it has a scheme, the letters before
    /// its first colon, that is one of `allowedLinkSchemes`, compared without
    /// case, white space at either end ignored.
    static func isAllowedLinkAddress(_ address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":") else { return false }
        return allowedLinkSchemes.contains(trimmed[..<colon].lowercased())
    }
}

/// Neighbouring runs that a writer writes together: the runs of one link,
/// or one run outside any link.
struct ExportRunGroup: Equatable, Sendable {
    /// The address the runs link to, one that may be a link
    /// (`ExportRun.isAllowedLinkAddress(_:)`); nil for a run outside any.
    var link: String?
    /// The runs, in order.
    var runs: [ExportRun]
}

extension Array where Element == ExportRun {
    /// The runs' text, joined: a heading's or a paragraph's plain text.
    var plainText: String {
        map(\.text).joined()
    }

    /// The runs in the groups writers write them in: neighbouring runs that
    /// link to the same address, when that address may be a link, make one
    /// group with that link (HTML writes it as one `<a>`, RTF as one field);
    /// every other run is a group of its own with no link, even one whose
    /// address may not be a link, which the writers trust no caller to have
    /// left out.
    var linkGroups: [ExportRunGroup] {
        var groups: [ExportRunGroup] = []
        for run in self {
            let link = run.link.flatMap { ExportRun.isAllowedLinkAddress($0) ? $0 : nil }
            if let link, let last = groups.last, last.link == link {
                groups[groups.count - 1].runs.append(run)
            } else {
                groups.append(ExportRunGroup(link: link, runs: [run]))
            }
        }
        return groups
    }
}
