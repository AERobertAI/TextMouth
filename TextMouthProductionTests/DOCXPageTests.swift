import XCTest
@testable import TextMouth

/// Where a Word document's pages begin (PG07). A DOCX marks a page in four
/// ways: a `w:br` of type page, a paragraph that says `w:pageBreakBefore`
/// (itself or through its style), a section whose break starts a page, and
/// the `w:lastRenderedPageBreak` Word leaves where its last layout broke a
/// page. The converter writes `<!-- page: LABEL -->` at each, numbered from
/// 1 with each section's restart and format, and never changes the reading
/// text. Each test reads a document as an import does
/// (`DOCXParser.extractMarkdown`, then the content.md parse) or converts a
/// small document built in memory.
final class DOCXPageTests: XCTestCase {

    // MARK: - Styles

    /// A style that sets `w:pageBreakBefore` starts a page, and so does a
    /// style based on it, however long the chain; a style that turns it off
    /// ends the chain with no page, whatever the styles behind it say.
    func testStylesTakePageBreakBeforeFromTheirBasedOnChain() throws {
        let styles = try Self.styles("""
        <w:style w:type="paragraph" w:styleId="Base"><w:name w:val="Base"/>
        <w:pPr><w:pageBreakBefore/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Child"><w:name w:val="Child"/><w:basedOn w:val="Base"/></w:style>
        <w:style w:type="paragraph" w:styleId="Grandchild"><w:name w:val="Grandchild"/><w:basedOn w:val="Child"/></w:style>
        <w:style w:type="paragraph" w:styleId="TurnedOff"><w:name w:val="TurnedOff"/><w:basedOn w:val="Base"/>
        <w:pPr><w:pageBreakBefore w:val="0"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="AfterOff"><w:name w:val="AfterOff"/><w:basedOn w:val="TurnedOff"/></w:style>
        <w:style w:type="paragraph" w:styleId="TurnedOnAgain"><w:name w:val="TurnedOnAgain"/><w:basedOn w:val="TurnedOff"/>
        <w:pPr><w:pageBreakBefore w:val="true"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Plain"><w:name w:val="Plain"/></w:style>
        """)

        XCTAssertEqual(styles.pageBreakBeforeStyles, ["Base", "Child", "Grandchild", "TurnedOnAgain"])
    }

    /// Every spelling of off in an on/off property turns it off ("0",
    /// "false", "off"); a missing value and every other value leave it on.
    func testPageBreakBeforeValuesOffAreZeroFalseAndOff() throws {
        let styles = try Self.styles("""
        <w:style w:type="paragraph" w:styleId="Zero"><w:pPr><w:pageBreakBefore w:val="0"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="False"><w:pPr><w:pageBreakBefore w:val="false"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Off"><w:pPr><w:pageBreakBefore w:val="off"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="One"><w:pPr><w:pageBreakBefore w:val="1"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="On"><w:pPr><w:pageBreakBefore w:val="on"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Bare"><w:pPr><w:pageBreakBefore/></w:pPr></w:style>
        """)

        XCTAssertEqual(styles.pageBreakBeforeStyles, ["One", "On", "Bare"])
    }

    /// A loop in the `w:basedOn` chain, a style based on one the part does
    /// not define, and a style whose only `w:pageBreakBefore` stands in a
    /// tracked change (the formatting from before the change) start no page.
    func testLoopsMissingStylesAndTrackedChangesStartNoPage() throws {
        let styles = try Self.styles("""
        <w:style w:type="paragraph" w:styleId="A"><w:basedOn w:val="B"/></w:style>
        <w:style w:type="paragraph" w:styleId="B"><w:basedOn w:val="A"/></w:style>
        <w:style w:type="paragraph" w:styleId="Orphan"><w:basedOn w:val="Nowhere"/></w:style>
        <w:style w:type="paragraph" w:styleId="Changed"><w:pPr><w:pPrChange w:id="1">
        <w:pPr><w:pageBreakBefore/></w:pPr></w:pPrChange></w:pPr></w:style>
        """)

        XCTAssertTrue(styles.pageBreakBeforeStyles.isEmpty)
    }

    /// A document that has no styles part starts no page by style, and a
    /// style without an ID cannot give its page break to unstyled paragraphs.
    func testAStyleWithoutAnIDStartsNoPage() throws {
        let styles = try Self.styles("""
        <w:style w:type="paragraph"><w:pPr><w:pageBreakBefore/></w:pPr></w:style>
        """)

        XCTAssertTrue(styles.pageBreakBeforeStyles.isEmpty)
        XCTAssertTrue(DOCXStyles().pageBreakBeforeStyles.isEmpty)
    }

    // MARK: - Page Numbers

    /// Roman numerals run from 1 to 3999, in lower and upper case; past that,
    /// and at 0, the number is written in decimal.
    func testRomanNumeralsRunFromOneToThreeThousandNineHundredNinetyNine() {
        let lower = DOCXPageNumberFormat.lowerRoman
        XCTAssertEqual((1...5).map(lower.label(forNumber:)), ["i", "ii", "iii", "iv", "v"])
        XCTAssertEqual(lower.label(forNumber: 14), "xiv")
        XCTAssertEqual(lower.label(forNumber: 1994), "mcmxciv")
        XCTAssertEqual(lower.label(forNumber: 3999), "mmmcmxcix")
        XCTAssertEqual(lower.label(forNumber: 4000), "4000")
        XCTAssertEqual(lower.label(forNumber: 0), "0")
        XCTAssertEqual(DOCXPageNumberFormat.upperRoman.label(forNumber: 4), "IV")
        XCTAssertEqual(DOCXPageNumberFormat.upperRoman.label(forNumber: 2024), "MMXXIV")
    }

