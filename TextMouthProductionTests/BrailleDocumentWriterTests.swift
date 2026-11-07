import XCTest
@testable import TextMouth

/// Tests for `BrailleDocumentWriter` (FMT22, Phase A) with the real liblouis
/// helper: the print blocks of the Pride and Prejudice and Grade 2 samples
/// written as pages, a BRF, and a PEF, compared with the samples' own
/// braille but for liblouis's two named differences. Every call must leave
/// its working folder empty.
final class BrailleDocumentWriterTests: XCTestCase {
    /// The folder the helper's hidden files are made in; every call must
    /// leave it empty.
    private var work = URL(fileURLWithPath: "/var/empty", isDirectory: true)  // replaced in setUp

    /// What the PEF sample says about its book.
    private let sampleMetadata = PEFMetadata(
        title: "Pride and Prejudice, Chapter I (Grade 1 UEB sample)",
        author: "Jane Austen",
        language: "en",
        identifier: "urn:uuid:5b0a3f6e-6c1d-4a35-9d57-0e2f6a1b7c10",
        date: "2026-10-17"
    )

    override func setUpWithError() throws {
        work = try makeSandboxDirectory("BrailleWriterWork")
    }

    // MARK: - Helpers

    /// Asserts that the working folder holds nothing, hidden files included.
    private func assertWorkFolderEmpty(file: StaticString = #filePath, line: UInt = #line) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? ["<unreadable>"]
        XCTAssertEqual(names, [], file: file, line: line)
    }

