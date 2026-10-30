import XCTest
@testable import TextMouth

/// Tests for `BrailleFileReader` (FMT20), which turns the bytes of a BRF,
/// BRL, or PEF file into pages of rows of Unicode braille and nothing more.
/// The samples are read from copies in a folder of the test's own; the other
/// files are made here, byte by byte.
final class BrailleFileReaderTests: XCTestCase {
    // MARK: - Helpers

    /// The blank cell, U+2800.
    private let blank = "\u{2800}"

    /// The cells of braille ASCII `text`, as the reader converts it.
    private func cells(_ text: String) -> String {
        String(String.UnicodeScalarView(text.utf8.compactMap { BrailleCells.cell(forASCII: $0) }))
    }

    /// The pages of `text` read as a BRF (or BRL), as UTF-8 bytes.
    private func pages(_ text: String, kind: BrailleFileKind = .brf) throws -> [[String]] {
        try BrailleFileReader.pages(fromASCII: Data(text.utf8), kind: kind).pages
    }

    /// The refusal `bytes` are met with when read as a BRF (or BRL), nil if read.
    private func refusal(of bytes: [UInt8], kind: BrailleFileKind = .brf) -> BrailleFileError? {
        do {
            _ = try BrailleFileReader.pages(fromASCII: Data(bytes), kind: kind)
            return nil
        } catch {
            return error as? BrailleFileError
        }
    }

    /// `bytes` read as a BRF (or BRL) in the braille file code `code`.
    private func pages(of bytes: [UInt8], kind: BrailleFileKind = .brf,
                       in code: BrailleFileCode) throws -> BrailleFilePages {
        try BrailleFileReader.pages(fromText: Data(bytes), kind: kind, code: code)
    }

    /// The refusal `bytes` are met with when read as a BRF (or BRL) in the
    /// braille file code `code`, nil if read.
    private func refusal(of bytes: [UInt8], kind: BrailleFileKind = .brf,
                         in code: BrailleFileCode) -> BrailleFileError? {
        do {
            _ = try pages(of: bytes, kind: kind, in: code)
            return nil
        } catch {
            return error as? BrailleFileError
        }
    }

    /// The dots of the 64 six-dot cells, in order: 0, the blank cell, to 63.
    private let sixDotCells = Array(UInt8(0)..<64)

    /// The 64 six-dot cells, in the order of their dots, as the seven-bit
    /// table `table` writes them.
    private func everyCell(in table: SevenBitBrailleTable) -> [UInt8] {
        sixDotCells.map { table.byte(forDots: $0) }
    }

    /// The UTF-8 bytes of `text` repeated `count` times.
    private func repeating(_ text: String, _ count: Int) -> [UInt8] {
        Array([[UInt8]](repeating: Array(text.utf8), count: count).joined())
    }

