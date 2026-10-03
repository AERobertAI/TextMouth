import XCTest
@testable import TextMouth

/// A book's metadata write (its bookInfo.json) that fails is reported with
/// the book's title, the record's path, and a retry, from the debounced save
/// and from the termination flush alike, and the book's next write that
/// succeeds settles it (TODO S09). A read-only package makes the writes
/// fail. A package that is simply gone belongs to a book that moved or left
/// the library after its write was queued, which is not a failure.
final class BookRecordFailureReportingTests: XCTestCase {
    /// A debounced save that cannot be written is reported on its own, with
    /// the book's title and the record's path, from the metadata queue.
    @MainActor
    func testAFailedDebouncedWriteIsReportedWithTheBooksTitle() throws {
        let center = cleanSharedFailureCenter()
        let book = try makePackagedBook("Unsaved Margins")
        makeReadOnly(book.tmbDirectory)

        LibraryPersistenceService.saveBookInfo(for: book)

        XCTAssertTrue(waitUntil(timeout: 5) { center.hasUnsavedChanges }, "the debounced write was not reported")
        let failure = try XCTUnwrap(center.outstandingFailures().first)
        XCTAssertEqual(failure.subject, .bookRecord(bookID: book.id, title: "Unsaved Margins"))
        XCTAssertEqual(failure.path, TextMouthPaths.bookInfoPath(in: book.tmbDirectory).path)
        XCTAssertNotNil(failure.retry)
        XCTAssertTrue(
            failure.sentence.hasPrefix("Changes to “Unsaved Margins” could not be saved: "),
            failure.sentence
        )
    }

    /// The termination flush writes the waiting record at once and reports
    /// its failure before it returns.
    @MainActor
    func testAFailedFlushIsReportedBeforeItReturns() throws {
        let center = cleanSharedFailureCenter()
        let book = try makePackagedBook("Flushed Margins")
        makeReadOnly(book.tmbDirectory)

        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(
            center.outstandingFailures().map(\.subject),
            [.bookRecord(bookID: book.id, title: "Flushed Margins")]
        )
    }

    /// Retry writes the record that failed, reading position and all, once
    /// the package can be written again, and settles the failure.
    @MainActor
    func testRetryWritesTheSameRecordAndSettlesTheFailure() throws {
        let center = cleanSharedFailureCenter()
        var book = try makePackagedBook("Retried Margins")
        book.readingPosition = ReadingPosition(chapterIndex: 3, characterOffset: 421)
        let giveBackPermission = makeReadOnly(book.tmbDirectory)
        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()
        XCTAssertTrue(center.hasUnsavedChanges)

        giveBackPermission()
        let recorder = recordingAnnouncements { center.retry(.bookRecord) }

        XCTAssertFalse(center.hasUnsavedChanges)
        let saved = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(saved.state.readingPosition?.chapterIndex, 3)
        XCTAssertEqual(saved.state.readingPosition?.characterOffset, 421)
        XCTAssertEqual(recorder.announcements.map(\.message), ["Changes to books saved."])
    }

    /// The book's next save that reaches the disk settles its failure; a
    /// failure of another book stays.
    @MainActor
    func testTheBooksNextSuccessfulWriteSettlesOnlyItsFailure() throws {
        let center = cleanSharedFailureCenter()
        let saved = try makePackagedBook("Saved Later")
        let stuck = try makePackagedBook("Still Stuck")
        let giveBackPermission = makeReadOnly(saved.tmbDirectory)
        makeReadOnly(stuck.tmbDirectory)
        LibraryPersistenceService.saveBookInfo(for: saved)
        LibraryPersistenceService.saveBookInfo(for: stuck)
        LibraryPersistenceService.flushPendingSave()
        XCTAssertEqual(center.outstandingFailures().count, 2)

        giveBackPermission()
        LibraryPersistenceService.saveBookInfo(for: saved)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(center.outstandingFailures().map(\.key), [.book(stuck.id)])
    }

    /// A queued write whose package is gone by the time it runs belongs to
    /// a book that moved or left the library meanwhile: it is dropped with a
    /// log line, not reported as unsaved.
    @MainActor
    func testAWriteForAPackageThatIsGoneIsNotAFailure() throws {
        let center = cleanSharedFailureCenter()
        let book = try makePackagedBook("Moved Away")
        LibraryPersistenceService.saveBookInfo(for: book)
        try FileManager.default.removeItem(at: book.tmbDirectory)

        LibraryPersistenceService.flushPendingSave()

        XCTAssertTrue(center.outstandingFailures().isEmpty)
        XCTAssertEqual(debugLogLines(containing: "BOOK_METADATA_DROPPED: book \(book.id.uuidString.prefix(8))").count, 1)
    }

    /// An analysis merged into the book's waiting snapshot writes the book's
    /// latest state, so it settles the book's earlier failure too.
    @MainActor
    func testAnAnalysisMergedIntoTheWaitingSnapshotSettlesTheBook() throws {
        let center = cleanSharedFailureCenter()
        let book = try makePackagedBook("Analyzed Margins")
        let giveBackPermission = makeReadOnly(book.tmbDirectory)
        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()
        XCTAssertTrue(center.hasUnsavedChanges)

        giveBackPermission()
        LibraryPersistenceService.saveBookInfo(for: book)
        let index = BookContentIndex.build(
            fromChapters: [Chapter(title: "Chapter", text: "Failure fixture")],
            format: .txt
        )
        XCTAssertNotNil(try LibraryPersistenceService.saveContentAnalysis(for: book, index: index, cacheFormatVersion: nil))

        XCTAssertFalse(center.hasUnsavedChanges)
    }

    // MARK: - Books Leaving the Library

    /// A book whose record could not be saved has nothing left to save once
    /// it is removed and deleted: its failure is withdrawn, so neither the
    /// banner nor quitting holds on to it. (The deletion is injected, so
    /// nothing goes to the real Trash.)
    @MainActor
    func testRemovingAndDeletingABookWithdrawsItsFailure() throws {
        let center = cleanSharedFailureCenter()
        let book = try failedRecord("Deleted While Unsaved")
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])

        let outcome = model.removeBooksAndDeleteReturningOutcome([book]) { _ in }

        XCTAssertTrue(outcome.succeeded)
        XCTAssertTrue(model.library.books.isEmpty)
        XCTAssertFalse(center.hasUnsavedChanges)
    }

    /// Remove from Library Only withdraws the book's failure the same way
    /// when it retires the package.
    @MainActor
    func testRemovingABookFromTheLibraryOnlyWithdrawsItsFailure() throws {
        let center = cleanSharedFailureCenter()
        let book = try failedRecord("Kept Out While Unsaved")
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])

        model.removeBooksFromLibraryOnly([book])

        XCTAssertTrue(model.library.books.isEmpty)
        XCTAssertFalse(model.showError, model.errorMessage ?? "")
        XCTAssertFalse(center.hasUnsavedChanges)
    }

    // MARK: - Helpers

    /// A packaged book titled `title` whose record write has just failed
    /// and been reported, in a package that is writable again.
    @MainActor
    private func failedRecord(_ title: String) throws -> Book {
        let book = try makePackagedBook(title)
        let giveBackPermission = makeReadOnly(book.tmbDirectory)
        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()
        XCTAssertTrue(PersistenceFailureCenter.shared.hasUnsavedChanges, "the record write did not fail")
        giveBackPermission()
        return book
    }
}
