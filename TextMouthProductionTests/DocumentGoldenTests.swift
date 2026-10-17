import XCTest
@testable import TextMouth

/// Readable golden files for the documents in TestData.
///
/// `TextPipelineGoldenTests` pins digests of what each book imports and reads
/// as; a digest says only that something changed. Here each document has a
/// small text file, `TestData/golden/<file name>.golden`, recording the facts
/// a person would check (`DocumentDump`), and a failure names every
/// difference in words. A deliberate change is recorded with
/// `Scripts/test/update-goldens.sh`, which runs these tests with
/// `TEXTMOUTH_UPDATE_GOLDENS=1`: they then write the goldens into the source
/// tree instead of comparing.
///
/// A PDF's text comes from PDFKit and Vision and changes with the macOS
/// version, so a PDF's golden records the macOS it was made on and is
/// compared only on a Mac of the same major version.
final class DocumentGoldenTests: XCTestCase {

    // MARK: - The Documents

    /// The PDFs in TestData whose goldens are kept, by file name.
    static let pdfNames = ["test_formatted.pdf", "test_with_outline.pdf"]

    /// The sentence that ends every failure that a deliberate change could
    /// explain.
    static let recordCommandSentence = "If the change is deliberate, record it with: Scripts/test/update-goldens.sh"

