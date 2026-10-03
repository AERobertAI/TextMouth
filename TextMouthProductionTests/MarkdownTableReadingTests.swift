import XCTest
@testable import TextMouth

/// How the Markdown reader reads a table (a finding of TODO T05): the way an
/// HTML table is read (`HTMLReadingText`, TODO T03). Each row, the header row
/// included, is a paragraph of its own, which speech pauses after; within a
/// row, each cell's words are kept apart from the words of the cell before
/// them by a space; and the table stands apart from the paragraphs before and
/// after it. The reader used to write no boundary anywhere in a table or
/// before it, so the DOCX fixture's table was heard as "Reading
/// (hPa)TrendExpected Conditions1013-1023Steady…".
///
/// DOCX books keep their tables as Markdown tables in content.md, and
/// Markdown books are cached as written, so the fix is in the reading text
/// derived from content.md, not in content.md itself: no cache rebuild is
/// needed. An index saved from the old reading no longer matches the text,
/// so the next load replaces it.
///
/// A DAISY 3 (DTBook) table reaches the reader as the same paragraphs, but
/// through its content.md: the DTBook converter writes each row as a
/// paragraph of its cells' words, with no Markdown table syntax. It used to
/// write `| cell | cell |` rows with no delimiter row, which the reader took
/// for one paragraph and read with its bars.
final class MarkdownTableReadingTests: XCTestCase {

    // MARK: - Rows and Cells

    /// Each row is a paragraph of its cells' words, one space between cells,
    /// and the table is a block of its own between the paragraphs around it.
    func testRowsAreParagraphsOfTheirCellsWords() throws {
        let reading = try read("""
        Barometer notes.

        | Reading (hPa) | Trend |
        | --- | --- |
        | 1013-1023 | Steady |
        | 1003-1013 | Falling |

        Check twice daily.
        """)

        XCTAssertEqual(reading, """
        Barometer notes.

        Reading (hPa) Trend

        1013-1023 Steady

        1003-1013 Falling

        Check twice daily.
        """)
    }

    /// A table that starts on the line right after a paragraph, with no
    /// blank line between, still begins a paragraph of its own.
    func testATableRightBelowAParagraphStillStandsApartFromIt() throws {
        let reading = try read("""
        Pressure chart:
        | Reading | Trend |
        | --- | --- |
        | 1013 | Steady |
        """)

        XCTAssertEqual(reading, "Pressure chart:\n\nReading Trend\n\n1013 Steady")
    }

    /// An empty cell adds nothing: no doubled space where it sits between
    /// two cells, no space after the last words of a row, and no blank
    /// paragraph for a row of empty cells. A row with fewer cells than the
    /// header reads the cells it has.
    func testEmptyCellsAddNoSpacesAndEmptyRowsNoParagraphs() throws {
        let reading = try read("""
        | Gauge | | Notes |
        | --- | --- | --- |
        | Aneroid | | Calibrate monthly |
        | | Mercury | |
        | | | |
        | Last |
        """)

        XCTAssertEqual(reading, "Gauge Notes\n\nAneroid Calibrate monthly\n\nMercury\n\nLast")
    }

    /// A cell's words are read without their formatting, as in a paragraph:
    /// emphasis, code, a link, an image's alternative text, and
    /// strikethrough. An escaped vertical bar is a word of its cell.
    func testCellsKeepTheirWordsWithoutTheirFormatting() throws {
        let reading = try read("""
        | **Bold** words | `inline code` | [a link](https://example.org) | ![alt text](gauge.png) |
        | --- | --- | --- | --- |
        | *one* | two | a \\| b | ~~four~~ |
        """)

        XCTAssertEqual(reading, "Bold words inline code a link alt text\n\none two a | b four")
    }

    /// A table that opens and closes its chapter leaves no space or blank
    /// line at either end of the chapter's text.
    func testATableFillingAChapterLeavesNothingAtItsEnds() throws {
        XCTAssertEqual(try read("| A | B |\n| --- | --- |\n| 1 | 2 |"), "A B\n\n1 2")
    }

