import XCTest
@testable import TextMouth

/// A damaged Word document must never turn silently into a shorter or plainer
/// one (TODO T04). Structure parts (styles, list numbering, and the document's
/// relationships) that break off or are not well-formed throw an error naming
/// the part, while a part the package simply lacks is still no error.
final class DOCXMalformedXMLTests: XCTestCase {

    // MARK: - Fixtures

    /// The document's text: two headings, whose levels come from the styles
    /// part; a numbered list, whose numbering comes from the numbering part;
    /// and a bold link, whose target comes from the relationships part.
    private static let documentXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
     xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
    <w:body>
    <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Mending Cloth Spines</w:t></w:r></w:p>
    <w:p><w:r><w:t>Lift the worn cloth with a thin bone folder before it tears further.</w:t></w:r></w:p>
    <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
    <w:r><w:t>Cut new cloth two centimetres wider than the spine.</w:t></w:r></w:p>
    <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
    <w:r><w:t>Paste the hollow tube, never the cloth itself.</w:t></w:r></w:p>
    <w:p>
    <w:r><w:t xml:space="preserve">Check the </w:t></w:r>
    <w:hyperlink r:id="rId2"><w:r><w:rPr><w:b/></w:rPr><w:t>paste chart</w:t></w:r></w:hyperlink>
    <w:r><w:t xml:space="preserve"> before choosing an adhesive.</w:t></w:r>
    </w:p>
    <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Drying and Pressing</w:t></w:r></w:p>
    <w:p><w:r><w:t>Press the volume between boards overnight, spine free of the press.</w:t></w:r></w:p>
    </w:body>
    </w:document>
    """

    /// The words a reader hears for the whole document.
    private static let spokenDocument = """
    Mending Cloth Spines

    Lift the worn cloth with a thin bone folder before it tears further.

    Cut new cloth two centimetres wider than the spine.

    Paste the hollow tube, never the cloth itself.

    Check the paste chart before choosing an adhesive.

    Drying and Pressing

    Press the volume between boards overnight, spine free of the press.
    """

    /// Paragraph styles: body text and two heading levels.
    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:style w:type="paragraph" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/>
    <w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/>
    <w:pPr><w:outlineLvl w:val="1"/></w:pPr></w:style>
    </w:styles>
    """

    /// One decimal list definition and the list instance that uses it.
    private static let numberingXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>
    <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
    </w:numbering>
    """

    /// The document's relationships: its styles part and its link target.
    private static let relationshipsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Target="styles.xml"
     Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"/>
    <Relationship Id="rId2" Target="https://example.org/paste-chart" TargetMode="External"
     Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"/>
    </Relationships>
    """

