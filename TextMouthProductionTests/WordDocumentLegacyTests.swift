import XCTest
import SwiftSoup
@testable import TextMouth

/// The Word reader's reading of Word 6 and Word 95 documents (`WordFileInformationBlock.Layout.legacy`),
/// tested on the real samples in `TestData/format-samples/doc6` and on documents built in code
/// (`WordLegacyDocumentBuilder`) for what the samples do not hold: heading styles, emphasis and its
/// toggles, hidden text and tracked deletions, pages and sections, tables, notes, numbering, code pages,
/// and Fast Save. The policy every reader shares (hidden text, deletions, notes) is asked of the old
/// layout the same way `WordDocumentReaderTests` asks it of Word 97's.
final class WordDocumentLegacyTests: XCTestCase {

    // MARK: - Helpers

    typealias Builder = WordLegacyDocumentBuilder
    typealias Paragraph = Builder.Paragraph
    typealias Run = Builder.Run

    /// The inner HTML of the body of the document `data` is read as.
    private func body(
        of data: Data, pages: Bool = false, speaksNumbers: Bool = WordDocumentReader.speaksListNumbers,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let html = try XCTUnwrap(
            WordDocumentReader.html(from: data, includesPages: pages, speaksListNumbers: speaksNumbers), file: file, line: line
        )
        let start = try XCTUnwrap(html.range(of: "<body>\n"), file: file, line: line)
        let end = try XCTUnwrap(html.range(of: "</body>"), file: file, line: line)
        return String(html[start.upperBound..<end.lowerBound])
    }

    /// The body of the document made from `paragraphs`, after `configure` has changed the builder.
    private func body(
        _ paragraphs: [Paragraph], pages: Bool = false, speaksNumbers: Bool = WordDocumentReader.speaksListNumbers,
        file: StaticString = #filePath, line: UInt = #line, configure: (inout Builder) -> Void = { _ in }
    ) throws -> String {
        var builder = Builder()
        builder.paragraphs = paragraphs
        configure(&builder)
        return try body(of: builder.build(), pages: pages, speaksNumbers: speaksNumbers, file: file, line: line)
    }

    private func span(_ page: Int) -> String {
        "<span role=\"doc-pagebreak\" aria-label=\"\(page)\"></span>"
    }

    /// The body of the sample at `path` (in `doc6`).
    private func sampleBody(_ name: String, pages: Bool = false) throws -> String {
        try body(of: Data(contentsOf: formatSampleURL("doc6/\(name)")), pages: pages)
    }

    // MARK: - The Real Samples

    func testWord6ReadsItsOneLine() throws {
        XCTAssertEqual(try sampleBody("poi-Word6.doc"), "<p>The quick brown fox jumps over the lazy dog</p>\n")
    }

    func testWord95ReadsItsParagraphsAndLeavesTheCodePageToTheWesternFonts() throws {
        // Its font table holds Far East fonts beside the Western ones, and its text is Western.
        let body = try sampleBody("poi-Word95.doc")
        XCTAssertTrue(body.contains("<p>The quick brown fox jumps over the lazy dog</p>"), body)
        XCTAssertTrue(body.contains("Paragraph 2"), body)
        XCTAssertTrue(body.contains("Paragraph 3."), body)
    }

    func testTheSectionSamplesReadTheirTextWhateverTheirSectionsDo() throws {
        let body = try sampleBody("poi-Word6_sections.doc")
        XCTAssertTrue(body.contains("This is a test."), body)
        XCTAssertTrue(body.contains("This is a new section."), body)
        // Runs of spaces in the document are kept as they are; compare the words.
        let longer = try sampleBody("poi-Word6_sections2.doc").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(longer.contains("STATEMENT"), longer)
        XCTAssertTrue(longer.contains("INSOLVENCY PRACTICE 10 (SCOTLAND)"), longer)
        XCTAssertTrue(longer.contains("PROXY FORMS"), longer)
    }

