import XCTest
@testable import TextMouth

// MARK: - Hidden Text in Word Documents

/// How the DOCX reader treats hidden text, by the one policy every document
/// reader of TextMouth follows: a listener hears what a person reading the
/// document sees in its ordinary view. `w:vanish` text is not read, through a
/// run's own properties, its character style, and its paragraph style, by the
/// toggle rule of ECMA-376 17.7.3; `w:webHidden` text, which shows in print,
/// is read; and a hidden paragraph mark joins nothing, so a run-in heading
/// stays a heading.
final class DOCXHiddenTextTests: XCTestCase {

    // MARK: - Fixtures

    /// Styles: the default paragraph style, a heading, hidden and shown
    /// paragraph and character styles (each also by `w:basedOn`), a table
    /// style that hides its first row, and a style whose only `w:vanish` is
    /// in a record of a change (the properties from before it).
    private let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Secret"><w:name w:val="Secret"/><w:rPr><w:vanish/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="SecretChild"><w:name w:val="SecretChild"/><w:basedOn w:val="Secret"/></w:style>
        <w:style w:type="paragraph" w:styleId="SecretOff"><w:name w:val="SecretOff"/><w:basedOn w:val="Secret"/><w:rPr><w:vanish w:val="0"/></w:rPr></w:style>
        <w:style w:type="character" w:styleId="Hide"><w:name w:val="Hide"/><w:rPr><w:vanish/></w:rPr></w:style>
        <w:style w:type="character" w:styleId="HideChild"><w:name w:val="HideChild"/><w:basedOn w:val="Hide"/></w:style>
        <w:style w:type="character" w:styleId="Show"><w:name w:val="Show"/><w:basedOn w:val="Hide"/><w:rPr><w:vanish w:val="false"/></w:rPr></w:style>
        <w:style w:type="character" w:styleId="WasHidden"><w:name w:val="WasHidden"/><w:rPr><w:rPrChange w:id="1" w:author="A"><w:rPr><w:vanish/></w:rPr></w:rPrChange></w:rPr></w:style>
        <w:style w:type="table" w:styleId="Grid"><w:name w:val="Grid"/><w:tblStylePr w:type="firstRow"><w:rPr><w:vanish/></w:rPr></w:tblStylePr></w:style>
        <w:style w:type="paragraph" w:styleId="Odd"><w:name w:val="Odd"/><w:tblStylePr w:type="firstRow"><w:rPr><w:vanish/></w:rPr></w:tblStylePr></w:style>
        </w:styles>
        """

    /// The Markdown of a body made of `paragraphs`, read with the styles,
    /// with each run of blank lines made one (an empty paragraph writes a
    /// blank line of its own, which says nothing about what is read).
    private func markdown(_ paragraphs: String..., includesPages: Bool = false) throws -> String {
        try docxMarkdown(body: paragraphs.joined(), styles: styles, includesPages: includesPages)
            .replacingOccurrences(of: "\n{2,}", with: "\n\n", options: .regularExpression)
    }

    /// The paragraph "Shown {hidden by `properties`} words".
    private func paragraphHiding(_ properties: String, style: String? = nil) -> String {
        docxParagraph(
            docxRun("Shown ") + docxRun("secret ", properties) + docxRun("words"),
            style: style
        )
    }

    // MARK: - A run's own properties

    /// A run with `w:vanish` is not read; the words around it are, and the
    /// emphasis of the words around it is kept.
    func testAHiddenRunIsNotRead() throws {
        XCTAssertEqual(try markdown(paragraphHiding("<w:vanish/>")), "Shown words")
        // The words around hidden bold text keep their emphasis, with no mark of it
        // read aloud: the runs that touch are one stretch of bold.
        let emphasized = docxParagraph(docxRun("Bold ", "<w:b/>") + docxRun("gone ", "<w:b/><w:vanish/>") + docxRun("stays", "<w:b/>"))
        XCTAssertEqual(try markdown(emphasized), "**Bold stays**")
        XCTAssertEqual(try docxReadingText(body: emphasized, styles: styles), "Bold stays")
        let apart = docxParagraph(docxRun("See the ") + docxRun("gone ", "<w:vanish/>") + docxRun("note", "<w:b/>"))
        XCTAssertEqual(try docxReadingText(body: apart, styles: styles), "See the note")
    }

    /// `w:vanish` turned off by its value (0, false, off) reads the text; one
    /// turned on by every other value (1, true, on) hides it.
    func testTheValueOfVanishDecides() throws {
        for off in ["0", "false", "off"] {
            XCTAssertEqual(try markdown(paragraphHiding("<w:vanish w:val=\"\(off)\"/>")), "Shown secret words", off)
        }
        for on in ["1", "true", "on"] {
            XCTAssertEqual(try markdown(paragraphHiding("<w:vanish w:val=\"\(on)\"/>")), "Shown words", on)
        }
    }

    /// Text hidden only on the web shows in print and in the normal view: it
    /// is read. A hidden paragraph mark alone hides no run.
    func testWebHiddenTextIsReadAndAHiddenMarkHidesNoRun() throws {
        XCTAssertEqual(try markdown(paragraphHiding("<w:webHidden/>")), "Shown secret words")
        let hiddenMark = docxParagraph(docxRun("Whole words"), markProperties: "<w:vanish/><w:specVanish/>")
        XCTAssertEqual(try markdown(hiddenMark), "Whole words")
    }

    /// A line break, a tab, and a page break inside hidden text are hidden
    /// with it.
    func testBreaksAndTabsInHiddenTextAreNotRead() throws {
        let hiddenBreaks = docxParagraph(
            docxRun("One") + "<w:r><w:rPr><w:vanish/></w:rPr><w:br/><w:tab/></w:r>" + docxRun("Two")
        )
        XCTAssertEqual(try markdown(hiddenBreaks), "OneTwo")
        let shownBreak = docxParagraph(docxRun("One") + "<w:r><w:br/></w:r>" + docxRun("Two"))
        XCTAssertTrue(try markdown(shownBreak).contains("One\nTwo"), "A visible break still breaks the line")
    }

    // MARK: - Styles

    /// A character style that hides text hides the runs that name it, also
    /// when it is based on one that does; a style based on a hiding one that
    /// turns the property off shows the text.
    func testACharacterStyleCanHideARun() throws {
        XCTAssertEqual(try markdown(paragraphHiding("<w:rStyle w:val=\"Hide\"/>")), "Shown words")
        XCTAssertEqual(try markdown(paragraphHiding("<w:rStyle w:val=\"HideChild\"/>")), "Shown words")
        XCTAssertEqual(try markdown(paragraphHiding("<w:rStyle w:val=\"Show\"/>")), "Shown secret words")
        // A vanish that is only in the record of a change is not the style's.
        XCTAssertEqual(try markdown(paragraphHiding("<w:rStyle w:val=\"WasHidden\"/>")), "Shown secret words")
    }

    /// A paragraph style that hides text hides every run of its paragraphs,
    /// whole paragraphs included, which then write nothing at all.
    func testAParagraphStyleCanHideItsParagraphs() throws {
        let hidden = docxParagraph(docxRun("Nothing to hear"), style: "Secret")
        let child = docxParagraph(docxRun("Nothing here either"), style: "SecretChild")
        let shown = docxParagraph(docxRun("Back in view"), style: "SecretOff")
        XCTAssertEqual(
            try markdown(docxParagraph(docxRun("Before")), hidden, child, shown, docxParagraph(docxRun("After"))),
            "Before\n\nBack in view\n\nAfter"
        )
    }

    /// The default paragraph style is the style of a paragraph that names
    /// none: this one hides it.
    func testTheDefaultParagraphStyleAppliesToAParagraphWithNoStyle() throws {
        let hidingDefault = styles.replacingOccurrences(
            of: "<w:name w:val=\"Normal\"/>", with: "<w:name w:val=\"Normal\"/><w:rPr><w:vanish/></w:rPr>"
        )
        let body = docxParagraph(docxRun("Unstyled")) + docxParagraph(docxRun("Styled"), style: "Heading1")
        let markdown = try docxMarkdown(body: body, styles: hidingDefault)
        XCTAssertEqual(markdown, "# Styled")
    }

    /// The toggle rule (ECMA-376 17.7.3): a paragraph style and a character
    /// style that both hide show the text again; the run's own `w:vanish`
    /// settles it either way.
    func testPropertiesToggleAcrossTheParagraphAndCharacterStyle() throws {
        let both = docxParagraph(docxRun("Twice hidden is shown", "<w:rStyle w:val=\"Hide\"/>"), style: "Secret")
        XCTAssertEqual(try markdown(both), "Twice hidden is shown")
        // Direct formatting is not toggled: it decides alone.
        let shownDirectly = docxParagraph(docxRun("Directly shown", "<w:vanish w:val=\"0\"/>"), style: "Secret")
        XCTAssertEqual(try markdown(shownDirectly), "Directly shown")
        let hiddenDirectly = docxParagraph(docxRun("Directly hidden", "<w:rStyle w:val=\"Hide\"/><w:vanish/>"), style: "Secret")
        XCTAssertEqual(try markdown(hiddenDirectly), "")
    }

    /// What the styles part says: the paragraph and character styles that
    /// hide, the default paragraph style, and no table style's formatting.
    func testTheStylesPartNamesTheHidingStyles() throws {
        let docx = try makeDOCXPackage(document: docxDocumentXML(docxParagraph(docxRun("x"))), styles: styles)
        let parsed = try DOCXParser.readStyles(from: docx)
        // (Neither the table style's conditional formatting nor the same inside a
        // paragraph style, "Odd", makes a style hide.)
        XCTAssertEqual(parsed.hiddenParagraphStyles, ["Secret", "SecretChild"])
        XCTAssertEqual(parsed.hiddenCharacterStyles, ["Hide", "HideChild"])
        XCTAssertEqual(parsed.defaultParagraphStyle, "Normal")
    }

    // MARK: - Hidden by a table style, the document defaults, or a row

    /// Styles with table styles that hide their text: directly, through
    /// `w:basedOn`, turned off again in a child, and only in conditional
    /// formatting (which hides nothing here), beside a hidden paragraph style
    /// and a hidden character style.
    private let tableStyles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
        <w:style w:type="paragraph" w:styleId="Secret"><w:name w:val="Secret"/><w:rPr><w:vanish/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Shown"><w:name w:val="Shown"/><w:rPr><w:vanish w:val="0"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="SecretChild"><w:name w:val="SecretChild"/><w:basedOn w:val="Secret"/></w:style>
        <w:style w:type="paragraph" w:styleId="ParaOnTable"><w:name w:val="ParaOnTable"/><w:basedOn w:val="Ghost"/></w:style>
        <w:style w:type="paragraph" w:styleId="ParaOnChar"><w:name w:val="ParaOnChar"/><w:basedOn w:val="Hide"/></w:style>
        <w:style w:type="character" w:styleId="Hide"><w:name w:val="Hide"/><w:rPr><w:vanish/></w:rPr></w:style>
        <w:style w:type="table" w:styleId="TableOnChar"><w:name w:val="TableOnChar"/><w:basedOn w:val="Hide"/></w:style>
        <w:style w:type="table" w:styleId="TableOnPara"><w:name w:val="TableOnPara"/><w:basedOn w:val="Secret"/></w:style>
        <w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/></w:style>
        <w:style w:type="table" w:styleId="Ghost"><w:name w:val="Ghost"/><w:rPr><w:vanish/></w:rPr></w:style>
        <w:style w:type="table" w:styleId="GhostChild"><w:name w:val="GhostChild"/><w:basedOn w:val="Ghost"/></w:style>
        <w:style w:type="table" w:styleId="GhostOff"><w:name w:val="GhostOff"/><w:basedOn w:val="Ghost"/><w:rPr><w:vanish w:val="0"/></w:rPr></w:style>
        <w:style w:type="table" w:styleId="Banded"><w:name w:val="Banded"/><w:tblStylePr w:type="firstRow"><w:rPr><w:vanish/></w:rPr></w:tblStylePr></w:style>
        </w:styles>
        """