    /// Two tables in a row stay two blocks: the last row of the first and
    /// the header row of the second are paragraphs of their own.
    func testTablesBackToBackStayApart() throws {
        let reading = try read("""
        | Morning |
        | --- |
        | 1013 |

        | Evening |
        | --- |
        | 1009 |
        """)

        XCTAssertEqual(reading, "Morning\n\n1013\n\nEvening\n\n1009")
    }

    /// A heading after a table is found where its label begins in the text
    /// that holds the table's separators, so heading navigation lands on it.
    func testHeadingsAfterATableAreFoundWhereTheirLabelsBegin() throws {
        let chapter = try MarkdownDocParser.parseChapter(markdown: """
        # Pressure

        | Reading | Trend |
        | --- | --- |
        | 1013 | Steady |

        ## Wind

        Light winds.
        """)

        XCTAssertEqual(chapter.text, "Pressure\n\nReading Trend\n\n1013 Steady\n\nWind\n\nLight winds.")
        XCTAssertEqual(chapter.headings.map(\.text), ["Pressure", "Wind"])
        XCTAssertEqual(chapter.headings.map(\.characterOffset), [0, utf16Offset(of: "Wind", in: chapter.text)])
    }

    /// A table reads exactly alike whether it reaches the cache as HTML, as
    /// an EPUB or HTML book's does (`HTMLToMarkdownConverter`, TODO T03),
    /// or as a Markdown table, as a DOCX or Markdown book's does: the same
    /// rows as paragraphs, the same cells as words, an empty cell adding
    /// nothing, and the same separation from the paragraphs around it.
    func testATableReadsAsTheSameTableInHTMLReads() throws {
        let markdown = """
        Barometer notes.

        | Reading (hPa) | Trend |
        | --- | --- |
        | 1013-1023 | Steady |
        | | Falling |

        Check twice daily.
        """

        let fromHTML = try read(HTMLToMarkdownConverter.convert(Self.barometerHTML))

        XCTAssertEqual(fromHTML, Self.barometerReading)
        XCTAssertEqual(try read(markdown), fromHTML)
    }

    // MARK: - DAISY 3 (DTBook) Tables

    /// A DTBook table reads exactly as the same table in HTML reads, from a
    /// file laid out as DTBook files are, with line breaks and indentation
    /// between its rows and cells: each row a paragraph of its cells' words,
    /// an empty cell adding nothing, and the table apart from the paragraphs
    /// around it. No Markdown table syntax reaches content.md.
    func testADTBookTableReadsAsTheSameTableInHTMLReads() throws {
        let markdown = try dtbookMarkdown(body: """
            <p>Barometer notes.</p>
            <table>
              <tr>
                <th>Reading (hPa)</th>
                <th>Trend</th>
              </tr>
              <tr>
                <td>1013-1023</td>
                <td>Steady</td>
              </tr>
              <tr>
                <td></td>
                <td>Falling</td>
              </tr>
            </table>
            <p>Check twice daily.</p>
            """)

        XCTAssertFalse(markdown.contains("|"), markdown)
        XCTAssertEqual(try read(markdown), Self.barometerReading)
        XCTAssertEqual(try read(markdown), try read(HTMLToMarkdownConverter.convert(Self.barometerHTML)))
    }

    /// A DTBook table's caption is a paragraph of its own before its rows.
    /// A cell's words are read without their formatting, and words that
    /// would begin Markdown structure where a row begins its line (a
    /// heading's number sign, a list's number or dash, a quotation's angle
    /// bracket) are read as written.
    func testDTBookCaptionsAndCellWordsReadAsWritten() throws {
        let markdown = try dtbookMarkdown(body: """
            <table>
              <caption>Sailings</caption>
              <tr><td># of crossings</td><td><strong>12</strong></td></tr>
              <tr><td>1.</td><td>Harbour <em>to</em> island</td></tr>
              <tr><td>- 5%</td><td>&gt; noon</td></tr>
            </table>
            """)

        XCTAssertEqual(try read(markdown), "Sailings\n\n# of crossings 12\n\n1. Harbour to island\n\n- 5% > noon")
    }