    func testTheSectionSampleWhoseSectionsAreContinuousHasOnePage() throws {
        // Both of its sections begin continuously (sprmSBkc 0), so the form feeds that end sections begin no page.
        let body = try sampleBody("poi-Word6_sections.doc", pages: true)
        XCTAssertFalse(body.contains(span(2)), body)
    }

    func testTheJapaneseSampleReadsShiftJisFromTheTwoByteUnitsAndItsFonts() throws {
        // wIdent 0xA697, fExtChar, an English language id, and SHIFTJIS_CHARSET fonts.
        let body = try sampleBody("libreoffice-ooo17498-1.doc")
        // The second line is larger than the rest: a heading, as in textutil's reading of the file.
        XCTAssertTrue(body.hasPrefix("<p>管理組合役員各位</p>\n<h1>理事会開催のお知らせ</h1>\n"), body)
        XCTAssertTrue(body.contains("2001/9/2"), body)
    }

    func testTheChineseAndKoreanSamplesReadTheirOwnCodePages() throws {
        // GB2312_CHARSET fonts, CHINESEBIG5_CHARSET fonts, and HANGEUL_CHARSET fonts.
        XCTAssertTrue(try sampleBody("libreoffice-ooo17498-3.doc").hasPrefix("<p>创建新文档</p>\n"))
        XCTAssertTrue(try sampleBody("libreoffice-ooo17498-4.doc").hasPrefix("<p>建立新文件</p>\n"))
        XCTAssertTrue(try sampleBody("libreoffice-ooo17498-2.doc").hasPrefix("<p>새 문서를 만들려면</p>\n"))
    }

    func testTheRussianSampleIsReadInCyrillicBecauseOfItsFont() throws {
        // The language id says English; the font "Times New Roman Cyr" says Windows-1251.
        let body = try sampleBody("poi-word95err.doc")
        XCTAssertTrue(body.contains("Компания"), body)
    }

    func testTheFastSavedWord95SampleReadsItsPiecesInTheOrderOfTheText() throws {
        // wIdent 0xA699, nFib 0x68, two-byte characters in a piece table, English text.
        let body = try body(of: Data(contentsOf: formatSampleURL("doc/poi-Bug51944.doc")))
        // The first words of the first piece in the text, which the stream stores after its second.
        XCTAssertTrue(body.hasPrefix("<p>By Post and Fax (5555 5555)</p>\n"), body)
        XCTAssertTrue(body.contains("Attention"), body)
        XCTAssertTrue(body.contains("Many thanks for"), body)
        // A unit that is a stray pair of single bytes (0x350D: a "5" and a paragraph mark) is kept as the two.
        XCTAssertTrue(body.contains("5</p>\n<p>9-55"), body)
        // And Western punctuation in a document with Far East fonts is Windows-1252: 0x92 is a right quote.
        XCTAssertTrue(body.contains("\u{2019}"), body)
    }

    func testTheOutlineNumberedSampleIsAListWhoseNumbersAreSilentOrWords() throws {
        let data = try Data(contentsOf: formatSampleURL("doc/libreoffice-tdf150197_anlv2ListFormat.doc"))
        let silent = try body(of: data, speaksNumbers: false)
        let words = try body(of: data, speaksNumbers: true)
        XCTAssertTrue(silent.contains("<ol>"), silent)
        XCTAssertTrue(silent.contains("<li>This is 1</li>") || silent.contains("<li>This is 1<"), silent)
        XCTAssertNotEqual(silent, words)
    }

    // MARK: - Text and Structure

    func testParagraphsAreEscapedAndKeepTheirOrder() throws {
        XCTAssertEqual(
            try body([Paragraph("Fish & <chips>"), Paragraph("Second > first")]),
            "<p>Fish &amp; &lt;chips&gt;</p>\n<p>Second &gt; first</p>\n"
        )
    }

