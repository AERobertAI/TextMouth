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
/// A MOBI book has no print pages (an APNX file beside it would hold them,
/// which is a later item), so none are written.
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
    /// - Parameter fallbackTitle: The title for a book that names none; its
    ///   file's name when nil.
    /// - Throws: `MOBIError` for a file that is not a Kindle book TextMouth
    ///   reads (copy-protected, KF8, or compressed in a way not read yet, or
    ///   damaged), `DocumentTooLargeError` for one past `DocumentByteLimit`,
    ///   and `FileImportError.noTextToRead` for one with no text.
    static func prepareBook(url: URL, fallbackTitle: String? = nil) throws -> PreparedBook {
        let fileBytes = try bytes(of: url)
        // Kindle's apps name KFX books .azw: the bytes decide, not the name.
        if KFXSignature.isKFXOrProtected(fileBytes) {
            // A book of the MOBI format has no print pages, so none are written.
            return try KFXParser.prepareBook(
                bytes: fileBytes,
                fallbackTitle: fallbackTitle ?? url.deletingPathExtension().lastPathComponent,
                includesPages: false, near: url
            )
        }
        let book = try MOBIBook(bytes: fileBytes)
        return try preparedBook(
            sections: book.sections, metadata: book.metadata,
            fallbackTitle: fallbackTitle ?? url.deletingPathExtension().lastPathComponent)
    }

    /// Makes a book of the HTML `sections` a Kindle book was cut into: each
    /// section that holds words is a chapter. MOBI and KFX books both end
    /// here, so they are read into chapters the same way.
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
        for section in sections {
            if let chapter = try preparedChapter(of: section, number: chapters.count + 1, includesPages: includesPages) {
                chapters.append(chapter)
            }
        }
        guard !chapters.isEmpty else { throw FileImportError.noTextToRead }
        return PreparedBook(
            title: metadata.title.isEmpty ? fallbackTitle : metadata.title,
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
        let fileBytes = try bytes(of: url)
        // An .azw file holding KFX names itself as KFX does.
        if KFXSignature.isKFXOrProtected(fileBytes) { return try KFXParser.readMetadata(bytes: fileBytes, near: url) }
        return try MOBIBook.metadata(in: fileBytes)
    }

    /// The bytes of the file at `url`, within `DocumentByteLimit`.
    private static func bytes(of url: URL) throws -> [UInt8] {
        [UInt8](try DocumentByteLimit.contents(of: url))
    }

    // MARK: Chapters

    /// Makes a chapter of `section`, or nil when it holds no words.
    /// `number` is the chapter's place among those that hold text, which
    /// titles a chapter nothing else titles.
    private static func preparedChapter(
        of section: MOBIBook.Section, number: Int, includesPages: Bool
    ) throws -> EPUBParser.PreparedChapter? {
        // The section's HTML in Markdown, its contents entries kept as
        // heading annotations at their anchors. No page markers are written.
        var markdown = try HTMLToMarkdownConverter.convert(
            section.html, stripDuplicateNavigation: false,
            headingTargets: section.headingTargets, pages: section.pages, includesPages: includesPages
        )
        let fallbackTitle = section.title ?? untitledChapter(number: number)
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
