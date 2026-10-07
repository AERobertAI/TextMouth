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

        progress.receive(.importingBook(number: 1, total: 3, book: "Moby Dick.epub", step: .readingText))
        progress.receive(.importing(done: 1, total: 3))
        XCTAssertEqual(progress.state.current, 1)
        XCTAssertEqual(
            progress.state.lines,
            ["1 of 3 books processed", "Book 1 of 3: “Moby Dick.epub”, reading its text"],
            "a finished book's line stays until the next book begins"
        )

        progress.receive(.importingBook(number: 2, total: 3, book: "Bleak House.pdf", step: .readingSource))
        XCTAssertEqual(
            progress.state.spokenStatus,
            "Importing Books: 1 of 3 books processed. Book 2 of 3: “Bleak House.pdf”, reading the file."
        )
    }
}