    /// Core properties naming the document's title and author.
    private static let coreXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Mending Cloth Spines</dc:title>
    <dc:creator>Radka Oyelaran</dc:creator>
    </cp:coreProperties>
    """

    /// Every part TextMouth reads, intact, by its path in the package.
    private static let intactParts = [
        DOCXParser.Part.document: documentXML,
        DOCXParser.Part.styles: stylesXML,
        DOCXParser.Part.numbering: numberingXML,
        DOCXParser.Part.documentRelationships: relationshipsXML,
        DOCXParser.Part.coreProperties: coreXML
    ]

    /// The package's file name without its extension, which differs from
    /// the title in its core properties.
    private static let fileTitle = "Spine Repair Notes"

    /// Write a package holding every intact part to "Spine Repair Notes.docx"
    /// in a new temporary directory, removed after the test. Each entry of
    /// `changes` replaces the part at that path with the given bytes, and
    /// each path in `removed` leaves that part out.
    private func makeDOCX(replacing changes: [String: Data] = [:], removing removed: Set<String> = []) throws -> URL {
        var parts = Self.intactParts.mapValues { Data($0.utf8) }.merging(changes) { _, change in change }
        for path in removed {
            parts[path] = nil
        }
        let zip = try makeTemporaryZip(prefix: "TextMouthDOCXTest", entries: parts)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextMouthDOCXTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let docx = directory.appendingPathComponent("\(Self.fileTitle).docx")
        try FileManager.default.moveItem(at: zip, to: docx)
        return docx
    }

    /// A package whose part at `path` is `text` cut off before `marker`.
    private func makeDOCX(truncating path: String, before marker: String) throws -> URL {
        let text = try XCTUnwrap(Self.intactParts[path], "No fixture part at \(path)")
        return try makeDOCX(replacing: [path: Data(Self.truncated(text, before: marker).utf8)])
    }

    /// Run `body`, which must throw `DOCXParserError.malformedXML` naming
    /// `expectedFile`, and return the error's reason ("" after a failure).
    @discardableResult
    private func malformedXMLReason<T>(
        naming expectedFile: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> T
    ) -> String {
        do {
            _ = try body()
            XCTFail("Expected a malformed-XML error naming \(expectedFile)", file: file, line: line)
        } catch let DOCXParserError.malformedXML(damagedFile, reason) {
            XCTAssertEqual(damagedFile, expectedFile, "The error must name the damaged part", file: file, line: line)
            return reason
        } catch {
            XCTFail("Expected a malformed-XML error naming \(expectedFile), got \(error)", file: file, line: line)
        }
        return ""
    }

    /// The position a reason gives for a file that breaks off at the end of
    /// `text`: "(line N, column " with N the line on which `text` ends.
    /// The parser reports the point just past the last markup it read, so
    /// the tests cut mid-line, where that point is on the text's last line.
    private static func endPosition(of text: String) -> String {
        "(line \(text.filter { $0 == "\n" }.count + 1), column "
    }

    // MARK: - Error Description

    /// The message a reader hears names the part and says what to do next.
    func testMalformedXMLDescriptionNamesThePartAndTheRemedy() {
        let error = DOCXParserError.malformedXML(file: "word/styles.xml", reason: "the file is empty")

        XCTAssertEqual(
            error.errorDescription,
            "The file “word/styles.xml” in this document is damaged or incomplete: the file is empty. "
                + "Get a fresh copy of the document, then import it again."
        )
    }

    // MARK: - Structure Parts

    /// The intact package reads in full and uses every structure part: its
    /// heading levels, list numbers, and link target. The damage tests below
    /// each break one of these parts.
    func testIntactPackageUsesEveryStructurePart() throws {
        let markdown = try DOCXParser.extractMarkdown(from: try makeDOCX())

        XCTAssertEqual(try Self.spokenText(of: markdown), Self.spokenDocument)
        XCTAssertTrue(markdown.hasPrefix("# Mending Cloth Spines\n"), markdown)
        XCTAssertTrue(markdown.contains("\n## Drying and Pressing\n"), markdown)
        XCTAssertTrue(markdown.contains("\n1. Cut new cloth"), markdown)
        XCTAssertTrue(markdown.contains("\n2. Paste the hollow tube"), markdown)
        XCTAssertTrue(markdown.contains("[**paste chart**](https://example.org/paste-chart)"), markdown)
    }

    /// Styles cut off inside the second heading style used to parse as a
    /// shorter style list, so "Drying and Pressing" silently read as a plain
    /// paragraph. Conversion, the direct reader, and style reading all refuse
    /// the part instead, saying where it breaks off.
    func testTruncatedStylesThrowErrorNamingThePart() throws {
        let marker = "<w:name w:val=\"heading 2\"/>"
        let docx = try makeDOCX(truncating: DOCXParser.Part.styles, before: marker)

        let reason = malformedXMLReason(naming: "word/styles.xml") { try DOCXParser.extractMarkdown(from: docx) }
        XCTAssertTrue(reason.hasPrefix("its markup breaks off early"), reason)
        XCTAssertTrue(reason.contains(Self.endPosition(of: Self.truncated(Self.stylesXML, before: marker))), reason)

        malformedXMLReason(naming: "word/styles.xml") { try DOCXParser.parse(url: docx) }
        malformedXMLReason(naming: "word/styles.xml") { try DOCXParser.readStyles(from: docx) }
    }

    /// Numbering cut off inside its list instance used to lose the link from
    /// the list to its definition, so the numbered steps read as bullets.
    func testTruncatedNumberingThrowsErrorNamingThePart() throws {
        let marker = "<w:abstractNumId w:val=\"0\"/></w:num>"
        let docx = try makeDOCX(truncating: DOCXParser.Part.numbering, before: marker)

        let reason = malformedXMLReason(naming: "word/numbering.xml") { try DOCXParser.extractMarkdown(from: docx) }
        XCTAssertTrue(reason.contains(Self.endPosition(of: Self.truncated(Self.numberingXML, before: marker))), reason)
    }

    /// Relationships cut off inside the link's relationship, before its
    /// target, used to leave the link as bare text, its destination gone.
    func testTruncatedRelationshipsThrowErrorNamingThePart() throws {
        let marker = "Target=\"https://example.org/paste-chart\""
        let docx = try makeDOCX(truncating: DOCXParser.Part.documentRelationships, before: marker)

        let reason = malformedXMLReason(naming: "word/_rels/document.xml.rels") {
            try DOCXParser.extractMarkdown(from: docx)
        }
        XCTAssertTrue(reason.contains(Self.endPosition(of: Self.truncated(Self.relationshipsXML, before: marker))), reason)
    }

    /// A byte that is not UTF-8 in a part declared as UTF-8 is described as
    /// an encoding problem rather than read around.
    func testMisencodedStylesAreReportedAsAnEncodingProblem() throws {
        let docx = try makeDOCX(replacing: [
            DOCXParser.Part.styles: Self.misencoded(Self.stylesXML, before: "heading 2")
        ])

        let reason = malformedXMLReason(naming: "word/styles.xml") { try DOCXParser.extractMarkdown(from: docx) }
        XCTAssertTrue(reason.hasPrefix("it contains characters that are not valid in its declared text encoding"), reason)
    }

    /// Markup after the root element means the part was not written whole,
    /// so it is reported like a part that breaks off.
    func testContentAfterTheNumberingRootIsReported() throws {
        let docx = try makeDOCX(replacing: [
            DOCXParser.Part.numbering: Data((Self.numberingXML + "\n<w:num w:numId=\"2\"/>").utf8)
        ])

        let reason = malformedXMLReason(naming: "word/numbering.xml") { try DOCXParser.extractMarkdown(from: docx) }
        XCTAssertTrue(reason.hasPrefix("its markup breaks off early or has extra content after the end"), reason)
    }

    /// A styles part that is present but empty is damage, not absence.
    func testEmptyStylesPartIsReportedAsEmpty() throws {
        let docx = try makeDOCX(replacing: [DOCXParser.Part.styles: Data()])

        let reason = malformedXMLReason(naming: "word/styles.xml") { try DOCXParser.extractMarkdown(from: docx) }
        XCTAssertEqual(reason, "the file is empty")
    }

    /// A package without styles, numbering, or relationships is not damaged:
    /// it simply has no heading styles, list definitions, or link targets,
    /// and every word still reads.
    func testMissingStructurePartsAreNotDamage() throws {
        let docx = try makeDOCX(removing: [
            DOCXParser.Part.styles, DOCXParser.Part.numbering, DOCXParser.Part.documentRelationships
        ])

        let markdown = try DOCXParser.extractMarkdown(from: docx)

        XCTAssertEqual(try Self.spokenText(of: markdown), Self.spokenDocument)
        XCTAssertFalse(markdown.contains("#"), "Without styles no paragraph is a heading: \(markdown)")
        XCTAssertTrue(markdown.contains("\n- Cut new cloth"), "Without numbering a list reads as bullets: \(markdown)")
        XCTAssertFalse(markdown.contains("](https://"), "Without relationships a link has no target: \(markdown)")
    }

    // MARK: - Helpers

    /// The words a reader hears for `markdown`: its plain text as the
    /// Markdown parser extracts it for speech and display.
    private static func spokenText(of markdown: String) throws -> String {
        try MarkdownDocParser.parse(markdown: markdown).chapters[0].text
    }
}
