import XCTest
@testable import TextMouth

// MARK: - Footnotes and Endnotes in Word Documents

/// The DOCX reader reads a document's footnotes and endnotes after its text,
/// in the order each part keeps them, but only the notes that a reference the
/// body read points to (a person who sees no reference sees no note): the
/// separators and the marks that stand for a note's number are not read, a
/// note's text is never a heading, a note begins no page, and a notes part
/// that is damaged or too large loses its notes without refusing the book.
final class DOCXNotesTests: XCTestCase {

    // MARK: - Fixtures

    /// A run that refers to the note numbered `id`, which holds no text.
    private func reference(_ kind: String, _ id: Int, properties: String = "") -> String {
        "<w:r><w:rPr><w:rStyle w:val=\"NoteReference\"/>\(properties)</w:rPr><w:\(kind)Reference w:id=\"\(id)\"/></w:r>"
    }

    /// The footnotes part with Word's two separators and `notes`.
    private func footnotesPart(_ notes: String) -> String {
        docxNotesXML(root: "footnotes", """
            <w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>
            <w:footnote w:type="continuationSeparator" w:id="0"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>
            \(notes)
            """)
    }

    /// A body of one paragraph that refers to footnotes `footnotes` and
    /// endnotes `endnotes`, in the runs of its words.
    private func body(footnotes: [Int] = [1], endnotes: [Int] = []) -> String {
        docxParagraph(
            docxRun("Main text")
                + footnotes.map { reference("footnote", $0) }.joined()
                + docxRun(" goes on")
                + endnotes.map { reference("endnote", $0) }.joined()
        )
    }

    // MARK: - Which notes, and in what order

    /// The footnotes follow the text and the endnotes follow the footnotes;
    /// the separators are not read and neither are the marks of the numbers.
    func testNotesAreReadAfterTheText() throws {
        let footnotes = footnotesPart(docxNote("footnote", id: 1, text: "A footnote"))
        let endnotes = docxNotesXML(root: "endnotes", """
            <w:endnote w:type="separator" w:id="-1"><w:p><w:r><w:t>Separator words</w:t></w:r></w:p></w:endnote>
            \(docxNote("endnote", id: 1, text: "An endnote"))
            """)
        let result = try docxMarkdown(body: body(endnotes: [1]), footnotes: footnotes, endnotes: endnotes)
        XCTAssertEqual(compact(result), "Main text goes on\n\nA footnote\n\nAn endnote")
    }

    /// Each part is read in the order it keeps its notes, not by their
    /// numbers or the order of the references.
    func testNotesKeepTheOrderOfTheFile() throws {
        let footnotes = footnotesPart(
            docxNote("footnote", id: 2, text: "Second by number but first in the file")
                + docxNote("footnote", id: 1, text: "First by number")
        )
        let result = try docxMarkdown(body: body(footnotes: [1, 2]), footnotes: footnotes)
        XCTAssertEqual(compact(result), "Main text goes on\n\nSecond by number but first in the file\n\nFirst by number")
    }

    /// The three kinds of note that only separate (and continue) the others
    /// are skipped, whatever they hold and even when a reference names them;
    /// a note with no type, or the type "normal", is read.
    func testSeparatorNotesAreSkipped() throws {
        let footnotes = docxNotesXML(root: "footnotes", """
            \(docxNote("footnote", id: -1, text: "separator words", type: "separator"))
            \(docxNote("footnote", id: 0, text: "continuation separator words", type: "continuationSeparator"))
            \(docxNote("footnote", id: 5, text: "continuation notice words", type: "continuationNotice"))
            \(docxNote("footnote", id: 1, text: "Plain note", type: "normal"))
            \(docxNote("footnote", id: 2, text: "Untyped note"))
            """)
        let result = try docxMarkdown(body: body(footnotes: [-1, 0, 5, 1, 2]), footnotes: footnotes)
        XCTAssertEqual(compact(result), "Main text goes on\n\nPlain note\n\nUntyped note")
    }

    /// A note that no reference points to is one nobody sees: it is not read.
    func testANoteNoReferencePointsToIsNotRead() throws {
        let footnotes = footnotesPart(
            docxNote("footnote", id: 1, text: "Referred to") + docxNote("footnote", id: 2, text: "Orphan")
        )
        XCTAssertEqual(compact(try docxMarkdown(body: body(), footnotes: footnotes)), "Main text goes on\n\nReferred to")
        // Nor is a note whose reference names no id, or an id the part lacks.
        let odd = docxParagraph(docxRun("Odd") + "<w:r><w:footnoteReference/></w:r>" + reference("footnote", 9))
        XCTAssertEqual(try docxMarkdown(body: odd, footnotes: footnotes), "Odd")
    }