    /// A one-cell table of the paragraph "Cell" (its run having `runProperties`
    /// and its paragraph `paragraphStyle`) in table style `tableStyle`.
    private func table(
        style tableStyle: String?, runProperties: String = "", paragraphStyle: String? = nil
    ) -> String {
        let properties = tableStyle.map { "<w:tblPr><w:tblStyle w:val=\"\($0)\"/></w:tblPr>" } ?? "<w:tblPr/>"
        let cell = docxParagraph(docxRun("Cell", runProperties), style: paragraphStyle)
        return "<w:tbl>\(properties)<w:tr><w:tc>\(cell)</w:tc></w:tr></w:tbl>"
    }

    /// The words a listener hears of `body`, read with `styles`.
    private func spoken(_ body: String, styles: String) throws -> String {
        try docxReadingText(body: docxParagraph(docxRun("Before")) + body + docxParagraph(docxRun("After")), styles: styles)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A table style that hides its text hides the table's words, also
    /// through the table style it is based on, until a child turns it off.
    /// A table with another style, or none, is read, and so is one whose
    /// style hides only in its conditional formatting (ECMA-376 17.7.2).
    func testATableStyleCanHideItsText() throws {
        for (style, expected) in [
            ("Ghost", "Before After"), ("GhostChild", "Before After"), ("GhostOff", "Before Cell After"),
            ("Banded", "Before Cell After"), ("TableNormal", "Before Cell After"), (nil, "Before Cell After"),
        ] as [(String?, String)] {
            XCTAssertEqual(try spoken(table(style: style), styles: tableStyles), expected, style ?? "no style")
        }
    }

    /// A table style named inside `w:tblPrChange`, the record of the table's
    /// properties before a tracked change, is not the table's style: the table
    /// is read with the style outside it, or the default.
    func testATableStyleInATrackedChangeRecordIsNotTheTablesStyle() throws {
        let cell = docxParagraph(docxRun("Cell"))
        func spokenTable(_ properties: String) throws -> String {
            try spoken("<w:tbl><w:tblPr>\(properties)</w:tblPr><w:tr><w:tc>\(cell)</w:tc></w:tr></w:tbl>", styles: tableStyles)
        }
        let before = "<w:tblPrChange w:id=\"1\"><w:tblPr><w:tblStyle w:val=\"Ghost\"/></w:tblPr></w:tblPrChange>"
        XCTAssertEqual(try spokenTable(before), "Before Cell After")
        // The style that stands outside the record is the table's, whichever comes first.
        XCTAssertEqual(try spokenTable("<w:tblStyle w:val=\"Ghost\"/>" + before), "Before After")
        XCTAssertEqual(try spokenTable(before + "<w:tblStyle w:val=\"Ghost\"/>"), "Before After")
        XCTAssertEqual(try spokenTable("<w:tblStyle w:val=\"TableNormal\"/>" + before), "Before Cell After")
    }

    /// Word's rule for the table style, the paragraph style, and the character
    /// style (`DOCXHiding`, MS-OI29500 17.7.6(b) and 17.7.8(a)): a table style
    /// or a paragraph style that states a value resets the state to it, a
    /// character style that hides flips it, and a run's own `w:vanish` decides
    /// alone. A hidden table style and a hidden paragraph style hide the text
    /// (they did not, by the standard's XOR), and a paragraph style that shows
    /// it (`w:val="0"`) shows the text of a table that hides it.
    func testATableStyleAndAParagraphStyleResetAndACharacterStyleToggles() throws {
        let rStyle = "<w:rStyle w:val=\"Hide\"/>"
        let cases: [(String?, String, String?, String)] = [
            // (table style, run properties, paragraph style, what is heard)
            ("Ghost", "", "Secret", "Before After"),
            ("Ghost", "", "Shown", "Before Cell After"),
            ("Ghost", "", nil, "Before After"),
            ("Ghost", rStyle, nil, "Before Cell After"),
            ("Ghost", rStyle, "Secret", "Before Cell After"),
            ("Ghost", rStyle, "Shown", "Before After"),
            (nil, rStyle, "Secret", "Before Cell After"),
            (nil, "", "Secret", "Before After"),
            (nil, "", "Shown", "Before Cell After"),
            ("GhostOff", "", "Secret", "Before After"),
            ("Ghost", "<w:vanish w:val=\"0\"/>", nil, "Before Cell After"),
            (nil, "<w:vanish/>", nil, "Before After"),
            ("Ghost", rStyle + "<w:vanish/>", nil, "Before After"),
        ]
        for (tableStyle, runProperties, paragraphStyle, expected) in cases {
            let body = table(style: tableStyle, runProperties: runProperties, paragraphStyle: paragraphStyle)
            XCTAssertEqual(try spoken(body, styles: tableStyles), expected, "\(tableStyle ?? "-") \(runProperties) \(paragraphStyle ?? "-")")
        }
    }

    /// Every combination of what the document defaults, the table style, the
    /// paragraph style, the character style, and the run state (nothing, true,
    /// or false), 243, against a table built from the clauses by
    /// `toggle_table.py` and not from the rule's code: ECMA-376 17.7.3 (the
    /// run's own value is absolute), MS-OI29500 17.7.3(a) and (b) (with
    /// defaults true, a level with no value takes true, and the text is hidden
    /// if and only if an even number of the three levels are false), 17.7.6(b)
    /// and 17.7.8(a) (a table or paragraph style that states a value resets
    /// the state), and ECMA-376 17.7.3 for a character style (true flips,
    /// false leaves). Nothing is checked in Word itself.
    func testTheRuleGivesWordsAnswerInEveryCombination() {
        let value: [Character: Bool?] = ["n": .none, "T": true, "F": false]
        let rows = Self.toggleTable.split(whereSeparator: \.isWhitespace)
        XCTAssertEqual(rows.count, 243)
        for row in rows {
            let letters = Array(row)
            guard letters.count == 6, let defaults = value[letters[0]], let table = value[letters[1]],
                  let paragraph = value[letters[2]], let character = value[letters[3]], let direct = value[letters[4]] else {
                return XCTFail("Not a row of the table: \(row)")
            }
            let hidden = DOCXHiding.isHidden(
                documentDefaults: defaults, table: table, paragraph: paragraph, character: character, direct: direct)
            XCTAssertEqual(hidden ? "H" : "S", String(letters[5]), "defaults table paragraph character direct = \(row.prefix(5))")
        }
    }

    /// The 243 rows: defaults, table, paragraph, character, and the run's own
    /// state (n nothing, T true, F false), then H hidden or S shown.
    private static let toggleTable = """
        nnnnnS nnnnTH nnnnFS nnnTnH nnnTTH nnnTFS nnnFnS nnnFTH nnnFFS
        nnTnnH nnTnTH nnTnFS nnTTnS nnTTTH nnTTFS nnTFnH nnTFTH nnTFFS
        nnFnnS nnFnTH nnFnFS nnFTnH nnFTTH nnFTFS nnFFnS nnFFTH nnFFFS
        nTnnnH nTnnTH nTnnFS nTnTnS nTnTTH nTnTFS nTnFnH nTnFTH nTnFFS
        nTTnnH nTTnTH nTTnFS nTTTnS nTTTTH nTTTFS nTTFnH nTTFTH nTTFFS
        nTFnnS nTFnTH nTFnFS nTFTnH nTFTTH nTFTFS nTFFnS nTFFTH nTFFFS
        nFnnnS nFnnTH nFnnFS nFnTnH nFnTTH nFnTFS nFnFnS nFnFTH nFnFFS
        nFTnnH nFTnTH nFTnFS nFTTnS nFTTTH nFTTFS nFTFnH nFTFTH nFTFFS
        nFFnnS nFFnTH nFFnFS nFFTnH nFFTTH nFFTFS nFFFnS nFFFTH nFFFFS
        TnnnnH TnnnTH TnnnFS TnnTnH TnnTTH TnnTFS TnnFnS TnnFTH TnnFFS
        TnTnnH TnTnTH TnTnFS TnTTnH TnTTTH TnTTFS TnTFnS TnTFTH TnTFFS
        TnFnnS TnFnTH TnFnFS TnFTnS TnFTTH TnFTFS TnFFnH TnFFTH TnFFFS
        TTnnnH TTnnTH TTnnFS TTnTnH TTnTTH TTnTFS TTnFnS TTnFTH TTnFFS
        TTTnnH TTTnTH TTTnFS TTTTnH TTTTTH TTTTFS TTTFnS TTTFTH TTTFFS
        TTFnnS TTFnTH TTFnFS TTFTnS TTFTTH TTFTFS TTFFnH TTFFTH TTFFFS
        TFnnnS TFnnTH TFnnFS TFnTnS TFnTTH TFnTFS TFnFnH TFnFTH TFnFFS
        TFTnnS TFTnTH TFTnFS TFTTnS TFTTTH TFTTFS TFTFnH TFTFTH TFTFFS
        TFFnnH TFFnTH TFFnFS TFFTnH TFFTTH TFFTFS TFFFnS TFFFTH TFFFFS
        FnnnnS FnnnTH FnnnFS FnnTnH FnnTTH FnnTFS FnnFnS FnnFTH FnnFFS
        FnTnnH FnTnTH FnTnFS FnTTnS FnTTTH FnTTFS FnTFnH FnTFTH FnTFFS
        FnFnnS FnFnTH FnFnFS FnFTnH FnFTTH FnFTFS FnFFnS FnFFTH FnFFFS
        FTnnnH FTnnTH FTnnFS FTnTnS FTnTTH FTnTFS FTnFnH FTnFTH FTnFFS
        FTTnnH FTTnTH FTTnFS FTTTnS FTTTTH FTTTFS FTTFnH FTTFTH FTTFFS
        FTFnnS FTFnTH FTFnFS FTFTnH FTFTTH FTFTFS FTFFnS FTFFTH FTFFFS
        FFnnnS FFnnTH FFnnFS FFnTnH FFnTTH FFnTFS FFnFnS FFnFTH FFnFFS
        FFTnnH FFTnTH FFTnFS FFTTnS FFTTTH FFTTFS FFTFnH FFTFTH FFTFFS
        FFFnnS FFFnTH FFFnFS FFFTnH FFFTTH FFFTFS FFFFnS FFFFTH FFFFFS
        """

    /// A `w:basedOn` naming a style of another kind is ignored (ECMA-376
    /// 17.7.4.3): a table or paragraph style based on a character, paragraph,
    /// or table style that hides does not hide, while one based on a style of
    /// its own kind does.
    func testABasedOnOfAnotherKindIsIgnored() throws {
        let docx = try makeDOCXPackage(document: docxDocumentXML(docxParagraph(docxRun("x"))), styles: tableStyles)
        let parsed = try DOCXParser.readStyles(from: docx)
        XCTAssertEqual(parsed.hiddenParagraphStyles, ["Secret", "SecretChild"])
        XCTAssertEqual(parsed.hiddenCharacterStyles, ["Hide"])
        XCTAssertEqual(parsed.hiddenTableStyles, ["Ghost", "GhostChild"])
        XCTAssertNil(parsed.tableHiding["TableOnChar"])
        XCTAssertNil(parsed.tableHiding["TableOnPara"])
        XCTAssertNil(parsed.paragraphHiding["ParaOnTable"])
        XCTAssertNil(parsed.paragraphHiding["ParaOnChar"])
        // What a style states is kept, false included.
        XCTAssertEqual(parsed.paragraphHiding["Shown"], false)
        XCTAssertEqual(parsed.tableHiding["GhostOff"], false)
        XCTAssertEqual(parsed.tableHiding["Ghost"], true)
        XCTAssertNil(parsed.tableHiding["Banded"])
        // And in a document, text in such a table or paragraph is read.
        XCTAssertEqual(try spoken(table(style: "TableOnChar"), styles: tableStyles), "Before Cell After")
        XCTAssertEqual(try spoken(table(style: "TableOnPara"), styles: tableStyles), "Before Cell After")
        XCTAssertEqual(try spoken(table(style: nil, paragraphStyle: "ParaOnTable"), styles: tableStyles), "Before Cell After")
        XCTAssertEqual(try spoken(table(style: nil, paragraphStyle: "ParaOnChar"), styles: tableStyles), "Before Cell After")
        XCTAssertEqual(try spoken(table(style: nil, paragraphStyle: "SecretChild"), styles: tableStyles), "Before After")
    }

    /// Only a table style with `w:default` on sets the default table style: a
    /// paragraph or character style with it does not (it sets its own default),
    /// and `w:default="0"` is not on.
    func testOnlyATableStyleWithDefaultOnIsTheDefaultTableStyle() throws {
        let styles = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:style w:type="table" w:default="1" w:styleId="First"><w:name w:val="First"/></w:style>
            <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
            <w:style w:type="character" w:default="1" w:styleId="DefaultChar"><w:name w:val="DefaultChar"/></w:style>
            <w:style w:type="table" w:default="0" w:styleId="NotDefault"><w:name w:val="NotDefault"/></w:style>
            <w:style w:type="table" w:default="false" w:styleId="NotDefaultEither"><w:name w:val="NotDefaultEither"/></w:style>
            <w:style w:type="paragraph" w:default="0" w:styleId="NotNormal"><w:name w:val="NotNormal"/></w:style>
            </w:styles>
            """
        let docx = try makeDOCXPackage(document: docxDocumentXML(docxParagraph(docxRun("x"))), styles: styles)
        let parsed = try DOCXParser.readStyles(from: docx)
        XCTAssertEqual(parsed.defaultTableStyle, "First")
        XCTAssertEqual(parsed.defaultParagraphStyle, "Normal")
    }

    /// The innermost table's style is the one that counts for a table inside
    /// a cell, and the outer table's does not reach into it: the outer text
    /// of a table that hides is hidden and the inner table's is read.
    func testAnOuterTableStyleDoesNotHideANestedTable() throws {
        let inner = table(style: "TableNormal")
        let outer = "<w:tbl><w:tblPr><w:tblStyle w:val=\"Ghost\"/></w:tblPr><w:tr><w:tc>"
            + docxParagraph(docxRun("Outer")) + inner + "</w:tc></w:tr></w:tbl>"
        XCTAssertEqual(try spoken(outer, styles: tableStyles), "Before Cell After")
    }

    /// A table that names no style takes the default table style, as a
    /// paragraph does; here it hides.
    func testTheDefaultTableStyleAppliesToATableWithNoStyle() throws {
        let styles = tableStyles.replacingOccurrences(of: "w:default=\"1\" w:styleId=\"TableNormal\"", with: "w:styleId=\"TableNormal\"")
            .replacingOccurrences(of: "<w:style w:type=\"table\" w:styleId=\"Ghost\">", with: "<w:style w:type=\"table\" w:default=\"1\" w:styleId=\"Ghost\">")
        XCTAssertEqual(try spoken(table(style: nil), styles: styles), "Before After")
        XCTAssertEqual(try spoken(table(style: "TableNormal"), styles: styles), "Before Cell After")
        XCTAssertEqual(try spoken(table(style: "GhostOff"), styles: styles), "Before Cell After")
    }

    /// The innermost table's style is the one that counts for a table inside
    /// a cell.
    func testANestedTablesOwnStyleDecides() throws {
        let inner = table(style: "Ghost")
        let outer = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableNormal\"/></w:tblPr><w:tr><w:tc>"
            + docxParagraph(docxRun("Outer")) + inner + docxParagraph(docxRun("Tail")) + "</w:tc></w:tr></w:tbl>"
        XCTAssertEqual(try spoken(outer, styles: tableStyles), "Before Outer Tail After")
    }

    /// The document defaults can hide all text (`w:docDefaults`): then a level
    /// with no value takes the defaults' true, and the text is hidden if and
    /// only if an even number of the table, paragraph, and character styles
    /// state false (MS-OI29500 17.7.3(a) and (b)). So a style that states
    /// false, one of three, shows the text again, and a style that states true
    /// changes nothing. Defaults that say nothing, or turn it off, hide
    /// nothing.
    func testDocumentDefaultsCanHideAllText() throws {
        func styles(_ defaultProperties: String) -> String {
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:docDefaults><w:rPrDefault><w:rPr>\(defaultProperties)</w:rPr></w:rPrDefault></w:docDefaults>
            <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
            <w:style w:type="paragraph" w:styleId="Secret"><w:name w:val="Secret"/><w:rPr><w:vanish/></w:rPr></w:style>
            <w:style w:type="character" w:styleId="Hide"><w:name w:val="Hide"/><w:rPr><w:vanish/></w:rPr></w:style>
            <w:style w:type="character" w:styleId="Show"><w:name w:val="Show"/><w:rPr><w:vanish w:val="0"/></w:rPr></w:style>
            <w:style w:type="paragraph" w:styleId="Shown"><w:name w:val="Shown"/><w:rPr><w:vanish w:val="0"/></w:rPr></w:style>
            </w:styles>
            """
        }
        let paragraph = docxParagraph(docxRun("Words"))
        let hidden = styles("<w:vanish/>")
        XCTAssertEqual(try spoken(paragraph, styles: hidden), "")
        // One level that states false makes the count of false levels odd.
        XCTAssertEqual(try spoken(docxParagraph(docxRun("Words", "<w:rStyle w:val=\"Show\"/>")), styles: hidden), "Words")
        XCTAssertEqual(try spoken(docxParagraph(docxRun("Words"), style: "Shown"), styles: hidden), "Words")
        // Two of them make it even again.
        XCTAssertEqual(try spoken(docxParagraph(docxRun("Words", "<w:rStyle w:val=\"Show\"/>"), style: "Shown"), styles: hidden), "")
        XCTAssertEqual(try spoken(docxParagraph(docxRun("Words", "<w:rStyle w:val=\"Hide\"/>")), styles: hidden), "")
        XCTAssertEqual(try spoken(docxParagraph(docxRun("Words"), style: "Secret"), styles: hidden), "")
        XCTAssertEqual(try spoken(docxParagraph(docxRun("Words", "<w:vanish w:val=\"0\"/>")), styles: hidden), "Words")
        for shown in [styles(""), styles("<w:vanish w:val=\"0\"/>"), styles("<w:sz w:val=\"22\"/>")] {
            XCTAssertEqual(try spoken(paragraph, styles: shown), "Before Words After")
        }
    }

