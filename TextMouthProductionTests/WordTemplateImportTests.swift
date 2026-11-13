import XCTest
import ZIPFoundation
@testable import TextMouth

/// Word templates (.dotx), macro-enabled documents (.docm), and
/// macro-enabled templates (.dotm) are the same Office Open XML package as
/// a .docx, only the main part's content type differs (FMT01). They share
/// the `.docx` case and its reader, which opens only the XML parts it needs,
/// so a macro project is never opened. Most tests import a copy of a sample
/// from `TestData/format-samples` (untrusted input) in a folder of its own;
/// the heading and macro tests make their copies from a real .docx.
@MainActor
final class WordTemplateImportTests: XCTestCase {
    /// The three extensions this task adds to the Word format.
    private static let templateExtensions = ["dotx", "docm", "dotm"]

    /// The Office Open XML types macOS names them with.
    private static let templateTypeIdentifiers = [
        "org.openxmlformats.wordprocessingml.template",
        "org.openxmlformats.wordprocessingml.document.macroenabled",
        "org.openxmlformats.wordprocessingml.template.macroenabled"
    ]

    /// One of the three forms: its extension and the content type its main
    /// part (word/document.xml) declares in [Content_Types].xml.
    private struct Form {
        let ext: String
        let mainContentType: String
    }

