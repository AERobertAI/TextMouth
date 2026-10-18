import XCTest
import ZIPFoundation
@testable import TextMouth

/// Word templates (.dotx), macro-enabled documents (.docm), and
/// macro-enabled templates (.dotm) are the same Office Open XML package as
/// a .docx, only the main part's content type differs (FMT01). They share
/// the `.docx` case and its reader, which opens only the XML parts it needs,
/// so a macro project is never opened. Each test imports a copy of a sample
/// from `TestData/format-samples` (untrusted input) in a folder of its own.
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

    // MARK: - Importing the samples

    /// Each synthetic sample imports as a Word document and opens with the
    /// text of the one document they were made from, whose titles are only
    /// bold, larger runs (direct formatting, no heading style), which
    /// `DOCXParser` does not take for headings: none is announced.
    func testSyntheticSamplesImportAsWordDocumentsWithTheirHeadings() throws {
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
    /// with its one paragraph of text; none holds a heading.
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
    /// (its stored bytes fail their CRC check) imports exactly as the same
    /// document without it: the reader never opens word/vbaProject.bin.
    func testAMacroProjectThatCannotBeReadIsNeverOpened() throws {
        let plain = try copyOfFormatSample("docm/headings-synthetic.docm")
        let withMacros = try copyWithUnreadableMacroProject(of: plain)

        // The damage is real: the checksum of the bytes the entry gives is
        // not the one the archive stores for it (`ArchiveEntryReader` hands
        // the comparison to its caller for a stored entry).
        let archive = try Archive(url: withMacros, accessMode: .read)
        let entry = try XCTUnwrap(archive["word/vbaProject.bin"])
        let read = try ArchiveEntryReader.read(entry, in: archive)
        XCTAssertNotEqual(read.checksum, entry.checksum)

        let expected = try openedContent(of: try importedForTest(plain).book)
        let imported = try importedForTest(withMacros)
        XCTAssertEqual(imported.book.format, .docx)
        let content = try openedContent(of: imported.book)
        XCTAssertEqual(headingLines(of: content), headingLines(of: expected))
        XCTAssertEqual(allText(of: content), allText(of: expected))
    }

    /// A copy of the .docm at `url`, in a sandbox folder of its own, with a
    /// `word/vbaProject.bin` entry that a relationship in
    /// word/_rels/document.xml.rels points to, whose stored bytes are then
    /// flipped in the file so that its stored checksum no longer matches.
    private func copyWithUnreadableMacroProject(of url: URL) throws -> URL {
        // Read every entry of the original, adding the relationship.
        let source = try Archive(url: url, accessMode: .read)
        var entries: [TestZIPEntry] = []
        for entry in source {
            var data = try ArchiveEntryReader.read(entry, in: source).data
            if entry.path == "word/_rels/document.xml.rels" {
                let xml = try XCTUnwrap(String(data: data, encoding: .utf8))
                let relationship = "<Relationship Id=\"rId99\" "
                    + "Type=\"http://schemas.microsoft.com/office/2006/relationships/vbaProject\" "
                    + "Target=\"vbaProject.bin\"/></Relationships>"
                data = Data(xml.replacingOccurrences(of: "</Relationships>", with: relationship).utf8)
            }
            entries.append(TestZIPEntry(entry.path, data))
        }

        // A project made of a marker repeated, so its stored bytes can be found.
        let marker = Data("MACRO-PROJECT-MUST-NOT-BE-READ".utf8)
        entries.append(TestZIPEntry("word/vbaProject.bin", Data(Array(repeating: marker, count: 4).joined())))
        let zip = try makeTemporaryZip(prefix: "WordTemplateImportTests", orderedEntries: entries)
        defer { try? FileManager.default.removeItem(at: zip) }

        // Flip a byte of the first stored copy of the marker.
        var bytes = try Data(contentsOf: zip)
        let range = try XCTUnwrap(bytes.range(of: marker))
        bytes[range.lowerBound] ^= 0xFF

        let copy = try makeSandboxDirectory("WordTemplateMacros").appendingPathComponent("with-macros.docm")
        try bytes.write(to: copy)
        return copy
    }
}