    /// A row marked hidden (`w:trPr` holding `w:hidden`) hides nothing of its
    /// own (the hidden row rule of `DOCXHiding`). So a row with an ordinary run
    /// shows its words, and a row whose runs and marks are all `w:vanish` reads
    /// nothing, which each run's own toggle says.
    func testAHiddenRowMarkHidesNothingOfItsOwn() throws {
        let hidden = "<w:hidden/>"
        func row(_ text: String, rowProperties: String = "", runProperties: String = "", markProperties: String = "") -> String {
            "<w:tr><w:trPr>\(rowProperties)</w:trPr><w:tc>"
                + docxParagraph(docxRun(text, runProperties), markProperties: markProperties) + "</w:tc></w:tr>"
        }
        func spokenRows(_ rows: String...) throws -> String {
            try spoken("<w:tbl><w:tblPr/>" + rows.joined() + "</w:tbl>", styles: styles)
        }
        // An ordinary run is read, whatever the mark says and wherever the row is.
        XCTAssertEqual(try spokenRows(row("marked row", rowProperties: hidden), row("plain row")),
                       "Before marked row plain row After")
        XCTAssertEqual(try spokenRows(row("plain row"), row("marked row", rowProperties: hidden)),
                       "Before plain row marked row After")
        for value in ["1", "true", "on", "0", "false", "off"] {
            XCTAssertEqual(try spokenRows(row("marked row", rowProperties: "<w:hidden w:val=\"\(value)\"/>")),
                           "Before marked row After", value)
        }
        // A run with its own `w:vanish` is hidden by that, and `w:val="0"` shows it.
        XCTAssertEqual(try spokenRows(row("gone", rowProperties: hidden, runProperties: "<w:vanish/>"), row("seen")),
                       "Before seen After")
        XCTAssertEqual(try spokenRows(row("shown", rowProperties: hidden, runProperties: "<w:vanish w:val=\"0\"/>")),
                       "Before shown After")
        // A row whose runs and paragraph marks are hidden reads nothing, and a table of them is not written.
        let wholeRowHidden = row("gone", rowProperties: hidden, runProperties: "<w:vanish/>", markProperties: "<w:vanish/>")
        XCTAssertEqual(try spokenRows(wholeRowHidden), "Before After")
        XCTAssertEqual(try spokenRows(wholeRowHidden, row("seen")), "Before seen After")
        // The words of a table nested in a marked row are read by their own toggles too.
        let nested = "<w:tbl><w:tblPr/>" + row("inner") + "</w:tbl>"
        let marked = "<w:tr><w:trPr>\(hidden)</w:trPr><w:tc>\(docxParagraph(docxRun("outer")))\(nested)</w:tc></w:tr>"
        XCTAssertEqual(try spokenRows(marked, row("after")), "Before outer inner after After")
    }