    func testHeadingStylesOneToThreeMakeHeadings() throws {
        let body = try body([
            Paragraph("Chapter", style: 1), Paragraph("Section", style: 2), Paragraph("Deep", style: 3), Paragraph("Text"),
        ])
        XCTAssertEqual(body, "<h1>Chapter</h1>\n<h2>Section</h2>\n<h3>Deep</h3>\n<p>Text</p>\n")
    }

    func testAStyleBasedOnAHeadingIsAHeadingAndAStyleNamedNothingIsBodyText() throws {
        let body = try body(
            [Paragraph("Based", style: 4), Paragraph("Missing", style: 40), Paragraph("None", style: 0xFFFF)]
        ) { $0.styles.append(Builder.Style(sti: 100, basedOn: 1, name: "Chapter title")) }
        XCTAssertEqual(body, "<h1>Based</h1>\n<p>Missing</p>\n<p>None</p>\n")
    }

    func testBoldAndItalicRunsAreEmphasis() throws {
        XCTAssertEqual(
            try body([Paragraph(runs: [Run("plain "), Run("bold run here", sprms: Builder.bold()), Run(" plain")])]),
            "<p>plain <strong>bold run here</strong> plain</p>\n"
        )
        XCTAssertEqual(
            try body([Paragraph(runs: [Run("plain "), Run("slanted", sprms: Builder.italic())])]),
            "<p>plain <em>slanted</em></p>\n"
        )
    }

    func testBoldIsAToggleThroughTheParagraphStyle() throws {
        let body = try body([
            // Most of the document is bold, so that a bold paragraph is not guessed to be a heading.
            Paragraph("The first paragraph is long, and set in the bold style, so that most of the document is bold.", style: 4),
            Paragraph("styled", style: 4),
            Paragraph(runs: [Run("off", sprms: Builder.bold(0))], style: 4),
            Paragraph(runs: [Run("reversed", sprms: Builder.bold(0x81))], style: 4),
            Paragraph(runs: [Run("kept", sprms: Builder.bold(0x80))], style: 4),
        ]) { $0.styles.append(Builder.Style(sti: 100, basedOn: 0, name: "Strong", characterSprms: Builder.bold())) }
        XCTAssertEqual(
            body,
            "<p><strong>The first paragraph is long, and set in the bold style, so that most of the document is bold.</strong></p>\n"
                + "<p><strong>styled</strong></p>\n<p>off</p>\n<p>reversed</p>\n<p><strong>kept</strong></p>\n"
        )
    }

    func testACharacterStyleTakesItsPropertiesFromTheStyleSheet() throws {
        // sprmCIstd (80) names a character style that is bold.
        let bold = Builder.Style(sti: 100, kind: 2, name: "Strong chars", characterSprms: Builder.bold())
        let body = try body([Paragraph(runs: [Run("a "), Run("b", sprms: Builder.sprm(80, [4, 0]))])]) { $0.styles.append(bold) }
        XCTAssertEqual(body, "<p>a <strong>b</strong></p>\n")
    }

    func testTablesAreMadeFromTheirCellMarksAndRowEnds() throws {
        let body = try body([
            Paragraph("a", sprms: Builder.inTable, mark: 0x07), Paragraph("b", sprms: Builder.inTable, mark: 0x07),
            Paragraph("", sprms: Builder.inTable + Builder.rowEnd, mark: 0x07),
            Paragraph("c", sprms: Builder.inTable, mark: 0x07),
            Paragraph("", sprms: Builder.inTable + Builder.rowEnd, mark: 0x07),
            Paragraph("After"),
        ])
        XCTAssertEqual(
            body,
            "<table>\n<tr><td><p>a</p>\n</td><td><p>b</p>\n</td></tr>\n<tr><td><p>c</p>\n</td></tr>\n</table>\n<p>After</p>\n"
        )
    }

    func testAHiddenCellKeepsItsPlaceInTheRow() throws {
        let body = try body([
            Paragraph(runs: [Run("hidden", sprms: Builder.hidden())], sprms: Builder.inTable, mark: 0x07),
            Paragraph("kept", sprms: Builder.inTable, mark: 0x07),
            Paragraph("", sprms: Builder.inTable + Builder.rowEnd, mark: 0x07),
        ])
        XCTAssertEqual(body, "<table>\n<tr><td></td><td><p>kept</p>\n</td></tr>\n</table>\n")
    }

