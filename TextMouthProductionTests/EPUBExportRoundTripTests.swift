import XCTest
import ZIPFoundation
@testable import TextMouth

// MARK: - The Round Trip

/// Export a book as EPUB, import the file through TextMouth's own EPUB reader,
/// and compare what the two read as: the same words in order, the same
/// headings at the same levels, the same pages at the same places. The
/// expected reading is the reader's own reading of the book's content.md
/// (`MarkdownCacheService.parseMultiChapterMarkdown`), never the walk the
/// writer reads, so a heading the walk loses is a heading the test misses
/// (`EPUBRoundTrip`, in `EPUBRoundTripSupport.swift`).
final class EPUBExportRoundTripTests: XCTestCase {
    /// The title the books of these tests are exported under.
    private let title = "Harbour Notes"

    /// Exports `markdown`, reads it back, and fails unless the readings are
    /// equal, naming each difference as a line of the two lists.
    private func assertRoundTrips(
        _ markdown: String,
        writer: EPUBExportWriter = EPUBExportWriterTests.writer(),
        language: String? = "en",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let folder = try makeSandboxDirectory("EPUB Round Trip")
        let url = try EPUBRoundTrip.export(markdown, title: title, in: folder, writer: writer, language: language)
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
        # Head & bold 'single' &amp; done

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

    /// Every level of heading, 1 to 6, reads back at its level: a build that
    /// turns a level into a paragraph, or caps the levels, loses a row here.
    func testEveryLevelOfHeadingReadsBack() throws {
        try assertRoundTrips("# One\n\na\n\n## Two\n\nb\n\n### Three\n\nc\n\n#### Four\n\nd\n\n##### Five\n\ne\n\n###### Six\n\nf")
    }

    /// A converted book's contents entries that point at styled paragraphs,
    /// not headings (a heading annotation of content.md), reach the file and
    /// read back as entries at their levels: chapters and the sections in them,
    /// the shape of an ordinary converter's EPUB (B3).
    func testContentsEntriesThatAreNoHeadingsReadBack() throws {
        func annotation(_ level: Int, _ text: String) -> String {
            MarkdownHeadingAnnotation(level: level, text: text).markdown
        }
        let markdown = """
        <!-- chapter: Chapter One -->
        \(annotation(1, "Chapter One"))

        Chapter One

        Opening words of the first chapter.

        \(annotation(2, "First Section"))

        First Section

        Words of the first section, with a \(annotation(2, "Middle Place")) place inside its words.

        \(annotation(2, "Second Section"))

        Second Section

        Words of the second section.

        <!-- chapter: Chapter Two -->
        \(annotation(1, "Chapter Two"))

        Chapter Two

        Words of the second chapter.

        \(annotation(2, "Third Section"))

        Third Section

        Words of the third section.
        """
        try assertRoundTrips(markdown)
        // The reader lists every one of them, so the test can fail.
        let reading = try EPUBRoundTrip.expectedReading(ofMarkdown: markdown, title: title)
        XCTAssertEqual(reading.headings, [
            "1: Chapter One", "2: First Section", "2: Middle Place", "2: Second Section",
            "1: Chapter Two", "2: Third Section",
        ])
    }

    /// A contents entry at the same place as a heading is one row, as the
    /// reader lists it, not two.
    func testAnEntryAtAHeadingsPlaceReadsBackOnce() throws {
        let annotation = MarkdownHeadingAnnotation(level: 2, text: "Real").markdown
        try assertRoundTrips("# Top\n\nWords.\n\n\(annotation)\n\n## Real\n\nMore words.")
    }

    /// A page inside a table's cell reads back at the same place, after the
    /// cell's first word (S3).
    func testAPageInATableCellReadsBackAtTheSamePlace() throws {
        try assertRoundTrips("# Table\n\n| Port | Depth |\n|------|-------|\n| Alder <!-- page: 12 --> | 12 |\n| Brant | 9 |\n\nAfter the table.")
    }

    /// A chapter of only a page (a plate) joins the next file, so its page
    /// lands at the next words, where the reader has it; the plate's entry is
    /// in the contents, and the reader's own row for it is the next heading's
    /// place, which keeps one row (S2).
    func testAChapterOfOnlyAPageKeepsItsPage() throws {
        let markdown = "<!-- chapter: One -->\n# One\n\nWords one.\n\n<!-- chapter: Plate -->\n<!-- page: 3 -->\n\n<!-- chapter: Two -->\n# Two\n\nWords two."
        let folder = try makeSandboxDirectory("EPUB Round Trip Plate")
        let url = try EPUBRoundTrip.export(markdown, title: title, in: folder, writer: EPUBExportWriterTests.writer())
        let expected = try EPUBRoundTrip.expectedReading(ofMarkdown: markdown, title: title)
        let actual = try EPUBRoundTrip.reading(ofEPUB: url)
        XCTAssertEqual(actual.words, expected.words)
        XCTAssertEqual(actual.pages, expected.pages)
        XCTAssertEqual(actual.pages, ["3@3"], "after the three words of chapter One, where the plate stood")
        let archive = try Archive(url: url, accessMode: .read)
        XCTAssertEqual(archive.filter { $0.path.hasPrefix("OEBPS/chapter-") }.count, 2, "the plate has no file of its own")
    }

    /// A right-to-left book exported with its language, and one with none,
    /// read back the same words.
    func testRightToLeftBooksReadBackWithOrWithoutALanguage() throws {
        let markdown = "# \u{5E9}\u{5DC}\u{5D5}\u{5DD}\n\n\u{5D4}\u{5D9}\u{5D4} \u{5D6}\u{5DE}\u{5DF} \u{5D0}\u{5D7}\u{5D3}."
        try assertRoundTrips(markdown, language: "he")
        try assertRoundTrips(markdown, language: nil)
    }

    /// A book whose language is unknown is exported with the language "und"
    /// (undetermined), which the reader takes as no language, not as one to
    /// show in Book Info; a book with a language keeps it.
    func testAnUndeterminedLanguageReadsBackAsNone() throws {
        let folder = try makeSandboxDirectory("EPUB Round Trip Language")
        let unknown = try EPUBRoundTrip.export("# One\n\nWords.", title: title, in: folder, writer: EPUBExportWriterTests.writer(), language: nil)
        let archive = try Archive(url: unknown, accessMode: .read)
        var data = Data()
        _ = try archive.extract(try XCTUnwrap(archive["OEBPS/content.opf"])) { data.append($0) }
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("<dc:language>und</dc:language>"), "the export says und")
        XCTAssertEqual(try EPUBParser.readMetadata(url: unknown).language, "")

        let known = try EPUBRoundTrip.export("# One\n\nWords.", title: title, in: folder, writer: EPUBExportWriterTests.writer(), language: "fr-CA")
        XCTAssertEqual(try EPUBParser.readMetadata(url: known).language, "fr-CA")
    }

    /// A book with no text reads back as the EPUB reader says of any book with
    /// nothing to read, rather than as a book with an invented chapter.
    func testABookWithNoTextHasNothingToReadBack() throws {
        let folder = try makeSandboxDirectory("EPUB Round Trip Empty")
        let url = try EPUBRoundTrip.export("", title: title, in: folder, writer: EPUBExportWriterTests.writer())
        XCTAssertThrowsError(try EPUBParser.prepareBook(url: url)) {
            guard case EPUBParserError.noReadableChapters? = $0 as? EPUBParserError else {
                return XCTFail("\($0)")
            }
        }
    }
}