    /// Pages follow the same toggles: a page break in a hidden run begins no
    /// page, in a row marked hidden as anywhere, and a visible one in a marked
    /// row begins its page.
    func testAPageBreakInAMarkedRowBeginsAPageOnlyWhenItIsRead() throws {
        let breaking = "<w:r><w:br w:type=\"page\"/></w:r>"
        let hiddenBreaking = "<w:r><w:rPr><w:vanish/></w:rPr><w:br w:type=\"page\"/></w:r>"
        func labels(_ cell: String) throws -> [String] {
            let table = "<w:tbl><w:tblPr/><w:tr><w:trPr><w:hidden/></w:trPr><w:tc>\(cell)</w:tc></w:tr></w:tbl>"
            let markdown = try docxMarkdown(
                body: docxParagraph(docxRun("first")) + table + docxParagraph(docxRun("last")),
                styles: styles, includesPages: true)
            return try pageLabels(of: markdown)
        }
        XCTAssertEqual(try labels(docxParagraph(hiddenBreaking + docxRun("gone", "<w:vanish/>"))), ["1"])
        XCTAssertEqual(try labels(docxParagraph(breaking + docxRun("seen"))), ["1", "2"])
    }

    /// What the styles part names: the table styles that hide, the default
    /// table style, and whether the document defaults hide.
    func testTheStylesPartNamesTheHidingTableStylesAndDefaults() throws {
        let docx = try makeDOCXPackage(document: docxDocumentXML(docxParagraph(docxRun("x"))), styles: tableStyles)
        let parsed = try DOCXParser.readStyles(from: docx)
        XCTAssertEqual(parsed.hiddenTableStyles, ["Ghost", "GhostChild"])
        XCTAssertEqual(parsed.defaultTableStyle, "TableNormal")
        XCTAssertFalse(parsed.documentDefaultsHide)
        XCTAssertNil(parsed.documentDefaultsHiding)
        XCTAssertEqual(parsed.hiddenParagraphStyles, ["Secret", "SecretChild"])

        let hiding = tableStyles.replacingOccurrences(
            of: "<w:style w:type=\"paragraph\" w:default",
            with: "<w:docDefaults><w:rPrDefault><w:rPr><w:vanish/></w:rPr></w:rPrDefault></w:docDefaults><w:style w:type=\"paragraph\" w:default")
        let hidingDocx = try makeDOCXPackage(document: docxDocumentXML(docxParagraph(docxRun("x"))), styles: hiding)
        XCTAssertTrue(try DOCXParser.readStyles(from: hidingDocx).documentDefaultsHide)
        // A `w:vanish` in the defaults' paragraph properties' run mark is not the defaults' run properties.
        let paragraphDefaults = tableStyles.replacingOccurrences(
            of: "<w:style w:type=\"paragraph\" w:default",
            with: "<w:docDefaults><w:pPrDefault><w:pPr><w:rPr><w:vanish/></w:rPr></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type=\"paragraph\" w:default")
        let paragraphDocx = try makeDOCXPackage(document: docxDocumentXML(docxParagraph(docxRun("x"))), styles: paragraphDefaults)
        XCTAssertFalse(try DOCXParser.readStyles(from: paragraphDocx).documentDefaultsHide)
    }

