import XCTest
@testable import TextMouth

/// What `WordDocumentLegacyTests` and the hostile tests leave to be proven, one feature at a time, each by a
/// document that reads differently without it: cancellation partway through a long read, damaged tables that lose
/// formatting and not the document, the property modifiers of a Fast Save file (`Prm0` and `Prm1`), pages of
/// formatting that follow the last the bin table lists, the stories that have no tables, and the numbering's
/// start, text, levels, and `fPrev`.
final class WordDocumentLegacyFeatureTests: XCTestCase {

    typealias Builder = WordLegacyDocumentBuilder
    typealias Paragraph = Builder.Paragraph
    typealias Run = Builder.Run

    // MARK: - Helpers

    private func body(
        of data: Data, speaksNumbers: Bool = false, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let html = try XCTUnwrap(
            WordDocumentReader.html(from: data, includesPages: false, speaksListNumbers: speaksNumbers), file: file, line: line
        )
        let start = try XCTUnwrap(html.range(of: "<body>\n"), file: file, line: line)
        let end = try XCTUnwrap(html.range(of: "</body>"), file: file, line: line)
        return String(html[start.upperBound..<end.lowerBound])
    }

    private func body(
        _ paragraphs: [Paragraph], speaksNumbers: Bool = false, file: StaticString = #filePath, line: UInt = #line,
        configure: (inout Builder) -> Void = { _ in }
    ) throws -> String {
        var builder = Builder()
        builder.paragraphs = paragraphs
        configure(&builder)
        return try body(of: builder.build(), speaksNumbers: speaksNumbers, file: file, line: line)
    }