    /// Letters are counted as Word counts them: a to z, then aa, bb, cc to
    /// zz, then aaa, and so on, up to 32 of one letter; past that, and at 0,
    /// the number is written in decimal.
    func testLettersRepeatAsWordCountsThem() {
        let lower = DOCXPageNumberFormat.lowerLetter
        XCTAssertEqual(lower.label(forNumber: 1), "a")
        XCTAssertEqual(lower.label(forNumber: 26), "z")
        XCTAssertEqual(lower.label(forNumber: 27), "aa")
        XCTAssertEqual(lower.label(forNumber: 28), "bb")
        XCTAssertEqual(lower.label(forNumber: 53), "aaa")
        XCTAssertEqual(DOCXPageNumberFormat.upperLetter.label(forNumber: 2), "B")
        XCTAssertEqual(DOCXPageNumberFormat.upperLetter.label(forNumber: 28), "BB")
        // The last number with a letter run of 32, and the first without one.
        XCTAssertEqual(lower.label(forNumber: 26 * 32), String(repeating: "z", count: 32))
        XCTAssertEqual(lower.label(forNumber: 26 * 32 + 1), String(26 * 32 + 1))
        XCTAssertEqual(lower.label(forNumber: 0), "0")
    }

    /// Every format Word offers beyond the five is written as decimal.
    func testOtherFormatsAreDecimal() {
        for name in [nil, "decimal", "chineseCounting", "ordinal", "decimalZero", "bullet", ""] {
            XCTAssertEqual(DOCXPageNumberFormat(name), .decimal, "format \(name ?? "none")")
        }
        XCTAssertEqual(DOCXPageNumberFormat("lowerRoman"), .lowerRoman)
        XCTAssertEqual(DOCXPageNumberFormat("upperRoman"), .upperRoman)
        XCTAssertEqual(DOCXPageNumberFormat("lowerLetter"), .lowerLetter)
        XCTAssertEqual(DOCXPageNumberFormat("upperLetter"), .upperLetter)
        XCTAssertEqual(DOCXPageNumberFormat.decimal.label(forNumber: 12), "12")
    }

    /// A restart number is a whole number from 0 to 999,999 written in ASCII
    /// digits; anything else is ignored.
    func testRestartNumbersAreWholeNumbersFromZeroTo999999() {
        XCTAssertEqual(DOCXSection.restartNumber("0"), 0)
        XCTAssertEqual(DOCXSection.restartNumber("7"), 7)
        XCTAssertEqual(DOCXSection.restartNumber("999999"), 999_999)
        XCTAssertEqual(DOCXSection.restartNumber("0000012"), 12)
        for ignored in [nil, "", "-3", "+3", "abc", "1.5", "1000000", "99999999999999999999", "\u{0663}"] {
            XCTAssertNil(DOCXSection.restartNumber(ignored), "start \(ignored ?? "none")")
        }
    }

    /// A section's break starts a page unless it is continuous or starts a
    /// column; no `w:type` means `nextPage`.
    func testSectionTypesStartAPageExceptContinuousAndNextColumn() {
        XCTAssertTrue(DOCXSection.typeStartsPage(nil))
        for type in ["nextPage", "oddPage", "evenPage", "unknown"] {
            XCTAssertTrue(DOCXSection.typeStartsPage(type), type)
        }
        XCTAssertFalse(DOCXSection.typeStartsPage("continuous"))
        XCTAssertFalse(DOCXSection.typeStartsPage("nextColumn"))
    }

    // MARK: - Where a Page Begins

    /// A page `w:br` in the middle of a paragraph begins a page at the words
    /// after it, and one space separates the two words it joined, as the
    /// newline it used to be read as did: "runs on and" and "continues"
    /// read "runs on and continues".
    func testAPageBreakInsideAParagraphKeepsTheWordsApart() throws {
        let reading = try read(body: [
            Self.paragraph(Self.run(Self.text("runs on and"), Self.pageBreak, Self.text("continues")))
        ])

        XCTAssertEqual(reading.chapter.text, "runs on and continues")
        XCTAssertEqual(reading.labels, ["1", "2"])
        XCTAssertEqual(reading.openings(), ["runs on and", "continues"])
        XCTAssertTrue(reading.markdown.contains("runs on and <!-- page: 2 -->continues"), reading.markdown)
        try assertSameReading(reading, body: [
            Self.paragraph(Self.run(Self.text("runs on and"), Self.pageBreak, Self.text("continues")))
        ])
    }

    /// Whitespace beside the break is the space that separates the words, so
    /// the break adds none of its own and doubles none, wherever it stands.
    func testWhitespaceBesideAPageBreakIsTheOnlySpaceBetweenTheWords() throws {
        for (before, after) in [("and ", "continues"), ("and", " continues"), ("and ", "  continues"), ("and", "continues")] {
            let body = [Self.paragraph(Self.run(Self.text(before), Self.pageBreak, Self.text(after)))]
            let reading = try read(body: body)

            XCTAssertEqual(reading.chapter.text, "and continues", "\"\(before)\" and \"\(after)\"")
            XCTAssertEqual(reading.openings(), ["and continues", "continues"], "\"\(before)\" and \"\(after)\"")
            try assertSameReading(reading, body: body)
        }
    }

    /// A break inside bold text splits the bold run in two, each piece with
    /// its own delimiters and the whitespace outside them, so no asterisk is
    /// read aloud, and the marker stands between the pieces.
    func testABreakInsideEmphasisKeepsTheDelimitersAndTheWhitespaceOutside() throws {
        let body = [Self.paragraph(Self.run("<w:rPr><w:b/></w:rPr>", Self.text("bold words "), Self.pageBreak, Self.text("more words")))]
        let reading = try read(body: body)

        XCTAssertTrue(reading.markdown.contains("**bold words** <!-- page: 2 -->**more words**"), reading.markdown)
        XCTAssertEqual(reading.chapter.text, "bold words more words")
        try assertSameReading(reading, body: body)
    }

    /// A page `w:br` at the end of a paragraph begins the page at the next
    /// paragraph's words, as a block before it. One that nothing follows
    /// writes no marker at all.
    func testABreakAtTheEndOfAParagraphMarksTheNextParagraph() throws {
        let reading = try read(body: [
            Self.plain("First"),
            Self.paragraph(Self.run(Self.text("Second"), Self.pageBreak)),
            Self.plain("Third"),
            Self.paragraph(Self.run(Self.pageBreak)),
        ])

        XCTAssertEqual(reading.labels, ["1", "2"])
        XCTAssertEqual(reading.openings(words: 1), ["First", "Third"])
    }