    /// A table in a DTBook cell is a block of its own, as in HTML: its rows
    /// are paragraphs between the words of the row holding it, which come
    /// before and after it in reading order.
    func testADTBookTableInACellReadsBetweenTheWordsOfItsRow() throws {
        let markdown = try dtbookMarkdown(body: """
            <table>
              <tr>
                <td>Ferry</td>
                <td>
                  <table>
                    <tr><td>Monday</td><td>9:00</td></tr>
                    <tr><td>Friday</td><td>17:30</td></tr>
                  </table>
                </td>
                <td>Weather permitting</td>
              </tr>
            </table>
            """)
        let html = "<table><tr><td>Ferry</td><td><table>"
            + "<tr><td>Monday</td><td>9:00</td></tr><tr><td>Friday</td><td>17:30</td></tr>"
            + "</table></td><td>Weather permitting</td></tr></table>"

        XCTAssertEqual(try read(markdown), "Ferry\n\nMonday 9:00\n\nFriday 17:30\n\nWeather permitting")
        XCTAssertEqual(try read(markdown), try read(HTMLToMarkdownConverter.convert(html)))
    }

    // MARK: - Through the Cache

    /// The DOCX fixture's table, read through its cache as the reader reads
    /// it, is heard row by row: the header row and each reading are
    /// paragraphs of their own, between the heading before the table and
    /// the chapter heading after it. content.md keeps the Markdown table the
    /// DOCX converter writes, so only the reading of it changed.
    func testDOCXFixtureTableIsReadRowByRowThroughItsCache() throws {
        let book = try importBook(requireFile("test_book.docx"))

        let chapters = try BookContentAnalysisService.load(book: book).content.chapters
        let cache = try String(contentsOf: MarkdownCacheService.cacheURL(for: book), encoding: .utf8)

        XCTAssertTrue(
            cache.contains("| Reading \\(hPa\\) | Trend | Expected Conditions |\n| --- | --- | --- |\n"),
            cache
        )
        XCTAssertEqual(chapters.count, 1)
        let reading = chapters.map(\.text).joined(separator: "\n\n")
        XCTAssertTrue(reading.contains("""
        Barometer Readings Reference

        Reading (hPa) Trend Expected Conditions

        1013-1023 Steady Fair weather, light winds

        1003-1013 Falling Clouds increasing, rain likely

        993-1003 Falling rapidly Storm approaching, high winds

        Below 993 Very low Severe storm, seek shelter

        Chapter 3: Communication
        """), reading)
    }

    /// A DAISY 3 book's table, imported and read through its cache as the
    /// reader reads it, is heard row by row between the paragraph before it
    /// and the section heading after it, and its content.md holds the rows
    /// as paragraphs, with no bars.
    func testDAISY3BookTableIsReadRowByRowThroughItsCache() throws {
        let fixtures = DAISYPackageFixtures.self
        let original = fixtures.packageBook["content/timetables.xml", default: ""]
        let paragraph = "<p>The first ferry leaves the north pier at ten past six.</p>"
        let dtbook = original.replacingOccurrences(
            of: paragraph,
            with: paragraph + "\n<table>\n<tr><th>Pier</th><th>Departs</th></tr>\n"
                + "<tr><td>North</td><td>6:10</td></tr>\n</table>"
        )
        XCTAssertNotEqual(dtbook, original, "the table was not added")
        let folder = try fixtures.writeFolder(
            fixtures.files(fixtures.packageBook, changing: ["content/timetables.xml": dtbook]),
            named: "Ferry Timetables",
            in: makeSandboxDirectory("dtbook-tables")
        )
        let book = try importBook(folder.appendingPathComponent("book.opf"))

        let chapters = try BookContentAnalysisService.load(book: book).content.chapters
        let cache = try String(contentsOf: MarkdownCacheService.cacheURL(for: book), encoding: .utf8)

        XCTAssertFalse(cache.contains("|"), cache)
        let reading = chapters.map(\.text).joined(separator: "\n\n")
        XCTAssertTrue(reading.contains("""
        The first ferry leaves the north pier at ten past six.

        Pier Departs

        North 6:10

        The Evening Return
        """), reading)
    }

