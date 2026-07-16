import Foundation
import ZIPFoundation
import SwiftSoup

/// Manages cached Markdown content files (content.md) inside .tmb packages.
/// All non-audio book formats are converted to Markdown at import time and stored
/// in the .tmb bundle. The reader loads from this cache instead of re-parsing
/// the original file on every open.
enum MarkdownCacheService {

    /// Current semantic version of the cache format. Bump this whenever the
    /// extraction or parsing logic changes so existing caches are regenerated
    /// on the next app launch. Books with a stored version lower than this
    /// (or nil for pre-versioning books) will have their content.md rebuilt.
    /// Uses semantic versioning: major.minor.patch
    static let currentCacheVersion: String = "3.0.2"

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

    // MARK: - Cache Generation

    /// Generate and write the content.md cache file for a book.
    /// Returns true if the cache was successfully created.
    @discardableResult
    static func generateCache(for book: Book) -> Bool {
        guard !book.format.isAudio else { return false }
        guard !book.tmbDirectoryName.isEmpty else { return false }

        let tmbDir = book.tmbDirectory
        let cachePath = TextMouthPaths.contentMarkdownPath(in: tmbDir)
        let fileURL = URL(fileURLWithPath: book.filePath)

        do {
            let markdown = try extractMarkdown(from: fileURL, format: book.format)
            try markdown.write(to: cachePath, atomically: true, encoding: .utf8)
            return true
        } catch {
            print("Failed to generate content cache for \(book.title): \(error)")
            return false
        }
    }

    /// Generate a cache and advance the stored format version only after the
    /// cache file has been written successfully.
    @discardableResult
    static func generateCacheAndStampVersion(for book: inout Book) -> Bool {
        guard generateCache(for: book) else { return false }
        book.cacheFormatVersion = currentCacheVersion
        return true
    }

    /// Import-time variant that also computes the persisted navigation index
    /// while already executing on the serial import queue.
    static func generateCacheAnalyzeAndStamp(for book: inout Book) -> BookContentIndex? {
        guard generateCacheAndStampVersion(for: &book),
              let content = try? loadFromCache(for: book) else { return nil }
        let index = content.contentIndex.replacingFormat(book.format)
        book.applyContentIndexSummary(index)
        return index
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
    /// HTML: converts the HTML to Markdown.
    /// Markdown: uses the file as-is.
    /// Plain text: wraps with minimal Markdown formatting (detects headings).
    private static func extractMarkdown(from url: URL, format: BookFormat) throws -> String {
        switch format {
        case .epub:
            return try extractFromEPUB(url: url)
        case .html:
            let html = try String(contentsOf: url, encoding: .utf8)
            return try HTMLToMarkdownConverter.convert(html)
        case .markdown:
            // Already Markdown — use as-is
            return try String(contentsOf: url, encoding: .utf8)
        case .txt:
            return try extractFromPlainText(url: url)
        case .docx:
            return try DOCXParser.extractMarkdown(from: url)
        case .daisy:
            return try DAISYParser.extractMarkdown(from: url)
        case .pdf:
            return try PDFTextParser.extractMarkdown(from: url)
        case .audio:
            // Audio books don't get text caching
            return ""
        }
    }

    /// Extract Markdown from an EPUB file. Each spine chapter is converted from HTML
    /// to Markdown and separated by chapter markers. When the HTML lacks semantic
    /// heading tags, falls back to the NCX table of contents for chapter titles and
    /// injects a `# Title` heading at the top of each chapter's Markdown so that
    /// MarkdownDocParser will find headings during cache loading.
    private static func extractFromEPUB(url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EPUBParserError.fileNotFound(url.path)
        }
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw EPUBParserError.invalidArchive
        }

        // Use shared EPUB parsing helpers from EPUBParser
        let containerXML = try EPUBParser.extractString(archive: archive, path: "META-INF/container.xml")
        let opfPath = try EPUBParser.parseContainerForOPFPath(containerXML)
        let opfXML = try EPUBParser.extractString(archive: archive, path: opfPath)
        let opfDirectory = (opfPath as NSString).deletingLastPathComponent
        let opfData = try EPUBParser.parseOPF(opfXML)

        // Build a mapping from content file href to NCX navigation title.
        // Many EPUBs use styled <div>/<span> instead of <h1>-<h6> for chapter
        // headings, so the HTML-to-Markdown converter produces no `#` headings.
        // The NCX provides the authoritative chapter titles in those cases.
        let ncxTitles = parseNCXTitles(archive: archive, opfData: opfData, opfDirectory: opfDirectory)

        var markdownParts: [String] = []

