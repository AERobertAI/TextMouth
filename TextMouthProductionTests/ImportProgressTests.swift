import AppKit
import Combine
import SwiftUI
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

    /// Over a queue of several imports the library model publishes twice,
    /// as the first starts and as the last ends; each change between, as
    /// one more is queued or one is done, publishes only the overlay's own
    /// progress, which counts those waiting. Until October 10, 2026 every
    /// change of the queue's count published the model, which every
    /// Library window's list observes (REV13).
    func testTheLibraryPublishesAsImportsStartAndEndAlone() {
        let library = LibraryViewModel(initializeServices: false)
        library.observeImportActivity()
        var libraryPublishes = 0
        let watcher = library.objectWillChange.sink { libraryPublishes += 1 }
        defer { watcher.cancel() }
        let imports = 3
        let gate = DispatchSemaphore(value: 0)
        // Whatever the test does, no import is left waiting at its end.
        addTeardownBlock { for _ in 0..<imports { gate.signal() } }

        for _ in 0..<imports {
            library.importOperationQueue.enqueue { gate.wait() }
        }
        XCTAssertTrue(
            waitUntil(timeout: 5) { library.importProgress.state.waitingImports == imports - 1 },
            "the overlay counts \(library.importProgress.state.waitingImports) imports waiting"
        )
        XCTAssertTrue(library.isImporting)
        for _ in 0..<imports {
            gate.signal()
        }
        XCTAssertTrue(waitUntil(timeout: 5) { !library.isImporting }, "the imports never ended")

        XCTAssertEqual(libraryPublishes, 2, "the library model published for a change of the queue's count")
    }

    /// One view observes every progress shown apart from the library model
    /// (`ProgressObserver`, #1461): hosted over the text extraction's
    /// progress or the imports', it draws its content anew each time that
    /// progress publishes, with the progress as it is then.
    func testOneObserverViewRedrawsAsEachKindOfProgressPublishes() {
        let extraction = TextExtractionProgress()
        let extractionDraws = CallLog<String>()
        let extractionView = ProgressObserver(progress: extraction) { progress in
            let _ = extractionDraws.record(progress.message)
            Text(progress.message)
        }
        withHostedView(extractionView, until: { _ in !extractionDraws.calls.isEmpty }) { hostingView in
            extraction.begin("Updating text cache", total: 3)
            XCTAssertTrue(waitUntil {
                hostingView.layoutSubtreeIfNeeded()
                return extractionDraws.calls.last == "Updating text cache: 0 of 3..."
            }, "\(extractionDraws.calls)")
            extraction.advance()
            XCTAssertTrue(waitUntil {
                hostingView.layoutSubtreeIfNeeded()
                return extractionDraws.calls.last == "Updating text cache: 1 of 3..."
            }, "\(extractionDraws.calls)")
        }

        let imports = ImportProgress()
        let importDraws = CallLog<String>()
        let importView = ProgressObserver(progress: imports) { progress in
            let _ = importDraws.record(progress.state.message)
            Text(progress.state.message)
        }
        withHostedView(importView, until: { _ in !importDraws.calls.isEmpty }) { hostingView in
            imports.showBook("Moby Dick.epub")
            XCTAssertTrue(waitUntil {
                hostingView.layoutSubtreeIfNeeded()
                return importDraws.calls.last == "“Moby Dick.epub”, reading the file"
            }, "\(importDraws.calls)")
            imports.reach(.readingText)
            XCTAssertTrue(waitUntil {
                hostingView.layoutSubtreeIfNeeded()
                return importDraws.calls.last == "“Moby Dick.epub”, reading its text"
            }, "\(importDraws.calls)")
        }
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

    /// The time left weighs each book left by the size it is timed by: a
    /// batch whose small books came first estimates its large one by the
    /// rate those took, rather than at the average time of a book, so it no
    /// longer runs short until the large one comes; a book without a size,
    /// an audiobook's file, takes the average time of the books timed
    /// without one, or of every book before any such was timed (FR10).
    func testTimeLeftWeighsTheBooksLeftByTheirSizes() {
        let clock = CommandClock()
        let progress = ImportProgress(now: { clock.now })
        progress.showArchive("Mixed Shelf.zip")
        progress.receive(.foundBooks(sizes: [1_000_000, 1_000_000, 300_000_000, nil]))

        progress.receive(.importingBook(number: 1, total: 4, book: "Notes.epub", step: .readingSource))
        clock.advance(by: 2)
        progress.receive(.importing(done: 1, total: 4))
        // 1 MB in 2 seconds: the next 1 MB takes 2, the 300 MB book 600,
        // and the audiobook the average, 2: 604 seconds. By books alone it
        // was 6 seconds, less than a minute.
        XCTAssertEqual(progress.state.details(at: clock.now), ["About 10 minutes left"])

        progress.receive(.importingBook(number: 2, total: 4, book: "Charts.epub", step: .readingSource))
        clock.advance(by: 2)
        progress.receive(.importing(done: 2, total: 4))
        progress.receive(.importingBook(number: 3, total: 4, book: "Atlas.pdf", step: .readingSource))
        clock.advance(by: 30)
        progress.receive(.importing(done: 3, total: 4))
        // The large book came quicker than its size foretold, and the
        // audiobook left, which has no size, takes the average time of the
        // three books timed: 34 seconds in all, about 11 seconds each.
        XCTAssertEqual(progress.state.details(at: clock.now), ["Less than a minute left"])

        progress.receive(.importingBook(number: 4, total: 4, book: "Harbor Talks.m4b", step: .readingSource))
        clock.advance(by: 5)
        progress.receive(.importing(done: 4, total: 4))
        XCTAssertEqual(progress.state.details(at: clock.now), [], "nothing is left to estimate")
        XCTAssertEqual(progress.state.timing.items, 4)
        XCTAssertEqual(progress.state.timing.sizedItems, 3, "the audiobook was timed by a size")
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

    // MARK: - Imports Waiting

    /// The imports queued behind the one shown are counted under it, and
    /// VoiceOver reads them with the rest; the count outlasts the import
    /// shown, which a new import or its end replaces, and follows the
    /// queue's count down to none. Once Cancel is pressed they are not
    /// counted, since the ZIP archives among them never start.
    func testImportsWaitingBehindTheOneShownAreCounted() {
        let clock = CommandClock()
        let progress = ImportProgress(now: { clock.now })

        progress.noteImportsQueued(3)
        progress.showArchive("Library Export.zip")
        XCTAssertEqual(progress.state.lines(at: clock.now), ["Extracting archive...", "2 more imports waiting"])
        XCTAssertEqual(
            progress.state.spokenStatus(at: clock.now),
            "Importing Books: Extracting archive... 2 more imports waiting."
        )

        // The archive ends; the queue has not yet counted it out.
        progress.end(.batch(ZipImportResult(books: Self.books(1), failures: [])))
        XCTAssertEqual(progress.state.details(at: clock.now), ["2 more imports waiting"])
        XCTAssertEqual(progress.state.spokenStatus(at: clock.now), "Importing Books: 2 more imports waiting.")
        progress.noteImportsQueued(2)
        progress.showBook("Moby Dick.epub")
        XCTAssertEqual(progress.state.lines(at: clock.now), ["“Moby Dick.epub”, reading the file", "1 more import waiting"])

        progress.cancel()
        XCTAssertEqual(progress.state.details(at: clock.now), ["Cancelling after this book..."])

        progress.noteImportsQueued(1)
        progress.showBook("Bleak House.pdf")
        XCTAssertEqual(progress.state.details(at: clock.now), [], "no import waits behind the last")
        progress.noteImportsQueued(0)
        progress.clear()
        XCTAssertEqual(progress.state, ImportProgressState())
    }

    /// The library follows its import queue's count: the overlay shows while
    /// any import is queued or running and counts those waiting behind the
    /// one it shows, Speak Import Progress says them too, and once none is
    /// left the overlay goes with nothing counted.
    func testTheLibraryCountsTheImportsItsQueueHolds() {
        let library = LibraryViewModel(initializeServices: false)

        let recorder = recordingAnnouncements {
            library.importActivityChanged(to: 3)
            library.importProgress.showBook("Leading Lights.txt")
            library.speakImportProgress()
        }

        XCTAssertTrue(library.isImporting)
        XCTAssertEqual(recorder.announcements.map(\.message), [
            "Importing Books: “Leading Lights.txt”, reading the file. 2 more imports waiting."
        ])
        library.importActivityChanged(to: 0)
        XCTAssertFalse(library.isImporting)
        XCTAssertEqual(library.importProgress.state, ImportProgressState())
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

    /// An archive holding one audiobook shows how far it has been
    /// extracted, its items and bytes, on its line while it is extracted,
    /// and no longer once its import moves on (FR10).
    func testAnAudiobookArchivesLineCountsWhatItHasExtracted() {
        let progress = ImportProgress()
        progress.showBook("Harbor Talks.zip")
        progress.reach(.extractingArchive)
        progress.receive(extraction: ArchiveExtractionProgress(entriesDone: 12, entries: 30, bytesDone: 120_000_000, bytes: 340_000_000))
        XCTAssertEqual(progress.state.message, "“Harbor Talks.zip”, extracting the archive: 12 of 30 items, 120 MB of 340 MB")

        progress.reach(.readingAudio)
        XCTAssertEqual(progress.state.message, "“Harbor Talks.zip”, reading its audio")
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

    /// Each kind of book imported alone is shown from the step its import
    /// begins with: a file or an archive at reading the file, a TextMouth
    /// package at checking it, and New from Text's text at creating its
    /// package.
    func testABookImportedAloneIsShownFromItsFirstStep() {
        let progress = ImportProgress()
        _ = progress.observeBook("Leading Lights.txt")
        XCTAssertTrue(waitUntil { progress.state.message == "“Leading Lights.txt”, reading the file" }, progress.state.message)
        _ = progress.observeBook("Puncture Repair.tmb", startingAt: .checkingPackage)
        XCTAssertTrue(waitUntil { progress.state.message == "“Puncture Repair.tmb”, checking the package" }, progress.state.message)
        _ = progress.observeBook("Harbor Notes", startingAt: .preparingPackage)
        XCTAssertTrue(waitUntil { progress.state.message == "“Harbor Notes”, creating its package" }, progress.state.message)
    }

    /// Text made into a book with New from Text is named in the overlay by
    /// the title typed, with the step its import is held at, and the overlay
    /// is cleared once the book is in the library; until October 10, 2026
    /// it showed no book and no step.
    func testNewFromTextShowsItsTitleAndStep() throws {
        let folder = makeIntegrationLibraryFolder("Import Progress Text")
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        let gate = holdImport(of: model, at: .readingText)

        model.createBookFromText(
            title: "Harbor Notes",
            author: "",
            text: "The pilot boards at the fairway buoy and takes the ship in.",
            toFolder: folder.path
        )

        XCTAssertTrue(
            waitUntil(timeout: 10) { model.importProgress.state.message == "“Harbor Notes”, reading its text" },
            model.importProgress.state.message
        )
        gate.signal()
        XCTAssertTrue(waitUntil(timeout: 10) { !model.library.books.isEmpty || model.showError }, "the import never finished")
        XCTAssertFalse(model.showError, model.errorMessage ?? "")
        XCTAssertEqual(model.importProgress.state, ImportProgressState(), "the overlay still shows the import")
    }

    /// A TextMouth package opened from the Finder that the library does not
    /// list is named in the overlay with the step its import is held at,
    /// then opens once it is in the library, the overlay cleared; opened
    /// again, it is the library's book, which opens with nothing imported
    /// and nothing left in the overlay. Until October 10, 2026 a package's
    /// import showed no book and no step.
    func testAPackageOpenedShowsItsNameAndStep() throws {
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        let opened = CallLog<UUID>()
        model.readerOpener = { opened.record($0) }
        let package = try makeExternalPackage(named: "Puncture Repair")
        let gate = holdImport(of: model, at: .readingText)

        model.openTMBPackage(from: package)

        XCTAssertTrue(
            waitUntil(timeout: 10) { model.importProgress.state.message == "“Puncture Repair.tmb”, reading its text" },
            model.importProgress.state.message
        )
        gate.signal()
        XCTAssertTrue(waitUntil(timeout: 10) { !opened.calls.isEmpty || model.showError }, "the package never opened")
        XCTAssertFalse(model.showError, model.errorMessage ?? "")
        let book = try XCTUnwrap(model.library.books.first)
        addTeardownBlock { try? FileManager.default.removeItem(at: book.tmbDirectory) }
        XCTAssertEqual(opened.calls, [book.id])
        XCTAssertEqual(model.importProgress.state, ImportProgressState(), "the overlay still shows the import")

        model.openTMBPackage(from: package)

        XCTAssertTrue(waitUntil(timeout: 10) { opened.calls.count == 2 }, "the listed package did not open")
        XCTAssertEqual(opened.calls, [book.id, book.id])
        XCTAssertEqual(model.library.books.count, 1, "the listed package was imported again")
        XCTAssertEqual(model.importProgress.state, ImportProgressState(), "the overlay still shows the open")
    }

    /// An archive holding one audiobook, imported through the library's own
    /// queue, tells the overlay what its extraction has done: held at the
    /// step after it, the overlay has the whole archive counted, every item
    /// and every byte its tracks declare, and its line has moved on to that
    /// step. Until October 10, 2026 such an archive showed only its step.
    func testAnAudiobookArchiveTellsTheOverlayWhatItExtracts() throws {
        let folder = makeIntegrationLibraryFolder("Import Progress Audio Bytes")
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        useAfterImportingBehavior(.askEachTime)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        let sources = try makeSandboxDirectory("ImportProgressAudioBytes")
        let track = sources.appendingPathComponent("Chapter 1.wav")
        try AudioTestFixtures.writeSilence(to: track)
        let trackData = try Data(contentsOf: track)
        let archive = sources.appendingPathComponent("Harbor Talks.zip")
        try FileManager.default.moveItem(
            at: try makeTemporaryZip(prefix: "ImportProgressBytes", entries: ["Chapter 1.wav": trackData]),
            to: archive
        )
        let gate = holdImport(of: model, at: .readingAudio)

        model.importZipAsync(from: archive, toFolder: folder.path)

        XCTAssertTrue(
            waitUntil(timeout: 10) { model.importProgress.state.message == "“Harbor Talks.zip”, reading its audio" },
            model.importProgress.state.message
        )
        let extraction = try XCTUnwrap(model.importProgress.state.book?.extraction, "the overlay heard nothing of the extraction")
        XCTAssertEqual(extraction.entriesDone, extraction.entries)
        XCTAssertEqual(extraction.entries, 1)
        XCTAssertEqual(extraction.bytes, Int64(trackData.count))
        XCTAssertEqual(extraction.bytesDone, extraction.bytes)
        gate.signal()
        XCTAssertTrue(waitUntil(timeout: 20) { !model.library.books.isEmpty || model.showError }, "the import never finished")
        XCTAssertFalse(model.showError, model.errorMessage ?? "")
    }

    /// Files imported one after another through the library's own queue:
    /// while the first is held at a step, the overlay names it and counts
    /// the two waiting behind it; the second, once it runs, counts one; the
    /// last, none; and the overlay goes once all three are in the library.
    func testImportsQueuedBehindTheOneShownAreCountedAsTheyRun() throws {
        let folder = makeIntegrationLibraryFolder("Import Progress Waiting")
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        useAfterImportingBehavior(.askEachTime)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        model.observeImportActivity()
        let sources = try makeSandboxDirectory("ImportProgressWaiting")
        let titles = ["Leading Lights", "Range Marks", "Day Beacons"]
        for title in titles {
            let text = "\(title)\n\nWhat the \(title.lowercased()) show a pilot coming in.\n"
            try Data(text.utf8).write(to: sources.appendingPathComponent("\(title).txt"))
        }
        let gate = holdImport(of: model, at: .readingText)

        for title in titles {
            model.importSingleFileAsync(from: sources.appendingPathComponent("\(title).txt"), toFolder: folder.path)
        }

        for (index, title) in titles.enumerated() {
            let waiting = titles.count - 1 - index
            let expected = ["“\(title).txt”, reading its text"] + (waiting > 0 ? [ImportProgressWording.waiting(waiting)] : [])
            XCTAssertTrue(
                waitUntil(timeout: 10) { model.importProgress.state.lines(at: Date()) == expected },
                "the overlay shows \(model.importProgress.state.lines(at: Date())) for \(title)"
            )
            XCTAssertTrue(model.isImporting)
            gate.signal()
        }
        XCTAssertTrue(waitUntil(timeout: 10) { model.library.books.count == 3 && !model.isImporting }, "the imports never finished")
        XCTAssertFalse(model.showError, model.errorMessage ?? "")
        XCTAssertEqual(model.importProgress.state, ImportProgressState(), "the overlay still shows the imports")
    }

    /// A ZIP archive whose books are all in the library already imports
    /// nothing and raises no alert and no question, so VoiceOver hears what
    /// it found as soon as it ends, however quickly; until October 10, 2026
    /// such an import ended in silence.
    func testAnArchiveOfBooksAlreadyInTheLibrarySaysSoAtOnce() throws {
        let folder = makeIntegrationLibraryFolder("Import Progress No New Books")
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        useAfterImportingBehavior(.askEachTime)
        let sources = try makeSandboxDirectory("ImportProgressNoNewBooks")
        let texts = [
            "Tide Tables.txt": Data("Tide Tables\n\nHigh water at the outer harbour comes late today.\n".utf8),
            "Knots.txt": Data("Knots\n\nA bowline holds fast and unties easily.\n".utf8)
        ]
        var hashes: [String] = []
        for (name, data) in texts {
            let file = sources.appendingPathComponent(name)
            try data.write(to: file)
            hashes.append(try FileImportService.md5Hash(of: file))
        }
        let model = LibraryViewModel(initializeServices: false)
        // The library already holds both books, known by their checksums.
        model.library = Library(books: hashes.enumerated().map { index, hash in
            Book(title: "Held \(index + 1)", format: .txt, filePath: "/nowhere/held-\(index + 1).txt", md5Hash: hash)
        })
        let archive = sources.appendingPathComponent("Harbour Notes.zip")
        try FileManager.default.moveItem(at: try makeTemporaryZip(prefix: "ImportProgressNoNew", entries: texts), to: archive)
        let heard = HeardMessages()
        let previousPoster = VoiceOverAnnouncer.poster
        VoiceOverAnnouncer.poster = { announcement, _ in heard.messages.append(announcement.message) }
        defer { VoiceOverAnnouncer.poster = previousPoster }

        model.importZipAsync(from: archive, toFolder: folder.path)

        let expected = "No new books in “Harbour Notes.zip”: both were already in your library."
        XCTAssertTrue(waitUntil(timeout: 20) { heard.messages.contains(expected) }, heard.messages.joined(separator: " | "))
        XCTAssertEqual(heard.messages, [expected])
        XCTAssertFalse(model.showError, model.errorMessage ?? "")
        XCTAssertEqual(model.library.books.count, 2, "a book was imported")
        XCTAssertNil(model.importDecisions.current, "a question was asked")
    }

    // MARK: - What VoiceOver Hears Unasked

    /// A batch that runs long is announced at each quarter of its books it
    /// reaches, once, with the books processed and the time left, at medium
    /// priority so it waits for VoiceOver's current speech; a quarter
    /// reached in its first 10 seconds passes silently, and its end is
    /// announced on its own.
    func testABatchThatRunsLongIsAnnouncedAtEachQuarterAndAtItsEnd() {
        let clock = CommandClock()
        let progress = ImportProgress(now: { clock.now })

        let recorder = recordingAnnouncements {
            progress.showArchive("Library Export.zip")
            for number in 1...8 {
                progress.receive(.importingBook(number: number, total: 8, book: "Book \(number).epub", step: .readingSource))
                clock.advance(by: 4)
                progress.receive(.importing(done: number, total: 8))
            }
            progress.end(.batch(ZipImportResult(books: Self.books(8), failures: [])))
        }

        // The first quarter came 8 seconds in, too soon to be said.
        XCTAssertEqual(recorder.announcements.map(\.message), [
            "Importing “Library Export.zip”: 4 of 8 books processed, less than a minute left.",
            "Importing “Library Export.zip”: 6 of 8 books processed, less than a minute left.",
            "Finished importing “Library Export.zip”: 8 books imported."
        ])
        XCTAssertEqual(recorder.announcements.map(\.priority), [.medium, .medium, .high])
        XCTAssertEqual(progress.state, ImportProgressState(), "the end clears the overlay")
    }

    /// An import that ends within 10 seconds is never announced, neither its
    /// quarters nor its end: its questions and alerts speak for it.
    func testAShortImportStaysQuiet() {
        let clock = CommandClock()
        let progress = ImportProgress(now: { clock.now })

        let recorder = recordingAnnouncements {
            progress.showArchive("Shelf.zip")
            for number in 1...4 {
                progress.receive(.importingBook(number: number, total: 4, book: "Book \(number).epub", step: .readingSource))
                clock.advance(by: 2)
                progress.receive(.importing(done: number, total: 4))
            }
            progress.end(.batch(ZipImportResult(books: Self.books(4), failures: [])))
            progress.showBook("Moby Dick.epub")
            clock.advance(by: 9)
            progress.end(.book)
        }

        XCTAssertEqual(recorder.announcements, [])
    }

    /// The end of an import that ran long says what came of it: a batch's
    /// books imported, skipped as duplicates, and failed, or that none was
    /// found; one book's name; a failure; and nothing for a batch the user
    /// cancelled, whose alert says where it stopped.
    func testTheEndOfALongImportSaysWhatCameOfIt() {
        let clock = CommandClock()
        let progress = ImportProgress(now: { clock.now })
        let failure = ZipImportFailure(fileName: "Knots.docx", message: "Reading its text failed: unreadable")

        let recorder = recordingAnnouncements {
            progress.showArchive("Library Export.zip")
            progress.receive(.importingBook(number: 1, total: 3, book: "Copy.epub", step: .readingSource))
            progress.receive(.importing(done: 1, total: 3, skippedDuplicate: true))
            progress.receive(.importingBook(number: 2, total: 3, book: "Knots.docx", step: .readingSource))
            progress.receive(.importing(done: 2, total: 3))
            progress.receive(.importingBook(number: 3, total: 3, book: "Atlas.pdf", step: .readingSource))
            clock.advance(by: 30)
            progress.receive(.importing(done: 3, total: 3))
            progress.end(.batch(ZipImportResult(books: Self.books(1), failures: [failure], skippedDuplicates: 1)))

            progress.showBook("Moby Dick.epub")
            clock.advance(by: 12)
            progress.end(.book)

            progress.showArchive("Too Big.zip")
            clock.advance(by: 15)
            progress.end(.failure)

            progress.showArchive("Cancelled.zip")
            progress.receive(.importingBook(number: 1, total: 2, book: "One.epub", step: .readingSource))
            clock.advance(by: 20)
            progress.cancel()
            progress.receive(.importing(done: 1, total: 2))
            progress.end(.batch(ZipImportResult(
                books: Self.books(1),
                failures: [],
                cancellation: .afterBooks(completed: 1, total: 2)
            )))

            progress.showArchive("Empty.zip")
            clock.advance(by: 10)
            progress.end(.batch(ZipImportResult(books: [], failures: [])))
        }

        XCTAssertEqual(recorder.announcements.map(\.message), [
            "Finished importing “Library Export.zip”: 1 book imported, 1 skipped as a duplicate, 1 failed.",
            "Finished importing “Moby Dick.epub”.",
            "Could not import “Too Big.zip”.",
            "Cancelling after this book...",
            "No books were found in “Empty.zip”."
        ])
    }

    /// A batch that found no new book, its every book already in the
    /// library or none found, and in which nothing failed, says what it
    /// found however short it was, since no alert or question follows it.
    /// A short batch with a failure, whose alert speaks for it, a short one
    /// cancelled, whose alert says where it stopped, and one ended after
    /// Cancel stay quiet, as every import's end after Cancel does.
    func testABatchThatFindsNoNewBookSaysSoHoweverShort() {
        let clock = CommandClock()
        let progress = ImportProgress(now: { clock.now })
        let failure = ZipImportFailure(fileName: "Knots.docx", message: "Reading its text failed: unreadable")

        let recorder = recordingAnnouncements {
            progress.showArchive("Library Export.zip")
            for number in 1...24 {
                progress.receive(.importingBook(number: number, total: 24, book: "Copy \(number).epub", step: .readingSource))
                progress.receive(.importing(done: number, total: 24, skippedDuplicate: true))
            }
            clock.advance(by: 1)
            progress.end(.batch(ZipImportResult(books: [], failures: [], skippedDuplicates: 24)))

            progress.showArchive("Shelf.zip")
            progress.end(.batch(ZipImportResult(books: [], failures: [], skippedDuplicates: 1)))

            progress.showArchive("Empty.zip")
            progress.end(.batch(ZipImportResult(books: [], failures: [])))

            progress.showArchive("Damaged.zip")
            progress.end(.batch(ZipImportResult(books: [], failures: [failure], skippedDuplicates: 2)))

            progress.showArchive("Stopped.zip")
            progress.end(.batch(ZipImportResult(books: [], failures: [], cancellation: .whileExtracting)))

            progress.showArchive("Late.zip")
            progress.cancel()
            progress.end(.batch(ZipImportResult(books: [], failures: [], skippedDuplicates: 3)))
        }

        XCTAssertEqual(recorder.announcements.map(\.message), [
            "No new books in “Library Export.zip”: all 24 were already in your library.",
            "No new books in “Shelf.zip”: its one book was already in your library.",
            "No books were found in “Empty.zip”.",
            "Cancelling..."
        ])
        XCTAssertEqual(recorder.announcements.map(\.priority), [.high, .high, .high, .high])
        XCTAssertEqual(progress.state, ImportProgressState(), "the end clears the overlay")
    }

    // MARK: - At the Reading List

    /// After an import at the Reading List that ran long, VoiceOver hears
    /// the import end first, at high priority, and the book joining the
    /// list after it, at medium priority, which waits for the speech before
    /// it rather than cutting it off, as the import's quarters wait; the
    /// two are made in this order as an import ends
    /// (`completeSingleImportedBook`). Until October 10, 2026 both were at
    /// high priority, so the second was spoken over the first.
    func testJoiningTheReadingListIsHeardAfterTheImportsEnd() throws {
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        let clock = CommandClock()
        let progress = ImportProgress(now: { clock.now })
        let library = LibraryViewModel(initializeServices: false)
        let book = Book(title: "Atlas of Tides", format: .txt, filePath: "/nowhere/Atlas of Tides.txt", md5Hash: "atlas", folderPath: "Charts")
        library.library = Library(books: [book])

        let recorder = recordingAnnouncements {
            progress.showBook("Atlas of Tides.txt")
            clock.advance(by: 12)
            progress.end(.book)
            library.addImportedBooksToReadingList([book], request: ImportRequest(addsToReadingList: true))
        }

        XCTAssertEqual(recorder.announcements.map(\.message), [
            "Finished importing “Atlas of Tides.txt”.",
            "Added to reading list: Atlas of Tides. The book is in Charts."
        ])
        XCTAssertEqual(recorder.announcements.map(\.priority), [.high, .medium])
    }

    /// Text made into a book with New from Text at the Reading List, through
    /// the library's own queue: the book joining the list is said at medium
    /// priority, so it never cuts off what VoiceOver is saying.
    func testABookJoiningTheReadingListAfterAnImportIsSaidAtMediumPriority() throws {
        let folder = makeIntegrationLibraryFolder("Import Progress Reading List")
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        let heard = HeardAnnouncements()
        let previousPoster = VoiceOverAnnouncer.poster
        VoiceOverAnnouncer.poster = { announcement, _ in heard.announcements.append(announcement) }
        defer { VoiceOverAnnouncer.poster = previousPoster }

        model.createBookFromText(
            title: "Deck Notes",
            author: "",
            text: "Coil the line and dry it before stowing.",
            toFolder: folder.path,
            addingToReadingList: true
        )

        let expected = "Added to reading list: Deck Notes. The book is in \(folder.path)."
        XCTAssertTrue(
            waitUntil(timeout: 10) { heard.announcements.contains { $0.message == expected } },
            heard.announcements.map(\.message).joined(separator: " | ")
        )
        XCTAssertEqual(heard.announcements.first { $0.message == expected }?.priority, .medium)
    }

    /// Cancel is announced at once, in the overlay's own words, and once
    /// however often it is pressed; before any book, it says only that the
    /// import is cancelling. The library's Cancel reaches it.
    func testCancelIsAnnouncedOnceInTheOverlaysWords() {
        let library = LibraryViewModel(initializeServices: false)

        let recorder = recordingAnnouncements {
            library.importProgress.showArchive("Library Export.zip")
            library.importProgress.receive(.extracting(archive: "Library Export.zip", done: 1, total: 3))
            library.cancelImports()
            library.cancelImports()
            library.importProgress.showBook("Moby Dick.epub")
            library.cancelImports()
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Cancelling...", "Cancelling after this book..."])
        XCTAssertEqual(recorder.announcements.map(\.priority), [.high, .high])
    }

    /// `count` books, as a batch's result lists the books it imported.
    private static func books(_ count: Int) -> [Book] {
        (0..<count).map { index in
            Book(title: "Book \(index + 1)", format: .epub, filePath: "/tmp/Book \(index + 1).epub", md5Hash: "\(index + 1)")
        }
    }

    // MARK: - Speak Import Progress

    /// The action is "Speak Import Progress" (config.json's key for it), in
    /// the app's scope, so the key the user gives it works from any window
    /// but the audio editor's, listed in Settings under Information beside
    /// Speak Info, with no key until the user gives it one, and it posts its
    /// own notification.
    func testSpeakImportProgressIsAnActionWithNoKeyBesideSpeakInfo() {
        XCTAssertEqual(ShortcutAction.speakImportProgress.rawValue, "Speak Import Progress")
        XCTAssertEqual(ShortcutAction.speakImportProgress.title, "Speak Import Progress")
        XCTAssertEqual(ShortcutAction(rawValue: "Speak Import Progress"), .speakImportProgress)
        XCTAssertEqual(ShortcutAction.defaultBindings[.speakImportProgress], [])
        XCTAssertEqual(ShortcutAction.speakImportProgress.defaultScope, .app)
        XCTAssertEqual(ShortcutAction.speakImportProgress.category, "Information")
        XCTAssertEqual(ShortcutAction.speakImportProgress.category, ShortcutAction.speakInfo.category)
        XCTAssertEqual(ShortcutAction.speakImportProgress.notificationName, .speakImportProgress)
        XCTAssertEqual(Notification.Name.speakImportProgress.rawValue, "speakImportProgress")
    }

    /// The Library menu, the one shown while a Library window is key,
    /// offers Speak Import Progress, named as the action is.
    func testTheLibraryMenuOffersSpeakImportProgress() throws {
        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        let library = try XCTUnwrap(mainMenu.items.first { $0.title == "Library" }?.submenu, "no Library menu")
        let titles = library.items.map(\.title)
        XCTAssertTrue(titles.contains(ShortcutAction.speakImportProgress.title), titles.joined(separator: ", "))
    }

    /// Speak Import Progress has VoiceOver speak every line the overlay
    /// shows, at once, wherever the user is; with no import under way, it
    /// says so.
    func testSpeakImportProgressSpeaksTheOverlaysLines() {
        let library = LibraryViewModel(initializeServices: false)

        let recorder = recordingAnnouncements {
            library.speakImportProgress()
            library.importProgress.showArchive("Library Export.zip")
            library.importProgress.receive(.importingBook(number: 4, total: 10, book: "Rope Splicing.txt", step: .copying))
            library.speakImportProgress()
        }

        XCTAssertEqual(recorder.announcements.map(\.message), [
            "No import is under way.",
            "Importing Books: 3 of 10 books processed. Book 4 of 10: “Rope Splicing.txt”, copying it into the library."
        ])
        XCTAssertEqual(recorder.announcements.map(\.priority), [.high, .high])
    }

    /// The menu item and the key reach Speak Import Progress through its
    /// notification, which the library answers once it observes it.
    func testTheCommandsNotificationReachesTheLibrary() {
        let library = LibraryViewModel(initializeServices: false)
        library.observeImportProgressRequests()
        library.importProgress.showArchive("Heard on Request.zip")
        let heard = HeardMessages()
        let previousPoster = VoiceOverAnnouncer.poster
        VoiceOverAnnouncer.poster = { announcement, _ in heard.messages.append(announcement.message) }
        defer { VoiceOverAnnouncer.poster = previousPoster }

        NotificationCenter.default.post(name: .speakImportProgress, object: nil)

        XCTAssertTrue(
            waitUntil { heard.messages.contains("Importing Books: Extracting archive...") },
            heard.messages.joined(separator: " | ")
        )
    }

    // MARK: - Fixtures

    /// A TextMouth package named `name`.tmb outside the library, holding a
    /// short plain-text book and a record that describes it, as another
    /// Mac's or a backup's package would; removed when the test ends.
    private func makeExternalPackage(named name: String) throws -> URL {
        let parent = try makeSandboxDirectory("ImportProgressPackage")
        let package = parent.appendingPathComponent("\(name).tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let content = package.appendingPathComponent("\(name).txt")
        try Data("\(name)\n\nFind the hole by its hiss, then roughen the rubber around it.\n".utf8).write(to: content)
        let info = BookInfo(
            metadata: BookMetadata(
                title: name,
                author: "Workshop Notes",
                format: .txt,
                md5Hash: try FileImportService.md5Hash(of: content),
                originalFileName: content.lastPathComponent,
                bookID: UUID()
            ),
            state: BookState(tmbDirectoryName: package.lastPathComponent)
        )
        try info.save(to: package)
        return package
    }

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


/// The messages VoiceOver was asked to speak while a test listened.
@MainActor
private final class HeardMessages {
    /// Every message, oldest first.
    var messages: [String] = []
}

/// The announcements VoiceOver was asked to make, with their priorities,
/// while a test listened.
@MainActor
private final class HeardAnnouncements {
    /// Every announcement, oldest first.
    var announcements: [VoiceOverAnnouncement] = []
}

extension ZipImportProgress {
    /// The extraction of `archive` at `done` of its `total` items, declaring
    /// no bytes, for the tests that count items alone.
    fileprivate static func extracting(archive: String, done: Int, total: Int) -> ZipImportProgress {
        .extracting(archive: archive, progress: ArchiveExtractionProgress(entriesDone: done, entries: total, bytesDone: 0, bytes: 0))
    }
}