    /// The .dotx, .docm, and .dotm forms, with the content types Office
    /// gives their main parts.
    private static let forms = [
        Form(ext: "dotx", mainContentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.template.main+xml"),
        Form(ext: "docm", mainContentType: "application/vnd.ms-word.document.macroEnabled.main+xml"),
        Form(ext: "dotm", mainContentType: "application/vnd.ms-word.template.macroEnabledTemplate.main+xml")
    ]

    /// The content type a plain .docx's main part declares.
    private static let docxMainContentType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"

    // MARK: - Importing the samples

    /// Each synthetic sample imports as a Word document and opens with the
    /// text of the one document they were made from. They hold NO heading
    /// style: their titles are only bold, larger runs (direct formatting),
    /// which `DOCXParser` does not take for headings, so none is announced.
    /// That is all the empty heading list pins; the headings of each form
    /// are pinned by `testEachFormImportsWithExactlyTheHeadingsOfItsDocx`.
    func testSyntheticSamplesImportAsWordDocumentsWithTheirText() throws {
        for sample in ["dotx/headings-synthetic.dotx", "docm/headings-synthetic.docm", "dotm/headings-synthetic.dotm"] {
            let imported = try importedForTest(try copyOfFormatSample(sample))
            XCTAssertEqual(imported.book.format, .docx, sample)

            let content = try openedContent(of: imported.book)
            XCTAssertEqual(headingLines(of: content), [], sample)
            let text = allText(of: content)
            XCTAssertTrue(text.contains("Harbour Notes"), sample)
            XCTAssertTrue(text.contains("Morning Tides"), sample)
            XCTAssertTrue(text.contains("The ferry leaves at seven."), sample)
            XCTAssertTrue(text.contains("Prices — in euros — are posted by the quay."), sample)
        }
    }

    /// Each real LibreOffice sample imports as a Word document and opens
    /// with its one paragraph of text. None holds a heading style, so the
    /// text is all these samples show.
    func testRealSamplesImportAsWordDocumentsWithTheirText() throws {
        let samples = [
            ("dotx/libreoffice-sample.dotx", "Sample file which will be a template"),
            ("docm/libreoffice-hello.docm", "adsf"),
            ("dotm/libreoffice-autotext-dotm.dotm", "This file contains AutoText entries")
        ]
        for (sample, phrase) in samples {
            let imported = try importedForTest(try copyOfFormatSample(sample))
            XCTAssertEqual(imported.book.format, .docx, sample)

            let content = try openedContent(of: imported.book)
            XCTAssertTrue(allText(of: content).contains(phrase), sample)
            XCTAssertEqual(headingLines(of: content), [], sample)
        }
    }

    // MARK: - Headings under every form's content type

    /// A real, heading-styled .docx turned into each of the three forms, by
    /// changing only its main part's content type and its extension,
    /// imports as a Word document with exactly the headings and the text of
    /// the plain .docx. The samples above hold no heading style, so only
    /// this test can fail if a form lost its headings.
    func testEachFormImportsWithExactlyTheHeadingsOfItsDocx() throws {
        let plain = try openedContent(of: try importedForTest(try copyOfHeadingDocx(named: "plain.docx")).book)
        let expectedHeadings = headingLines(of: plain)

        // The plain document must hold headings of three levels, or the
        // comparison below would pin nothing. Its first four are named.
        XCTAssertGreaterThan(expectedHeadings.count, 4)
        XCTAssertEqual(Array(expectedHeadings.prefix(4)), [
            "1: The Lighthouse Operator's Handbook",
            "1: Chapter 1: First Principles",
            "2: The Daily Routine",
            "2: Equipment Checklist"
        ])
        XCTAssertTrue(expectedHeadings.contains { $0.hasPrefix("3: ") })

        for form in Self.forms {
            let url = try makeForm(form)

            // The copy really is of this form: its main part's type is the form's.
            let types = try archiveText(of: "[Content_Types].xml", in: url)
            XCTAssertTrue(types.contains("PartName=\"/word/document.xml\" ContentType=\"\(form.mainContentType)\""), form.ext)
            XCTAssertFalse(types.contains(Self.docxMainContentType), form.ext)

            let imported = try importedForTest(url)
            XCTAssertEqual(imported.book.format, .docx, form.ext)
            let content = try openedContent(of: imported.book)
            XCTAssertEqual(headingLines(of: content), expectedHeadings, form.ext)
            XCTAssertEqual(allText(of: content), allText(of: plain), form.ext)
        }
    }

    // MARK: - Detection and registration

    /// Each extension is a Word document in any letter case, and the legacy
    /// .doc is still not one.
    func testDetectionGivesDocxForEachTemplateExtensionInAnyCase() {
        for ext in ["docx"] + Self.templateExtensions {
            for name in [ext, ext.uppercased(), ext.capitalized] {
                let url = URL(fileURLWithPath: "/tmp/file.\(name)")
                XCTAssertEqual(BookFormat.detect(from: url), .docx, name)
            }
            XCTAssertTrue(BookFormat.docx.fileExtensions.contains(ext), ext)
        }
        XCTAssertNotEqual(BookFormat.detect(from: URL(fileURLWithPath: "/tmp/file.doc")), .docx)
    }

    /// The Open Book panel offers the three types beside the .docx type.
    func testSupportedTypesHoldTheTemplateTypes() {
        let identifiers = FileImportService.supportedTypes.map(\.identifier)
        for identifier in Self.templateTypeIdentifiers {
            XCTAssertTrue(identifiers.contains(identifier), identifier)
        }
    }

    /// The app's Info.plist lists each extension and each type in a
    /// Viewer document type, so the Finder offers TextMouth for them.
    func testInfoPlistListsEachExtensionAndTypeInAViewerDocumentType() throws {
        for ext in Self.templateExtensions {
            let type = try XCTUnwrap(documentType(listing: ext), ext)
            XCTAssertEqual(type["CFBundleTypeRole"] as? String, "Viewer", ext)
        }
        for identifier in Self.templateTypeIdentifiers {
            let type = try XCTUnwrap(documentType(listingContentType: identifier), identifier)
            XCTAssertEqual(type["CFBundleTypeRole"] as? String, "Viewer", identifier)
        }
    }

    // MARK: - Macros are never read

    /// A macro-enabled document holding a macro project that cannot be read
    /// (its deflated bytes are damaged, so inflating them fails) imports
    /// exactly as the same document without it: the reader never opens
    /// word/vbaProject.bin.
    func testAMacroProjectThatCannotBeReadIsNeverOpened() throws {
        let docm = try XCTUnwrap(Self.forms.first { $0.ext == "docm" })
        let plain = try makeForm(docm)
        let withMacros = try copyWithUnreadableMacroProject(of: plain)

        // The damage is real: reading the entry throws, so a reader that
        // opened it could not have imported the document unchanged.
        let archive = try Archive(url: withMacros, accessMode: .read)
        let entry = try XCTUnwrap(archive["word/vbaProject.bin"])
        XCTAssertEqual(entry.type, .file)
        XCTAssertThrowsError(try ArchiveEntryReader.read(entry, in: archive))

        // A relationship points at the project, as in a real macro document.
        let relationships = try archiveText(of: "word/_rels/document.xml.rels", in: withMacros)
        XCTAssertTrue(relationships.contains("Target=\"vbaProject.bin\""))

        // The copy with the unreadable project imports as the copy without it.
        let expected = try openedContent(of: try importedForTest(plain).book)
        XCTAssertFalse(headingLines(of: expected).isEmpty)
        let imported = try importedForTest(withMacros)
        XCTAssertEqual(imported.book.format, .docx)
        let content = try openedContent(of: imported.book)
        XCTAssertEqual(headingLines(of: content), headingLines(of: expected))
        XCTAssertEqual(allText(of: content), allText(of: expected))
    }

    // MARK: - A document with no text

    /// A Word document of the three forms and the plain .docx whose body
    /// holds only empty paragraphs and white space is refused with "This
    /// file has no text to read.", as a blank RTF or ODT is, instead of being
    /// added as a silent, empty book.
    func testAWordDocumentWithNoTextIsRefused() throws {
        let blankBody = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
        <w:p/><w:p><w:r><w:t xml:space="preserve">   </w:t></w:r></w:p><w:p><w:r><w:tab/></w:r></w:p>
        </w:body></w:document>
        """
        var blankDocuments = [try copyOfHeadingDocx(named: "blank.docx")]
        for form in Self.forms {
            blankDocuments.append(try makeForm(form))
        }
        for url in blankDocuments {
            try replaceEntry("word/document.xml", in: url) { _ in blankBody }

            XCTAssertThrowsError(try FileImportService.importFileWithReport(from: url), url.lastPathComponent) { error in
                // The import wraps the refusal in a failure naming the file
                // and the step it was at (reading the text).
                guard let failure = error as? ImportFailure, case FileImportError.noTextToRead? = failure.underlying as? FileImportError else {
                    return XCTFail("\(url.lastPathComponent): expected noTextToRead, got \(error)")
                }
                XCTAssertEqual(failure.step, .readingText, url.lastPathComponent)
                XCTAssertEqual(failure.reason, "Reading its text failed: This file has no text to read.", url.lastPathComponent)
            }
        }
    }

    /// A Word document whose only text is in a table, or only in a text box,
    /// holds text: it is not refused as blank, and the book opens with the
    /// words. (A refusal that looked at the body's ordinary paragraphs alone
    /// would turn both away.)
    func testAWordDocumentWhoseOnlyTextIsInATableOrATextBoxIsNotRefused() throws {
        let tableOnly = "<w:tbl><w:tblPr/><w:tr><w:tc><w:p><w:r><w:t>Cell words</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:p/>"
        let textBoxOnly = "<w:p><w:r><w:pict><w:txbxContent><w:p><w:r><w:t>Boxed words</w:t></w:r></w:p></w:txbxContent></w:pict></w:r></w:p>"
        for (label, body, words) in [("table", tableOnly, "Cell words"), ("text box", textBoxOnly, "Boxed words")] {
            let url = try copyOfHeadingDocx(named: "\(label).docx")
            try replaceEntry("word/document.xml", in: url) { _ in
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                    + "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>"
                    + body + "</w:body></w:document>"
            }

            let imported = try importedForTest(url)

            XCTAssertEqual(imported.book.format, .docx, label)
            XCTAssertTrue(allText(of: try openedContent(of: imported.book)).contains(words), label)
        }
    }

    // MARK: - Making the copies

    /// A copy of TestData/test_book.docx (a real Word document with Heading
    /// 1, 2, and 3 styles) named `name`, in a sandbox folder of its own.
    private func copyOfHeadingDocx(named name: String) throws -> URL {
        let copy = try makeSandboxDirectory("WordTemplateForms").appendingPathComponent(name)
        try FileManager.default.copyItem(at: try requireFile("test_book.docx"), to: copy)
        return copy
    }

    /// A copy of the heading-styled .docx made into `form`: named with its
    /// extension, and with the content type of its main part changed to the
    /// form's, which is all that tells the forms apart.
    private func makeForm(_ form: Form) throws -> URL {
        let url = try copyOfHeadingDocx(named: "document.\(form.ext)")
        try replaceEntry("[Content_Types].xml", in: url) { xml in
            // The replacement must change something, or the copy is no form.
            XCTAssertTrue(xml.contains(Self.docxMainContentType))
            return xml.replacingOccurrences(of: Self.docxMainContentType, with: form.mainContentType)
        }
        return url
    }

    /// A copy of the .docm at `url`, in a sandbox folder of its own, with a
    /// `word/vbaProject.bin` entry that a relationship in
    /// word/_rels/document.xml.rels points to. The entry is deflated, and
    /// then its compressed bytes are damaged in the file so that inflating
    /// them fails.
    private func copyWithUnreadableMacroProject(of url: URL) throws -> URL {
        let copy = try makeSandboxDirectory("WordTemplateMacros").appendingPathComponent("with-macros.docm")
        try FileManager.default.copyItem(at: url, to: copy)

        // Add the relationship to the project.
        try replaceEntry("word/_rels/document.xml.rels", in: copy) { xml in
            let relationship = "<Relationship Id=\"rId99\" "
                + "Type=\"http://schemas.microsoft.com/office/2006/relationships/vbaProject\" "
                + "Target=\"vbaProject.bin\"/></Relationships>"
            return xml.replacingOccurrences(of: "</Relationships>", with: relationship)
        }

        // Add the project itself: a marker repeated, deflated.
        let marker = Data("MACRO-PROJECT-MUST-NOT-BE-READ".utf8)
        let project = Data(Array(repeating: marker, count: 64).joined())
        do {
            let archive = try Archive(url: copy, accessMode: .update)
            try archive.addEntry(
                with: "word/vbaProject.bin",
                type: .file,
                uncompressedSize: Int64(project.count),
                compressionMethod: .deflate,
                provider: { position, size in project[Int(position)..<min(Int(position) + size, project.count)] }
            )
        }

        // Damage the first compressed bytes. A local file header is 30 bytes
        // plus the entry's name and extra field, and the extra field's
        // length is the two bytes before the name. 0xFF starts a deflate
        // block of the invalid type 3, which no inflater accepts.
        var bytes = try Data(contentsOf: copy)
        let name = try XCTUnwrap(bytes.range(of: Data("word/vbaProject.bin".utf8)))
        let extraLength = Int(bytes[name.lowerBound - 2]) | Int(bytes[name.lowerBound - 1]) << 8
        let dataStart = name.upperBound + extraLength
        for offset in dataStart..<dataStart + 4 {
            bytes[offset] = 0xFF
        }
        try bytes.write(to: copy)
        return copy
    }

    /// Replaces the UTF-8 text entry `path` of the ZIP archive at `url`
    /// with `transform` of its text, deflated, in place.
    private func replaceEntry(_ path: String, in url: URL, transform: (String) throws -> String) throws {
        let archive = try Archive(url: url, accessMode: .update)
        let entry = try XCTUnwrap(archive[path], path)
        let text = try XCTUnwrap(String(data: try ArchiveEntryReader.read(entry, in: archive).data, encoding: .utf8))
        let replacement = Data(try transform(text).utf8)
        try archive.remove(entry)
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(replacement.count),
            compressionMethod: .deflate,
            provider: { position, size in replacement[Int(position)..<min(Int(position) + size, replacement.count)] }
        )
    }

    /// The text of the entry `path` of the ZIP archive at `url`.
    private func archiveText(of path: String, in url: URL) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        let entry = try XCTUnwrap(archive[path], path)
        return try XCTUnwrap(String(data: try ArchiveEntryReader.read(entry, in: archive).data, encoding: .utf8))
    }
}
