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

    /// Empty and duplicate-only results must preserve the source archive,
    /// and the library's alert says why nothing came in.
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

    /// A partial batch is not titled "Error": one that added books but had
    /// a file fail, or was cancelled, says some files were not imported; one
    /// that added nothing says nothing was imported; one whose books only
    /// lack chapters keeps the title of a book imported with something to tell.
    func testAPartialBatchAlertIsNotTitledError() {
        let book = Book(title: "Accepted", format: .txt, filePath: "/tmp/accepted", md5Hash: "hash")
        let failed = [ZipImportFailure(fileName: "failed.epub", message: "unreadable")]
        let cancelled = ZipImportCancellation.afterBooks(completed: 1, total: 3)

        let titles = [
            ImportProgressWording.zipAlertTitle(for: ZipImportResult(books: [book], failures: failed), addedBooks: 1),
            ImportProgressWording.zipAlertTitle(
                for: ZipImportResult(books: [book], failures: [], cancellation: cancelled), addedBooks: 1
            ),
            ImportProgressWording.zipAlertTitle(for: ZipImportResult(books: [], failures: failed), addedBooks: 0),
            ImportProgressWording.zipAlertTitle(
                for: ZipImportResult(books: [book], failures: [], incompleteBooks: failed), addedBooks: 1
            ),
        ]

        XCTAssertEqual(titles, ["Some Files Not Imported", "Some Files Not Imported", "Nothing Imported", "Book Imported"])
        XCTAssertFalse(titles.contains("Error"))
    }

    /// The library's alert after a ZIP batch is titled to agree with its
    /// message, which opens "Imported N book(s), but ...": a plural title for
    /// several books, the singular for one, and a title that says the books
    /// were already there when the library took none of those found.
    @MainActor
    func testAZIPAlertTitleAgreesWithItsMessage() {
        let first = Book(title: "First", format: .txt, filePath: "/tmp/first", md5Hash: UUID().uuidString)
        let second = Book(title: "Second", format: .txt, filePath: "/tmp/second", md5Hash: UUID().uuidString)
        let missing = [
            ZipImportFailure(fileName: "first.epub", message: "missing"),
            ZipImportFailure(fileName: "second.epub", message: "missing"),
        ]
        let failed = [ZipImportFailure(fileName: "failed.epub", message: "unreadable")]
        let original = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).zip")

        // (what the library held, what the batch found, then the title and
        // the start of the message the alert must show)
        let cases: [(held: [Book], result: ZipImportResult, title: String, message: String)] = [
            ([], ZipImportResult(books: [first, second], failures: [], incompleteBooks: missing),
             "Books Imported", "Imported 2 books, but 2 books are missing chapters:"),
            ([], ZipImportResult(books: [first], failures: [], incompleteBooks: [missing[0]]),
             "Book Imported", "Imported 1 book, but 1 book is missing chapters:"),
            ([], ZipImportResult(books: [first, second], failures: failed),
             "Some Files Not Imported", "Imported 2 books, but 1 file failed:"),
            ([first], ZipImportResult(books: [first], failures: [], incompleteBooks: [missing[0]]),
             "Already in Library", "Imported 1 book, but 1 book is missing chapters:"),
        ]
        for (held, result, title, message) in cases {
            // An inert model, as in verifyOriginalHandling.
            let viewModel = LibraryViewModel(initializeServices: false)
            viewModel.library = Library(books: held)

            viewModel.completeZIPImport(result, originalURL: original, folderPath: "")

            XCTAssertEqual(viewModel.errorTitle, title, message)
            XCTAssertTrue(viewModel.errorMessage?.hasPrefix(message) == true, "\(title): \(viewModel.errorMessage ?? "no message")")
        }
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
        // A failure or a book missing chapters raises an error; a batch
        // that imported nothing, and lost nothing, says so under its own
        // title.
        XCTAssertEqual(viewModel.showError, hasFailure || hasIncompleteBook || !hasBook)
        // The alert is never the untitled "Error": it is titled by what
        // the batch brought in and what it left out.
        let expectedTitle: String?
        if !hasBook {
            expectedTitle = "Nothing Imported"
        } else if hasFailure {
            expectedTitle = "Some Files Not Imported"
        } else if hasIncompleteBook {
            expectedTitle = "Book Imported"
        } else {
            expectedTitle = nil
        }
        XCTAssertEqual(viewModel.errorTitle, expectedTitle)
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
    /// book, which the library's alert says, however short it was.
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

    /// A batch that finds no book counts the files it passed over by
    /// extension, in any case, those in an archive inside it too, but not
    /// hidden files or the copies macOS keeps in `__MACOSX`, and its end is
    /// logged whatever it brought. On October 13, 2026 a ZIP of 176 radio
    /// dramas as Ogg files, before TextMouth played Ogg, was extracted,
    /// searched, and removed with nothing logged or shown.
    func testABatchWithoutABookCountsWhatItPassedOverAndLogsItsEnd() throws {
        let inner = try makeTemporaryZip(prefix: "NonBookInner", entries: [
            "cover.jpg": Data("jpeg".utf8),
            "readme": Data("no extension".utf8)
        ])
        defer { try? FileManager.default.removeItem(at: inner) }
        let archive = try makeTemporaryZip(prefix: "NonBookOuter", entries: [
            "Radio/elegy.wma": Data("one".utf8),
            "Radio/two.WMA": Data("two".utf8),
            "Radio/notes.json": Data("{}".utf8),
            "Radio/.hidden.wma": Data("hidden".utf8),
            "__MACOSX/Radio/._elegy.wma": Data("apple double".utf8),
            "Radio/extras.zip": try Data(contentsOf: inner)
        ])
        defer { try? FileManager.default.removeItem(at: archive) }

        let result = try FileImportService.importZip(from: archive)

        XCTAssertTrue(result.foundNoNewBook)
        XCTAssertEqual(result.nonBookFiles.countsByExtension, ["wma": 2, "json": 1, "jpg": 1, "": 1])
        // Each log line starts with a timestamp; compare from the tag on.
        let tag = "\(ZipImportResult.finishedLogTag): \(archive.lastPathComponent): "
        let logged = debugLogLines(containing: tag).compactMap { line in
            line.range(of: tag).map { String(line[$0.lowerBound...]) }
        }
        XCTAssertEqual(logged, [
            tag + "imported=0 duplicates=0 failed=0 incomplete=0 cancelled=false "
                + "notBooks=5 (wma 2, no extension 1, jpg 1, json 1)"
        ])
    }

    /// The library alert's title goes back to "Error" once the alert
    /// closes, so an alert raised next, anywhere, never shows a title meant
    /// for another.
    @MainActor
    func testTheLibraryAlertsTitleIsClearedAsItCloses() {
        let viewModel = LibraryViewModel(initializeServices: false)
        viewModel.errorMessage = "No books were found in “Radio.zip”. It holds no files."
        viewModel.errorTitle = ImportProgressWording.nothingImportedTitle
        viewModel.showError = true
        XCTAssertEqual(viewModel.errorTitle, ImportProgressWording.nothingImportedTitle)

        viewModel.showError = false

        XCTAssertNil(viewModel.errorTitle)
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

    // MARK: - TextMouth Packages

    /// A TextMouth package in an archive is one book, listed as its folder
    /// whatever the capitals of its extension, and nothing inside it is a
    /// book or a file passed over: not its book file, its text cache, or its
    /// record. A plain file named like a package is no book. Until October
    /// 30, 2026 the batch walked into a package and imported its book file
    /// and its text cache as two books, passing its record over.
    func testAPackageInAnArchiveIsOneBookAndNothingInsideIt() throws {
        let directory = try makeSandboxDirectory("zip-package-candidates")
        for name in ["Novel.tmb", "Shouting.TMB"] {
            let package = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data("Chapter one.".utf8).write(to: package.appendingPathComponent("novel.txt"))
            try Data("# Chapter one".utf8).write(to: package.appendingPathComponent("content.md"))
            try Data("{}".utf8).write(to: package.appendingPathComponent("bookInfo.json"))
        }
        try Data("epub".utf8).write(to: directory.appendingPathComponent("other.epub"))
        try Data("not a folder".utf8).write(to: directory.appendingPathComponent("Plain.tmb"))
        let unpacking = NestedArchiveUnpacking(
            directory: try makeSandboxDirectory("zip-package-nested"),
            budget: ArchiveBudget(),
            depth: 1,
            isCancelled: { false },
            progress: nil
        )

        let found = try FileImportService.importCandidates(in: directory, unpacking: unpacking)

        XCTAssertEqual(found.books.map(\.lastPathComponent), ["Novel.tmb", "other.epub", "Shouting.TMB"])
        XCTAssertEqual(found.nonBookFiles.countsByExtension, ["tmb": 1])
        XCTAssertEqual(found.failures, [])
    }

    /// A ZIP holding a TextMouth package, as the Finder's Compress makes of
    /// one, imports one book: the package's own, under its book ID and
    /// title, with its place, at the library's top level as a package opened
    /// from the Finder is, whatever folder the batch imports into. Its book
    /// file and its text cache are no books of their own.
    func testAZippedPackageImportsAsItsOwnBookWithItsPlace() throws {
        var position = ReadingPosition(characterOffset: 12, globalCharacterOffset: 12)
        // Whole seconds, since bookInfo.json stores dates to the second.
        position.lastUpdated = Date(timeIntervalSince1970: 1_790_000_000)
        let package = try makeTextPackage(named: "Novel.tmb", title: "Chain Lines", position: position)
        removeLibraryCopiesAfterTheTest(of: package.bookID)
        let archive = try zipped(package.url)
        let folder = makeIntegrationLibraryFolder("ZIP Package Folder")

        let result = try FileImportService.importZip(from: archive, toFolder: folder.path)

        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(result.books.map(\.id), [package.bookID])
        let book = try XCTUnwrap(result.books.first)
        XCTAssertEqual(book.title, "Chain Lines")
        XCTAssertEqual(book.readingPosition, position)
        XCTAssertEqual(book.folderPath, "")
        XCTAssertEqual(book.tmbDirectory.deletingLastPathComponent().path, TextMouthPaths.libraryDir.path)
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).metadata.bookID, package.bookID)
    }

    /// A zipped package whose book the library already lists, by its ID (as
    /// Replace Existing's old copy records its replacement's, and a feed
    /// item's package its item's) or by its checksum, is skipped as a
    /// duplicate: no failure, and no copy of it in the library.
    func testAZippedPackageOfAListedBookIsSkippedByItsIDOrItsChecksum() throws {
        let package = try makeTextPackage(named: "Listed.tmb", title: "Gear Inches")
        removeLibraryCopiesAfterTheTest(of: package.bookID)
        let archive = try zipped(package.url)
        let checksum = try BookInfo.load(from: package.url).metadata.md5Hash

        let byID = try FileImportService.importZip(from: archive, existingBookIDs: [package.bookID])
        let byChecksum = try FileImportService.importZip(from: archive, existingHashes: [checksum])

        for result in [byID, byChecksum] {
            XCTAssertEqual(result.books, [])
            XCTAssertEqual(result.failures, [])
            XCTAssertEqual(result.skippedDuplicates, 1)
        }
        XCTAssertEqual(Self.libraryCopies(of: package.bookID), [])
    }

    /// The library's ZIP import skips a package of a book it lists under the
    /// same ID and another checksum, as Replace Existing's old copy is: the
    /// library keeps its one row of the book, its alert says nothing new
    /// came in, and no copy of the package is made.
    @MainActor
    func testTheLibrarysZIPImportNeverListsAPackagesBookTwice() throws {
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        useAfterImportingBehavior(.askEachTime)
        let package = try makeTextPackage(named: "Old Copy.tmb", title: "Derailleur Hanger")
        removeLibraryCopiesAfterTheTest(of: package.bookID)
        let archive = try zipped(package.url)
        let folder = makeIntegrationLibraryFolder("ZIP Listed Package")
        let listed = Book(
            id: package.bookID,
            title: "Derailleur Hanger",
            format: .txt,
            filePath: "/nowhere/replacement.txt",
            md5Hash: "replacement checksum"
        )
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [listed])

        model.importZipAsync(from: archive, toFolder: folder.path)

        XCTAssertTrue(waitUntil(timeout: 20) { model.showError }, "no alert followed the import")
        XCTAssertEqual(model.errorTitle, ImportProgressWording.nothingImportedTitle, model.errorMessage ?? "")
        XCTAssertEqual(model.library.books.map(\.id), [listed.id])
        XCTAssertEqual(model.library.books.map(\.md5Hash), [listed.md5Hash])
        XCTAssertEqual(Self.libraryCopies(of: package.bookID), [])
    }

    /// A package in an archive that cannot be identified, its record missing
    /// and no removal marker in its place, is one failure named by the
    /// package, so the archive is kept, and nothing inside it is imported
    /// on its own.
    func testAZippedPackageThatCannotBeIdentifiedIsOneFailure() throws {
        let archive = try makeTemporaryZip(prefix: "BrokenPackage", entries: [
            "Broken.tmb/novel.txt": Data("Chapter one.".utf8),
            "Broken.tmb/content.md": Data("# Chapter one".utf8)
        ])
        addTeardownBlock { try? FileManager.default.removeItem(at: archive) }

        let result = try FileImportService.importZip(from: archive)
        let imported = result.books.map(\.tmbDirectory)
        addTeardownBlock { imported.forEach { try? FileManager.default.removeItem(at: $0) } }

        XCTAssertEqual(result.books, [])
        XCTAssertEqual(result.failures.map(\.fileName), ["Broken.tmb"])
        XCTAssertTrue(
            result.failures.first?.message.hasPrefix("Checking the package failed:") == true,
            "\(result.failures)"
        )
        XCTAssertTrue(result.keepsOriginal)
    }

    /// An archive's entry lies in a TextMouth package when a folder on its
    /// path is named .tmb, in any capitals: never for a file named so, nor
    /// for a folder whose name only holds it.
    func testAnArchiveEntryLiesInAPackageWhenAFolderOnItsPathIsOne() {
        XCTAssertTrue(FileImportService.liesInTMBPackage("Novel.tmb/bookInfo.json"))
        XCTAssertTrue(FileImportService.liesInTMBPackage("Shelf/Novel.TMB/audio/01.mp3"))
        XCTAssertTrue(FileImportService.liesInTMBPackage("Novel.tmb/"))
        XCTAssertFalse(FileImportService.liesInTMBPackage("Novel.tmb"))
        XCTAssertFalse(FileImportService.liesInTMBPackage("Shelf/Novel.tmb.d/notes.txt"))
        XCTAssertFalse(FileImportService.liesInTMBPackage("Shelf/notes.txt"))
    }

    /// A ZIP of an audiobook's package, its tracks beside its record and no
    /// text cache, is no audio ZIP: it reaches the batch, which imports it
    /// as the package, under its book ID, rather than its tracks as a new
    /// audiobook without its record. The same track zipped in a plain
    /// folder is an audio ZIP, as before.
    func testAZippedAudiobookPackageReachesTheBatchAsItsOwnBook() throws {
        let package = try makeAudioPackage(named: "Cadence Drills.tmb", title: "Cadence Drills")
        removeLibraryCopiesAfterTheTest(of: package.bookID)
        let archive = try zipped(package.url)
        let track = try Data(contentsOf: package.url.appendingPathComponent("audio/01.wav"))
        let plainTracks = try makeTemporaryZip(prefix: "PlainTracks", entries: ["Cadence Drills/01.wav": track])
        addTeardownBlock { try? FileManager.default.removeItem(at: plainTracks) }

        XCTAssertTrue(LibraryViewModel.isAudioZip(url: plainTracks))
        XCTAssertFalse(LibraryViewModel.isAudioZip(url: archive))
        let result = try FileImportService.importZip(from: archive)

        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(result.books.map(\.id), [package.bookID])
        XCTAssertEqual(result.books.map(\.format), [.audio])
    }

    /// A ZIP of a DAISY book's package is no DAISY ZIP: it reaches the
    /// batch, which imports it as the package, under its book ID, rather
    /// than as a new DAISY book without its record. The same book zipped in
    /// a plain folder is a DAISY ZIP, as before.
    func testAZippedDAISYBookPackageReachesTheBatchAsItsOwnBook() throws {
        let package = try makeDAISYPackage(named: "Rope Splicing.tmb")
        removeLibraryCopiesAfterTheTest(of: package.bookID)
        let archive = try zipped(package.url)
        let plainBook = try makeTemporaryZip(
            prefix: "PlainDAISY",
            entries: DAISYPackageFixtures.entries(DAISYPackageFixtures.navigationBook, inFolder: "Rope Splicing")
                .mapValues { Data($0.utf8) }
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: plainBook) }

        XCTAssertTrue(DAISYParser.isDAISYZip(url: plainBook))
        XCTAssertFalse(DAISYParser.isDAISYZip(url: archive))
        let result = try FileImportService.importZip(from: archive)

        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(result.books.map(\.id), [package.bookID])
        XCTAssertEqual(result.books.map(\.format), [.daisy])
    }

    // MARK: - Package Fixtures

    /// A TextMouth package of a text book named `name` in a new sandbox
    /// folder, as an import leaves one: the book's document, its text cache,
    /// and a record naming the book `title` with `position`.
    private func makeTextPackage(
        named name: String,
        title: String,
        position: ReadingPosition? = nil
    ) throws -> (url: URL, bookID: UUID) {
        let package = try makePackageFolder(named: name)
        let document = package.appendingPathComponent("novel.txt")
        try Data("\(title)\n\nThe chain runs straight from the middle ring to the middle cog.\n".utf8).write(to: document)
        try Data("# \(title)\n".utf8).write(to: TextMouthPaths.contentMarkdownPath(in: package))
        let bookID = try writeRecord(
            in: package,
            title: title,
            format: .txt,
            fileName: document.lastPathComponent,
            checksum: try FileImportService.md5Hash(of: document),
            position: position
        )
        return (package, bookID)
    }

    /// A TextMouth package of an audiobook named `name` in a new sandbox
    /// folder, as an import leaves one: a folder of one silent track beside
    /// a record naming the book `title`, and no text cache, which an
    /// audiobook never has. A folder of tracks has no checksum of its own,
    /// so the record keeps one unique to the book, as an audio archive's
    /// import records the archive's.
    private func makeAudioPackage(named name: String, title: String) throws -> (url: URL, bookID: UUID) {
        let package = try makePackageFolder(named: name)
        let tracks = package.appendingPathComponent("audio", isDirectory: true)
        try AudioTestFixtures.writeSilence(to: tracks.appendingPathComponent("01.wav"))
        let bookID = try writeRecord(
            in: package,
            title: title,
            format: .audio,
            fileName: tracks.lastPathComponent,
            checksum: "archive-\(UUID().uuidString)"
        )
        return (package, bookID)
    }

    /// A TextMouth package of a DAISY 2.02 book named `name` in a new
    /// sandbox folder: the book's files laid out as its folder holds them,
    /// its navigation file made unique to this test, so that no package
    /// another test left behind holds the same content, and a record naming
    /// the book by that file's checksum, as an import of its folder does.
    private func makeDAISYPackage(named name: String) throws -> (url: URL, bookID: UUID) {
        let navigation = (DAISYPackageFixtures.navigationBook["ncc.html"] ?? "")
            .replacingOccurrences(of: "<title>", with: "<!-- \(UUID().uuidString) -->\n<title>")
        let package = try DAISYPackageFixtures.writeFolder(
            DAISYPackageFixtures.files(DAISYPackageFixtures.navigationBook, changing: ["ncc.html": navigation]),
            named: name,
            in: try makeSandboxDirectory("zip-package")
        )
        let navigationFile = package.appendingPathComponent("ncc.html")
        let bookID = try writeRecord(
            in: package,
            title: "Notes on Rope Splicing",
            format: .daisy,
            fileName: navigationFile.lastPathComponent,
            checksum: try FileImportService.md5Hash(of: navigationFile)
        )
        return (package, bookID)
    }

    /// A new, empty folder named `name`, for a package, inside a sandbox
    /// folder of its own.
    private func makePackageFolder(named name: String) throws -> URL {
        let package = try makeSandboxDirectory("zip-package").appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        return package
    }

    /// Writes into `package` the record an import leaves there for the book
    /// `title`, whose own file or folder there is `fileName`, of `format`,
    /// known by `checksum`, at `position`. Returns the book's new ID.
    private func writeRecord(
        in package: URL,
        title: String,
        format: BookFormat,
        fileName: String,
        checksum: String,
        position: ReadingPosition? = nil
    ) throws -> UUID {
        let bookID = UUID()
        let info = BookInfo(
            metadata: BookMetadata(
                title: title,
                author: "Workshop Notes",
                format: format,
                md5Hash: checksum,
                originalFileName: fileName,
                bookID: bookID
            ),
            state: BookState(readingPosition: position, tmbDirectoryName: package.lastPathComponent)
        )
        try info.save(to: package)
        return bookID
    }

    /// A ZIP archive holding every file in `package`, at any depth, under
    /// the package's own name, as the Finder's Compress makes of it,
    /// removed after the test.
    private func zipped(_ package: URL) throws -> URL {
        var entries: [String: Data] = [:]
        for relativePath in try FileManager.default.subpathsOfDirectory(atPath: package.path) {
            let item = package.appendingPathComponent(relativePath)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isFolder), !isFolder.boolValue else {
                continue
            }
            entries["\(package.lastPathComponent)/\(relativePath)"] = try Data(contentsOf: item)
        }
        let archive = try makeTemporaryZip(prefix: "ZippedPackage", entries: entries)
        addTeardownBlock { try? FileManager.default.removeItem(at: archive) }
        return archive
    }

    /// The packages at the library's top level named for the book `bookID`,
    /// as a package's import names the copy it makes there.
    private static func libraryCopies(of bookID: UUID) -> [URL] {
        let library = TextMouthPaths.libraryDir
        let names = (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
        return names
            .filter { $0.hasSuffix("\(bookID.uuidString.lowercased()).tmb") }
            .map { library.appendingPathComponent($0, isDirectory: true) }
    }

    /// Removes, once the test ends, every copy of the book `bookID`'s
    /// package an import made at the library's top level.
    private func removeLibraryCopiesAfterTheTest(of bookID: UUID) {
        addTeardownBlock {
            ZIPImportTests.libraryCopies(of: bookID).forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }
}
