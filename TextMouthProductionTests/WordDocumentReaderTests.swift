import XCTest
import SwiftSoup
@testable import TextMouth

/// TextMouth's own reader of Word 97-2003 documents (`WordDocumentReader`,
/// FMT47), tested on the real samples in `TestData/format-samples/doc` and
/// `dot`, and on documents built in code (`WordDocumentBuilder`) for the
/// structures the samples do not hold: heading styles and outline levels,
/// bold and italic with their toggles, tables, fields, pages, and the
/// documents the reader leaves alone or refuses.
final class WordDocumentReaderTests: XCTestCase {

    // MARK: - Helpers

    typealias Paragraph = WordDocumentBuilder.Paragraph
    typealias Run = WordDocumentBuilder.Run

    /// The inner HTML of the body of the document `data` is read as.
    private func body(of data: Data, pages: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let html = try XCTUnwrap(WordDocumentReader.html(from: data, includesPages: pages), file: file, line: line)
        let start = try XCTUnwrap(html.range(of: "<body>\n"), file: file, line: line)
        let end = try XCTUnwrap(html.range(of: "</body>"), file: file, line: line)
        return String(html[start.upperBound..<end.lowerBound])
    }

    /// The body of the document made from `paragraphs` (the standard styles).
    private func body(_ paragraphs: [Paragraph], pages: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        var builder = WordDocumentBuilder()
        builder.paragraphs = paragraphs
        return try body(of: builder.build(), pages: pages, file: file, line: line)
    }

    /// The body of the sample at `path`.
    private func sampleBody(_ path: String, pages: Bool = true) throws -> String {
        try body(of: Data(contentsOf: formatSampleURL(path)), pages: pages)
    }

    private func span(_ page: Int) -> String {
        "<span role=\"doc-pagebreak\" aria-label=\"\(page)\"></span>"
    }

    /// The modifiers of a paragraph in a table, and of the mark that ends a row.
    private let inTable = WordDocumentBuilder.modifier(WordSprm.inTable, 1)
    private var rowEnd: [UInt8] { inTable + WordDocumentBuilder.modifier(WordSprm.rowEnd, 1) }

    // MARK: - The Samples

    func testTheTextutilSampleKeepsItsWordsBoldAndTable() throws {
        let body = try sampleBody("doc/headings.doc", pages: false)
        // No heading styles, so headings are guessed from size, as for textutil: 24, 18, and 12 point.
        XCTAssertTrue(body.contains("<h1>Harbour Notes</h1>"), body)
        XCTAssertTrue(body.contains("<h2>Morning Tides</h2>"), body)
        XCTAssertTrue(body.contains("<h2>Timetable</h2>"), body)
        XCTAssertTrue(body.contains("<ul>\n<li>Bread from the bakery on Rue Ménard</li>\n<li>Smoked fish, naïve prices</li>\n<li>A newspaper already a day old</li>\n</ul>"), body)
        XCTAssertTrue(body.contains("<p>The ferry leaves at seven. Café tables fill early, and the señor at the counter pours coffee without asking.</p>"), body)
        XCTAssertTrue(body.contains("Prices — in euros — are posted by the quay."), body)
        XCTAssertTrue(body.contains("<table>"), body)
        // Two columns in three rows.
        XCTAssertEqual(body.components(separatedBy: "<tr>").count - 1, 3, body)
        XCTAssertEqual(body.components(separatedBy: "<td>").count - 1, 6, body)
        XCTAssertTrue(body.contains("<td><p><strong>Boat</strong></p>\n</td><td><p><strong>Departs</strong></p>\n</td></tr>"), body)
        XCTAssertTrue(body.contains("<td><p>Ferry</p>\n</td><td><p>07:00</p>\n</td>"), body)
    }

    func testTheTextutilSampleNamesItsAuthor() throws {
        let html = try XCTUnwrap(WordDocumentReader.html(from: Data(contentsOf: formatSampleURL("doc/headings.doc")), includesPages: true))
        XCTAssertTrue(html.contains("<meta name=\"author\" content=\"A. Sample\">"), html)
    }

    func testTheLibreOfficeSampleHasHeadingsOneToSixAtTheirLevels() throws {
        let body = try sampleBody("doc/libreoffice-tdf104239_chapterNumbering.doc", pages: false)
        // The headings are numbered by the list their styles are linked to,
        // but the numbers are silent (see the list tests): each heading is its words alone.
        for level in 1...6 {
            XCTAssertTrue(body.contains("<h\(level)>Heading \(level)</h\(level)>"), body)
        }
    }

    func testAnOutlineLevelInAStyleMakesAHeadingOfAnyStyle() throws {
        let body = try sampleBody("doc/libreoffice-tdf81705_outlineLevel.doc", pages: false)
        XCTAssertTrue(body.contains("<h1>A</h1>"), body)
        XCTAssertTrue(body.contains("<h1>B</h1>"), body)
        XCTAssertTrue(body.contains("<h1>D</h1>"), body)
        // C is in a style with no outline level, and the contents are body text.
        XCTAssertTrue(body.contains("<p>C</p>"), body)
        XCTAssertTrue(body.contains("<p>Contents</p>"), body)
    }

    func testThePageBreakSampleHasTwoPagesAndKeepsItsWordsApart() throws {
        let body = try sampleBody("doc/page-breaks.doc")
        XCTAssertTrue(body.hasPrefix(span(1) + "<p>First page paragraph one.</p>"), body)
        XCTAssertTrue(body.contains("runs on and \(span(2))continues here."), body)
        XCTAssertFalse(body.contains(span(3)), body)
    }

    func testThePageBreakSampleHasNoPagesWhenNoneAreAsked() throws {
        let body = try sampleBody("doc/page-breaks.doc", pages: false)
        XCTAssertFalse(body.contains("doc-pagebreak"), body)
        XCTAssertTrue(body.contains("runs on and continues here."), body)
    }

    func testTheTemplatesReadAsDocuments() throws {
        let synthetic = try sampleBody("dot/headings-synthetic.dot", pages: false)
        XCTAssertEqual(synthetic, try sampleBody("doc/headings.doc", pages: false))
        // The LibreOffice template's body is one empty paragraph, and its only words are in a header text box.
        XCTAssertEqual(try sampleBody("dot/libreoffice-tdf120761_zOrder.dot", pages: false), "<p><strong>Blah blah blah</strong></p>\n")
    }

    func testRealFilesThatNameStylesThatAreNotThereReadAndAFileOfAnOlderLayoutIsLeftToTextutil() throws {
        // A style 0xFFFF in a paragraph's properties, and a style sheet whose length holds
        // fewer slots than it counts: both are the default formatting, and the files read.
        for sample in ["doc/poi-61911.doc", "doc/libreoffice-tdf112535.doc"] {
            let html = try XCTUnwrap(WordDocumentReader.html(from: Data(contentsOf: formatSampleURL(sample)), includesPages: true), sample)
            XCTAssertTrue(html.contains("<body>"), sample)
        }
        // wIdent 0xA699 with nFib 0x68 is a Word 95 layout, which this reader leaves to textutil.
        XCTAssertNil(try WordDocumentReader.html(from: Data(contentsOf: formatSampleURL("doc/poi-Bug51944.doc")), includesPages: true))
    }

    // MARK: - Text

    func testParagraphsAreEscapedAndKeepTheirOrder() throws {
        let body = try body([Paragraph("Fish & <chips>"), Paragraph("Second > first")])
        XCTAssertEqual(body, "<p>Fish &amp; &lt;chips&gt;</p>\n<p>Second &gt; first</p>\n")
    }

    func testTextStoredAsWindows1252AndAsUTF16ReadsAlike() throws {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [Paragraph("Café señor naïve")]
        let compressed = try body(of: builder.build())
        builder.isCompressed = false
        XCTAssertEqual(try body(of: builder.build()), compressed)
        XCTAssertEqual(compressed, "<p>Café señor naïve</p>\n")
    }

    func testWindows1252PunctuationInACompressedPieceBecomesUnicode() throws {
        // Bytes 0x93 and 0x94 are the curly quotes, 0x96 the en dash, 0x80 the euro.
        let body = try body([Paragraph("\u{93}Hi\u{94} \u{96} \u{80}5")])
        XCTAssertEqual(body, "<p>“Hi” – €5</p>\n")
    }

    func testUTF16TextWithSurrogatePairsAndLoneSurrogates() throws {
        var builder = WordDocumentBuilder()
        builder.isCompressed = false
        builder.paragraphs = [Paragraph("日本語 😀 end")]
        XCTAssertEqual(try body(of: builder.build()), "<p>日本語 😀 end</p>\n")
        // A lone high surrogate, and a lone low one, are replacement characters.
        builder.paragraphs = [Paragraph("a#b#c")]
        let data = builder.build { word, _, layout in
            let first = layout.pieceOffsets[0] + 2
            word.replaceSubrange(first..<first + 2, with: [0x00, 0xD8])
            word.replaceSubrange(first + 4..<first + 6, with: [0x00, 0xDC])
        }
        XCTAssertEqual(try body(of: data), "<p>a\u{FFFD}b\u{FFFD}c</p>\n")
    }

    func testAFastSavedDocumentWithPiecesInReverseOrderReadsAsOne() throws {
        var builder = WordDocumentBuilder()
        builder.paragraphs = (1...6).map { Paragraph("Paragraph number \($0) of the file.", style: $0 == 2 ? 1 : 0) }
        let whole = try body(of: builder.build())
        for count in [2, 3, 6] {
            builder.pieceCount = count
            XCTAssertEqual(try body(of: builder.build()), whole, "\(count) pieces")
        }
        XCTAssertTrue(whole.contains("<h1>Paragraph number 2 of the file.</h1>"), whole)
    }

    func testPropertiesThatCrossPiecesStillApply() throws {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [Paragraph(runs: [Run("plain "), Run("bold run here", bold: 1), Run(" plain")])]
        builder.pieceCount = 3
        XCTAssertEqual(try body(of: builder.build()), "<p>plain <strong>bold run here</strong> plain</p>\n")
    }

    // MARK: - Piece Modifiers (Pcd.prm)

    /// "aaaa bbbb" in two pieces, "aaaa " and "bbbb" with its paragraph mark,
    /// the second piece having the modifier `prm`, and the CLX holding `groups`.
    private func twoPieces(prm: Int, groups: [[UInt8]] = [], runs: [Run] = [Run("aaaa bbbb")]) throws -> String {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [Paragraph(runs: runs)]
        builder.pieceCount = 2
        builder.piecePrms = [0, prm]
        builder.modifierGroups = groups
        return try body(of: builder.build())
    }

