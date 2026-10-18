import Foundation
import SwiftSoup

/// Manages cached Markdown content files (content.md) inside .tmb packages.
/// All non-audio book formats are converted to Markdown at import time and stored
/// in the .tmb bundle. The reader loads from this cache instead of re-parsing
/// the original file on every open.
enum MarkdownCacheService {

    /// Current semantic version of the extracted Markdown. Bump this when source
    /// extraction or the stored representation changes. Changes confined to
    /// reading-text/index derivation should bump BookContentIndex.currentVersion
    /// instead, so existing Markdown can be reindexed without source conversion.
    /// Older versions (or nil) regenerate through startup maintenance.
    /// Uses semantic versioning: major.minor.patch
    /// 3.0.5: EPUB page lists, landmarks, and hidden content no longer become
    /// headings or speech; a navigation annotation never enters a heading or
    /// begins a line (which hid that line's words); named anchors add no "[]";
    /// and a heading with a line break stays one heading.
    /// 3.0.6: plain-text books are stored as literal Markdown, so text that
    /// looks like Markdown or HTML is read as written and matches the direct
    /// parser; and DAISY 2.02 inline fragments are read in full, where caches
    /// written earlier kept only a fragment's first child element's text.
    /// 3.0.7: HTML text (HTML, EPUB, DAISY 2.02) is literal Markdown keeping block, row, and cell boundaries and code lines.
    static let currentCacheVersion: String = "3.0.7"

    /// Whether a cache stamped `stored` is older than `current`
    /// (`SemanticVersion.isOutdated(stored:current:)`), and so is extracted
    /// again.
    static func isCacheOutdated(stored: String?, current: String = currentCacheVersion) -> Bool {
        SemanticVersion.isOutdated(stored: stored, current: current)
    }

    /// The comment prefix used to separate chapters in the cached Markdown file.
    /// Each chapter begins with <!-- chapter: Title --> on its own line.
    private static let chapterMarkerPrefix = "<!-- chapter: "
    private static let chapterMarkerSuffix = " -->"

    /// The line that begins a chapter titled `title` in content.md, as
    /// `splitChapters(_:)` finds it. `title` must be one line.
    static func chapterMarker(title: String) -> String {
        "\(chapterMarkerPrefix)\(title)\(chapterMarkerSuffix)"
    }

    /// EPUB extraction already produces reading chapters to resolve heading
    /// coordinates. Keep those results until indexing instead of parsing the
    /// newly written Markdown a second time. Other formats supply Markdown only.
    /// `report` names the chapters the source could not supply; formats that
    /// do not report omissions leave it empty.
    private struct ExtractedCache {
        var markdown: String
        var chapters: [Chapter]? = nil
        var report = ExtractionReport()
    }

    /// What one successful cache generation produced: the book's reading
    /// content, indexed, and the report of chapters its source could not
    /// supply, kept beside the content so a reader can later say what is
    /// missing from it.
    struct GeneratedCache {
        var content: DocumentContent
        var report: ExtractionReport
        /// The book's saved places, moved from its old text to the one just
        /// written (T06's branch D); nil when nothing needed moving. The copy
        /// of the old text stays until the book's record holds them, so the
        /// caller commits them (`MovedPlaces.discardSnapshot()` after).
        var movedPlaces: MovedPlaces? = nil
    }

    // MARK: - Cache Generation

    /// Generate and write the content.md cache file for a book.
    /// Returns true if the cache was successfully created.
    @discardableResult
    static func generateCache(for book: Book) -> Bool {
        generateCacheContent(for: book) != nil
    }

    /// Generate the cache and its reading content together, with the book's
    /// places moved to the new text, treating any failure as no cache.
    /// Chapters the source could not supply are still recorded in the debug
    /// log (see `generateReportedCacheContent`).
    static func generateCacheContent(for book: Book) -> GeneratedCache? {
        do {
            return try generateReportedCacheContent(for: book)
        } catch {
            logGenerationFailure(error, for: book)
            return nil
        }
    }