    /// A book whose index was saved from the old, fused reading of its table
    /// needs no rebuild: content.md is unchanged, and the next load finds
    /// that the saved index no longer matches the reading text, reports it,
    /// and indexes the text afresh.
    func testAnIndexSavedFromTheFusedReadingIsReplacedOnTheNextLoad() throws {
        let book = try importBook(writingMarkdown: """
        Before the table.

        | Reading | Trend |
        | --- | --- |
        | 1013 | Steady |

        After the table.
        """)
        let fused = "Before the table.ReadingTrend1013Steady\n\nAfter the table."
        let separated = "Before the table.\n\nReading Trend\n\n1013 Steady\n\nAfter the table."
        let imported = try XCTUnwrap(book.storedBookInfo()?.contentIndex)
        var fusedIndex = BookContentIndex.build(
            fromChapters: [Chapter(title: book.title, text: fused, headings: [])],
            format: book.format
        )
        fusedIndex.textCacheFingerprint = imported.textCacheFingerprint
        try book.saveBookInfoThrowing(contentIndex: fusedIndex)

        let result = try BookContentAnalysisService.load(book: book)

        XCTAssertFalse(result.usedPersistedIndex)
        XCTAssertEqual(result.content.chapters.map(\.text), [separated])
        XCTAssertEqual(result.index.totalCharacterCount, separated.utf16.count)
        XCTAssertEqual(rejections(of: book), [
            "CONTENT_INDEX_REJECTED: \(book.title): chapters[0].characterCount is \(fused.utf16.count), "
                + "but the reading text holds \(separated.utf16.count)",
        ])
    }

    // MARK: - Helpers

    /// The cross-format barometer table in HTML, between a paragraph before
    /// it and one after it; its last row's first cell is empty.
    private static let barometerHTML = "<p>Barometer notes.</p><table>"
        + "<tr><th>Reading (hPa)</th><th>Trend</th></tr>"
        + "<tr><td>1013-1023</td><td>Steady</td></tr>"
        + "<tr><td></td><td>Falling</td></tr>"
        + "</table><p>Check twice daily.</p>"

    /// How the barometer table reads, whatever format it arrives in.
    private static let barometerReading =
        "Barometer notes.\n\nReading (hPa) Trend\n\n1013-1023 Steady\n\nFalling\n\nCheck twice daily."

    /// The reading text of `markdown` as one chapter.
    private func read(_ markdown: String) throws -> String {
        try MarkdownDocParser.parseChapter(markdown: markdown).text
    }

    /// The Markdown the DAISY 3 converter writes for a DTBook file whose one
    /// section holds `body`, failing the test if it finds the file damaged.
    private func dtbookMarkdown(body: String) throws -> String {
        try convertDTBookSnippet("""
            <?xml version="1.0" encoding="UTF-8"?>
            <dtbook xmlns="http://www.daisy.org/z3986/2005/dtbook/" version="2005-3">
            <book><bodymatter><level1>
            \(body)
            </level1></bodymatter></book></dtbook>
            """)
    }

    /// Where `needle` first begins in `text`, in UTF-16 code units, the
    /// coordinates of heading offsets.
    private func utf16Offset(of needle: String, in text: String) -> Int {
        (text as NSString).range(of: needle).location
    }

    /// Imports the file at `url` as a user imports it, removing its package
    /// when the test ends.
    private func importBook(_ url: URL) throws -> Book {
        let book = try FileImportService.importFile(from: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: book.tmbDirectory) }
        return book
    }

    /// Imports a Markdown book holding `markdown`, titled by a file name of
    /// its own so that its log lines are told from any other book's.
    private func importBook(writingMarkdown markdown: String) throws -> Book {
        let source = try makeSandboxDirectory("markdown-tables")
            .appendingPathComponent("Pressure Log \(UUID().uuidString.prefix(8)).md")
        try Data(markdown.utf8).write(to: source)
        return try importBook(source)
    }

    /// The debug log's reports of an index rejected for `book`, each from
    /// its tag onwards (without the timestamp).
    private func rejections(of book: Book) -> [String] {
        debugLogLines(containing: "CONTENT_INDEX_REJECTED: \(book.title):").compactMap { line in
            line.range(of: "CONTENT_INDEX_REJECTED:").map { String(line[$0.lowerBound...]) }
        }
    }
}