    func testAPieceModifierOfOneSprmSetsBoldHiddenAndItalic() throws {
        // Prm0: the sprm is named by its index in the specification's table.
        XCTAssertEqual(try twoPieces(prm: WordDocumentBuilder.prm0(0x55, 1)), "<p>aaaa <strong>bbbb</strong></p>\n")
        XCTAssertEqual(try twoPieces(prm: WordDocumentBuilder.prm0(0x56, 1)), "<p>aaaa <em>bbbb</em></p>\n")
        XCTAssertEqual(try twoPieces(prm: WordDocumentBuilder.prm0(0x5C, 1)), "<p>aaaa</p>\n")
        // A toggle's 0x81 reverses a style that is not hidden, and 0 leaves it shown.
        XCTAssertEqual(try twoPieces(prm: WordDocumentBuilder.prm0(0x5C, 0x81)), "<p>aaaa</p>\n")
        XCTAssertEqual(try twoPieces(prm: WordDocumentBuilder.prm0(0x5C, 0)), "<p>aaaa bbbb</p>\n")
    }

    func testAPieceModifierComesAfterTheRunsOwnProperties() throws {
        let boldRun = [Run("aaaa bbbb", bold: 1)]
        XCTAssertEqual(try twoPieces(prm: WordDocumentBuilder.prm0(0x55, 0), runs: boldRun), "<p><strong>aaaa</strong> bbbb</p>\n")
    }

    func testAGroupOfPieceModifiersIsAppliedByItsIndex() throws {
        let bold = WordDocumentBuilder.modifier(WordSprm.bold, 1)
        let italic = WordDocumentBuilder.modifier(WordSprm.italic, 1)
        // Prm1: the index of a group in the CLX; here the second of two.
        let groups = [bold, bold + italic]
        XCTAssertEqual(try twoPieces(prm: WordDocumentBuilder.prm1(1), groups: groups), "<p>aaaa <strong><em>bbbb</em></strong></p>\n")
        XCTAssertEqual(try twoPieces(prm: WordDocumentBuilder.prm1(0), groups: groups), "<p>aaaa <strong>bbbb</strong></p>\n")
    }

    func testAGroupOfPieceModifiersMayHoldCharacterAndParagraphSprmsAtOnce() throws {
        // Hidden text, and the paragraph's outline level, in one group.
        let group = WordDocumentBuilder.modifier(WordSprm.hidden, 1) + WordDocumentBuilder.modifier(WordSprm.outlineLevel, 0)
        XCTAssertEqual(try twoPieces(prm: WordDocumentBuilder.prm1(0), groups: [group]), "<h1>aaaa</h1>\n")
    }

    func testAnUnknownOrNullPieceModifierChangesNothing() throws {
        XCTAssertEqual(try twoPieces(prm: WordDocumentBuilder.prm0(0x7F, 1)), "<p>aaaa bbbb</p>\n")
        // isprm 0 with a zero operand has no effect (sprmCLbcCRJ is not applied).
        XCTAssertEqual(try twoPieces(prm: WordDocumentBuilder.prm0(0, 0)), "<p>aaaa bbbb</p>\n")
        // A group holding a sprm cut short is read as far as it goes.
        XCTAssertEqual(try twoPieces(prm: WordDocumentBuilder.prm1(0), groups: [[0x35, 0x08]]), "<p>aaaa bbbb</p>\n")
    }

    /// "Chapter One" and "Body" with every character a piece of its own, the
    /// piece of the first paragraph's mark being the twelfth.
    private func chapterWithPrmOnPiece(_ piece: Int, group: [UInt8]) throws -> String {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [Paragraph("Chapter One"), Paragraph("Body")]
        builder.pieceCount = 17
        builder.piecePrms = [Int](repeating: 0, count: piece) + [WordDocumentBuilder.prm1(0)]
        builder.modifierGroups = [group]
        return try body(of: builder.build())
    }

    func testAParagraphStyleSetByTheModifiersOfItsLastPieceMakesAHeading() throws {
        let style = WordDocumentBuilder.le16(WordSprm.paragraphStyle) + WordDocumentBuilder.le16(1)
        XCTAssertEqual(try chapterWithPrmOnPiece(11, group: style), "<h1>Chapter One</h1>\n<p>Body</p>\n")
    }

    func testTheModifiersOfAnEarlierPieceDoNotChangeWhatTheParagraphIs() throws {
        // The paragraph's properties are those of the piece with its mark
        // ([MS-DOC] 2.4.6.1); the first character's piece says "heading" but is not the last.
        let style = WordDocumentBuilder.le16(WordSprm.paragraphStyle) + WordDocumentBuilder.le16(1)
        XCTAssertEqual(try chapterWithPrmOnPiece(0, group: style), "<p>Chapter One</p>\n<p>Body</p>\n")
    }

    func testTheRealFastSavedSampleHasAHeadingOnlyThePieceModifiersGive() throws {
        // The second form's company line is Heading 1 by the Prm1 of its
        // paragraph mark (sprmPIstd 1); the first form's identical line is body text.
        let body = try sampleBody("doc/poi-rasp.doc", pages: false)
        XCTAssertTrue(body.contains("<h1>Открытое акционерное общество «УУУУУУУУУУУ»</h1>"), body)
        // The first form's line is body text, in bold as the file sets it.
        XCTAssertTrue(body.contains("«ХХХХХХХХХХХ»"), body)
        XCTAssertFalse(body.contains("<h1>Открытое акционерное общество «ХХХХХХХХХХХ»"), body)
        XCTAssertEqual(body.components(separatedBy: "<h1>").count - 1, 1, body)
    }

    // MARK: - Runs Across Pieces, And Each Prm0

    /// "aaaa bbbb" as one paragraph in two pieces stored side by side, so that
    /// one run of properties covers both (as in a file whose pieces are next to
    /// each other), the pieces having the modifiers `prms`.
    private func acrossPieces(prms: [Int], groups: [[UInt8]] = [], style: Int = 0, runs: [Run] = [Run("aaaa bbbb")]) throws -> String {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [Paragraph(runs: runs, style: style)]
        builder.pieceCount = 2
        builder.storesPiecesInOrder = true
        builder.piecePrms = prms
        builder.modifierGroups = groups
        return try body(of: builder.build())
    }

    func testAParagraphTakesTheModifiersOfThePieceWithItsMarkWhenOneRunCoversTwoPieces() throws {
        let heading = [WordDocumentBuilder.le16(WordSprm.paragraphStyle) + WordDocumentBuilder.le16(1)]
        // [MS-DOC] 2.4.6.1: the Pcd of the paragraph's last character, not its first.
        XCTAssertEqual(try acrossPieces(prms: [WordDocumentBuilder.prm1(0), 0], groups: heading), "<p>aaaa bbbb</p>\n")
        XCTAssertEqual(try acrossPieces(prms: [0, WordDocumentBuilder.prm1(0)], groups: heading), "<h1>aaaa bbbb</h1>\n")
    }

    func testCharactersTakeTheirOwnPiecesModifiersWhenOneRunCoversTwoPieces() throws {
        let bold = WordDocumentBuilder.prm0(0x55, 1)
        XCTAssertEqual(try acrossPieces(prms: [bold, 0]), "<p><strong>aaaa</strong> bbbb</p>\n")
        XCTAssertEqual(try acrossPieces(prms: [0, bold]), "<p>aaaa <strong>bbbb</strong></p>\n")
    }

    func testPieceModifiersAreAppliedAfterThePAPX() throws {
        // Heading 1 by the paragraph's own properties; the modifiers of its last piece say style 0.
        let normal = [WordDocumentBuilder.le16(WordSprm.paragraphStyle) + WordDocumentBuilder.le16(0)]
        XCTAssertEqual(try acrossPieces(prms: [0, WordDocumentBuilder.prm1(0)], groups: normal, style: 1), "<p>aaaa bbbb</p>\n")
    }

    /// The paragraphs, each character in a piece of its own stored in order, so that a paragraph is one run
    /// across its pieces, the pieces having the `Prm0`s `modifiers` by the position of their character.
    private func withPieceModifiers(_ paragraphs: [Paragraph], _ modifiers: [Int: Int], pages: Bool = false) throws -> String {
        var builder = WordDocumentBuilder()
        builder.paragraphs = paragraphs
        let units = paragraphs.reduce(0) { $0 + $1.runs.reduce(0) { $0 + $1.text.utf16.count } + 1 }
        builder.pieceCount = units
        builder.storesPiecesInOrder = true
        builder.piecePrms = (0..<units).map { modifiers[$0] ?? 0 }
        return try body(of: builder.build(), pages: pages)
    }

    func testEachSprmOfThePrm0TableTheReaderUsesIsApplied() throws {
        // Deleted text (0x41: the second character), and plain text (0x53), which takes off hiding.
        XCTAssertEqual(try withPieceModifiers([Paragraph("abc")], [1: WordDocumentBuilder.prm0(0x41, 1)]), "<p>ac</p>\n")
        XCTAssertEqual(
            try withPieceModifiers([Paragraph(runs: [Run("hid", hidden: 1)])], [0: WordDocumentBuilder.prm0(0x53, 1), 1: WordDocumentBuilder.prm0(0x53, 1), 2: WordDocumentBuilder.prm0(0x53, 1)]),
            "<p>hid</p>\n"
        )
        // A special character (0x75): a symbol's "(" is not read.
        XCTAssertEqual(try withPieceModifiers([Paragraph("a(b")], [1: WordDocumentBuilder.prm0(0x75, 1)]), "<p>ab</p>\n")
        // Page break before (0x09), on the mark of "B": a page begins before its words.
        XCTAssertEqual(
            try withPieceModifiers([Paragraph("A"), Paragraph("B")], [3: WordDocumentBuilder.prm0(0x09, 1)], pages: true),
            span(1) + "<p>A</p>\n<p>\(span(2))B</p>\n"
        )
        // An outline level (0x78) makes a heading, and a level change (0x04) moves Heading 1 to Heading 2.
        XCTAssertEqual(try withPieceModifiers([Paragraph("t")], [1: WordDocumentBuilder.prm0(0x78, 0)]), "<h1>t</h1>\n")
        XCTAssertEqual(try withPieceModifiers([Paragraph("Chapter", style: 1)], [7: WordDocumentBuilder.prm0(0x04, 1)]), "<h2>Chapter</h2>\n")
        XCTAssertEqual(try withPieceModifiers([Paragraph("Chapter", style: 2)], [7: WordDocumentBuilder.prm0(0x04, 0xFF)]), "<h1>Chapter</h1>\n")
        // In a table (0x18): a cell, though its own properties say nothing.
        XCTAssertEqual(
            try withPieceModifiers([Paragraph("cell", mark: 0x07)], [4: WordDocumentBuilder.prm0(0x18, 1)]),
            "<table>\n<tr><td><p>cell</p>\n</td></tr>\n</table>\n"
        )
        // A row's end (0x19): the cells on either side are two rows.
        let inTable = WordDocumentBuilder.modifier(WordSprm.inTable, 1)
        let rowEnd = inTable + WordDocumentBuilder.modifier(WordSprm.rowEnd, 1)
        XCTAssertEqual(
            try withPieceModifiers([
                Paragraph("a", modifiers: inTable, mark: 0x07), Paragraph("", modifiers: inTable, mark: 0x07),
                Paragraph("b", modifiers: inTable, mark: 0x07), Paragraph("", modifiers: rowEnd, mark: 0x07),
            ], [2: WordDocumentBuilder.prm0(0x19, 1)]),
            "<table>\n<tr><td><p>a</p>\n</td></tr>\n<tr><td><p>b</p>\n</td></tr>\n</table>\n"
        )
    }