    /// Generate the cache and its reading content together, with the report
    /// of chapters the source could not supply. Index construction reuses
    /// EPUB's prepared chapters and performs only one Markdown pass for other
    /// formats. No result escapes until the atomic cache write succeeds.
    ///
    /// Every generation path (import, startup maintenance, Redo Text
    /// Extraction, legacy migration, and the reader's regeneration) passes
    /// through here, so each one writes a report with omissions to the debug
    /// log as a single `<FORMAT>_INCOMPLETE_CONTENT: <title>: <message>` line.
    /// Only an import presents it to the reader (see `FileImportService`).
    ///
    /// Each one also fingerprints the source and the content.md it writes
    /// (TODO T07), so the index returned carries what a later load checks
    /// the cache against. The source is fingerprinted before extraction
    /// reads it: one replaced meanwhile then differs from its fingerprint
    /// next time, instead of being recorded as the one this cache came from.
    /// Each one also removes the reading text this Mac kept for the book
    /// (`ReadingTextCache`), which the old content.md gave.
    /// While the book's text is being edited in the user's editor (FR05),
    /// what the user saved in content.md is kept beside it before anything
    /// replaces it, and an edit not taken is never replaced at all
    /// (`BookTextEditSessions.permitTextRebuild(of:writing:)`).
    /// Each one also copies the old content.md aside with the book's places
    /// and moves them to the new text (T06's branch D, `PlaceSnapshot`),
    /// returned in `movedPlaces` for the caller to commit with the book's
    /// analysis; the copy stays until the record holds them.
    /// Every generation is storage work (TODO S04): a data-directory move
    /// waits for it, so its cache lands where it chose to write it, and one
    /// started during a move waits until the move has published. A book
    /// captured before a move is read and cached in the new data directory.
    /// - Returns: nil for a book with no text cache: an audio book, or one
    ///   without a package.
    /// - Throws: why no cache could be written. A cache written earlier is
    ///   left as it was, so a failed rebuild never empties a readable book.
    static func generateReportedCacheContent(for book: Book) throws -> GeneratedCache? {
        guard !book.format.isAudio, !book.tmbDirectoryName.isEmpty else { return nil }
        let boundary = StorageBoundary.shared
        return try boundary.perform(.textExtraction) { _ in
            try writeCache(for: boundary.rebasedToCurrent(book))
        }
    }

    /// The work of `generateReportedCacheContent(for:)` for a book with a
    /// package, whose paths are in the current data directory: extracts the
    /// source, writes content.md, and indexes and fingerprints the result.
    private static func writeCache(for book: Book) throws -> GeneratedCache {
        let cachePath = cacheURL(for: book)
        extractionObserver?(book)
        let fileURL = URL(fileURLWithPath: book.filePath)
        let sourceFingerprint = FileFingerprint(of: fileURL, hasher: .md5)

        let extracted: ExtractedCache
        do {
            extracted = try extractCache(from: fileURL, format: book.format)
        } catch EPUBParserError.noReadableChapters(let report) {
            // Nothing can be cached, but which chapters could not be read is
            // still worth recording before the failure is passed on.
            logIncompleteContent(report, of: book)
            throw EPUBParserError.noReadableChapters(report)
        }

        let parsed: DocumentContent
        if let chapters = extracted.chapters, !chapters.isEmpty {
            parsed = DocumentContent(
                title: documentTitle(of: chapters, bookTitle: book.title),
                author: book.author,
                chapters: chapters,
                contentIndex: BookContentIndex.build(fromChapters: chapters, format: book.format)
            )
        } else {
            // Preserve the cache reader's empty-document and chapter-marker
            // behavior as well as its title fallback for non-EPUB formats.
            let markdownContent = parseMultiChapterMarkdown(
                extracted.markdown, bookTitle: book.title, bookAuthor: book.author
            )
            parsed = DocumentContent(
                title: markdownContent.title, author: markdownContent.author, chapters: markdownContent.chapters,
                contentIndex: markdownContent.contentIndex.replacingFormat(book.format)
            )
        }
        // Write exactly the bytes that are digested, as UTF-8 without a
        // byte-order mark, which is how a String's UTF-8 write stores them.
        let bytes = Data(extracted.markdown.utf8)
        // A book being edited in the user's editor keeps what the user saved
        // there: copied aside before it is replaced, and an edit not taken
        // never replaced (FR05). Asked only now, after extraction, so a save
        // made while the source was read is not missed.
        let edits = BookTextEditSessions.shared
        try edits.permitTextRebuild(of: book, writing: bytes)
        // The book's places are copied aside with the old text, so they can
        // be moved to the new one; a failed write leaves no copy behind.
        let snapshot = keptPlaceSnapshot(of: book, replacing: cachePath, with: bytes)
        do {
            try bytes.write(to: cachePath, options: .atomic)
        } catch {
            snapshot?.discard()
            throw error
        }
        // The reading text this Mac kept for the book was read from the
        // content.md just replaced, so it goes now rather than at the next
        // open, which would find it no longer matches (PERF22).
        ReadingTextCache.shared.remove(bookID: book.id)
        var index = parsed.contentIndex
        index.textCacheFingerprint = fingerprint(source: sourceFingerprint, written: bytes, to: cachePath)
        // The user's next save is checked against the text just written.
        edits.textRebuilt(book, writing: bytes, fingerprint: index.textCacheFingerprint)
        let content = DocumentContent(
            title: parsed.title, author: parsed.author, chapters: parsed.chapters, contentIndex: index
        )
        logIncompleteContent(extracted.report, of: book)
        // The places move from the copied old text to the text just written.
        let movedPlaces = snapshot.flatMap { $0.movePlaces(to: content, at: Date()) }
        return GeneratedCache(content: content, report: extracted.report, movedPlaces: movedPlaces)
    }

