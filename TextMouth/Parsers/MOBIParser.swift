import Foundation

/// Reads a Kindle (MOBI) book into the reading text: TextMouth's own reader
/// (FMT42), the same on the Mac and on iOS, with no helper program.
///
/// `MOBIBook` opens the file and cuts its text into HTML sections; this hands
/// each section to the shared `HTMLToMarkdownConverter` and makes chapters of
/// them, as `EPUBParser` does of a book's documents: the contents' entries
/// become the chapters and, below them, headings kept as annotations
/// (`MarkdownHeadingAnnotation`) that add no words to what is read aloud.
///
/// A MOBI 6 book has no print pages (an APNX file beside it would hold them,
/// which is a later item), so none are written. A KF8 book (FMT48) is made of
/// the XHTML documents of an EPUB, and a page-break element in them is a page
/// as it is in the EPUB (`KF8Book`). An `.azw` file that holds a KFX book is
/// read by `KFXParser` from here, with no pages: the same book named `.kfx`
/// has them (`KFXSetTests` pins this).
enum MOBIParser {

    /// A book read in its chapters: its names and the chapters that hold
    /// text, each with the Markdown the cache writes.
    struct PreparedBook {
        var title: String
        var author: String
        var language: String?
        var chapters: [EPUBParser.PreparedChapter]
    }

    /// How a section that no contents entry titles, and that has no heading
    /// of its own, is titled: "Chapter 3" for the third chapter that holds text.
    private static func untitledChapter(number: Int) -> String { "Chapter \(number)" }

    // MARK: Reading

    /// Reads the Kindle book at `url` for direct reading.
    /// - Throws: what `prepareBook(url:)` throws.
    static func parse(url: URL) throws -> DocumentContent {
        let book = try prepareBook(url: url)
        return DocumentContent(
            title: book.title,
            author: book.author,
            chapters: book.chapters.map(\.chapter)
        )
    }

    /// Opens the Kindle book at `url` and prepares each of its sections that
    /// holds text as a chapter. The direct reader and the Markdown cache both
    /// read a MOBI book here, so they hear the same words.
    /// - Parameters:
    ///   - fallbackTitle: The title for a book that names none; its file's
    ///     name when nil.
    ///   - includesPages: Whether the print pages a KF8 book's page-break
    ///     elements name are written; a MOBI 6 book has none, and a KFX book
    ///     is read by `KFXParser`.
    ///   - hybrid: Which half of a hybrid file is read; the KF8 half by default. The upgrade of
    ///     a library's books asks for the MOBI 6 half to find the text an older TextMouth stored.
    /// - Throws: `MOBIError` for a file that is not a Kindle book TextMouth
    ///   reads (copy-protected, compressed in a way not read, or damaged), `DocumentTooLargeError` for one past `DocumentByteLimit`,
    ///   `FileImportError.noTextToRead` for one with no text, and
    ///   `ImportCancelled` when the import running it was cancelled.
    static func prepareBook(
        url: URL, fallbackTitle: String? = nil, includesPages: Bool = true,
        hybrid: MOBIBook.HybridChoice = MOBIBook.hybridChoice
    ) throws -> PreparedBook {
        try refuseProtectedKFX(at: url)
        let file = try mappedContents(of: url)
        // Kindle's apps name KFX books .azw: the bytes decide, not the name.
        if KFXSignature.isKFXOrProtected(Array(file.prefix(Self.signaturePrefixLength))) {
            // A KFX book is read whole, within the limit for one document.
            try DocumentByteLimit.check(byteCount: Int64(file.count))
            return try KFXParser.prepareBook(
                bytes: [UInt8](file),
                fallbackTitle: fallbackTitle ?? url.deletingPathExtension().lastPathComponent,
                includesPages: false, near: url
            )
        }
        let book = try MOBIBook(data: file, hybrid: hybrid)
        return try preparedBook(
            sections: book.sections, metadata: book.metadata,
            fallbackTitle: fallbackTitle ?? url.deletingPathExtension().lastPathComponent,
            includesPages: includesPages && book.includesPages)
    }

    /// Makes a book of the HTML `sections` a Kindle book was cut into: each
    /// section that holds words is a chapter, and a section that continues
    /// the chapter before it (a KF8 document calibre cut into pieces) is read
    /// in that chapter. MOBI and KFX books both end here, so they are read
    /// into chapters the same way.
    /// - Parameters:
    ///   - metadata: What the book says of itself; a title it lacks becomes
    ///     `fallbackTitle`, an author it lacks the unknown author.
    ///   - includesPages: Whether the pages a section names are written as
    ///     page markers; a MOBI book names none.
    /// - Throws: `FileImportError.noTextToRead` for a book with no words.
    static func preparedBook(
        sections: [MOBIBook.Section], metadata: MOBIBook.Metadata, fallbackTitle: String,
        includesPages: Bool = false
    ) throws -> PreparedBook {
        var chapters: [EPUBParser.PreparedChapter] = []
        let bookTitle = metadata.title.isEmpty ? fallbackTitle : metadata.title
        // The sections of each chapter: a section, and the ones after it that continue it.
        var groups: [[MOBIBook.Section]] = []
        for section in sections {
            if section.continuesPrevious, !groups.isEmpty {
                groups[groups.count - 1].append(section)
            } else {
                groups.append([section])
            }
        }
        for group in groups {
            // Cancel during a very large book is heard between its chapters.
            try ImportCancellation.throwIfCancelled()
            if let chapter = try preparedChapter(
                of: group, number: group[0].documentNumber ?? chapters.count + 1, bookTitle: bookTitle,
                includesPages: includesPages) {
                chapters.append(chapter)
            }
        }
        guard !chapters.isEmpty else { throw FileImportError.noTextToRead }
        return PreparedBook(
            title: bookTitle,
            author: metadata.author.isEmpty ? Book.unknownAuthor : metadata.author,
            language: metadata.language,
            chapters: chapters
        )
    }

