import Combine
import XCTest
@testable import TextMouth

/// The import overlay's progress (FR10): an object of its own that only the
/// overlay observes, so the many reports of a ZIP batch redraw the overlay
/// alone and never the Library windows' lists, which observe the library
/// model (as TODO PERF12 did for the text extraction's progress).
@MainActor
final class ImportProgressTests: XCTestCase {

    // MARK: - Publishing

    /// Each change to the imports' progress publishes the progress object,
    /// which the overlay observes, and never the library model.
    func testProgressPublishesItselfAndNeverTheLibrary() {
        let library = LibraryViewModel(initializeServices: false)
        var libraryPublishes = 0
        var progressPublishes = 0
        let watchers = [
            library.objectWillChange.sink { libraryPublishes += 1 },
            library.importProgress.objectWillChange.sink { progressPublishes += 1 }
        ]
        defer { watchers.forEach { $0.cancel() } }

        library.importProgress.show("Extracting archive...")
        library.importProgress.receive(.extracting(archive: "Shelf.zip", done: 1, total: 2))
        library.importProgress.receive(.importing(done: 1, total: 2))
        library.importProgress.clear()

        XCTAssertEqual(progressPublishes, 4)
        XCTAssertEqual(libraryPublishes, 0, "the library model published, which redraws every Library window's list")
    }

    /// A message shown alone leaves the bar spinning with no count, and
    /// clearing leaves nothing shown.
    func testAMessageAloneSpinsAndClearingShowsNothing() {
        let progress = ImportProgress()

        progress.show(LibraryViewModel.importWaitingForMoveMessage)
        XCTAssertEqual(progress.state.message, "Waiting for the data directory move to finish...")
        XCTAssertEqual(progress.state.current, 0)
        XCTAssertEqual(progress.state.total, 0)

        progress.clear()
        XCTAssertEqual(progress.state, ImportProgressState())
        XCTAssertEqual(progress.state.message, "")
    }

    // MARK: - The Book and Its Step

    /// A ZIP batch's overlay counts the archive's items while it is
    /// extracted, under a bar that only spins; then it counts the books
    /// done and names the book under way and the step it is at, which it
    /// keeps until the next book begins. VoiceOver reads every line.
    func testABatchNamesEachBookAndItsStep() {
        let progress = ImportProgress()
        progress.show(ImportProgressWording.startingArchive)

        progress.receive(.extracting(archive: "Library Export.zip", done: 120, total: 120))
        XCTAssertEqual(progress.state.lines, ["Extracting “Library Export.zip”: 120 of 120 items..."])
        XCTAssertEqual(progress.state.total, 0, "the bar counts books, so it only spins while the archive is extracted")

        progress.receive(.importingBook(number: 1, total: 3, book: "Moby Dick.epub", step: .readingSource))
        XCTAssertEqual(progress.state.lines, ["0 of 3 books processed", "Book 1 of 3: “Moby Dick.epub”, reading the file"])
        XCTAssertEqual(
            progress.state.spokenStatus,
            "Importing Books: 0 of 3 books processed. Book 1 of 3: “Moby Dick.epub”, reading the file."
        )

        progress.receive(.importingBook(number: 1, total: 3, book: "Moby Dick.epub", step: .readingText))
        progress.receive(.importing(done: 1, total: 3))
        XCTAssertEqual(progress.state.current, 1)
        XCTAssertEqual(
            progress.state.message,
            "Book 1 of 3: “Moby Dick.epub”, reading its text",
            "a finished book's line stays until the next book begins"
        )

        progress.receive(.importingBook(number: 2, total: 3, book: "Bleak House.pdf", step: .readingSource))
        XCTAssertEqual(progress.state.current, 1)
        XCTAssertEqual(progress.state.message, "Book 2 of 3: “Bleak House.pdf”, reading the file")
    }

    // MARK: - The Time Left

    /// No time left is said while the archive is extracted, however long it
    /// takes; once the batch's first book is done, the time left is the
    /// average of the books done times the books left, recomputed only as
    /// each book finishes, and VoiceOver hears it.
    func testTimeLeftFollowsTheBooksDoneAndNeverTheExtraction() {
        let clock = CommandClock()
        let progress = ImportProgress(now: { clock.now })
        progress.show(ImportProgressWording.startingArchive)
        progress.receive(.extracting(archive: "Library Export.zip", done: 0, total: 300))
        clock.advance(by: 600)
        progress.receive(.extracting(archive: "Library Export.zip", done: 300, total: 300))
        XCTAssertEqual(progress.state.details, [], "the extraction alone gives no estimate")

        progress.receive(.importingBook(number: 1, total: 10, book: "Moby Dick.epub", step: .readingSource))
        clock.advance(by: 20)
        progress.receive(.importingBook(number: 1, total: 10, book: "Moby Dick.epub", step: .readingText))
        XCTAssertEqual(progress.state.details, [], "no book is done yet")
        clock.advance(by: 10)
        progress.receive(.importing(done: 1, total: 10))
        // 30 seconds a book, 9 books left: 4.5 minutes.
        XCTAssertEqual(progress.state.details, ["About 5 minutes left"])

        progress.receive(.importingBook(number: 2, total: 10, book: "Bleak House.pdf", step: .readingSource))
        clock.advance(by: 200)
        XCTAssertEqual(progress.state.details, ["About 5 minutes left"], "the estimate waits for the book to finish")

        progress.receive(.importing(done: 2, total: 10))
        // 230 seconds for 2 books, 8 books left: 15.3 minutes.
        XCTAssertEqual(progress.state.details, ["About 15 minutes left"])
        XCTAssertEqual(
            progress.state.spokenStatus,
            "Importing Books: 2 of 10 books processed. Book 2 of 10: “Bleak House.pdf”, reading the file. "
                + "About 15 minutes left."
        )
    }

