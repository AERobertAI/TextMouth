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

    /// A form feed ends a page after a line end, in the middle of a line,
    /// and at the very end (adding no empty page), and two in a row make
    /// an empty page; with a form feed the pages are not cut at 25.
    func testFormFeedsEndPages() throws {
        let a = [cells("A")], b = [cells("A"), cells("B")], c = [cells("C")]
        XCTAssertEqual(try pages("A\nB\n\u{0C}C\n"), [b, c])
        XCTAssertEqual(try pages("A\nB\u{0C}C\n"), [b, c])
        XCTAssertEqual(try pages("A\n\u{0C}"), [a])
        XCTAssertEqual(try pages("A\n\u{0C}\u{0C}"), [a, []])
        XCTAssertEqual(try pages("A\n\u{0C}\u{0C}C\n"), [a, [], c])
        let thirty = String(repeating: "A\n", count: 30) + "\u{0C}"
        XCTAssertEqual(try pages(thirty).map(\.count), [30])
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

        // A lone Latin-1 é is no valid UTF-8.
        let byte = refusal(of: [0x41, 0x0A, 0x41, 0xE9])
        XCTAssertEqual(byte, .notBrailleASCII(.byte(0xE9), line: 2))
        XCTAssertEqual(byte?.errorDescription, "Line 2 holds the byte 0xE9, which is not braille ASCII.")

        // A control character past four digits keeps them all, and the DEL
        // character is a control character too.
        XCTAssertEqual(refusal(of: [0x7F])?.errorDescription,
                       "Line 1 holds the control character U+007F, which is not braille ASCII.")
        XCTAssertEqual(refusal(of: Array("A\u{85}".utf8))?.errorDescription,
                       "Line 1 holds the control character U+0085, which is not braille ASCII.")
        // A UTF-8 sequence cut short at the end of the file is a byte.
        XCTAssertEqual(refusal(of: [0x41, 0xC3]), .notBrailleASCII(.byte(0xC3), line: 1))
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
}