    /// The text of the format sample at `path`, read from a copy of it.
    private func sampleText(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: copyOfFormatSample(path)), as: UTF8.self)
    }

    /// The cells braille ASCII `ascii` stands for (a space is the blank cell).
    private func cells(_ ascii: String) throws -> String {
        var result = String.UnicodeScalarView()
        for byte in ascii.utf8 {
            result.append(try XCTUnwrap(BrailleCells.cell(forASCII: byte), "no cell for byte \(byte)"))
        }
        return String(result)
    }

    /// The Grade 1 sample's 14 blocks made of `texts`: the title (a level-1
    /// heading), the chapter heading (level 2), then 12 paragraphs.
    private func sampleBlocks(_ texts: [String]) -> [BrailleBlock] {
        texts.enumerated().map { index, text in
            switch index {
            case 0: return .heading(level: 1, text: text)
            case 1: return .heading(level: 2, text: text)
            default: return .paragraph(text: text)
            }
        }
    }

    /// The 14 print blocks of the Grade 1 sample, split at blank lines.
    private func printBlocks() throws -> [BrailleBlock] {
        let texts = try sampleText("brf/pride-and-prejudice-ch1.txt")
            .trimmingCharacters(in: .newlines)
            .components(separatedBy: "\n\n")
        XCTAssertEqual(texts.count, 14)
        return sampleBlocks(texts)
    }

    /// The BRL sample's 14 lines as braille blocks, with the two differences
    /// that are liblouis's own made in them. First: a question mark at a
    /// word's end is the cell for 8 alone in liblouis, where the sample has
    /// ;8 (three times in the BRL lines, so ";8" becomes "8"). Second: the
    /// underscores of _You_ (Project Gutenberg's mark for italics) are
    /// characters to liblouis, each written as the underscore sign (.-),
    /// where the sample has the italic word indicator (.1) before the word
    /// (the BRL line of the 10th block, so ".1,YOU" becomes ".-,YOU.-").
    private func expectedBrailleBlocks() throws -> [BrailleBlock] {
        let lines = try sampleText("brl/pride-and-prejudice-ch1-grade1.brl").components(separatedBy: "\r\n")
        let kept = Array(lines.dropLast(lines.last == "" ? 1 : 0))  // the empty string after the last CR LF
        XCTAssertEqual(kept.count, 14)
        let converted = try kept.map {
            try cells($0.replacingOccurrences(of: ";8", with: "8").replacingOccurrences(of: ".1,YOU", with: ".-,YOU.-"))
        }
        return sampleBlocks(converted)
    }

    /// The Grade 2 sample's three print sentences, one paragraph each.
    private func grade2Blocks() throws -> [BrailleBlock] {
        let lines = try sampleText("brf/grade2-short.txt").components(separatedBy: "\n")
        return lines.filter { !$0.isEmpty }.map { .paragraph(text: $0) }
    }

    /// The Grade 2 sample's three rows, the first three lines of its BRF, as
    /// cells.
    private func grade2Rows() throws -> [String] {
        let lines = try sampleText("brf/grade2-short.brf").components(separatedBy: "\r\n")
        XCTAssertGreaterThanOrEqual(lines.count, 3)
        return try lines.prefix(3).map(cells)
    }

    /// `pages(of:)` with the working folder checked for leftovers.
    private func pages(
        _ blocks: [BrailleBlock], _ options: BrailleExportOptions, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [[String]] {
        defer { assertWorkFolderEmpty(file: file, line: line) }
        return try BrailleDocumentWriter.pages(of: blocks, options: options, workingIn: work)
    }

    /// Options at the defaults, with the table `table`.
    private func options(_ table: String) -> BrailleExportOptions {
        BrailleExportOptions(table: table)
    }

    // MARK: - Grade 1 Against the Samples

    /// Grade 1: the BRF is the sample's file but for liblouis's two named
    /// differences (see `expectedBrailleBlocks`), laid out and written the
    /// same way.
    func testGrade1BRFMatchesTheSampleButForTheTwoNamedDifferences() throws {
        let options = options("en-ueb-g1.ctb")
        XCTAssertEqual(options.page, BraillePageFormat())
        XCTAssertEqual(options.lineEnd, .crlf)
        let expected = try BrailleFileWriter.brf(
            pages: BrailleLayout.pages(of: try expectedBrailleBlocks(), format: options.page), lineEnd: .crlf
        )

        let result = try BrailleDocumentWriter.brf(of: try printBlocks(), options: options, workingIn: work)
        assertWorkFolderEmpty()
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result, expected)
        // Two pages, so one form feed.
        XCTAssertEqual(result.filter { $0 == 0x0C }.count, 1)
    }

    /// Grade 1: the PEF is the one built the same way, under the sample's
    /// metadata.
    func testGrade1PEFMatchesTheSampleButForTheTwoNamedDifferences() throws {
        let options = options("en-ueb-g1.ctb")
        let expected = try BrailleFileWriter.pef(
            pages: BrailleLayout.pages(of: try expectedBrailleBlocks(), format: options.page),
            metadata: sampleMetadata,
            format: options.page
        )

        let result = try BrailleDocumentWriter.pef(
            of: try printBlocks(), metadata: sampleMetadata, options: options, workingIn: work
        )
        assertWorkFolderEmpty()
        XCTAssertEqual(result, expected)
        let text = String(decoding: result, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "<page>").count - 1, 2)
        XCTAssertTrue(text.contains(#"cols="40" rows="25""#))
    }

    // MARK: - Grade 2

    /// Grade 2: the three sentences give the BRF sample's three rows, each
    /// now in cell 3 (a paragraph's first line), and the page number at the
    /// right of the last row.
    func testGrade2PagesHoldTheSampleRowsInCellThree() throws {
        let result = try pages(try grade2Blocks(), options("en-ueb-g2.ctb"))
        XCTAssertEqual(result.count, 1)
        guard result.count == 1 else { return }
        let page = result[0]
        XCTAssertEqual(page.count, 25)
        guard page.count == 25 else { return }

        let rows = try grade2Rows()
        let indent = String(repeating: String(BrailleCells.blank), count: 2)
        for (index, row) in rows.enumerated() {
            XCTAssertEqual(BrailleCells.spaced(page[index]), BrailleCells.spaced(indent + row), "row \(index + 1)")
        }
        // The last row is the number sign and the digit 1, ending at cell 40.
        let blanks = String(repeating: String(BrailleCells.blank), count: 38)
        XCTAssertEqual(page.last, blanks + "\u{283C}\u{2801}")
    }

    // MARK: - Options

    /// 32 by 10, numbers off, LF: every row is at most 32 cells, every page
    /// has 10 rows, no page's last row is a page number, and a BRF ends its
    /// rows in LF alone.
    func testOptionsChangeTheLayoutAndTheLineEnd() throws {
        var options = options("en-ueb-g1.ctb")
        options.page = BraillePageFormat(cellsPerLine: 32, linesPerPage: 10, numbersPages: false)
        options.lineEnd = .lf

        let result = try pages(try printBlocks(), options)
        XCTAssertGreaterThan(result.count, 2)
        for (number, page) in result.enumerated() {
            XCTAssertEqual(page.count, 10, "page \(number + 1)")
            for row in page {
                XCTAssertLessThanOrEqual(row.unicodeScalars.count, 32, row)
            }
            // With numbers off the last line holds no page number.
            let last = page.last?.trimmingCharacters(in: CharacterSet(charactersIn: "\u{2800}"))
            XCTAssertNotEqual(last, BrailleLayout.pageNumberCells(number + 1), "page \(number + 1)")
        }

        let brf = try BrailleDocumentWriter.brf(of: try printBlocks(), options: options, workingIn: work)
        assertWorkFolderEmpty()
        XCTAssertFalse(brf.contains(0x0D))
        XCTAssertEqual(brf, try BrailleFileWriter.brf(pages: result, lineEnd: .lf))
    }

    /// `standard()` takes its table from the Braille setting, and holds the
    /// October 17 defaults otherwise.
    func testStandardOptionsTakeTheSettingsTable() {
        BraillePreferences.$tableForImports.withValue("en-us-g1.ctb") {
            let standard = BrailleExportOptions.standard()
            XCTAssertEqual(standard.table, "en-us-g1.ctb")
            XCTAssertEqual(standard.page.cellsPerLine, 40)
            XCTAssertEqual(standard.page.linesPerPage, 25)
            XCTAssertTrue(standard.page.numbersPages)
            XCTAssertEqual(standard.lineEnd, .crlf)
        }
    }

    /// A BRF is written in the options' braille file code (braillecodes):
    /// North American Braille ASCII by default, as every BRF was before, and
    /// Eurobraille when it is chosen, whose letters are lowercase. The two
    /// files hold the same cells; only the characters differ.
    func testABRFIsWrittenInTheOptionsBrailleFileCode() throws {
        let blocks = [BrailleBlock.paragraph(text: "Hello.")]
        var options = options("en-ueb-g1.ctb")
        XCTAssertEqual(options.fileCode, .northAmerican)
        let northAmerican = try BrailleDocumentWriter.brf(of: blocks, options: options, workingIn: work)
        options.fileCode = .eurobraille
        let eurobraille = try BrailleDocumentWriter.brf(of: blocks, options: options, workingIn: work)
        assertWorkFolderEmpty()

        // The letters of "hello", which Grade 1 never contracts, and page 1's
        // number, ⠼⠁, at the end of the page's last line.
        let northAmericanText = String(decoding: northAmerican, as: UTF8.self)
        XCTAssertTrue(northAmericanText.contains("HELLO"), northAmericanText)
        XCTAssertTrue(northAmericanText.hasSuffix("#A\r\n"), northAmericanText)
        let eurobrailleText = String(decoding: eurobraille, as: UTF8.self)
        XCTAssertTrue(eurobrailleText.contains("hello"), eurobrailleText)
        XCTAssertTrue(eurobrailleText.hasSuffix("#a\r\n"), eurobrailleText)

        // The same cells: the default file, read in North American Braille
        // ASCII and written again in each code, gives each file exactly.
        let pages = try BrailleFileReader.pages(fromText: northAmerican, kind: .brf, code: .northAmerican).pages
        XCTAssertEqual(try BrailleFileWriter.brf(pages: pages, code: .northAmerican), northAmerican)
        XCTAssertEqual(try BrailleFileWriter.brf(pages: pages, code: .eurobraille), eurobraille)
    }

    // MARK: - Kinds, Errors, and No Blocks

    /// A block keeps its kind through the translation: a paragraph starts in
    /// cell 3, a list item of depth 1 in cell 1, after the blank line that
    /// sets a list apart from the paragraph above it.
    func testBlocksKeepTheirKinds() throws {
        let result = try pages([.paragraph(text: "go"), .listItem(depth: 1, text: "go")], options("en-ueb-g2.ctb"))
        XCTAssertEqual(result.count, 1)
        guard let page = result.first, page.count == 25 else { return }
        let paragraph = Array(page[0].unicodeScalars)
        XCTAssertEqual(page[1], "", "the blank line before the list")
        let item = Array(page[2].unicodeScalars)
        XCTAssertGreaterThan(paragraph.count, 2)
        XCTAssertGreaterThan(item.count, 0)
        guard paragraph.count > 2, !item.isEmpty else { return }
        XCTAssertEqual(paragraph[0], BrailleCells.blank)
        XCTAssertEqual(paragraph[1], BrailleCells.blank)
        XCTAssertNotEqual(paragraph[2], BrailleCells.blank)
        XCTAssertNotEqual(item[0], BrailleCells.blank)
    }

    /// The translator's errors pass on unchanged, and leave the folder empty.
    func testTranslatorErrorsPassOn() throws {
        let bad = options("en-xx.ctb")
        let blocks = [BrailleBlock.paragraph(text: "Hello.")]
        XCTAssertThrowsError(try BrailleDocumentWriter.pages(of: blocks, options: bad, workingIn: work)) {
            XCTAssertEqual($0 as? BrailleTranslator.Failure, .unknownTable("en-xx.ctb"))
        }
        XCTAssertThrowsError(try BrailleDocumentWriter.brf(of: blocks, options: bad, workingIn: work)) {
            XCTAssertEqual($0 as? BrailleTranslator.Failure, .unknownTable("en-xx.ctb"))
        }
        XCTAssertThrowsError(
            try BrailleDocumentWriter.pef(of: blocks, metadata: sampleMetadata, options: bad, workingIn: work)
        ) {
            XCTAssertEqual($0 as? BrailleTranslator.Failure, .unknownTable("en-xx.ctb"))
        }
        assertWorkFolderEmpty()
    }

    // MARK: - Characters a Table Lacks, Exported and Read Back

    /// The text blocks of the book `url` imports as, with `table` as the
    /// Braille setting's table: the reader's text with the blank lines
    /// between blocks left out.
    private func importedBlocks(from url: URL, table: String) throws -> [String] {
        let book = try BraillePreferences.$tableForImports.withValue(table) {
            try importedForTest(url).book
        }
        return allText(of: try openedContent(of: book))
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// TextMouth reads back the BRF and the PEF it writes for characters a
    /// table lacks (review finding M6). With Grade 2, liblouis writes
    /// Cyrillic, Chinese, and an emoji as escapes whose backslash is the
    /// eight-dot cell U+2873; the writers write six-dot cells only, so the
    /// backslash is ⠳ in both files and neither import is refused (the PEF
    /// used to be, as eight-dot braille).
    ///
    /// The expected texts are liblouis's reading of its own escape notation,
    /// not the print: an escape is not a letter, and back-translation turns
    /// its cells into whatever the table's rules make of them. The test
    /// pins them to catch a change in either direction, and to show that
    /// both files give the same text.
    func testEscapedCharactersExportedAsBRFAndPEFAreReadBackFromBoth() throws {
        let table = "en-ueb-g2.ctb"
        // The widest page, so that no paragraph wraps: the longest, Москва,
        // is 48 cells, and a wrapped row would be read with a break in it.
        var options = options(table)
        options.page = BraillePageFormat(cellsPerLine: BraillePageFormat.cellsPerLineRange.upperBound)
        let blocks: [BrailleBlock] = ["Москва", "中文", "\u{1F642}"].map { .paragraph(text: $0) }
        let expected = [
            "'oux\"diseac''oux\"discce''oux\"dis.,''oux\"discca''oux\"disccbb''oux\".:\"'",
            "'oux.ebbd''ouxffen?\u{2032}'",
            "'ouyeaf!.be'",
        ]
        let folder = try makeSandboxDirectory("BrailleRoundTrip")

        let brfURL = folder.appendingPathComponent("escapes.brf")
        try BrailleDocumentWriter.brf(of: blocks, options: options, workingIn: work).write(to: brfURL)
        let pefURL = folder.appendingPathComponent("escapes.pef")
        try BrailleDocumentWriter.pef(of: blocks, metadata: sampleMetadata, options: options, workingIn: work)
            .write(to: pefURL)
        assertWorkFolderEmpty()

        let fromBRF = try importedBlocks(from: brfURL, table: table)
        let fromPEF = try importedBlocks(from: pefURL, table: table)
        XCTAssertEqual(fromBRF, expected)
        XCTAssertEqual(fromPEF, expected)
    }

    /// An eight-dot braille pattern in the print, as in liblouis's own NEWS
    /// line "☐ (⣏⣀⣹)", is written as its six-dot part with every bundled
    /// table, which pass braille in the print through as itself, and a
    /// noncharacter is removed: such a book exports (review F1).
    func testEightDotBrailleInThePrintExportsAsItsSixDotPart() throws {
        // liblouis's own NEWS line: a ballot box, then three eight-dot cells.
        let news = "\u{2610} (\u{28CF}\u{28C0}\u{28F9})"
        // Swift takes no noncharacter in a literal, so these are made here.
        let nonCharacters = String(String.UnicodeScalarView([0xFFFF, 0xFDD0, 0x1FFFE].compactMap(Unicode.Scalar.init)))
        XCTAssertEqual(nonCharacters.unicodeScalars.count, 3)
        XCTAssertEqual(
            BrailleDocumentWriter.printForBraille(news + nonCharacters),
            "\u{2610} (\u{280F}\u{2800}\u{2839})"
        )
        let folder = try makeSandboxDirectory("BrailleEightDotPrint")
        let blocks: [BrailleBlock] = [.paragraph(text: news), .paragraph(text: "a" + nonCharacters + "b")]
        for table in BrailleTableCatalog.bundled.map(\.id) {
            let options = BrailleExportOptions(table: table)
            let cells = try BrailleDocumentWriter.pages(of: blocks, options: options, workingIn: folder).flatMap { $0 }.joined()
            XCTAssertNil(BrailleCells.firstEightDotCell(in: cells), table)
            XCTAssertTrue(cells.contains("\u{280F}") && cells.contains("\u{2839}"), "\(table): \(cells)")
            XCTAssertNoThrow(try BrailleDocumentWriter.brf(of: blocks, options: options, workingIn: folder), table)
        }
    }

    /// Print with emphasis keeps each scalar's emphasis through
    /// `printForBraille`: a noncharacter it removes takes its emphasis with
    /// it, and an eight-dot pattern made six-dot keeps its own.
    func testPrintForBrailleKeepsEachScalarsEmphasisInStep() throws {
        let nonCharacter = String(try XCTUnwrap(Unicode.Scalar(0xFFFF)))
        let print = try XCTUnwrap(EmphasizedText("a" + nonCharacter + "\u{28CF}b", emphasis: [.italic, .bold, .bold, []]))
        let prepared = BrailleDocumentWriter.printForBraille(print)
        XCTAssertEqual(prepared.text, "a\u{280F}b")
        XCTAssertEqual(prepared.emphasis, [.italic, .bold, []])
        XCTAssertEqual(BrailleDocumentWriter.printForBraille(EmphasizedText("plain" + nonCharacter)), EmphasizedText("plain"))
    }

    /// No blocks give an empty BRF and a PEF with no page.
    func testNoBlocksGiveAnEmptyBRFAndAPEFWithoutPages() throws {
        let options = options("en-ueb-g1.ctb")
        XCTAssertEqual(try pages([], options), [])
        XCTAssertEqual(try BrailleDocumentWriter.brf(of: [] as [BrailleBlock], options: options, workingIn: work), Data())
        XCTAssertEqual(try BrailleDocumentWriter.brf(of: [] as [BraillePrintBlock], options: options, workingIn: work), Data())
        let pef = try BrailleDocumentWriter.pef(of: [] as [BraillePrintBlock], metadata: sampleMetadata, options: options, workingIn: work)
        assertWorkFolderEmpty()
        let text = String(decoding: pef, as: UTF8.self)
        XCTAssertTrue(text.contains("<pef "))
        XCTAssertFalse(text.contains("<page"))
    }
}
