import Foundation

/// Reads a braille book (FMT20, FMT21) into the Markdown the library keeps
/// and into a parsed book, the way `PlainTextParser` does for a text file.
///
/// A braille book is a BRF, a BRL, or a PEF file. The reader puts the
/// pieces the braille types provide in a row: `BrailleFileReader` reads the
/// file's pages, `BraillePageAnalyzer` finds the headings and paragraphs,
/// and `BrailleTranslator` turns each block's cells into print through
/// liblouis in the braille helper, with the table the book was imported
/// with, and with the emphasis liblouis reads from the braille's
/// indicators. Both reading paths, the direct parse and the Markdown cache,
/// call `markdown(of:table:)`, so they read the same text.
enum BrailleBookReader {

    // MARK: - The kind of file

    /// The kind of braille file at `url`, by its extension: `.brl` for
    /// "brl", `.pef` for "pef" and for "xml" (a PEF is XML, and the import
    /// sends a loose .xml file here only when its root is a PEF's, see
    /// `XMLDocumentSniffer`), and `.brf` for "brf" and anything else. A
    /// braille book's file always has one of these extensions, so the last
    /// case is only a safe answer.
    static func kind(of url: URL) -> BrailleFileKind {
        switch url.pathExtension.lowercased() {
        case "brl": return .brl
        case "pef", "xml": return .pef
        default: return .brf
        }
    }

    // MARK: - The size

    /// The most bytes of braille TextMouth reads from one file: 32 MB, about
    /// six times a long novel's BRF. The translation holds a book's blocks,
    /// its pieces, and their translations at once, several times the file's
    /// size, so a file past this is refused before it is read (review finding
    /// E5). `BrailleFileError.fileTooLarge` says it in words.
    static let maximumFileBytes: Int64 = 32 * 1_048_576