    // MARK: - Headings and paragraphs

    /// A heading whose every word is hidden writes no empty heading, one with
    /// some hidden words keeps the rest, and a hidden paragraph mark leaves a
    /// run-in heading a heading.
    func testHeadingsAroundHiddenText() throws {
        let allHidden = docxParagraph(docxRun("Gone", "<w:vanish/>"), style: "Heading1")
        let partlyHidden = docxParagraph(docxRun("Chapter ") + docxRun("One ", "<w:vanish/>") + docxRun("Two"), style: "Heading1")
        XCTAssertEqual(try markdown(allHidden, partlyHidden), "# Chapter Two")

        let runIn = docxParagraph(docxRun("Run in heading"), style: "Heading1", markProperties: "<w:vanish/><w:specVanish/>")
        let body = docxParagraph(docxRun("The body that follows"))
        XCTAssertEqual(try markdown(runIn, body), "# Run in heading\n\nThe body that follows")
    }

    /// A hidden table cell leaves its cell empty and the others whole.
    func testHiddenTextInATableCell() throws {
        let cell = { (text: String, properties: String) in
            "<w:tc>" + self.docxParagraph(self.docxRun(text, properties)) + "</w:tc>"
        }
        let table = "<w:tbl><w:tr>" + cell("Seen", "") + cell("Unseen", "<w:vanish/>") + "</w:tr></w:tbl>"
        let result = try markdown(table)
        XCTAssertTrue(result.contains("Seen"), result)
        XCTAssertFalse(result.contains("Unseen"), result)
    }