    /// Copies the book's old content.md aside with its saved places, before
    /// a rebuild replaces it (T06's branch D), so the places can be moved to
    /// the new text. Nil, with nothing copied, unless all of these hold,
    /// checked cheapest first:
    /// - the book holds a place to move;
    /// - the book is not held by an Edit Text session, whose places that
    ///   session moves;
    /// - the old content.md exists and is on this Mac: one only in the cloud
    ///   is never downloaded for this;
    /// - the old content.md differs from `newBytes`: an unchanged text moves
    ///   nothing.
    /// A failure to read or copy the old text is logged once as
    /// `PLACES_NOT_KEPT` and gives nil; the rebuild goes on, and the places
    /// stay at their numbers, as before branch D.
    private static func keptPlaceSnapshot(of book: Book, replacing cacheURL: URL, with newBytes: Data) -> PlaceSnapshot? {
        guard book.holdsPlacesToMove,
              !BookTextEditSessions.shared.isEditing(book.id),
              FileManager.default.fileExists(atPath: cacheURL.path),
              !DatalessFiles.isDataless(cacheURL)
        else { return nil }
        do {
            // Read without asking the cloud to download anything.
            let oldBytes = try DatalessFiles.withoutDownloading { try Data(contentsOf: cacheURL) }
            guard oldBytes != newBytes else { return nil }
            let record = PlaceSnapshot.Record(
                bookID: book.id, title: book.title, author: book.author,
                places: book.relocatablePlaces, takenAt: Date()
            )
            return try PlaceSnapshot.keep(textAt: cacheURL, record: record)
        } catch {
            DiagnosticLog.event(.storage, "PLACES_NOT_KEPT: \(book.title): \(error.localizedDescription)")
            return nil
        }
    }

    /// The fingerprint of a cache just written as `bytes` to `cacheURL` from
    /// a source fingerprinted as `source` before extraction read it. Nil
    /// when either file could not be fingerprinted (the source could not be
    /// read twice, say), so the cache counts as one written before
    /// fingerprints and the next verified load fingerprints it.
    private static func fingerprint(source: FileFingerprint?, written bytes: Data, to cacheURL: URL) -> TextCacheFingerprint? {
        guard let source, let stamp = FileStamp(of: cacheURL) else { return nil }
        return TextCacheFingerprint(
            source: source,
            cache: FileFingerprint(stamp: stamp, digest: FingerprintHasher.md5.digestOfData(bytes))
        )
    }

    /// Generate a cache and advance the stored format version, with the
    /// statistics and fingerprints recorded alongside it, only after the
    /// cache file has been written successfully.
    @discardableResult
    static func generateCacheAndStampVersion(for book: inout Book) -> Bool {
        generateCacheAnalyzeAndStamp(for: &book) != nil
    }

    /// Variant that also computes the persisted navigation index while
    /// already executing on a background queue, treating any failure as no
    /// cache. Cache rebuilds use it: they log omissions but never alert.
    static func generateCacheAnalyzeAndStamp(for book: inout Book) -> BookContentIndex? {
        do {
            return try generateReportedCacheAnalyzeAndStamp(for: &book)?.content.contentIndex
        } catch {
            logGenerationFailure(error, for: book)
            return nil
        }
    }

