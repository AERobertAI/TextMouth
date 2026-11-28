import XCTest
@testable import TextMouth

// MARK: - Text Boxes in Word Documents

/// The DOCX reader reads a text box once even though Word writes it twice,
/// in a `mc:Choice` and again in the `mc:Fallback` for older readers, and
/// loses no word of the paragraph that holds the box's anchor: the box's
/// paragraphs are paragraphs in the middle of another, whose words are set
/// aside while the box is read and are there when it goes on.
final class DOCXTextBoxTests: XCTestCase {

    // MARK: - Text boxes

    /// A text box as Word writes it: in a `mc:Choice` for current Word and
    /// again in the `mc:Fallback` for older readers.
    private func textBoxAlternate(_ words: String) -> String {
        """
        <w:r><mc:AlternateContent>
        <mc:Choice Requires="wps"><w:drawing><wps:wsp><wps:txbx><w:txbxContent>\(docxParagraph(docxRun(words)))</w:txbxContent></wps:txbx></wps:wsp></w:drawing></mc:Choice>
        <mc:Fallback><w:pict><v:shape><v:textbox><w:txbxContent>\(docxParagraph(docxRun(words)))</w:txbxContent></v:textbox></v:shape></w:pict></mc:Fallback>
        </mc:AlternateContent></w:r>
        """
    }

    /// A text box written in both the choice and the fallback is read once,
    /// and the words of the paragraph around its anchor are all there.
    func testATextBoxInAlternateContentIsReadOnce() throws {
        let body = docxParagraph(docxRun("Before the box ") + textBoxAlternate("Box words") + docxRun("after the box"))
        let result = try docxMarkdown(body: body)
        XCTAssertEqual(occurrences(of: "Box words", in: result), 1, result)
        XCTAssertTrue(result.contains("Before the box after the box"), result)
    }

    /// Only the first choice is read when there are several, and a fallback
    /// is read when no choice came before it.
    func testOnlyTheFirstChoiceIsReadAndALoneFallbackIs() throws {
        let twoChoices = """
            <w:r><mc:AlternateContent>
            <mc:Choice Requires="wps"><w:txbxContent>\(docxParagraph(docxRun("First choice")))</w:txbxContent></mc:Choice>
            <mc:Choice Requires="wpg"><w:txbxContent>\(docxParagraph(docxRun("Second choice")))</w:txbxContent></mc:Choice>
            <mc:Fallback><w:txbxContent>\(docxParagraph(docxRun("Fallback")))</w:txbxContent></mc:Fallback>
            </mc:AlternateContent></w:r>
            """
        let result = try docxMarkdown(body: docxParagraph(docxRun("Anchor ") + twoChoices))
        XCTAssertTrue(result.contains("First choice"), result)
        XCTAssertFalse(result.contains("Second choice"), result)
        XCTAssertFalse(result.contains("Fallback"), result)

        let loneFallback = """
            <w:r><mc:AlternateContent>
            <mc:Fallback><w:txbxContent>\(docxParagraph(docxRun("Only fallback")))</w:txbxContent></mc:Fallback>
            </mc:AlternateContent></w:r>
            """
        XCTAssertTrue(try docxMarkdown(body: docxParagraph(docxRun("x") + loneFallback)).contains("Only fallback"))
    }

    /// A text box outside any alternate content (the VML Word 2007 writes)
    /// is read once too, and two boxes in a row are two.
    func testATextBoxWithNoAlternateIsReadOnce() throws {
        let box = { (words: String) in
            "<w:r><w:pict><v:shape><v:textbox><w:txbxContent>\(self.docxParagraph(self.docxRun(words)))</w:txbxContent></v:textbox></v:shape></w:pict></w:r>"
        }
        let body = docxParagraph(docxRun("Lead ") + box("Box one") + box("Box two") + docxRun("tail"))
        let result = try docxMarkdown(body: body)
        XCTAssertEqual(occurrences(of: "Box one", in: result), 1, result)
        XCTAssertEqual(occurrences(of: "Box two", in: result), 1, result)
        XCTAssertTrue(result.contains("Lead tail"), result)
    }