    func testPlainTextAndACharacterStyleTakeOffTheDirectFormattingBeforeThemButNotAfter() throws {
        var plain = Run("x", hidden: 1)
        plain.extraModifiers = WordDocumentBuilder.modifier(WordSprm.plain, 0)
        XCTAssertEqual(try body([Paragraph(runs: [plain])]), "<p>x</p>\n")
        // Hidden before the character style (italic): the style's properties replace it.
        // (The builder writes a character style first, as Word does, so both are written by hand here.)
        var before = Run("y")
        before.extraModifiers = WordDocumentBuilder.modifier(WordSprm.hidden, 1)
            + WordDocumentBuilder.le16(WordSprm.characterStyle) + WordDocumentBuilder.le16(11)
        XCTAssertEqual(try body([Paragraph(runs: [before])]), "<p><em>y</em></p>\n")
        // Hidden after it: it stays.
        var after = Run("z", characterStyle: 11)
        after.extraModifiers = WordDocumentBuilder.modifier(WordSprm.hidden, 1)
        XCTAssertEqual(try body([Paragraph(runs: [after]), Paragraph("kept")]), "<p>kept</p>\n")
    }

    func testALineBreakThatIsAStyleSeparatorEndsTheParagraph() throws {
        var separator = Run("\u{0B}")
        separator.extraModifiers = WordDocumentBuilder.modifier(WordSprm.styleSeparator, 1)
        // The words are not joined into one line of a heading; both parts are in the paragraph's style.
        XCTAssertEqual(
            try body([Paragraph(runs: [Run("Run-in heading."), separator, Run("Body follows.")], style: 1)]),
            "<h1>Run-in heading.</h1>\n<h1>Body follows.</h1>\n"
        )
    }

    // MARK: - Properties in the Data Stream

    /// The `Data` stream with, at offset 16, a `PrcData` of 10 bytes that makes a heading of the paragraph.
    private var headingInTheDataStream: [UInt8] {
        let group = WordDocumentBuilder.le16(WordSprm.paragraphStyle) + WordDocumentBuilder.le16(1)
            + WordDocumentBuilder.modifier(WordSprm.pageBreakBefore, 0) + WordDocumentBuilder.modifier(0x2405, 1)
        return [UInt8](repeating: 0, count: 16) + WordDocumentBuilder.le16(group.count) + group
    }

    func testAParagraphWhosePropertiesAreInTheDataStreamIsRead() throws {
        var builder = WordDocumentBuilder()
        builder.dataStream = headingInTheDataStream
        for opcode in [WordSprm.hugeParagraphProperties, WordSprm.tableProperties] {
            builder.paragraphs = [
                Paragraph("Title", modifiers: WordDocumentBuilder.le16(opcode) + WordDocumentBuilder.le32(16)), Paragraph("Body"),
            ]
            XCTAssertEqual(try body(of: builder.build()), "<h1>Title</h1>\n<p>Body</p>\n", "sprm \(String(opcode, radix: 16))")
        }
    }

    func testAHugePapxThatIsNotTheFirstSprmIsIgnoredAndOneNamingNothingReadsAsNone() throws {
        var builder = WordDocumentBuilder()
        builder.dataStream = headingInTheDataStream
        let heading2 = WordDocumentBuilder.le16(WordSprm.paragraphStyle) + WordDocumentBuilder.le16(2)
        let huge = WordDocumentBuilder.le16(WordSprm.hugeParagraphProperties) + WordDocumentBuilder.le32(16)
        // Not first: ignored ([MS-DOC] sprmPHugePapx), so the paragraph is Heading 2 and the data is not applied.
        builder.paragraphs = [Paragraph("Not first", modifiers: heading2 + huge)]
        XCTAssertEqual(try body(of: builder.build()), "<h2>Not first</h2>\n")
        // An offset past the stream, a PrcData too small, and a missing Data stream: no properties.
        for offset in [4000, 0] {
            builder.paragraphs = [Paragraph("Title", modifiers: WordDocumentBuilder.le16(WordSprm.hugeParagraphProperties) + WordDocumentBuilder.le32(offset))]
            XCTAssertEqual(try body(of: builder.build()), "<p>Title</p>\n", "offset \(offset)")
        }
        builder.dataStream = []
        builder.paragraphs = [Paragraph("Title", modifiers: huge)]
        XCTAssertEqual(try body(of: builder.build()), "<p>Title</p>\n")
    }