        for itemRef in opfData.spineItemRefs {
            guard let manifestItem = opfData.manifest[itemRef],
                  manifestItem.mediaType.contains("html") || manifestItem.mediaType.contains("xml") else {
                continue
            }

            let chapterPath: String
            if opfDirectory.isEmpty {
                chapterPath = manifestItem.href
            } else {
                chapterPath = "\(opfDirectory)/\(manifestItem.href)"
            }

            let decodedPath = chapterPath.removingPercentEncoding ?? chapterPath
            guard !decodedPath.contains("..") && !decodedPath.hasPrefix("/") else {
                continue
            }

            guard let chapterHTML = try? EPUBParser.extractString(archive: archive, path: decodedPath) else {
                continue
            }

            // Convert chapter HTML to Markdown. EPUB cache generation uses the
            // same duplicate nav/TOC stripping rule as direct EPUB parsing.
            var chapterMD = (try? HTMLToMarkdownConverter.convert(
                chapterHTML,
                stripDuplicateNavigation: true
            )) ?? ""
            guard !chapterMD.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            // Extract chapter title from the first heading in the Markdown
            var chapterTitle = extractFirstHeading(from: chapterMD)

            // If no heading was found in the HTML, look up the NCX title for this
            // content file and inject it as a level-1 Markdown heading at the top.
            // This ensures MarkdownDocParser will pick it up as a proper heading.
            if chapterTitle.isEmpty {
                let ncxTitle = ncxTitles[manifestItem.href] ?? ""
                if !ncxTitle.isEmpty {
                    chapterTitle = ncxTitle
                    // Prepend the heading so it appears in the parsed content
                    chapterMD = "# \(ncxTitle)\n\n\(chapterMD)"
                }
            }

            markdownParts.append("\(chapterMarkerPrefix)\(chapterTitle)\(chapterMarkerSuffix)\n\(chapterMD)")
        }

        // If only one chapter, skip the chapter markers for simplicity
        if markdownParts.count == 1, let single = markdownParts.first {
            // Strip the chapter marker line from the single chapter
            let lines = single.components(separatedBy: "\n")
            if lines.first?.hasPrefix(chapterMarkerPrefix) == true {
                return lines.dropFirst().joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return single
        }

        return markdownParts.joined(separator: "\n\n")
    }

    /// Parse the NCX table of contents from an EPUB archive and return a mapping
    /// from content file href (relative to OPF directory) to navigation title.
    /// Returns an empty dictionary if no NCX is found or parsing fails.
    private static func parseNCXTitles(
        archive: Archive,
        opfData: EPUBParser.OPFData,
        opfDirectory: String
    ) -> [String: String] {
        // Find the NCX file from the manifest (media-type application/x-dtbncx+xml)
        let ncxItem = opfData.manifest.values.first { $0.mediaType.contains("ncx") }
        guard let ncxHref = ncxItem?.href else { return [:] }

        let ncxPath = opfDirectory.isEmpty ? ncxHref : "\(opfDirectory)/\(ncxHref)"
        guard let ncxXML = try? EPUBParser.extractString(archive: archive, path: ncxPath) else {
            return [:]
        }

        // Parse navPoints from the NCX XML
        guard let doc = try? XMLDocument(xmlString: ncxXML) else { return [:] }
        guard let navPoints = try? doc.nodes(forXPath: "//*[local-name()='navPoint']") else {
            return [:]
        }

        var titles: [String: String] = [:]
        for navPoint in navPoints {
            guard let element = navPoint as? XMLElement else { continue }

            // Extract the label text
            let labelText = (try? element.nodes(forXPath: "*[local-name()='navLabel']/*[local-name()='text']"))?
                .first?.stringValue ?? ""
            guard !labelText.isEmpty else { continue }

            // Extract the content src (may include a fragment like "file.html#id")
            guard let contentNode = (try? element.nodes(forXPath: "*[local-name()='content']"))?.first as? XMLElement,
                  let src = contentNode.attribute(forName: "src")?.stringValue else {
                continue
            }

            // Strip fragment identifier — we map by filename only so the title
            // applies to the spine item regardless of which anchor the NCX points to
            let fileOnly = src.components(separatedBy: "#").first ?? src
            let decoded = fileOnly.removingPercentEncoding ?? fileOnly

            // Only store the first title for each file (the primary chapter heading)
            if titles[decoded] == nil {
                titles[decoded] = labelText
            }
        }

        return titles
    }

    /// Convert plain text to Markdown, promoting detected headings to proper Markdown headings.
    private static func extractFromPlainText(url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)
        var result: [String] = []
        var setextLines: Set<Int> = []

        // First pass: identify setext underline lines
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 3 && (trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" })) {
                setextLines.insert(index)
            }
        }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip setext underline lines (already part of headings in Markdown)
            if setextLines.contains(index) {
                result.append(line)
                continue
            }

            // Already has markdown heading syntax — keep as-is
            if trimmed.hasPrefix("#") {
                result.append(line)
                continue
            }

            // Setext-style heading: line followed by === or ---
            if !trimmed.isEmpty && index + 1 < lines.count && setextLines.contains(index + 1) {
                // Already valid Markdown setext heading — keep as-is
                result.append(line)
                continue
            }

            // All-caps short lines → convert to ## headings
            if trimmed.count >= 3 && trimmed.count <= 80
                && trimmed.uppercased() == trimmed
                && trimmed.rangeOfCharacter(from: .letters) != nil {
                let letters = trimmed.filter { $0.isLetter }
                if letters.count >= 3 {
                    result.append("## \(trimmed)")
                    continue
                }
            }

            // Regular line — keep as-is
            result.append(line)
        }

        return result.joined(separator: "\n")
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
            let chapter = (try? MarkdownDocParser.parseChapter(markdown: markdown, title: bookTitle))
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
                title: section.title
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
                currentTitle = String(line[titleStart..<titleEnd])
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

    // MARK: - Helpers

    /// Extract the first heading text from Markdown content (for chapter title detection).
    private static func extractFirstHeading(from markdown: String) -> String {
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level >= 1 && level <= 6 {
                    return String(trimmed.dropFirst(level))
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                        .trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return ""
    }

}