    /// The reference of a note is seen only when its words are: a reference in
    /// hidden text, in a paragraph of a hiding style, in deleted or moved text,
    /// or in the fallback of alternate content that a choice replaced, makes
    /// no note. A visible reference does.
    func testANoteWhoseReferenceIsNotSeenIsNotRead() throws {
        let styles = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:style w:type="paragraph" w:styleId="Secret"><w:name w:val="Secret"/><w:rPr><w:vanish/></w:rPr></w:style>
            <w:style w:type="character" w:styleId="NoteReference"><w:name w:val="Note Reference"/></w:style>
            </w:styles>
            """
        let footnotes = footnotesPart((1...6).map { docxNote("footnote", id: $0, text: "Note \($0)") }.joined())
        let hidden = reference("footnote", 1, properties: "<w:vanish/>")
        let inHidingParagraph = docxParagraph(docxRun("B") + reference("footnote", 2), style: "Secret")
        let deleted = "<w:del w:id=\"1\" w:author=\"A\">\(reference("footnote", 3))</w:del>"
        let moved = "<w:moveFrom w:id=\"2\" w:author=\"A\">\(reference("footnote", 4))</w:moveFrom>"
        let replaced = """
            <w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:t>choice</w:t></mc:Choice>\
            <mc:Fallback>\(reference("footnote", 5))</mc:Fallback></mc:AlternateContent></w:r>
            """
        let visible = reference("footnote", 6)
        let document = docxParagraph(docxRun("A") + hidden + deleted + moved + replaced + visible) + inHidingParagraph
        let result = try docxMarkdown(body: document, styles: styles, footnotes: footnotes)
        XCTAssertEqual(compact(result), "Achoice\n\nNote 6")
    }

    // MARK: - What a note keeps

    /// A note keeps its paragraphs and its emphasis, and hidden text and
    /// deleted text in it are left out as in the text.
    func testANoteKeepsItsParagraphsAndEmphasis() throws {
        let note = """
            <w:footnote w:id="1">
            \(docxParagraph("<w:r><w:footnoteRef/></w:r>" + docxRun(" Plain and ") + docxRun("bold", "<w:b/>")))
            \(docxParagraph(docxRun("Second ") + docxRun("hidden ", "<w:vanish/>") + docxRun("paragraph")))
            </w:footnote>
            """
        let result = try docxMarkdown(body: body(), footnotes: footnotesPart(note))
        XCTAssertEqual(compact(result), "Main text goes on\n\nPlain and **bold**\n\nSecond paragraph")
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
        let heading = docxParagraph(docxRun("Chapter") + reference("footnote", 1), style: "Heading1")
        let result = try docxMarkdown(body: heading, styles: styles, footnotes: footnotes)
        XCTAssertEqual(compact(result), "# Chapter\n\nStyled as a heading")
    }

    /// A note adds no page: the pages of the text are the same with the
    /// notes, and a page break inside a note begins none.
    func testANoteAddsNoPage() throws {
        let text = docxParagraph(
            docxRun("Page one") + "<w:r><w:br w:type=\"page\"/></w:r>" + docxRun("Page two") + reference("footnote", 1)
        )
        let withoutNotes = try docxMarkdown(body: text, includesPages: true)
        let note = """
            <w:footnote w:id="1">
            \(docxParagraph("<w:r><w:footnoteRef/></w:r><w:r><w:br w:type=\"page\"/></w:r>" + docxRun("Note words")))
            </w:footnote>
            """
        let withNotes = try docxMarkdown(body: text, footnotes: footnotesPart(note), includesPages: true)
        XCTAssertEqual(try pageLabels(of: withNotes), try pageLabels(of: withoutNotes))
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
        let result = try docxMarkdown(body: body(), footnotes: footnotesPart(note))
        XCTAssertEqual(compact(result), "Main text goes on\n\nsee the label")
    }

    /// A custom mark (an asterisk, a dagger) is not a word, in the body after
    /// the reference that says one follows, and at the head of its note.
    func testACustomReferenceMarkIsNotRead() throws {
        let custom = """
            <w:r><w:rPr><w:rStyle w:val="NoteReference"/></w:rPr><w:footnoteReference w:customMarkFollows="1" w:id="1"/><w:t>*</w:t></w:r>
            """
        let text = docxParagraph(docxRun("Body") + custom + docxRun(" text"))
        let note = """
            <w:footnote w:id="1">
            \(docxParagraph("<w:r><w:rPr><w:rStyle w:val=\"NoteReference\"/></w:rPr><w:t>*</w:t></w:r>" + docxRun(" Custom note")))
            </w:footnote>
            """
        let result = try docxReadingText(body: text, footnotes: footnotesPart(note))
        XCTAssertEqual(result, "Body text\n\nCustom note")
        // The words of a note's first run in another style are words.
        let plain = """
            <w:footnote w:id="1">\(docxParagraph(docxRun("Words in no reference style")))</w:footnote>
            """
        XCTAssertEqual(
            try docxReadingText(body: text, footnotes: footnotesPart(plain)), "Body text\n\nWords in no reference style"
        )
    }

    /// A document that refers to no notes reads as it did, whatever its notes
    /// parts hold; one that is nothing but a reference reads its note.
    func testDocumentsWithoutReferencesAreUnchanged() throws {
        let text = docxParagraph(docxRun("Just the text"))
        let plain = try docxMarkdown(body: text)
        XCTAssertEqual(plain, "Just the text")
        XCTAssertEqual(try docxMarkdown(body: text, footnotes: footnotesPart("")), plain)
        XCTAssertEqual(try docxMarkdown(body: text, footnotes: footnotesPart(docxNote("footnote", id: 1, text: "Unseen"))), plain)
        let onlyReference = docxParagraph(reference("footnote", 1))
        let onlyNotes = try docxMarkdown(body: onlyReference, footnotes: footnotesPart(docxNote("footnote", id: 1, text: "Only a note")))
        XCTAssertEqual(onlyNotes, "Only a note")
    }

    // MARK: - Limits and damage

    /// The book is read, and the damage reported, when a notes part is
    /// `part`: the body is whole and the part's notes are left out.
    private func assertBookIsReadAndDamageReported(
        _ part: Data?, named name: String, reason: String? = nil,
        endnotes: Bool = false, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let document = Data(docxDocumentXML(body(footnotes: endnotes ? [] : [1], endnotes: endnotes ? [1] : [])).utf8)
        var parts: [String: Data] = [DOCXParser.Part.document: document]
        if let part { parts[name] = part }
        let docx = try packageWith(parts)
        var diagnostics: [DOCXParserError] = []
        let result = try DOCXParser.extractMarkdown(from: docx, includesPages: false) { diagnostics.append($0) }
        XCTAssertEqual(result, "Main text goes on", file: file, line: line)
        guard case let .malformedXML(damaged, why)? = diagnostics.first, diagnostics.count == 1 else {
            return XCTFail("Expected one report of damage, got \(diagnostics)", file: file, line: line)
        }
        XCTAssertEqual(damaged, name, file: file, line: line)
        if let reason { XCTAssertEqual(why, reason, file: file, line: line) }
    }

    /// A package of the given parts, by path.
    private func packageWith(_ parts: [String: Data]) throws -> URL {
        let zip = try makeTemporaryZip(prefix: "TextMouthDOCXNotes", entries: parts)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextMouthDOCXNotes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let docx = directory.appendingPathComponent("Small Document.docx")
        try FileManager.default.moveItem(at: zip, to: docx)
        return docx
    }

    /// A notes part larger than a part may be loses its notes and is reported
    /// by name; the book is read. The same for the endnotes.
    func testANotesPartPastTheLimitIsReportedAndTheBookIsRead() throws {
        let limit: Int64 = 1_000
        let big = footnotesPart(docxNote("footnote", id: 1, text: String(repeating: "word ", count: 400)))
        let reason = ArchiveEntryOverflow.pastLimit(path: DOCXParser.Part.footnotes, limit: limit).reason
        try ArchiveEntryLimits.$current.withValue(ArchiveEntryLimits(audio: limit, text: limit)) {
            try assertBookIsReadAndDamageReported(Data(big.utf8), named: DOCXParser.Part.footnotes, reason: reason)
            let bigEndnotes = docxNotesXML(root: "endnotes", docxNote("endnote", id: 1, text: String(repeating: "word ", count: 400)))
            try assertBookIsReadAndDamageReported(
                Data(bigEndnotes.utf8), named: DOCXParser.Part.endnotes,
                reason: ArchiveEntryOverflow.pastLimit(path: DOCXParser.Part.endnotes, limit: limit).reason, endnotes: true
            )
        }
    }

    /// A notes part that is empty, blank, cut off before any note's words, or
    /// not XML loses its notes and is reported; the book is read.
    func testADamagedNotesPartIsReportedAndTheBookIsRead() throws {
        let name = DOCXParser.Part.footnotes
        try assertBookIsReadAndDamageReported(Data(), named: name, reason: "the file is empty")
        try assertBookIsReadAndDamageReported(Data("  \n\t ".utf8), named: name, reason: "the file is empty")
        try assertBookIsReadAndDamageReported(Data("<?xml version=\"1.0\"?><w:footnotes xmlns:w=\"urn:w\"><w:footnote".utf8), named: name)
        let separatorsOnly = footnotesPart("")
        let cut = try XCTUnwrap(separatorsOnly.range(of: "<w:separator/>"))
        try assertBookIsReadAndDamageReported(Data(separatorsOnly[..<cut.lowerBound].utf8), named: name)
    }

    /// A notes part that breaks off after some of its text keeps that text and
    /// reports the damage, as the text part does.
    func testANotesPartCutOffAfterSomeTextKeepsIt() throws {
        let intact = footnotesPart(docxNote("footnote", id: 1, text: "First note") + docxNote("footnote", id: 2, text: "Second note"))
        let cutAt = try XCTUnwrap(intact.range(of: "Second note"))
        let broken = String(intact[..<cutAt.lowerBound]) + "Second"
        var diagnostics: [DOCXParserError] = []
        let docx = try makeDOCXPackage(
            document: docxDocumentXML(body(footnotes: [1, 2])), footnotes: broken
        )
        let result = try DOCXParser.extractMarkdown(from: docx, includesPages: false) { diagnostics.append($0) }
        XCTAssertTrue(result.contains("First note"), result)
        XCTAssertEqual(diagnostics.count, 1)
    }
}
