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
}
