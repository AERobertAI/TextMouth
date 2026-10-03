import XCTest
@testable import TextMouth

/// A PDF whose pictures OCR could not read is imported the way an EPUB
/// missing chapters is (TODO T09): the book is added with all the text that
/// could be read, the reader is warned once with the pages and why, the
/// original file is kept whatever the "After Importing a Book" preference
/// says, and every cache generation logs the pages as one
/// `PDF_INCOMPLETE_CONTENT` line.
///
/// Vision works on the Macs these tests run on, so each test chooses how
/// PDF extraction reads pictures (`PDFFixtures.withDefaultRecognizer`):
/// with no recognizer, OCR is unavailable, as it would be where Vision
/// cannot run.
final class PDFImportReportTests: XCTestCase {

    // MARK: - Importing

    /// An import returns the PDF's page report, and the warning to give: the
    /// report's sentence, then that the original file was kept. The book
    /// holds the embedded text that could be read.
    func testImportReportsThePagesOCRCouldNotRead() throws {
        let pdf = try PDFFixtures.captionedPicture(for: self)

        let imported = try PDFFixtures.withDefaultRecognizer(nil) { try importWithReport(pdf) }

        XCTAssertTrue(imported.keepsOriginal)
        XCTAssertEqual(imported.report.pdf?.pagesWhereOCRCouldNotRun, [1])
        XCTAssertEqual(imported.warning, Self.unreadPictureWarning)
        XCTAssertEqual(
            try String(contentsOf: MarkdownCacheService.cacheURL(for: imported.book), encoding: .utf8),
            PDFFixtures.caption
        )
    }

    /// A PDF read in full has nothing to warn about and leaves the original
    /// to the preference, and its report still says how its pages were read.
    func testCompletePDFImportHasNoWarning() throws {
        let pdf = try PDFFixtures.captionedPicture(for: self)

        let imported = try PDFFixtures.withDefaultRecognizer(ScriptedTextRecognizer.findingNothing()) {
            try importWithReport(pdf)
        }

        XCTAssertFalse(imported.keepsOriginal)
        XCTAssertNil(imported.warning)
        XCTAssertEqual(
            imported.report.pdf?.summary,
            "Its only page has embedded text only. OCR found no text on page 1."
        )
    }

    // MARK: - Completing an Import in the Library

    /// End to end: the book is added with its embedded text, the warning is
    /// given once, the original stays although the preference says to
    /// delete it, nothing more is asked, and the import is logged once.
    @MainActor
    func testIncompletePDFImportWarnsOnceAddsTheBookAndKeepsTheOriginal() throws {
        let title = Self.uniqueTitle()
        let pdf = try PDFFixtures.captionedPicture(for: self, named: "\(title).pdf")

        try withImportDeleteBehavior(.deleteAfterImport) {
            let imported = try PDFFixtures.withDefaultRecognizer(nil) { try importWithReport(pdf) }
            let library = Self.emptyLibrary()

            library.completeSingleImportedBook(imported, originalURL: pdf)

            XCTAssertEqual(library.library.books.map(\.title), [title])
            XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path))
            XCTAssertTrue(library.showError)
            XCTAssertEqual(library.errorMessage, Self.unreadPictureWarning)
            XCTAssertTrue(library.importDecisions.isEmpty)
            let lines = debugLogLines(containing: "PDF_INCOMPLETE_CONTENT: \(title): ")
            XCTAssertEqual(lines.count, 1, "\(lines)")
            XCTAssertTrue(
                lines.first?.hasSuffix("PDF_INCOMPLETE_CONTENT: \(title): \(Self.unreadPictureProblem)") == true,
                "\(lines)"
            )
        }
    }

    // MARK: - Cache Rebuilds

    /// A rebuild of a PDF whose pictures OCR can no longer read still
    /// succeeds, carries the page report, and logs the pages once per
    /// generation rather than alerting; a generation that read everything
    /// logs nothing.
    func testCacheRebuildLogsThePagesOCRCouldNotRead() throws {
        let title = Self.uniqueTitle()
        let pdf = try PDFFixtures.captionedPicture(for: self, named: "\(title).pdf")
        var book = try PDFFixtures.withDefaultRecognizer(ScriptedTextRecognizer.findingNothing()) {
            try importWithReport(pdf).book
        }
        XCTAssertEqual(debugLogLines(containing: "PDF_INCOMPLETE_CONTENT: \(title): "), [])

        let rebuiltIndex = PDFFixtures.withDefaultRecognizer(nil) {
            MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &book)
        }
        let generated = try PDFFixtures.withDefaultRecognizer(nil) {
            try XCTUnwrap(MarkdownCacheService.generateReportedCacheContent(for: book))
        }

        XCTAssertNotNil(rebuiltIndex)
        XCTAssertEqual(book.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        XCTAssertEqual(generated.report.pdf?.pagesWhereOCRCouldNotRun, [1])
        let lines = debugLogLines(containing: "PDF_INCOMPLETE_CONTENT: \(title): ")
        XCTAssertEqual(lines.count, 2, "\(lines)")
        XCTAssertTrue(
            lines.allSatisfy { $0.hasSuffix("PDF_INCOMPLETE_CONTENT: \(title): \(Self.unreadPictureProblem)") },
            "\(lines)"
        )
    }

    // MARK: - Helpers

    /// What OCR being unavailable leaves missing from the one-page PDF with
    /// a captioned picture.
    private static let unreadPictureProblem =
        "OCR could not run on the PDF's only page, so text that appears only in its images is missing: "
            + "page 1 (text recognition is not available)."

    /// The warning an import of that PDF gives.
    private static let unreadPictureWarning = "\(unreadPictureProblem) The original file was kept."

    /// A title no other test uses, so this test's log lines can be found.
    private static func uniqueTitle() -> String {
        "Harbour Plates \(UUID().uuidString.prefix(8))"
    }

    /// Import `source` through the production path into the hosted tests'
    /// isolated library, removing its package when the test ends.
    private func importWithReport(_ source: URL) throws -> ImportedBook {
        let imported = try FileImportService.importFileWithReport(from: source)
        let package = imported.book.tmbDirectory
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }
        return imported
    }

    /// A library model with no books that starts no disk maintenance, so only
    /// the import under test can raise an alert.
    @MainActor
    private static func emptyLibrary() -> LibraryViewModel {
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library()
        return library
    }

    /// Run `body` with the "After Importing a Book" preference set to
    /// `behavior`, restoring the previous preference afterwards.
    @MainActor
    private func withImportDeleteBehavior(_ behavior: ImportDeleteBehavior, _ body: () throws -> Void) rethrows {
        let config = ConfigService.shared
        let previous = config.config.importDeleteBehavior
        config.config.importDeleteBehavior = behavior
        defer { config.config.importDeleteBehavior = previous }
        try body()
    }
}