    /// A little-endian 16-bit number's bytes.
    private func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }

    // MARK: - Cancellation

    /// What a read asks of its cancellation check.
    private struct Stop: Error {}

    func testAReadAsksWhetherItWasCancelledAtTheStartBetweenPagesAndEveryFewThousandCharacters() throws {
        // One paragraph of 10,000 letters: 10,001 characters with its mark, so two asks in the main loop (at 4,096 and 8,192).
        var builder = Builder()
        builder.paragraphs = [Paragraph(String(repeating: "a", count: 10_000))]
        let built = builder.buildStream()
        var file = CompoundFileBuilder()
        file.streams = [("WordDocument", built.bytes)]
        var asks = 0
        _ = try WordDocumentReader.html(from: file.build().data, includesPages: false, checkCancellation: { asks += 1 })
        // The start, a page of character runs, a page of paragraph runs, and the loop.
        XCTAssertEqual(asks, 1 + built.layout.chpxPages.count + built.layout.papxPages.count + 2)
    }

    func testACancelPartwayThroughALongReadStopsItInBothLayouts() throws {
        var old = Builder()
        old.paragraphs = [Paragraph(String(repeating: "a", count: 20_000))]
        var modern = WordDocumentBuilder()
        modern.paragraphs = [WordDocumentBuilder.Paragraph(String(repeating: "a", count: 20_000))]
        for data in [old.build(), modern.build()] {
            // Not the start, and not a page: the fourth ask or later, which only the loop makes.
            var asks = 0
            XCTAssertThrowsError(try WordDocumentReader.html(from: data, includesPages: false, checkCancellation: {
                asks += 1
                if asks >= 4 { throw Stop() }
            })) { XCTAssertTrue($0 is Stop, "\($0)") }
            XCTAssertGreaterThanOrEqual(asks, 4)
        }
    }

    // MARK: - Damaged Tables

    /// The stream of `builder`'s document and where it puts the bin table of character runs (the FIB's pair at 0xB8).
    private func characterBinTable(of built: (bytes: [UInt8], layout: Builder.Layout)) -> (start: Int, length: Int) {
        let start = Int(built.bytes[0xB8]) | Int(built.bytes[0xB9]) << 8 | Int(built.bytes[0xBA]) << 16
        let length = Int(built.bytes[0xBC]) | Int(built.bytes[0xBD]) << 8
        return (start, length)
    }

    private func document(holding stream: [UInt8]) -> Data {
        var file = CompoundFileBuilder()
        file.streams = [("WordDocument", stream)]
        return file.build().data
    }

    func testABinTableThatPointsPastTheStreamLosesTheFormattingNotTheDocument() throws {
        var builder = Builder()
        builder.paragraphs = [Paragraph(runs: [Run("plain "), Run("bold", sprms: Builder.bold())])]
        var built = builder.buildStream()
        XCTAssertEqual(try body(of: document(holding: built.bytes)), "<p>plain <strong>bold</strong></p>\n")
        // The one page number, which is after the two offsets (three of them with the end) of the table.
        let table = characterBinTable(of: built)
        let count = (table.length - 4) / 6
        let pageNumber = table.start + (count + 1) * 4
        built.bytes.replaceSubrange(pageNumber..<pageNumber + 2, with: [0xFF, 0xFF])
        XCTAssertEqual(try body(of: document(holding: built.bytes)), "<p>plain bold</p>\n")
    }

    func testAStyleThatDoesNotFitItsBytesLosesThatStyleNotTheSheet() throws {
        // Heading 2 is damaged: its group claims 0x7FFF bytes. Heading 1 is still a heading, and Heading 2's paragraph is text.
        let body = try body([Paragraph("Chapter", style: 1), Paragraph("Section", style: 2)]) { $0.damagedStyle = 2 }
        XCTAssertEqual(body, "<h1>Chapter</h1>\n<p>Section</p>\n")
    }

    // MARK: - Fast Save

    /// "aaaa bbbb" in two pieces (the second holds "bbbb" and the mark), the second with the modifiers `prm`.
    private func fastSaved(prm: UInt16, groups: [[UInt8]] = []) throws -> String {
        try body([Paragraph("aaaa bbbb")]) {
            $0.isFastSaved = true
            $0.piecePrms = [0, prm]
            $0.modifierGroups = groups
        }
    }

    func testAPieceModifierOfOneSprmSetsTheTextOfItsPiece() throws {
        // Prm0: not complex (bit 0 is 0), the sprm's index (0x55, bold) in 7 bits, and its operand (1) above.
        XCTAssertEqual(try fastSaved(prm: UInt16(0x55 << 1) | 1 << 8), "<p>aaaa <strong>bbbb</strong></p>\n")
        XCTAssertEqual(try fastSaved(prm: UInt16(0x5C << 1) | 1 << 8), "<p>aaaa</p>\n")
    }

    func testAPieceModifierNamedByAnIndexIsReadInTheOldForm() throws {
        // Prm1: complex (bit 0 is 1) and the index of a group of modifiers, in the form of a property list.
        XCTAssertEqual(try fastSaved(prm: 1, groups: [Builder.bold()]), "<p>aaaa <strong>bbbb</strong></p>\n")
        XCTAssertEqual(try fastSaved(prm: 1 | 1 << 1, groups: [Builder.bold(), Builder.hidden()]), "<p>aaaa</p>\n")
        // An index that names no group has no modifiers.
        XCTAssertEqual(try fastSaved(prm: 1 | 5 << 1, groups: [Builder.bold()]), "<p>aaaa bbbb</p>\n")
    }

    func testAGroupThatHoldsTheNumberingBeforeTheTableFlagKeepsTheFlag() throws {
        // The level of the numbering (13) is a one-byte sprm, then "in a table" (24): a group read as its Word 97 form must size
        // both, or the paragraph loses its place in the table.
        let group = Builder.sprm(13, [10]) + Builder.inTable
        let body = try body([Paragraph("cell", mark: 0x07)]) {
            $0.isFastSaved = true
            $0.piecePrms = [0, 1]
            $0.modifierGroups = [group]
        }
        XCTAssertEqual(body, "<table>\n<tr><td><p>cell</p>\n</td></tr>\n</table>\n")
    }

    // MARK: - Bin Tables That Stop Short

    func testPagesOfFormattingThatFollowTheLastTheBinTableListsAreRead() throws {
        // 150 paragraphs, each with a bold word: several pages of character runs, of which the table lists the first.
        var builder = Builder()
        builder.paragraphs = (0..<150).map { _ in Paragraph(runs: [Run("word "), Run("bold", sprms: Builder.bold())]) }
        var built = builder.buildStream()
        let pages = built.layout.chpxPages.count
        XCTAssertGreaterThan(pages, 2)
        XCTAssertEqual(try body(of: document(holding: built.bytes)).components(separatedBy: "<strong>").count - 1, 150)
        // The table lists the first page alone (its two offsets, then its page number); the FIB says how many there are.
        let table = characterBinTable(of: built)
        let count = (table.length - 4) / 6
        let firstOffsets = Array(built.bytes[table.start..<table.start + 8])
        let firstPage = Array(built.bytes[table.start + (count + 1) * 4..<table.start + (count + 1) * 4 + 2])
        built.bytes.replaceSubrange(table.start..<table.start + 10, with: firstOffsets + firstPage)
        built.bytes.replaceSubrange(0xBC..<0xC0, with: [10, 0, 0, 0])
        built.bytes.replaceSubrange(0x18E..<0x190, with: le16(pages))
        XCTAssertEqual(try body(of: document(holding: built.bytes)).components(separatedBy: "<strong>").count - 1, 150)
        // Without the count, only what the first page holds is bold.
        built.bytes.replaceSubrange(0x18E..<0x190, with: le16(0))
        XCTAssertLessThan(try body(of: document(holding: built.bytes)).components(separatedBy: "<strong>").count - 1, 150)
    }

    // MARK: - Stories

    func testEndnotesAndTextBoxesFollowTheMainTextBeyondTheirNotes() throws {
        // This layout has no tables for them: each story is read whole, after the footnotes, in the order the file keeps them.
        let body = try body([Paragraph("Body")]) {
            $0.endnotes = ["End."]
            $0.textBoxes = ["Box."]
        }
        XCTAssertEqual(body, "<p>Body</p>\n<p>End.</p>\n<p>Box.</p>\n")
    }

    // MARK: - A Word 97 FIB with Word 97's Identifier

    func testAWord97DocumentWhoseNFibIsTheEmptyDocumentsIsReadAsWord97() throws {
        // Word installs an empty document with an nFib of 0xC0 and the identifier 0xA5EC; the old layout is for any other.
        var builder = WordDocumentBuilder()
        builder.paragraphs = [WordDocumentBuilder.Paragraph("This one will be fine")]
        builder.version = 0x00C0
        XCTAssertEqual(try body(of: builder.build()), "<p>This one will be fine</p>\n")
    }

    // MARK: - Numbering

    func testANumbersStartAndTheTextAroundItAreRead() throws {
        let numbered = Builder.numbering(before: "(", after: ")", start: 5)
        XCTAssertEqual(
            try body([Paragraph("One", sprms: numbered), Paragraph("Two", sprms: numbered)], speaksNumbers: true),
            "<p>(5) One</p>\n<p>(6) Two</p>\n"
        )
    }

    func testALevelThatIncludesThePreviousWritesTheNumberOfTheLevelAboveFirst() throws {
        let outer = Builder.numbering(level: 1)
        let inner = Builder.numbering(before: ".", after: "", level: 2, includesPrevious: true)
        let paragraphs = [Paragraph("A", sprms: outer), Paragraph("B", sprms: outer), Paragraph("C", sprms: inner)]
        XCTAssertEqual(try body(paragraphs, speaksNumbers: true), "<p>1. A</p>\n<p>2. B</p>\n<p>2.1 C</p>\n")
        XCTAssertEqual(try body(paragraphs), "<ol>\n<li>A</li>\n<li>B<ol>\n<li>C</li>\n</ol>\n</li>\n</ol>\n")
    }

    func testAnOutlineWithNoFirstLevelTakesTheNumberOfTheSimpleListAmongItsParagraphs() throws {
        // The shape of libreoffice-tdf150197: "1." and "2." as a simple list, "2.1" and "2.2" at the outline's second
        // level (which includes the previous level's number), then "3." and "3.1".
        let simple = Builder.numbering()
        let inner = Builder.numbering(before: ".", after: "", level: 2, includesPrevious: true)
        let paragraphs = [
            Paragraph("A", sprms: simple), Paragraph("B", sprms: simple), Paragraph("C", sprms: inner), Paragraph("D", sprms: inner),
            Paragraph("E", sprms: simple), Paragraph("F", sprms: inner),
        ]
        XCTAssertEqual(
            try body(paragraphs, speaksNumbers: true),
            "<p>1. A</p>\n<p>2. B</p>\n<p>2.1 C</p>\n<p>2.2 D</p>\n<p>3. E</p>\n<p>3.1 F</p>\n"
        )
    }

    func testASimpleListApartFromAnOutlineByTextIsItsOwnList() throws {
        // Ordinary text between the lists: the simple list does not stand in for the outline's first level.
        let simple = Builder.numbering()
        let inner = Builder.numbering(before: ".", after: "", level: 2, includesPrevious: true)
        let paragraphs = [Paragraph("A", sprms: simple), Paragraph("B", sprms: simple), Paragraph("Text"), Paragraph("C", sprms: inner)]
        XCTAssertEqual(try body(paragraphs, speaksNumbers: true), "<p>1. A</p>\n<p>2. B</p>\n<p>Text</p>\n<p>1.1 C</p>\n")
    }

    func testAnAnldWithNoLevelIsLeftOverAndTheParagraphIsNotInAList() throws {
        // 1,589 paragraphs in 22 real files: many begin with a number typed by hand. A heading stays a heading.
        let leftOver = Builder.numbering(level: nil)
        for speaks in [false, true] {
            XCTAssertEqual(
                try body([Paragraph("2. Glossary", sprms: leftOver), Paragraph("Chapter", style: 1, sprms: leftOver)], speaksNumbers: speaks),
                "<p>2. Glossary</p>\n<h1>Chapter</h1>\n"
            )
        }
    }

    func testTheLevelMayComeFromTheParagraphStyle() throws {
        let style = Builder.Style(sti: 100, basedOn: 0, name: "Numbered", paragraphSprms: Builder.sprm(13, [10]))
        let paragraphs = [Paragraph("x", style: 4, sprms: Builder.numbering(level: nil))]
        XCTAssertEqual(try body(paragraphs) { $0.styles.append(style) }, "<ol>\n<li>x</li>\n</ol>\n")
        XCTAssertEqual(try body(paragraphs, speaksNumbers: true) { $0.styles.append(style) }, "<p>1. x</p>\n")
    }

    func testAWordBulletIsAtLevelElevenAndIsAnItemOfAnUnorderedList() throws {
        XCTAssertEqual(
            try body([Paragraph("dot", sprms: Builder.numbering(format: 255, after: "o", level: 11))]),
            "<ul>\n<li>dot</li>\n</ul>\n"
        )
    }

    func testASimpleListBeginsAgainAfterAParagraphOfText() throws {
        let numbered = Builder.numbering()
        XCTAssertEqual(
            try body([Paragraph("One", sprms: numbered), Paragraph("Text"), Paragraph("Two", sprms: numbered)], speaksNumbers: true),
            "<p>1. One</p>\n<p>Text</p>\n<p>1. Two</p>\n"
        )
    }

    func testAnOutlineGoesOnCountingThroughParagraphsOfText() throws {
        let outer = Builder.numbering(level: 1)
        XCTAssertEqual(
            try body([Paragraph("One", sprms: outer), Paragraph("Text"), Paragraph("Two", sprms: outer)], speaksNumbers: true),
            "<p>1. One</p>\n<p>Text</p>\n<p>2. Two</p>\n"
        )
    }
}