    // MARK: - Hidden Text and Tracked Deletions

    func testHiddenTextIsNotReadAndItsWhiteSpaceGoesWithIt() throws {
        XCTAssertEqual(
            try body([Paragraph(runs: [Run("Seen "), Run("secret words ", sprms: Builder.hidden()), Run("seen again")])]),
            "<p>Seen seen again</p>\n"
        )
    }

    func testHiddenTextIsATogglePropertyLikeBoldAndItalic() throws {
        let hiddenStyle = Builder.Style(sti: 100, basedOn: 0, name: "Quiet", characterSprms: Builder.hidden())
        let body = try body([
            Paragraph(runs: [Run("on", sprms: Builder.hidden())]),
            Paragraph(runs: [Run("off", sprms: Builder.hidden(0))]),
            Paragraph(runs: [Run("reversed", sprms: Builder.hidden(0x81))]),
            Paragraph(runs: [Run("kept", sprms: Builder.hidden(0x80))]),
            Paragraph("by style", style: 4),
            Paragraph(runs: [Run("shown by zero", sprms: Builder.hidden(0))], style: 4),
            Paragraph(runs: [Run("kept hidden", sprms: Builder.hidden(0x80))], style: 4),
            Paragraph(runs: [Run("reversed to shown", sprms: Builder.hidden(0x81))], style: 4),
        ]) { $0.styles.append(hiddenStyle) }
        XCTAssertEqual(body, "<p>off</p>\n<p>kept</p>\n<p>shown by zero</p>\n<p>reversed to shown</p>\n")
    }

    func testTextATrackedChangeDeletedIsNotRead() throws {
        XCTAssertEqual(
            try body([Paragraph(runs: [Run("kept "), Run("gone ", sprms: Builder.deleted()), Run("end")])]),
            "<p>kept end</p>\n"
        )
    }

    func testAParagraphOfOnlyHiddenOrDeletedWordsWritesNothingNotEvenAnEmptyHeading() throws {
        let body = try body([
            Paragraph(runs: [Run("Chapter One", sprms: Builder.hidden())], style: 1),
            Paragraph(runs: [Run("hidden", sprms: Builder.hidden())]),
            Paragraph(runs: [Run("deleted", sprms: Builder.deleted())], style: 2),
            Paragraph("After"),
        ])
        XCTAssertEqual(body, "<p>After</p>\n")
    }

    func testAHiddenHeadingWritesNoHeadingAndLeavesTheGuessBySizeOn() throws {
        let body = try body([
            Paragraph(runs: [Run("Hidden chapter", sprms: Builder.hidden())], style: 1),
            Paragraph(runs: [Run("Big title", sprms: Builder.size(halfPoints: 80))]),
            Paragraph("Body text goes on for a good while here."),
            Paragraph("More body text."),
        ])
        XCTAssertEqual(body, "<h1>Big title</h1>\n<p>Body text goes on for a good while here.</p>\n<p>More body text.</p>\n")
    }

    func testAHiddenParagraphMarkAloneJoinsNothing() throws {
        let body = try body([
            Paragraph(runs: [Run("Run-in heading.")], style: 1, markSprms: Builder.hidden()),
            Paragraph("Body follows."),
        ])
        XCTAssertEqual(body, "<h1>Run-in heading.</h1>\n<p>Body follows.</p>\n")
    }

    // MARK: - The Sizes of Sprms