    /// A book skipped as a duplicate is not timed, so an archive whose first
    /// books are already in the library does not promise far too little.
    func testDuplicatesSkippedAreNotTimed() {
        let clock = CommandClock()
        let progress = ImportProgress(now: { clock.now })
        progress.show(ImportProgressWording.startingArchive)
        for number in 1...3 {
            progress.receive(.importingBook(number: number, total: 5, book: "Copy \(number).epub", step: .readingSource))
            clock.advance(by: 0.01)
            progress.receive(.importing(done: number, total: 5, skippedDuplicate: true))
        }
        XCTAssertEqual(progress.state.details, [], "a duplicate skipped is no book timed")

        progress.receive(.importingBook(number: 4, total: 5, book: "Audiobook.m4b", step: .readingSource))
        clock.advance(by: 120)
        progress.receive(.importing(done: 4, total: 5))
        // The one book timed took 2 minutes, and 1 book is left.
        XCTAssertEqual(progress.state.details, ["About 2 minutes left"])
    }

    /// No time left is said for a batch of one book, nor once the last book
    /// is done: nothing is left to estimate.
    func testNoTimeLeftForOneBookOrAfterTheLast() {
        let clock = CommandClock()
        let progress = ImportProgress(now: { clock.now })
        progress.receive(.importingBook(number: 1, total: 1, book: "Only.epub", step: .readingSource))
        clock.advance(by: 90)
        progress.receive(.importing(done: 1, total: 1))
        XCTAssertEqual(progress.state.details, [])

        progress.show(ImportProgressWording.startingArchive)
        progress.receive(.importingBook(number: 1, total: 2, book: "First.epub", step: .readingSource))
        clock.advance(by: 90)
        progress.receive(.importing(done: 1, total: 2))
        XCTAssertEqual(progress.state.details, ["About 2 minutes left"])
        progress.receive(.importingBook(number: 2, total: 2, book: "Second.epub", step: .readingSource))
        clock.advance(by: 90)
        progress.receive(.importing(done: 2, total: 2))
        XCTAssertEqual(progress.state.details, [])
    }

    /// Once Cancel is pressed the overlay says the import is cancelling in
    /// place of the time left, which never comes back as the book under way
    /// finishes; before any book, it says only that it is cancelling. The
    /// overlay's Cancel reaches the progress through the library's
    /// `cancelImports()`.
    func testCancellingReplacesTheTimeLeft() {
        let library = LibraryViewModel(initializeServices: false)
        library.importProgress.show(ImportProgressWording.startingArchive)
        library.importProgress.receive(.extracting(archive: "Library Export.zip", done: 1, total: 3))
        library.cancelImports()
        XCTAssertEqual(library.importProgress.state.details, ["Cancelling..."])

        let clock = CommandClock()
        let progress = ImportProgress(now: { clock.now })
        progress.receive(.importingBook(number: 1, total: 4, book: "First.epub", step: .readingSource))
        clock.advance(by: 60)
        progress.receive(.importing(done: 1, total: 4))
        XCTAssertEqual(progress.state.details, ["About 3 minutes left"])
        progress.receive(.importingBook(number: 2, total: 4, book: "Second.epub", step: .readingText))
        progress.cancel()
        XCTAssertEqual(progress.state.details, ["Cancelling after this book..."])
        clock.advance(by: 60)
        progress.receive(.importing(done: 2, total: 4))
        XCTAssertEqual(progress.state.details, ["Cancelling after this book..."], "the estimate came back once cancelled")
        XCTAssertEqual(
            progress.state.spokenStatus,
            "Importing Books: 2 of 4 books processed. Book 2 of 4: “Second.epub”, reading its text. "
                + "Cancelling after this book..."
        )

        progress.show(ImportProgressWording.startingArchive)
        XCTAssertFalse(progress.state.isCancelling, "the next import starts afresh")
    }
}
