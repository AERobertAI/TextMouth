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
/// compared only on a Mac of the same major version. The same holds for the
/// format samples that macOS's `textutil` reads (RTF, RTFD, Word 97-2003,
/// OpenDocument, and WordML): they are compared on a Mac of the same major
/// version too. The other format samples are compared on every Mac. A format
/// sample's golden is named by its path inside `TestData/format-samples`,
/// each "/" written as "__", such as `rtf__headings.rtf.golden`.
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
        try skipIfRecordedOnAnotherMacOS(skipped)
    }

    /// The format samples that TextMouth's own readers read (Word templates,
    /// the web archive, SSML, DTBook) match their goldens on every Mac.
    func testFormatSamplesMatchTheirGoldens() throws {
        let names = recordedFormatSampleNames.filter { !TextPipelineFixtures.isMacOSDependentFormatSample($0) }
        _ = try checkOrRecord(try formatSampleDocuments(names), macOSVersion: nil)
    }

    /// The format samples that macOS's `textutil` reads match their goldens
    /// on the Mac they were recorded on, as the PDFs do. On a Mac whose major
    /// macOS version differs the comparison is skipped: what Apple's readers
    /// give changes with macOS.
    func testTextutilFormatSamplesMatchTheirGoldensOnTheMacTheyWereRecordedOn() throws {
        let names = recordedFormatSampleNames.filter { TextPipelineFixtures.isMacOSDependentFormatSample($0) }
        let skipped = try checkOrRecord(try formatSampleDocuments(names), macOSVersion: DocumentDump.currentMacOSVersion)
        try skipIfRecordedOnAnotherMacOS(skipped)
    }

    /// The list of format samples names every sample of the formats' folders
    /// (so a sample added later gets a golden) and nothing that is not
    /// there; golden names are plain file names that do not repeat.
    func testTheFormatSampleListNamesEverySample() throws {
        let samplesFolder = try requireFile(String(TextPipelineFixtures.formatSamplesPrefix.dropLast()))
        let folders = Set(TextPipelineFixtures.formatSampleNames.compactMap {
            TextPipelineFixtures.pathInsideFormatSamples($0).split(separator: "/").first.map(String.init)
        })
        // Everything in those folders but the HTML the RTF samples came from.
        var onDisk: [String] = []
        for folder in folders.sorted() {
            let entries = try FileManager.default.contentsOfDirectory(atPath: samplesFolder.appendingPathComponent(folder).path)
            for entry in entries where !entry.hasPrefix(".") && entry != "headings-source.html" {
                onDisk.append("\(TextPipelineFixtures.formatSamplesPrefix)\(folder)/\(entry)")
            }
        }
        XCTAssertEqual(
            TextPipelineFixtures.formatSampleNames.sorted(), onDisk.sorted(),
            "TextPipelineFixtures.formatSampleNames must name every sample in the formats' folders"
        )
        let goldenNames = TextPipelineFixtures.formatSampleNames.map(TextPipelineFixtures.formatSampleGoldenName)
        XCTAssertEqual(Set(goldenNames).count, goldenNames.count)
        XCTAssertFalse(goldenNames.contains { $0.contains("/") })
        // A renamed sample is one of the list.
        for name in TextPipelineFixtures.formatSampleImportNames.keys {
            XCTAssertTrue(TextPipelineFixtures.formatSampleNames.contains(name), name)
        }
    }

    /// Every held-back sample is a listed format sample, so a removed or
    /// renamed sample cannot leave a stale entry.
    func testHeldBackSamplesAreFormatSamples() {
        for name in TextPipelineFixtures.formatSamplesHeldBack.keys {
            XCTAssertTrue(TextPipelineFixtures.formatSampleNames.contains(name), name)
        }
    }

    /// The golden name of a format sample is its path inside the format
    /// samples folder with each "/" written as "__", and the WordML sample
    /// imports under an .xml name.
    func testFormatSampleGoldenNamesJoinThePathWithTwoUnderscores() {
        XCTAssertEqual(
            TextPipelineFixtures.formatSampleGoldenName("format-samples/rtf/headings.rtf"), "rtf__headings.rtf"
        )
        XCTAssertEqual(
            TextPipelineFixtures.formatSampleGoldenName("format-samples/dtbook/nimas-style-package"),
            "dtbook__nimas-style-package"
        )
        XCTAssertEqual(
            TextPipelineFixtures.formatSampleImportName("format-samples/wordml/headings.wordml"), "headings.xml"
        )
        XCTAssertEqual(
            TextPipelineFixtures.formatSampleImportName("format-samples/rtf/headings.rtf"), "headings.rtf"
        )
    }

    /// The format samples whose goldens are recorded and compared: all but
    /// those held back until a reader bug is fixed, and the real OpenDocument
    /// files from LibreOffice, which `ODTTextutilComparisonTests` compares
    /// with textutil's reading instead.
    private var recordedFormatSampleNames: [String] {
        TextPipelineFixtures.formatSampleNames.filter {
            TextPipelineFixtures.formatSamplesHeldBack[$0] == nil && !TextPipelineFixtures.isComparedByODTTests($0)
        }
    }

    /// Skip the test, naming the documents, when any golden was recorded on
    /// another major macOS version; do nothing when `skipped` is empty.
    private func skipIfRecordedOnAnotherMacOS(_ skipped: [String]) throws {
        if !skipped.isEmpty {
            throw XCTSkip("""
                \(skipped.joined(separator: ", ")) was recorded on another major version of macOS than \
                \(DocumentDump.currentMacOSVersion), so its text may differ for reasons that are not a change: \
                record it on this Mac with Scripts/test/update-goldens.sh
                """)
        }
    }

    /// Copies of the format samples `names` in sandbox folders of this test
    /// (a sample is never imported where it lies, and a renamed one gets its
    /// import name), each with its golden's name.
    private func formatSampleDocuments(_ names: [String]) throws -> [(name: String, url: URL)] {
        try names.map { name in
            let copy = try copyOfFormatSample(
                TextPipelineFixtures.pathInsideFormatSamples(name),
                named: TextPipelineFixtures.formatSampleImportNames[name]
            )
            return (TextPipelineFixtures.formatSampleGoldenName(name), copy)
        }
    }

    /// Every golden in TestData/golden belongs to a document: one of the
    /// named books, a named PDF, a format sample, or one of the optional
    /// books (whether or not this checkout holds it). A stale golden is removed in the same
    /// commit as its document.
    func testEveryGoldenFileHasADocument() throws {
        // Recording writes the goldens; the folder may not exist yet.
        try XCTSkipIf(Self.isRecording, "Goldens are being recorded")
        let formatSamples = TextPipelineFixtures.formatSampleNames.map(TextPipelineFixtures.formatSampleGoldenName)
        let known = Set(
            TextPipelineFixtures.testDataBookNames + TextPipelineFixtures.optionalTestDataBookNames + Self.pdfNames
                + formatSamples
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
