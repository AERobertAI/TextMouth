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
        let expected = BrailleFileWriter.brf(
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
        let expected = BrailleFileWriter.pef(
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
        XCTAssertEqual(brf, BrailleFileWriter.brf(pages: result, lineEnd: .lf))
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

    // MARK: - Kinds, Errors, and No Blocks

    /// A block keeps its kind through the translation: a paragraph starts in
    /// cell 3, a list item of depth 1 in cell 1.
    func testBlocksKeepTheirKinds() throws {
        let result = try pages([.paragraph(text: "go"), .listItem(depth: 1, text: "go")], options("en-ueb-g2.ctb"))
        XCTAssertEqual(result.count, 1)
        guard let page = result.first, page.count == 25 else { return }
        let paragraph = Array(page[0].unicodeScalars)
        let item = Array(page[1].unicodeScalars)
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

    /// No blocks give an empty BRF and a PEF with no page.
    func testNoBlocksGiveAnEmptyBRFAndAPEFWithoutPages() throws {
        let options = options("en-ueb-g1.ctb")
        XCTAssertEqual(try pages([], options), [])
        XCTAssertEqual(try BrailleDocumentWriter.brf(of: [], options: options, workingIn: work), Data())
        let pef = try BrailleDocumentWriter.pef(of: [], metadata: sampleMetadata, options: options, workingIn: work)
        assertWorkFolderEmpty()
        let text = String(decoding: pef, as: UTF8.self)
        XCTAssertTrue(text.contains("<pef "))
        XCTAssertFalse(text.contains("<page"))
    }
}