    func testPropertiesInTheDataStreamMayNameOthersAndALoopEnds() throws {
        var builder = WordDocumentBuilder()
        // At 16, 10 bytes whose first sprm names the PrcData at 40; at 40 the heading's.
        var data = [UInt8](repeating: 0, count: 64)
        let link = WordDocumentBuilder.le16(WordSprm.tableProperties) + WordDocumentBuilder.le32(40)
        let padding = WordDocumentBuilder.modifier(0x2405, 1) + WordDocumentBuilder.modifier(0x2406, 1)
        data.replaceSubrange(16..<28, with: WordDocumentBuilder.le16(12) + link + padding)
        let heading = headingInTheDataStream
        data.replaceSubrange(40..<52, with: Array(heading[16..<28]))
        builder.dataStream = data
        builder.paragraphs = [Paragraph("Chained", modifiers: WordDocumentBuilder.le16(WordSprm.hugeParagraphProperties) + WordDocumentBuilder.le32(16))]
        XCTAssertEqual(try body(of: builder.build()), "<h1>Chained</h1>\n")
        // A PrcData that names itself: followed a few times, then given up, and the paragraph reads.
        let loop = WordDocumentBuilder.le16(WordSprm.hugeParagraphProperties) + WordDocumentBuilder.le32(16)
        builder.dataStream = [UInt8](repeating: 0, count: 16) + WordDocumentBuilder.le16(12) + loop + padding
        let start = Date()
        XCTAssertEqual(try body(of: builder.build()), "<p>Chained</p>\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testTheRealSampleWhoseTableRowsHaveTheirPropertiesInTheDataStreamHasFiveRows() throws {
        // Each row's end mark has its in-table and row-end flags (sprmPTableProps) in the Data stream.
        let body = try sampleBody("doc/libreoffice-tdf73056_cellMargins.doc", pages: false)
        XCTAssertEqual(body.components(separatedBy: "<tr>").count - 1, 5, body)
    }

    func testEmptyParagraphsAndBlankDocumentsWriteNoBlocks() throws {
        XCTAssertEqual(try body([Paragraph(""), Paragraph("   "), Paragraph("")]), "")
        XCTAssertEqual(try body([]), "")
    }

    func testControlCharactersAreDroppedAndBreaksKept() throws {
        // A picture anchor, a footnote mark, a comment mark, a drawing anchor,
        // an optional hyphen, a tab, a non-breaking hyphen, and a line break.
        let body = try body([Paragraph("one\u{01}\u{02}\u{05}\u{08}two\u{1F}\tthree\u{1E}four\u{0B}five")])
        XCTAssertEqual(body, "<p>onetwo three-four<br>five</p>\n")
    }

    func testTheTitleAndAuthorComeFromTheSummaryInformation() throws {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [Paragraph("Text")]
        builder.title = "A \"quoted\" & <odd> title"
        builder.author = "Ana Pereira"
        let html = try XCTUnwrap(WordDocumentReader.html(from: builder.build(), includesPages: false))
        XCTAssertTrue(html.contains("<title>A &quot;quoted&quot; &amp; &lt;odd&gt; title</title>"), html)
        XCTAssertTrue(html.contains("<meta name=\"author\" content=\"Ana Pereira\">"), html)
        // Nothing is written for names the document does not give.
        builder.title = nil
        builder.author = nil
        let bare = try XCTUnwrap(WordDocumentReader.html(from: builder.build(), includesPages: false))
        XCTAssertFalse(bare.contains("<title>"), bare)
        XCTAssertFalse(bare.contains("author"), bare)
    }

    // MARK: - Bullets

    /// The body of the document made from `paragraphs` stored as UTF-16, which
    /// the bullet glyphs need.
    private func wideBody(_ paragraphs: [Paragraph], pages: Bool = false) throws -> String {
        var builder = WordDocumentBuilder()
        builder.isCompressed = false
        builder.paragraphs = paragraphs
        return try body(of: builder.build(), pages: pages)
    }

    func testParagraphsThatBeginWithABulletAndASpaceBecomeAList() throws {
        let body = try wideBody([
            Paragraph("Before"), Paragraph("•\tfirst item"), Paragraph("•\tsecond item"), Paragraph("After"),
            Paragraph("● third"),
        ])
        XCTAssertEqual(body, "<p>Before</p>\n<ul>\n<li>first item</li>\n<li>second item</li>\n</ul>\n<p>After</p>\n<ul>\n<li>third</li>\n</ul>\n")
    }

    func testADashOrAnAsteriskIsABulletOnlyBeforeATab() throws {
        // Dialogue that begins with a dash and a space stays a paragraph, as in textutil's rule.
        XCTAssertEqual(
            try wideBody([Paragraph("– Hello, she said."), Paragraph("- again"), Paragraph("* star")]),
            "<p>– Hello, she said.</p>\n<p>- again</p>\n<p>* star</p>\n"
        )
        XCTAssertEqual(
            try wideBody([Paragraph("–\tone"), Paragraph("-\ttwo"), Paragraph("*\tthree")]),
            "<ul>\n<li>one</li>\n<li>two</li>\n<li>three</li>\n</ul>\n"
        )
    }

    func testABulletGlyphMayBeFollowedByATabOrASpaceButNotByNothing() throws {
        XCTAssertEqual(
            try wideBody([Paragraph("•\ttab"), Paragraph("• space"), Paragraph("•glued"), Paragraph("•")]),
            "<ul>\n<li>tab</li>\n<li>space</li>\n</ul>\n<p>•glued</p>\n<p>•</p>\n"
        )
    }

    func testAListItemKeepsItsEmphasisAndItsPage() throws {
        let body = try wideBody([Paragraph(runs: [Run("•\t"), Run("bold", bold: 1), Run(" item")]), Paragraph("\u{0C}•\tnext")], pages: true)
        XCTAssertEqual(body, span(1) + "<ul>\n<li><strong>bold</strong> item</li>\n<li>\(span(2))next</li>\n</ul>\n")
    }

    // MARK: - Other Stories

    private func storyDocument(main: [Paragraph]) -> WordDocumentBuilder {
        var builder = WordDocumentBuilder()
        builder.paragraphs = main
        builder.stories = [
            .footnotes: [Paragraph("Footnote words.")], .headers: [Paragraph("Header words.")],
            .comments: [Paragraph("Comment words.")], .endnotes: [Paragraph("Endnote words.")],
            .textBoxes: [Paragraph("Textbox words.")], .headerTextBoxes: [Paragraph("Header textbox words.")],
        ]
        return builder
    }

    func testAMainStoryWithWordsIsFollowedByItsNotesAndTextBoxesAndNothingElse() throws {
        // Headers, comments, and the text boxes of headers are left out; the
        // footnotes, the endnotes, and the text boxes follow, as in textutil's reading.
        let body = try body(of: storyDocument(main: [Paragraph("Main words.")]).build())
        XCTAssertEqual(body, "<p>Main words.</p>\n<p>Footnote words.</p>\n<p>Endnote words.</p>\n<p>Textbox words.</p>\n")
    }

    func testTextBoxesFollowTheNotesInTheOrderOfTheirStories() throws {
        // Only text boxes, then boxes with a second paragraph, a table, and a hidden word.
        var builder = WordDocumentBuilder()
        builder.paragraphs = [Paragraph("Main words.")]
        builder.stories = [.textBoxes: [Paragraph("Box one."), Paragraph(runs: [Run("Box "), Run("secret ", hidden: 1), Run("two.")])]]
        XCTAssertEqual(try body(of: builder.build()), "<p>Main words.</p>\n<p>Box one.</p>\n<p>Box two.</p>\n")
        builder.stories = [.headerTextBoxes: [Paragraph("Header box.")]]
        XCTAssertEqual(try body(of: builder.build()), "<p>Main words.</p>\n")
        builder.stories = [.endnotes: [Paragraph("End.")], .textBoxes: [Paragraph("Box.")], .footnotes: [Paragraph("Foot.")]]
        XCTAssertEqual(try body(of: builder.build()), "<p>Main words.</p>\n<p>Foot.</p>\n<p>End.</p>\n<p>Box.</p>\n")
    }

    // MARK: - Notes Whose Marks Are Not Shown

    /// A document whose main paragraph is "Seen", a shown footnote mark,
    /// " and more", and a second mark `second`, with two footnotes.
    private func noteDocument(second: Run) -> WordDocumentBuilder {
        var builder = WordDocumentBuilder()
        // The marks stand at positions 4 and 14 of the main text.
        builder.paragraphs = [Paragraph(runs: [Run("Seen"), Run("\u{02}"), Run(" and more"), second])]
        builder.footnoteReferences = [4, 14]
        builder.stories = [.footnotes: [Paragraph("Shown note."), Paragraph("Second note.")]]
        return builder
    }

    func testANoteIsReadOnlyIfItsReferenceMarkIsShown() throws {
        // Both marks shown: both notes.
        XCTAssertEqual(
            try body(of: noteDocument(second: Run("\u{02}")).build()),
            "<p>Seen and more</p>\n<p>Shown note.</p>\n<p>Second note.</p>\n"
        )
        // The second mark hidden: its note is left out.
        XCTAssertEqual(
            try body(of: noteDocument(second: Run("\u{02}", hidden: 1)).build()),
            "<p>Seen and more</p>\n<p>Shown note.</p>\n"
        )
        // Or deleted by a tracked change.
        var deleted = Run("\u{02}")
        deleted.isDeleted = true
        XCTAssertEqual(try body(of: noteDocument(second: deleted).build()), "<p>Seen and more</p>\n<p>Shown note.</p>\n")
    }

    func testEndnotesFollowTheSameRule() throws {
        var builder = WordDocumentBuilder()
        var gone = Run("\u{02}")
        gone.isDeleted = true
        builder.paragraphs = [Paragraph(runs: [Run("Main."), gone, Run("\u{02}")])]
        builder.endnoteReferences = [5, 6]
        builder.stories = [.endnotes: [Paragraph("Lost end."), Paragraph("Kept end.")]]
        XCTAssertEqual(try body(of: builder.build()), "<p>Main.</p>\n<p>Kept end.</p>\n")
    }

    func testNoteTablesThatAreNotWholeEntriesOrTooShortReadTheWholeStory() throws {
        let builder = noteDocument(second: Run("\u{02}", hidden: 1))
        XCTAssertEqual(try body(of: builder.build()), "<p>Seen and more</p>\n<p>Shown note.</p>\n")
        let whole = "<p>Seen and more</p>\n<p>Shown note.</p>\n<p>Second note.</p>\n"
        // Each table's length in the FIB, made a byte longer (not a whole number of entries), and the
        // text table made too short to place both notes: none is trusted.
        for (structure, change) in [
            (WordFileInformationBlock.Structure.footnoteReferences, 1), (.footnoteText, 1), (.footnoteText, -8),
        ] {
            let data = builder.build { word, _, layout in
                let at = layout.pairs + structure.rawValue * 8 + 4
                let length = Int(word[at]) | Int(word[at + 1]) << 8 | Int(word[at + 2]) << 16 | Int(word[at + 3]) << 24
                word.replaceSubrange(at..<at + 4, with: WordDocumentBuilder.le32(length + change))
            }
            XCTAssertEqual(try body(of: data), whole, "\(structure) \(change)")
        }
    }

    func testEveryNoteHiddenLeavesTheMainTextAlone() throws {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [Paragraph(runs: [Run("Main."), Run("\u{02}\u{02}", hidden: 1)])]
        builder.footnoteReferences = [5, 6]
        builder.stories = [.footnotes: [Paragraph("One."), Paragraph("Two.")]]
        XCTAssertEqual(try body(of: builder.build()), "<p>Main.</p>\n")
    }

    func testNoteTablesThatDoNotAddUpReadTheWholeStory() throws {
        // Marks that go back are not trusted, so nothing is left out.
        var builder = noteDocument(second: Run("\u{02}", hidden: 1))
        builder.footnoteReferences = [14, 4]
        XCTAssertEqual(
            try body(of: builder.build()),
            "<p>Seen and more</p>\n<p>Shown note.</p>\n<p>Second note.</p>\n"
        )
    }

    // MARK: - Tracked Deletions and Moves

    func testADeletionIsATogglePropertyAndNoStyleGivesOne() throws {
        // Revision-mark deletion is a toggle ([MS-DOC] sprmCFRMarkDel): 1 and
        // 0x81 delete, 0x80 keeps what a style gives, which is nothing.
        func run(_ value: Int) -> Run {
            var run = Run(" word")
            run.extraModifiers = WordDocumentBuilder.modifier(WordSprm.deleted, value)
            return run
        }
        for (value, expected) in [(1, "<p>Kept</p>\n"), (0x81, "<p>Kept</p>\n"), (0x80, "<p>Kept word</p>\n"), (0, "<p>Kept word</p>\n")] {
            XCTAssertEqual(try body([Paragraph(runs: [Run("Kept"), run(value)])]), expected, "operand \(value)")
        }
    }

    func testMovedTextIsReadOnceBecauseTheFormatHasNoMoves() throws {
        // [MS-DOC] has no move: a tracked move is a deletion where the text
        // was and an insertion where it went, so the text is read at its
        // new place only.
        var movedFrom = Run("The paragraph that moved. ")
        movedFrom.isDeleted = true
        XCTAssertEqual(
            try body([Paragraph(runs: [movedFrom, Run("First.")]), Paragraph("The paragraph that moved. Second.")]),
            "<p>First.</p>\n<p>The paragraph that moved. Second.</p>\n"
        )
    }

    // MARK: - Hidden Text and Pages, Headings

    func testAPageBreakInsideDeletedTextBeginsNoPage() throws {
        var deleted = Run("\u{0C}")
        deleted.isDeleted = true
        XCTAssertEqual(
            try body([Paragraph(runs: [Run("one "), deleted, Run("two")])], pages: true),
            span(1) + "<p>one two</p>\n"
        )
    }

    func testAParagraphOfDeletedWordsThatBeginsAPageBeginsNone() throws {
        var deleted = Run("gone")
        deleted.isDeleted = true
        let pageBreakBefore = WordDocumentBuilder.modifier(WordSprm.pageBreakBefore, 1)
        let body = try body([Paragraph("A"), Paragraph(runs: [deleted], modifiers: pageBreakBefore), Paragraph("B")], pages: true)
        XCTAssertEqual(body, span(1) + "<p>A</p>\n<p>B</p>\n")
    }

    func testAHiddenSectionBreakBeginsNoPage() throws {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [Paragraph("first", mark: 0x0C, markModifiers: hiddenMark), Paragraph("second")]
        builder.sectionBreaks = [(0, 2)]
        XCTAssertEqual(try body(of: builder.build(), pages: true), span(1) + "<p>first</p>\n<p>second</p>\n")
        // The same break shown begins page 2.
        builder.paragraphs = [Paragraph("first", mark: 0x0C), Paragraph("second")]
        XCTAssertEqual(try body(of: builder.build(), pages: true), span(1) + "<p>first</p>\n<p>\(span(2))second</p>\n")
    }

    func testAHiddenHeadingWritesNoHeadingAndLeavesTheGuessBySizeOn() throws {
        // The Heading 1 paragraph is all hidden: no heading is written, and it
        // is not a "real" heading that turns off the guess by size.
        let body = try body([
            Paragraph(runs: [Run("Hidden chapter", hidden: 1)], style: 1),
            Paragraph(runs: [Run("Big title", fontSize: 40)]),
            Paragraph("Body text goes on for a good while here."),
            Paragraph("More body text."),
        ])
        XCTAssertEqual(body, "<h1>Big title</h1>\n<p>Body text goes on for a good while here.</p>\n<p>More body text.</p>\n")
    }

    // MARK: - The Reading Text

    /// The chapter an import makes of the HTML the reader writes for `data`:
    /// its reading text, as a listener hears it, and its headings.
    private func readingChapter(of data: Data) throws -> Chapter {
        let html = try XCTUnwrap(WordDocumentReader.html(from: data, includesPages: false))
        let markdown = try HTMLToMarkdownConverter.convert(
            document: SwiftSoup.parse(html), readingFlow: PublicationSemantics.ReadingFlow(source: html), includesPages: false
        )
        return try MarkdownDocParser.parseChapter(markdown: markdown, title: "", includeNavigationHeadings: true)
    }

    func testEmphasisThatStartsOrEndsOnPunctuationSpeaksNoAsterisk() throws {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [
            Paragraph(runs: [Run("He said "), Run("\"stop!\"", bold: 1), Run(" loudly")]),
            Paragraph(runs: [Run("word"), Run("(aside)", italic: 1), Run(" and "), Run("Really", italic: 1), Run("?", italic: 1)]),
            Paragraph(runs: [Run("Price: "), Run("$5.00,", bold: 1), Run(" or "), Run("-", bold: 1), Run("dash", bold: 1)]),
        ]
        let text = try readingChapter(of: builder.build()).text
        XCTAssertFalse(text.contains("*"), text)
        XCTAssertEqual(
            text, "He said \"stop!\" loudly\n\nword(aside) and Really?\n\nPrice: $5.00, or -dash"
        )
    }

    func testTheRealSampleWithTextBoxesReadsThemAfterTheMainText() throws {
        // The notice's body ends with the Mayor's name; the contact details
        // of the text boxes follow it, and the last box ends the reading.
        let body = try sampleBody("doc/poi-textboxes.doc", pages: false)
        let main = try XCTUnwrap(body.range(of: "mgr inż. Jacek Brygman"), body)
        let box = try XCTUnwrap(body.range(of: "inwestycje.cekcyn@las.pl"), body)
        let last = try XCTUnwrap(body.range(of: "ww.ekomel.com.pl"), body)
        XCTAssertLessThan(main.lowerBound, box.lowerBound)
        XCTAssertLessThan(box.lowerBound, last.lowerBound)
    }

    func testOnlyEndnotesOrOnlyFootnotesFollowTheMainStory() throws {
        var builder = storyDocument(main: [Paragraph("Main words.")])
        builder.stories = [.endnotes: [Paragraph("Endnote one."), Paragraph("Endnote two.")], .headers: [Paragraph("Header.")]]
        XCTAssertEqual(try body(of: builder.build()), "<p>Main words.</p>\n<p>Endnote one.</p>\n<p>Endnote two.</p>\n")
        builder.stories = [.footnotes: [Paragraph("Footnote one.")]]
        XCTAssertEqual(try body(of: builder.build()), "<p>Main words.</p>\n<p>Footnote one.</p>\n")
    }

    func testAMainStoryWithNoWordsReadsItsNotesAndTextBoxesAndNotItsHeadersOrComments() throws {
        for main in [[], [Paragraph("")], [Paragraph("  ... ")]] {
            let body = try body(of: storyDocument(main: main).build())
            // A main story of punctuation keeps its punctuation, as textutil's does.
            XCTAssertTrue(body.hasSuffix("<p>Footnote words.</p>\n<p>Endnote words.</p>\n<p>Textbox words.</p>\n"), body)
            for page in ["Header", "Comment"] { XCTAssertFalse(body.contains(page), body) }
        }
    }

    func testADocumentWhoseWordsAreAllInHeadersAndCommentsReadsEveryStoryInFileOrder() throws {
        var builder = WordDocumentBuilder()
        builder.stories = [
            .headers: [Paragraph("Header words.")], .comments: [Paragraph("Comment words.")],
            .headerTextBoxes: [Paragraph("Header textbox words.")],
        ]
        XCTAssertEqual(
            try body(of: builder.build()),
            "<p>Header words.</p>\n<p>Comment words.</p>\n<p>Header textbox words.</p>\n"
        )
    }

    func testAFootnoteOrABoxHasNoPagesAndAnOpenFieldDoesNotEatTheNextStory() throws {
        let pageBreakBefore = WordDocumentBuilder.modifier(WordSprm.pageBreakBefore, 1)
        var builder = WordDocumentBuilder()
        // The main story ends in a field whose end is not there.
        builder.paragraphs = [Paragraph("Main \u{13} NEVER ENDS")]
        builder.stories = [
            .footnotes: [Paragraph("Note one.", modifiers: pageBreakBefore), Paragraph("Note two.\u{0C} more.")],
            .textBoxes: [Paragraph("Box words.", modifiers: pageBreakBefore)],
        ]
        // No pages begin in a note or a box, and the notes and the box are read.
        XCTAssertEqual(
            try body(of: builder.build(), pages: true),
            span(1) + "<p>Main</p>\n<p>Note one.</p>\n<p>Note two. more.</p>\n<p>Box words.</p>\n"
        )
    }

    // MARK: - The Guess at Headings Is the Main Story's

    func testATextBoxHeadingDoesNotTurnOffTheMainStorysGuessAtHeadings() throws {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [
            Paragraph(runs: [Run("Big title", fontSize: 40)]),
            Paragraph("Body text goes on for a good while here."),
            Paragraph("More body text."),
        ]
        builder.stories = [.textBoxes: [Paragraph("Boxed heading", style: 1)]]
        XCTAssertEqual(
            try body(of: builder.build()),
            "<h1>Big title</h1>\n<p>Body text goes on for a good while here.</p>\n<p>More body text.</p>\n<h1>Boxed heading</h1>\n"
        )
    }

    func testMuchSmallTextInTheBoxesDoesNotMakeHeadingsOfTheMainStory() throws {
        var builder = WordDocumentBuilder()
        // The main story is 12-point and short; the boxes hold far more text at 8 points.
        builder.paragraphs = [Paragraph(runs: [Run("Short main paragraph.", fontSize: 24)]), Paragraph(runs: [Run("Another short one here.", fontSize: 24)])]
        builder.stories = [.textBoxes: [Paragraph(runs: [Run(String(repeating: "Small print goes on and on. ", count: 30), fontSize: 16)])]]
        let body = try body(of: builder.build())
        XCTAssertFalse(body.contains("<h"), body)
        XCTAssertTrue(body.hasPrefix("<p>Short main paragraph.</p>\n<p>Another short one here.</p>\n<p>Small print"), body)
    }

    func testTheTextBoxTableMakesABoxOfEachRangeAndIgnoresTheLast() throws {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [Paragraph("Main words.")]
        builder.stories = [.textBoxes: [Paragraph("Box one."), Paragraph("Box two.")]]
        builder.writesTextBoxTable = true
        XCTAssertEqual(try body(of: builder.build()), "<p>Main words.</p>\n<p>Box one.</p>\n<p>Box two.</p>\n")
        // A table that names only the first box: what lies after it, in the last range, is ignored.
        builder.textBoxTableLimit = 1
        XCTAssertEqual(try body(of: builder.build()), "<p>Main words.</p>\n<p>Box one.</p>\n")
    }

    func testTheOtherStoriesOfAnEmptyBodyHavePagesToo() throws {
        let body = try body(of: storyDocument(main: []).build(), pages: true)
        XCTAssertTrue(body.hasPrefix(span(1) + "<p>Footnote words.</p>\n"), body)
    }

    // MARK: - Tracked Changes

    func testTextATrackedChangeDeletedIsNotRead() throws {
        var deleted = Run(" dolor sit amet")
        deleted.isDeleted = true
        let body = try body([Paragraph(runs: [Run("Lorem ipsum"), deleted, Run(" consectetur")])])
        XCTAssertEqual(body, "<p>Lorem ipsum consectetur</p>\n")
    }

    func testAParagraphThatIsAllDeletedTextIsLeftOut() throws {
        var deleted = Run("gone entirely")
        deleted.isDeleted = true
        XCTAssertEqual(try body([Paragraph(runs: [deleted]), Paragraph("kept")]), "<p>kept</p>\n")
    }

    // MARK: - Hidden Text

    /// A builder whose styles hold, after the standard ones: 12 a paragraph
    /// style that is hidden, 13 a character style that is hidden, 14 a
    /// paragraph style based on 12 that says nothing of its own, and 15 a
    /// paragraph style based on 12 that turns hidden text off.
    private func hiddenStylesBuilder() -> WordDocumentBuilder {
        var builder = WordDocumentBuilder()
        builder.styles.append(WordDocumentBuilder.Style(basedOn: 0, hidden: 1))
        builder.styles.append(WordDocumentBuilder.Style(kind: 2, hidden: 1))
        builder.styles.append(WordDocumentBuilder.Style(basedOn: 12))
        builder.styles.append(WordDocumentBuilder.Style(basedOn: 12, hidden: 0))
        return builder
    }

    /// The modifier that hides a paragraph mark (a character property of the mark).
    private let hiddenMark = WordDocumentBuilder.modifier(WordSprm.hidden, 1)

    func testHiddenTextIsNotReadAndItsWhiteSpaceGoesWithIt() throws {
        let body = try body([Paragraph(runs: [Run("Seen "), Run("secret words ", hidden: 1), Run("seen again")])])
        XCTAssertEqual(body, "<p>Seen seen again</p>\n")
    }

    func testHiddenTextIsATogglePropertyLikeBoldAndItalic() throws {
        var builder = hiddenStylesBuilder()
        builder.paragraphs = [
            // Directly on and off, in a paragraph that is not hidden.
            Paragraph(runs: [Run("on", hidden: 1)]),
            Paragraph(runs: [Run("off", hidden: 0)]),
            // 0x81 reverses what the style gives: hidden from a visible style.
            Paragraph(runs: [Run("reversed", hidden: 0x81)]),
            Paragraph(runs: [Run("kept", hidden: 0x80)]),
            // In a hidden paragraph style: hidden by default, shown by 0, kept by 0x80, shown by 0x81.
            Paragraph("by style", style: 12),
            Paragraph(runs: [Run("shown by zero", hidden: 0)], style: 12),
            Paragraph(runs: [Run("kept hidden", hidden: 0x80)], style: 12),
            Paragraph(runs: [Run("reversed to shown", hidden: 0x81)], style: 12),
            // A style based on a hidden one is hidden, unless it says otherwise.
            Paragraph("inherited", style: 14),
            Paragraph("overridden", style: 15),
            // A hidden character style.
            Paragraph(runs: [Run("hidden by character style", characterStyle: 13)]),
            Paragraph(runs: [Run("shown over the character style", hidden: 0, characterStyle: 13)]),
        ]
        XCTAssertEqual(
            try body(of: builder.build()),
            "<p>off</p>\n<p>kept</p>\n<p>shown by zero</p>\n<p>reversed to shown</p>\n<p>overridden</p>\n<p>shown over the character style</p>\n"
        )
    }

    func testAParagraphOfOnlyHiddenWordsWritesNothingNotEvenAnEmptyHeading() throws {
        let body = try body([
            Paragraph(runs: [Run("Chapter One", hidden: 1)], style: 1),
            Paragraph(runs: [Run("hidden", hidden: 1)]),
            Paragraph("After"),
        ])
        XCTAssertEqual(body, "<p>After</p>\n")
    }

    func testAHiddenParagraphMarkAloneJoinsNothing() throws {
        // A run-in heading's mark is hidden in Word so that the next paragraph
        // runs on from it; here the paragraphs stay separate and a heading stays a heading.
        let body = try body([
            Paragraph(runs: [Run("Run-in heading.")], style: 1, markModifiers: hiddenMark),
            Paragraph("Body text follows."),
            Paragraph(runs: [Run("Plain.")], markModifiers: hiddenMark),
            Paragraph("Last."),
        ])
        XCTAssertEqual(body, "<h1>Run-in heading.</h1>\n<p>Body text follows.</p>\n<p>Plain.</p>\n<p>Last.</p>\n")
    }

    func testHiddenLineBreaksTabsAndColumnBreaksAreNotRead() throws {
        // Nothing but the hidden characters stands between the words, so a hidden tab or column break that were read would show as a space.
        let body = try body([Paragraph(runs: [Run("a"), Run("\u{0B}", hidden: 1), Run("b"), Run("\u{09}\u{0E}", hidden: 1), Run("c")])])
        XCTAssertEqual(body, "<p>abc</p>\n")
        // The same characters shown.
        XCTAssertEqual(try self.body([Paragraph(runs: [Run("a"), Run("\u{0B}"), Run("b")])]), "<p>a<br>b</p>\n")
        XCTAssertEqual(try self.body([Paragraph(runs: [Run("b"), Run("\u{09}\u{0E}"), Run("c")])]), "<p>b c</p>\n")
    }

    func testAPageBreakInsideHiddenTextBeginsNoPage() throws {
        let hiddenBreak = try body([Paragraph(runs: [Run("one "), Run("\u{0C}", hidden: 1), Run("two")])], pages: true)
        XCTAssertEqual(hiddenBreak, span(1) + "<p>one two</p>\n")
        let shownBreak = try body([Paragraph(runs: [Run("one "), Run("\u{0C}"), Run("two")])], pages: true)
        XCTAssertEqual(shownBreak, span(1) + "<p>one \(span(2))two</p>\n")
    }

    func testAParagraphOfHiddenWordsThatBeginsAPageBeginsNone() throws {
        let pageBreakBefore = WordDocumentBuilder.modifier(WordSprm.pageBreakBefore, 1)
        let body = try body([
            Paragraph("A"),
            Paragraph(runs: [Run("hidden", hidden: 1)], modifiers: pageBreakBefore),
            Paragraph("B"),
        ], pages: true)
        XCTAssertEqual(body, span(1) + "<p>A</p>\n<p>B</p>\n")
    }

    func testTextHiddenOnlyOnTheWebAndAHiddenMarkAreStillRead() throws {
        // sprmCFWebHidden (0x0811) shows in print and in the normal view;
        // sprmCFSpecVanish (0x0818) hides the paragraph mark alone.
        var webHidden = Run("web only ")
        webHidden.extraModifiers = WordDocumentBuilder.modifier(0x0811, 1)
        var specVanish = Run("spec vanish")
        specVanish.extraModifiers = WordDocumentBuilder.modifier(0x0818, 1)
        // The mark of the first paragraph is a style separator: the paragraphs stay two.
        XCTAssertEqual(
            try body([
                Paragraph(runs: [webHidden, specVanish], markModifiers: WordDocumentBuilder.modifier(WordSprm.styleSeparator, 1)),
                Paragraph("next"),
            ]),
            "<p>web only spec vanish</p>\n<p>next</p>\n"
        )
    }

    func testAHiddenCellKeepsItsPlaceInTheRow() throws {
        let body = try body([
            Paragraph(runs: [Run("hidden", hidden: 1)], modifiers: inTable, mark: 0x07),
            Paragraph("kept", modifiers: inTable, mark: 0x07),
            Paragraph("", modifiers: rowEnd, mark: 0x07),
        ])
        XCTAssertEqual(body, "<table>\n<tr><td></td><td><p>kept</p>\n</td></tr>\n</table>\n")
    }

    func testHiddenTextInFootnotesIsNotReadEither() throws {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [Paragraph("Body")]
        builder.stories[.footnotes] = [Paragraph(runs: [Run("noted "), Run("secret", hidden: 1)])]
        XCTAssertEqual(try body(of: builder.build()), "<p>Body</p>\n<p>noted</p>\n")
    }

    func testTheRealSampleWithHiddenTextReadsOnlyItsVisibleParagraphs() throws {
        // Five paragraphs hold the letter S; the rest of the file is text
        // made hidden by sprmCFVanish 0x81, in paragraphs and table cells.
        // textutil leaves the same text out.
        let body = try sampleBody("doc/libreoffice-tdf102334_hiddenText.doc", pages: false)
        let text = body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        XCTAssertEqual(text.split(whereSeparator: \.isWhitespace).map(String.init), ["S", "S", "S", "S", "S"], body)
    }

    // MARK: - Fields

    func testAFieldKeepsItsResultAndDropsItsInstruction() throws {
        let text = "See \u{13} HYPERLINK \"http://example.com\" \u{14}the site\u{15} for more."
        XCTAssertEqual(try body([Paragraph(text)]), "<p>See the site for more.</p>\n")
    }

    func testNestedFieldsKeepOnlyTheInnermostResultsOfTheOutermostResult() throws {
        // The outer instruction holds a field; its result holds one too.
        let text = "A\u{13} IF \u{13} PAGE \u{14}7\u{15} > 1 \u{14}outer \u{13} NUMPAGES \u{14}9\u{15} result\u{15}Z"
        XCTAssertEqual(try body([Paragraph(text)]), "<p>Aouter 9 resultZ</p>\n")
    }

    func testAFieldWithNoSeparatorIsAllInstruction() throws {
        XCTAssertEqual(try body([Paragraph("a\u{13} PAGE \u{15}b")]), "<p>ab</p>\n")
    }

    func testAFieldThatSpansParagraphsKeepsItsResultsParagraphs() throws {
        // A table of contents: the instruction in the first paragraph, the
        // result in the next two.
        let paragraphs = [Paragraph("\u{13} TOC \\o \u{14}Chapter one"), Paragraph("Chapter two\u{15}"), Paragraph("After")]
        XCTAssertEqual(try body(paragraphs), "<p>Chapter one</p>\n<p>Chapter two</p>\n<p>After</p>\n")
    }

    func testStrayFieldMarksAreIgnored() throws {
        XCTAssertEqual(try body([Paragraph("a\u{14}b\u{15}c")]), "<p>abc</p>\n")
    }

    // MARK: - Headings

    func testHeadingStylesOneToNineAreHeadingsOneToSix() throws {
        let paragraphs = (1...9).map { Paragraph("Level \($0)", style: $0) }
        let expected = (1...9).map { "<h\(min($0, 6))>Level \($0)</h\(min($0, 6))>\n" }.joined()
        XCTAssertEqual(try body(paragraphs), expected)
    }

    func testAParagraphOutlineLevelMakesAHeadingOfANormalParagraph() throws {
        let outline = { (level: Int) in WordDocumentBuilder.modifier(WordSprm.outlineLevel, level) }
        let body = try body([
            Paragraph("Zero", modifiers: outline(0)), Paragraph("Two", modifiers: outline(2)),
            Paragraph("Eight", modifiers: outline(8)), Paragraph("Body", modifiers: outline(9)),
        ])
        XCTAssertEqual(body, "<h1>Zero</h1>\n<h3>Two</h3>\n<h6>Eight</h6>\n<p>Body</p>\n")
    }

    func testADirectOutlineLevelOnHeadingOneToNineIsIgnoredAndOnAStyleBasedOnOneIsNot() throws {
        // [MS-DOC] sprmPOutLvl: "This MUST be ignored if the paragraph has an
        // istd that is greater than or equal to 0x1 and less than or equal to 0x9."
        var builder = WordDocumentBuilder()
        // Index 12 is based on Heading 2 and says nothing of its own.
        builder.styles.append(WordDocumentBuilder.Style(basedOn: 2))
        let outline = { (level: Int) in WordDocumentBuilder.modifier(WordSprm.outlineLevel, level) }
        builder.paragraphs = [
            Paragraph("Heading 2 says body text", style: 2, modifiers: outline(9)),
            Paragraph("Heading 2 says level 5", style: 2, modifiers: outline(4)),
            // A style that is based on a heading is not one: its paragraph's own level counts.
            Paragraph("Based on a heading, body text", style: 12, modifiers: outline(9)),
            Paragraph("Based on a heading, level 1", style: 12, modifiers: outline(0)),
        ]
        XCTAssertEqual(
            try body(of: builder.build()),
            "<h2>Heading 2 says body text</h2>\n<h2>Heading 2 says level 5</h2>\n"
                + "<p><strong>Based on a heading, body text</strong></p>\n<h1>Based on a heading, level 1</h1>\n"
        )
    }

    func testAStyleBasedOnAHeadingIsAHeadingAndOneWithItsOwnOutlineLevelUsesIt() throws {
        var builder = WordDocumentBuilder()
        // Index 12 is based on Heading 2 and says nothing; 13 is based on
        // Heading 2 and sets outline level 4; 14 is a user style that sets
        // body text.
        builder.styles += [
            WordDocumentBuilder.Style(basedOn: 2),
            WordDocumentBuilder.Style(basedOn: 2, outlineLevel: 3),
            WordDocumentBuilder.Style(basedOn: 1, outlineLevel: 9),
        ]
        builder.paragraphs = [Paragraph("a", style: 12), Paragraph("b", style: 13), Paragraph("c", style: 14)]
        XCTAssertEqual(try body(of: builder.build()), "<h2>a</h2>\n<h4>b</h4>\n<p><strong>c</strong></p>\n")
    }

    func testTitleAndSubtitleStylesAreHeadingsOneAndTwoAsInDOCX() throws {
        var builder = WordDocumentBuilder()
        builder.styles += [WordDocumentBuilder.Style(builtInIdentifier: 62), WordDocumentBuilder.Style(builtInIdentifier: 74)]
        builder.paragraphs = [Paragraph("T", style: 12), Paragraph("S", style: 13)]
        XCTAssertEqual(try body(of: builder.build()), "<h1>T</h1>\n<h2>S</h2>\n")
    }

    func testAStyleLoopDoesNotHangAndReadsAsBodyText() throws {
        var builder = WordDocumentBuilder()
        builder.styles += [WordDocumentBuilder.Style(basedOn: 13), WordDocumentBuilder.Style(basedOn: 12)]
        builder.paragraphs = [Paragraph("loop", style: 12)]
        XCTAssertEqual(try body(of: builder.build()), "<p>loop</p>\n")
    }

    func testAHeadingCarriesNoEmphasis() throws {
        let body = try body([Paragraph(runs: [Run("Bold "), Run("italic", italic: 1)], style: 1)])
        XCTAssertEqual(body, "<h1>Bold italic</h1>\n")
    }

    // MARK: - Guessed Headings

    /// A body of ordinary paragraphs (10 point) for the guess to measure.
    private func bodyText() -> [Paragraph] {
        (1...3).map { Paragraph("This is ordinary body text number \($0), long enough to outweigh any short heading in the count of characters.") }
    }

    func testLargerParagraphsAreHeadingsRankedBySizeWhenTheDocumentHasNoRealOnes() throws {
        let body = try body([
            Paragraph(runs: [Run("Big", fontSize: 40)]), Paragraph(runs: [Run("Medium", fontSize: 28)]),
            Paragraph(runs: [Run("Medium again", fontSize: 28)]), Paragraph(runs: [Run("Small", fontSize: 24)]),
        ] + bodyText())
        XCTAssertTrue(body.hasPrefix("<h1>Big</h1>\n<h2>Medium</h2>\n<h2>Medium again</h2>\n<h3>Small</h3>\n<p>This is"), body)
    }

    func testAShortParagraphWhollyInBoldAtTheBodySizeIsTheNextLevel() throws {
        let body = try body([
            Paragraph(runs: [Run("Large", fontSize: 32)]), Paragraph(runs: [Run("Just bold", bold: 1)]),
            Paragraph(runs: [Run("Some "), Run("bold", bold: 1), Run(" words")]),
        ] + bodyText())
        XCTAssertTrue(body.hasPrefix("<h1>Large</h1>\n<h2>Just bold</h2>\n<p>Some <strong>bold</strong> words</p>\n"), body)
    }

    func testNoGuessIsMadeWhenTheDocumentHasARealHeading() throws {
        let body = try body([
            Paragraph("Real", style: 1), Paragraph(runs: [Run("Large", fontSize: 32)]), Paragraph(runs: [Run("Just bold", bold: 1)]),
        ] + bodyText())
        XCTAssertTrue(body.hasPrefix("<h1>Real</h1>\n<p>Large</p>\n<p><strong>Just bold</strong></p>\n"), body)
    }

    func testLongParagraphsSingleLettersAndTablesAreNotGuessedToBeHeadings() throws {
        let long = String(repeating: "word ", count: 30)
        let inTable = WordDocumentBuilder.modifier(WordSprm.inTable, 1)
        let body = try body([
            Paragraph(runs: [Run(long, fontSize: 40)]), Paragraph(runs: [Run("W", fontSize: 40)]),
            Paragraph(runs: [Run("Cell", fontSize: 40)], modifiers: inTable, mark: 0x07),
            Paragraph("", modifiers: inTable + WordDocumentBuilder.modifier(WordSprm.rowEnd, 1), mark: 0x07),
        ] + bodyText())
        XCTAssertFalse(body.contains("<h"), body)
    }

    func testADocumentWhollyInBoldHasNoHeadingsFromBold() throws {
        let bold = (1...3).map { Paragraph(runs: [Run("Bold line number \($0)", bold: 1)]) }
        XCTAssertFalse(try body(bold).contains("<h"))
    }

    func testAHeadingGuessedFromSizeCarriesNoEmphasis() throws {
        let body = try body([Paragraph(runs: [Run("Big ", bold: 1, fontSize: 40), Run("title", bold: 1, fontSize: 40)])] + bodyText())
        XCTAssertTrue(body.hasPrefix("<h1>Big title</h1>\n"), body)
    }

    func testSizesComeFromStylesToo() throws {
        var builder = WordDocumentBuilder()
        // Style 12 is a paragraph style set in 30 point.
        builder.styles.append(WordDocumentBuilder.Style(basedOn: 0, fontSize: 60))
        builder.paragraphs = [Paragraph("Styled big", style: 12)] + bodyText()
        XCTAssertTrue(try body(of: builder.build()).hasPrefix("<h1>Styled big</h1>\n"))
    }

    // MARK: - Emphasis

    func testBoldAndItalicRunsBecomeStrongAndEm() throws {
        let body = try body([Paragraph(runs: [
            Run("plain "), Run("bold", bold: 1), Run(" and "), Run("italic", italic: 1), Run(" and "),
            Run("both", bold: 1, italic: 1), Run(" end"),
        ])])
        XCTAssertEqual(body, "<p>plain <strong>bold</strong> and <em>italic</em> and <strong><em>both</em></strong> end</p>\n")
    }

    func testWhiteSpaceAtTheEdgesOfARunStaysOutsideItsTags() throws {
        let body = try body([Paragraph(runs: [Run("one"), Run(" bold ", bold: 1), Run("two")])])
        XCTAssertEqual(body, "<p>one <strong>bold</strong> two</p>\n")
    }

    func testAnEmphasisThatContinuesAcrossRunsStaysOpen() throws {
        let body = try body([Paragraph(runs: [Run("a ", bold: 1), Run("b", bold: 1, italic: 0), Run(" c", bold: 1)])])
        XCTAssertEqual(body, "<p><strong>a b c</strong></p>\n")
    }

    func testToggleValuesAreRelativeToTheStyle() throws {
        var builder = WordDocumentBuilder()
        // Style 12 is a paragraph style that is bold and italic.
        builder.styles.append(WordDocumentBuilder.Style(basedOn: 0, bold: 1, italic: 1))
        // 0x80 keeps the style's value, 0x81 reverses it, 0 turns it off.
        builder.paragraphs = [Paragraph(runs: [
            Run("keep", bold: 0x80), Run(" "), Run("flip", bold: 0x81), Run(" "), Run("off", bold: 0, italic: 0),
        ], style: 12)]
        XCTAssertEqual(try body(of: builder.build()), "<p><strong><em>keep</em></strong> <em>flip</em> off</p>\n")
    }

    func testToggleValuesOfAStyleChainAndOfACharacterStyle() throws {
        var builder = WordDocumentBuilder()
        // 12: paragraph style, bold. 13: based on 12, reverses bold (0x81).
        // Character style 10 is bold; character style 11 is italic.
        builder.styles.append(WordDocumentBuilder.Style(basedOn: 0, bold: 1))
        builder.styles.append(WordDocumentBuilder.Style(basedOn: 12, bold: 0x81))
        builder.paragraphs = [
            // A heading, so that no bold paragraph is guessed to be one.
            Paragraph("Heading", style: 1),
            Paragraph(runs: [Run("bold style")], style: 12),
            Paragraph(runs: [Run("reversed to plain")], style: 13),
            Paragraph(runs: [Run("char bold", characterStyle: 10), Run(" "), Run("char italic", characterStyle: 11)]),
            // A bold character style reversed by a direct 0x81: plain.
            Paragraph(runs: [Run("flipped", bold: 0x81, characterStyle: 10)]),
        ]
        XCTAssertEqual(
            try body(of: builder.build()),
            "<h1>Heading</h1>\n<p><strong>bold style</strong></p>\n<p>reversed to plain</p>\n"
                + "<p><strong>char bold</strong> <em>char italic</em></p>\n<p>flipped</p>\n"
        )
    }

    func testEmphasisIsKeptInsideTableCells() throws {
        let body = try body([
            Paragraph(runs: [Run("Head", bold: 1)], modifiers: inTable, mark: 0x07),
            Paragraph("", modifiers: rowEnd, mark: 0x07),
        ])
        XCTAssertEqual(body, "<table>\n<tr><td><p><strong>Head</strong></p>\n</td></tr>\n</table>\n")
    }

    // MARK: - Tables

    func testATableWritesRowsAndCells() throws {
        let body = try body([
            Paragraph("Before"),
            Paragraph("a", modifiers: inTable, mark: 0x07), Paragraph("b", modifiers: inTable, mark: 0x07),
            Paragraph("", modifiers: rowEnd, mark: 0x07),
            Paragraph("c", modifiers: inTable, mark: 0x07), Paragraph("d", modifiers: inTable, mark: 0x07),
            Paragraph("", modifiers: rowEnd, mark: 0x07),
            Paragraph("After"),
        ])
        XCTAssertEqual(
            body,
            "<p>Before</p>\n<table>\n<tr><td><p>a</p>\n</td><td><p>b</p>\n</td></tr>\n<tr><td><p>c</p>\n</td><td><p>d</p>\n</td></tr>\n</table>\n<p>After</p>\n"
        )
    }

    func testACellWithSeveralParagraphsAndAnEmptyCell() throws {
        let body = try body([
            Paragraph("one", modifiers: inTable), Paragraph("two", modifiers: inTable, mark: 0x07),
            Paragraph("", modifiers: inTable, mark: 0x07),
            Paragraph("", modifiers: rowEnd, mark: 0x07),
        ])
        XCTAssertEqual(body, "<table>\n<tr><td><p>one</p>\n<p>two</p>\n</td><td></td></tr>\n</table>\n")
    }

    func testATableThatEndsTheDocumentWithoutARowMarkIsClosed() throws {
        let body = try body([Paragraph("a", modifiers: inTable, mark: 0x07)])
        XCTAssertEqual(body, "<table>\n<tr><td><p>a</p>\n</td></tr>\n</table>\n")
    }

    func testATableInsideACellIsReadIntoTheCell() throws {
        let depth = { (level: Int) in WordDocumentBuilder.modifier(WordSprm.inTable, 1) + [UInt8(0x49), 0x66, UInt8(level), 0, 0, 0] }
        let body = try body([
            Paragraph("outer", modifiers: depth(1)),
            Paragraph("inner a", modifiers: depth(2), mark: 0x07), Paragraph("inner b", modifiers: depth(2), mark: 0x07),
            Paragraph("", modifiers: depth(2) + WordDocumentBuilder.modifier(WordSprm.rowEnd, 1), mark: 0x07),
            Paragraph("outer end", modifiers: depth(1), mark: 0x07),
            Paragraph("", modifiers: depth(1) + WordDocumentBuilder.modifier(WordSprm.rowEnd, 1), mark: 0x07),
        ])
        XCTAssertEqual(
            body,
            "<table>\n<tr><td><p>outer</p>\n<p>inner a</p>\n<p>inner b</p>\n<p>outer end</p>\n</td></tr>\n</table>\n"
        )
    }

    func testAHeadingStyleInsideACellIsAParagraphWithItsEmphasis() throws {
        let body = try body([
            Paragraph("Cell title", style: 1, modifiers: inTable, mark: 0x07), Paragraph("", modifiers: rowEnd, mark: 0x07),
        ])
        XCTAssertEqual(body, "<table>\n<tr><td><p><strong>Cell title</strong></p>\n</td></tr>\n</table>\n")
    }

    // MARK: - Pages

    func testPageOneStartsTheBodyAndAnExplicitBreakStartsPageTwoBeforeItsFirstLetter() throws {
        let body = try body([Paragraph("one and\u{0C}two"), Paragraph("three")], pages: true)
        XCTAssertEqual(body, span(1) + "<p>one and \(span(2))two</p>\n<p>three</p>\n")
    }

    func testABreakBetweenWordsThatAlreadyHaveWhiteSpaceAddsNone() throws {
        let body = try body([Paragraph("one \u{0C} two")], pages: true)
        XCTAssertEqual(body, span(1) + "<p>one \(span(2))two</p>\n")
    }

    func testABreakAtTheStartOfAParagraphPutsThePageInsideIt() throws {
        let body = try body([Paragraph("A"), Paragraph("\u{0C}B")], pages: true)
        XCTAssertEqual(body, span(1) + "<p>A</p>\n<p>\(span(2))B</p>\n")
    }

    func testAPageBreakBeforeEmphasisKeepsTheSpanOutsideTheTags() throws {
        let body = try body([Paragraph(runs: [Run("go\u{0C}"), Run("bold", bold: 1)])], pages: true)
        XCTAssertEqual(body, span(1) + "<p>go \(span(2))<strong>bold</strong></p>\n")
    }

    func testBreaksWithNoLetterOrDigitAfterThemBeginNoPage() throws {
        XCTAssertEqual(try body([Paragraph("last words\u{0C}\u{0C}")], pages: true), span(1) + "<p>last words</p>\n")
        // A break and then only punctuation.
        XCTAssertEqual(try body([Paragraph("last\u{0C}...")], pages: true), span(1) + "<p>last ...</p>\n")
    }

    func testTwoBreaksBeforeOneLetterGiveTwoPagesThere() throws {
        let body = try body([Paragraph("x\u{0C}\u{0C}y")], pages: true)
        XCTAssertEqual(body, span(1) + "<p>x \(span(2))\(span(3))y</p>\n")
    }

    func testADocumentWithNoLetterOrDigitHasNoPages() throws {
        XCTAssertEqual(try body([Paragraph("... \u{0C} ---")], pages: true), "<p>... ---</p>\n")
        XCTAssertEqual(try body([], pages: true), "")
    }

    func testNoPagesAreWrittenWhenNoneAreAsked() throws {
        let body = try body([Paragraph("one\u{0C}two")], pages: false)
        XCTAssertEqual(body, "<p>one two</p>\n")
    }

    func testASectionBreakThatStartsANewPageIsAPageAndEndsItsParagraph() throws {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [Paragraph("first section", mark: 0x0C), Paragraph("second section")]
        // The second section's break kind is new page (2), or not given.
        for kind in [2, 3, 4, nil] as [Int?] {
            builder.sectionBreaks = [(0, kind)]
            XCTAssertEqual(
                try body(of: builder.build(), pages: true),
                span(1) + "<p>first section</p>\n<p>\(span(2))second section</p>\n",
                "kind \(String(describing: kind))"
            )
        }
    }

    func testAContinuousSectionBreakIsNotAPageButStillEndsTheParagraph() throws {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [Paragraph("first section", mark: 0x0C), Paragraph("second section")]
        for kind in [0, 1] {
            builder.sectionBreaks = [(0, kind)]
            XCTAssertEqual(
                try body(of: builder.build(), pages: true),
                span(1) + "<p>first section</p>\n<p>second section</p>\n",
                "kind \(kind)"
            )
        }
    }

    func testAFormFeedThatDoesNotEndASectionIsAPageBreakEvenWithSections() throws {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [Paragraph("a\u{0C}b", mark: 0x0C), Paragraph("c")]
        builder.sectionBreaks = [(0, 0)]
        XCTAssertEqual(try body(of: builder.build(), pages: true), span(1) + "<p>a \(span(2))b</p>\n<p>c</p>\n")
    }

    func testADocumentWithMoreBreaksThanPagesAreNumberedIsReadWithoutPages() throws {
        var builder = WordDocumentBuilder()
        // One more break than the limit allows.
        builder.paragraphs = [Paragraph(String(repeating: "a\u{0C}", count: TextutilPageBreaks.maximumPages) + "z")]
        let body = try body(of: builder.build(), pages: true)
        XCTAssertFalse(body.contains("doc-pagebreak"))
        XCTAssertTrue(body.hasPrefix("<p>a a a a"))
        XCTAssertTrue(body.hasSuffix("a z</p>\n"))
    }

    func testADocumentWithExactlyTheMostBreaksKeepsItsPages() throws {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [Paragraph(String(repeating: "a\u{0C}", count: TextutilPageBreaks.maximumPages - 1) + "z")]
        let body = try body(of: builder.build(), pages: true)
        XCTAssertTrue(body.contains("aria-label=\"\(TextutilPageBreaks.maximumPages)\""))
    }

    // MARK: - Page Break Before

    private let pageBreakBefore = WordDocumentBuilder.modifier(WordSprm.pageBreakBefore, 1)

    func testAParagraphWithPageBreakBeforeBeginsAPageBeforeItsFirstWords() throws {
        let body = try body([Paragraph("One"), Paragraph("Two", modifiers: pageBreakBefore), Paragraph("Three")], pages: true)
        XCTAssertEqual(body, span(1) + "<p>One</p>\n<p>\(span(2))Two</p>\n<p>Three</p>\n")
    }

    func testPageBreakBeforeOnTheFirstParagraphIsNotASecondPage() throws {
        let body = try body([Paragraph("One", modifiers: pageBreakBefore), Paragraph("Two")], pages: true)
        XCTAssertEqual(body, span(1) + "<p>One</p>\n<p>Two</p>\n")
    }

    func testAStyleWithPageBreakBeforeAndTheStylesBasedOnItBeginPages() throws {
        var builder = WordDocumentBuilder()
        // 12 begins pages; 13 is based on 12 and says nothing; 14 is based on 12 and turns it off.
        builder.styles += [
            WordDocumentBuilder.Style(basedOn: 0, pageBreakBefore: 1),
            WordDocumentBuilder.Style(basedOn: 12),
            WordDocumentBuilder.Style(basedOn: 12, pageBreakBefore: 0),
        ]
        builder.paragraphs = [
            Paragraph("a"), Paragraph("b", style: 12), Paragraph("c", style: 13), Paragraph("d", style: 14),
            // The paragraph's own setting wins over its style, either way.
            Paragraph("e", style: 12, modifiers: WordDocumentBuilder.modifier(WordSprm.pageBreakBefore, 0)),
            Paragraph("f", modifiers: pageBreakBefore),
        ]
        XCTAssertEqual(
            try body(of: builder.build(), pages: true),
            span(1) + "<p>a</p>\n<p>\(span(2))b</p>\n<p>\(span(3))c</p>\n<p>d</p>\n<p>e</p>\n<p>\(span(4))f</p>\n"
        )
    }

    func testPageBreakBeforeOnAHeadingStyleOpensTheHeadingOnANewPage() throws {
        var builder = WordDocumentBuilder()
        builder.styles[1] = WordDocumentBuilder.Style(builtInIdentifier: 1, basedOn: 0, outlineLevel: 0, bold: 1, pageBreakBefore: 1)
        builder.paragraphs = [Paragraph("Intro"), Paragraph("Chapter", style: 1), Paragraph("Text")]
        XCTAssertEqual(try body(of: builder.build(), pages: true), span(1) + "<p>Intro</p>\n<h1>\(span(2))Chapter</h1>\n<p>Text</p>\n")
    }

    func testPageBreakBeforeAfterAFormFeedOrSectionBreakIsNotAnEmptyPage() throws {
        // A form feed, and then a paragraph that begins a page: one break.
        XCTAssertEqual(
            try body([Paragraph("A\u{0C}"), Paragraph("B", modifiers: pageBreakBefore)], pages: true),
            span(1) + "<p>A</p>\n<p>\(span(2))B</p>\n"
        )
        var builder = WordDocumentBuilder()
        builder.paragraphs = [Paragraph("A", mark: 0x0C), Paragraph("B", modifiers: pageBreakBefore)]
        builder.sectionBreaks = [(0, 2)]
        XCTAssertEqual(try body(of: builder.build(), pages: true), span(1) + "<p>A</p>\n<p>\(span(2))B</p>\n")
    }

    func testPageBreakBeforeNeedsWordsAndAskedForPagesAndIsNotForTables() throws {
        // An empty paragraph begins no page, and neither do two together.
        XCTAssertEqual(
            try body([Paragraph("A"), Paragraph("", modifiers: pageBreakBefore), Paragraph("B")], pages: true),
            span(1) + "<p>A</p>\n<p>B</p>\n"
        )
        XCTAssertEqual(try body([Paragraph("A"), Paragraph("B", modifiers: pageBreakBefore)], pages: false), "<p>A</p>\n<p>B</p>\n")
        let inTable = WordDocumentBuilder.modifier(WordSprm.inTable, 1)
        XCTAssertEqual(
            try body([Paragraph("A"), Paragraph("cell", modifiers: inTable + pageBreakBefore, mark: 0x07)], pages: true),
            span(1) + "<p>A</p>\n<table>\n<tr><td><p>cell</p>\n</td></tr>\n</table>\n"
        )
    }

    func testTwoParagraphsThatBeginPagesAreTwoPages() throws {
        XCTAssertEqual(
            try body([Paragraph("A"), Paragraph("B", modifiers: pageBreakBefore), Paragraph("C", modifiers: pageBreakBefore)], pages: true),
            span(1) + "<p>A</p>\n<p>\(span(2))B</p>\n<p>\(span(3))C</p>\n"
        )
    }

    // MARK: - Documents Left Alone or Refused

    func testAWord95DocumentIsLeftToTextutil() throws {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [Paragraph("old")]
        builder.version = 0x0068
        XCTAssertNil(try WordDocumentReader.html(from: builder.build(), includesPages: true))
        // And one from before Word 95, by its other wIdent.
        builder.version = 0x0065
        builder.identifier = 0xA5DC
        XCTAssertNil(try WordDocumentReader.html(from: builder.build(), includesPages: true))
    }

    func testAnEncryptedDocumentIsRefusedWithThePasswordSentence() throws {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [Paragraph("secret")]
        builder.isEncrypted = true
        XCTAssertThrowsError(try WordDocumentReader.html(from: builder.build(), includesPages: true)) { error in
            XCTAssertEqual(error as? PasswordProtectedDocument, PasswordProtectedDocument())
            XCTAssertEqual(
                error.localizedDescription,
                "This document is protected by a password. Save a copy without the password, then import that copy."
            )
        }
    }

    func testAFileThatIsNotAWordDocumentIsUnreadable() throws {
        let unreadable = TextutilConverter.Failure.unreadable(.doc)
        // Plain text.
        XCTAssertThrowsError(try WordDocumentReader.html(from: Data("Hello".utf8), includesPages: true)) {
            XCTAssertEqual($0 as? TextutilConverter.Failure, unreadable)
        }
        // A compound file with no WordDocument stream.
        var file = CompoundFileBuilder()
        file.streams = [("Workbook", [1, 2, 3])]
        XCTAssertThrowsError(try WordDocumentReader.html(from: file.build().data, includesPages: true)) {
            XCTAssertEqual($0 as? TextutilConverter.Failure, unreadable)
        }
        // A WordDocument stream that is not a FIB.
        file.streams = [("WordDocument", [UInt8](repeating: 7, count: 2000)), ("1Table", [0])]
        XCTAssertThrowsError(try WordDocumentReader.html(from: file.build().data, includesPages: true)) {
            XCTAssertEqual($0 as? TextutilConverter.Failure, unreadable)
        }
        XCTAssertEqual(unreadable.localizedDescription, "This file could not be read as a Word 97-2003 document. It may be damaged, or another kind of file.")
    }

    func testTheReaderIsOnForEveryPlatform() {
        XCTAssertTrue(WordDocumentReader.isOn)
    }
}
