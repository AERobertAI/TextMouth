import AppKit
import Combine
import SwiftUI
import XCTest
@testable import TextMouth

/// Performance regression tests with committed baselines (TODO Q05): what
/// the developer feels most, measured on a generated library and books the
/// size of the developer's, never the live library, and compared with
/// performance-baselines.json. Each number is the median of five runs after
/// an uncounted warm-up run; a test fails when a number is more than twice
/// its baseline, measured twice, and prints a warning at 1.5 times
/// (PerformanceBaselineSupport.swift has the rules, and when the tests skip
/// instead).
///
/// They run with every suite, in well under 90 seconds together. `make
/// check` runs them strictly, never skipping on a busy Mac, and `make
/// perf-baselines` records new baselines after a deliberate change.
@MainActor
final class PerformanceBaselineTests: XCTestCase {

    /// How many list derivations each run of a list measurement averages:
    /// enough that the fastest sort's run takes milliseconds.
    private static let derivationsPerRun = 10
    /// How many live reading positions each run of that measurement
    /// averages: a run takes milliseconds, though one takes microseconds.
    private static let liveUpdatesPerRun = 1_000
    /// How many cloud refreshes each run of that measurement averages: a
    /// refresh of a library outside the cloud takes a fraction of a
    /// millisecond, so a run of a hundred takes tens of milliseconds.
    private static let refreshesPerRun = 100
    /// How many reader publishes each run of the heading sheet measurement
    /// averages, after three that warm it up.
    private static let publishesPerRun = 20
    /// The punctuation pause level the long chapter's speech is prepared
    /// with: subtle, so the pause stage is measured with the rest.
    private static let pauseLevel = 1.0
    /// Each sort's direction in the list measurements: names from A, dates
    /// and sizes from the newest or largest, as the developer reads them.
    private static let sortAscending: [LibrarySortField: Bool] = [
        .title: true, .author: true, .dateAdded: false, .lastOpened: false, .fileSize: false, .manual: true,
    ]

    /// The run every test shares, which compares or records each number.
    private var baselines: PerformanceBaselineRun { .shared }

    /// Skips the test, saying why, unless the baselines apply to this Mac
    /// and it is quiet enough to measure on; a recording run waits for it
    /// to quiet down.
    override func setUp() async throws {
        try await super.setUp()
        try await PerformanceBaselineRun.shared.prepareToMeasure()
    }

    // MARK: - Launch

    /// Launch with the 643 generated books, each in its package with a
    /// current, fingerprinted text cache: reading library.json, the startup
    /// repair, and finding the books whose text caches need rebuilding, as
    /// LibraryViewModel does at startup. The last runs off the main thread
    /// in the app, and is timed here all the same. Before PERF13 the
    /// developer's library held the main thread 165 ms for these.
    func testLaunch() throws {
        let index = try captureLibraryIndex()
        let library = try PerformanceFixtures.writeLibraryOnDisk(for: self)
        try index.stageValid(library, at: index.indexURL)
        let fixtureBooks = Set(library.books.map(\.id))

        /// One launch, and what it found: the timed part leaves out making
        /// the model, which the app does before its window shows.
        func launch() -> (model: LibraryViewModel, milliseconds: Double, staleCaches: [Book]) {
            let model = LibraryViewModel(initializeServices: false)
            var staleCaches: [Book] = []
            let milliseconds = PerformanceClock.milliseconds {
                model.loadLibraryIndex()
                staleCaches = LibraryViewModel.booksNeedingCacheUpdate(model.library.books, access: .live)
            }
            return (model, milliseconds, staleCaches)
        }

        // A first launch, untimed, repairs whatever else the hosted test
        // root holds, and its save is written now, so every timed launch
        // reads the same index and repairs nothing.
        let first = launch()
        LibraryPersistenceService.flushPendingSave()
        XCTAssertTrue(
            fixtureBooks.isSubset(of: first.model.library.books.map(\.id)),
            "a generated book was lost at launch"
        )
        XCTAssertFalse(
            first.staleCaches.contains { fixtureBooks.contains($0.id) },
            "a generated book's text cache was found stale, so launch would rebuild it"
        )

        try baselines.check(.launch) { launch().milliseconds }
    }

    // MARK: - The Library List