    /// What the Kindle book at `url` says about itself, without reading its
    /// text.
    /// - Throws: `MOBIError.notAKindleBook` and `.damaged` for a file whose
    ///   headers do not read; the file system's error for one that cannot be read.
    static func readMetadata(url: URL) throws -> MOBIBook.Metadata {
        try refuseProtectedKFX(at: url)
        let file = try mappedContents(of: url)
        // An .azw file holding KFX names itself as KFX does.
        if KFXSignature.isKFXOrProtected(Array(file.prefix(Self.signaturePrefixLength))) {
            try DocumentByteLimit.check(byteCount: Int64(file.count))
            return try KFXParser.readMetadata(bytes: [UInt8](file), near: url)
        }
        return try MOBIBook.metadata(in: file)
    }

    /// Refuses a file that starts with the mark of a protected KFX container
    /// (Kindle's apps name such a book .azw) from its first eight bytes, before
    /// its size is asked: a protected book is told so, however large.
    /// - Throws: `MOBIError.copyProtected`.
    private static func refuseProtectedKFX(at url: URL) throws {
        if (try? KFXSignature.kind(ofFileAt: url)) == .protected { throw MOBIError.copyProtected }
    }

    /// The most bytes of a Kindle file that are read: 512 MB. A kindlegen
    /// hybrid carries its pictures twice (111 MB for a book of 1 MB of
    /// words), so the 64 MB `DocumentByteLimit` is held to the book's
    /// *text* (`MOBIText.bytes` checks the length the header declares before
    /// it decompresses anything), not to the file. The header's own limits
    /// (record counts, offsets, lengths) stand as they were.
    static let maximumFileBytes: Int64 = 512 * 1024 * 1024

    /// How many bytes at the start of a file tell a KFX container from a Palm database
    /// (its type and creator lie at 0x3C, eight bytes).
    private static let signaturePrefixLength = 0x3C + 8

    /// The file at `url`, memory-mapped, within `maximumFileBytes`: only the
    /// records that are read are paged in, so a file of a hundred megabytes
    /// costs no allocation of that size.
    /// - Throws: `FileImportError.noTextToRead` for an empty file,
    ///   `DocumentTooLargeError` for one past the limit, and the file
    ///   system's error for one that cannot be read.
    private static func mappedContents(of url: URL) throws -> Data {
        // A link is sized by what it points to, not by its own few bytes.
        let target = url.resolvingSymlinksInPath()
        let size = Int64(try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard size > 0 else { throw FileImportError.noTextToRead }
        let limit = max(DocumentByteLimit.current, maximumFileBytes)
        guard size <= limit else { throw DocumentTooLargeError(limit: limit) }
        let data = try Data(contentsOf: target, options: .alwaysMapped)
        // A file that grew since it was sized.
        guard Int64(data.count) <= limit else { throw DocumentTooLargeError(limit: limit) }
        return data
    }

    // MARK: Chapters

    /// Makes a chapter of the sections in `group`, the first and the pieces
    /// after it that continue it, or nil when they hold no words. `number` is
    /// the chapter's place among the documents (KF8) or among the chapters
    /// that hold text (MOBI 6), which titles a chapter nothing else titles (or
    /// `bookTitle`, for a section that asks for it).
    private static func preparedChapter(
        of group: [MOBIBook.Section], number: Int, bookTitle: String, includesPages: Bool
    ) throws -> EPUBParser.PreparedChapter? {
        let section = group[0]
        // Each section's HTML in Markdown, its contents entries kept as
        // heading annotations at their anchors (and the pages a KFX book names).
        var markdown = ""
        for piece in group {
            let converted = try HTMLToMarkdownConverter.convert(
                piece.html, stripDuplicateNavigation: piece.stripsDuplicateNavigation,
                headingTargets: piece.headingTargets, pages: piece.pages, includesPages: includesPages
            )
            if markdown.isEmpty {
                markdown = converted
            } else if converted.isEmpty {
                continue
            } else if piece.joinsParagraph {
                // The cut fell inside a paragraph: its two halves are one paragraph.
                markdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines) + " "
                    + converted.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                markdown += "\n\n" + converted
            }
        }
        let fallbackTitle = section.title ?? (section.untitledTakesBookTitle ? bookTitle : untitledChapter(number: number))
        var chapter = try MarkdownDocParser.parseChapter(
            markdown: markdown, title: fallbackTitle, includeNavigationHeadings: true
        )
        guard !chapter.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        if chapter.headings.first?.characterOffset != 0 {
            // A chapter that starts with no heading (or only a later one)
            // still needs a start entry. It is kept as metadata, never as
            // text, so nothing is added to what is read aloud.
            let heading = MarkdownHeadingAnnotation(level: 1, text: fallbackTitle)
            markdown = heading.markdown + "\n\n" + markdown
            chapter.headings.insert(Heading(level: heading.level, text: heading.text), at: 0)
        }
        chapter.title = chapter.headings.first?.text ?? fallbackTitle
        return EPUBParser.PreparedChapter(markdown: markdown, chapter: chapter)
    }
}