    // MARK: - Pages

    /// How many page markers `markdown` holds.
    private func pageMarkers(in markdown: String) -> Int {
        markdown.components(separatedBy: "<!-- page:").count - 1
    }

    /// Text in a hidden run is left out of the page tracking: a page break
    /// and a last-rendered page break inside it begin no page, and the page
    /// a visible break begins is still marked.
    func testAPageBreakInHiddenTextBeginsNoPage() throws {
        let plain = try markdown(docxParagraph(docxRun("First page") + docxRun(" still the first")), includesPages: true)
        let hiddenBreak = try markdown(
            docxParagraph(
                docxRun("First page")
                    + "<w:r><w:rPr><w:vanish/></w:rPr><w:br w:type=\"page\"/><w:lastRenderedPageBreak/></w:r>"
                    + docxRun(" still the first")
            ),
            includesPages: true
        )
        XCTAssertEqual(pageMarkers(in: hiddenBreak), pageMarkers(in: plain))
        let shownBreak = try markdown(
            docxParagraph(docxRun("First page") + "<w:r><w:br w:type=\"page\"/></w:r>" + docxRun("Second page")),
            includesPages: true
        )
        XCTAssertEqual(pageMarkers(in: shownBreak), pageMarkers(in: plain) + 1)
    }

    // MARK: - Tracked changes

