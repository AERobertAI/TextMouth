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
        let clock = CommandClock()
        let progress = ImportProgress(now: { clock.now })
        progress.show(ImportProgressWording.startingArchive)

        progress.receive(.extracting(archive: "Library Export.zip", done: 120, total: 120))
        XCTAssertEqual(progress.state.lines(at: clock.now), ["Extracting “Library Export.zip”: 120 of 120 items..."])
        XCTAssertEqual(progress.state.total, 0, "the bar counts books, so it only spins while the archive is extracted")

        progress.receive(.importingBook(number: 1, total: 3, book: "Moby Dick.epub", step: .readingSource))
        XCTAssertEqual(
            progress.state.lines(at: clock.now),
            ["0 of 3 books processed", "Book 1 of 3: “Moby Dick.epub”, reading the file"]
        )
        XCTAssertEqual(
            progress.state.spokenStatus(at: clock.now),
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
        XCTAssertEqual(progress.state.details(at: clock.now), [], "the extraction alone gives no estimate")

        progress.receive(.importingBook(number: 1, total: 10, book: "Moby Dick.epub", step: .readingSource))
        clock.advance(by: 20)
        progress.receive(.importingBook(number: 1, total: 10, book: "Moby Dick.epub", step: .readingText))
        XCTAssertEqual(progress.state.details(at: clock.now), ["20 seconds on this book"], "no book is done yet")
        clock.advance(by: 10)
        progress.receive(.importing(done: 1, total: 10))
        // 30 seconds a book, 9 books left: 4.5 minutes.
        XCTAssertEqual(progress.state.details(at: clock.now), ["About 5 minutes left"])

        progress.receive(.importingBook(number: 2, total: 10, book: "Bleak House.pdf", step: .readingSource))
        clock.advance(by: 200)
        XCTAssertEqual(
            progress.state.details(at: clock.now),
            ["3 minutes, 20 seconds on this book", "About 5 minutes left"],
            "the estimate waits for the book to finish"
        )

        progress.receive(.importing(done: 2, total: 10))
        // 230 seconds for 2 books, 8 books left: 15.3 minutes.
        XCTAssertEqual(progress.state.details(at: clock.now), ["About 15 minutes left"])
        XCTAssertEqual(
            progress.state.spokenStatus(at: clock.now),
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
        XCTAssertEqual(progress.state.details(at: clock.now), [], "a duplicate skipped is no book timed")

        progress.receive(.importingBook(number: 4, total: 5, book: "Audiobook.m4b", step: .readingSource))
        clock.advance(by: 120)
        progress.receive(.importing(done: 4, total: 5))
        // The one book timed took 2 minutes, and 1 book is left.
        XCTAssertEqual(progress.state.details(at: clock.now), ["About 2 minutes left"])
    }

    /// No time left is said for a batch of one book, nor once the last book
    /// is done: nothing is left to estimate.
    func testNoTimeLeftForOneBookOrAfterTheLast() {
        let clock = CommandClock()
        let progress = ImportProgress(now: { clock.now })
        progress.receive(.importingBook(number: 1, total: 1, book: "Only.epub", step: .readingSource))
        clock.advance(by: 90)
        progress.receive(.importing(done: 1, total: 1))
        XCTAssertEqual(progress.state.details(at: clock.now), [])

        progress.show(ImportProgressWording.startingArchive)
        progress.receive(.importingBook(number: 1, total: 2, book: "First.epub", step: .readingSource))
        clock.advance(by: 90)
        progress.receive(.importing(done: 1, total: 2))
        XCTAssertEqual(progress.state.details(at: clock.now), ["About 2 minutes left"])
        progress.receive(.importingBook(number: 2, total: 2, book: "Second.epub", step: .readingSource))
        clock.advance(by: 90)
        progress.receive(.importing(done: 2, total: 2))
        XCTAssertEqual(progress.state.details(at: clock.now), [])
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
        XCTAssertEqual(library.importProgress.state.details(at: Date()), ["Cancelling..."])

        let clock = CommandClock()
        let progress = ImportProgress(now: { clock.now })
        progress.receive(.importingBook(number: 1, total: 4, book: "First.epub", step: .readingSource))
        clock.advance(by: 60)
        progress.receive(.importing(done: 1, total: 4))
        XCTAssertEqual(progress.state.details(at: clock.now), ["About 3 minutes left"])
        progress.receive(.importingBook(number: 2, total: 4, book: "Second.epub", step: .readingText))
        progress.cancel()
        XCTAssertEqual(progress.state.details(at: clock.now), ["Cancelling after this book..."])
        clock.advance(by: 60)
        XCTAssertEqual(
            progress.state.details(at: clock.now),
            ["1 minute on this book", "Cancelling after this book..."],
            "the book under way goes on being timed while it finishes"
        )
        progress.receive(.importing(done: 2, total: 4))
        XCTAssertEqual(
            progress.state.details(at: clock.now),
            ["Cancelling after this book..."],
            "the estimate came back once cancelled"
        )
        XCTAssertEqual(
            progress.state.spokenStatus(at: clock.now),
            "Importing Books: 2 of 4 books processed. Book 2 of 4: “Second.epub”, reading its text. "
                + "Cancelling after this book..."
        )

        progress.show(ImportProgressWording.startingArchive)
        XCTAssertFalse(progress.state.isCancelling, "the next import starts afresh")
    }

    // MARK: - It Is Moving

    /// While one book takes long, the overlay the window shows says so: the
    /// time since the book began, once it passes 10 seconds, in steps of 5,
    /// which VoiceOver hears with the rest.
    func testTheWindowsOverlayShowsTheTimeOnALongBook() throws {
        let library = LibraryViewModel(initializeServices: false)
        library.importProgress.receive(.importingBook(number: 3, total: 100, book: "Moby Dick.epub", step: .readingText))
        let started = try XCTUnwrap(library.importProgress.state.book?.startedAt)

        XCTAssertEqual(LibraryWindowView.importProgressOverlay(for: library, at: started.addingTimeInterval(9)).details, [])
        let overlay = LibraryWindowView.importProgressOverlay(for: library, at: started.addingTimeInterval(47))
        XCTAssertEqual(overlay.details, ["45 seconds on this book"])
        XCTAssertEqual(
            overlay.spokenStatus,
            "Importing Books: 2 of 100 books processed. Book 3 of 100: “Moby Dick.epub”, reading its text. "
                + "45 seconds on this book."
        )
    }

    /// The time on a book runs through all its steps, stops once it is
    /// done, and starts again with the next book.
    func testTheTimeOnABookOutlastsItsStepsAndStartsAgainWithTheNext() {
        let clock = CommandClock()
        let progress = ImportProgress(now: { clock.now })
        progress.receive(.importingBook(number: 1, total: 2, book: "Atlas.pdf", step: .readingSource))
        clock.advance(by: 30)
        progress.receive(.importingBook(number: 1, total: 2, book: "Atlas.pdf", step: .readingText))
        clock.advance(by: 32)
        XCTAssertEqual(progress.state.message, "Book 1 of 2: “Atlas.pdf”, reading its text")
        XCTAssertEqual(progress.state.details(at: clock.now), ["1 minute on this book"])

        progress.receive(.importing(done: 1, total: 2))
        progress.receive(.importingBook(number: 2, total: 2, book: "Tide Tables.txt", step: .readingSource))
        // The first book took 62 seconds, and 1 book is left.
        XCTAssertEqual(progress.state.details(at: clock.now), ["About 1 minute left"])
        clock.advance(by: 11)
        XCTAssertEqual(progress.state.details(at: clock.now), ["10 seconds on this book", "About 1 minute left"])
    }

    /// A book imported alone, a file or an archive holding one book, is
    /// named in the overlay with each step its import begins on its
    /// package, which the overlay hears before the queue's own hook does,
    /// and is timed as a batch's book is; it has no count and no time left.
    func testABookImportedAloneIsNamedWithEachStep() throws {
        let clock = CommandClock()
        let progress = ImportProgress(now: { clock.now })
        var hookHeard: [ImportStep] = []
        let observer = progress.observeBook("Harbor Talks.zip") { step, _ in hookHeard.append(step) }
        XCTAssertTrue(waitUntil { progress.state.message == "“Harbor Talks.zip”, reading the file" }, progress.state.message)

        try observer(.extractingArchive, FileManager.default.temporaryDirectory)
        XCTAssertEqual(hookHeard, [.extractingArchive])
        XCTAssertTrue(
            waitUntil { progress.state.message == "“Harbor Talks.zip”, extracting the archive" },
            progress.state.message
        )
        clock.advance(by: 25)
        XCTAssertEqual(
            progress.state.lines(at: clock.now),
            ["“Harbor Talks.zip”, extracting the archive", "25 seconds on this book"]
        )
        XCTAssertEqual(
            progress.state.spokenStatus(at: clock.now),
            "Importing Books: “Harbor Talks.zip”, extracting the archive. 25 seconds on this book."
        )
        XCTAssertEqual(progress.state.total, 0, "one book has no count")
    }

    // MARK: - Through the Import Queue

    /// A file imported alone through the library's own import queue is named
    /// in the overlay with the step it is held at, and the overlay is
    /// cleared once the book is in the library.
    func testAFileImportedAloneShowsItsNameAndStep() throws {
        let folder = makeIntegrationLibraryFolder("Import Progress File")
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        useAfterImportingBehavior(.askEachTime)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        let source = try makeSandboxDirectory("ImportProgressFile").appendingPathComponent("Leading Lights.txt")
        try Data("Leading Lights\n\nThe range lights line up over the channel.\n".utf8).write(to: source)
        let gate = holdImport(of: model, at: .readingText)

        model.importSingleFileAsync(from: source, toFolder: folder.path)

        XCTAssertTrue(
            waitUntil(timeout: 10) { model.importProgress.state.message == "“Leading Lights.txt”, reading its text" },
            model.importProgress.state.message
        )
        gate.signal()
        XCTAssertTrue(waitUntil(timeout: 10) { !model.library.books.isEmpty || model.showError }, "the import never finished")
        XCTAssertFalse(model.showError, model.errorMessage ?? "")
        XCTAssertEqual(model.importProgress.state, ImportProgressState(), "the overlay still shows the import")
    }

    /// An archive holding one audiobook is named in the overlay with the
    /// step it is held at, as a single file is, however long that step
    /// takes, and the overlay is cleared once the book is in the library.
    func testAnAudiobookArchiveShowsItsNameAndStep() throws {
        let folder = makeIntegrationLibraryFolder("Import Progress Audio")
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        useAfterImportingBehavior(.askEachTime)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        let sources = try makeSandboxDirectory("ImportProgressAudio")
        let track = sources.appendingPathComponent("Chapter 1.wav")
        try AudioTestFixtures.writeSilence(to: track)
        let archive = sources.appendingPathComponent("Harbor Talks.zip")
        try FileManager.default.moveItem(
            at: try makeTemporaryZip(prefix: "ImportProgress", entries: ["Chapter 1.wav": try Data(contentsOf: track)]),
            to: archive
        )
        let gate = holdImport(of: model, at: .extractingArchive)

        model.importZipAsync(from: archive, toFolder: folder.path)

        XCTAssertTrue(
            waitUntil(timeout: 10) { model.importProgress.state.message == "“Harbor Talks.zip”, extracting the archive" },
            model.importProgress.state.message
        )
        gate.signal()
        XCTAssertTrue(waitUntil(timeout: 20) { !model.library.books.isEmpty || model.showError }, "the import never finished")
        XCTAssertFalse(model.showError, model.errorMessage ?? "")
        XCTAssertEqual(model.importProgress.state, ImportProgressState(), "the overlay still shows the import")
    }

    // MARK: - Fixtures

    /// Holds the import `model`'s queue runs when it begins `step`, until the
    /// returned gate is signaled. The gate is signaled, and the hook
    /// removed, when the test ends, so no import waits forever.
    private func holdImport(of model: LibraryViewModel, at step: ImportStep) -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        let queue = model.importOperationQueue
        queue.stepObserver = { reached, _ in
            if reached == step { gate.wait() }
        }
        addTeardownBlock {
            queue.stepObserver = nil
            gate.signal()
        }
        return gate
    }
}