    /// Refuses the file at `url` when it is larger than `maximumFileBytes`,
    /// by the size the file system gives, before anything is read. A
    /// symbolic link is sized by what it points to, as `DocumentByteLimit`
    /// sizes a file, so a link to a huge file is refused. A file that cannot
    /// be sized passes: reading it then throws the file system's own error.
    /// - Throws: `BrailleFileError.fileTooLarge`.
    private static func requireSizeWithinLimit(of url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let size = (try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard Int64(size) <= maximumFileBytes else { throw BrailleFileError.fileTooLarge }
    }

    // MARK: - Reading

    /// Throws `BrailleTranslator.Failure.changedTable` when the book was read
    /// with one of this Mac's tables under liblouis `recorded`, and the Mac's
    /// tables now have another version, or name none (review R2, decision
    /// 8): Apple installs liblouis's tables whole, recording their release,
    /// so a macOS update that changes a table changes the version, and
    /// reading the book with the changed rules could move its text under its
    /// places. The rebuild then fails by name and keeps the old content.md.
    /// A bundled table, and a book that recorded no version, pass.
    static func requireUnchangedTable(_ table: String, recordedVersion recorded: String?) throws {
        guard let recorded, BrailleTableSource.parse(table).source == .mac else { return }
        let now = BrailleTableCatalog.currentMacLiblouisVersion()
        guard now == recorded else { throw BrailleTranslator.Failure.changedTable(table, then: recorded, now: now) }
    }

    /// The Markdown of the braille book at `url`, translated to print with
    /// `table`: a heading as an ATX heading of its level, a paragraph or a
    /// list item as a paragraph, every one written as a Markdown literal so
    /// text that merely looks like Markdown is read as written.
    ///
    /// With `includesPages`, each braille page of a BRF or a PEF is a page
    /// marker where its first word is read (PG12; `PagedTranslation`), and
    /// the reading text is the same, word for word, as without them.
    ///
    /// Reading keeps the emphasis the braille carries (the user, October 21,
    /// 2026: "keeping all text formatting extractable from the braille
    /// converted to the intermediate format"): each block's print comes back
    /// from liblouis with the emphasis it read from the braille's
    /// indicators, which becomes Markdown's own (`markdownLine(of:)`).
    ///
    /// Keeping emphasis changes no word by itself. Markdown's delimiters are
    /// never text, and the helper's pass for EBAE's emphasis signs keeps
    /// every word liblouis reads alone, so a block reads, scalar for scalar,
    /// as it read before emphasis was kept, and so do the heading list's
    /// labels and offsets (`BrailleImportTests` pins it). Only the helper's
    /// pass for UEB's emphasis terminators changes words, where liblouis
    /// misread them (contracted UEB's "p" for "people"). A braille book
    /// imported before braille had pages is read again once at a launch
    /// (braille's line in `PageReaderVersions`): PG16's compare keeps a copy
    /// of its old text when the new reading differs from it, even by
    /// emphasis alone, and its saved places move with the text, as at every
    /// re-read (T06).
    /// - Parameters:
    ///   - url: The book's file.
    ///   - table: The stored value of an offered table: a bundled table's
    ///     bare file name, or "mac:" and one of this Mac's.
    ///   - recordedVersion: The liblouis version of this Mac's tables the
    ///     book was read with (`Book.brailleTableVersion`), which a rebuild
    ///     requires them to have still (review R2); nil for a first reading.
    ///   - includesPages: Whether page markers are written (PG12): true for
    ///     every cache the app writes, which `MarkdownCacheService` asks for
    ///     by name; false writes what the reader wrote before pages, byte for
    ///     byte, which PG09's launch re-read compares a book's content.md
    ///     with to find text changed by hand. A BRL has no pages either way.
    ///     It is false unless asked for, unlike the other readers' option:
    ///     the cache is the one reading that wants pages, and every other
    ///     caller, such as the direct parse, wants the text alone.
    /// - Throws: `BrailleFileError` for a file that is not braille or is
    ///   larger than `maximumFileBytes`,
    ///   `FileImportError.noTextToRead` when the book has no blocks or no
    ///   print text, `BrailleTranslator.Failure` for a table that is unknown,
    ///   has changed (`requireUnchangedTable(_:recordedVersion:)`), or a
    ///   translation that fails, and what the file's reading throws.
    static func markdown(
        of url: URL, table: String, recordedVersion: String? = nil, includesPages: Bool = false
    ) throws -> String {
        // A book whose Mac table changed is not read again (review R2).
        try requireUnchangedTable(table, recordedVersion: recordedVersion)
        // A file past the limit is refused before a byte of it is read.
        try requireSizeWithinLimit(of: url)
        // The file's pages, then the blocks the pages hold (a BRL file has
        // no layout to read, so its analysis is not "formatted").
        let fileKind = kind(of: url)
        let pages = try BrailleFileReader.read(url, as: fileKind)
        let structure = BraillePageAnalyzer.structure(of: pages)
        guard !structure.blocks.isEmpty else { throw FileImportError.noTextToRead }

        // What to translate: every block whole, and with pages, the pieces
        // that find where each page begins in its block's print, for a file
        // whose pages are pages (`marksItsPages(_:_:)`).
        let translation = PagedTranslation(
            blocks: structure.blocks,
            starts: includesPages && marksItsPages(pages, structure) ? pageStarts(of: structure) : []
        )

        // One run of the helper translates every text, in a working folder
        // beside the staged package during an import and a temporary one
        // otherwise, with the emphasis liblouis reads.
        let printed = try TextutilDocumentReader.withWorkingFolder(for: url) { folder in
            try BrailleTranslator.translate(translation.texts, table: table, direction: .brailleToPrint, workingIn: folder)
        }

        // Each block's print, trimmed at both ends, as Markdown, the blocks
        // apart by a blank line, as `PlainTextParser.markdown(text:)` keeps
        // its blocks, with each page's marker; a block with no print left is
        // dropped.
        guard let text = translation.markdown(from: printed) else { throw FileImportError.noTextToRead }
        return text
    }

    /// Whether the pages of a braille file, read as `file` and laid out as
    /// `structure`, are pages an embosser counts, so that they become the
    /// book's pages (PG12, the review of October 24): a PEF's page elements,
    /// a BRF's form feeds, or, in a BRF with no form feed, braille page
    /// numbers ending more than half of the pages it was cut into.
    ///
    /// A BRF with no form feed is cut every 25 rows only so that its layout
    /// can be read (`BrailleFileReader.linesPerUnmarkedPage`). Laid out at
    /// another length, or not in pages at all, those pieces are no pages,
    /// and naming them would invent pages: a file of 27 lines a page would
    /// read "Page 3" where its third page has not begun. Its numbers tell:
    /// when the cut matches its layout, nearly every piece ends in its
    /// braille page number, and when it does not, few or none do. A BRL has
    /// no pages.
    static func marksItsPages(_ file: BrailleFilePages, _ structure: BrailleStructure) -> Bool {
        guard file.kind != .brl else { return false }
        if file.marksItsPages { return true }
        let numbered = structure.pages.filter { $0.braillePageNumber != nil }.count
        return numbered * 2 > structure.pages.count
    }

    /// One block's print, trimmed, as one line of Markdown: every character
    /// a literal, so text that merely looks like Markdown (an asterisk, an
    /// underscore, a backslash) is read as written, and its emphasis as
    /// Markdown's (`BrailleEmphasis.markdownStyle`), with delimiters CommonMark
    /// always pairs, so none is ever read aloud (`MarkdownEmphasis`).
    static func markdownLine(of text: EmphasizedText) -> String {
        MarkdownEmphasis.markdown(text.text, styles: text.emphasis.map(\.markdownStyle))
    }

    /// The parsed content of the braille book at `url`, from the Markdown
    /// `markdown(of:table:)` reads, so the direct reading and the cache's
    /// read the same text. This parse reads no page markers (its Markdown
    /// goes to the plain `MarkdownDocParser.parse`), so none are written,
    /// as DOCX's direct parse writes none (PG07, PG12).
    /// - Parameters:
    ///   - title: The book's title.
    ///   - table: The table the book was imported with.
    static func parse(url: URL, title: String, table: String, recordedVersion: String? = nil) throws -> DocumentContent {
        let text = try markdown(of: url, table: table, recordedVersion: recordedVersion, includesPages: false)
        return try MarkdownDocParser.parse(markdown: text, title: title)
    }
}