    /// Only a break of type page starts a page: a column break, a
    /// text-wrapping break, and a plain line break stay newlines.
    func testOnlyBreaksOfTypePageStartAPage() throws {
        let body = [Self.paragraph(Self.run(
            Self.text("one"), "<w:br w:type=\"column\"/>", Self.text("two"), "<w:br w:type=\"textWrapping\"/>",
            Self.text("three"), "<w:br/>", Self.text("four")
        ))]
        let reading = try read(body: body)

        XCTAssertEqual(reading.labels, ["1"])
        XCTAssertEqual(reading.spoken, "one two three four")
        try assertSameReading(reading, body: body)
    }

    /// A break and Word's note of its layout, with no words between them, are
    /// one page: Word writes the rendered break after its own explicit one.
    func testAnExplicitBreakAndARenderedBreakWithNothingBetweenAreOnePage() throws {
        let reading = try read(body: [
            Self.plain("One"),
            Self.paragraph(Self.run(Self.text("Two."), Self.pageBreak)),
            Self.paragraph(Self.run(Self.renderedBreak, Self.text("Three"))),
        ])

        XCTAssertEqual(reading.labels, ["1", "2"])
        XCTAssertEqual(reading.openings(words: 1), ["One", "Three"])
    }

    /// A rendered break begins a page where it stands, mid-sentence, and
    /// adds neither a word nor a space.
    func testARenderedBreakBeginsAPageWhereItStands() throws {
        let body = [Self.paragraph(Self.run(Self.text("Alpha beta "), Self.renderedBreak, Self.text("gamma delta")))]
        let reading = try read(body: body)

        XCTAssertEqual(reading.labels, ["1", "2"])
        XCTAssertEqual(reading.openings(), ["Alpha beta gamma", "gamma delta"])
        XCTAssertEqual(reading.chapter.text, "Alpha beta gamma delta")
        try assertSameReading(reading, body: body)
    }

    /// A page break in text a tracked change deleted starts no page; the
    /// reading is what it was.
    func testABreakInDeletedTextStartsNoPage() throws {
        let body = [Self.paragraph(
            Self.run(Self.text("Keep")),
            "<w:del w:id=\"1\">" + Self.run(Self.pageBreak, Self.renderedBreak) + "</w:del>",
            Self.run(Self.text(" going"))
        )]
        let reading = try read(body: body)

        XCTAssertEqual(reading.labels, ["1"])
        XCTAssertEqual(reading.spoken, "Keep going")
        try assertSameReading(reading, body: body)
    }

    /// A page break inside a hyperlink's label begins a page after the link,
    /// never inside the label, and keeps the label's words apart.
    func testABreakInsideAHyperlinkMarksTheTextAfterTheLink() throws {
        let body = [Self.paragraph(
            Self.run(Self.text("See ")),
            "<w:hyperlink r:id=\"rId9\">" + Self.run(Self.text("first"), Self.pageBreak, Self.text("second")) + "</w:hyperlink>",
            Self.run(Self.text(" end"))
        )]
        let reading = try read(body: body)

        XCTAssertEqual(reading.labels, ["1", "2"])
        XCTAssertEqual(reading.spoken, "See first second end")
        XCTAssertEqual(reading.openings(), ["See first second", "end"])
        try assertSameReading(reading, body: body)
    }

    /// A page that begins before a hyperlink is marked before the link.
    func testAPageBeforeAHyperlinkIsMarkedBeforeTheLink() throws {
        let reading = try read(body: [
            Self.plain("Intro"),
            Self.paragraph(
                Self.run(Self.pageBreak),
                "<w:hyperlink r:id=\"rId9\">" + Self.run(Self.text("link words")) + "</w:hyperlink>"
            ),
        ])

        XCTAssertEqual(reading.labels, ["1", "2"])
        XCTAssertEqual(reading.openings(words: 1), ["Intro", "link"])
    }

    /// After a line break inside a paragraph, a page that begins at the next
    /// line keeps its marker off the start of the line, where it would hide
    /// the line's words in an HTML block.
    func testAMarkerAfterALineBreakDoesNotBeginALine() throws {
        let body = [Self.paragraph(Self.run(Self.text("line one"), "<w:br/>", Self.renderedBreak, Self.text("line two")))]
        let reading = try read(body: body)

        XCTAssertEqual(reading.labels, ["1", "2"])
        XCTAssertEqual(reading.openings(), ["line one line", "line two"])
        try assertSameReading(reading, body: body)
    }

    /// An italic line whose line break is inside its run, then a page break:
    /// the emphasis ends "*Roses\n*", and the space the break brings goes
    /// after the marker. Before it, the space made "* " a list item whose
    /// first line, the words after the break included, was raw HTML. The
    /// line keeps its words, and reads the same without pages.
    func testAnItalicLineBreakBeforeAPageBreakKeepsTheLineAfterIt() throws {
        let body = [Self.paragraph(
            Self.run("<w:rPr><w:i/></w:rPr>", Self.text("Roses"), "<w:br/>"),
            Self.run(Self.pageBreak),
            Self.run(Self.text("are red."))
        )]
        let reading = try read(body: body)

        XCTAssertEqual(reading.labels, ["1", "2"])
        XCTAssertTrue(reading.spoken.hasSuffix(" are red."), reading.spoken)
        XCTAssertEqual(reading.openings(words: 2).last, "are red.")
        XCTAssertFalse(reading.markdown.contains("* <!--"), reading.markdown)
        try assertSameReading(reading, body: body)
    }

    /// A line break and then a page break in a list item: the marker is
    /// written at the end of the line before, so the item's next line keeps
    /// its words. On a line of its own, four spaces before it counted from
    /// the line's start, not from the item's words, and opened an HTML block
    /// that held the rest of the line.
    func testALineBreakThenAPageBreakInAListItemKeepsTheLineAfterIt() throws {
        let body = [
            Self.listItem("Alpha", level: 0),
            Self.paragraph(
                Self.run(Self.text("Beta"), "<w:br/>", Self.pageBreak, Self.text("more words")),
                properties: Self.numberingProperties(level: 0)
            ),
        ]
        let reading = try read(body: body, numbering: Self.nestedListNumbering)

        XCTAssertEqual(reading.labels, ["1", "2"])
        XCTAssertEqual(reading.spoken, "Alpha Beta more words")
        XCTAssertEqual(reading.openings(words: 2).last, "more words")
    }

