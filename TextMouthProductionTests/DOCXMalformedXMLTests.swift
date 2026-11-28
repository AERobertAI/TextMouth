import XCTest
import ZIPFoundation
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
    private func makeDOCX(
        replacing changes: [String: Data] = [:],
        removing removed: Set<String> = [],
        compressionMethod: CompressionMethod = .none
    ) throws -> URL {
        var parts = Self.intactParts.mapValues { Data($0.utf8) }.merging(changes) { _, change in change }
        for path in removed {
            parts[path] = nil
        }
        let zip = try makeTemporaryZip(prefix: "TextMouthDOCXTest", entries: parts, compressionMethod: compressionMethod)
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

    // MARK: - A Tag With Too Many Attributes

    /// The intact package with the first `opening` of `part` replaced by
    /// `hostile`, in which "MANY" stands for 200,000 attributes (the parser
    /// takes time that grows with the square of them: 11 to 17 s).
    private func makeDOCX(replacing part: String, opening: String, with hostile: String) throws -> URL {
        let text = try XCTUnwrap(Self.intactParts[part], "No fixture part at \(part)")
        let range = try XCTUnwrap(text.range(of: opening), "\(part) has no \(opening)")
        let many = (0..<200_000).map { "a\($0)=\"\"" }.joined(separator: " ")
        let replaced = text.replacingCharacters(in: range, with: hostile.replacingOccurrences(of: "MANY", with: many))
        return try makeDOCX(replacing: [part: Data(replaced.utf8)])
    }

    /// A tag of more than 1,024 attributes (`XMLInputGuard.mostAttributesInATag`,
    /// 27 times the most in any of 3.98 million real start tags) in any part
    /// TextMouth reads is refused as damage, naming the part, in a few
    /// milliseconds: the parser took 11 to 17 seconds over 200,000. A bound of
    /// five seconds is far above the refusal and far below the parser. The
    /// core properties never fail an import: they are logged, and the file's
    /// name is used.
    func testATagWithTooManyAttributesIsRefusedAsDamageNamingThePart() throws {
        let cases: [(part: String, opening: String, hostile: String)] = [
            (DOCXParser.Part.document, "<w:p>", "<w:p MANY>"),
            (DOCXParser.Part.styles, "<w:style w:type", "<w:style MANY w:type"),
            (DOCXParser.Part.numbering, "<w:num w:numId", "<w:num MANY w:numId"),
            (DOCXParser.Part.documentRelationships, "<Relationship Id", "<Relationship MANY Id"),
            (DOCXParser.Part.coreProperties, "<dc:title>", "<dc:title MANY>"),
        ]
        for testCase in cases {
            let docx = try makeDOCX(replacing: testCase.part, opening: testCase.opening, with: testCase.hostile)
            let clock = ContinuousClock()
            let start = clock.now
            if testCase.part == DOCXParser.Part.coreProperties {
                // Only `readMetadata` opens the core properties.
                var reported: [DOCXParserError] = []
                let metadata = try DOCXParser.readMetadata(from: docx) { reported.append($0) }
                XCTAssertNil(metadata)
                guard case .malformedXML(let file, let reason)? = reported.first, reported.count == 1 else {
                    XCTFail("Expected one report for the core properties, got \(reported)")
                    continue
                }
                XCTAssertEqual(file, testCase.part)
                XCTAssertEqual(reason, XMLInputGuard.tooManyAttributesProblem)
            } else {
                let reason = malformedXMLReason(naming: testCase.part) { try DOCXParser.extractMarkdown(from: docx) }
                XCTAssertEqual(reason, XMLInputGuard.tooManyAttributesProblem, testCase.part)
            }
            XCTAssertLessThan(clock.now - start, .seconds(5), "\(testCase.part) took too long")
        }
    }

    /// The error `DOCXParser.extractMarkdown(from:)` throws for `docx`: a part
    /// that is not damaged, but that TextMouth will not read, with the part and
    /// the problem, and the sentence a person hears.
    private func unsafePart(
        _ docx: URL, file: StaticString = #filePath, line: UInt = #line
    ) -> (part: String, problem: XMLInputGuard.Problem, sentence: String)? {
        do {
            _ = try DOCXParser.extractMarkdown(from: docx)
            XCTFail("The document was read", file: file, line: line)
        } catch let DOCXParserError.unsafeXML(part, problem) {
            return (part, problem, DOCXParserError.unsafeXML(file: part, problem: problem).localizedDescription)
        } catch {
            XCTFail("Another error: \(error)", file: file, line: line)
        }
        return nil
    }

    /// A part with a document type that has definitions of its own, or in an
    /// encoding the guard cannot see through (UTF-7 here, and its alias
    /// CSISO2022JP's kin, with a newline around the `=`), is refused as not
    /// damaged, naming the part, in the sentences of `XMLInputGuard`: a
    /// declaration skipped to its first `>` hid a hostile tag, which took
    /// 21.9 s to parse. The sentences say what the matter is and what to do.
    func testAPartWithOwnDefinitionsOrAStatefulEncodingIsRefusedInItsOwnSentence() throws {
        let intact = try XCTUnwrap(Self.intactParts[DOCXParser.Part.document])
        let range = try XCTUnwrap(intact.range(of: "<w:document"))
        let subset = intact.replacingCharacters(in: range, with: "<!DOCTYPE w:document [<!ENTITY e \"x>y<!--\">]><w:document")
        let docx = try makeDOCX(replacing: [DOCXParser.Part.document: Data(subset.utf8)])
        let refused = unsafePart(docx)
        XCTAssertEqual(refused?.part, DOCXParser.Part.document)
        XCTAssertEqual(refused?.problem, .ownDefinitions)
        XCTAssertEqual(
            refused?.sentence,
            "TextMouth can't safely read the file \u{201C}word/document.xml\u{201D} in this document, because it defines "
                + "entities of its own. Open the document in the program that made it, save it again, then import it again.")

        // The encoding, spelled plainly, as an alias, and with a newline round the equals sign.
        for (declared, spelling) in [
            ("UTF-7", "encoding=\"UTF-7\""), ("UNICODE-1-1-UTF-7", "encoding=\"UNICODE-1-1-UTF-7\""),
            ("CSISO2022JP", "encoding\n=\n'CSISO2022JP'"),
        ] {
            let changed = intact.replacingOccurrences(of: "encoding=\"UTF-8\"", with: spelling)
            XCTAssertNotEqual(changed, intact)
            let docxChanged = try makeDOCX(replacing: [DOCXParser.Part.document: Data(changed.utf8)])
            let refusedEncoding = unsafePart(docxChanged)
            XCTAssertEqual(refusedEncoding?.problem, .encoding(declared), declared)
            XCTAssertEqual(
                refusedEncoding?.sentence,
                "TextMouth can't safely read the file \u{201C}word/document.xml\u{201D} in this document, because it is written "
                    + "in the \(declared) encoding. Save it as UTF-8, then import it again.")
        }

        // An external type, which a DTBook or NCX has, is no definition of its own.
        let external = intact.replacingCharacters(in: range, with: "<!DOCTYPE w:document PUBLIC \"-//X//EN\" \"http://example.org/x.dtd\"><w:document")
        let docxExternal = try makeDOCX(replacing: [DOCXParser.Part.document: Data(external.utf8)])
        XCTAssertNoThrow(try DOCXParser.extractMarkdown(from: docxExternal))
    }

    /// The refusal reads as the other damage does: it names the part, says
    /// what is wrong in words a listener can use, and says what to do.
    func testTheRefusalOfATagWithTooManyAttributesIsInTheSentenceOfAnyDamagedPart() {
        let error = DOCXParserError.malformedXML(file: "word/document.xml", reason: XMLInputGuard.tooManyAttributesProblem)
        XCTAssertEqual(
            error.errorDescription,
            "The file \u{201C}word/document.xml\u{201D} in this document is damaged or incomplete: "
                + "it has a tag with too many attributes for TextMouth to read safely. "
                + "Get a fresh copy of the document, then import it again.")
    }

    /// A document text whose group holds a picture in one attribute
    /// (`o:gfxdata`, a base64 ZIP of the shape, as Word writes it for a photo
    /// in a group): a real SAMHSA postcard has one of 267,106 characters in a
    /// tag of 267,352 bytes. The attribute is no hazard, whatever its length,
    /// so the words before and after it are read.
    func testALongPictureAttributeIsNoHazardAndTheWordsAroundItAreRead() throws {
        let picture = String(repeating: "UEsDBBQAAAAIAA==", count: 20_000)
        XCTAssertGreaterThan(picture.utf8.count, 300_000)
        let body = docxParagraph(docxRun("Before the picture."))
            + "<w:p><w:r><w:pict><v:group xmlns:o=\"urn:schemas-microsoft-com:office:office\" o:gfxdata=\"\(picture)\"/></w:pict></w:r></w:p>"
            + docxParagraph(docxRun("After the picture."))
        let docx = try makeDOCXPackage(document: docxDocumentXML(body))
        let markdown = try DOCXParser.extractMarkdown(from: docx, includesPages: false)
        let heard = try MarkdownDocParser.parseChapter(markdown: markdown).text
        XCTAssertEqual(heard.split(whereSeparator: \.isWhitespace).joined(separator: " "), "Before the picture. After the picture.")
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

    // MARK: - Missing Parts

    /// A package without its text part has nothing to read (audit U20). The
    /// conversion and the direct reader name the missing part, and an import
    /// fails while reading the text with that sentence, leaving no package
    /// or row and the original as it was.
    @MainActor
    func testPackageWithoutItsTextPartNamesTheMissingPart() throws {
        let docx = try makeDOCX(removing: [DOCXParser.Part.document])
        let sentence = "The DOCX file is missing required entry: word/document.xml"

        XCTAssertThrowsError(try DOCXParser.extractMarkdown(from: docx)) { error in
            guard case .missingEntry(let path)? = error as? DOCXParserError else {
                return XCTFail("Expected a missing-entry error, got \(error)")
            }
            XCTAssertEqual(path, DOCXParser.Part.document)
            XCTAssertEqual(error.localizedDescription, sentence)
        }
        XCTAssertThrowsError(try DOCXParser.parse(url: docx)) { error in
            XCTAssertEqual(error.localizedDescription, sentence)
        }
        try assertImportRefused(docx, saying: sentence)
    }

    /// Relationships naming a part the package does not hold are no damage
    /// today (audit U20): the styles part they name reads as absent, so the
    /// headings read as plain paragraphs while every word, list number, and
    /// link target stays, nothing is reported, and an import adds the book
    /// with that text.
    func testRelationshipsNamingAMissingPartReadAsThoughItWereAbsent() throws {
        XCTAssertTrue(Self.relationshipsXML.contains(#"Target="styles.xml""#), "the relationships must name the styles part")
        let docx = try makeDOCX(removing: [DOCXParser.Part.styles])

        let markdown = try DOCXParser.extractMarkdown(from: docx, includesPages: false) {
            XCTFail("Unexpected damage report: \($0)")
        }

        XCTAssertEqual(try Self.spokenText(of: markdown), Self.spokenDocument)
        XCTAssertFalse(markdown.contains("#"), "Without its styles part no paragraph is a heading: \(markdown)")
        XCTAssertTrue(markdown.contains("\n1. Cut new cloth"), markdown)
        XCTAssertTrue(markdown.contains("[**paste chart**](https://example.org/paste-chart)"), markdown)

        let book = try FileImportService.importFile(from: docx)
        let package = book.tmbDirectory
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }
        let cached = try String(contentsOf: TextMouthPaths.contentMarkdownPath(in: package), encoding: .utf8)
        XCTAssertEqual(try Self.spokenText(of: cached), Self.spokenDocument)
    }

    // MARK: - ZIP Damage

    /// A part whose compressed data cannot be decoded is damage in the
    /// package like any other, said in the same words with the part named,
    /// not ZIPFoundation's own error, which is logged.
    func testAPartWhoseCompressedDataCannotBeDecodedIsNamedAsDamaged() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let docx = try makeDOCX(compressionMethod: .deflate)
        try damageData(of: DOCXParser.Part.document, in: docx)

        var thrown: Error?
        let lines = debugLogLines { do { _ = try DOCXParser.parse(url: docx) } catch { thrown = error } }

        XCTAssertEqual(
            thrown?.localizedDescription,
            "The file “word/document.xml” in this document is damaged or incomplete: "
                + "its compressed data could not be decoded. "
                + "Get a fresh copy of the document, then import it again.",
            "what a listener is told of ZIP damage"
        )
        let logged = lines.filter { $0.contains("DOCX_ZIP_ERROR: word/document.xml: ") }
        XCTAssertEqual(logged.count, 1, "ZIPFoundation's own error is logged once: \(lines)")
        XCTAssertFalse(
            (thrown?.localizedDescription ?? "").contains("ZIPFoundation"),
            "the raw error reached the listener: \(String(describing: thrown))"
        )
        guard case .malformedXML(let file, _)? = thrown as? DOCXParserError else {
            return XCTFail("Expected DOCXParserError.malformedXML, received \(String(describing: thrown))")
        }
        XCTAssertEqual(file, "word/document.xml")
    }

    /// The same damage in the styles part, which is read before the text,
    /// names that part.
    func testAStylesPartThatCannotBeDecodedIsNamedAsDamaged() throws {
        let docx = try makeDOCX(compressionMethod: .deflate)
        try damageData(of: DOCXParser.Part.styles, in: docx)

        malformedXMLReason(naming: DOCXParser.Part.styles) { try DOCXParser.parse(url: docx) }
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

    /// Core properties that name no title, or no author (an empty element, a
    /// self-closing one, one of only spaces and line breaks, or none), leave
    /// the document its file name and the unknown author, as a document with
    /// no core properties has, rather than an empty title and author.
    func testEmptyCorePropertiesFallBackLikeMissingOnes() throws {
        func core(title: String, creator: String) -> Data {
            Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
             xmlns:dc="http://purl.org/dc/elements/1.1/">\(title)\(creator)</cp:coreProperties>
            """.utf8)
        }
        let cases: [(name: String, part: Data?)] = [
            ("empty elements", core(title: "<dc:title></dc:title>", creator: "<dc:creator></dc:creator>")),
            ("self-closing elements", core(title: "<dc:title/>", creator: "<dc:creator/>")),
            ("spaces and line breaks", core(title: "<dc:title>  \n </dc:title>", creator: "<dc:creator> \t </dc:creator>")),
            ("no elements", core(title: "", creator: "")),
            ("no core properties at all", nil),
        ]
        for (name, part) in cases {
            let docx = try part.map { try makeDOCX(replacing: [DOCXParser.Part.coreProperties: $0]) }
                ?? makeDOCX(removing: [DOCXParser.Part.coreProperties])
            let content = try DOCXParser.parse(url: docx)
            XCTAssertEqual(content.title, Self.fileTitle, "title for \(name)")
            XCTAssertEqual(content.author, Book.unknownAuthor, "author for \(name)")
            XCTAssertEqual(content.chapters.map(\.text), [Self.spokenDocument], "text for \(name)")
        }
        // A title given with an empty author keeps the title, and the reverse.
        let titleOnly = try makeDOCX(replacing: [
            DOCXParser.Part.coreProperties: core(title: "<dc:title>Spine Notes</dc:title>", creator: "<dc:creator> </dc:creator>")
        ])
        XCTAssertEqual(try DOCXParser.parse(url: titleOnly).title, "Spine Notes")
        XCTAssertEqual(try DOCXParser.parse(url: titleOnly).author, Book.unknownAuthor)
        let authorOnly = try makeDOCX(replacing: [
            DOCXParser.Part.coreProperties: core(title: "<dc:title> </dc:title>", creator: "<dc:creator>Ilse Varga</dc:creator>")
        ])
        XCTAssertEqual(try DOCXParser.parse(url: authorOnly).title, Self.fileTitle)
        XCTAssertEqual(try DOCXParser.parse(url: authorOnly).author, "Ilse Varga")
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
