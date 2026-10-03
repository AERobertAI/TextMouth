import XCTest
import ZIPFoundation
@testable import TextMouth

/// A ZIP batch extracts its archive, and the archives found inside it, within
/// one budget (TODO I05). An archive past the limits is refused before
/// anything of it is written, one whose sizes lie is stopped at its first
/// excess byte, and either way nothing is imported, the source is untouched,
/// and nothing is left extracted. An archive inside that cannot be searched,
/// or lies deeper than the batch unpacks, is reported, so the original is
/// kept. Each test imports into a library folder of its own, removed when it
/// ends, with small limits bound where it needs them.
final class ArchiveImportBoundsTests: XCTestCase {
    /// The library folder this test imports into.
    private var folderPath: String!
    /// Where this test's archives are written, outside the library.
    private var sources: URL!

    override func setUpWithError() throws {
        folderPath = "Archive Bounds \(UUID().uuidString.prefix(8))"
        sources = try makeSandboxDirectory("archive-bounds-sources")
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        if let folderPath {
            try? FileManager.default.removeItem(at: TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true))
        }
    }

    // MARK: - Within the Budget

    /// A batch within the standard budget imports every book as before,
    /// those in the archive inside it included, reports nothing, and leaves
    /// nothing extracted.
    func testBatchWithinItsBudgetImportsEveryBook() throws {
        let inner = try makeArchive("Inner", [TestZIPEntry("Tides.txt", Self.notes("tides"))])
        let archive = try makeArchive("Library Export", [
            TestZIPEntry("Rope Splicing.txt", Self.notes("rope")),
            TestZIPEntry("Shelf/Knots.txt", Self.notes("knots")),
            TestZIPEntry("Collection.zip", try Data(contentsOf: inner))
        ])

        let result = try importBatch(archive)

        XCTAssertEqual(Set(result.books.map(\.title)), ["Rope Splicing", "Knots", "Tides"])
        XCTAssertEqual(result.failures, [])
        XCTAssertNil(result.failureSummary)
        XCTAssertEqual(try folderEntries(), Set(result.books.map(\.tmbDirectoryName)))
        XCTAssertEqual(leftoverExtractionDirectories(), [])
    }

    // MARK: - Refused Before Extraction

    /// An archive declaring more than the limit is refused whole, the reason
    /// stating its total and the limit.
    func testDeclaredTotalPastTheLimitRefusesTheBatch() throws {
        let archive = try makeArchive("Tide Tables", [
            TestZIPEntry("January.txt", Data(count: 800)),
            TestZIPEntry("February.txt", Data(count: 800))
        ])

        assertBatchFails(
            archive,
            limits: ArchiveBudgetTests.limits(other: 1_000),
            because: "The archive expands to \(ArchiveFigures.size(1_600)), more than the "
                + "\(ArchiveFigures.size(1_000)) TextMouth extracts from archives without audio."
        )
    }

    /// An archive holding more entries than the limit is refused whole, the
    /// reason stating its count and the limit.
    func testEntryCountPastTheLimitRefusesTheBatch() throws {
        let archive = try makeArchive("Pamphlets", (1...3).map { TestZIPEntry("Pamphlet \($0).txt", Self.notes("pamphlet \($0)")) })

        assertBatchFails(
            archive,
            limits: ArchiveBudgetTests.limits(entries: 2),
            because: "The archive holds 3 files and folders, more than the 2 TextMouth extracts in one import."
        )
    }

    /// An archive that would leave less than the reserve free on the disk
    /// holding the library is refused whole, the reason stating what it
    /// needs, what is free, and the reserve. The disk asked is the one the
    /// archive extracts to, in the data directory.
    func testShortageOfFreeSpaceRefusesTheBatch() throws {
        let archive = try makeArchive("Harbor Charts", [TestZIPEntry("Charts.txt", Data(count: 600))])
        let extractionFolder = ArchiveExtractionDirectory.defaultParent.path

        assertBatchFails(
            archive,
            limits: ArchiveBudgetTests.limits(reserve: 1_000, freeSpace: { $0.path.hasPrefix(extractionFolder) ? 1_500 : nil }),
            because: "The archive expands to \(ArchiveFigures.size(600)), but the disk holding the TextMouth library "
                + "has only \(ArchiveFigures.size(1_500)) free, and TextMouth keeps \(ArchiveFigures.size(1_000)) "
                + "of it free. Free up space, then import it again."
        )
    }

    /// Archives inside count toward the batch's totals: one that takes the
    /// total past the limit refuses the whole batch, before any book is
    /// imported.
    func testArchivesInsideCountTowardTheBatchBudget() throws {
        let inner = try makeArchive("Inner", [
            TestZIPEntry("Tides.txt", Data(count: 800)),
            TestZIPEntry("Currents.txt", Data(count: 800))
        ])
        let innerBytes = try Data(contentsOf: inner)
        let archive = try makeArchive("Library Export", [
            TestZIPEntry("Rope Splicing.txt", Data(count: 300)),
            TestZIPEntry("Collection.zip", innerBytes)
        ])
        // The archive holds another, so the limit for archives holding
        // archives applies; it fits on its own, but not with what is inside.
        let total = Int64(300 + innerBytes.count + 1_600)
        let limit = total - 1

        assertBatchFails(
            archive,
            limits: ArchiveBudgetTests.limits(audio: limit),
            because: "Together with the archives inside it, the archive expands to \(ArchiveFigures.size(total)), "
                + "more than the \(ArchiveFigures.size(limit)) TextMouth extracts from archives holding audio or other archives."
        )
    }

    // MARK: - Stopped During Extraction

    /// An archive whose recorded size lies is stopped at the first excess
    /// chunk, naming the file, and the whole batch fails.
    func testLyingArchiveStopsTheBatch() throws {
        let archive = try makeArchive("Ferry Notes", [
            TestZIPEntry("Rope Splicing.txt", Self.notes("rope")),
            TestZIPEntry("Flood.txt", Data(repeating: 0x61, count: 200_000))
        ], compression: .deflate)
        try setRecordedSize(of: "Flood.txt", in: archive, to: 10)

        assertBatchFails(
            archive,
            because: "The file “Flood.txt” in this archive is damaged or incomplete: it holds more than the "
                + "\(ArchiveFigures.size(10)) the archive records for it. Get a fresh copy of the archive, then import it again."
        )
    }

    /// An archive with a file whose path climbs out of it is refused whole,
    /// and nothing appears outside its extraction.
    func testArchiveLeadingOutsideIsRefusedAndNothingEscapes() throws {
        let escapeName = "escape-\(UUID().uuidString).txt"
        let archive = try makeArchive("Mixed Bag", [
            TestZIPEntry("Rope Splicing.txt", Self.notes("rope")),
            TestZIPEntry("../\(escapeName)", Self.notes("escape"))
        ])

        assertBatchFails(
            archive,
            because: "The archive holds a file whose path leads outside it, which is never extracted."
        )
        let extractionFolder = ArchiveExtractionDirectory.defaultParent
        XCTAssertFalse(FileManager.default.fileExists(atPath: extractionFolder.appendingPathComponent(escapeName).path))
    }

    // MARK: - Archives Inside That Cannot Be Searched

    /// An archive more than one level inside is reported, not searched, so
    /// its books are never passed over in silence; the books above it import.
    func testArchivesDeeperThanTheNestingLimitAreReportedNotSearched() throws {
        let deepest = try makeArchive("Deepest", [TestZIPEntry("Currents.txt", Self.notes("currents"))])
        let middle = try makeArchive("Middle", [
            TestZIPEntry("Tides.txt", Self.notes("tides")),
            TestZIPEntry("Level Two.zip", try Data(contentsOf: deepest))
        ])
        let archive = try makeArchive("Library Export", [
            TestZIPEntry("Rope Splicing.txt", Self.notes("rope")),
            TestZIPEntry("Level One.zip", try Data(contentsOf: middle))
        ])

        let result = try importBatch(archive)

        XCTAssertEqual(Set(result.books.map(\.title)), ["Rope Splicing", "Tides"])
        XCTAssertEqual(result.failures, [ZipImportFailure(
            fileName: "Level Two.zip",
            message: "Not extracted: TextMouth extracts archives within an archive only 1 level deep."
        )])
        XCTAssertTrue(
            result.failureSummary?.contains("Level Two.zip: Not extracted: ") == true,
            result.failureSummary ?? "no summary"
        )
        XCTAssertEqual(try folderEntries(), Set(result.books.map(\.tmbDirectoryName)))
        XCTAssertEqual(leftoverExtractionDirectories(), [])
    }

    /// A damaged archive inside is reported by name while the other books
    /// import, where it was once passed over in silence.
    func testDamagedArchiveInsideIsReportedWhileTheOthersImport() throws {
        let archive = try makeArchive("Library Export", [
            TestZIPEntry("Rope Splicing.txt", Self.notes("rope")),
            TestZIPEntry("Torn Download.zip", Data("not a ZIP archive".utf8))
        ])

        let result = try importBatch(archive)

        XCTAssertEqual(result.books.map(\.title), ["Rope Splicing"])
        XCTAssertEqual(result.failures, [ZipImportFailure(
            fileName: "Torn Download.zip",
            message: "Extracting the archive failed: The archive is damaged, incomplete, or not a ZIP archive."
        )])
        XCTAssertEqual(leftoverExtractionDirectories(), [])
    }

    /// An archive inside whose recorded size lies is stopped and reported by
    /// name, naming its file, while the other books import.
    func testLyingArchiveInsideIsReportedWhileTheOthersImport() throws {
        let inner = try makeArchive("Inner", [TestZIPEntry("Flood.txt", Data(repeating: 0x61, count: 200_000))], compression: .deflate)
        try setRecordedSize(of: "Flood.txt", in: inner, to: 10)
        let archive = try makeArchive("Library Export", [
            TestZIPEntry("Rope Splicing.txt", Self.notes("rope")),
            TestZIPEntry("Collection.zip", try Data(contentsOf: inner))
        ])

        let result = try importBatch(archive)

        XCTAssertEqual(result.books.map(\.title), ["Rope Splicing"])
        XCTAssertEqual(result.failures, [ZipImportFailure(
            fileName: "Collection.zip",
            message: "Extracting the archive failed: The file “Flood.txt” in this archive is damaged or incomplete: "
                + "it holds more than the \(ArchiveFigures.size(10)) the archive records for it. "
                + "Get a fresh copy of the archive, then import it again."
        )])
        XCTAssertEqual(leftoverExtractionDirectories(), [])
    }

    // MARK: - Progress and Cancellation

    /// The batch tells its extraction, the entries done of the total, before
    /// its first book, an archive inside under that archive's own name, and
    /// then each book imported of the total found.
    func testExtractionProgressComesBeforeTheFirstBook() throws {
        let inner = try makeArchive("Inner", [TestZIPEntry("Tides.txt", Self.notes("tides"))])
        let archive = try makeArchive("Library Export", [
            TestZIPEntry("Rope Splicing.txt", Self.notes("rope")),
            TestZIPEntry("Collection.zip", try Data(contentsOf: inner))
        ])
        var reports: [ZipImportProgress] = []

        _ = try FileImportService.importZip(from: archive, toFolder: folderPath, progress: { reports.append($0) })

        let name = archive.lastPathComponent
        XCTAssertEqual(reports, [
            .extracting(archive: name, done: 0, total: 2),
            .extracting(archive: name, done: 1, total: 2),
            .extracting(archive: name, done: 2, total: 2),
            .extracting(archive: "Collection.zip", done: 0, total: 1),
            .extracting(archive: "Collection.zip", done: 1, total: 1),
            .importing(done: 1, total: 2),
            .importing(done: 2, total: 2)
        ])
    }

    /// Cancelling while the archive is extracted stops before any book:
    /// nothing is imported or left extracted, the summary says where the
    /// batch stopped and that the original was kept, and the cancellation is
    /// logged, not as a failure.
    func testCancellingWhileExtractingImportsNothing() throws {
        let archive = try makeArchive("Library Export", (1...4).map { TestZIPEntry("Book \($0).txt", Self.notes("book \($0)")) })
        let cancellation = ImportCancellation()

        let result = try FileImportService.importZip(
            from: archive,
            toFolder: folderPath,
            progress: { progress in
                if case .extracting(archive: _, done: 2, total: _) = progress { cancellation.cancel() }
            },
            isCancelled: cancellation.check
        )

        XCTAssertEqual(result.cancellation, .whileExtracting)
        XCTAssertEqual(result.books, [])
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(
            result.failureSummary,
            "Import cancelled while extracting the archive, before any book was imported.\nThe original file was kept."
        )
        XCTAssertEqual(try folderEntries(), [])
        XCTAssertEqual(leftoverExtractionDirectories(), [])
        XCTAssertEqual(debugLogLines(containing: "IMPORT_CANCELLED: \(archive.lastPathComponent): while extracting the archive").count, 1)
        XCTAssertEqual(debugLogLines(containing: "IMPORT_FAILED: \(archive.lastPathComponent)").count, 0)
    }

    /// Cancelling while an archive inside is extracted stops the batch the
    /// same way, before any book.
    func testCancellingWhileAnArchiveInsideIsExtractedImportsNothing() throws {
        let inner = try makeArchive("Inner", (1...3).map { TestZIPEntry("Tide \($0).txt", Self.notes("tide \($0)")) })
        let archive = try makeArchive("Library Export", [
            TestZIPEntry("Rope Splicing.txt", Self.notes("rope")),
            TestZIPEntry("Collection.zip", try Data(contentsOf: inner))
        ])
        let cancellation = ImportCancellation()

        let result = try FileImportService.importZip(
            from: archive,
            toFolder: folderPath,
            progress: { progress in
                if case .extracting(archive: "Collection.zip", done: 1, total: _) = progress { cancellation.cancel() }
            },
            isCancelled: cancellation.check
        )

        XCTAssertEqual(result.cancellation, .whileExtracting)
        XCTAssertEqual(result.books, [])
        XCTAssertEqual(try folderEntries(), [])
        XCTAssertEqual(leftoverExtractionDirectories(), [])
    }

    /// Cancelling between books stops before the next one and keeps those
    /// already imported: the summary says after how many of how many the
    /// batch stopped, and nothing is left staged or extracted.
    func testCancellingBetweenBooksKeepsTheBooksAlreadyImported() throws {
        let archive = try makeArchive("Library Export", (1...3).map { TestZIPEntry("Book \($0).txt", Self.notes("book \($0)")) })
        let cancellation = ImportCancellation()

        let result = try FileImportService.importZip(
            from: archive,
            toFolder: folderPath,
            progress: { progress in
                if progress == .importing(done: 1, total: 3) { cancellation.cancel() }
            },
            isCancelled: cancellation.check
        )

        XCTAssertEqual(result.cancellation, .afterBooks(completed: 1, total: 3))
        XCTAssertEqual(result.books.map(\.title), ["Book 1"])
        XCTAssertEqual(result.failureSummary, "Import cancelled after 1 of 3 books. Imported 1 book.\nThe original file was kept.")
        XCTAssertEqual(try folderEntries(), Set(result.books.map(\.tmbDirectoryName)))
        XCTAssertEqual(leftoverExtractionDirectories(), [])
        XCTAssertEqual(debugLogLines(containing: "IMPORT_CANCELLED: \(archive.lastPathComponent): after 1 of 3 books").count, 1)
    }

    /// A cancelled batch's summary starts with where it stopped, lists its
    /// failures as before, and says the original was kept; a batch that ran
    /// to its end in full still has none.
    func testSummaryOfACancelledBatch() {
        let book = Book(title: "Rope Splicing", format: .txt, filePath: "/tmp/rope.txt", md5Hash: "a")
        let failure = ZipImportFailure(fileName: "Knots.docx", message: "Reading its text failed: unreadable")

        XCTAssertEqual(
            ZipImportResult(books: [book], failures: [failure], cancellation: .afterBooks(completed: 2, total: 5)).failureSummary,
            "Import cancelled after 2 of 5 books. Imported 1 book, but 1 file failed:\n"
                + "Knots.docx: Reading its text failed: unreadable\nThe original file was kept."
        )
        XCTAssertEqual(
            ZipImportResult(books: [], failures: [], cancellation: .afterBooks(completed: 0, total: 1)).failureSummary,
            "Import cancelled after 0 of 1 book. Imported 0 books.\nThe original file was kept."
        )
        XCTAssertNil(ZipImportResult(books: [book], failures: []).failureSummary)
    }

    /// The import overlay's bar counts books, so while an archive is
    /// extracted it is left indeterminate and the message counts the items
    /// extracted; once books import, both count books, as before.
    func testOverlayShowsExtractionThenBooks() {
        let extracting = LibraryViewModel.overlayProgress(for: .extracting(archive: "Library Export.zip", done: 37, total: 120))
        let importing = LibraryViewModel.overlayProgress(for: .importing(done: 3, total: 10))

        XCTAssertEqual(extracting.current, 0)
        XCTAssertEqual(extracting.total, 0)
        XCTAssertEqual(extracting.message, "Extracting “Library Export.zip”: 37 of 120 items...")
        XCTAssertEqual(importing.current, 3)
        XCTAssertEqual(importing.total, 10)
        XCTAssertEqual(importing.message, "Importing book 3 of 10...")
    }

    // MARK: - Cancelling in the Library

    /// The original ZIP is kept when a file in it failed, a book from it is
    /// missing chapters, or the batch was cancelled; otherwise the "After
    /// Importing a Book" preference decides.
    func testOriginalIsKeptForFailuresMissingChaptersAndCancellation() {
        let failure = ZipImportFailure(fileName: "Knots.docx", message: "unreadable")

        XCTAssertFalse(ZipImportResult(books: [], failures: []).keepsOriginal)
        XCTAssertTrue(ZipImportResult(books: [], failures: [failure]).keepsOriginal)
        XCTAssertTrue(ZipImportResult(books: [], failures: [], incompleteBooks: [failure]).keepsOriginal)
        XCTAssertTrue(ZipImportResult(books: [], failures: [], cancellation: .whileExtracting).keepsOriginal)
    }

    /// The library adds the books a cancelled batch imported, says where the
    /// batch stopped, and keeps the archive although the preference says to
    /// delete it.
    @MainActor
    func testLibraryKeepsTheArchiveOfACancelledBatch() throws {
        let sandbox = try LibraryIndexSandbox.capture()
        defer { sandbox.restore() }
        let archive = try makeArchive("Library Export", [TestZIPEntry("Rope Splicing.txt", Self.notes("rope"))])
        let book = Book(title: "Rope Splicing", format: .txt, filePath: "/tmp/rope.txt", md5Hash: UUID().uuidString)
        let result = ZipImportResult(books: [book], failures: [], cancellation: .afterBooks(completed: 1, total: 3))
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()

        withImportDeleteBehavior(.deleteAfterImport) {
            withTrashPreference(movesToTrash: false) {
                model.completeZIPImport(result, originalURL: archive, folderPath: folderPath)
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertEqual(model.library.books.map(\.id), [book.id])
        XCTAssertTrue(model.showError)
        XCTAssertEqual(model.errorMessage, "Import cancelled after 1 of 3 books. Imported 1 book.\nThe original file was kept.")
    }

    /// A ZIP import waiting in the queue when the reader cancels never
    /// starts: nothing is imported or reported, the archive is kept, and the
    /// cancellation is logged.
    @MainActor
    func testZIPImportWaitingWhenCancelledNeverStarts() throws {
        let sandbox = try LibraryIndexSandbox.capture()
        defer { sandbox.restore() }
        let archive = try makeArchive("Library Export", [TestZIPEntry("Rope Splicing.txt", Self.notes("rope"))])
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        // The queue is held while the import is queued and cancelled.
        let gate = DispatchSemaphore(value: 0)
        model.importOperationQueue.enqueue { gate.wait() }

        model.importZipAsync(from: archive, toFolder: folderPath)
        model.cancelImports()
        gate.signal()
        drainImportQueue(of: model)

        XCTAssertEqual(model.library.books, [])
        XCTAssertFalse(model.showError, model.errorMessage ?? "")
        XCTAssertEqual(try folderEntries(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertEqual(debugLogLines(containing: "IMPORT_CANCELLED: \(archive.lastPathComponent): before it started").count, 1)
    }

    /// A ZIP import queued after a cancel is not reached by it and imports
    /// as usual.
    @MainActor
    func testZIPImportQueuedAfterACancelRuns() throws {
        let sandbox = try LibraryIndexSandbox.capture()
        defer { sandbox.restore() }
        let archive = try makeArchive("Library Export", [TestZIPEntry("Rope Splicing.txt", Self.notes("rope"))])
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()

        model.cancelImports()
        withImportDeleteBehavior(.keepOriginal) {
            model.importZipAsync(from: archive, toFolder: folderPath)
            drainImportQueue(of: model)
        }

        XCTAssertEqual(model.library.books.map(\.title), ["Rope Splicing"])
        XCTAssertFalse(model.showError, model.errorMessage ?? "")
        XCTAssertEqual(try folderEntries(), Set(model.library.books.map(\.tmbDirectoryName)))
    }

    // MARK: - Startup

    /// At startup the library removes, in the background, the extraction
    /// directory an interrupted import of a process no longer running left
    /// in the data directory, with everything in it, and logs the removal.
    @MainActor
    func testStartupRemovesLeftoverExtractionDirectories() throws {
        let leftover = try makeLeftoverExtraction()
        let sandbox = try LibraryIndexSandbox.capture()
        defer { sandbox.restore() }
        let logLine = "ARCHIVE_EXTRACTION_REMOVED: \(leftover.path): left by an interrupted import"

        _ = LibraryViewModel()

        XCTAssertTrue(
            eventually(within: 20) {
                !FileManager.default.fileExists(atPath: leftover.path) && debugLogLines(containing: logLine).count == 1
            },
            "the leftover extraction was not removed and logged"
        )
    }

    // MARK: - Audio Archives

    /// An audio archive past its budget is refused before anything is
    /// written into its package, the reason stating its total and the limit.
    func testAudioArchivePastItsBudgetIsRefused() throws {
        let tracks = [try silence(seconds: 1), try silence(seconds: 1)]
        let archive = try makeArchive("Lecture Series", [TestZIPEntry("01.wav", tracks[0]), TestZIPEntry("02.wav", tracks[1])])
        let declared = Int64(tracks[0].count + tracks[1].count)
        let limits = ArchiveBudgetTests.limits(audio: declared - 1)

        assertImportFails(
            archive,
            at: .extractingArchive,
            because: "The archive expands to \(ArchiveFigures.size(declared)), more than the "
                + "\(ArchiveFigures.size(declared - 1)) TextMouth extracts from archives holding audio or other archives."
        ) {
            _ = try withLimits(limits) { try FileImportService.importAudioZipWithReport(from: archive, toFolder: folderPath) }
        }
    }

    /// An audio archive whose recorded size lies is stopped at the first
    /// excess chunk, naming the track, and nothing is published.
    func testLyingAudioArchiveIsStoppedNamingTheTrack() throws {
        let archive = try makeArchive("Lecture Series", [TestZIPEntry("01.wav", try silence(seconds: 1))], compression: .deflate)
        try setRecordedSize(of: "01.wav", in: archive, to: 10)

        assertImportFails(
            archive,
            at: .extractingArchive,
            because: "The file “01.wav” in this archive is damaged or incomplete: it holds more than the "
                + "\(ArchiveFigures.size(10)) the archive records for it. Get a fresh copy of the archive, then import it again."
        ) {
            _ = try FileImportService.importAudioZipWithReport(from: archive, toFolder: folderPath)
        }
    }

    /// A DAISY audio book past its budget is refused before any audio is
    /// converted, the reason stating its total and the limit.
    func testDAISYAudioBookPastItsBudgetIsRefused() throws {
        let book = try makeDAISYAudioBook("Harbor Soundings")
        let limits = ArchiveBudgetTests.limits(audio: book.declared - 1)

        assertImportFails(
            book.archive,
            at: .convertingAudio,
            because: "The archive expands to \(ArchiveFigures.size(book.declared)), more than the "
                + "\(ArchiveFigures.size(book.declared - 1)) TextMouth extracts from archives holding audio or other archives."
        ) {
            _ = try withLimits(limits) {
                try FileImportService.importDAISYAudioZipWithReport(from: book.archive, toFolder: folderPath)
            }
        }
    }

    /// A DAISY audio file whose recorded size lies fails the import, named
    /// in the DAISY damage sentence, although the converter carries on past
    /// an audio file it cannot copy.
    func testDAISYAudioFileLyingAboutItsSizeFailsTheImport() throws {
        let book = try makeDAISYAudioBook("Harbor Soundings", compression: .deflate)
        try setRecordedSize(of: "part1.wav", in: book.archive, to: 10)

        assertImportFails(
            book.archive,
            at: .convertingAudio,
            because: "The file “part1.wav” in this DAISY book is damaged or incomplete: it holds more than the "
                + "\(ArchiveFigures.size(10)) the archive records for it. Get a fresh copy of the book, then import it again."
        ) {
            _ = try FileImportService.importDAISYAudioZipWithReport(from: book.archive, toFolder: folderPath)
        }
    }

    /// A DAISY audio book exactly at its budget still imports.
    func testDAISYAudioBookWithinItsBudgetImports() throws {
        let book = try makeDAISYAudioBook("Harbor Soundings", compression: .deflate)

        let imported = try withLimits(ArchiveBudgetTests.limits(audio: book.declared)) {
            try FileImportService.importDAISYAudioZipWithReport(from: book.archive, toFolder: folderPath)
        }

        XCTAssertEqual(try folderEntries(), [imported.book.tmbDirectoryName])
        XCTAssertEqual(try BookInfo.load(from: imported.book.tmbDirectory).contentIndex?.chapters.map(\.title), ["Leadline Readings"])
    }

    // MARK: - Fixtures

    /// The bytes of a silent WAVE file lasting `seconds`.
    private func silence(seconds: TimeInterval) throws -> Data {
        let file = sources.appendingPathComponent("\(UUID().uuidString).wav")
        try AudioTestFixtures.writeSilence(to: file, duration: seconds)
        return try Data(contentsOf: file)
    }

    /// A DAISY 2.02 talking book as a ZIP archive named `name`.zip: one
    /// heading, read from one SMIL file and a second of silence in one WAVE
    /// file, with the total its entries declare.
    private func makeDAISYAudioBook(
        _ name: String,
        compression: CompressionMethod = .none
    ) throws -> (archive: URL, declared: Int64) {
        let navigation = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head>
        <meta name="dc:title" content="Harbor Soundings"/>
        <meta name="dc:creator" content="Folasade Nyberg"/>
        </head><body>
        <h1 id="h1"><a href="part1.smil#p1">Leadline Readings</a></h1>
        </body></html>
        """
        let smil = """
        <?xml version="1.0" encoding="utf-8"?>
        <smil><body><seq>
        <par id="p1"><text src="text.html#t1"/><audio src="part1.wav" clip-begin="npt=0.000s" clip-end="npt=1.000s"/></par>
        </seq></body></smil>
        """
        let entries = [
            TestZIPEntry("ncc.html", Data(navigation.utf8)),
            TestZIPEntry("part1.smil", Data(smil.utf8)),
            TestZIPEntry("part1.wav", try silence(seconds: 1))
        ]
        let archive = try makeArchive(name, entries, compression: compression)
        return (archive, Int64(entries.map(\.data.count).reduce(0, +)))
    }

    /// A short note about `subject`, readable as a plain-text book.
    private static func notes(_ subject: String) -> Data {
        Data("Notes on \(subject): keep the line dry and coiled after use.".utf8)
    }

    /// An archive named `name`, a short tag of its own, and ".zip", holding
    /// `entries` in order, in this test's sources folder. The tag keeps the
    /// debug log lines naming it this test's own.
    private func makeArchive(_ name: String, _ entries: [TestZIPEntry], compression: CompressionMethod = .none) throws -> URL {
        let made = try makeTemporaryZip(prefix: "ArchiveImportBounds", orderedEntries: entries, compressionMethod: compression)
        let archive = sources.appendingPathComponent("\(name) \(UUID().uuidString.prefix(8)).zip")
        try FileManager.default.moveItem(at: made, to: archive)
        return archive
    }

    /// Runs `body` with `limits` bound, when given.
    private func withLimits<Value>(_ limits: ArchiveLimits?, _ body: () throws -> Value) rethrows -> Value {
        guard let limits else { return try body() }
        return try ArchiveLimits.$current.withValue(limits, operation: body)
    }

    /// Imports the batch `archive` into this test's folder, with `limits`
    /// bound when given.
    private func importBatch(_ archive: URL, limits: ArchiveLimits? = nil) throws -> ZipImportResult {
        try withLimits(limits) {
            try FileImportService.importZip(from: archive, toFolder: folderPath)
        }
    }

    /// Imports the batch `archive`, with `limits` bound when given, and
    /// asserts that it fails while extracting because of `problem` (see
    /// `assertImportFails`).
    @discardableResult
    private func assertBatchFails(
        _ archive: URL,
        limits: ArchiveLimits? = nil,
        because problem: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ImportFailure? {
        assertImportFails(archive, at: .extractingArchive, because: problem, file: file, line: line) {
            _ = try importBatch(archive, limits: limits)
        }
    }

    /// Runs `attempt`, an import of `source`, and asserts that it fails at
    /// `step` because of `problem`: the failure names the source and the
    /// step, the debug log records it once, nothing is left in the folder or
    /// extracted, and the source keeps its bytes.
    @discardableResult
    private func assertImportFails(
        _ source: URL,
        at step: ImportStep,
        because problem: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        attempt: () throws -> Void
    ) -> ImportFailure? {
        let bytes = try? Data(contentsOf: source)
        let reason = "\(step.activity) failed: \(problem)"
        let logLine = "IMPORT_FAILED: \(source.lastPathComponent): \(reason)"
        let logged = debugLogLines(containing: logLine).count
        var failure: ImportFailure?

        XCTAssertThrowsError(try attempt(), file: file, line: line) { error in
            failure = error as? ImportFailure
        }

        XCTAssertEqual(failure?.fileName, source.lastPathComponent, file: file, line: line)
        XCTAssertEqual(failure?.step, step, file: file, line: line)
        XCTAssertEqual(failure?.reason, reason, file: file, line: line)
        XCTAssertEqual(debugLogLines(containing: logLine).count, logged + 1, file: file, line: line)
        XCTAssertEqual((try? folderEntries()) ?? [], [], "left in the library", file: file, line: line)
        XCTAssertEqual(try? Data(contentsOf: source), bytes, "the source must be untouched", file: file, line: line)
        XCTAssertEqual(leftoverExtractionDirectories(), [], "left extracted", file: file, line: line)
        return failure
    }

    /// An extraction directory holding a book, as an interrupted import of a
    /// process that has since exited leaves it in the data directory.
    private func makeLeftoverExtraction() throws -> URL {
        let stopped = Process()
        stopped.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try stopped.run()
        stopped.waitUntilExit()
        let leftover = ArchiveExtractionDirectory.defaultParent.appendingPathComponent(
            "\(ArchiveExtractionDirectory.namePrefix)\(stopped.processIdentifier)-\(UUID().uuidString)",
            isDirectory: true
        )
        let archiveFolder = leftover.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveFolder, withIntermediateDirectories: true)
        try Self.notes("rope").write(to: archiveFolder.appendingPathComponent("Rope Splicing.txt"))
        addTeardownBlock { try? FileManager.default.removeItem(at: leftover) }
        return leftover
    }

    /// Waits until every import `model` has queued so far has run, and lets
    /// the main-queue work they sent run too.
    @MainActor
    private func drainImportQueue(of model: LibraryViewModel) {
        let drained = expectation(description: "the import queue ran everything queued before")
        model.importOperationQueue.enqueue { drained.fulfill() }
        wait(for: [drained], timeout: 60)
        spinMainRunLoop(for: 0.1)
    }

    /// Runs `body` with the "After Importing a Book" preference set to
    /// `behavior`, restoring the previous preference afterwards.
    @MainActor
    private func withImportDeleteBehavior(_ behavior: ImportDeleteBehavior, _ body: () throws -> Void) rethrows {
        let config = ConfigService.shared
        let previous = config.config.importDeleteBehavior
        config.config.importDeleteBehavior = behavior
        defer { config.config.importDeleteBehavior = previous }
        try body()
    }

    /// Every name in this test's library folder, hidden ones included; none
    /// when the folder does not exist.
    private func folderEntries() throws -> Set<String> {
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    /// The extraction directories this process has in the data directory:
    /// none once every batch has ended.
    private func leftoverExtractionDirectories() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: ArchiveExtractionDirectory.defaultParent.path)) ?? []
        return names.filter { ArchiveExtractionDirectory.processIdentifier(inName: $0) == getpid() }
    }
}