    /// Whether this run records goldens (`TEXTMOUTH_UPDATE_GOLDENS=1`)
    /// rather than comparing them.
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["TEXTMOUTH_UPDATE_GOLDENS"] == "1"
    }

    /// The folder holding the goldens in the source tree: `TestData/golden`,
    /// found from this file's own location, as the fixtures are.
    static var goldenFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TestData", isDirectory: true)
            .appendingPathComponent("golden", isDirectory: true)
    }

    /// The golden of the document named `name`: `<name>.golden`, which git
    /// does not ignore as it ignores `*.txt` and `*.md`.
    static func goldenURL(for name: String) -> URL {
        goldenFolder.appendingPathComponent("\(name).golden")
    }

    // MARK: - Tests

    /// Every book but the PDFs matches its golden, on every Mac. The large
    /// optional DAISY books are compared only where they are present and a
    /// golden for them exists, and are never recorded.
    func testEveryDocumentMatchesItsGolden() throws {
        let required = Set(TextPipelineFixtures.testDataBookNames)
        let documents = try TextPipelineFixtures.testDataBooks().filter { document in
            required.contains(document.name)
                || (!Self.isRecording && FileManager.default.fileExists(atPath: Self.goldenURL(for: document.name).path))
        }
        _ = try checkOrRecord(documents, macOSVersion: nil)
    }

    /// The PDFs match their goldens on the Mac they were recorded on. On a
    /// Mac whose major macOS version differs the comparison is skipped: the
    /// text PDFKit and Vision produce changes with macOS.
    func testPDFsMatchTheirGoldensOnTheMacTheyWereRecordedOn() throws {
        let documents = try Self.pdfNames.map { (name: $0, url: try requireFile($0)) }
        let skipped = try checkOrRecord(documents, macOSVersion: DocumentDump.currentMacOSVersion)
        if !skipped.isEmpty {
            throw XCTSkip("""
                \(skipped.joined(separator: ", ")) was recorded on another major version of macOS than \
                \(DocumentDump.currentMacOSVersion), so its text may differ for reasons that are not a change: \
                record it on this Mac with Scripts/test/update-goldens.sh
                """)
        }
    }

    /// Every golden in TestData/golden belongs to a document: one of the
    /// named books, a named PDF, or one of the optional books (whether or
    /// not this checkout holds it). A stale golden is removed in the same
    /// commit as its document.
    func testEveryGoldenFileHasADocument() throws {
        // Recording writes the goldens; the folder may not exist yet.
        try XCTSkipIf(Self.isRecording, "Goldens are being recorded")
        let known = Set(
            TextPipelineFixtures.testDataBookNames + TextPipelineFixtures.optionalTestDataBookNames + Self.pdfNames
        ).map { "\($0).golden" }
        let found = try FileManager.default.contentsOfDirectory(atPath: Self.goldenFolder.path)
            .filter { !$0.hasPrefix(".") }
        let stale = found.filter { !known.contains($0) }.sorted()
        XCTAssertTrue(
            stale.isEmpty,
            "TestData/golden holds goldens with no document: \(stale.joined(separator: ", ")). Remove them with their document."
        )
    }

    // MARK: - Comparing and Recording

    /// Import each of `documents`, dump it, and either record its golden
    /// (when recording) or compare it with the golden on disk. A document
    /// that cannot be imported fails by name and the rest are still compared.
    /// - Parameter macOSVersion: recorded in each dump and, for the
    ///   comparison, the version whose major number must match the golden's;
    ///   nil for documents that do not depend on macOS.
    /// - Returns: the names of the documents whose comparison was skipped
    ///   because their golden was recorded on another major macOS version.
    private func checkOrRecord(_ documents: [(name: String, url: URL)], macOSVersion: String?) throws -> [String] {
        var skipped: [String] = []
        for (name, url) in documents {
            let golden = Self.recordedGolden(named: name)
            // A PDF's golden made on another major version of macOS is not
            // compared (and is replaced when recording).
            if !Self.isRecording, let macOSVersion, let recorded = golden.flatMap(DocumentDump.macOSMajorVersion(inGolden:)),
               recorded != Int(macOSVersion.split(separator: ".").first ?? "") {
                skipped.append(name)
                continue
            }
            guard let dump = dumped(name, at: url, macOSVersion: macOSVersion) else { continue }
            if Self.isRecording {
                record(dump, named: name)
            } else {
                compare(dump, with: golden, named: name)
            }
        }
        return skipped
    }

    /// The contents of the golden for `name`, or nil when there is none.
    private static func recordedGolden(named name: String) -> String? {
        try? String(contentsOf: goldenURL(for: name), encoding: .utf8)
    }

    /// The dump of the document at `url`, imported as a reader imports it
    /// into the hosted tests' isolated library (its package is removed when
    /// the test ends); nil, after failing the test by name, when it cannot
    /// be imported or opened.
    ///
    /// This calls `FileImportService.importFileWithReport` as
    /// `TextPipelineFixtures.imported` does, because the dump records the
    /// import's report, which `imported` does not return.
    private func dumped(_ name: String, at url: URL, macOSVersion: String?) -> DocumentDump? {
        do {
            let imported = try FileImportService.importFileWithReport(from: url)
            addTeardownBlock { try? FileManager.default.removeItem(at: imported.book.tmbDirectory) }
            let opened = try BookContentAnalysisService.load(book: imported.book)
            return DocumentDump(
                fileName: name, book: imported.book, opened: opened, report: imported.report, macOSVersion: macOSVersion
            )
        } catch {
            XCTFail("\(name) could not be imported, so its golden was not compared: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fail the test, naming every difference, when `dump` differs from
    /// `golden`; fail with the record command when there is no golden.
    private func compare(_ dump: DocumentDump, with golden: String?, named name: String) {
        guard let golden else {
            XCTFail("\(name) has no golden (TestData/golden/\(name).golden). \(Self.recordCommandSentence)")
            return
        }
        let differences = DocumentDump.differences(golden: golden, actual: dump.rendered())
        guard !differences.isEmpty else { return }
        let listed = differences.map { "  - \($0)" }.joined(separator: "\n")
        XCTFail("\(name) differs from its golden:\n\(listed)\n\(Self.recordCommandSentence)")
    }

    /// Write the golden for `name` into the source tree, atomically, and
    /// print `GOLDEN RECORDED: <name>`. Only a plain file name is written,
    /// and only inside TestData/golden.
    private func record(_ dump: DocumentDump, named name: String) {
        guard !name.isEmpty, !name.contains("/") else {
            XCTFail("Refusing to record a golden named \"\(name)\": it is not a plain file name")
            return
        }
        do {
            try FileManager.default.createDirectory(at: Self.goldenFolder, withIntermediateDirectories: true)
            try dump.rendered().write(to: Self.goldenURL(for: name), atomically: true, encoding: .utf8)
            print("GOLDEN RECORDED: \(name)")
        } catch {
            XCTFail("The golden of \(name) could not be written: \(error.localizedDescription)")
        }
    }
}