    /// A text box inside a heading paragraph does not take the heading's
    /// words away, nor turn its own into a heading.
    func testATextBoxInAHeadingKeepsTheHeading() throws {
        let styles = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>
            </w:styles>
            """
        let body = docxParagraph(docxRun("Chapter ") + textBoxAlternate("Side words") + docxRun("Nine"), style: "Heading1")
        let result = compact(try docxMarkdown(body: body, styles: styles))
        XCTAssertEqual(occurrences(of: "Side words", in: result), 1, result)
        XCTAssertTrue(result.contains("# Chapter Nine"), result)
        XCTAssertFalse(result.contains("# Side words"), result)
    }

    /// An alternate content element that the damage cut off is closed with
    /// the rest: the text before the damage stands.
    func testDamageInsideAlternateContentKeepsTheTextBefore() throws {
        let intact = docxDocumentXML(docxParagraph(docxRun("Before ") + textBoxAlternate("Box words") + docxRun("after")))
        let cut = try XCTUnwrap(intact.range(of: "<mc:Fallback>"))
        let broken = String(intact[..<cut.lowerBound])
        let docx = try makeDOCXPackage(document: broken)
        var diagnostics: [DOCXParserError] = []
        let result = try DOCXParser.extractMarkdown(from: docx, includesPages: false) { diagnostics.append($0) }
        XCTAssertTrue(result.contains("Box words"), result)
        XCTAssertEqual(diagnostics.count, 1)
    }

    // MARK: - Which choice is read

    /// A typed emoji as Word writes it: a `w16se:symEx` choice the reader cannot
    /// read, and the character itself in the fallback. The fallback is read.
    func testATypedEmojiIsRead() throws {
        let emoji = """
            <w:r><mc:AlternateContent><mc:Choice Requires="w16se"><w16se:symEx w16se:font="Segoe UI Emoji" w16se:char="1F600"/></mc:Choice>\
            <mc:Fallback><w:t>\u{1F600}</w:t></mc:Fallback></mc:AlternateContent></w:r>
            """
        let body = docxParagraph(docxRun("Smile ") + emoji + docxRun(" now"))
        XCTAssertEqual(try docxReadingText(body: body), "Smile \u{1F600} now")
    }

    /// A choice that requires a prefix the reader does not know is passed over
    /// for the next one it does, and the fallback is read only when none
    /// is: here the later `wps` choice.
    func testAChoiceWithAnUnknownPrefixGivesWayToTheNextChoice() throws {
        let alternate = """
            <w:r><mc:AlternateContent>\
            <mc:Choice Requires="w99"><w:t>Future</w:t></mc:Choice>\
            <mc:Choice Requires="wps w99"><w:t>Half known</w:t></mc:Choice>\
            <mc:Choice Requires="wps"><w:t>Known</w:t></mc:Choice>\
            <mc:Fallback><w:t>Fallback</w:t></mc:Fallback></mc:AlternateContent></w:r>
            """
        XCTAssertEqual(try docxReadingText(body: docxParagraph(docxRun("A ") + alternate)), "A Known")
        let unknownOnly = """
            <w:r><mc:AlternateContent><mc:Choice Requires="w99"><w:t>Future</w:t></mc:Choice>\
            <mc:Fallback><w:t>Fallback</w:t></mc:Fallback></mc:AlternateContent></w:r>
            """
        XCTAssertEqual(try docxReadingText(body: docxParagraph(docxRun("A ") + unknownOnly)), "A Fallback")
    }

    // MARK: - Where the box is read

    /// A text box is read right after the paragraph that holds its anchor, so
    /// that the sentence is whole.
    func testATextBoxIsReadRightAfterItsAnchorParagraph() throws {
        let body = docxParagraph(docxRun("Before ") + textBoxAlternate("Boxed words") + docxRun("after."))
            + docxParagraph(docxRun("Next paragraph."))
        XCTAssertEqual(
            try docxReadingText(body: body),
            "Before after.\n\nBoxed words\n\nNext paragraph."
        )
    }

    /// A page break before the box keeps its page and the words after it: the
    /// box has no pages of its own and takes none of the document's.
    func testAPageBreakBeforeABoxKeepsItsPageAndItsWords() throws {
        let body = docxParagraph(
            docxRun("A") + "<w:r><w:br w:type=\"page\"/></w:r>" + textBoxAlternate("B") + docxRun("C")
        )
        let markdown = try docxMarkdown(body: body, includesPages: true)
        XCTAssertEqual(try pageLabels(of: markdown), ["1", "2"])
        let reading = try MarkdownDocParser.parseChapter(markdown: markdown).text
        XCTAssertEqual(reading, "A C\n\nB")
    }

    /// A box in a list item does not end the numbering of the list.
    func testABoxInAListItemKeepsTheListWhole() throws {
        let numbering = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>
            <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>
            """
        func item(_ content: String) -> String {
            "<w:p><w:pPr><w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"1\"/></w:numPr></w:pPr>\(content)</w:p>"
        }
        let body = item(docxRun("One")) + item(docxRun("Two") + textBoxAlternate("Side")) + item(docxRun("Three"))
        let markdown = try docxMarkdown(body: body, numbering: numbering)
        XCTAssertEqual(compact(markdown), "1. One\n2. Two\n\nSide\n\n3. Three")
    }