    // MARK: Page 1

    /// The first page begins at the document's start; a `w:pageBreakBefore`
    /// on the first paragraph, or a section break before the first words,
    /// is that page and no second one.
    func testPageOneMergesWithABreakBeforeTheFirstWords() throws {
        let breakBefore = try read(body: [
            Self.plain("First", properties: "<w:pageBreakBefore/>"), Self.plain("Second"),
        ])
        XCTAssertEqual(breakBefore.labels, ["1"])
        XCTAssertEqual(breakBefore.openings(), ["First Second"])

        // An empty first section ends, and the second begins a page.
        let sectionBreak = try read(body: [
            Self.paragraph(properties: Self.sectionProperties()), Self.plain("First"), Self.sectionProperties(),
        ])
        XCTAssertEqual(sectionBreak.labels, ["1"])
        XCTAssertEqual(sectionBreak.openings(), ["First"])

        // The merged page takes the numbering of the last start merged into it.
        let restarted = try read(body: [
            Self.paragraph(properties: Self.sectionProperties()), Self.plain("First"),
            Self.sectionProperties(pageNumbers: "<w:pgNumType w:start=\"5\"/>"),
        ])
        XCTAssertEqual(restarted.labels, ["5"])
    }

    /// Every page of a document is marked once, and a document with no words
    /// has no page.
    func testADocumentWithoutWordsHasNoPage() throws {
        let docx = try makePackage(body: [Self.paragraph(Self.run(Self.pageBreak)), Self.paragraph()])
        let markdown = try DOCXParser.extractMarkdown(from: docx, includesPages: true) { damage in
            XCTFail("Unexpected damage report: \(damage)")
        }

        XCTAssertFalse(markdown.contains("<!-- page:"), markdown)
    }

    // MARK: Sections and Numbering

    /// A section's `w:pgNumType` writes its page numbers: Roman numerals in
    /// either case, letters as Word counts them, and decimal for any format
    /// this reader does not know.
    func testSectionFormatsNumberTheirPages() throws {
        let cases: [(numbering: String, pages: Int, expected: [String])] = [
            ("<w:pgNumType w:fmt=\"lowerRoman\" w:start=\"1\"/>", 5, ["i", "ii", "iii", "iv", "v"]),
            ("<w:pgNumType w:fmt=\"upperRoman\" w:start=\"4\"/>", 1, ["IV"]),
            ("<w:pgNumType w:fmt=\"lowerLetter\" w:start=\"1\"/>", 1, ["a"]),
            ("<w:pgNumType w:fmt=\"upperLetter\" w:start=\"2\"/>", 1, ["B"]),
            ("<w:pgNumType w:fmt=\"chineseCounting\"/>", 2, ["1", "2"]),
            ("<w:pgNumType w:fmt=\"decimal\" w:start=\"9\"/>", 2, ["9", "10"]),
        ]
        for testCase in cases {
            let reading = try read(body: Self.pages(testCase.pages) + [Self.sectionProperties(pageNumbers: testCase.numbering)])
            XCTAssertEqual(reading.labels, testCase.expected, testCase.numbering)
        }
    }

    /// Letters count past z as Word does: aa, bb, and on.
    func testLetterPageNumbersRepeatPastZ() throws {
        let reading = try read(body: Self.pages(28) + [
            Self.sectionProperties(pageNumbers: "<w:pgNumType w:fmt=\"lowerLetter\" w:start=\"1\"/>")
        ])

        XCTAssertEqual(reading.labels.count, 28)
        guard reading.labels.count == 28 else { return }
        XCTAssertEqual(reading.labels[0], "a")
        XCTAssertEqual(reading.labels[25], "z")
        XCTAssertEqual(reading.labels[26], "aa")
        XCTAssertEqual(reading.labels[27], "bb")
    }

    /// A restart number that is not a whole number from 0 to 999,999 is
    /// ignored and the pages count from 1; a restart at 0 is honored.
    func testBadRestartNumbersAreIgnoredAndZeroIsHonored() throws {
        for ignored in ["-3", "abc", "1000000", ""] {
            let reading = try read(body: Self.pages(2) + [
                Self.sectionProperties(pageNumbers: "<w:pgNumType w:start=\"\(ignored)\"/>")
            ])
            XCTAssertEqual(reading.labels, ["1", "2"], "start \"\(ignored)\"")
        }
        let zero = try read(body: Self.pages(2) + [Self.sectionProperties(pageNumbers: "<w:pgNumType w:start=\"0\"/>")])
        XCTAssertEqual(zero.labels, ["0", "1"])
    }

    /// A section whose break is nextPage, oddPage, evenPage, or has no type
    /// begins a page; a continuous or nextColumn section does not.
    func testOnlySectionsThatStartAPageBeginOne() throws {
        for type in ["nextPage", nil, "oddPage", "evenPage"] {
            let reading = try read(body: [
                Self.plain("A", properties: Self.sectionProperties()), Self.plain("B"), Self.sectionProperties(type: type),
            ])
            XCTAssertEqual(reading.labels, ["1", "2"], "type \(type ?? "none")")
            XCTAssertEqual(reading.openings(words: 1), ["A", "B"], "type \(type ?? "none")")
        }
        for type in ["continuous", "nextColumn"] {
            let reading = try read(body: [
                Self.plain("A", properties: Self.sectionProperties()), Self.plain("B"), Self.sectionProperties(type: type),
            ])
            XCTAssertEqual(reading.labels, ["1"], "type \(type)")
        }
    }

