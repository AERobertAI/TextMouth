import XCTest
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
        XCTAssertTrue(body.contains("<p><strong>Harbour Notes</strong></p>"), body)
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
        // The LibreOffice template holds one empty paragraph.
        XCTAssertEqual(try sampleBody("dot/libreoffice-tdf120761_zOrder.dot", pages: false), "")
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

    func testBodyTextOutlineLevelOverridesAHeadingStyle() throws {
        // The paragraph keeps the style's bold: it is body text, so it shows.
        let body = try body([Paragraph("Not a heading", style: 2, modifiers: WordDocumentBuilder.modifier(WordSprm.outlineLevel, 9))])
        XCTAssertEqual(body, "<p><strong>Not a heading</strong></p>\n")
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
            Paragraph(runs: [Run("bold style")], style: 12),
            Paragraph(runs: [Run("reversed to plain")], style: 13),
            Paragraph(runs: [Run("char bold", characterStyle: 10), Run(" "), Run("char italic", characterStyle: 11)]),
            // A bold character style reversed by a direct 0x81: plain.
            Paragraph(runs: [Run("flipped", bold: 0x81, characterStyle: 10)]),
        ]
        XCTAssertEqual(
            try body(of: builder.build()),
            "<p><strong>bold style</strong></p>\n<p>reversed to plain</p>\n"
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

    func testTheReaderIsOffOnTheMacUntilItIsChecked() {
        #if os(macOS)
        XCTAssertFalse(WordDocumentReader.isOn)
        #else
        XCTAssertTrue(WordDocumentReader.isOn)
        #endif
    }
}