    /// A box anchored in a table cell is read in the cell, after the words of
    /// the paragraph that holds it.
    func testABoxInACellStaysInTheCell() throws {
        let table = "<w:tbl><w:tr><w:tc>"
            + docxParagraph(docxRun("Left ") + textBoxAlternate("In box") + docxRun("right"))
            + "</w:tc><w:tc>" + docxParagraph(docxRun("Other")) + "</w:tc></w:tr></w:tbl>"
        let markdown = try docxMarkdown(body: table)
        XCTAssertTrue(markdown.contains("| Left right In box | Other |"), markdown)
    }

    /// A box inside a box is read after the paragraph of the box that holds it.
    func testNestedBoxesAreReadAfterTheirAnchors() throws {
        let inner = "<w:r><w:pict><w:txbxContent>"
            + docxParagraph(docxRun("Mid ") + textBoxAlternate("Inner") + docxRun("end"))
            + "</w:txbxContent></w:pict></w:r>"
        let body = docxParagraph(docxRun("Outer ") + inner + docxRun("tail"))
        XCTAssertEqual(try docxReadingText(body: body), "Outer tail\n\nMid end\n\nInner")
    }

    // MARK: - Boxes nobody sees

    /// A box anchored in hidden text, or in text a tracked change deleted or
    /// moved away, is not read; one in visible text is.
    func testABoxAnchoredInHiddenOrDeletedTextIsNotRead() throws {
        let box = "<w:pict><w:txbxContent>\(docxParagraph(docxRun("Boxed words")))</w:txbxContent></w:pict>"
        let hidden = "<w:r><w:rPr><w:vanish/></w:rPr>\(box)</w:r>"
        let deleted = "<w:del w:id=\"1\" w:author=\"A\"><w:r>\(box)</w:r></w:del>"
        let moved = "<w:moveFrom w:id=\"2\" w:author=\"A\"><w:r>\(box)</w:r></w:moveFrom>"
        let visible = "<w:r>\(box)</w:r>"
        for (name, anchor) in [("hidden", hidden), ("deleted", deleted), ("moved", moved)] {
            let result = try docxReadingText(body: docxParagraph(docxRun("A") + anchor + docxRun("B")))
            XCTAssertEqual(result, "AB", name)
        }
        XCTAssertEqual(
            try docxReadingText(body: docxParagraph(docxRun("A") + visible + docxRun("B"))), "AB\n\nBoxed words"
        )
    }

    /// The damage cut inside the box: the box's words and the anchor paragraph's
    /// words are both kept.
    func testDamageInsideABoxKeepsBothParagraphs() throws {
        let intact = docxDocumentXML(docxParagraph(docxRun("Before ") + textBoxAlternate("Box words here") + docxRun("after")))
        let cut = try XCTUnwrap(intact.range(of: "words here"))
        let docx = try makeDOCXPackage(document: String(intact[..<cut.lowerBound]) + "words")
        var diagnostics: [DOCXParserError] = []
        let result = try DOCXParser.extractMarkdown(from: docx, includesPages: false) { diagnostics.append($0) }
        XCTAssertTrue(result.contains("Before"), result)
        XCTAssertTrue(result.contains("Box words"), result)
        XCTAssertEqual(diagnostics.count, 1)
    }
}