    /// A section's restart waits for the first page that begins in it, so a
    /// continuous section that restarts takes effect at its next page.
    func testARestartInAContinuousSectionWaitsForItsFirstPage() throws {
        let reading = try read(body: [
            Self.plain("A", properties: Self.sectionProperties()),
            Self.plain("B"),
            Self.plain("C", properties: "<w:pageBreakBefore/>"),
            Self.sectionProperties(type: "continuous", pageNumbers: "<w:pgNumType w:start=\"20\"/>"),
        ])

        XCTAssertEqual(reading.labels, ["1", "20"])
        XCTAssertEqual(reading.openings(words: 1), ["A", "C"])
    }

    /// A section break inside a tracked change (`w:sectPrChange`) is the
    /// section as it was, and counts for nothing.
    func testASectionPropertiesChangeRecordIsNotASection() throws {
        let change = "<w:sectPr><w:type w:val=\"nextPage\"/><w:pgNumType w:fmt=\"upperRoman\"/>"
            + "<w:sectPrChange w:id=\"1\"><w:sectPr><w:pgNumType w:fmt=\"lowerLetter\" w:start=\"7\"/></w:sectPr></w:sectPrChange></w:sectPr>"
        let reading = try read(body: Self.pages(2) + [change])

        XCTAssertEqual(reading.labels, ["I", "II"])
    }

    // MARK: Styles and Paragraph Properties

    /// A style that sets `w:pageBreakBefore` starts a page, and so does a
    /// style based on it; a paragraph that turns it off itself ("0", "false",
    /// or "off") does not; and the property starts a page wherever it stands
    /// among the paragraph's properties.
    func testPageBreakBeforeComesFromTheStyleChainAndTheParagraph() throws {
        let reading = try read(body: [
            Self.plain("One"),
            Self.plain("Two", properties: "<w:pStyle w:val=\"Child\"/>"),
            Self.plain("Three", properties: "<w:pStyle w:val=\"Child\"/><w:pageBreakBefore w:val=\"0\"/>"),
            Self.plain("Four", properties: "<w:pageBreakBefore/>"),
            Self.plain("Five", properties: "<w:pageBreakBefore w:val=\"off\"/><w:pStyle w:val=\"Child\"/>"),
            Self.plain("Six", properties: "<w:pStyle w:val=\"Child\"/><w:pageBreakBefore w:val=\"false\"/>"),
            Self.plain("Seven", properties: "<w:pageBreakBefore w:val=\"on\"/><w:pStyle w:val=\"Plain\"/>"),
        ], styles: """
        <w:style w:type="paragraph" w:styleId="Base"><w:name w:val="Base"/><w:pPr><w:pageBreakBefore/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Child"><w:name w:val="Child"/><w:basedOn w:val="Base"/></w:style>
        <w:style w:type="paragraph" w:styleId="Plain"><w:name w:val="Plain"/></w:style>
        """)

        XCTAssertEqual(reading.labels, ["1", "2", "3", "4"])
        XCTAssertEqual(reading.openings(words: 1), ["One", "Two", "Four", "Seven"])
    }

    /// A page that begins inside a heading is a block before the heading: a
    /// heading line holds only its words. The break stays the line break it
    /// always was, which ends the heading line, so the reading text, and with
    /// it every saved place, is exactly what it was without pages.
    func testAHeadingLineHoldsOnlyItsWords() throws {
        let body = [
            Self.plain("Intro"),
            Self.paragraph(Self.run(Self.text("A heading that"), Self.pageBreak, Self.text("crosses a page")),
                           properties: "<w:pStyle w:val=\"Heading1\"/>"),
        ]
        let reading = try read(body: body)

        XCTAssertEqual(reading.labels, ["1", "2"])
        XCTAssertEqual(reading.chapter.headings.map(\.text), ["A heading that"])
        XCTAssertEqual(reading.openings(), ["Intro A heading", "A heading that"])
        XCTAssertTrue(reading.markdown.contains("# A heading that\ncrosses a page"), reading.markdown)
        XCTAssertFalse(reading.markdown.contains("# A heading that <!--"), reading.markdown)
        try assertSameReading(reading, body: body)
    }

    // MARK: Lists and Tables

    /// A page that begins at the second item of a nested list is a block
    /// before it, which closes the list, and changes no reading text.
    func testAPageAtAListItemKeepsTheReadingText() throws {
        let body = [
            Self.listItem("Alpha", level: 0),
            Self.listItem("Beta", level: 1),
            Self.listItem("Gamma", level: 1, properties: "<w:pageBreakBefore/>"),
            Self.listItem("Delta", level: 0),
        ]
        let reading = try read(body: body, numbering: Self.nestedListNumbering)

        XCTAssertEqual(reading.labels, ["1", "2"])
        XCTAssertEqual(reading.openings(words: 1), ["Alpha", "Gamma"])
        XCTAssertEqual(reading.spoken, "Alpha Beta Gamma Delta")
        try assertSameReading(reading, body: body, numbering: Self.nestedListNumbering)
    }

    /// A page pending when a table begins is a block before it.
    func testAPagePendingWhenATableBeginsIsMarkedBeforeIt() throws {
        let body = [
            Self.paragraph(Self.run(Self.text("Before"), Self.pageBreak)),
            Self.table(Self.row(Self.textCell("Cell A"), Self.textCell("Cell B"))),
            Self.plain("After"),
        ]
        let reading = try read(body: body)

        XCTAssertEqual(reading.labels, ["1", "2"])
        XCTAssertEqual(reading.openings(words: 1), ["Before", "Cell"])
        try assertSameReading(reading, body: body)
    }

    /// A page that begins inside a table is a block after the table, and
    /// several that begin in one table are one page there, numbered as the
    /// last of them is.
    func testPagesThatBeginInATableAreOnePageAfterIt() throws {
        let body = [
            Self.plain("Before"),
            Self.table(
                Self.row(Self.textCell("Row one"), Self.paragraphCell(Self.renderedBreak, "Row one b")),
                Self.row(Self.paragraphCell(Self.renderedBreak, "Row two"), Self.textCell("Row two b"))
            ),
            Self.plain("After"),
        ]
        let reading = try read(body: body)

        XCTAssertEqual(reading.labels, ["1", "3"])
        XCTAssertEqual(reading.openings(words: 1), ["Before", "After"])
        XCTAssertFalse(reading.markdown.contains("<!-- page: 2 -->"), reading.markdown)
        let tableEnd = try XCTUnwrap(reading.markdown.range(of: "Row two b |")).upperBound
        let marker = try XCTUnwrap(reading.markdown.range(of: "<!-- page: 3 -->"))
        let after = try XCTUnwrap(reading.markdown.range(of: "After"))
        XCTAssertLessThanOrEqual(tableEnd, marker.lowerBound, reading.markdown)
        XCTAssertLessThan(marker.upperBound, after.lowerBound, reading.markdown)
        try assertSameReading(reading, body: body)
    }