    /// One derivation of the 643-book All Items list for each sort, the
    /// work a Library window does once per change of the library that moves
    /// a book (PERF10), and the first File Size sort, which measures every
    /// book's package once (PERF10's "about 330 ms by File Size").
    func testLibraryListDerivations() throws {
        let filesFolder = try LibraryBenchmarkFixture.makeFilesFolder(for: self)
        let library = try LibraryBenchmarkFixture.library(filesIn: filesFolder)
        let allItems = LibraryLocation(category: .allItems, folderPath: "")

        // The first File Size sort of a library model, as after launch.
        try baselines.check(.firstSortByFileSize) {
            let model = Self.listModel(of: library, sortedBy: .fileSize, at: allItems)
            let milliseconds = PerformanceClock.milliseconds { _ = model.displayedBooks(at: allItems) }
            guard model.listCache.fileMeasurementCount == library.books.count else {
                throw PerformanceBaselineError.fixture(
                    "the first File Size sort measured \(model.listCache.fileMeasurementCount) packages, "
                        + "not \(library.books.count)"
                )
            }
            return milliseconds
        }

        // One derivation per sort, each after a book moved to another
        // folder, a change every list follows.
        let model = Self.listModel(of: library, sortedBy: .title, at: allItems)
        for field in LibrarySortField.allCases {
            Self.sort(model, by: field, at: allItems)
            // Derived once, so a File Size list has measured its packages.
            _ = model.displayedBooks(at: allItems)
            try baselines.check(.listDerivation(field)) {
                var total = 0.0
                for _ in 0..<Self.derivationsPerRun {
                    LibraryBenchmarkFixture.moveOneBook(in: model)
                    let derivationsBefore = model.listCache.derivationCount
                    total += PerformanceClock.milliseconds { _ = model.displayedBooks(at: allItems) }
                    guard model.listCache.derivationCount == derivationsBefore + 1 else {
                        throw PerformanceBaselineError.fixture("a read of the \(field.rawValue) list did not derive it once")
                    }
                }
                return total / Double(Self.derivationsPerRun)
            }
        }
    }

    /// A library model holding `library`, its All Items list sorted by
    /// `field`. Nothing is saved.
    private static func listModel(
        of library: Library,
        sortedBy field: LibrarySortField,
        at location: LibraryLocation
    ) -> LibraryViewModel {
        let model = LibraryViewModel(initializeServices: false)
        model.library = library
        sort(model, by: field, at: location)
        return model
    }

    /// Sorts `model`'s list at `location` by `field`, in the field's
    /// direction. Set on the library itself: the model's own setter would
    /// save this generated library over the hosted test root's index.
    private static func sort(_ model: LibraryViewModel, by field: LibrarySortField, at location: LibraryLocation) {
        model.library.setSortSetting(
            FolderSortSetting(sortField: field, sortAscending: sortAscending[field] ?? true),
            for: location.sortSettingsKey
        )
    }

    // MARK: - Listening

    /// One live reading position in the 643-book library, as a playing
    /// reader reports about once a second; the playing book's row watches
    /// its entry, as BookRow does. Before PERF11 each one republished the
    /// whole library.
    func testLiveReadingPositionUpdate() throws {
        let model = LibraryViewModel(initializeServices: false)
        model.library = try LibraryBenchmarkFixture.library()
        let bookID = model.library.books[model.library.books.count / 2].id
        var rowRedraws = 0
        let row = model.livePositions.entry(for: bookID).objectWillChange.sink { rowRedraws += 1 }
        defer { row.cancel() }
        var offset = 0

        try baselines.check(.liveReadingPosition) {
            let milliseconds = PerformanceClock.milliseconds {
                for _ in 0..<Self.liveUpdatesPerRun {
                    offset += 15
                    model.updateLiveReadingPosition(
                        bookID: bookID,
                        position: ReadingPosition(chapterIndex: 0, characterOffset: offset, globalCharacterOffset: offset)
                    )
                }
            }
            return milliseconds * 1_000 / Double(Self.liveUpdatesPerRun)
        }
        XCTAssertGreaterThan(rowRedraws, 0, "the playing book's row never heard its live position")
    }

