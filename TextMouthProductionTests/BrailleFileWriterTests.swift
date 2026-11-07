import XCTest
@testable import TextMouth

/// Tests for `BrailleFileWriter` (FMT22, Phase A): the BRF and PEF writers.
/// The real samples are the oracle: the pages of the BRF sample, written
/// back as a BRF, give the sample's bytes, and written as a PEF with the
/// sample's metadata, give the PEF sample's bytes. A BRF in each braille
/// file code (braillecodes) is pinned by its bytes and read back by the
/// reader in the same code.
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

    // MARK: Braille File Codes

    /// Every six-dot cell, U+2800 to U+283F in the order of its dots: the
    /// blank cell first, so it is no trailing blank and is written too.
    private let everySixDotCell = String(String.UnicodeScalarView((0x2800...0x283F).compactMap { Unicode.Scalar($0) }))

    /// North American Braille ASCII is the default code, and writes exactly
    /// the bytes every BRF was written in before files had a code: the
    /// sample's own, with either line end.
    func testNorthAmericanBrailleASCIIWritesTheSampleBytes() throws {
        let sample = try Data(contentsOf: copyOfFormatSample("brf/pride-and-prejudice-ch1-grade1.brf"))
        let pages = brfPages(sample)
        XCTAssertEqual(try BrailleFileWriter.brf(pages: pages, code: .northAmerican), sample)
        XCTAssertEqual(try BrailleFileWriter.brf(pages: pages, lineEnd: .lf, code: .northAmerican), Data(sample.filter { $0 != 0x0D }))
    }

    /// Each seven-bit code writes the 64 six-dot cells as its own 64
    /// characters, in the order of their dots (liblouis's `en-us-brf.dis`
    /// and `de-eurobrl6.dis`, which `BrailleFileCodeTests` compares with the
    /// tables): ASCII only, and Eurobraille in its lowercase form.
    func testEachSevenBitCodeWritesItsOwnCharacters() throws {
        let expected: [(BrailleFileCode, String)] = [
            (.northAmerican, #" A1B'K2L@CIF/MSP"E3H9O6R^DJG>NTQ,*5<-U8V.%[$+X!&;:4\0Z7(_?W]#Y)="#),
            (.eurobraille, #" a,b.k;l"cif|msp!e:h*o+r>djg`ntq'1?2-u(v$3960x~&<5/8)z={_4w7#y}%"#),
        ]
        for (code, characters) in expected {
            let data = try BrailleFileWriter.brf(pages: [[everySixDotCell]], lineEnd: .lf, code: code)
            XCTAssertEqual(String(data: data, encoding: .ascii), characters + "\n", code.name)
            XCTAssertTrue(data.allSatisfy { $0 < 0x80 }, code.name)
        }
    }

    /// Eurobraille writes the same cells as other characters than North
    /// American Braille ASCII: dot 1 is "a" (never "A"), dots 4-5-6 are "_"
    /// in both, the blank cell is the space in both, and the digits are the
    /// letters a to j with dot 6 (0 is dots 3-4-6), which North American
    /// Braille ASCII writes as punctuation.
    func testEurobrailleWritesLowercaseLettersAndItsOwnDigits() throws {
        // ⠁ ⠸, a blank cell, then the cells of the digits 1 to 9 and 0.
        let digits = "\u{2821}\u{2823}\u{2829}\u{2839}\u{2831}\u{282B}\u{283B}\u{2833}\u{282A}\u{282C}"
        let page = [["\u{2801}\u{2838}\u{2800}" + digits]]
        let eurobraille = try BrailleFileWriter.brf(pages: page, lineEnd: .lf, code: .eurobraille)
        XCTAssertEqual(String(data: eurobraille, encoding: .ascii), "a_ 1234567890\n")
        let northAmerican = try BrailleFileWriter.brf(pages: page, lineEnd: .lf, code: .northAmerican)
        XCTAssertEqual(String(data: northAmerican, encoding: .ascii), "A_ *<%?:$]\\[+\n")
    }

    /// Unicode braille patterns write each cell as its pattern's UTF-8, an
    /// inner blank cell (and a scalar that is no pattern) as U+2800, never
    /// the ASCII space, and no trailing blank cell; CR LF and the form feed
    /// between pages are the same bytes as in every code, and the file has
    /// no byte order mark.
    func testUnicodeBraillePatternsWriteEachCellAsUTF8() throws {
        let pages = [["\u{2801}\u{2800}\u{2803}\u{2800}\u{2800}", "\u{2800}"], ["x\u{283F}"]]
        let data = try BrailleFileWriter.brf(pages: pages, lineEnd: .crlf, code: .unicode)
        XCTAssertEqual(Array(data), [
            0xE2, 0xA0, 0x81, 0xE2, 0xA0, 0x80, 0xE2, 0xA0, 0x83, 0x0D, 0x0A,  // ⠁, a blank cell, ⠃
            0x0D, 0x0A,  // the row of blank cells, written as an empty line
            0x0C,  // the form feed between the two pages
            0xE2, 0xA0, 0x80, 0xE2, 0xA0, 0xBF, 0x0D, 0x0A,  // the "x" as a blank cell, then ⠿
        ])
        XCTAssertEqual(String(data: data, encoding: .utf8), "\u{2801}\u{2800}\u{2803}\r\n\r\n\u{0C}\u{2800}\u{283F}\r\n")
        XCTAssertFalse(data.contains(0x20), "no ASCII space")
        XCTAssertFalse(data.starts(with: [0xEF, 0xBB, 0xBF]), "no byte order mark")
    }

    /// liblouis's escape backslash, U+2873, is written as ⠳ in every code:
    /// braille ASCII's backslash, Eurobraille's "8", and the pattern itself.
    func testTheEscapesBackslashIsWrittenAsTheSixDotCellInEveryCode() throws {
        let row = "\u{2804}\u{2873}\u{2835}"
        let expected: [(BrailleFileCode, String)] = [
            (.northAmerican, "'\\Z\n"),
            (.eurobraille, ".8z\n"),
            (.unicode, "\u{2804}\u{2833}\u{2835}\n"),
        ]
        XCTAssertEqual(expected.map { $0.0 }, BrailleFileCode.all, "every code is checked")
        for (code, text) in expected {
            let data = try BrailleFileWriter.brf(pages: [[row]], lineEnd: .lf, code: code)
            XCTAssertEqual(String(data: data, encoding: .utf8), text, code.name)
        }
    }

    /// A cell with dot 7 or 8 (here U+2841) is refused in every code, as it
    /// was before files had a code (review R1): no code writes its six-dot
    /// part.
    func testAnEightDotCellIsRefusedInEveryCode() {
        for code in BrailleFileCode.all {
            XCTAssertThrowsError(try BrailleFileWriter.brf(pages: [["\u{2801}\u{2841}"]], code: code), code.name) {
                XCTAssertEqual($0 as? BrailleFileWriter.EightDotCell, BrailleFileWriter.EightDotCell(cell: "\u{2841}"), code.name)
            }
        }
    }

    /// Pages written in each code, with either line end, are read back in
    /// that code by the reader as the same pages: every six-dot cell, an
    /// inner blank cell, leading blank cells, a blank row, and two pages,
    /// whose form feed stands between braille text. Each row comes back
    /// without the trailing blank cells the writer leaves out.
    func testPagesWrittenInEachCodeReadBackAsTheSamePages() throws {
        let pages = [
            [everySixDotCell, "", "\u{2801}\u{2800}\u{2803}\u{2800}\u{2800}"],
            ["\u{2800}\u{2800}\u{283F}", "\u{2838}"],
        ]
        let expected = [
            [everySixDotCell, "", "\u{2801}\u{2800}\u{2803}"],
            ["\u{2800}\u{2800}\u{283F}", "\u{2838}"],
        ]
        for code in BrailleFileCode.all {
            for lineEnd in [BrailleLineEnd.crlf, .lf] {
                let data = try BrailleFileWriter.brf(pages: pages, lineEnd: lineEnd, code: code)
                let read = try BrailleFileReader.pages(fromText: data, kind: .brf, code: code)
                XCTAssertEqual(read.pages, expected, "\(code.name), \(lineEnd)")
            }
        }
    }

    /// The real BRF sample's pages, as the reader reads them, written in
    /// each code and read back in that code, are the same pages: two pages
    /// of a book, page numbers and all.
    func testTheBRFSampleWrittenInEachCodeReadsBackAsItself() throws {
        let copy = try copyOfFormatSample("brf/pride-and-prejudice-ch1-grade1.brf")
        let sample = try BrailleFileReader.read(copy, as: .brf, code: .northAmerican).pages
        XCTAssertEqual(sample.count, 2)
        for code in BrailleFileCode.all {
            let written = try BrailleFileWriter.brf(pages: sample, code: code)
            XCTAssertEqual(try BrailleFileReader.pages(fromText: written, kind: .brf, code: code).pages, sample, code.name)
        }
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