    /// The first table of a section that begins a page begins that page.
    func testASectionThatBeginsWithATableBeginsAPageThere() throws {
        let body = [
            Self.plain("Intro", properties: Self.sectionProperties()),
            Self.table(Self.row(Self.textCell("Cell A"), Self.textCell("Cell B"))),
            Self.sectionProperties(),
        ]
        let reading = try read(body: body)

        XCTAssertEqual(reading.labels, ["1", "2"])
        XCTAssertEqual(reading.openings(words: 1), ["Intro", "Cell"])
    }

    // MARK: Text Boxes

    /// A run holding a text box (a legacy `w:pict`) of one paragraph reading `value`.
    static func box(_ value: String) -> String {
        run("<w:pict><w:txbxContent>" + plain(value) + "</w:txbxContent></w:pict>")
    }

    /// A page that waits begins at the first words written after it, the box's
    /// when the paragraph that holds its anchor has none: a paragraph of only
    /// a box, after a page break, is read under the page the break began.
    func testAParagraphOfOnlyABoxBeginsThePageThatWaits() throws {
        let body = [
            Self.paragraph(Self.run(Self.text("page one text"), Self.pageBreak)),
            Self.paragraph(Self.box("BOXPAGE2")),
            Self.plain("later on page two"),
        ]
        let reading = try read(body: body)

        XCTAssertEqual(reading.labels, ["1", "2"])
        XCTAssertEqual(reading.openings(words: 1), ["page", "BOXPAGE2"])
        XCTAssertEqual(reading.spoken, "page one text BOXPAGE2 later on page two")
        try assertSameReading(reading, body: body)
    }

    /// The same when the page begins at the paragraph's own properties.
    func testAParagraphOfOnlyABoxWithPageBreakBeforeBeginsItsPageAtTheBox() throws {
        let body = [
            Self.plain("one"),
            Self.paragraph(Self.box("BOXPAGE2"), properties: "<w:pageBreakBefore/>"),
            Self.plain("later"),
        ]
        let reading = try read(body: body)

        XCTAssertEqual(reading.labels, ["1", "2"])
        XCTAssertEqual(reading.openings(words: 1), ["one", "BOXPAGE2"])
        try assertSameReading(reading, body: body)
    }

    /// A document that begins with a box, or holds nothing else, has its first
    /// page marked before the box's words, not never.
    func testABoxAtTheStartOfADocumentIsOnPageOne() throws {
        let first = try read(body: [Self.paragraph(Self.box("BOX")), Self.plain("later")])
        XCTAssertEqual(first.labels, ["1"])
        XCTAssertEqual(first.openings(words: 1), ["BOX"])
        XCTAssertEqual(first.spoken, "BOX later")

        let only = try read(body: [Self.paragraph(Self.box("BOX"), Self.box("TWO"))])
        XCTAssertEqual(only.labels, ["1"])
        XCTAssertEqual(only.openings(words: 1), ["BOX"])
        XCTAssertEqual(only.spoken, "BOX TWO")
    }

    /// A box after a paragraph that has words of its own stays after it: the
    /// paragraph's words take the page. A box with no words takes none.
    func testAPendingPageGoesToTheFirstWordsWrittenWhoseverTheyAre() throws {
        let withWords = [
            Self.paragraph(Self.run(Self.text("A"), Self.pageBreak, Self.text("B")), Self.box("BOX")),
            Self.plain("C"),
        ]
        let reading = try read(body: withWords)
        XCTAssertEqual(reading.labels, ["1", "2"])
        XCTAssertEqual(reading.openings(words: 1), ["A", "B"])
        XCTAssertEqual(reading.spoken, "A B BOX C")

        let empty = [
            Self.paragraph(Self.run(Self.text("A"), Self.pageBreak)),
            Self.paragraph(Self.run("<w:pict><w:txbxContent>" + Self.paragraph() + "</w:txbxContent></w:pict>")),
            Self.plain("later"),
        ]
        let emptyReading = try read(body: empty)
        XCTAssertEqual(emptyReading.labels, ["1", "2"])
        XCTAssertEqual(emptyReading.openings(words: 1), ["A", "later"])
    }

    // MARK: Pages Not Included

    /// With `includesPages` false no marker is written and a page `w:br` is
    /// the newline it was.
    func testWithoutPagesNoMarkerIsWrittenAndABreakStaysANewline() throws {
        let reading = try read(body: [
            Self.paragraph(Self.run(Self.text("runs on and"), Self.pageBreak, Self.text("continues"))),
            Self.plain("Next", properties: "<w:pageBreakBefore/>"),
        ], includesPages: false)

        XCTAssertFalse(reading.markdown.contains("<!--"), reading.markdown)
        XCTAssertTrue(reading.markdown.contains("runs on and\ncontinues"), reading.markdown)
        XCTAssertTrue(reading.chapter.pages.isEmpty)
    }

    // MARK: - The Sample and the Real Documents