    /// The bytes one 30-second reading checkpoint writes for a book whose
    /// record is as large as the developer's largest, in a 643-book
    /// library: every file it rewrites within the half second its record
    /// waits. Before PERF15 each one rewrote library.json and the whole
    /// record, 1,305,075 bytes.
    func testReadingCheckpointBytes() throws {
        _ = try captureLibraryIndex()
        let folder = makeIntegrationLibraryFolder("Performance Checkpoint")
        let book = try PerformanceFixtures.bookWithLargestRecord(in: folder)
        let model = LibraryViewModel(initializeServices: false)
        model.library = PersistenceCostTests.library(holding: book, besides: LibraryBenchmarkFixture.bookCount - 1)
        model.save()
        LibraryPersistenceService.flushPendingSave()
        let files = PersistenceCostTests.checkpointFiles(of: book)
        var checkpoint = 0

        try baselines.check(.checkpointBytes) {
            checkpoint += 1
            let before = files.map(PersistenceCostTests.identity(of:))
            model.persistReadingPosition(
                bookID: book.id,
                position: ReadingPosition(chapterIndex: 1, characterOffset: 100 * checkpoint)
            )
            waitPastLibrarySaveDebounce()
            let rewritten = zip(files, before).filter { PersistenceCostTests.identity(of: $0.0) != $0.1 }.map(\.0)
            guard !rewritten.isEmpty else {
                throw PerformanceBaselineError.fixture("checkpoint \(checkpoint) wrote nothing")
            }
            return Double(rewritten.map(PersistenceCostTests.size(of:)).reduce(0, +))
        }
    }

    // MARK: - Opening Books

    /// Opening the 1 MB EPUB for the first time, imported as the developer
    /// imports a book, in a reader with the developer's 16 substitution
    /// rules, until the speech of the chapter it opens at is prepared, as
    /// Play needs it. Each run, the warm-up's too, starts with nothing of
    /// the book kept on this Mac: the reading text the run before kept
    /// (`ReadingTextCache`) is forgotten first, so every run parses the
    /// book's content.md and keeps its reading text anew.
    func testOpeningTheEPUB() throws {
        let epub = try importOneMegabyteEPUB("Performance Open EPUB")

        try baselines.check(.openTextBook) {
            Self.forgetKeptReadingText(of: epub.book)
            let milliseconds = try millisecondsToOpenedChapterSpeech(of: epub)
            // Only an open that parsed content.md keeps its reading text.
            guard Self.keptReadingTextFile(of: epub.book) != nil else {
                throw PerformanceBaselineError.fixture(
                    "the first open kept no reading text, so it may not have parsed content.md"
                )
            }
            return milliseconds
        }
    }

    /// Opening the 1 MB EPUB again, as each later open of a book of a
    /// megabyte or more opens it: from the reading text this Mac kept when
    /// the book was first opened, which an untimed open keeps before the
    /// runs. Each run checks that it read that reading text, rather than
    /// parse content.md and keep its reading text anew, so the number can
    /// never quietly measure a first open.
    func testOpeningTheEPUBFromItsKeptReadingText() throws {
        let epub = try importOneMegabyteEPUB("Performance Reopen EPUB")
        _ = try millisecondsToOpenedChapterSpeech(of: epub)
        guard let kept = Self.keptReadingTextFile(of: epub.book) else {
            throw PerformanceBaselineError.fixture("the first open kept no reading text for the 1 MB EPUB")
        }

        try baselines.check(.openTextBookCached) {
            let milliseconds = try millisecondsToOpenedChapterSpeech(of: epub)
            guard Self.keptReadingTextFile(of: epub.book) == kept else {
                throw PerformanceBaselineError.fixture(
                    "the open parsed content.md again instead of reading the kept reading text"
                )
            }
            return milliseconds
        }
    }

    /// Opening a 3-file audiobook, each chapter a silent track of its own,
    /// in a reader until it has loaded. Nothing plays.
    func testOpeningTheAudiobook() throws {
        let world = try makeIntegrationWorld("Performance Open Audiobook")
        let book = try world.makeSilentAudioBook(title: "Three Tracks", trackDurations: [2, 2, 2])
        let substitutions = TextSubstitutionService(rules: [])

        try baselines.check(.openAudiobook) {
            let start = ContinuousClock.now
            let reader = try openReader(on: book, in: world, substitutions: substitutions)
            defer { reader.close() }
            guard reader.content?.chapters.count == 3 else {
                throw PerformanceBaselineError.fixture("the audiobook did not open with its three chapters")
            }
            return PerformanceClock.milliseconds(since: start)
        }
    }

    /// The 1 MB EPUB imported into a world of a test's own, and the
    /// developer's 16 substitution rules, which its readers apply.
    private struct ImportedEPUB {
        let world: IntegrationWorld
        let book: Book
        let rules: TextSubstitutionService
    }

    /// The 1 MB EPUB, imported as the developer imports a book into a world
    /// of the test's own named after `label`.
    private func importOneMegabyteEPUB(_ label: String) throws -> ImportedEPUB {
        let world = try makeIntegrationWorld(label)
        return ImportedEPUB(
            world: world,
            book: try world.importBook(from: try PerformanceFixtures.oneMegabyteEPUB(for: self)),
            rules: TextSubstitutionService(rules: try PerformanceFixtures.developerSubstitutionRules())
        )
    }

