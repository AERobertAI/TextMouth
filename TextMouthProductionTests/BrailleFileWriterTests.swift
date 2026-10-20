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
        let data = BrailleFileWriter.pef(pages: pages, metadata: metadata ?? sampleMetadata, format: format)
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

        XCTAssertEqual(BrailleFileWriter.brf(pages: pages, lineEnd: .crlf), sample)
        // CR LF is the default.
        XCTAssertEqual(BrailleFileWriter.brf(pages: pages), sample)
        let lfSample = Data(sample.filter { $0 != 0x0D })
        XCTAssertEqual(BrailleFileWriter.brf(pages: pages, lineEnd: .lf), lfSample)
        XCTAssertLessThan(lfSample.count, sample.count)
    }

    /// The Grade 2 sample also writes back byte for byte (a page with one
    /// page-number line and no form feed).
    func testTheGrade2SampleWritesBackToo() throws {
        let copy = try copyOfFormatSample("brf/grade2-short.brf")
        let sample = try Data(contentsOf: copy)
        let pages = brfPages(sample)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(BrailleFileWriter.brf(pages: pages), sample)
    }

    /// A BRF is ASCII only, whatever the rows hold.
    func testABRFIsAlwaysASCII() throws {
        // Every six-dot cell, an eight-dot cell, a print letter, and a blank.
        let allCells = String(String.UnicodeScalarView((0x2800...0x283F).compactMap { Unicode.Scalar($0) }))
        let data = BrailleFileWriter.brf(pages: [[allCells + "\u{28FF}x\u{2800}"]])
        XCTAssertNotNil(String(data: data, encoding: .ascii))
        XCTAssertTrue(data.allSatisfy { $0 < 0x80 })
    }

    /// A cell with dot 7 (U+2841) cannot be written in braille ASCII, so a
    /// BRF writes its six-dot part, ⠁ (A); a PEF writes the same cells,
    /// because TextMouth writes and reads six-dot braille only (review
    /// finding M6: a PEF that kept dots 7 and 8 was refused on import as
    /// eight-dot braille). This test used to pin the PEF keeping the cell;
    /// the lead approved reversing it for M6 (message #3446).
    func testADotSevenCellIsWrittenAsItsSixDotPartInABRFAndInAPEF() throws {
        let row = "\u{2841}\u{28FF}\u{2840}"
        // U+2841 is ⠁ with dot 7: A. U+28FF is all eight dots: all six dots,
        // "=". U+2840 is dot 7 alone: no dot left, the blank cell, which
        // ends the row and so is not written.
        let brf = BrailleFileWriter.brf(pages: [[row]], lineEnd: .lf)
        XCTAssertEqual(String(data: brf, encoding: .ascii), "A=\n")

        let pef = try pefText([[row]])
        XCTAssertTrue(pef.contains("<row>\u{2801}\u{283F}</row>"), pef)
        XCTAssertFalse(pef.contains("\u{2841}") || pef.contains("\u{28FF}") || pef.contains("\u{2840}"))
    }

    /// The eight-dot backslash of liblouis's escape notation, U+2873, is
    /// written as ⠳ (U+2833) in a PEF and as braille ASCII's backslash in a
    /// BRF, so the two files hold the same cells (review finding M6).
    func testTheEscapesBackslashCellIsSixDotInBothFiles() throws {
        let row = "\u{2804}\u{2873}\u{2835}"
        XCTAssertTrue(try pefText([[row]]).contains("<row>\u{2804}\u{2833}\u{2835}</row>"))
        let brf = BrailleFileWriter.brf(pages: [[row]], lineEnd: .lf)
        // Dot 3 is the apostrophe, dots 1, 2, 5, and 6 the backslash, and
        // dots 1, 3, 5, and 6 the letter Z.
        XCTAssertEqual(String(data: brf, encoding: .ascii), "'\\Z\n")
    }

    /// A row that ends in cells that are blank once their dots 7 and 8 are
    /// cleared is a blank row in a PEF, as in a BRF: the trailing cells are
    /// left out and an all-blank row is `<row/>`.
    func testCellsThatAreBlankInSixDotsEndAPEFRowToo() throws {
        let text = try pefText([["\u{2801}\u{2840}\u{2880}", "\u{2840}"]])
        XCTAssertTrue(text.contains("\t\t\t\t\t<row>\u{2801}</row>\n\t\t\t\t\t<row/>\n"), text)
    }

    /// A scalar that is no braille pattern is written as a blank cell in a
    /// BRF and in a PEF, so that rows keep their columns and the PEF stays
    /// valid.
    func testAScalarThatIsNoCellBecomesABlankCell() throws {
        let row = "\u{2801}x\u{2803}"
        XCTAssertEqual(String(data: BrailleFileWriter.brf(pages: [[row]], lineEnd: .lf), encoding: .ascii), "A B\n")
        XCTAssertTrue(try pefText([[row]]).contains("<row>\u{2801}\u{2800}\u{2803}</row>"))
    }

    /// Trailing blank cells of a row are not written, and a wholly blank row
    /// is an empty line.
    func testTrailingBlankCellsAreNotWritten() throws {
        let rows = ["\u{2801}\u{2800}\u{2800}", "\u{2800}\u{2800}", ""]
        let data = BrailleFileWriter.brf(pages: [rows], lineEnd: .lf)
        XCTAssertEqual(String(data: data, encoding: .ascii), "A\n\n\n")
    }

    /// One form feed lies between two pages and none after the last; one
    /// page gives none, and no pages give nothing.
    func testFormFeedsSeparatePagesAndEndNone() throws {
        let page = ["\u{2801}"]
        let formFeed = UInt8(0x0C)
        let two = BrailleFileWriter.brf(pages: [page, page], lineEnd: .lf)
        XCTAssertEqual(Array(two), [0x41, 0x0A, formFeed, 0x41, 0x0A])
        let three = BrailleFileWriter.brf(pages: [page, page, page], lineEnd: .crlf)
        XCTAssertEqual(three.filter { $0 == formFeed }.count, 2)
        XCTAssertNotEqual(three.last, formFeed)
        let one = BrailleFileWriter.brf(pages: [page])
        XCTAssertFalse(one.contains(formFeed))
        XCTAssertEqual(Array(one), [0x41, 0x0D, 0x0A])
        XCTAssertTrue(BrailleFileWriter.brf(pages: []).isEmpty)
    }

    // MARK: PEF

    /// The same pages with the sample's metadata, at 40 by 25, give the PEF
    /// sample's bytes exactly.
    func testTheSamplePagesWriteBackToThePEFSampleBytes() throws {
        let pef = try Data(contentsOf: copyOfFormatSample("pef/pride-and-prejudice-ch1-grade1.pef"))
        let pages = try brfSamplePages()
        XCTAssertEqual(pages.count, 2)
        let written = BrailleFileWriter.pef(pages: pages, metadata: sampleMetadata, format: BraillePageFormat())
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