    /// The synthetic sample holds every kind of page start in order, and each
    /// page begins at the words it should: the page `w:br` mid-sentence, the
    /// style with `w:pageBreakBefore`, the explicit and rendered breaks that
    /// are one page, the Roman-numbered section, the decimal section that
    /// restarts, the page inside a table (after it), and the page inside a
    /// heading (before it).
    func testTheSampleHasEveryKindOfPageInOrder() throws {
        let reading = try read(at: copyOfDocument("format-samples/docx/page-breaks.docx"), includesPages: true)

        XCTAssertEqual(reading.labels, ["1", "2", "3", "4", "i", "ii", "1", "2", "3"])
        XCTAssertEqual(reading.openings(), [
            "Pages in a", "continues here on", "The third page", "The fourth page", "The second section",
            "page ii begins", "The third section", "A heading that", "A heading that",
        ])
        XCTAssertEqual(reading.content.chapters.count, 1)
        XCTAssertEqual(reading.markdown.components(separatedBy: "<!-- page:").count - 1, 9)

        // One space joins the words around the page break, and the two breaks
        // that mark the fourth page are one page.
        XCTAssertTrue(reading.chapter.text.contains("The first page runs on and continues here on the second page."))
        XCTAssertTrue(reading.markdown.contains("runs on and <!-- page: 2 -->continues here"), reading.markdown)

        // The table's page is after the table; the heading's, before the heading,
        // and the heading line holds only its words.
        let tableEnd = try XCTUnwrap(reading.markdown.range(of: "cell B\\. |", options: .backwards)).upperBound
        let tablePage = try XCTUnwrap(reading.markdown.range(of: "<!-- page: 2 -->\n", range: tableEnd..<reading.markdown.endIndex))
        let headingPage = try XCTUnwrap(reading.markdown.range(of: "<!-- page: 3 -->\n", range: tableEnd..<reading.markdown.endIndex))
        let heading = try XCTUnwrap(reading.markdown.range(of: "# A heading that\ncrosses a page"))
        XCTAssertLessThan(tablePage.upperBound, headingPage.lowerBound)
        XCTAssertLessThan(headingPage.upperBound, heading.lowerBound)
        // The page break ends the heading line, as it did before pages.
        XCTAssertEqual(reading.chapter.headings.map(\.text), ["Pages in a Word Document", "A heading that"])
    }

    /// Every DOCX in the repository reads the same with pages as without
    /// (the same chapters, reading text, and headings, so no saved place
    /// moves), and without pages it holds no marker. Each has at least page 1.
    func testEveryDocumentReadsTheSameWithAndWithoutPages() throws {
        for name in [
            "format-samples/docx/page-breaks.docx", "alice.docx", "test_book.docx",
            "format-samples/docm/headings-synthetic.docm", "format-samples/docm/libreoffice-hello.docm",
            "format-samples/dotm/headings-synthetic.dotm", "format-samples/dotm/libreoffice-autotext-dotm.dotm",
            "format-samples/dotx/headings-synthetic.dotx", "format-samples/dotx/libreoffice-sample.dotx",
        ] {
            let copy = try copyOfDocument(name)
            let with = try read(at: copy, includesPages: true)
            let without = try read(at: copy, includesPages: false)

            XCTAssertFalse(without.markdown.contains("<!-- page:"), name)
            XCTAssertTrue(without.chapter.pages.isEmpty, name)
            XCTAssertFalse(with.content.pages.isEmpty, name)
            assertSameReading(with, without)
        }
    }

    /// alice.docx, from Project Gutenberg through Word, holds 18
    /// `w:pageBreakBefore` set on (and one set off): the first, on "Table of
    /// Contents", is page 1 itself, so there are 18 pages. Seventeen begin at a
    /// heading; the one that does not begins the paragraph that ends the book.
    func testAliceHasEighteenPagesAtItsHeadings() throws {
        let reading = try read(at: copyOfDocument("alice.docx"), includesPages: true)

        XCTAssertEqual(reading.content.chapters.count, 1)
        XCTAssertEqual(reading.labels, (1...18).map(String.init))
        let headingOffsets = Set(reading.chapter.headings.map(\.characterOffset))
        let notAtHeadings = zip(reading.chapter.pages, reading.openings(words: 4))
            .filter { !headingOffsets.contains($0.0.characterOffset) }
            .map(\.1)
        XCTAssertEqual(notAtHeadings, ["*** END OF THE"])
        XCTAssertEqual(reading.openings(words: 3).first, "Table of Contents")
    }

