import XCTest
@testable import TextMouth

/// A damaged Word document must never turn silently into a shorter or plainer
/// one (TODO T04). Structure parts (styles, list numbering, and the document's
/// relationships) that break off or are not well-formed throw an error naming
/// the part, while a part the package simply lacks is still no error. The
/// text part keeps the text read before any damage, closes what the damage
/// left open, and reports the damage beside that text; a text part damaged
/// before any text throws like a structure part. Damaged core properties
/// never fail an import: the document is read under its file name.
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

    /// A package whose intact part at `path` is cut off before its first `marker`.
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

    /// Convert `docx`, requiring exactly one incomplete-content diagnostic,
    /// and return the Markdown with the part and reason the diagnostic gives.
    private func convertIncomplete(
        _ docx: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (markdown: String, part: String, reason: String) {
        var diagnostics: [DOCXParserError] = []
        let markdown = try DOCXParser.extractMarkdown(from: docx, includesPages: false) { diagnostics.append($0) }
        guard diagnostics.count == 1, case let .malformedXML(part, reason)? = diagnostics.first else {
            XCTFail("Expected one malformed-XML diagnostic, got \(diagnostics)", file: file, line: line)
            return (markdown, "", "")
        }
        XCTAssertFalse(markdown.contains(reason), "The diagnostic must stay out of the text", file: file, line: line)
        return (markdown, part, reason)
    }

    /// The debug-log lines written while `body` runs.
    private func debugLogLines(writtenDuring body: () throws -> Void) rethrows -> [String] {
        let log = TextMouthPaths.debugLogFile
        TextMouthPaths.flushLogs()
        let before = (try? Data(contentsOf: log)) ?? Data()
        try body()
        TextMouthPaths.flushLogs()
        let after = (try? Data(contentsOf: log)) ?? Data()
        // A log rotated meanwhile starts a new file holding only new lines.
        let written = after.starts(with: before) ? after.dropFirst(before.count) : after
        return String(decoding: written, as: UTF8.self).components(separatedBy: "\n").filter { !$0.isEmpty }
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
        let markdown = try DOCXParser.extractMarkdown(from: try makeDOCX(), includesPages: false)

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

        let markdown = try DOCXParser.extractMarkdown(from: docx, includesPages: false)

        XCTAssertEqual(try Self.spokenText(of: markdown), Self.spokenDocument)
        XCTAssertFalse(markdown.contains("#"), "Without styles no paragraph is a heading: \(markdown)")
        XCTAssertTrue(markdown.contains("\n- Cut new cloth"), "Without numbering a list reads as bullets: \(markdown)")
        XCTAssertFalse(markdown.contains("](https://"), "Without relationships a link has no target: \(markdown)")
    }

    // MARK: - Document Text

    /// Text cut off mid-paragraph keeps every paragraph read before the cut,
    /// with its heading and list numbering, and the words of the list item in
    /// progress. The damage is reported beside the text, never inside it,
    /// naming the part and where it breaks off; the direct reader reads the
    /// same words.
    func testTruncatedDocumentKeepsTheTextReadBeforeTheCut() throws {
        let damaged = Self.truncated(Self.documentXML, before: "wider than the spine.")
        let docx = try makeDOCX(replacing: [DOCXParser.Part.document: Data(damaged.utf8)])
        let recovered = """
        Mending Cloth Spines

        Lift the worn cloth with a thin bone folder before it tears further.

        Cut new cloth two centimetres
        """

        let conversion = try convertIncomplete(docx)

        XCTAssertEqual(try Self.spokenText(of: conversion.markdown), recovered)
        XCTAssertTrue(conversion.markdown.hasPrefix("# Mending Cloth Spines\n"), conversion.markdown)
        XCTAssertTrue(conversion.markdown.hasSuffix("\n1. Cut new cloth two centimetres"), conversion.markdown)
        XCTAssertEqual(conversion.part, "word/document.xml")
        XCTAssertTrue(conversion.reason.hasPrefix("its markup breaks off early"), conversion.reason)
        XCTAssertTrue(conversion.reason.contains(Self.endPosition(of: damaged)), conversion.reason)
        XCTAssertEqual(try DOCXParser.parse(url: docx).chapters.map(\.text), [recovered])
    }

    /// A cut inside a bold link closes the run, the link, and the paragraph
    /// as their end tags would have. The link keeps its target, and the space
    /// before the cut does not keep the bold from closing, so no asterisk or
    /// bracket is read aloud.
    func testTruncatedDocumentClosesTheBoldLinkLeftOpen() throws {
        let docx = try makeDOCX(truncating: DOCXParser.Part.document, before: "chart</w:t>")

        let conversion = try convertIncomplete(docx)

        XCTAssertTrue(
            conversion.markdown.hasSuffix("\n\nCheck the [**paste**](https://example.org/paste-chart)"),
            conversion.markdown
        )
        let spoken = try Self.spokenText(of: conversion.markdown)
        XCTAssertTrue(spoken.hasSuffix("\n\nCheck the paste"), spoken)
        XCTAssertFalse(spoken.contains("*") || spoken.contains("["), spoken)
    }

    /// A cut inside a table cell finishes the cell, its row, and the table,
    /// so the rows read before the cut stay one table.
    func testTruncatedDocumentClosesTheTableLeftOpen() throws {
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>
        <w:p><w:r><w:t>Paste strengths by volume:</w:t></w:r></w:p>
        <w:tbl>
        <w:tr><w:tc><w:p><w:r><w:t>Paste</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Water</w:t></w:r></w:p></w:tc></w:tr>
        <w:tr><w:tc><w:p><w:r><w:t>Wheat starch</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Six parts</w:t></w:r></w:p></w:tc></w:tr>
        </w:tbl>
        </w:body>
        </w:document>
        """
        let docx = try makeDOCX(replacing: [
            DOCXParser.Part.document: Data(Self.truncated(document, before: "parts</w:t>").utf8)
        ])

        let conversion = try convertIncomplete(docx)

        XCTAssertEqual(conversion.markdown, """
        Paste strengths by volume\\:

        | Paste | Water |
        | --- | --- |
        | Wheat starch | Six |
        """)
    }

    /// Damage before any text leaves nothing worth reading, so the document
    /// fails like a damaged structure part and reports no partial content,
    /// whether the part is empty or breaks off before its first words.
    func testDocumentDamagedBeforeAnyTextThrows() throws {
        let damagedParts = [
            Data(),
            Data(Self.truncated(Self.documentXML, before: "<w:body>").utf8),
            Data(Self.truncated(Self.documentXML, before: "<w:t>Mending").utf8)
        ]
        for damaged in damagedParts {
            let docx = try makeDOCX(replacing: [DOCXParser.Part.document: damaged])

            malformedXMLReason(naming: "word/document.xml") {
                try DOCXParser.extractMarkdown(from: docx) { XCTFail("Unexpected partial-content report: \($0)") }
            }
            malformedXMLReason(naming: "word/document.xml") { try DOCXParser.parse(url: docx) }
        }
    }

    /// Markup after the document's root element comes after all of its text,
    /// so every word is kept, exactly as from the intact part, and the damage
    /// is still reported.
    func testContentAfterTheDocumentRootKeepsAllTextAndReportsTheDamage() throws {
        let intact = try DOCXParser.extractMarkdown(from: try makeDOCX(), includesPages: false) {
            XCTFail("Unexpected partial-content report: \($0)")
        }
        let docx = try makeDOCX(replacing: [
            DOCXParser.Part.document: Data((Self.documentXML + "\n<w:p/>").utf8)
        ])

        let conversion = try convertIncomplete(docx)

        XCTAssertEqual(conversion.markdown, intact)
        XCTAssertTrue(
            conversion.reason.hasPrefix("its markup breaks off early or has extra content after the end"),
            conversion.reason
        )
    }

    /// A byte that is not UTF-8 partway through the text keeps every
    /// paragraph before it and reports an encoding problem.
    func testMisencodedDocumentKeepsTheTextBeforeTheBadByte() throws {
        let docx = try makeDOCX(replacing: [
            DOCXParser.Part.document: Self.misencoded(Self.documentXML, before: "Drying and Pressing")
        ])

        let conversion = try convertIncomplete(docx)

        XCTAssertEqual(
            try Self.spokenText(of: conversion.markdown),
            Self.truncated(Self.spokenDocument, before: "\n\nDrying and Pressing")
        )
        XCTAssertTrue(
            conversion.reason.hasPrefix("it contains characters that are not valid in its declared text encoding"),
            conversion.reason
        )
    }

    /// With no reporter supplied, as when the Markdown cache is built on
    /// import, the damage is recorded in the debug log.
    func testIncompleteContentIsWrittenToTheDebugLogByDefault() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let docx = try makeDOCX(truncating: DOCXParser.Part.document, before: "wider than the spine.")

        let lines = try debugLogLines { _ = try DOCXParser.extractMarkdown(from: docx) }

        let entries = lines.filter { $0.contains("DOCX_INCOMPLETE_CONTENT:") }
        XCTAssertEqual(entries.count, 1, "\(lines)")
        XCTAssertTrue(entries.first?.contains(
            "DOCX_INCOMPLETE_CONTENT: The file “word/document.xml” in this document is damaged or incomplete: "
                + "its markup breaks off early"
        ) == true, "\(entries)")
    }

    /// Importing a document whose text breaks off still adds the book, with
    /// the recovered text as its cached reading text.
    func testImportKeepsTheTextOfADocumentThatBreaksOff() throws {
        let docx = try makeDOCX(truncating: DOCXParser.Part.document, before: "wider than the spine.")

        let book = try FileImportService.importFile(from: docx)
        let package = book.tmbDirectory
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }

        let cached = try String(contentsOf: TextMouthPaths.contentMarkdownPath(in: package), encoding: .utf8)
        XCTAssertEqual(cached, try DOCXParser.extractMarkdown(from: docx) { _ in })
        XCTAssertTrue(cached.hasSuffix("\n1. Cut new cloth two centimetres"), cached)
        XCTAssertEqual(book.title, "Mending Cloth Spines")
    }

    // MARK: - Core Properties

    /// Intact core properties give the document its title and author.
    func testIntactCorePropertiesNameTheDocument() throws {
        let docx = try makeDOCX()

        let metadata = try XCTUnwrap(DOCXParser.readMetadata(from: docx) {
            XCTFail("Unexpected damage report: \($0)")
        })

        XCTAssertEqual(metadata.title, "Mending Cloth Spines")
        XCTAssertEqual(metadata.author, "Radka Oyelaran")
        XCTAssertEqual(try DOCXParser.parse(url: docx).title, "Mending Cloth Spines")
    }

    /// Damaged core properties never fail the document. It is read under its
    /// file name with an unknown author, even when a title was read before
    /// the damage, all of its text still reads, and the damage is reported.
    func testDamagedCorePropertiesFallBackToTheFileName() throws {
        let damagedParts = [
            "truncated": Data(Self.truncated(Self.coreXML, before: "<dc:creator>").utf8),
            "misencoded": Self.misencoded(Self.coreXML, before: "Radka"),
            "empty": Data()
        ]
        for (damage, part) in damagedParts {
            let docx = try makeDOCX(replacing: [DOCXParser.Part.coreProperties: part])
            var reports: [DOCXParserError] = []

            XCTAssertNil(try DOCXParser.readMetadata(from: docx) { reports.append($0) }, damage)

            guard reports.count == 1, case let .malformedXML(file, _)? = reports.first else {
                XCTFail("Expected one malformed-XML report for the \(damage) part, got \(reports)")
                continue
            }
            XCTAssertEqual(file, "docProps/core.xml", damage)
            let content = try DOCXParser.parse(url: docx)
            XCTAssertEqual(content.title, Self.fileTitle, damage)
            XCTAssertEqual(content.author, "Unknown", damage)
            XCTAssertEqual(content.chapters.map(\.text), [Self.spokenDocument], damage)
        }
    }

    /// Importing a document with damaged core properties adds the book under
    /// its file name, with all of its text.
    func testImportWithDamagedCorePropertiesUsesTheFileName() throws {
        let docx = try makeDOCX(truncating: DOCXParser.Part.coreProperties, before: "<dc:creator>")

        let book = try FileImportService.importFile(from: docx)
        let package = book.tmbDirectory
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }

        XCTAssertEqual(book.title, "Spine Repair Notes")
        XCTAssertEqual(book.author, "Unknown")
        let cached = try String(contentsOf: TextMouthPaths.contentMarkdownPath(in: package), encoding: .utf8)
        XCTAssertEqual(try Self.spokenText(of: cached), Self.spokenDocument)
    }

    /// With no reporter supplied, as on import, damaged core properties are
    /// recorded in the debug log.
    func testDamagedCorePropertiesAreWrittenToTheDebugLogByDefault() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let docx = try makeDOCX(truncating: DOCXParser.Part.coreProperties, before: "<dc:creator>")

        var metadata: DOCXMetadata?
        let lines = try debugLogLines { metadata = try DOCXParser.readMetadata(from: docx) }

        XCTAssertNil(metadata)
        let entries = lines.filter { $0.contains("DOCX_DAMAGED_METADATA:") }
        XCTAssertEqual(entries.count, 1, "\(lines)")
        XCTAssertTrue(entries.first?.contains(
            "DOCX_DAMAGED_METADATA: The file “docProps/core.xml” in this document is damaged or incomplete: "
        ) == true, "\(entries)")
    }

    // MARK: - Helpers

    /// The words a reader hears for `markdown`: its plain text as the
    /// Markdown parser extracts it for speech and display.
    private static func spokenText(of markdown: String) throws -> String {
        try MarkdownDocParser.parse(markdown: markdown).chapters[0].text
    }
}
