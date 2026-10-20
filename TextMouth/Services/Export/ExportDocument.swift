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

    /// The deepest nesting of lists and block quotes the model holds: a list
    /// or quote met deeper in content.md, which is untrusted, is not opened,
    /// and its blocks join the container that holds it. Every writer can
    /// therefore recurse through the blocks without bound checks of its own.
    static let maximumNesting = 8

    /// A document of `blocks` for the book `book`, with `titleHeading`.
    init(book: ExportBookDetails, titleHeading: ExportHeading? = nil, blocks: [ExportBlock]) {
        self.book = book
        self.titleHeading = titleHeading
        self.blocks = blocks
    }

    /// Every heading in `blocks`, at any depth, in reading order: the
    /// headings a contents list links. `titleHeading` is not among them.
    var headings: [ExportHeading] {
        ExportBlock.headings(in: blocks)
    }
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

    /// The details given, as they are: a test's, or a caller's that has
    /// already checked them.
    init(title: String, author: String? = nil, language: String? = nil) {
        self.title = title
        self.author = author
        self.language = language
    }

    /// The details of `book` as the library holds them: its title, its
    /// author unless it is the placeholder for none (`Book.isUnknownAuthor`),
    /// and the language its metadata names when that is a language tag.
    init(_ book: Book) {
        self.init(
            title: book.title,
            author: Book.isUnknownAuthor(book.author) ? nil : book.author,
            language: book.epubLanguage.flatMap(Self.languageTag)
        )
    }

    /// The longest language tag accepted, in characters.
    static let maximumLanguageTagLength = 35

    /// `text` as a language tag, or nil when it is not one: trimmed, with an
    /// underscore read as a hyphen ("en_US" is "en-US"), a primary subtag of
    /// two or three ASCII letters, then any number of subtags of one to eight
    /// ASCII letters or digits, each after a hyphen, and at most
    /// `maximumLanguageTagLength` characters in all. A book's language comes
    /// from its file, which is untrusted, and goes into attributes and
    /// metadata, so anything else is left out rather than escaped.
    static func languageTag(_ text: String) -> String? {
        let tag = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
        guard !tag.isEmpty, tag.count <= maximumLanguageTagLength else { return nil }
        let subtags = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard let primary = subtags.first,
              (2...3).contains(primary.count),
              primary.allSatisfy({ $0.isASCII && $0.isLetter })
        else { return nil }
        let isSubtag = { (subtag: Substring) in
            (1...8).contains(subtag.count) && subtag.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
        return subtags.dropFirst().allSatisfy(isSubtag) ? tag : nil
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

    /// The block's plain text, as braille and any writer without styles
    /// read it:
    /// - a heading's or a paragraph's runs, joined;
    /// - a list's items' own words (`ExportListItem.plainText`), an item a
    ///   line, each followed by the lists inside it, if any, and no line for
    ///   an item with no words of its own;
    /// - a quote's blocks' text, apart by a blank line;
    /// - a code block's code, as it is;
    /// - nothing for a thematic break;
    /// - a table's rows, a row a line, its cells that have words apart by a
    ///   space, as the reader reads a row.
    var plainText: String {
        switch self {
        case .heading(let heading):
            return heading.plainText
        case .paragraph(let runs):
            return runs.plainText
        case .list(let list):
            return list.items.flatMap { item in
                [item.plainText] + item.blocks.compactMap { block in
                    if case .list = block { return block.plainText }
                    return nil
                }
            }.filter { !$0.isEmpty }.joined(separator: "\n")
        case .blockQuote(let blocks):
            return blocks.map(\.plainText).joined(separator: "\n\n")
        case .codeBlock(let code):
            return code
        case .thematicBreak:
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
            case .paragraph, .codeBlock, .thematicBreak, .table:
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

    /// The item's own words: the plain text of its blocks other than the
    /// lists inside it, apart by a line feed. A list inside the item is a
    /// list of its own, with its own items.
    var plainText: String {
        blocks.compactMap { block -> String? in
            if case .list = block { return nil }
            return block.plainText
        }.joined(separator: "\n")
    }
}

/// A table of an exported document, its cells as plain text.
struct ExportTable: Equatable, Sendable {
    /// The rows, in order, each its cells' plain text: the header row first
    /// when there is one.
    var rows: [[String]]
    /// Whether the first row is the table's header row.
    var hasHeaderRow: Bool
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

    /// A run of `text` in the style given; plain by default.
    init(_ text: String, isEmphasis: Bool = false, isStrong: Bool = false, isCode: Bool = false, link: String? = nil) {
        self.text = text
        self.isEmphasis = isEmphasis
        self.isStrong = isStrong
        self.isCode = isCode
        self.link = link
    }

    /// Whether `other` has this run's style and link, so the two, side by
    /// side, are one run.
    func hasSameStyle(as other: ExportRun) -> Bool {
        isEmphasis == other.isEmphasis && isStrong == other.isStrong && isCode == other.isCode && link == other.link
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

extension Array where Element == ExportRun {
    /// The runs' text, joined: a heading's or a paragraph's plain text.
    var plainText: String {
        map(\.text).joined()
    }
}