    /// A copy of the document at `path`, a format sample ("format-samples/…")
    /// or a book in TestData, in a new folder of this test's own: samples are
    /// untrusted input and are never read in place.
    func copyOfDocument(_ path: String) throws -> URL {
        let source = try requireFile(path)
        let copy = try makeSandboxDirectory("DOCXPages").appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    // MARK: - Helpers

    /// The WordprocessingML namespace each part declares.
    static let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    /// A `w:br` of type page, and Word's note of where its last layout broke a page.
    static let pageBreak = "<w:br w:type=\"page\"/>"
    static let renderedBreak = "<w:lastRenderedPageBreak/>"

    /// A `w:t` holding `value`, whitespace kept.
    static func text(_ value: String) -> String {
        "<w:t xml:space=\"preserve\">\(value)</w:t>"
    }

    /// A run holding `children`.
    static func run(_ children: String...) -> String {
        "<w:r>" + children.joined() + "</w:r>"
    }

    /// A paragraph holding `runs` (and any other children), with `properties`
    /// in its `w:pPr` when there are any.
    static func paragraph(_ runs: String..., properties: String = "") -> String {
        let pPr = properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>"
        return "<w:p>" + pPr + runs.joined() + "</w:p>"
    }

    /// A paragraph of one run reading `value`.
    static func plain(_ value: String, properties: String = "") -> String {
        paragraph(run(text(value)), properties: properties)
    }

    /// `count` pages: the first plain, each later one begun by `w:pageBreakBefore`.
    static func pages(_ count: Int) -> [String] {
        (1...count).map { number in
            plain("Page \(number)", properties: number == 1 ? "" : "<w:pageBreakBefore/>")
        }
    }

    /// A `w:sectPr` of type `type` (none when nil) holding `pageNumbers`
    /// (`w:pgNumType`). In a paragraph's properties it ends a section; last
    /// in the body it is the last section's.
    static func sectionProperties(type: String? = "nextPage", pageNumbers: String = "") -> String {
        let typeElement = type.map { "<w:type w:val=\"\($0)\"/>" } ?? ""
        return "<w:sectPr>\(typeElement)\(pageNumbers)</w:sectPr>"
    }

    /// A list item reading `value` at `level` of list 1.
    static func listItem(_ value: String, level: Int, properties: String = "") -> String {
        plain(value, properties: properties + numberingProperties(level: level))
    }

    /// The paragraph properties that make a paragraph an item at `level` of list 1.
    static func numberingProperties(level: Int) -> String {
        "<w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"1\"/></w:numPr>"
    }

    /// Definitions for list 1: bullets at level 0 and numbers at level 1.
    static let nestedListNumbering = """
    <w:abstractNum w:abstractNumId="0">
    <w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl>
    <w:lvl w:ilvl="1"><w:numFmt w:val="decimal"/></w:lvl>
    </w:abstractNum>
    <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
    """

    /// A table of `rows`.
    static func table(_ rows: String...) -> String {
        "<w:tbl>" + rows.joined() + "</w:tbl>"
    }

    /// A table row of `cells`.
    static func row(_ cells: String...) -> String {
        "<w:tr>" + cells.joined() + "</w:tr>"
    }

    /// A table cell of one paragraph reading `value`.
    static func textCell(_ value: String) -> String {
        "<w:tc>" + plain(value) + "</w:tc>"
    }

    /// A table cell of one paragraph whose run holds `leading` and then `value`.
    static func paragraphCell(_ leading: String, _ value: String) -> String {
        "<w:tc>" + paragraph(run(leading, text(value))) + "</w:tc>"
    }

    /// The styles every test document has: the heading style, and a styles
    /// part holding `definitions` besides.
    static func stylesPart(_ definitions: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="\(wordNamespace)">
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/></w:style>
        \(definitions)
        </w:styles>
        """
    }

    /// The styles `definitions` declares, read by the production parser.
    static func styles(_ definitions: String) throws -> DOCXStyles {
        try DOCXStylesParser(data: Data(stylesPart(definitions).utf8), file: DOCXParser.Part.styles).parse()
    }

    /// What a reading of a document gives.
    struct Reading {
        /// The Markdown TextMouth caches for it.
        let markdown: String
        /// The book as the content.md parse makes it.
        let content: DocumentContent
        /// The book's first chapter, the whole of a DOCX.
        let chapter: Chapter

        /// The labels of the pages, in order.
        var labels: [String] { chapter.pages.map(\.label) }

        /// The reading text with every run of whitespace made one space.
        var spoken: String {
            chapter.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        /// The first `words` words at the start of each page, joined by spaces.
        func openings(words: Int = 3) -> [String] {
            let text = chapter.text as NSString
            return chapter.pages.map { page in
                guard page.characterOffset >= 0, page.characterOffset <= text.length else { return "(out of range)" }
                return text.substring(from: page.characterOffset)
                    .split(whereSeparator: \.isWhitespace).prefix(words).joined(separator: " ")
            }
        }
    }

    /// Read the document at `url` as an import does: its Markdown, then the
    /// content.md parse. Any damage report fails the test, and so does a line
    /// that begins with a comment but is not a whole marker, which would hide
    /// the rest of its line in an HTML block.
    func read(at url: URL, includesPages: Bool, file: StaticString = #filePath, line: UInt = #line) throws -> Reading {
        let markdown = try DOCXParser.extractMarkdown(from: url, includesPages: includesPages) { damage in
            XCTFail("Unexpected damage report: \(damage)", file: file, line: line)
        }
        for markdownLine in markdown.split(separator: "\n", omittingEmptySubsequences: false)
        where markdownLine.hasPrefix("<!--") {
            XCTAssertNotNil(MarkdownPageMarker.decode(String(markdownLine)), "\(markdownLine)", file: file, line: line)
        }
        let content = MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: "Pages", bookAuthor: "Author")
        let chapter = try XCTUnwrap(content.chapters.first, file: file, line: line)
        return Reading(markdown: markdown, content: content, chapter: chapter)
    }

    /// Read a package made by `makePackage`.
    func read(
        body: [String],
        styles: String = "",
        numbering: String? = nil,
        includesPages: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Reading {
        let docx = try makePackage(body: body, styles: styles, numbering: numbering)
        return try read(at: docx, includesPages: includesPages, file: file, line: line)
    }

    /// A package, removed when the test ends, whose text part holds `body`,
    /// with the styles part (the heading style and `styles`) and a numbering
    /// part holding `numbering` when it is given.
    func makePackage(body: [String], styles: String = "", numbering: String? = nil) throws -> URL {
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="\(Self.wordNamespace)"
         xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>
        \(body.joined(separator: "\n"))
        </w:body></w:document>
        """
        var parts = [
            DOCXParser.Part.document: Data(document.utf8),
            DOCXParser.Part.styles: Data(Self.stylesPart(styles).utf8),
        ]
        if let numbering {
            parts[DOCXParser.Part.numbering] = Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:numbering xmlns:w="\(Self.wordNamespace)">\(numbering)</w:numbering>
            """.utf8)
        }
        let docx = try makeTemporaryZip(prefix: "TextMouthDOCXPages", entries: parts)
        addTeardownBlock { try? FileManager.default.removeItem(at: docx) }
        return docx
    }

    /// Fail unless the document `body` reads the same with pages as without:
    /// the same chapters, reading text, and headings, with the same offsets.
    func assertSameReading(
        _ reading: Reading,
        body: [String],
        numbering: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let without = try read(body: body, numbering: numbering, includesPages: false, file: file, line: line)
        XCTAssertFalse(without.markdown.contains("<!-- page:"), file: file, line: line)
        assertSameReading(reading, without, file: file, line: line)
    }

    /// Fail unless `reading` and `without` hold the same chapters, reading
    /// text, and headings.
    func assertSameReading(_ reading: Reading, _ without: Reading, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(reading.content.chapters.map(\.text), without.content.chapters.map(\.text), file: file, line: line)
        XCTAssertEqual(reading.content.chapters.map(\.title), without.content.chapters.map(\.title), file: file, line: line)
        XCTAssertEqual(
            reading.content.chapters.map(\.headings), without.content.chapters.map(\.headings), file: file, line: line
        )
    }
}