    func testTheFontSizeIsTwoBytesSoWhatFollowsItIsStillRead() throws {
        // Real files write `63 18 00 56 01`: a size of 24 half-points, then italic. Word writes bold, italic, and
        // hidden text before the size, but other writers put them after it.
        XCTAssertEqual(
            try body([Paragraph(runs: [Run("size first", sprms: Builder.size(halfPoints: 24) + Builder.italic())])]),
            "<p><em>size first</em></p>\n"
        )
        XCTAssertEqual(
            try body([Paragraph(runs: [Run("seen "), Run("secret", sprms: Builder.size(halfPoints: 24) + Builder.hidden()), Run(" seen")])]),
            "<p>seen seen</p>\n"
        )
    }

    func testAPicturePlaceAndASymbolHaveASizeByteSoWhatFollowsThemIsStillRead() throws {
        // `44 04 04 e7 07 00 55 81`: a picture's place of four bytes, then bold toggled.
        let place = Builder.sprm(68, [4, 0x04, 0xE7, 0x07, 0x00])
        XCTAssertEqual(
            try body([Paragraph(runs: [Run("x"), Run("hidden after a picture", sprms: place + Builder.hidden())])]),
            "<p>x</p>\n"
        )
        // `4a 03 01 00 2d`: a symbol of font 1 and character 0x2d, then hidden text.
        let symbol = Builder.sprm(74, [3, 1, 0, 0x2D])
        XCTAssertEqual(
            try body([Paragraph(runs: [Run("a"), Run("secret", sprms: symbol + Builder.hidden())])]),
            "<p>a</p>\n"
        )
    }

    func testTheCharacterSetAndTheLanguageSprmsAreSizedSoWhatFollowsThemIsStillRead() throws {
        // 73 (a flag and 16 bits), 77 (16 bits), and 14 (a byte) before hidden text.
        for before in [Builder.sprm(73, [0, 0, 0]), Builder.sprm(77, [1, 2]), Builder.sprm(14, [0])] {
            XCTAssertEqual(
                try body([Paragraph(runs: [Run("a"), Run("secret", sprms: before + Builder.hidden())])]),
                "<p>a</p>\n",
                "\(before)"
            )
        }
    }

    // MARK: - Pages

    func testAPageBreakInsideHiddenOrDeletedTextBeginsNoPage() throws {
        for sprms in [Builder.hidden(), Builder.deleted()] {
            XCTAssertEqual(
                try body([Paragraph(runs: [Run("one "), Run("\u{0C}", sprms: sprms), Run("two")])], pages: true),
                span(1) + "<p>one two</p>\n"
            )
        }
        XCTAssertEqual(
            try body([Paragraph(runs: [Run("one "), Run("\u{0C}"), Run("two")])], pages: true),
            span(1) + "<p>one \(span(2))two</p>\n"
        )
    }

    func testAParagraphOfHiddenOrDeletedWordsThatBeginsAPageBeginsNone() throws {
        for sprms in [Builder.hidden(), Builder.deleted()] {
            let body = try body([
                Paragraph("A"),
                Paragraph(runs: [Run("gone", sprms: sprms)], sprms: Builder.pageBreakBefore),
                Paragraph("B"),
            ], pages: true)
            XCTAssertEqual(body, span(1) + "<p>A</p>\n<p>B</p>\n")
        }
        XCTAssertEqual(
            try body([Paragraph("A"), Paragraph("B", sprms: Builder.pageBreakBefore)], pages: true),
            span(1) + "<p>A</p>\n<p>\(span(2))B</p>\n"
        )
    }

    func testASectionBreakBeginsAPageOnlyIfTheNextSectionDoes() throws {
        // "first" and its form feed are 6 characters, "second" and its mark 7.
        func document(nextSectionKind: UInt8, markSprms: [UInt8] = []) throws -> String {
            try body([Paragraph("first", mark: 0x0C, markSprms: markSprms), Paragraph("second")], pages: true) {
                $0.sections = [Builder.Section(end: 6, breakKind: nil), Builder.Section(end: 13, breakKind: nextSectionKind)]
            }
        }
        XCTAssertEqual(try document(nextSectionKind: 2), span(1) + "<p>first</p>\n<p>\(span(2))second</p>\n")
        XCTAssertEqual(try document(nextSectionKind: 0), span(1) + "<p>first</p>\n<p>second</p>\n")
        // A section break in hidden text begins no page.
        XCTAssertEqual(try document(nextSectionKind: 2, markSprms: Builder.hidden()), span(1) + "<p>first</p>\n<p>second</p>\n")
    }

