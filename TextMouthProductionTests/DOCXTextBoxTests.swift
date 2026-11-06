import XCTest
@testable import TextMouth

// MARK: - Text Boxes in Word Documents

/// The DOCX reader reads a text box once even though Word writes it twice,
/// in a `mc:Choice` and again in the `mc:Fallback` for older readers, and
/// loses no word of the paragraph that holds the box's anchor: the box's
/// paragraphs are paragraphs in the middle of another, whose words are set
/// aside while the box is read and are there when it goes on.
final class DOCXTextBoxTests: XCTestCase {

    /// The Markdown with its runs of blank lines made one.
    private func compact(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "\n{2,}", with: "\n\n", options: .regularExpression)
    }

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

    /// How many times `needle` is in `text`.
    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
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
}