    /// Text a tracked change deleted is not read and text it inserted is,
    /// as for the other document readers.
    func testTrackedDeletionsAreNotReadAndInsertionsAre() throws {
        let deleted = "<w:del w:id=\"1\" w:author=\"A\"><w:r><w:delText xml:space=\"preserve\">gone </w:delText></w:r></w:del>"
        let inserted = "<w:ins w:id=\"2\" w:author=\"A\">" + docxRun("added ") + "</w:ins>"
        XCTAssertEqual(try markdown(docxParagraph(docxRun("Kept ") + deleted + inserted + docxRun("end"))), "Kept added end")
    }

    // MARK: - Fields, links, and boxes

    /// The result of a hidden field, a hidden link's label, and hidden text in
    /// a text box are left out as hidden words are anywhere; the words around
    /// them are read.
    func testHiddenFieldsLinksAndBoxes() throws {
        let hiddenField = """
            <w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText> PAGE </w:instrText></w:r>\
            <w:r><w:fldChar w:fldCharType="separate"/></w:r>\
            \(docxRun("7", "<w:vanish/>"))<w:r><w:fldChar w:fldCharType="end"/></w:r>
            """
        let hiddenLink = "<w:hyperlink r:id=\"rId9\">\(docxRun("link label", "<w:vanish/>"))</w:hyperlink>"
        let box = "<w:r><w:pict><w:txbxContent>\(docxParagraph(docxRun("hidden in box", "<w:vanish/>") + docxRun("shown in box")))</w:txbxContent></w:pict></w:r>"
        let body = docxParagraph(docxRun("A ") + hiddenField + docxRun("B ") + hiddenLink + docxRun("C") + box)
        XCTAssertEqual(try docxReadingText(body: body), "A B C\n\nshown in box")
    }

