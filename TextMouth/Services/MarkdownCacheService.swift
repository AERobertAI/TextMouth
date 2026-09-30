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

    /// Compare two semantic version strings (e.g. "2.0.0" > "1.0.0").
    /// Returns true if `stored` is older than `current`.
    static func isCacheOutdated(stored: String?, current: String = currentCacheVersion) -> Bool {
        guard let stored = stored, !stored.isEmpty else { return true }
        let storedParts = stored.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }
        // Pad to 3 components for consistent comparison
        let s = storedParts + Array(repeating: 0, count: max(0, 3 - storedParts.count))
        let c = currentParts + Array(repeating: 0, count: max(0, 3 - currentParts.count))
        for i in 0..<3 {
            if s[i] < c[i] { return true }
            if s[i] > c[i] { return false }
        }
        return false // equal
    }

    /// The comment prefix used to separate chapters in the cached Markdown file.
    /// Each chapter begins with <!-- chapter: Title --> on its own line.
    private static let chapterMarkerPrefix = "<!-- chapter: "
    private static let chapterMarkerSuffix = " -->"

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
    }

    // MARK: - Cache Generation

    /// Generate and write the content.md cache file for a book.
    /// Returns true if the cache was successfully created.
    @discardableResult
    static func generateCache(for book: Book) -> Bool {
        generateCacheContent(for: book) != nil
    }

    /// Generate the cache and its reading content together, treating any
    /// failure as no cache. Chapters the source could not supply are still
    /// recorded in the debug log (see `generateReportedCacheContent`).
    static func generateCacheContent(for book: Book) -> DocumentContent? {
        do {
            return try generateReportedCacheContent(for: book)?.content
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
    /// - Returns: nil for a book with no text cache: an audio book, or one
    ///   without a package.
    /// - Throws: why no cache could be written. A cache written earlier is
    ///   left as it was, so a failed rebuild never empties a readable book.
    static func generateReportedCacheContent(for book: Book) throws -> GeneratedCache? {
        guard !book.format.isAudio, !book.tmbDirectoryName.isEmpty else { return nil }

        let tmbDir = book.tmbDirectory
        let cachePath = TextMouthPaths.contentMarkdownPath(in: tmbDir)
        let fileURL = URL(fileURLWithPath: book.filePath)

        let extracted: ExtractedCache
        do {
            extracted = try extractCache(from: fileURL, format: book.format)
        } catch EPUBParserError.noReadableChapters(let report) {
            // Nothing can be cached, but which chapters could not be read is
            // still worth recording before the failure is passed on.
            logIncompleteContent(report, of: book)
            throw EPUBParserError.noReadableChapters(report)
        }

        let content: DocumentContent
        if let chapters = extracted.chapters, !chapters.isEmpty {
            content = DocumentContent(
                title: chapters.first?.title.isEmpty == false ? chapters[0].title : book.title,
                author: book.author,
                chapters: chapters,
                contentIndex: BookContentIndex.build(fromChapters: chapters, format: book.format)
            )
        } else {
            // Preserve the cache reader's empty-document and chapter-marker
            // behavior as well as its title fallback for non-EPUB formats.
            let parsed = parseMultiChapterMarkdown(
                extracted.markdown, bookTitle: book.title, bookAuthor: book.author
            )
            content = DocumentContent(
                title: parsed.title, author: parsed.author, chapters: parsed.chapters,
                contentIndex: parsed.contentIndex.replacingFormat(book.format)
            )
        }
        try extracted.markdown.write(to: cachePath, atomically: true, encoding: .utf8)
        logIncompleteContent(extracted.report, of: book)
        return GeneratedCache(content: content, report: extracted.report)
    }

    /// Generate a cache and advance the stored format version only after the
    /// cache file has been written successfully.
    @discardableResult
    static func generateCacheAndStampVersion(for book: inout Book) -> Bool {
        guard generateCache(for: book) else { return false }
        book.cacheFormatVersion = currentCacheVersion
        return true
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

    /// Check whether a cached content.md exists for a book.
    static func cacheExists(for book: Book) -> Bool {
        guard !book.tmbDirectoryName.isEmpty else { return false }
        let tmbDir = book.tmbDirectory
        let cachePath = TextMouthPaths.contentMarkdownPath(in: tmbDir)
        return FileManager.default.fileExists(atPath: cachePath.path)
    }

    /// Delete the cached content.md for a book (used before re-extraction).
    static func deleteCache(for book: Book) {
        guard !book.tmbDirectoryName.isEmpty else { return }
        let tmbDir = book.tmbDirectory
        let cachePath = TextMouthPaths.contentMarkdownPath(in: tmbDir)
        try? FileManager.default.removeItem(at: cachePath)
    }

    // MARK: - Cache Loading

    /// Load DocumentContent from the cached content.md file.
    /// Parses chapter markers and runs each chapter through the Markdown parser
    /// to produce plain text + headings for TTS consumption.
    static func loadFromCache(
        for book: Book,
        contentIndex: BookContentIndex? = nil
    ) throws -> DocumentContent {
        let tmbDir = book.tmbDirectory
        let cachePath = TextMouthPaths.contentMarkdownPath(in: tmbDir)
        let markdown = try String(contentsOf: cachePath, encoding: .utf8)

        return parseMultiChapterMarkdown(
            markdown,
            bookTitle: book.title,
            bookAuthor: book.author,
            contentIndex: contentIndex
        )
    }

    // MARK: - Format-Specific Extraction

    /// Extract Markdown content from a book file based on its format.
    /// EPUB: converts each chapter's HTML to Markdown with chapter separators.
    /// HTML: converts the HTML to Markdown, stripping duplicate navigation
    /// exactly as the direct parser (HTMLParser) does.
    /// Markdown: uses the file as-is.
    /// Plain text: literal Markdown with the plain-text headings as ATX headings.
    private static func extractCache(from url: URL, format: BookFormat) throws -> ExtractedCache {
        let markdown: String
        switch format {
        case .epub:
            return try extractFromEPUB(url: url)
        case .html:
            let html = try String(contentsOf: url, encoding: .utf8)
            markdown = try HTMLToMarkdownConverter.convert(html, stripDuplicateNavigation: true)
        case .markdown:
            // Already Markdown — use as-is
            markdown = try String(contentsOf: url, encoding: .utf8)
        case .txt:
            // The same line analysis as the direct parser, written as literal
            // Markdown, so a cached book reads exactly as
            // PlainTextParser.parse(text:) reads it.
            let text = try String(contentsOf: url, encoding: .utf8)
            markdown = PlainTextParser.markdown(text: text)
        case .docx:
            markdown = try DOCXParser.extractMarkdown(from: url)
        case .daisy:
            markdown = try DAISYParser.extractMarkdown(from: url)
        case .pdf:
            markdown = try PDFTextParser.extractMarkdown(from: url)
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
            "\(chapterMarkerPrefix)\(prepared.chapter.title)\(chapterMarkerSuffix)\n\(prepared.markdown)"
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
                title: chapter.title.isEmpty ? bookTitle : chapter.title,
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

        // Use the first chapter's title as the document title, or fall back to book title
        let docTitle = chapters.first?.title.isEmpty == false ? chapters.first!.title : bookTitle

        return DocumentContent(
            title: docTitle,
            author: bookAuthor,
            chapters: chapters,
            contentIndex: contentIndex
        )
    }

    /// Split cached Markdown into chapter sections based on chapter markers.
    /// Returns empty array if no chapter markers are found.
    private static func splitChapters(_ markdown: String) -> [(title: String, content: String)] {
        let lines = markdown.components(separatedBy: "\n")
        var sections: [(title: String, content: String)] = []
        var currentTitle = ""
        var currentLines: [String] = []
        var foundMarker = false

        for line in lines {
            if line.hasPrefix(chapterMarkerPrefix) && line.hasSuffix(chapterMarkerSuffix) {
                // Save previous section if it has content
                if foundMarker {
                    let content = currentLines.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty {
                        sections.append((title: currentTitle, content: content))
                    }
                }
                // Extract title from marker
                let titleStart = line.index(line.startIndex, offsetBy: chapterMarkerPrefix.count)
                let titleEnd = line.index(line.endIndex, offsetBy: -chapterMarkerSuffix.count)
                currentTitle = visibleChapterTitle(String(line[titleStart..<titleEnd]))
                currentLines = []
                foundMarker = true
            } else {
                currentLines.append(line)
            }
        }

        // Save final section
        if foundMarker {
            let content = currentLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                sections.append((title: currentTitle, content: content))
            }
        }

        return sections
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