    /// Import-time variant: write the cache, stamp `book` with the cache
    /// version and its index summary, and return the content with the report
    /// of chapters the source could not supply.
    /// - Returns: nil for a book with no text cache.
    /// - Throws: why no cache could be written; `book` is then unchanged.
    static func generateReportedCacheAnalyzeAndStamp(for book: inout Book) throws -> GeneratedCache? {
        guard let generated = try generateReportedCacheContent(for: book) else { return nil }
        book.cacheFormatVersion = currentCacheVersion
        book.applyContentIndexSummary(generated.content.contentIndex)
        return generated
    }

    // MARK: - Test Seam

    /// Told, with the book, once a cache generation has chosen where its
    /// content.md goes and before it reads the source, on the thread doing
    /// the work; nil in the app. Tests set it to hold a rebuild there.
    static var extractionObserver: (@Sendable (Book) -> Void)? {
        get {
            extractionObserverLock.lock()
            defer { extractionObserverLock.unlock() }
            return storedExtractionObserver
        }
        set {
            extractionObserverLock.lock()
            storedExtractionObserver = newValue
            extractionObserverLock.unlock()
        }
    }

    /// Guards `storedExtractionObserver`, which any cache generation reads.
    private static let extractionObserverLock = NSLock()
    // Access is confined by extractionObserverLock. `nonisolated(unsafe)`
    // documents that contract to Swift's global-state checker.
    nonisolated(unsafe) private static var storedExtractionObserver: (@Sendable (Book) -> Void)?

    // MARK: - Generation Diagnostics

    /// Print why no cache could be generated for `book`, for the callers that
    /// treat a failure as no cache.
    static func logGenerationFailure(_ error: Error, for book: Book) {
        print("Failed to generate content cache for \(book.title): \(error)")
    }

    /// Record a report that left chapters out as one line in the console and
    /// the debug log, tagged by format ("EPUB_INCOMPLETE_CONTENT"), in the
    /// form every format's damage reports take (see `PackageDamage.log`).
    /// A complete report records nothing.
    private static func logIncompleteContent(_ report: ExtractionReport, of book: Book) {
        guard !report.isComplete else { return }
        PackageDamage.log(
            IncompleteContent(title: book.title, report: report),
            tag: "\(book.format.rawValue.uppercased())_INCOMPLETE_CONTENT"
        )
    }

    /// A book whose extraction left chapters out, described for the log line
    /// that `PackageDamage.log` writes: the book's title, then the report.
    private struct IncompleteContent: LocalizedError {
        var title: String
        var report: ExtractionReport

        /// A line break in the title (or in a file name) becomes a space,
        /// so the entry stays on the one line that readers of the log expect.
        var errorDescription: String? {
            "\(title): \(report.message)".components(separatedBy: .newlines).joined(separator: " ")
        }
    }

    /// Where `book`'s content.md is: in its package, whether or not one has
    /// been written there yet.
    static func cacheURL(for book: Book) -> URL {
        TextMouthPaths.contentMarkdownPath(in: book.tmbDirectory)
    }

