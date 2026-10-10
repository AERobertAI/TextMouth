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

    /// Every file imported, but a book that is missing chapters has only
    /// the archive as a complete source: keep it, and say what is missing.
    @MainActor
    func testImportWithBookMissingChaptersKeepsOriginalArchive() throws {
        try verifyOriginalHandling(hasFailure: false, hasBook: true, hasIncompleteBook: true, shouldDelete: false)
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
        XCTAssertEqual(viewModel.importDecisions.current?.duplicate?.book.id, imported.id)
        XCTAssertEqual(viewModel.importDecisions.current?.duplicate?.existing.id, existing.id)
    }

    /// Use a disposable file and restore the config preference after each
    /// scenario; no test deletes or overwrites a developer-owned archive.
    @MainActor
    private func verifyOriginalHandling(
        hasFailure: Bool,
        hasBook: Bool,
        hasIncompleteBook: Bool = false,
        shouldDelete: Bool
    ) throws {
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
            failures: hasFailure ? [ZipImportFailure(fileName: "failed.epub", message: "unreadable")] : [],
            incompleteBooks: hasIncompleteBook ? [ZipImportFailure(fileName: "accepted.epub", message: "missing")] : []
        )

        // Deleting goes to the Trash when that preference is on: keep this
        // test's archive out of the real Trash.
        withTrashPreference(movesToTrash: false) {
            viewModel.completeZIPImport(result, originalURL: original, folderPath: "")
        }

        XCTAssertEqual(FileManager.default.fileExists(atPath: original.path), !shouldDelete)
        XCTAssertEqual(viewModel.library.books.count, hasBook ? 1 : 0)
        XCTAssertEqual(viewModel.showError, hasFailure || hasIncompleteBook)
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
            importer: { url, _, _, _ in
                if url.lastPathComponent == "bad.txt" {
                    throw FileImportError.importFailed("simulated parse failure")
                }
                return ImportedBook(book: Book(
                    title: "Imported",
                    format: .txt,
                    filePath: url.path,
                    md5Hash: try FileImportService.md5Hash(of: url)
                ))
            }
        )

        XCTAssertEqual(result.books.map(\.title), ["Imported"])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures[0].fileName, "bad.txt")
        XCTAssertTrue(result.failures[0].message.contains("simulated parse failure"))
    }

    /// The loop names each book by its file as it begins, reading the file,
    /// passes on each step its importer begins on the book's package, and
    /// counts each book done once it is imported, skipped as a duplicate
    /// without reaching the importer, which it says so the estimate of the
    /// time left leaves it out, or failed (FR10).
    func testSupportedFileLoopReportsEachBookItsStepsAndItsEnd() throws {
        let directory = try makeSandboxDirectory("zip-loop-progress")
        let imported = directory.appendingPathComponent("Rope Splicing.txt")
        let duplicate = directory.appendingPathComponent("Knots.txt")
        let failing = directory.appendingPathComponent("Tides.txt")
        try Data("rope".utf8).write(to: imported)
        try Data("knots".utf8).write(to: duplicate)
        try Data("tides".utf8).write(to: failing)
        var reports: [ZipImportProgress] = []

        let result = FileImportService.importSupportedFiles(
            [imported, duplicate, failing],
            toFolder: "",
            existingHashes: [try FileImportService.md5Hash(of: duplicate)],
            progress: { reports.append($0) },
            importer: { url, _, _, observer in
                try observer?(.copying, url)
                if url == failing {
                    throw FileImportError.importFailed("simulated parse failure")
                }
                try observer?(.readingText, url)
                return ImportedBook(book: Book(
                    title: "Rope Splicing",
                    format: .txt,
                    filePath: url.path,
                    md5Hash: try FileImportService.md5Hash(of: url)
                ))
            }
        )

        XCTAssertEqual(result.books.map(\.title), ["Rope Splicing"])
        XCTAssertEqual(result.failures.map(\.fileName), ["Tides.txt"])
        XCTAssertEqual(result.skippedDuplicates, 1)
        XCTAssertFalse(result.foundNoNewBook)
        XCTAssertEqual(reports, [
            // Each book's size first, as the estimate of the time left
            // weighs them: the bytes of "rope", "knots", and "tides".
            .foundBooks(sizes: [4, 5, 5]),
            .importingBook(number: 1, total: 3, book: "Rope Splicing.txt", step: .readingSource),
            .importingBook(number: 1, total: 3, book: "Rope Splicing.txt", step: .copying),
            .importingBook(number: 1, total: 3, book: "Rope Splicing.txt", step: .readingText),
            .importing(done: 1, total: 3),
            .importingBook(number: 2, total: 3, book: "Knots.txt", step: .readingSource),
            .importing(done: 2, total: 3, skippedDuplicate: true),
            .importingBook(number: 3, total: 3, book: "Tides.txt", step: .readingSource),
            .importingBook(number: 3, total: 3, book: "Tides.txt", step: .copying),
            .importing(done: 3, total: 3)
        ])
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

    /// Books imported without some of their chapters are listed after the
    /// failed files, each with what it is missing, and the summary says the
    /// original ZIP was kept.
    func testFailureSummaryListsBooksMissingChapters() throws {
        let result = ZipImportResult(
            books: [
                Book(title: "Complete", format: .epub, filePath: "/tmp/complete.epub", md5Hash: "a"),
                Book(title: "Partial", format: .epub, filePath: "/tmp/partial.epub", md5Hash: "b")
            ],
            failures: [ZipImportFailure(fileName: "bad.epub", message: "unreadable")],
            incompleteBooks: [ZipImportFailure(fileName: "partial.epub", message: "1 of 3 chapters could not be read.")]
        )

        XCTAssertEqual(
            result.failureSummary,
            "Imported 2 books, but 1 file failed:\nbad.epub: unreadable\n"
                + "1 book is missing chapters:\npartial.epub: 1 of 3 chapters could not be read.\n"
                + "The original file was kept."
        )
    }

    /// A batch whose only problem is books missing chapters still gets a
    /// summary, since the reader must hear what is missing.
    func testIncompleteBooksAloneProduceASummary() {
        let result = ZipImportResult(
            books: [Book(title: "Partial", format: .epub, filePath: "/tmp/partial.epub", md5Hash: "b")],
            failures: [],
            incompleteBooks: [
                ZipImportFailure(fileName: "one.epub", message: "Missing one."),
                ZipImportFailure(fileName: "two.epub", message: "Missing two.")
            ]
        )

        XCTAssertEqual(
            result.failureSummary,
            "Imported 1 book, but 2 books are missing chapters:\none.epub: Missing one.\ntwo.epub: Missing two.\n"
                + "The original file was kept."
        )
    }

    /// A file already in the library is skipped, counted among the batch's
    /// duplicates, and is no failure; a batch of nothing else found no new
    /// book, which VoiceOver is told however short it was (FR10).
    func testDuplicateFilesAreSkippedWithoutBeingReportedAsFailures() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("duplicate".utf8).write(to: file)
        let hash = try FileImportService.md5Hash(of: file)

        let result = FileImportService.importSupportedFiles(
            [file],
            toFolder: "",
            existingHashes: [hash],
            importer: { _, _, _, _ in
                XCTFail("Duplicate should not reach importer")
                throw FileImportError.importFailed("unexpected")
            }
        )

        XCTAssertTrue(result.books.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.skippedDuplicates, 1)
        XCTAssertTrue(result.foundNoNewBook)
        XCTAssertNil(result.failureSummary, "an alert would follow the batch")
    }

    /// A batch found no new book only when it imported none, nothing in it
    /// failed, and it ran to its end; a cancelled batch, or one with a
    /// failure, has an alert that speaks for it.
    func testABatchFoundNoNewBookOnlyWithNothingImportedFailedOrCancelled() {
        let book = Book(title: "Kept", format: .txt, filePath: "/tmp/kept.txt", md5Hash: "kept")
        let failure = ZipImportFailure(fileName: "bad.epub", message: "unreadable")
        XCTAssertTrue(ZipImportResult(books: [], failures: []).foundNoNewBook)
        XCTAssertTrue(ZipImportResult(books: [], failures: [], skippedDuplicates: 3).foundNoNewBook)
        XCTAssertFalse(ZipImportResult(books: [book], failures: []).foundNoNewBook)
        XCTAssertFalse(ZipImportResult(books: [], failures: [failure]).foundNoNewBook)
        XCTAssertFalse(ZipImportResult(books: [], failures: [], cancellation: .whileExtracting).foundNoNewBook)
    }

    /// A batch reads each book's bytes once for its checksum: the duplicate
    /// check reads it, and the book's own import, given it, knows the book
    /// by it rather than reading the file again, so each book published
    /// carries the checksum the batch read. Until October 10, 2026 each
    /// book of a batch was read twice for it.
    @MainActor
    func testABatchReadsEachBooksChecksumOnce() throws {
        let folder = makeIntegrationLibraryFolder("ZIP Checksum Once")
        let directory = try makeSandboxDirectory("zip-loop-checksum")
        let names = ["Rope Splicing.txt", "Knots.txt"]
        for name in names {
            try Data("\(name)\n\nHow sailors make fast and let go.\n".utf8).write(to: directory.appendingPathComponent(name))
        }
        let reads = CallLog<String>()

        let result = FileImportService.importSupportedFiles(
            names.map { directory.appendingPathComponent($0) },
            toFolder: folder.path,
            checksum: { url in
                reads.record(url.lastPathComponent)
                return "batch checksum of \(url.lastPathComponent)"
            }
        )

        XCTAssertEqual(reads.calls, names, "a book's checksum was not read exactly once")
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(
            result.books.map(\.md5Hash),
            names.map { "batch checksum of \($0)" },
            "a book's import read the file again for its checksum"
        )
    }

    /// A batch's book is timed by its file's size when its text is read
    /// whole as it imports, as an EPUB's, a PDF's, or a plain text's is;
    /// an audiobook's file, whose chapters are read rather than its every
    /// byte, a DAISY book's folder or ZIP, an empty file, and a file that
    /// is not there have no size it is timed by (FR10).
    func testABooksTimedSizeIsItsFilesWhenItsTextIsReadWhole() throws {
        let directory = try makeSandboxDirectory("zip-timed-size")
        let notes = directory.appendingPathComponent("Notes.txt")
        try Data("Ten bytes.".utf8).write(to: notes)
        let guide = directory.appendingPathComponent("Guide.pdf")
        try Data(repeating: 0x25, count: 2_048).write(to: guide)
        let track = directory.appendingPathComponent("Chapter 1.mp3")
        try Data(repeating: 0xFF, count: 4_096).write(to: track)
        let empty = directory.appendingPathComponent("Empty.txt")
        try Data().write(to: empty)
        let folder = directory.appendingPathComponent("Talking Book", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("Talking Book.zip")
        try Data(repeating: 0x50, count: 512).write(to: archive)

        XCTAssertEqual(FileImportService.timedSize(of: notes), 10)
        XCTAssertEqual(FileImportService.timedSize(of: guide), 2_048)
        XCTAssertNil(FileImportService.timedSize(of: track))
        XCTAssertNil(FileImportService.timedSize(of: empty))
        XCTAssertNil(FileImportService.timedSize(of: folder))
        XCTAssertNil(FileImportService.timedSize(of: archive))
        XCTAssertNil(FileImportService.timedSize(of: directory.appendingPathComponent("Missing.epub")))
    }

    /// A book imported alone, and one of a batch whose checksum could not
    /// be read, is read for its checksum by its own import.
    func testAnImportGivenNoChecksumReadsTheFilesOwn() throws {
        let file = try makeSandboxDirectory("zip-loop-no-checksum").appendingPathComponent("Tides.txt")
        try Data("Tides\n\nThe flood runs for six hours.\n".utf8).write(to: file)
        let folder = makeIntegrationLibraryFolder("ZIP Own Checksum")

        let imported = try FileImportService.importFileWithReport(from: file, checksum: nil, toFolder: folder.path)

        XCTAssertEqual(imported.book.md5Hash, try FileImportService.md5Hash(of: file))
    }
}
