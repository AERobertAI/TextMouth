import XCTest
@testable import TextMouth

/// Tests for `BrailleFileWriter` (FMT22, Phase A): the BRF and PEF writers.
/// The real samples are the oracle: the pages of the BRF sample, written
/// back as a BRF, give the sample's bytes, and written as a PEF with the
/// sample's metadata, give the PEF sample's bytes.
final class BrailleFileWriterTests: XCTestCase {
    // MARK: Helpers

    /// The metadata the PEF sample was made with.
    private let sampleMetadata = PEFMetadata(
        title: "Pride and Prejudice, Chapter I (Grade 1 UEB sample)",
        author: "Jane Austen",
        language: "en",
        identifier: "urn:uuid:5b0a3f6e-6c1d-4a35-9d57-0e2f6a1b7c10",
        date: "2026-10-17"
    )

    /// A PEF of `pages` as text, at the default format.
    private func pefText(
        _ pages: [[String]], metadata: PEFMetadata? = nil, format: BraillePageFormat = BraillePageFormat()
    ) throws -> String {
        let data = try BrailleFileWriter.pef(pages: pages, metadata: metadata ?? sampleMetadata, format: format)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    // MARK: BRF

    /// The BRF sample's own pages give the sample's bytes exactly, and with
    /// LF line ends the same bytes without the carriage returns.
    func testTheBRFSamplePagesWriteBackToTheSampleBytes() throws {
        let copy = try copyOfFormatSample("brf/pride-and-prejudice-ch1-grade1.brf")
        let sample = try Data(contentsOf: copy)
        let pages = brfPages(sample)
        XCTAssertEqual(pages.count, 2)

        XCTAssertEqual(try BrailleFileWriter.brf(pages: pages, lineEnd: .crlf), sample)
        // CR LF is the default.
        XCTAssertEqual(try BrailleFileWriter.brf(pages: pages), sample)
        let lfSample = Data(sample.filter { $0 != 0x0D })
        XCTAssertEqual(try BrailleFileWriter.brf(pages: pages, lineEnd: .lf), lfSample)
        XCTAssertLessThan(lfSample.count, sample.count)
    }

    /// The Grade 2 sample also writes back byte for byte (a page with one
    /// page-number line and no form feed).
    func testTheGrade2SampleWritesBackToo() throws {
        let copy = try copyOfFormatSample("brf/grade2-short.brf")
        let sample = try Data(contentsOf: copy)
        let pages = brfPages(sample)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(try BrailleFileWriter.brf(pages: pages), sample)
    }

    /// A BRF is ASCII only, whatever the rows hold that it can write.
    func testABRFIsAlwaysASCII() throws {
        // Every six-dot cell, liblouis's eight-dot escape backslash, a print
        // letter, and a blank.
        let allCells = String(String.UnicodeScalarView((0x2800...0x283F).compactMap { Unicode.Scalar($0) }))
        let data = try BrailleFileWriter.brf(pages: [[allCells + "\u{2873}x\u{2800}"]])
        XCTAssertNotNil(String(data: data, encoding: .ascii))
        XCTAssertTrue(data.allSatisfy { $0 < 0x80 })
    }

    /// A cell with dot 7 or 8 (here U+2841, ⠁ with dot 7) cannot be held by
    /// TextMouth's six-dot files, and dropping its extra dots would change
    /// what it means, so a BRF and a PEF both refuse it, naming its dots
    /// (review R1). It used to be written as its six-dot part (review
    /// finding M6), which hid what the table wrote.
    func testAnEightDotCellIsRefusedInABRFAndInAPEF() throws {
        let row = "\u{2801}\u{2841}"
        let refusal = BrailleFileWriter.EightDotCell(cell: "\u{2841}")
        XCTAssertThrowsError(try BrailleFileWriter.brf(pages: [[row]], lineEnd: .lf)) {
            XCTAssertEqual($0 as? BrailleFileWriter.EightDotCell, refusal)
        }
        XCTAssertThrowsError(try pefText([[row]])) {
            XCTAssertEqual($0 as? BrailleFileWriter.EightDotCell, refusal)
        }
        XCTAssertEqual(
            refusal.errorDescription,
            "The braille table writes an eight-dot cell, dots 1 and 7, and TextMouth writes BRF and PEF files in six-dot braille only."
        )
        XCTAssertEqual(
            BrailleFileWriter.EightDotCell(cell: "\u{2848}", character: "\u{2019}").errorDescription,
            "The braille table writes \u{201C}\u{2019}\u{201D} as an eight-dot cell, and TextMouth writes BRF and PEF files in six-dot braille only."
        )
    }

    /// The first cell a six-dot file cannot hold is any with dot 7 or 8 but
    /// liblouis's escape backslash; a cell's dots are said in words.
    func testEightDotCellsAndTheirDots() {
        XCTAssertNil(BrailleCells.firstEightDotCell(in: "\u{2801}\u{2873}\u{2800}"))
        XCTAssertEqual(BrailleCells.firstEightDotCell(in: "\u{2801}\u{2873}\u{28E4}\u{2848}"), "\u{28E4}")
        XCTAssertEqual(BrailleCells.dotsInWords(of: "\u{2800}"), "no dots")
        XCTAssertEqual(BrailleCells.dotsInWords(of: "\u{2840}"), "dot 7")
        XCTAssertEqual(BrailleCells.dotsInWords(of: "\u{2848}"), "dots 4 and 7")
        XCTAssertEqual(BrailleCells.dotsInWords(of: "\u{28E4}"), "dots 3, 6, 7, and 8")
    }

    /// The eight-dot backslash of liblouis's escape notation, U+2873, is
    /// written as ⠳ (U+2833) in a PEF and as braille ASCII's backslash in a
    /// BRF, so the two files hold the same cells (review finding M6).
    func testTheEscapesBackslashCellIsSixDotInBothFiles() throws {
        let row = "\u{2804}\u{2873}\u{2835}"
        XCTAssertTrue(try pefText([[row]]).contains("<row>\u{2804}\u{2833}\u{2835}</row>"))
        let brf = try BrailleFileWriter.brf(pages: [[row]], lineEnd: .lf)
        // Dot 3 is the apostrophe, dots 1, 2, 5, and 6 the backslash, and
        // dots 1, 3, 5, and 6 the letter Z.
        XCTAssertEqual(String(data: brf, encoding: .ascii), "'\\Z\n")
    }

    /// A row's trailing blank cells are left out of a PEF, as of a BRF, and
    /// an all-blank row is `<row/>`.
    func testTrailingBlankCellsEndAPEFRowToo() throws {
        let text = try pefText([["\u{2801}\u{2800}\u{2800}", "\u{2800}"]])
        XCTAssertTrue(text.contains("\t\t\t\t\t<row>\u{2801}</row>\n\t\t\t\t\t<row/>\n"), text)
    }

    /// A scalar that is no braille pattern is written as a blank cell in a
    /// BRF and in a PEF, so that rows keep their columns and the PEF stays
    /// valid.
    func testAScalarThatIsNoCellBecomesABlankCell() throws {
        let row = "\u{2801}x\u{2803}"
        XCTAssertEqual(String(data: try BrailleFileWriter.brf(pages: [[row]], lineEnd: .lf), encoding: .ascii), "A B\n")
        XCTAssertTrue(try pefText([[row]]).contains("<row>\u{2801}\u{2800}\u{2803}</row>"))
    }

    /// Trailing blank cells of a row are not written, and a wholly blank row
    /// is an empty line.
    func testTrailingBlankCellsAreNotWritten() throws {
        let rows = ["\u{2801}\u{2800}\u{2800}", "\u{2800}\u{2800}", ""]
        let data = try BrailleFileWriter.brf(pages: [rows], lineEnd: .lf)
        XCTAssertEqual(String(data: data, encoding: .ascii), "A\n\n\n")
    }

    /// One form feed lies between two pages and none after the last; one
    /// page gives none, and no pages give nothing.
    func testFormFeedsSeparatePagesAndEndNone() throws {
        let page = ["\u{2801}"]
        let formFeed = UInt8(0x0C)
        let two = try BrailleFileWriter.brf(pages: [page, page], lineEnd: .lf)
        XCTAssertEqual(Array(two), [0x41, 0x0A, formFeed, 0x41, 0x0A])
        let three = try BrailleFileWriter.brf(pages: [page, page, page], lineEnd: .crlf)
        XCTAssertEqual(three.filter { $0 == formFeed }.count, 2)
        XCTAssertNotEqual(three.last, formFeed)
        let one = try BrailleFileWriter.brf(pages: [page])
        XCTAssertFalse(one.contains(formFeed))
        XCTAssertEqual(Array(one), [0x41, 0x0D, 0x0A])
        XCTAssertTrue(try BrailleFileWriter.brf(pages: []).isEmpty)
    }

    // MARK: PEF

    /// The same pages with the sample's metadata, at 40 by 25, give the PEF
    /// sample's bytes exactly.
    func testTheSamplePagesWriteBackToThePEFSampleBytes() throws {
        let pef = try Data(contentsOf: copyOfFormatSample("pef/pride-and-prejudice-ch1-grade1.pef"))
        let pages = try brfSamplePages()
        XCTAssertEqual(pages.count, 2)
        let written = try BrailleFileWriter.pef(pages: pages, metadata: sampleMetadata, format: BraillePageFormat())
        XCTAssertEqual(written, pef)
    }

    /// A title with `&`, `<`, and `>` is escaped, and characters XML forbids
    /// are left out.
    func testMetadataIsXMLEscaped() throws {
        var metadata = sampleMetadata
        metadata.title = "Tom & Jerry <1> \"Quoted\"\u{1}"
        metadata.author = "A > B"
        metadata.identifier = "urn:x&y"
        let text = try pefText([["\u{2801}"]], metadata: metadata)
        XCTAssertTrue(text.contains("<dc:title>Tom &amp; Jerry &lt;1&gt; \"Quoted\"</dc:title>"))
        XCTAssertTrue(text.contains("<dc:creator>A &gt; B</dc:creator>"))
        XCTAssertTrue(text.contains("<dc:identifier>urn:x&amp;y</dc:identifier>"))
        // The result parses as XML.
        XCTAssertTrue(XMLParser(data: Data(text.utf8)).parse())
    }

    /// An empty author leaves out `dc:creator`; the file stays valid.
    func testAnEmptyAuthorLeavesOutTheCreator() throws {
        var metadata = sampleMetadata
        metadata.author = ""
        let text = try pefText([["\u{2801}"]], metadata: metadata)
        XCTAssertFalse(text.contains("dc:creator"))
        XCTAssertTrue(text.contains("<dc:title>"))
        XCTAssertTrue(XMLParser(data: Data(text.utf8)).parse())
        metadata.author = "  \n"
        XCTAssertFalse(try pefText([["\u{2801}"]], metadata: metadata).contains("dc:creator"))
    }

    /// The volume's size is the format's, held to its ranges, and the
    /// language is the metadata's.
    func testTheVolumeCarriesTheFormatAndTheLanguage() throws {
        var metadata = sampleMetadata
        metadata.language = "de-CH"
        let format = BraillePageFormat(cellsPerLine: 32, linesPerPage: 20, numbersPages: false)
        let text = try pefText([["\u{2801}"]], metadata: metadata, format: format)
        XCTAssertTrue(text.contains(#"<volume cols="32" rows="20" rowgap="0" duplex="false">"#))
        XCTAssertTrue(text.contains("<dc:language>de-CH</dc:language>"))
        let clamped = try pefText([], format: BraillePageFormat(cellsPerLine: 5, linesPerPage: 99))
        XCTAssertTrue(clamped.contains(#"cols="18" rows="50""#))
    }

    /// A blank row is `<row/>`, a page is a `page` element, and the file ends
    /// with one LF and has no carriage return.
    func testRowsPagesAndLineEnds() throws {
        let text = try pefText([["\u{2801}\u{2800}", ""], ["\u{2803}"]])
        XCTAssertTrue(text.contains("\t\t\t\t<page>\n\t\t\t\t\t<row>\u{2801}</row>\n\t\t\t\t\t<row/>\n\t\t\t\t</page>\n"))
        XCTAssertEqual(text.components(separatedBy: "<page>").count - 1, 2)
        XCTAssertTrue(text.hasSuffix("</pef>\n"))
        XCTAssertFalse(text.hasSuffix("\n\n"))
        XCTAssertFalse(text.contains("\r"))
    }
}
