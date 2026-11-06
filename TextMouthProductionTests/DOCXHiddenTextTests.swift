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
        // The words around hidden bold text keep their emphasis.
        let emphasized = docxParagraph(docxRun("Bold", "<w:b/>") + docxRun("gone", "<w:b/><w:vanish/>") + docxRun("stays", "<w:b/>"))
        let result = try markdown(emphasized)
        XCTAssertFalse(result.contains("gone"), result)
        XCTAssertEqual(result, "**Bold****stays**")
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
        XCTAssertEqual(parsed.hiddenParagraphStyles, ["Secret", "SecretChild"])
        XCTAssertEqual(parsed.hiddenCharacterStyles, ["Hide", "HideChild"])
        XCTAssertEqual(parsed.defaultParagraphStyle, "Normal")
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
}