    /// Milliseconds from opening a reader on `epub` until the speech of the
    /// chapter it opens at is prepared, as Play needs it. The reader is
    /// closed afterwards.
    private func millisecondsToOpenedChapterSpeech(of epub: ImportedEPUB) throws -> Double {
        let start = ContinuousClock.now
        let reader = try openReader(on: epub.book, in: epub.world, substitutions: epub.rules)
        defer { reader.close() }
        guard let speech = reader.preparedSpeech(forChapterAt: reader.currentChapterIndex), !speech.text.isEmpty else {
            throw PerformanceBaselineError.fixture("the EPUB's first chapter has no speech")
        }
        return PerformanceClock.milliseconds(since: start)
    }

    /// Forgets the reading text this Mac kept for `book`, through the
    /// cache's own API, once every store an earlier open queued has ended,
    /// so the next open parses the book's content.md, as a first open does.
    private static func forgetKeptReadingText(of book: Book) {
        ReadingTextCache.waitForBackgroundWork()
        ReadingTextCache.shared.remove(bookID: book.id)
    }

    /// The file number of the file in which this Mac keeps `book`'s reading
    /// text, once every store queued has ended, or nil when none is kept.
    /// An open that reads the kept text leaves that very file in place; an
    /// open that parses content.md keeps the text anew, in another file
    /// renamed into its place, which has another number.
    private static func keptReadingTextFile(of book: Book) -> Int? {
        ReadingTextCache.waitForBackgroundWork()
        let kept = ReadingTextCache.shared.url(for: book.id)
        let attributes = try? FileManager.default.attributesOfItem(atPath: kept.path)
        return (attributes?[.systemFileNumber] as? NSNumber)?.intValue
    }