    // MARK: - Moved and deleted text

    /// Text a change moved is read once, where it was moved to; the old place
    /// (`w:moveFrom`) is a deletion. A `w:t` inside `w:del` is not read either.
    func testMovedTextIsReadOnceAndDeletedTextNever() throws {
        let from = "<w:moveFrom w:id=\"1\" w:author=\"A\">\(docxRun("moved words "))</w:moveFrom>"
        let to = "<w:moveTo w:id=\"2\" w:author=\"A\">\(docxRun("moved words"))</w:moveTo>"
        let deleted = "<w:del w:id=\"3\" w:author=\"A\">\(docxRun("gone "))</w:del>"
        let body = docxParagraph(docxRun("Start ") + from + docxRun("middle ") + to + docxRun(" end ") + deleted + docxRun("last"))
        XCTAssertEqual(try docxReadingText(body: body), "Start middle moved words end last")
    }

    /// A line break, a tab, and a hyphen in a deleted or moved-away run are left
    /// out with it.
    func testBreaksInDeletedRunsAreLeftOut() throws {
        let deleted = "<w:del w:id=\"1\" w:author=\"A\"><w:r><w:br/><w:tab/><w:noBreakHyphen/></w:r></w:del>"
        XCTAssertEqual(try docxReadingText(body: docxParagraph(docxRun("One") + deleted + docxRun("Two"))), "OneTwo")
    }

    /// A non-breaking hyphen is the hyphen RTF's `\\_` gives, and `w:cr` breaks
    /// the line as `w:br` does, unless hidden.
    func testNoBreakHyphenAndCarriageReturn() throws {
        let body = docxParagraph(
            docxRun("well") + "<w:r><w:noBreakHyphen/></w:r>" + docxRun("known") + "<w:r><w:cr/></w:r>" + docxRun("next")
                + "<w:r><w:rPr><w:vanish/></w:rPr><w:noBreakHyphen/><w:cr/></w:r>" + docxRun(" end")
        )
        XCTAssertEqual(try docxReadingText(body: body), "well-known next end")
    }

    // MARK: - Pages and tables

    /// A paragraph that holds hidden words and no visible ones begins no page
    /// by `w:pageBreakBefore`, whether the property is its own or its style's;
    /// a paragraph with no run at all still begins its page, and so does one
    /// whose words are visible.
    func testPageBreakBeforeOnAnUnreadParagraphBeginsNoPage() throws {
        let breaking = "<w:pPr><w:pageBreakBefore/></w:pPr>"
        let hidden = "<w:p>\(breaking)\(docxRun("hidden", "<w:vanish/>"))</w:p>"
        let styled = docxParagraph(docxRun("hidden", "<w:vanish/>"), style: "BreaksBefore")
        let empty = "<w:p>\(breaking)</w:p>"
        let visible = "<w:p>\(breaking)\(docxRun("seen"))</w:p>"
        let styles = self.styles.replacingOccurrences(
            of: "</w:styles>",
            with: "<w:style w:type=\"paragraph\" w:styleId=\"BreaksBefore\"><w:pPr><w:pageBreakBefore/></w:pPr></w:style></w:styles>"
        )
        func pages(_ paragraphs: String...) throws -> [String] {
            let markdown = try docxMarkdown(body: docxParagraph(docxRun("first")) + paragraphs.joined() + docxParagraph(docxRun("last")),
                                           styles: styles, includesPages: true)
            return try pageLabels(of: markdown)
        }
        XCTAssertEqual(try pages(hidden), ["1"])
        XCTAssertEqual(try pages(styled), ["1"])
        XCTAssertEqual(try pages(empty), ["1", "2"])
        XCTAssertEqual(try pages(visible), ["1", "2"])
    }

    /// A table in which no cell holds a word writes no table.
    func testATableOfHiddenWordsIsNotWritten() throws {
        func table(_ properties: String) -> String {
            "<w:tbl><w:tr><w:tc>\(docxParagraph(docxRun("x", properties)))</w:tc><w:tc>\(docxParagraph(docxRun("y", properties)))</w:tc></w:tr></w:tbl>"
        }
        XCTAssertEqual(try markdown(docxParagraph(docxRun("Before")), table("<w:vanish/>"), docxParagraph(docxRun("After"))), "Before\n\nAfter")
        XCTAssertTrue(try markdown(table("")).contains("| x | y |"))
    }
}
