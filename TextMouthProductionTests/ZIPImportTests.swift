import XCTest
@testable import TextMouth

/// Regression coverage for partial ZIP import reporting.
final class ZIPImportTests: XCTestCase {
    /// A successful member cannot authorize deletion of failed members' only
    /// source. Exercise the real completion path with automatic deletion on.
    @MainActor
    func testPartialImportKeepsOriginalArchive() throws {
        try verifyOriginalHandling(hasFailure: true, hasBook: true, shouldDelete: false)
    }

    /// Empty and duplicate-only results must preserve the source archive.
    @MainActor
    func testImportWithoutAcceptedBooksKeepsOriginalArchive() throws {
        try verifyOriginalHandling(hasFailure: false, hasBook: false, shouldDelete: false)
    }

    /// Preserve the explicit delete-after-import preference after success.
    @MainActor
    func testSuccessfulImportStillHonorsOriginalDeletionPreference() throws {
        try verifyOriginalHandling(hasFailure: false, hasBook: true, shouldDelete: true)
    }

    /// ZIP books use the same Replace/Keep Both/Cancel flow as documents.
    @MainActor
    func testSingleZIPBookRequestsDuplicateResolution() {
        let existing = Book(title: "Existing", format: .audio, filePath: "/tmp/existing", md5Hash: "same")
        let imported = Book(title: "Imported", format: .audio, filePath: "/tmp/imported", md5Hash: "same")
        let viewModel = LibraryViewModel()
        viewModel.library = Library(books: [existing])

        viewModel.completeSingleImportedBook(ImportedBook(book: imported), originalURL: URL(fileURLWithPath: "/tmp/source.zip"))

        XCTAssertEqual(viewModel.library.books.map(\.id), [existing.id])
        XCTAssertEqual(viewModel.pendingDuplicateBook?.id, imported.id)
        XCTAssertTrue(viewModel.showDuplicateDialog)
    }

    /// Use a disposable file and restore the config preference after each
    /// scenario; no test deletes or overwrites a developer-owned archive.
    @MainActor
    private func verifyOriginalHandling(hasFailure: Bool, hasBook: Bool, shouldDelete: Bool) throws {
        let original = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        try Data("archive source".utf8).write(to: original)
        let config = ConfigService.shared
        let previous = config.config.importDeleteBehavior
        defer {
            config.config.importDeleteBehavior = previous
            try? FileManager.default.removeItem(at: original)
        }
        config.config.importDeleteBehavior = .deleteAfterImport
        // An inert model, so that only this import can raise the alert under
        // test: a full startup would also run the startup repair over
        // whatever records earlier tests left in the shared test index.
        let viewModel = LibraryViewModel(initializeServices: false)
        viewModel.library = Library()
        let book = Book(title: "Accepted", format: .txt, filePath: "/tmp/accepted", md5Hash: UUID().uuidString)
        let result = ZipImportResult(
            books: hasBook ? [book] : [],
            failures: hasFailure ? [ZipImportFailure(fileName: "failed.epub", message: "unreadable")] : []
        )

        viewModel.completeZIPImport(result, originalURL: original, folderPath: "")

        XCTAssertEqual(FileManager.default.fileExists(atPath: original.path), !shouldDelete)
        XCTAssertEqual(viewModel.library.books.count, hasBook ? 1 : 0)
        XCTAssertEqual(viewModel.showError, hasFailure)
    }

    func testSupportedFileLoopReturnsBooksAndPerFileFailures() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appendingPathComponent("good.txt")
        let bad = directory.appendingPathComponent("bad.txt")
        try Data("good".utf8).write(to: good)
        try Data("bad".utf8).write(to: bad)

        let result = FileImportService.importSupportedFiles(
            [good, bad],
            toFolder: "",
            importer: { url, _ in
                if url.lastPathComponent == "bad.txt" {
                    throw FileImportError.importFailed("simulated parse failure")
                }
                return Book(
                    title: "Imported",
                    format: .txt,
                    filePath: url.path,
                    md5Hash: try FileImportService.md5Hash(of: url)
                )
            }
        )

        XCTAssertEqual(result.books.map(\.title), ["Imported"])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures[0].fileName, "bad.txt")
        XCTAssertTrue(result.failures[0].message.contains("simulated parse failure"))
    }

    func testFailureSummaryNamesEveryFailedFile() throws {
        let result = ZipImportResult(
            books: [],
            failures: [
                ZipImportFailure(fileName: "first.epub", message: "invalid archive"),
                ZipImportFailure(fileName: "second.pdf", message: "unreadable")
            ]
        )

        let summary = try XCTUnwrap(result.failureSummary)
        XCTAssertTrue(summary.contains("2 files failed"))
        XCTAssertTrue(summary.contains("first.epub: invalid archive"))
        XCTAssertTrue(summary.contains("second.pdf: unreadable"))
    }

    func testDuplicateFilesAreSkippedWithoutBeingReportedAsFailures() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("duplicate".utf8).write(to: file)
        let hash = try FileImportService.md5Hash(of: file)

        let result = FileImportService.importSupportedFiles(
            [file],
            toFolder: "",
            existingHashes: [hash],
            importer: { _, _ in
                XCTFail("Duplicate should not reach importer")
                throw FileImportError.importFailed("unexpected")
            }
        )

        XCTAssertTrue(result.books.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
    }
}