    // MARK: - Notes

    func testFootnotesFollowTheMainTextAndTheirMarksAreNotRead() throws {
        let body = try body([Paragraph(runs: [Run("Body"), Run("\u{02}", sprms: Builder.sprm(117, [1]))])]) {
            $0.footnotes = ["\u{02}First note.", "\u{02}Second note."]
        }
        XCTAssertEqual(body, "<p>Body</p>\n<p>First note.</p>\n<p>Second note.</p>\n")
    }

    func testANoteWhoseReferenceIsInHiddenTextIsNotRead() throws {
        let hiddenMark = Builder.sprm(117, [1]) + Builder.hidden()
        let body = try body([Paragraph(runs: [Run("Body "), Run("\u{02}", sprms: Builder.sprm(117, [1])), Run("more"), Run("\u{02}", sprms: hiddenMark)])]) {
            $0.footnotes = ["\u{02}Shown note.", "\u{02}Hidden note."]
        }
        XCTAssertEqual(body, "<p>Body more</p>\n<p>Shown note.</p>\n")
    }

    // MARK: - Characters and Code Pages

    func testTwoByteUnitsOfLatinTextReadAsLatinText() throws {
        XCTAssertEqual(try body([Paragraph("Hello café")]) { $0.twoByteCharacters = true }, "<p>Hello café</p>\n")
    }

    func testAFarEastFontNamesTheDoubleByteCodePageOfATwoByteDocument() throws {
        let encoding = try XCTUnwrap(TextEncodingCatalog.entry(forIdentifier: "cp932")?.encoding)
        let body = try body([Paragraph("管理組合 2001")]) {
            $0.twoByteCharacters = true
            $0.encoding = encoding
            $0.fontCharacterSets = [0, 128]
        }
        XCTAssertEqual(body, "<p>管理組合 2001</p>\n")
    }

    func testFarEastFontsInAOneByteDocumentLeaveItsAccentsAlone() throws {
        // The Western editions name Far East fonts beside their own; the text stays Windows-1252.
        XCTAssertEqual(try body([Paragraph("café")]) { $0.fontCharacterSets = [0, 2, 128] }, "<p>café</p>\n")
    }

    func testACyrillicFontOrLanguageMakesTheDocumentWindows1251() throws {
        let encoding = try XCTUnwrap(TextEncodingCatalog.entry(forIdentifier: "windows-1251")?.encoding)
        for configure in [
            { (builder: inout Builder) in builder.fontCharacterSets = [0, 204] },
            { (builder: inout Builder) in builder.language = 0x0419 },
        ] {
            let body = try body([Paragraph("Привет")]) {
                $0.encoding = encoding
                configure(&$0)
            }
            XCTAssertEqual(body, "<p>Привет</p>\n")
        }
    }

    func testADocumentMarkedMacintoshIsMacRoman() throws {
        let encoding = try XCTUnwrap(TextEncodingCatalog.entry(forIdentifier: "macintosh")?.encoding)
        let body = try body([Paragraph("café")]) {
            $0.encoding = encoding
            $0.characterSet = 256
        }
        XCTAssertEqual(body, "<p>café</p>\n")
    }

    func testAUnitThatIsNoDoubleByteCharacterReadsAsItsTwoBytesAndKeepsAParagraphMark() throws {
        // The unit 0x350D is a "5" and a carriage return, as a stray pair of single bytes in a two-byte document.
        let encoding = try XCTUnwrap(TextEncodingCatalog.entry(forIdentifier: "cp932")?.encoding)
        var builder = Builder()
        builder.paragraphs = [Paragraph("abc")]
        builder.twoByteCharacters = true
        builder.encoding = encoding
        builder.fontCharacterSets = [128]
        let built = builder.buildStream()
        var stream = built.bytes
        // The unit of "b" is stored 0x0D, 0x35 (low byte first).
        stream.replaceSubrange(built.layout.textStart + 2..<built.layout.textStart + 4, with: [0x0D, 0x35])
        var file = CompoundFileBuilder()
        file.streams = [("WordDocument", stream)]
        XCTAssertEqual(try body(of: file.build().data), "<p>a5</p>\n<p>c</p>\n")
    }

