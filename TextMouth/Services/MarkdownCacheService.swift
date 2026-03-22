import Foundation
import ZIPFoundation
import SwiftSoup

/// Manages cached Markdown content files (content.md) inside .tmb packages.
/// All non-audio book formats are converted to Markdown at import time and stored
/// in the .tmb bundle. The reader loads from this cache instead of re-parsing
/// the original file on every open.
enum MarkdownCacheService {

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
    static func loadFromCache(for book: Book) throws -> DocumentContent {
        let tmbDir = book.tmbDirectory
        let cachePath = TextMouthPaths.contentMarkdownPath(in: tmbDir)
        let markdown = try String(contentsOf: cachePath, encoding: .utf8)

        return parseMultiChapterMarkdown(markdown, bookTitle: book.title, bookAuthor: book.author)
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
        case .audio:
            // Audio books don't get text caching
            return ""
        }
    }

    /// Extract Markdown from an EPUB file. Each spine chapter is converted from HTML
    /// to Markdown and separated by chapter markers.
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

            // Convert chapter HTML to Markdown
            let chapterMD = (try? HTMLToMarkdownConverter.convert(chapterHTML)) ?? ""
            guard !chapterMD.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            // Extract chapter title from the first heading in the Markdown
            let chapterTitle = extractFirstHeading(from: chapterMD)

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
    static func parseMultiChapterMarkdown(_ markdown: String, bookTitle: String, bookAuthor: String) -> DocumentContent {
        let sections = splitChapters(markdown)

        if sections.isEmpty {
            // No chapter markers — treat entire file as single chapter
            let content = parseSingleChapter(markdown, title: bookTitle)
            return DocumentContent(title: content.title.isEmpty ? bookTitle : content.title,
                                   author: bookAuthor,
                                   chapters: content.chapters)
        }

        var chapters: [Chapter] = []
        for section in sections {
            let parsed = try? MarkdownDocParser.parse(
                markdown: section.content,
                title: section.title
            )
            if let parsed = parsed, let chapter = parsed.chapters.first {
                // Use the chapter marker title, falling back to what the parser found
                var ch = chapter
                if !section.title.isEmpty {
                    ch.title = section.title
                }
                chapters.append(ch)
            }
        }

        // Use the first chapter's title as the document title, or fall back to book title
        let docTitle = chapters.first?.title.isEmpty == false ? chapters.first!.title : bookTitle

        return DocumentContent(title: docTitle, author: bookAuthor, chapters: chapters)
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

    /// Parse a single Markdown string into a DocumentContent (single chapter).
    private static func parseSingleChapter(_ markdown: String, title: String) -> DocumentContent {
        (try? MarkdownDocParser.parse(markdown: markdown, title: title))
            ?? DocumentContent(title: title, author: "Unknown", chapters: [
                Chapter(title: title, text: markdown, headings: [])
            ])
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