    /// A PEF document with `body` after a head holding `head`, in the PEF
    /// namespace unless `namespace` says another, under the root `root`.
    private func pef(_ body: String, head: String = "", root: String = "pef",
                     namespace: String = "http://www.daisy.org/ns/2008/pef") -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <\(root) version="2008-1" xmlns="\(namespace)">
        <head><meta xmlns:dc="http://purl.org/dc/elements/1.1/">\(head)</meta></head>
        <body>\(body)</body>
        </\(root)>
        """.utf8)
    }

    /// A PEF with one volume and section holding `pageRows`' pages.
    private func pef(pages pageRows: [[String]]) -> Data {
        let pageXML = pageRows.map { "<page>" + $0.map { "<row>\($0)</row>" }.joined() + "</page>" }.joined()
        return pef("<volume><section>\(pageXML)</section></volume>")
    }

    /// The PEF `data`, read, or the refusal it throws.
    private func pefRefusal(_ data: Data) -> BrailleFileError? {
        do {
            _ = try BrailleFileReader.pages(fromPEF: data)
            return nil
        } catch {
            return error as? BrailleFileError
        }
    }

    // MARK: - The Samples

    /// The BRF sample is two pages of 25 rows, which are the PEF sample's
    /// rows cell for cell.
    func testTheBRFSampleIsTwoPagesThatEqualThePEFSample() throws {
        let brf = try BrailleFileReader.read(
            copyOfFormatSample("brf/pride-and-prejudice-ch1-grade1.brf"), as: .brf)
        let pefPages = try BrailleFileReader.read(
            copyOfFormatSample("pef/pride-and-prejudice-ch1-grade1.pef"), as: .pef)
        XCTAssertEqual(brf.kind, .brf)
        XCTAssertNil(brf.title)
        XCTAssertEqual(brf.pages.map(\.count), [25, 25])
        // Rows 1 and 25 of page 1 are read below, so both pages' rows are
        // counted before any row is.
        guard brf.pages.map(\.count) == [25, 25] else { return }
        XCTAssertEqual(BrailleCells.spaced(brf.pages[0][0]), "         ⠠⠏⠗⠊⠙⠑ ⠁⠝⠙ ⠠⠏⠗⠑⠚⠥⠙⠊⠉⠑")
        XCTAssertEqual(brf.pages[0][24], String(repeating: blank, count: 38) + "⠼⠁")
        XCTAssertEqual(brf.pages, pefPages.pages)
    }

    /// The PEF sample is the same two pages, with its title, author, and
    /// language, which `pefMetadata(of:)` gives too.
    func testThePEFSampleHasItsPagesAndMetadata() throws {
        let url = try copyOfFormatSample("pef/pride-and-prejudice-ch1-grade1.pef")
        let result = try BrailleFileReader.read(url, as: .pef)
        XCTAssertEqual(result.kind, .pef)
        XCTAssertEqual(result.pages.map(\.count), [25, 25])
        XCTAssertEqual(result.title, "Pride and Prejudice, Chapter I (Grade 1 UEB sample)")
        XCTAssertEqual(result.author, "Jane Austen")
        XCTAssertEqual(result.language, "en")

        let metadata = BrailleFileReader.pefMetadata(of: url)
        XCTAssertEqual(metadata.title, result.title)
        XCTAssertEqual(metadata.author, result.author)
        XCTAssertEqual(metadata.language, result.language)
    }

    /// The BRL sample is one page of its 14 lines.
    func testTheBRLSampleIsOnePageOfFourteenRows() throws {
        let result = try BrailleFileReader.read(
            copyOfFormatSample("brl/pride-and-prejudice-ch1-grade1.brl"), as: .brl)
        XCTAssertEqual(result.kind, .brl)
        XCTAssertEqual(result.pages.count, 1)
        guard result.pages.count == 1 else { return }
        XCTAssertEqual(result.pages[0].count, 14)
        XCTAssertEqual(result.pages[0].first, cells(",PRIDE AND ,PREJUDICE"))
    }

    /// The Grade 2 sample is one page of 25 rows.
    func testTheGrade2SampleIsOnePageOfTwentyFiveRows() throws {
        let result = try BrailleFileReader.read(copyOfFormatSample("brf/grade2-short.brf"), as: .brf)
        XCTAssertEqual(result.pages.map(\.count), [25])
        guard let first = result.pages.first?.first else { return XCTFail("The page has no row.") }
        XCTAssertEqual(BrailleCells.spaced(first), "⠠⠮ ⠃⠕⠽ ⠯ ⠛⠊⠗⠇ ⠉ ⠛ ⠾ ⠽⠲")
    }

    // MARK: - Lines and Pages

    /// LF, a lone CR, and CR LF end lines alike; text after the last line
    /// end is a row; a final line end adds no empty row.
    func testLineEndsAreLFCRAndCRLF() throws {
        let expected = [cells("AB"), cells("CD"), cells("EF")]
        XCTAssertEqual(try pages("AB\nCD\nEF").first, expected)
        XCTAssertEqual(try pages("AB\rCD\rEF").first, expected)
        XCTAssertEqual(try pages("AB\r\nCD\r\nEF\r\n").first, expected)
        XCTAssertEqual(try pages("AB\n").first, [cells("AB")])
        // A blank line is a row, empty.
        XCTAssertEqual(try pages("AB\n\nCD").first, [cells("AB"), "", cells("CD")])
        // A CR followed by an LF is one line end, not two.
        XCTAssertEqual(try pages("AB\r\n\r\nCD").first, [cells("AB"), "", cells("CD")])
    }

    /// A file with no form feed is cut into pages of 25 lines.
    func testAFileWithoutFormFeedsIsCutIntoPagesOfTwentyFive() throws {
        let sixty = String(repeating: "A\n", count: 60)
        XCTAssertEqual(try pages(sixty).map(\.count), [25, 25, 10])
    }

    /// A form feed between braille text ends a page: after a line end, in
    /// the middle of a line, and, once the last text is read, at the very
    /// end too (adding no empty page); two in a row make an empty page; and
    /// pages that form feeds end are not cut at 25.
    func testFormFeedsEndPages() throws {
        let a = [cells("A")], b = [cells("A"), cells("B")], c = [cells("C")]
        XCTAssertEqual(try pages("A\nB\n\u{0C}C\n"), [b, c])
        XCTAssertEqual(try pages("A\nB\u{0C}C\n"), [b, c])
        XCTAssertEqual(try pages("A\n\u{0C}C\n\u{0C}"), [a, c])
        XCTAssertEqual(try pages("A\n\u{0C}C\n\u{0C}\u{0C}"), [a, c, []])
        XCTAssertEqual(try pages("A\n\u{0C}\u{0C}C\n"), [a, [], c])
        let thirty = String(repeating: "A\n", count: 30) + "\u{0C}C\n"
        XCTAssertEqual(try pages(thirty).map(\.count), [30, 1])
    }

    /// A form feed marks a page only between braille text. One that stands
    /// only at a file's start or end, with nothing but line ends and blank
    /// cells before or after it, is read as no form feed: the file is cut
    /// every 25 lines exactly as the same file without it, and marks no pages
    /// of its own, so that braille page numbers decide whether those pieces
    /// are pages. Counted, the one form feed at the end of a six-page file
    /// made it a single page.
    func testAFormFeedOnlyAtTheStartOrTheEndIsNoFormFeed() throws {
        let thirty = String(repeating: "A\n", count: 30)
        let files = [
            "\u{0C}" + thirty, thirty + "\u{0C}", thirty + "\u{0C}\u{0C}", "\u{0C}" + thirty + "\u{0C}",
            thirty + "\u{0C}\r\n", "\r\n\u{0C}" + thirty, "\u{0C}\u{0C}A\n", "A\n\u{0C}",
        ]
        for file in files {
            let read = try BrailleFileReader.pages(fromASCII: Data(file.utf8), kind: .brf)
            let unmarked = file.replacingOccurrences(of: "\u{0C}", with: "")
            XCTAssertEqual(read.pages, try pages(unmarked), file.debugDescription)
            XCTAssertFalse(read.marksItsPages, file.debugDescription)
        }
        XCTAssertEqual(try pages(thirty + "\u{0C}").map(\.count), [25, 5])

        // Between braille text a form feed marks its page, whatever stands at the ends.
        let marked = try BrailleFileReader.pages(fromASCII: Data(("\u{0C}" + thirty + "\u{0C}B\n\u{0C}").utf8), kind: .brf)
        XCTAssertTrue(marked.marksItsPages)
        XCTAssertEqual(marked.pages.map(\.count), [0, 30, 1])
    }

    /// A file of nothing but form feeds holds no page at all.
    func testAFileOfOnlyFormFeedsHasNoPages() throws {
        XCTAssertEqual(try pages("\u{0C}\u{0C}"), [])
        XCTAssertEqual(try pages("\r\n"), [[""]])
    }

    /// A BRL is one page, whatever form feeds it holds, and they are not characters.
    func testABRLIsOnePageAndIgnoresFormFeeds() throws {
        XCTAssertEqual(try pages("A\n\u{0C}B\n", kind: .brl), [[cells("A"), cells("B")]])
        XCTAssertEqual(try pages("A\u{0C}B", kind: .brl), [[cells("AB")]])
        XCTAssertEqual(try pages(String(repeating: "A\n", count: 60), kind: .brl).map(\.count), [60])
    }

    // MARK: - Characters

    /// Lowercase reads as capitals, a tab as one blank cell, a final Ctrl-Z
    /// is dropped, and a Ctrl-Z elsewhere is refused on its line.
    func testLowercaseTabsAndCtrlZ() throws {
        XCTAssertEqual(try pages(",pride").first, [cells(",PRIDE")])
        XCTAssertEqual(try pages("A\tB").first, [cells("A") + blank + cells("B")])
        XCTAssertEqual(try pages("AB\n\u{1A}").first, [cells("AB")])
        XCTAssertEqual(refusal(of: Array("A\nB\u{1A}C".utf8)),
                       .notBrailleASCII(.controlCharacter(0x1A), line: 2))
    }

    // MARK: - Refusals

    /// Each sentence a BRF or BRL is refused with, exactly.
    func testTheSentencesNameTheCharacterTheControlCodeOrTheByte() {
        let character = refusal(of: Array("A\r\nB\r\n,é".utf8))
        XCTAssertEqual(character, .notBrailleASCII(.character("é"), line: 3))
        XCTAssertEqual(character?.errorDescription, "Line 3 holds “é”, which is not braille ASCII.")

        let control = refusal(of: Array("A\u{07}".utf8))
        XCTAssertEqual(control, .notBrailleASCII(.controlCharacter(7), line: 1))
        XCTAssertEqual(control?.errorDescription,
                       "Line 1 holds the control character U+0007, which is not braille ASCII.")

        // A lone Latin-1 é is no valid UTF-8: eight-bit computer braille.
        let byte = refusal(of: [0x41, 0x0A, 0x41, 0xE9])
        XCTAssertEqual(byte, .eightBitBraille)
        XCTAssertEqual(byte?.errorDescription,
                       "This file looks like eight-bit computer braille, which TextMouth does not read.")

        // A control character past four digits keeps them all, and the DEL
        // character is a control character too.
        XCTAssertEqual(refusal(of: [0x7F])?.errorDescription,
                       "Line 1 holds the control character U+007F, which is not braille ASCII.")
        XCTAssertEqual(refusal(of: Array("A\u{85}".utf8))?.errorDescription,
                       "Line 1 holds the control character U+0085, which is not braille ASCII.")
        // A UTF-8 sequence cut short at the end of the file is a byte that
        // begins no character: eight-bit computer braille too.
        XCTAssertEqual(refusal(of: [0x41, 0xC3]), .eightBitBraille)
    }

    /// White space, format characters, and combining marks are named by
    /// their code, since a quoted one shows as nothing or joins its neighbour.
    func testUnseenCharactersAreNamedByTheirCode() {
        // A no-break space (Zs), a zero-width space (Cf), a byte order mark
        // inside the file (Cf), and a line separator (Zl).
        XCTAssertEqual(refusal(of: Array("A\u{A0}".utf8))?.errorDescription,
                       "Line 1 holds the character U+00A0, which is not braille ASCII.")
        XCTAssertEqual(refusal(of: Array("A\nB\u{200B}".utf8))?.errorDescription,
                       "Line 2 holds the character U+200B, which is not braille ASCII.")
        XCTAssertEqual(refusal(of: Array("A\u{FEFF}".utf8))?.errorDescription,
                       "Line 1 holds the character U+FEFF, which is not braille ASCII.")
        XCTAssertEqual(refusal(of: Array("A\u{2028}".utf8))?.errorDescription,
                       "Line 1 holds the character U+2028, which is not braille ASCII.")
        // A combining acute (Mn) after a letter, which would join the quote.
        XCTAssertEqual(refusal(of: Array("A\u{301}".utf8))?.errorDescription,
                       "Line 1 holds the character U+0301, which is not braille ASCII.")
        // A printable character keeps its quotes, and a control character its words.
        XCTAssertEqual(refusal(of: Array("A\u{2603}".utf8))?.errorDescription,
                       "Line 1 holds “\u{2603}”, which is not braille ASCII.")
        XCTAssertEqual(refusal(of: Array("A\u{07}".utf8))?.errorDescription,
                       "Line 1 holds the control character U+0007, which is not braille ASCII.")
    }

    /// The blank braille pattern, which shows as nothing in quotes and as an
    /// empty cell on a braille display, is named by its code, in North
    /// American Braille ASCII and Eurobraille alike, while any other pattern
    /// keeps its quotes: a file of Unicode braille patterns read in another
    /// code often begins with a blank cell.
    func testTheBlankBraillePatternIsNamedByItsCode() {
        XCTAssertEqual(refusal(of: Array("\u{2800}\u{2801}".utf8))?.errorDescription,
                       "Line 1 holds the character U+2800, which is not braille ASCII.")
        XCTAssertEqual(refusal(of: Array("A\n\u{2800}".utf8), in: .eurobraille)?.errorDescription,
                       "Line 2 holds the character U+2800, which is not Eurobraille.")
        XCTAssertEqual(refusal(of: Array("\u{2801}".utf8))?.errorDescription,
                       "Line 1 holds “\u{2801}”, which is not braille ASCII.")
    }

    /// A UTF-8 byte order mark at the very start is dropped, in a BRF and a BRL.
    func testAByteOrderMarkAtTheStartIsDropped() throws {
        let mark: [UInt8] = [0xEF, 0xBB, 0xBF]
        let text = Array(",PRIDE\nAND\n".utf8)
        for kind in [BrailleFileKind.brf, .brl] {
            let plain = try BrailleFileReader.pages(fromASCII: Data(text), kind: kind)
            let marked = try BrailleFileReader.pages(fromASCII: Data(mark + text), kind: kind)
            XCTAssertEqual(marked, plain, "\(kind)")
            XCTAssertEqual(marked.pages.first?.first, cells(",PRIDE"))
        }
        // A mark anywhere else is a refusal, on the line it is on.
        XCTAssertEqual(refusal(of: Array("A\n".utf8) + mark)?.errorDescription,
                       "Line 2 holds the character U+FEFF, which is not braille ASCII.")
    }

    /// Lines are counted by line ends, CR LF, LF, and lone CR each once, and
    /// a form feed does not start a line.
    func testTheRefusedLineIsCountedByLineEnds() {
        XCTAssertEqual(refusal(of: Array("A\r\nB\rC\nD\u{07}".utf8)),
                       .notBrailleASCII(.controlCharacter(7), line: 4))
        XCTAssertEqual(refusal(of: Array("A\u{0C}B\n\u{07}".utf8)),
                       .notBrailleASCII(.controlCharacter(7), line: 2))
        // BRL refuses alike.
        XCTAssertEqual(refusal(of: Array("A\n\u{07}".utf8), kind: .brl),
                       .notBrailleASCII(.controlCharacter(7), line: 2))
    }

    /// The PEF sentences, exactly.
    func testThePEFSentences() {
        XCTAssertEqual(BrailleFileError.damagedPEF.errorDescription,
                       "This file could not be read as a PEF braille file. It may be damaged, or another kind of file.")
        XCTAssertEqual(BrailleFileError.eightDotBraille.errorDescription,
                       "This file is eight-dot braille, which TextMouth does not read.")
    }

    // MARK: - The Compact Form

    /// The pages are three flat arrays: each cell a byte of its dots, where
    /// each row ends, and the rows in the pages up to and including each page.
    func testThePagesAreKeptAsCellBytesAndOffsets() throws {
        // A, B, and a blank row; then C; two form feeds make an empty page between.
        let result = try BrailleFileReader.pages(fromASCII: Data("AB\n\nC\u{0C}\u{0C}D".utf8), kind: .brf)
        XCTAssertEqual(result.cells, [0x01, 0x03, 0x09, 0x19])
        XCTAssertEqual(result.rowEnds, [2, 2, 3, 4])
        XCTAssertEqual(result.pageEnds, [3, 3, 4])
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertEqual(result.rowCount, 4)
        XCTAssertEqual(result.rows(ofPage: 1), 3..<3)
        XCTAssertEqual(result.cellRange(ofRow: 2), 2..<3)
        XCTAssertEqual(result.pages, [[cells("AB"), "", cells("C")], [], [cells("D")]])
        // An index past the end is an empty range, not a trap.
        XCTAssertEqual(result.rows(ofPage: 3), 0..<0)
        XCTAssertEqual(result.cellRange(ofRow: 4), 0..<0)
    }

    /// Pages made of text keep the blank cells, and a scalar that is no
    /// braille pattern becomes the cell of all eight dots.
    func testPagesMadeOfTextKeepTheirRows() {
        let rows = ["\u{2801}\u{2800}\u{2803}\u{2800}", "", "\u{283F}"]
        let made = BrailleFilePages(kind: .pef, pages: [rows, []])
        XCTAssertEqual(made.pages, [rows, []])
        XCTAssertEqual(made.cells, [0x01, 0x00, 0x03, 0x00, 0x3F])
        XCTAssertEqual(BrailleFilePages(kind: .brf, pages: [["A"]]).cells, [0xFF])
    }

    // MARK: - The Limits

    /// More than 100,000 pages are refused with exactly this sentence; 100,000 are read.
    func testMoreThanOneHundredThousandPagesAreRefused() throws {
        let sentence = "This file has more than 100,000 braille pages, the most TextMouth reads."
        XCTAssertEqual(BrailleFileError.tooManyPages.errorDescription, sentence)
        XCTAssertEqual(BrailleFilePages.maxPages, 100_000)
        // Each "A" and form feed is a page.
        let hundredThousand = try BrailleFileReader.pages(
            fromASCII: Data(repeating("A\u{0C}", 100_000)), kind: .brf)
        XCTAssertEqual(hundredThousand.pageCount, 100_000)
        let tooMany = refusal(of: repeating("A\u{0C}", 100_001))
        XCTAssertEqual(tooMany, .tooManyPages)
        XCTAssertEqual(tooMany?.errorDescription, sentence)
    }

    /// More than 4,000,000 rows are refused with exactly this sentence; 4,000,000 are read
    /// (as a BRL, which is one page), and a BRF with no form feed is cut into pages of 25,
    /// so 2,500,001 rows of it are past the pages' limit.
    func testMoreThanFourMillionRowsAreRefused() throws {
        let sentence = "This file has more than 4,000,000 lines of braille, the most TextMouth reads."
        XCTAssertEqual(BrailleFileError.tooManyRows.errorDescription, sentence)
        XCTAssertEqual(BrailleFilePages.maxRows, 4_000_000)
        let fourMillion = try BrailleFileReader.pages(
            fromASCII: Data([UInt8](repeating: 0x0A, count: 4_000_000)), kind: .brl)
        XCTAssertEqual(fourMillion.rowCount, 4_000_000)
        XCTAssertEqual(fourMillion.pageCount, 1)
        let tooMany = refusal(of: [UInt8](repeating: 0x0A, count: 4_000_001), kind: .brl)
        XCTAssertEqual(tooMany, .tooManyRows)
        XCTAssertEqual(tooMany?.errorDescription, sentence)
        // The same lines as a BRF cut into pages of 25 run past the pages' limit first.
        XCTAssertEqual(refusal(of: [UInt8](repeating: 0x0A, count: 2_500_001)), .tooManyPages)
    }

    /// A PEF with more than 100,000 pages is refused as a BRF is.
    func testAPEFWithTooManyPagesIsRefused() {
        let pages = String(repeating: "<page/>", count: 100_001)
        XCTAssertEqual(pefRefusal(pef("<volume><section>\(pages)</section></volume>")), .tooManyPages)
        let enough = String(repeating: "<page/>", count: 100_000)
        XCTAssertNil(pefRefusal(pef("<volume><section>\(enough)</section></volume>")))
    }

    // MARK: - PEF

    /// A file that is not XML, a root of another name or namespace, a row
    /// outside a page, and a row holding a letter are damaged.
    func testDamagedPEFFilesAreRefused() {
        XCTAssertEqual(pefRefusal(Data("not xml at all".utf8)), .damagedPEF)
        XCTAssertEqual(pefRefusal(Data()), .damagedPEF)
        XCTAssertEqual(pefRefusal(pef("", root: "book")), .damagedPEF)
        XCTAssertEqual(pefRefusal(pef("", namespace: "http://example.com/other")), .damagedPEF)
        XCTAssertEqual(pefRefusal(pef("<volume><section><row>⠁</row></section></volume>")), .damagedPEF)
        XCTAssertEqual(pefRefusal(pef(pages: [["⠁A"]])), .damagedPEF)
        // An XML error after good rows still refuses the file.
        XCTAssertEqual(pefRefusal(Data("<pef xmlns=\"http://www.daisy.org/ns/2008/pef\"><body>".utf8)),
                       .damagedPEF)
    }

    /// A row holding dot 7 or 8 is eight-dot braille.
    func testEightDotRowsAreRefused() {
        XCTAssertEqual(pefRefusal(pef(pages: [["⠁⡁"]])), .eightDotBraille)
        XCTAssertEqual(pefRefusal(pef(pages: [["\u{2841}"]])), .eightDotBraille)
        // U+283F, the last six-dot cell, is fine.
        XCTAssertNil(pefRefusal(pef(pages: [["\u{283F}"]])))
    }

    /// White space inside a row is ignored, and an empty row is "".
    func testWhiteSpaceInARowIsIgnored() throws {
        let data = pef("<volume><section><page><row> ⠁ \n\t⠃\r\n </row><row/><row></row></page></section></volume>")
        XCTAssertEqual(try BrailleFileReader.pages(fromPEF: data).pages, [["⠁⠃", "", ""]])
    }

    /// Two volumes with a section each give their pages in order, and a
    /// PEF with no page gives none.
    func testPEFVolumesGiveTheirPagesInOrder() throws {
        let data = pef("""
        <volume><section><page><row>⠁</row></page><page><row>⠃</row></page></section></volume>
        <volume><section><page><row>⠉</row></page></section></volume>
        """)
        XCTAssertEqual(try BrailleFileReader.pages(fromPEF: data).pages, [["⠁"], ["⠃"], ["⠉"]])
        XCTAssertEqual(try BrailleFileReader.pages(fromPEF: pef("<volume><section/></volume>")).pages, [])
    }

    /// A volume's `cols` is kept as the PEF's line width when it is a whole
    /// number from 18 to 80; the sample declares 40.
    func testAVolumesColsIsKeptAsTheLineWidth() throws {
        let sample = try BrailleFileReader.read(copyOfFormatSample("pef/pride-and-prejudice-ch1-grade1.pef"), as: .pef)
        XCTAssertEqual(sample.lineWidth, 40)
        for (cols, expected) in [("18", 18), ("32", 32), ("80", 80), ("040", 40)] {
            let data = pef("<volume cols=\"\(cols)\"><section><page><row>⠁</row></page></section></volume>")
            XCTAssertEqual(try BrailleFileReader.pages(fromPEF: data).lineWidth, expected, cols)
        }
    }

    /// A `cols` that is missing, outside the range, or not a whole number
    /// written in digits is ignored (the attribute is untrusted), and a BRF
    /// or BRL declares no width.
    func testAnUnusableColsGivesNoLineWidth() throws {
        let values = ["", "17", "81", "0", "1000", "-40", "+40", " 40", "40 ", "4e1", "40.0", "٤٠", "forty",
                      "99999999999999999999"]
        for cols in values {
            let data = pef("<volume cols=\"\(cols)\"><section><page><row>⠁</row></page></section></volume>")
            XCTAssertNil(try BrailleFileReader.pages(fromPEF: data).lineWidth, "cols=\"\(cols)\"")
        }
        XCTAssertNil(try BrailleFileReader.pages(fromPEF: pef(pages: [["⠁"]])).lineWidth)
        XCTAssertNil(try BrailleFileReader.pages(fromASCII: Data("A\r\n".utf8), kind: .brf).lineWidth)
        XCTAssertNil(try BrailleFileReader.pages(fromASCII: Data("A\r\n".utf8), kind: .brl).lineWidth)
    }

    /// Of several volumes the first one with a usable `cols` gives the width,
    /// and a `cols` on any other element is not the volume's.
    func testTheFirstUsableVolumeColsGivesTheLineWidth() throws {
        let data = pef("""
        <volume cols="7"><section cols="30"><page><row>⠁</row></page></section></volume>
        <volume cols="24"><section><page><row>⠃</row></page></section></volume>
        <volume cols="50"><section><page><row>⠉</row></page></section></volume>
        """)
        XCTAssertEqual(try BrailleFileReader.pages(fromPEF: data).lineWidth, 24)
    }

    /// The metadata is the first of each Dublin Core element, trimmed, and
    /// nil when it is empty or absent.
    func testPEFMetadataIsTrimmedAndTheFirstOfEach() throws {
        let head = """
        <dc:title>  First
         </dc:title><dc:title>Second</dc:title><dc:creator>   </dc:creator>
        <dc:subject>Ignored</dc:subject>
        """
        let result = try BrailleFileReader.pages(fromPEF: pef("", head: head))
        XCTAssertEqual(result.title, "First")
        XCTAssertNil(result.author)
        XCTAssertNil(result.language)
    }

    /// `pefMetadata(of:)` never throws: a missing, empty, or other file
    /// gives three nils, and it reads the head of a file whose rest is cut.
    func testPEFMetadataOfUnreadableFilesIsNil() throws {
        let folder = try makeSandboxDirectory("BrailleMetadata")
        let missing = BrailleFileReader.pefMetadata(of: folder.appendingPathComponent("none.pef"))
        XCTAssertNil(missing.title)
        XCTAssertNil(missing.author)
        XCTAssertNil(missing.language)

        let other = folder.appendingPathComponent("other.pef")
        try Data("plain text".utf8).write(to: other)
        let none = BrailleFileReader.pefMetadata(of: other)
        XCTAssertNil(none.title)
        XCTAssertNil(none.language)

        let cut = folder.appendingPathComponent("cut.pef")
        let whole = pef("", head: "<dc:title>Cut Book</dc:title><dc:creator>Writer</dc:creator>")
        try whole.prefix(whole.count - 20).write(to: cut)
        XCTAssertEqual(BrailleFileReader.pefMetadata(of: cut).title, "Cut Book")
        XCTAssertEqual(BrailleFileReader.pefMetadata(of: cut).author, "Writer")
    }

    // MARK: - Reading a File

    /// An empty file has no text, and a file past the byte limit is too large.
    func testReadRefusesAnEmptyFileAndATooLargeOne() throws {
        let folder = try makeSandboxDirectory("BrailleRead")
        let empty = folder.appendingPathComponent("empty.brf")
        try Data().write(to: empty)
        XCTAssertThrowsError(try BrailleFileReader.read(empty, as: .brf)) { error in
            guard case FileImportError.noTextToRead = error else {
                return XCTFail("Expected noTextToRead, got \(error).")
            }
        }

        let long = folder.appendingPathComponent("long.brf")
        try Data("ABCDEFGHIJKLMNOP".utf8).write(to: long)
        try DocumentByteLimit.$current.withValue(10) {
            XCTAssertThrowsError(try BrailleFileReader.read(long, as: .brf)) { error in
                XCTAssertTrue(error is DocumentTooLargeError)
            }
        }
    }

    // MARK: - Braille File Codes

    /// The refusals the braille file codes add, exactly, beside North
    /// American Braille ASCII's own, whose words are unchanged.
    func testTheBrailleFileCodeSentences() {
        XCTAssertEqual(BrailleFileError.notBrailleASCII(.character("é"), line: 3).errorDescription,
                       "Line 3 holds “é”, which is not braille ASCII.")
        XCTAssertEqual(BrailleFileError.notInFileCode(.character("é"), line: 3, characters: "Eurobraille")
                        .errorDescription,
                       "Line 3 holds “é”, which is not Eurobraille.")
        XCTAssertEqual(BrailleFileError.eightBitBraille.errorDescription,
                       "This file looks like eight-bit computer braille, which TextMouth does not read.")
        XCTAssertEqual(BrailleFileError.unknownFileCode("x-code").errorDescription,
                       "TextMouth has no braille file characters named “x-code”.")
    }

    /// A file of Eurobraille bytes reads as the same cells as the North
    /// American Braille ASCII bytes of the same cells, the 64 six-dot cells
    /// in order, and each code reads its other written form alike:
    /// Eurobraille its capitals, and North American Braille ASCII its
    /// lowercase.
    func testEurobrailleReadsAsTheSameCellsAsNorthAmericanBrailleASCII() throws {
        let northAmerican = everyCell(in: .northAmerican)
        let eurobraille = everyCell(in: .eurobraille)
        // The codes write most cells with other characters, so reading them
        // alike means something.
        XCTAssertNotEqual(eurobraille, northAmerican)
        let read = try pages(of: northAmerican, in: .northAmerican)
        XCTAssertEqual(read.cells, sixDotCells)
        XCTAssertEqual(try pages(of: eurobraille, in: .eurobraille), read)

        // Eurobraille's capitals form writes each of its characters 0x60 to
        // 0x7E 0x20 lower; North American Braille ASCII's lowercase form
        // writes each of its characters 0x40 to 0x5E 0x20 higher.
        let capitals = eurobraille.map { (0x60...0x7E).contains($0) ? $0 - 0x20 : $0 }
        let lowercase = northAmerican.map { (0x40...0x5E).contains($0) ? $0 + 0x20 : $0 }
        XCTAssertNotEqual(capitals, eurobraille)
        XCTAssertNotEqual(lowercase, northAmerican)
        XCTAssertEqual(try pages(of: capitals, in: .eurobraille), read)
        XCTAssertEqual(try pages(of: lowercase, in: .northAmerican), read)
    }

    /// Both seven-bit codes read every printable character, 0x20 to 0x7E.
    /// They differ on DEL, which Eurobraille reads as dots 4-5-6 and North
    /// American Braille ASCII refuses in today's words. Eurobraille refuses
    /// a control character, BEL, and a letter that is no braille by its own
    /// name.
    func testEurobrailleReadsDELAndRefusesByItsName() throws {
        let printable = Array(UInt8(0x20)...UInt8(0x7E))
        for code in [BrailleFileCode.northAmerican, .eurobraille] {
            XCTAssertEqual(try pages(of: printable, in: code).cells.count, printable.count, code.id)
        }

        XCTAssertEqual(try pages(of: [0x7F], in: .eurobraille).pages, [["\u{2838}"]])
        let delete = refusal(of: [0x7F], in: .northAmerican)
        XCTAssertEqual(delete, .notBrailleASCII(.controlCharacter(0x7F), line: 1))
        XCTAssertEqual(delete?.errorDescription,
                       "Line 1 holds the control character U+007F, which is not braille ASCII.")

        let bell = refusal(of: [0x07], in: .eurobraille)
        XCTAssertEqual(bell, .notInFileCode(.controlCharacter(7), line: 1, characters: "Eurobraille"))
        XCTAssertEqual(bell?.errorDescription,
                       "Line 1 holds the control character U+0007, which is not Eurobraille.")
        let letter = refusal(of: Array("a\r\nb\r\n,é".utf8), in: .eurobraille)
        XCTAssertEqual(letter, .notInFileCode(.character("é"), line: 3, characters: "Eurobraille"))
        XCTAssertEqual(letter?.errorDescription, "Line 3 holds “é”, which is not Eurobraille.")
    }

    /// A byte above 0x7F that begins no UTF-8 character is eight-bit
    /// computer braille in either seven-bit code, refused with that sentence.
    func testAByteThatBeginsNoUTF8IsEightBitBrailleInASevenBitCode() {
        for code in [BrailleFileCode.northAmerican, .eurobraille] {
            let refused = refusal(of: [0xE9], in: code)
            XCTAssertEqual(refused, .eightBitBraille, code.id)
            XCTAssertEqual(refused?.errorDescription,
                           "This file looks like eight-bit computer braille, which TextMouth does not read.",
                           code.id)
        }
    }

    /// Unicode braille patterns read as their cells, the 64 six-dot cells in
    /// order, and a blank cell written U+2800 or as a space reads alike.
    func testUnicodeBraillePatternsReadAsTheirCells() throws {
        let patterns = String(String.UnicodeScalarView(
            sixDotCells.compactMap { Unicode.Scalar(0x2800 + UInt32($0)) }))
        XCTAssertEqual(try pages(of: Array(patterns.utf8), in: .unicode).cells, sixDotCells)

        let blanksAsPatterns = try pages(of: Array("⠁⠀⠃⠀".utf8), in: .unicode)
        XCTAssertEqual(blanksAsPatterns.pages, [["⠁⠀⠃⠀"]])
        XCTAssertEqual(try pages(of: Array("⠁ ⠃ ".utf8), in: .unicode), blanksAsPatterns)
    }

    /// Line ends (CR LF, LF, and CR), form feeds, tabs, a leading byte order
    /// mark, and a final Ctrl-Z are read in Unicode braille patterns as in a
    /// seven-bit file: the same text in both codes gives the same pages, in a
    /// BRF and in a BRL.
    func testUnicodeBraillePatternsKeepTheLinesAndPagesOfASevenBitFile() throws {
        let northAmerican = "\u{FEFF}A B\r\nC\tD\n\rE\u{0C}F\r\n\u{0C}\u{0C}G H\nI\u{1A}"
        let unicode = "\u{FEFF}⠁⠀⠃\r\n⠉\t⠙\n\r⠑\u{0C}⠋\r\n\u{0C}\u{0C}⠛ ⠓\n⠊\u{1A}"
        // As a BRF, the form feeds between text end four pages; a BRL is one.
        let rowsOfPagesByKind: [(kind: BrailleFileKind, rowsOfPages: [Int])] = [(.brf, [4, 1, 0, 2]), (.brl, [6])]
        for (kind, rowsOfPages) in rowsOfPagesByKind {
            let expected = try pages(of: Array(northAmerican.utf8), kind: kind, in: .northAmerican)
            XCTAssertEqual(expected.pages.map(\.count), rowsOfPages, "\(kind)")
            XCTAssertEqual(try pages(of: Array(unicode.utf8), kind: kind, in: .unicode), expected, "\(kind)")
        }
    }

    /// In Unicode braille patterns a pattern with dot 7 or 8 is eight-dot
    /// braille. A letter, a lead byte with no pattern after it, a pattern
    /// cut off by the end of the file, and a byte that begins no UTF-8
    /// character are each refused on their line, by name.
    func testUnicodeBraillePatternsRefuseEightDotsAndOtherCharacters() {
        let eightDots = refusal(of: Array("⠁\n⠃\u{2841}".utf8), in: .unicode)
        XCTAssertEqual(eightDots, .eightDotBraille)
        XCTAssertEqual(eightDots?.errorDescription, "This file is eight-dot braille, which TextMouth does not read.")
        XCTAssertEqual(refusal(of: Array("\u{28FF}".utf8), in: .unicode), .eightDotBraille)

        let letter = refusal(of: Array("⠁\n⠃A".utf8), in: .unicode)
        XCTAssertEqual(letter, .notInFileCode(.character("A"), line: 2, characters: "a Unicode braille pattern"))
        XCTAssertEqual(letter?.errorDescription, "Line 2 holds “A”, which is not a Unicode braille pattern.")
        // A character of the patterns' own three-byte block is named too.
        XCTAssertEqual(refusal(of: Array("⠁•".utf8), in: .unicode)?.errorDescription,
                       "Line 1 holds “•”, which is not a Unicode braille pattern.")

        // A lead byte with a line end after it, and one that ends the file.
        XCTAssertEqual(refusal(of: [0xE2] + Array("\n⠃".utf8), in: .unicode)?.errorDescription,
                       "Line 1 holds the byte 0xE2, which is not a Unicode braille pattern.")
        XCTAssertEqual(refusal(of: Array("⠁\n".utf8) + [0xE2], in: .unicode)?.errorDescription,
                       "Line 2 holds the byte 0xE2, which is not a Unicode braille pattern.")
        // A pattern whose last byte the end of the file cuts off.
        let cutOff = refusal(of: Array("⠁\n\n".utf8) + [0xE2, 0xA0], in: .unicode)
        XCTAssertEqual(cutOff, .notInFileCode(.byte(0xE2), line: 3, characters: "a Unicode braille pattern"))
        XCTAssertEqual(cutOff?.errorDescription,
                       "Line 3 holds the byte 0xE2, which is not a Unicode braille pattern.")
        // A byte that begins no UTF-8 character is named: a file of patterns
        // is UTF-8, so it is no eight-bit braille.
        let byte = refusal(of: Array("⠁\n".utf8) + [0xE9], in: .unicode)
        XCTAssertEqual(byte, .notInFileCode(.byte(0xE9), line: 2, characters: "a Unicode braille pattern"))
        XCTAssertEqual(byte?.errorDescription,
                       "Line 2 holds the byte 0xE9, which is not a Unicode braille pattern.")
    }

    /// Unicode braille patterns are a certain code when a file's first
    /// character, after a byte order mark at the start, line ends, form
    /// feeds, tabs, and spaces, is a pattern, six-dot or eight-dot. Nothing
    /// else is certain: a seven-bit code's character first, nothing at all,
    /// only blank lines, a pattern cut off at the end, or a byte order mark
    /// that is not at the start.
    func testOnlyUnicodeBraillePatternsAreACertainCode() {
        // The certain code of a prefix holding `bytes`.
        func certainCode(_ bytes: [UInt8]) -> BrailleFileCode? {
            BrailleFileReader.certainCode(of: Data(bytes))
        }
        XCTAssertEqual(certainCode(Array("⠠⠏⠗⠊⠙⠑".utf8)), .unicode)
        XCTAssertEqual(certainCode(Array("⠀⠁".utf8)), .unicode)
        XCTAssertEqual(certainCode([0xEF, 0xBB, 0xBF] + Array("\r\n\n\r \t\u{0C}⠁A".utf8)), .unicode)
        XCTAssertEqual(certainCode(Array("\u{2841}⠁".utf8)), .unicode)

        XCTAssertNil(certainCode(Array(",PRIDE AND ,PREJUDICE\r\n".utf8)))
        XCTAssertNil(certainCode(everyCell(in: .eurobraille)))
        // Every character of North American Braille ASCII and Eurobraille,
        // DEL too, decides alone, whatever follows it.
        for byte in UInt8(0x21)...UInt8(0x7F) {
            XCTAssertNil(certainCode([byte] + Array("⠁⠃".utf8)), "byte \(byte)")
        }
        XCTAssertNil(certainCode([]))
        XCTAssertNil(certainCode(Array("\r\n\r\n \t\u{0C}".utf8)))
        XCTAssertNil(certainCode(Array("\n".utf8) + [0xE2, 0xA0]))
        XCTAssertNil(certainCode(Array("\n\u{FEFF}⠁".utf8)))
    }

    /// `certainCode(ofFileAt:)` reads a file's first 65,536 bytes only: a
    /// pattern whose last byte is the 65,536th is read, and one a byte later
    /// is cut off. A file of North American Braille ASCII, an empty file,
    /// and a missing one give nil.
    func testTheCertainCodeOfAFileIsReadFromItsFirstBytes() throws {
        XCTAssertEqual(BrailleFileReader.detectionByteCount, 65_536)
        let folder = try makeSandboxDirectory("BrailleCertainCode")
        // The certain code of a file named `name` in the folder, holding `bytes`.
        func certainCode(_ bytes: [UInt8], named name: String) throws -> BrailleFileCode? {
            let url = folder.appendingPathComponent(name)
            try Data(bytes).write(to: url)
            return BrailleFileReader.certainCode(ofFileAt: url)
        }
        XCTAssertEqual(try certainCode(Array("\r\n⠠⠏⠗⠊⠙⠑\r\n".utf8), named: "patterns.brf"), .unicode)
        XCTAssertNil(try certainCode(Array(",PRIDE\r\n".utf8), named: "ascii.brf"))
        XCTAssertNil(try certainCode([], named: "empty.brf"))

        let blankLines = [UInt8](repeating: 0x0A, count: 65_536 - 3)
        XCTAssertEqual(try certainCode(blankLines + Array("⠁".utf8), named: "fits.brf"), .unicode)
        XCTAssertNil(try certainCode(blankLines + [0x0A] + Array("⠁".utf8), named: "cut.brf"))
        XCTAssertNil(BrailleFileReader.certainCode(ofFileAt: folder.appendingPathComponent("missing.brf")))
    }
}