    func testWesternPunctuationInADocumentWithFarEastFontsIsWindows1252() throws {
        // 0x92 alone is no character of Shift JIS, and is a right single quote in Windows-1252.
        let body = try body([Paragraph(runs: [Run("it\u{2019}s")])]) {
            $0.twoByteCharacters = true
            $0.fontCharacterSets = [128]
            $0.encoding = .windowsCP1252
        }
        XCTAssertEqual(body, "<p>it\u{2019}s</p>\n")
    }

    func testALineFeedIsALineBreakSoTheWordsOnEitherSideDoNotRunTogether() throws {
        // Word 97 drops the character; textutil reads it as the end of a line.
        XCTAssertEqual(try body([Paragraph("one\ntwo")]), "<p>one<br>two</p>\n")
    }

    // MARK: - Fast Save

    func testAFastSavedDocumentReadsItsTwoPiecesInTheOrderOfTheText() throws {
        let plain = try body([Paragraph("first half second half")]) { $0.isFastSaved = true }
        XCTAssertEqual(plain, "<p>first half second half</p>\n")
        // A bold run that crosses the boundary of the pieces stays one run.
        let crossing = try body([Paragraph(runs: [Run("aaaaaaaa", sprms: Builder.bold()), Run("bbbb")])]) { $0.isFastSaved = true }
        XCTAssertEqual(crossing, "<p><strong>aaaaaaaa</strong>bbbb</p>\n")
    }

    // MARK: - Numbering

    func testNumberedParagraphsAreAnOrderedListWhoseNumbersAreSilentOrWords() throws {
        let numbered = Builder.numbering()
        let paragraphs = [
            Paragraph("One", sprms: numbered), Paragraph("Two", sprms: numbered), Paragraph("Plain"), Paragraph("Three", sprms: numbered),
        ]
        XCTAssertEqual(
            try body(paragraphs, speaksNumbers: false),
            "<ol>\n<li>One</li>\n<li>Two</li>\n</ol>\n<p>Plain</p>\n<ol>\n<li>Three</li>\n</ol>\n"
        )
        XCTAssertEqual(try body(paragraphs, speaksNumbers: true), "<p>1. One</p>\n<p>2. Two</p>\n<p>Plain</p>\n<p>1. Three</p>\n")
    }

    func testABulletIsAnItemOfAnUnorderedListAndAnOutlineNestsByItsLevel() throws {
        XCTAssertEqual(
            try body([Paragraph("dot", sprms: Builder.numbering(format: 255, after: "o"))], speaksNumbers: false),
            "<ul>\n<li>dot</li>\n</ul>\n"
        )
        let outer = Builder.numbering(level: 1)
        let inner = Builder.numbering(after: ")", level: 2)
        XCTAssertEqual(
            try body([Paragraph("A", sprms: outer), Paragraph("B", sprms: inner)], speaksNumbers: false),
            "<ol>\n<li>A<ol>\n<li>B</li>\n</ol>\n</li>\n</ol>\n"
        )
    }

    func testAnAnldOfTheWrongSizeOrALevelOfNothingIsNotAList() throws {
        let short = Builder.sprm(12, [4, 0, 0, 0, 0]) + Builder.sprm(13, [10])
        XCTAssertEqual(try body([Paragraph("short", sprms: short)], speaksNumbers: false), "<p>short</p>\n")
        XCTAssertEqual(try body([Paragraph("none", sprms: Builder.numbering(level: 0))], speaksNumbers: false), "<p>none</p>\n")
    }