    /// Check whether a cached content.md exists for a book.
    static func cacheExists(for book: Book) -> Bool {
        guard !book.tmbDirectoryName.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: cacheURL(for: book).path)
    }

    /// Delete the cached content.md for a book (used before re-extraction).
    static func deleteCache(for book: Book) {
        guard !book.tmbDirectoryName.isEmpty else { return }
        try? FileManager.default.removeItem(at: cacheURL(for: book))
    }

    // MARK: - Cache Loading

    /// Load DocumentContent from the cached content.md file.
    /// Parses chapter markers and runs each chapter through the Markdown parser
    /// to produce plain text + headings for TTS consumption.
    static func loadFromCache(
        for book: Book,
        contentIndex: BookContentIndex? = nil
    ) throws -> DocumentContent {
        let url = cacheURL(for: book)
        let markdown = try cacheText(from: Data(contentsOf: url), at: url)

        return parseMultiChapterMarkdown(
            markdown,
            bookTitle: book.title,
            bookAuthor: book.author,
            contentIndex: contentIndex
        )
    }

    /// The text of a content.md whose bytes, read from `url`, are `bytes`.
    /// They are decoded as UTF-8 exactly as reading the file as a string
    /// decodes it, a leading byte-order mark dropped, so a load that needs
    /// the bytes for their digest reads the file once. Bytes that are not
    /// UTF-8 throw the error that reading the file as a string throws.
    static func cacheText(from bytes: Data, at url: URL) throws -> String {
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
        }
        return text
    }

    // MARK: - Format-Specific Extraction

    /// Extract Markdown content from a book file based on its format.
    /// EPUB: converts each chapter's HTML to Markdown with chapter separators.
    /// HTML: converts the HTML to Markdown, stripping duplicate navigation
    /// exactly as the direct parser (HTMLParser) does.
    /// Markdown: uses the file's text as-is.
    /// Plain text: literal Markdown with the plain-text headings as ATX headings.
    /// HTML, Markdown, and plain-text files are decoded by `TextFileDecoder`,
    /// as the direct parsers decode them (see `BookParser.parse(url:format:)`).
    /// RTF, RTFD, Word 97-2003, OpenDocument text, and Word 2003 XML are
    /// read by textutil in a child process (`TextutilDocumentReader`), which
    /// blocks while it runs: like DOCX's regeneration, this runs off the main
    /// thread, in the import queue, startup maintenance, Redo Text
    /// Extraction, and the reader's background load.
    private static func extractCache(from url: URL, format: BookFormat) throws -> ExtractedCache {
        let markdown: String
        switch format {
        case .epub:
            return try extractFromEPUB(url: url)
        case .html:
            let html = try TextFileDecoder.readText(at: url, format: format)
            markdown = try HTMLToMarkdownConverter.convert(html, stripDuplicateNavigation: true)
        case .markdown:
            // Already Markdown — use the decoded text as-is
            markdown = try TextFileDecoder.readText(at: url, format: format)
        case .txt:
            // The same line analysis as the direct parser, written as literal
            // Markdown, so a cached book reads exactly as
            // PlainTextParser.parse(text:) reads it.
            let text = try TextFileDecoder.readText(at: url, format: format)
            markdown = PlainTextParser.markdown(text: text)
        case .docx:
            markdown = try DOCXParser.extractMarkdown(from: url)
        case .rtf, .rtfd, .doc, .odt, .wordml:
            markdown = try TextutilDocumentReader.extractMarkdown(from: url, bookFormat: format)
        case .daisy:
            markdown = try DAISYParser.extractMarkdown(from: url)
        case .pdf:
            // The report says how each page was read and names any page
            // whose pictures OCR could not read, so an import warns and
            // keeps the original, and every generation logs those pages.
            let pdf = try PDFTextParser.extract(from: url)
            return ExtractedCache(markdown: pdf.markdown, report: pdf.report)
        case .audio:
            // Audio books don't get text caching
            markdown = ""
        }
        return ExtractedCache(markdown: markdown)
    }

    /// Use the direct EPUB parser's navigation recovery as the cache source.
    /// Chapter markers preserve boundaries; heading annotations preserve TOC
    /// labels and offsets without inserting any extra text into the book.
    private static func extractFromEPUB(url: URL) throws -> ExtractedCache {
        let book = try EPUBParser.prepareBook(url: url)
        let markdown = book.chapters.map { prepared in
            "\(chapterMarker(title: prepared.chapter.title))\n\(prepared.markdown)"
        }.joined(separator: "\n\n")
        return ExtractedCache(markdown: markdown, chapters: book.chapters.map(\.chapter), report: book.report)
    }

    // MARK: - Multi-Chapter Markdown Parsing

    /// Parse a cached Markdown file that may contain chapter markers into DocumentContent.
    /// Each chapter section is parsed through the Markdown parser for heading detection
    /// and plain text extraction.
    static func parseMultiChapterMarkdown(
        _ markdown: String,
        bookTitle: String,
        bookAuthor: String,
        contentIndex: BookContentIndex? = nil
    ) -> DocumentContent {
        let sections = splitChapters(markdown)

        if sections.isEmpty {
            // No chapter markers — treat entire file as single chapter
            let chapter = (try? MarkdownDocParser.parseChapter(markdown: markdown, title: bookTitle, includeNavigationHeadings: true))
                ?? Chapter(title: bookTitle, text: markdown, headings: [])
            return DocumentContent(
                title: documentTitle(of: [chapter], bookTitle: bookTitle),
                author: bookAuthor,
                chapters: [chapter],
                contentIndex: contentIndex
            )
        }

        var chapters: [Chapter] = []
        for section in sections {
            let parsedChapter = try? MarkdownDocParser.parseChapter(
                markdown: section.content,
                title: section.title,
                includeNavigationHeadings: true
            )
            if var ch = parsedChapter {
                // Use the chapter marker title, falling back to what the parser found
                if !section.title.isEmpty {
                    ch.title = section.title
                }

                // If this chapter has a title but the Markdown parser found no
                // headings, inject a synthetic level-1 heading at offset 0.
                // This ensures every titled chapter appears in the heading list.
                if ch.headings.isEmpty && !ch.title.isEmpty {
                    ch.headings = [Heading(level: 1, text: ch.title, characterOffset: 0)]
                }

                chapters.append(ch)
            }
        }

        return DocumentContent(
            title: documentTitle(of: chapters, bookTitle: bookTitle),
            author: bookAuthor,
            chapters: chapters,
            contentIndex: contentIndex
        )
    }

    /// The title of a book whose reading text is `chapters`: its first
    /// chapter's title, or `bookTitle` when that is empty or there is no
    /// chapter. Extraction, parsing content.md, and reading a book's cached
    /// reading text (`ReadingTextCache`) all name a book's content this way.
    static func documentTitle(of chapters: [Chapter], bookTitle: String) -> String {
        guard let first = chapters.first, !first.title.isEmpty else { return bookTitle }
        return first.title
    }

    /// Split cached Markdown into chapter sections based on chapter markers.
    /// Returns empty array if no chapter markers are found.
    ///
    /// A line ends at each line feed alone, as `components(separatedBy: "\n")`
    /// ends it, and a marker is a whole line that begins with the marker's
    /// prefix and ends with its suffix, compared Character by Character. A
    /// section's content is everything between its marker line and the next
    /// one (or the end), trimmed of whitespace and newlines; one with nothing
    /// left is dropped.
    ///
    /// The lines and sections are Substrings of `markdown`, found by looking
    /// for line feeds among its UTF-8 bytes, so each section is copied once,
    /// when it is trimmed, rather than every line being copied into an array
    /// and every section joined again (PERF22: four times as long, and 46 MB
    /// at its peak for a 20 MB book in one chapter, where this split needs
    /// no more than the sections it keeps).
    static func splitChapters(_ markdown: String) -> [(title: String, content: String)] {
        var sections: [(title: String, content: String)] = []
        // The title of the section being read, and where its content starts:
        // nil until the first marker.
        var current: (title: String, contentStart: String.Index)?

        /// Close the section being read at `end`, keeping it if it holds anything.
        func closeSection(at end: String.Index) {
            guard let current else { return }
            let content = markdown[current.contentStart..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                sections.append((title: current.title, content: content))
            }
        }

        let bytes = markdown.utf8
        var lineStart = markdown.startIndex
        while true {
            let lineEnd = bytes[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? markdown.endIndex
            // Sliced as scalars, so a line ending in the CR of a CR LF keeps
            // it, as the lines `components(separatedBy: "\n")` made kept it.
            let line = Substring(markdown.unicodeScalars[lineStart..<lineEnd])
            let nextLineStart = lineEnd < markdown.endIndex ? bytes.index(after: lineEnd) : lineEnd
            if line.hasPrefix(chapterMarkerPrefix) && line.hasSuffix(chapterMarkerSuffix) {
                closeSection(at: lineStart)
                current = (title: visibleChapterTitle(markerTitle(of: line)), contentStart: nextLineStart)
            }
            guard lineEnd < markdown.endIndex else { break }
            lineStart = nextLineStart
        }
        closeSection(at: markdown.endIndex)
        return sections
    }

    /// The title a chapter marker line names: what stands between the
    /// marker's prefix and suffix, counted in Characters. A line too short
    /// to hold both apart (`<!-- chapter: -->`, whose single space both
    /// share) names no title; reading one there once stopped the app.
    private static func markerTitle(of line: Substring) -> String {
        let titleLength = line.count - chapterMarkerPrefix.count - chapterMarkerSuffix.count
        guard titleLength > 0 else { return "" }
        return String(line.dropFirst(chapterMarkerPrefix.count).prefix(titleLength))
    }

    /// A chapter marker title is the chapter's first heading label. Caches
    /// written before format 3.0.5 could carry a navigation annotation inside
    /// that label; the title is shown to the reader (and becomes the chapter's
    /// heading when it has none), so complete HTML comments are dropped.
    private static func visibleChapterTitle(_ title: String) -> String {
        guard title.contains("<!--") else { return title }
        return title.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
