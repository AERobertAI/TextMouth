import XCTest
@testable import TextMouth

// MARK: - Footnotes and Endnotes in Word Documents

/// The DOCX reader reads a document's footnotes and endnotes (parts it never
/// opened before) after its text, in the order each part keeps them: the
/// separators and the marks that stand for a note's number are not read, a
/// note's text is never a heading, and a note begins no page.
final class DOCXNotesTests: XCTestCase {

    // MARK: - Fixtures

    /// A run that refers to the note numbered `id`, which holds no text.
    private func reference(_ kind: String, _ id: Int) -> String {
        "<w:r><w:rPr><w:rStyle w:val=\"NoteReference\"/></w:rPr><w:\(kind)Reference w:id=\"\(id)\"/></w:r>"
    }

    /// The footnotes part with Word's two separators and `notes`.
    private func footnotesPart(_ notes: String) -> String {
        docxNotesXML(root: "footnotes", """
            <w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>
            <w:footnote w:type="continuationSeparator" w:id="0"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>
            \(notes)
            """)
    }

    /// The Markdown with its runs of blank lines made one.
    private func compact(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "\n{2,}", with: "\n\n", options: .regularExpression)
    }

    /// A body of one paragraph holding two note references.
    private var bodyWithReferences: String {
        docxParagraph(docxRun("Main text") + reference("footnote", 1) + docxRun(" goes on") + reference("endnote", 1))
    }

    // MARK: - Notes

    /// The footnotes follow the text and the endnotes follow the footnotes;
    /// the separators are not read and neither are the marks of the numbers.
    func testNotesAreReadAfterTheText() throws {
        let footnotes = footnotesPart(docxNote("footnote", id: 1, text: "A footnote"))
        let endnotes = docxNotesXML(root: "endnotes", """
            <w:endnote w:type="separator" w:id="-1"><w:p><w:r><w:t>Separator words</w:t></w:r></w:p></w:endnote>
            \(docxNote("endnote", id: 1, text: "An endnote"))
            """)
        let result = try docxMarkdown(body: bodyWithReferences, footnotes: footnotes, endnotes: endnotes)
        XCTAssertEqual(compact(result), "Main text goes on\n\nA footnote\n\nAn endnote")
    }

    /// Each part is read in the order it keeps its notes, not by their
    /// numbers.
    func testNotesKeepTheOrderOfTheFile() throws {
        let footnotes = footnotesPart(
            docxNote("footnote", id: 2, text: "Second by number but first in the file")
                + docxNote("footnote", id: 1, text: "First by number")
        )
        let result = try docxMarkdown(body: bodyWithReferences, footnotes: footnotes)
        XCTAssertEqual(compact(result), "Main text goes on\n\nSecond by number but first in the file\n\nFirst by number")
    }

    /// The three kinds of note that only separate (and continue) the others
    /// are skipped, whatever they hold; a note with no type, or the type
    /// "normal", is read.
    func testSeparatorNotesAreSkipped() throws {
        let footnotes = docxNotesXML(root: "footnotes", """
            \(docxNote("footnote", id: -1, text: "separator words", type: "separator"))
            \(docxNote("footnote", id: 0, text: "continuation separator words", type: "continuationSeparator"))
            \(docxNote("footnote", id: 5, text: "continuation notice words", type: "continuationNotice"))
            \(docxNote("footnote", id: 1, text: "Plain note", type: "normal"))
            \(docxNote("footnote", id: 2, text: "Untyped note"))
            """)
        let result = try docxMarkdown(body: docxParagraph(docxRun("Body")), footnotes: footnotes)
        XCTAssertEqual(compact(result), "Body\n\nPlain note\n\nUntyped note")
    }

    /// A note keeps its paragraphs and its emphasis, and hidden text and
    /// deleted text in it are left out as in the text.
    func testANoteKeepsItsParagraphsAndEmphasis() throws {
        let note = """
            <w:footnote w:id="1">
            \(docxParagraph("<w:r><w:footnoteRef/></w:r>" + docxRun(" Plain and ") + docxRun("bold", "<w:b/>")))
            \(docxParagraph(docxRun("Second ") + docxRun("hidden ", "<w:vanish/>") + docxRun("paragraph")))
            </w:footnote>
            """
        let result = try docxMarkdown(body: docxParagraph(docxRun("Body")), footnotes: footnotesPart(note))
        XCTAssertEqual(compact(result), "Body\n\nPlain and **bold**\n\nSecond paragraph")
    }

    /// A note's text is never a heading, whatever style it names.
    func testANotesTextIsNeverAHeading() throws {
        let styles = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>
            </w:styles>
            """
        let footnotes = footnotesPart(docxNote("footnote", id: 1, text: "Styled as a heading", paragraphStyle: "Heading1"))
        let body = docxParagraph(docxRun("Chapter"), style: "Heading1")
        let result = try docxMarkdown(body: body, styles: styles, footnotes: footnotes)
        XCTAssertEqual(compact(result), "# Chapter\n\nStyled as a heading")
    }

    /// A note adds no page: the pages of the text are the same with the
    /// notes, and a page break inside a note begins none.
    func testANoteAddsNoPage() throws {
        let body = docxParagraph(docxRun("Page one") + "<w:r><w:br w:type=\"page\"/></w:r>" + docxRun("Page two") + reference("footnote", 1))
        let withoutNotes = try docxMarkdown(body: body, includesPages: true)
        let note = """
            <w:footnote w:id="1">
            \(docxParagraph("<w:r><w:footnoteRef/></w:r><w:r><w:br w:type=\"page\"/></w:r>" + docxRun("Note words")))
            </w:footnote>
            """
        let withNotes = try docxMarkdown(body: body, footnotes: footnotesPart(note), includesPages: true)
        let markers = { (markdown: String) in markdown.components(separatedBy: "<!-- page:").count - 1 }
        XCTAssertEqual(markers(withNotes), markers(withoutNotes))
        XCTAssertTrue(withNotes.contains("Note words"), withNotes)
        // The text before the notes is exactly the text without them.
        XCTAssertTrue(withNotes.hasPrefix(withoutNotes), withNotes)
    }

    /// A link in a note keeps its label and no target.
    func testALinkInANoteKeepsItsLabel() throws {
        let note = """
            <w:footnote w:id="1">
            \(docxParagraph("<w:hyperlink r:id=\"rId9\">" + docxRun("see the label") + "</w:hyperlink>"))
            </w:footnote>
            """
        let result = try docxMarkdown(body: docxParagraph(docxRun("Body")), footnotes: footnotesPart(note))
        XCTAssertEqual(compact(result), "Body\n\nsee the label")
    }

    /// A document with no notes parts, or notes parts holding only
    /// separators, reads exactly as before.
    func testDocumentsWithoutNotesAreUnchanged() throws {
        let body = docxParagraph(docxRun("Just the text"))
        let plain = try docxMarkdown(body: body)
        XCTAssertEqual(plain, "Just the text")
        let separatorsOnly = try docxMarkdown(body: body, footnotes: footnotesPart(""))
        XCTAssertEqual(separatorsOnly, plain)
        // A document that is nothing but notes reads them.
        let onlyNotes = try docxMarkdown(body: "", footnotes: footnotesPart(docxNote("footnote", id: 1, text: "Only a note")))
        XCTAssertEqual(onlyNotes, "Only a note")
    }

    // MARK: - Limits and damage

    /// A notes part holding more than the most TextMouth reads from one file
    /// is refused by name, as the text part is.
    func testANotesPartPastTheLimitIsRefused() throws {
        let footnotes = footnotesPart(docxNote("footnote", id: 1, text: String(repeating: "word ", count: 400)))
        let docx = try makeDOCXPackage(document: docxDocumentXML(docxParagraph(docxRun("Body"))), footnotes: footnotes)
        let limit: Int64 = 1_000
        try ArchiveEntryLimits.$current.withValue(ArchiveEntryLimits(audio: limit, text: limit)) {
            XCTAssertThrowsError(try DOCXParser.extractMarkdown(from: docx)) { error in
                guard case let .malformedXML(file, reason)? = error as? DOCXParserError else {
                    return XCTFail("Expected a damaged part, got \(error)")
                }
                XCTAssertEqual(file, "word/footnotes.xml")
                XCTAssertEqual(reason, ArchiveEntryOverflow.pastLimit(path: file, limit: limit).reason)
            }
        }
    }

    /// A notes part that breaks off after some of its text keeps that text
    /// and reports the damage, as the text part does; one damaged before any
    /// of its text is refused by name.
    func testADamagedNotesPart() throws {
        let intact = footnotesPart(docxNote("footnote", id: 1, text: "First note") + docxNote("footnote", id: 2, text: "Second note"))
        let cutAt = try XCTUnwrap(intact.range(of: "Second note"))
        let broken = String(intact[..<cutAt.lowerBound]) + "Second"
        var diagnostics: [DOCXParserError] = []
        let docx = try makeDOCXPackage(document: docxDocumentXML(docxParagraph(docxRun("Body"))), footnotes: broken)
        let result = try DOCXParser.extractMarkdown(from: docx, includesPages: false) { diagnostics.append($0) }
        XCTAssertTrue(result.contains("First note"), result)
        XCTAssertEqual(diagnostics.count, 1)

        let unreadable = try makeDOCXPackage(
            document: docxDocumentXML(docxParagraph(docxRun("Body"))),
            footnotes: "<?xml version=\"1.0\"?><w:footnotes xmlns:w=\"urn:w\"><w:footnote"
        )
        XCTAssertThrowsError(try DOCXParser.extractMarkdown(from: unreadable)) { error in
            guard case let .malformedXML(file, _)? = error as? DOCXParserError else {
                return XCTFail("Expected a damaged part, got \(error)")
            }
            XCTAssertEqual(file, "word/footnotes.xml")
        }
    }
}