    // MARK: - What It Leaves to Textutil or Refuses

    func testAnEncryptedDocumentIsRefusedWithThePasswordSentence() throws {
        var builder = Builder()
        builder.paragraphs = [Paragraph("secret")]
        builder.extraFlags = 0x0100
        XCTAssertThrowsError(try WordDocumentReader.html(from: builder.build(), includesPages: false)) {
            XCTAssertTrue($0 is PasswordProtectedDocument, "\($0)")
        }
    }

    func testTheMacLeavesTheOldLayoutToTextutilUntilTheSwitchAndIOSReadsIt() throws {
        let copy = try copyOfFormatSample("doc6/poi-Word6.doc")
        let html = try OwnDocumentReaders.html(of: copy, as: .doc, includesPages: false)
        #if os(macOS)
        XCTAssertNil(html)
        XCTAssertFalse(WordDocumentReader.readsWord6AndWord95)
        #else
        XCTAssertNotNil(html)
        #endif
        // Asked not to read it, the reader itself says nil, and Word 97 documents read.
        XCTAssertNil(try WordDocumentReader.html(from: Builder().build(), includesPages: false, readsOldLayout: false))
        var modern = WordDocumentBuilder()
        modern.paragraphs = [WordDocumentBuilder.Paragraph("Word 97")]
        XCTAssertNotNil(try WordDocumentReader.html(from: modern.build(), includesPages: false, readsOldLayout: false))
    }

    func testWord1AndWord2DocumentsAreRefusedWithTheUnreadableSentenceAtOnce() throws {
        // Bare streams from before Word 6, with no compound file: out of scope, refused as they were before.
        for name in ["poi-word2.doc", "libreoffice-ww5-ooo37322-1-WW2.doc", "libreoffice-ww5-ooo40683-1-WW1.doc"] {
            let data = try Data(contentsOf: formatSampleURL("doc6/\(name)"))
            let start = Date()
            XCTAssertThrowsError(try WordDocumentReader.html(from: data, includesPages: true), name) { error in
                XCTAssertTrue(error is TextutilConverter.Failure, "\(name): \(error)")
                XCTAssertTrue(error.localizedDescription.hasPrefix("This file could not be read as"), error.localizedDescription)
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, name)
        }
    }

    func testADocumentOlderThanWord6IsLeftAlone() throws {
        var builder = Builder()
        builder.paragraphs = [Paragraph("old")]
        builder.version = 0x2D
        builder.identifier = 0xA5DC
        XCTAssertNil(try WordDocumentReader.html(from: builder.build(), includesPages: false))
    }

    func testTheOldLayoutsNumbersAndWordsAreTheSameWhetherTheNumbersAreWordsOrNot() throws {
        // Switching the numbers to words changes only the paragraphs that are numbered.
        let plain = [Paragraph("A"), Paragraph("B")]
        XCTAssertEqual(try body(plain, speaksNumbers: true), try body(plain, speaksNumbers: false))
    }

    // MARK: - The Reading Text

    func testTheReadingTextOfAnOldDocumentHasItsHeadingsAndNoMarkup() throws {
        var builder = Builder()
        builder.paragraphs = [Paragraph("Title", style: 1), Paragraph(runs: [Run("Some "), Run("bold", sprms: Builder.bold()), Run(" words.")])]
        let html = try XCTUnwrap(WordDocumentReader.html(from: builder.build(), includesPages: false))
        let markdown = try HTMLToMarkdownConverter.convert(
            document: SwiftSoup.parse(html), readingFlow: PublicationSemantics.ReadingFlow(source: html), includesPages: false
        )
        let chapter = try MarkdownDocParser.parseChapter(markdown: markdown, title: "", includeNavigationHeadings: true)
        XCTAssertEqual(chapter.headings.map(\.text), ["Title"])
        XCTAssertTrue(chapter.text.contains("Some bold words."), chapter.text)
        XCTAssertFalse(chapter.text.contains("*"), chapter.text)
    }
}
