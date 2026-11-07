import XCTest
import ZIPFoundation
@testable import TextMouth

// MARK: - What a Book Reads As

/// What a listener gets from a book's text: its words in order, its headings
/// with their levels, and its pages with the number of words before each.
/// Two books that read the same have equal readings.
struct BookReading: Equatable {
    /// Every word, chapter after chapter, split at white space.
    var words: [String] = []
    /// Each heading as "level: words", in order.
    var headings: [String] = []
    /// Each page as "label@N": N is the number of words before it.
    var pages: [String] = []

    /// Adds one chapter's reading text with its headings (level and words)
    /// and pages (label and UTF-16 offset in the text).
    mutating func append(text: String, headings chapterHeadings: [(level: Int, text: String)], pages chapterPages: [(label: String, offset: Int)]) {
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
    /// The words and pages of `markdown`, a content.md, as
    /// `MarkdownDocParser.parseChapter` reads them chapter by chapter, as the
    /// reader loads it (`MarkdownCacheService.parseMultiChapterMarkdown`). Its
    /// headings are left to `expectedReading(ofMarkdown:title:)`.
    static func wordsAndPages(ofMarkdown markdown: String) throws -> BookReading {
        var sections = MarkdownCacheService.splitChapters(markdown)
        if sections.isEmpty {
            sections = [(title: "", content: markdown)]
        }
        var reading = BookReading()
        for section in sections {
            let chapter = try MarkdownDocParser.parseChapter(
                markdown: section.content, title: section.title, includeNavigationHeadings: true
            )
            reading.append(
                text: chapter.text,
                headings: [],
                pages: chapter.pages.map { (label: $0.label, offset: $0.characterOffset) }
            )
        }
        return reading
    }

    /// `text` as a name on one line, as the reader's headings are compared.
    private static func line(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The headings the EPUB reader finds in the export of `document`, a walk
    /// that kept the chapters: the book's own headings, and, at the start of
    /// each chapter whose text does not begin with a heading, the one entry
    /// the reader gives a file that begins with other text. That entry is
    /// named as the reader names it: by the contents entry that links the
    /// file when the chapter has no heading (the chapter's title, or the
    /// book's for a book that is one untitled chapter), else by the file's
    /// title (the chapter's) unless that is the book's or none, which the
    /// reader calls "Chapter N" for the Nth file. Each chapter here is one file.
    static func expectedHeadings(of document: ExportDocument, bookTitle: String) -> [String] {
        let blocks = document.blocks
        let starts = document.chapterStarts
        var headings: [String] = []
        var fileNumber = 0
        for (index, start) in starts.enumerated() {
            let lower = min(max(start.blockIndex, 0), blocks.count)
            let upper = index + 1 < starts.count ? min(max(starts[index + 1].blockIndex, lower), blocks.count) : blocks.count
            guard lower < upper else { continue }
            fileNumber += 1
            let chapter = Array(blocks[lower..<upper])
            let own = ExportBlock.headings(in: chapter)
            let firstText = chapter.first { block in
                if case .pageBreak = block { return false }
                return true
            }
            var startsWithHeading = false
            if case .heading? = firstText { startsWithHeading = true }
            if !startsWithHeading {
                let title = line(start.title)
                let name: String
                if own.isEmpty {
                    name = title.isEmpty ? line(bookTitle) : title
                } else {
                    name = title.isEmpty || title == line(bookTitle) ? "Chapter \(fileNumber)" : title
                }
                headings.append("1: \(name)")
            }
            headings += own.map { "\($0.level): \(line($0.plainText))" }
        }
        return headings
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

    /// The reading the export of `markdown` should have: the words and pages
    /// of the book as read, and the headings the EPUB reader finds in the
    /// export (`expectedHeadings(of:bookTitle:)`).
    static func expectedReading(ofMarkdown markdown: String, title: String) throws -> BookReading {
        var expected = try wordsAndPages(ofMarkdown: markdown)
        let document = try ExportDocumentWalker.document(
            fromMarkdown: markdown, book: ExportBookDetails(title: title), options: .bookStructure
        )
        expected.headings = expectedHeadings(of: document, bookTitle: title)
        return expected
    }

    /// Writes the EPUB of `markdown` for a book titled `title` into a new
    /// folder `folder` and returns its URL.
    static func export(
        _ markdown: String,
        title: String,
        in folder: URL,
        writer: EPUBExportWriter = EPUBExportWriterTests.writer()
    ) throws -> URL {
        let book = ExportBookDetails(title: title, author: "Test Author", language: "en", identifier: UUID())
        let document = try ExportDocumentWalker.document(fromMarkdown: markdown, book: book, options: writer.walkOptions)
        let url = folder.appendingPathComponent("\(UUID().uuidString).epub")
        try writer.write(document, options: NoTextExportOptions(), to: url, cancellation: BookExportCancellation())
        return url
    }
}

// MARK: - The Round Trip

/// Export a book as EPUB, import the file through TextMouth's own EPUB reader,
/// and compare what the two read as: the same words in order, the same
/// headings at the same levels, the same pages at the same places. The
/// comparison is of `MarkdownDocParser.parseChapter`'s reading text, never of
/// markup.
final class EPUBExportRoundTripTests: XCTestCase {
    /// The title the books of these tests are exported under.
    private let title = "Harbour Notes"

    /// Exports `markdown`, reads it back, and fails unless the readings are
    /// equal, naming each difference as a line of the two lists.
    private func assertRoundTrips(
        _ markdown: String,
        writer: EPUBExportWriter = EPUBExportWriterTests.writer(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let folder = try makeSandboxDirectory("EPUB Round Trip")
        let url = try EPUBRoundTrip.export(markdown, title: title, in: folder, writer: writer)
        let expected = try EPUBRoundTrip.expectedReading(ofMarkdown: markdown, title: title)
        let actual = try EPUBRoundTrip.reading(ofEPUB: url)
        XCTAssertEqual(actual.words, expected.words, "the words", file: file, line: line)
        XCTAssertEqual(actual.headings, expected.headings, "the headings", file: file, line: line)
        XCTAssertEqual(actual.pages, expected.pages, "the pages", file: file, line: line)
        XCTAssertFalse(expected.words.isEmpty, "the book has words to compare", file: file, line: line)
    }

    /// A book with chapters, three levels of heading (one skipped), emphasis,
    /// a link, lists, a quote, a table, code, and pages between blocks and
    /// inside paragraphs, in a heading, and at the very start and the very
    /// end of the book.
    private static let fullBook = """
    <!-- chapter: Landfall -->
    <!-- page: 1 -->
    # Landfall

    The *pilot* boat came in at dawn, **late** and low, past [the light](https://example.com/light).

    <!-- page: 2 -->
    ## Moorings

    - First rope
    - Second rope
      - Inner rope

    1. One
    2. Two

    > A quote over
    > two lines.

    | Port | Depth |
    |------|-------|
    | Alder | 12 |
    | Brant | 9 |

    ```
    tide < high && wind > low
    ```

    <!-- chapter: Departure -->
    Plain chapter with no heading of its own, then a page <!-- page: iii --> inside a paragraph.

    #### Four deep, after a skip

    ## <!-- page: A-4 -->A heading with its page

    Last words of the book.

    <!-- page: 9 -->
    """

    /// The whole book reads back the same.
    func testAFullBookReadsBackTheSame() throws {
        try assertRoundTrips(Self.fullBook)
    }

    /// A book of many short parts, each a heading, a paragraph, and a page.
    private static var manyParts: String {
        var markdown = "# Start\n\nIntroduction words before the parts.\n\n"
        for number in 1...14 {
            markdown += "<!-- page: \(number) -->\n## Part \(number)\n\nParagraph \(number) with enough words in it to count.\n\n"
        }
        return markdown
    }

    /// The same kind of book split into many files by a small size limit
    /// reads back the same: a file ends where a heading begins, so a file
    /// boundary is not a change of the text or of the headings.
    func testABookInManyFilesReadsBackTheSame() throws {
        let writer = EPUBExportWriterTests.writer(maximumFileBytes: 400)
        try assertRoundTrips(Self.manyParts, writer: writer)
        let folder = try makeSandboxDirectory("EPUB Round Trip Files")
        let url = try EPUBRoundTrip.export(Self.manyParts, title: title, in: folder, writer: writer)
        XCTAssertGreaterThan(try Archive(url: url, accessMode: .read).filter { $0.path.hasSuffix(".xhtml") }.count, 5)
    }

    /// A book with no heading reads back the same words and pages, and a
    /// contents list of one entry, the book's title.
    func testABookWithNoHeadingsReadsBackWithTheOneEntry() throws {
        try assertRoundTrips("First paragraph.\n\n<!-- page: 2 -->\nSecond paragraph, with a page before it.")
    }

    /// One chapter of many has its place: three chapters each read back.
    func testOneChapterOfManyReadsBack() throws {
        try assertRoundTrips("<!-- chapter: A -->\nAlpha.\n\n<!-- chapter: B -->\n# Bee\n\nBeta.\n\n<!-- chapter: C -->\nGamma.")
    }

    /// Heading levels that skip, both up and down, keep their levels.
    func testHeadingLevelsThatSkipKeepTheirLevels() throws {
        try assertRoundTrips("# One\n\nx\n\n#### Four\n\ny\n\n## Two\n\nz\n\n###### Six\n\nw\n\n# Again\n\nv")
    }

    /// A heading of only punctuation keeps its words.
    func testAHeadingOfOnlyPunctuationReadsBack() throws {
        try assertRoundTrips("## !?!\n\nWords after it.")
    }

    /// A page marker at the very start and the very end of the book.
    func testPagesAtTheVeryStartAndEndReadBack() throws {
        try assertRoundTrips("<!-- page: 1 -->\nFirst.\n\nMiddle.\n\nLast.\n\n<!-- page: 9 -->")
    }

    /// Hostile text: markup characters, entities, raw HTML, `]]>`, form feeds,
    /// quotes, and emoji, in the title, a heading, and a paragraph, read back
    /// as the same words.
    func testHostileTextReadsBackTheSame() throws {
        try assertRoundTrips("""
        <!-- chapter: Rock & <Roll> "quoted" -->
        # Head & <b>bold</b> 'single' &amp; done

        Body & <i>raw</i> text and ]]> and &lt;tag&gt; and page\u{0C}break and emoji \u{1F469}\u{200D}\u{1F4BB} \u{1F44D}\u{1F3FD} caf\u{E9} e\u{301}.

        Line one
        Line two after a hard break.
        """)
    }

    /// Right-to-left and non-Latin scripts read back the same words, headings,
    /// and pages.
    func testRightToLeftAndNonLatinTextReadsBackTheSame() throws {
        try assertRoundTrips("""
        <!-- chapter: \u{5E4}\u{5E8}\u{5E7} \u{5D0} -->
        # \u{5E9}\u{5DC}\u{5D5}\u{5DD} \u{5E2}\u{5D5}\u{5DC}\u{5DD}

        \u{5D4}\u{5D9}\u{5D4} \u{5D6}\u{5DE}\u{5DF} \u{5D0}\u{5D7}\u{5D3} <!-- page: \u{5D0} --> \u{5D5}\u{5D4}\u{5D9}\u{5D4} \u{5E2}\u{5D5}\u{5D3}.

        <!-- chapter: \u{627}\u{644}\u{641}\u{635}\u{644} -->
        ## \u{645}\u{631}\u{62D}\u{628}\u{627} \u{628}\u{627}\u{644}\u{639}\u{627}\u{644}\u{645}

        \u{643}\u{627}\u{646} \u{64A}\u{627} \u{645}\u{627} \u{643}\u{627}\u{646} <!-- page: \u{662} --> \u{641}\u{64A} \u{642}\u{62F}\u{64A}\u{645} \u{627}\u{644}\u{632}\u{645}\u{627}\u{646}.

        <!-- chapter: \u{65E5}\u{672C}\u{8A9E} -->
        # \u{3053}\u{3093}\u{306B}\u{3061}\u{306F} \u{4E16}\u{754C}

        \u{543E}\u{8F29}\u{306F}\u{732B}\u{3067}\u{3042}\u{308B}\u{3002} \u{540D}\u{524D}\u{306F}\u{307E}\u{3060}\u{7121}\u{3044}\u{3002}
        """)
    }

    /// A book with no text reads back as the EPUB reader says of any book with
    /// nothing to read, rather than as a book with an invented chapter.
    func testABookWithNoTextHasNothingToReadBack() throws {
        let folder = try makeSandboxDirectory("EPUB Round Trip Empty")
        let url = try EPUBRoundTrip.export("", title: title, in: folder)
        XCTAssertThrowsError(try EPUBParser.prepareBook(url: url)) {
            guard case EPUBParserError.noReadableChapters? = $0 as? EPUBParserError else {
                return XCTFail("\($0)")
            }
        }
    }
}