    /// A reader on `book` in `world`, opened as its window opens one, once
    /// it has loaded; it renders nothing and loads no voice.
    private func openReader(
        on book: Book,
        in world: IntegrationWorld,
        substitutions: TextSubstitutionService
    ) throws -> ReaderViewModel {
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: world.library,
            settingsViewModel: world.settings,
            substitutionService: substitutions,
            autoplayRequests: world.autoplayRequests,
            notificationCenter: world.notifications,
            renderScheduler: SilentRenderQueue()
        )
        guard runMainLoopPromptly(until: { !reader.isLoading }, timeout: 30), reader.errorMessage == nil else {
            reader.close()
            throw PerformanceBaselineError.fixture(
                "\(book.title) did not load: \(reader.errorMessage ?? "it was still loading after 30 seconds")"
            )
        }
        return reader
    }

    // MARK: - Speech

    /// Preparing the speech of a chapter of a million characters with the
    /// developer's 16 substitution rules, subtle punctuation pauses, and the
    /// standard repeated-symbol rule: what the look-ahead does off the main
    /// thread before such a chapter, and Play on it otherwise. Before PERF01
    /// the rules alone took 3.4 s.
    func testSpeechPreparationOfAMillionCharacterChapter() throws {
        let rules = try PerformanceFixtures.developerSubstitutionRules()
        XCTAssertEqual(rules.count, 16, "the developer's rules")
        let substitutions = TextSubstitutionService(rules: rules)
        let chapter = PerformanceFixtures.millionCharacterChapter()

        try baselines.check(.speechPreparation) {
            // A copy of its own, so no run is faster for an earlier run's
            // work on the same string (`freshCopy(of:)`).
            let inputs = ChapterSpeechInputs(
                chapterIndex: 0,
                text: freshCopy(of: chapter),
                chapterHeadings: [],
                bookSkippedHeadingIDs: [],
                repeatedSymbolRule: substitutions.repeatedSymbolRule,
                punctuationPauseLevel: Self.pauseLevel,
                substitutions: substitutions.substitutionPass
            )
            // Kept past the timing, so freeing it is not timed.
            var speech: ReaderViewModel.ChapterSpeech?
            let milliseconds = PerformanceClock.milliseconds { speech = inputs.prepare() }
            guard let speech, speech.text.utf16.count >= PerformanceFixtures.longChapterLength / 2 else {
                throw PerformanceBaselineError.fixture("the chapter's speech came out short")
            }
            return milliseconds
        }
    }

    /// The memory the rendered speech of a 40,000-character chapter, the
    /// developer's 90th percentile, takes while it is built and keeps once
    /// built. Before PERF04 it peaked at 216 MB and kept 87.
    func testRenderedSpeechMemory() throws {
        try baselines.check([.renderPeakMemory, .renderKeptMemory]) {
            let memory = try PerformanceFixtures.renderedSpeechMemory(units: 40_000)
            return [memory.peakMegabytes, memory.keptMegabytes]
        }
    }

    // MARK: - Importing

    /// Extracting the 1 MB EPUB's text into content.md, with its index and
    /// fingerprints, as an import and Redo Text Extraction do.
    func testEPUBExtraction() throws {
        let folder = makeIntegrationLibraryFolder("Performance EPUB")
        let book = try PerformanceFixtures.packagedEPUBBook(try PerformanceFixtures.oneMegabyteEPUB(for: self), in: folder)

        try baselines.check(.epubExtraction) {
            // Kept past the timing, so freeing it is not timed.
            var extracted: MarkdownCacheService.GeneratedCache?
            let milliseconds = try PerformanceClock.milliseconds {
                extracted = try MarkdownCacheService.generateReportedCacheContent(for: book)
            }
            guard let chapters = extracted?.content.chapters, chapters.count == PerformanceFixtures.epubDocumentCount else {
                throw PerformanceBaselineError.fixture(
                    "the EPUB was extracted into \(extracted?.content.chapters.count ?? 0) chapters, "
                        + "not \(PerformanceFixtures.epubDocumentCount)"
                )
            }
            return milliseconds
        }
    }

    // MARK: - The Cloud

    /// The processor time of one cloud refresh of the 643 books in a
    /// library outside the cloud, as every visible Library window makes
    /// each minute: the library's location is read once and nothing else
    /// (PERF16; 82 ms before it). Processor time, on every thread, rather
    /// than the time it takes: the refresh hands its little work to a
    /// utility thread and back, and on a busy Mac those hops wait several
    /// times longer while the work stays the same.
    func testCloudRefreshOfALocalLibrary() async throws {
        let packages = PerformanceFixtures.cloudRefreshPackages()
        let storage = BookCloudStorageService(items: UbiquitousItemStatusProvider())
        let states = BookCloudStates()

        try await baselines.checkAwaiting(.cloudRefresh) {
            let start = PerformanceClock.processCPUNanoseconds()
            for _ in 0..<Self.refreshesPerRun {
                await states.refresh(packages, using: storage)
            }
            let nanoseconds = PerformanceClock.processCPUNanoseconds() - start
            return Double(nanoseconds) / 1_000_000 / Double(Self.refreshesPerRun)
        }
        XCTAssertEqual(states.libraryLocation, .local, "the hosted test root is not in a cloud location")
        XCTAssertEqual(states.states, [:], "a local library's refresh recorded cloud states")
    }

    // MARK: - The Headings Sheet

    /// The main-thread time one reader publish, eight a second while a book
    /// plays, costs the open Headings sheet of a book of 180 headings,
    /// presented as ReaderView presents it, in an offscreen window that
    /// never comes forward. Before PERF30 it was 19 ms with 179 headings.
    func testHeadingSheetPerPublish() throws {
        _ = try captureLibraryIndex()
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        let book = try makeMarkdownBook(chapters: 36, charactersPerChapter: 6_000, sectionsPerChapter: 4)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: model,
            settingsViewModel: settings,
            notificationCenter: NotificationCenter(),
            renderScheduler: SilentRenderQueue()
        )
        defer { reader.close() }
        guard runMainLoopPromptly(until: { !reader.isLoading }, timeout: 60) else {
            throw PerformanceBaselineError.fixture("the 180-heading book did not load")
        }
        XCTAssertEqual(reader.headings.count, 180)
        let hosted = hostOffscreen(
            ReaderSheetHost(reader: reader) { HeadingNavigatorView(viewModel: $0) },
            size: NSSize(width: 600, height: 700)
        )
        defer { takeDown(hosted.window) }
        settle(hosted.hostingView, seconds: 1.5)

        try baselines.check(.headingSheetPublish) {
            for _ in 0..<3 {
                reader.objectWillChange.send()
                flush(hosted.hostingView)
            }
            let start = PerformanceClock.threadCPUNanoseconds()
            for _ in 0..<Self.publishesPerRun {
                reader.objectWillChange.send()
                flush(hosted.hostingView)
            }
            let nanoseconds = PerformanceClock.threadCPUNanoseconds() - start
            return Double(nanoseconds) / 1_000_000 / Double(Self.publishesPerRun)
        }
    }

    // MARK: - Support

    /// Captures the hosted test root's library index, which the test's
    /// models may save over, and puts it back when the test ends.
    private func captureLibraryIndex() throws -> LibraryIndexSandbox {
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        return sandbox
    }
}
