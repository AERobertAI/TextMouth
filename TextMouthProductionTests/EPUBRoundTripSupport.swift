import Foundation
@testable import TextMouth

// MARK: - What a Book Reads As

/// What a listener gets from a book's text: its words in order, its headings
/// with their levels, and its pages with the number of words before each.
/// Two books that read the same have equal readings.
///
/// This file imports no XCTest, so the scratch package that proves the tests
/// (a harness outside the repository) can compile it with the app.
struct BookReading: Equatable {
    /// Every word, chapter after chapter, split at white space.
    var words: [String] = []
    /// Each heading as "level: words", in order.
    var headings: [String] = []
    /// Each page as "label@N": N is the number of words before it.
    var pages: [String] = []

    /// Adds one chapter's reading text with its headings (level and words)
    /// and pages (label and UTF-16 offset in the text).
    mutating func append(
        text: String,
        headings chapterHeadings: [(level: Int, text: String)],
        pages chapterPages: [(label: String, offset: Int)]
    ) {
        let before = words.count
        words += text.split(whereSeparator: \.isWhitespace).map(String.init)
        headings += chapterHeadings.map { "\($0.level): \($0.text.split(whereSeparator: \.isWhitespace).joined(separator: " "))" }
        let utf16 = Array(text.utf16)
        for page in chapterPages {
            let offset = min(max(page.offset, 0), utf16.count)
            let prefix = String(decoding: utf16[0..<offset], as: UTF16.self)
            pages.append("\(page.label)@\(before + prefix.split(whereSeparator: \.isWhitespace).count)")
        }
    }
}

/// The two readings a round trip compares: the book as TextMouth reads its
/// content.md, and the book as TextMouth's own EPUB reader reads the file
/// exported from it.
enum EPUBRoundTrip {
    /// The reading of `markdown`, a content.md, as the reader loads it
    /// (`MarkdownCacheService.parseMultiChapterMarkdown`, the loader's own
    /// code, not the export's walk): its words, its pages, and its headings
    /// as the reader lists them, the contents annotations among them and a
    /// chapter's title standing for the heading it has none of.
    static func readerReading(ofMarkdown markdown: String, bookTitle: String) -> BookReading {
        let content = MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: bookTitle, bookAuthor: "")
        var reading = BookReading()
        for chapter in content.chapters {
            reading.append(
                text: chapter.text,
                headings: chapter.headings.map { (level: $0.level, text: $0.text) },
                pages: chapter.pages.map { (label: $0.label, offset: $0.characterOffset) }
            )
        }
        return reading
    }

    /// The reading the EPUB reader should find in the export of `markdown`:
    /// the reader's own reading of the book (`readerReading`), and, at the
    /// start of each chapter whose first heading is not at its first word (or
    /// that has none), the one entry the reader gives a file that begins with
    /// other text. The writer links the file's start from the contents with the
    /// chapter's title, or the book's when it has none (S7), and the reader
    /// names its entry by that link.
    ///
    /// Each chapter is one file here, and a contents target is read back at
    /// the depth of its entry in the contents, so a fixture's annotations carry
    /// the level of the place they hold.
    static func expectedReading(ofMarkdown markdown: String, title: String) throws -> BookReading {
        let sections = MarkdownCacheService.splitChapters(markdown)
        let content = MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: title, bookAuthor: "")
        var reading = BookReading()
        for (index, chapter) in content.chapters.enumerated() {
            var headings = chapter.headings.map { (level: $0.level, text: $0.text) }
            if chapter.headings.first?.characterOffset != 0 {
                let chapterTitle = sections.indices.contains(index) ? sections[index].title : ""
                headings.insert((level: 1, text: chapterTitle.isEmpty ? title : chapterTitle), at: 0)
            }
            reading.append(
                text: chapter.text,
                headings: headings,
                pages: chapter.pages.map { (label: $0.label, offset: $0.characterOffset) }
            )
        }
        return reading
    }

    /// The reading of the EPUB at `url` by TextMouth's own EPUB reader.
    static func reading(ofEPUB url: URL) throws -> BookReading {
        var reading = BookReading()
        for prepared in try EPUBParser.prepareBook(url: url).chapters {
            let chapter = prepared.chapter
            reading.append(
                text: chapter.text,
                headings: chapter.headings.map { (level: $0.level, text: $0.text) },
                pages: chapter.pages.map { (label: $0.label, offset: $0.characterOffset) }
            )
        }
        return reading
    }

    /// Writes the EPUB of `markdown` for a book titled `title` as a new file in
    /// `folder` and returns its URL.
    static func export(
        _ markdown: String,
        title: String,
        in folder: URL,
        writer: EPUBExportWriter,
        language: String? = "en"
    ) throws -> URL {
        let book = ExportBookDetails(title: title, author: "Test Author", language: language, identifier: UUID())
        let document = try ExportDocumentWalker.document(fromMarkdown: markdown, book: book, options: writer.walkOptions)
        let url = folder.appendingPathComponent("\(UUID().uuidString).epub")
        try writer.write(document, options: NoTextExportOptions(), to: url, cancellation: BookExportCancellation())
        return url
    }

    /// The first place two lists differ, as a sentence with both lists'
    /// lengths and the neighbours of the difference, or nil when they are equal.
    static func firstDifference(_ expected: [String], _ actual: [String]) -> String? {
        if expected == actual { return nil }
        let index = zip(expected, actual).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(expected.count, actual.count)
        let window = { (list: [String]) in Array(list[max(0, index - 2)..<min(list.count, index + 3)]) }
        return "differ at \(index) (\(expected.count) expected, \(actual.count) read back): expected \(window(expected)), read back \(window(actual))"
    }
}
