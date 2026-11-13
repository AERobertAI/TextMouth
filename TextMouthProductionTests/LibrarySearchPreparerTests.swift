import Combine
import Foundation
import os
import XCTest
@testable import TextMouth

// MARK: - Fixtures

/// The reports of the passes a preparer ended, recorded from its lanes.
private final class PassReports: Sendable {
    private let reports = OSAllocatedUnfairLock<[LibrarySearchPreparer.PassReport]>(initialState: [])

    /// Notes a pass that ended.
    func record(_ report: LibrarySearchPreparer.PassReport) {
        reports.withLock { $0.append(report) }
    }

    var all: [LibrarySearchPreparer.PassReport] { reports.withLock { $0 } }

    /// Waits, for at most `timeout` seconds, until `count` passes have
    /// ended; false when they did not, which the test then fails on.
    func wait(for count: Int, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while all.count < count {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }
}

/// The reads of books' content.md a preparer made, each with the quality of
/// service of the thread it was made on, and a hook the test runs as a
/// given book is read, as a search starting then would.
private final class ReadLog: Sendable {
    /// One read: the content.md's path, and the thread's quality of service.
    struct Read: Equatable, Sendable {
        let path: String
        let qos: UInt32
    }

    private let reads = OSAllocatedUnfairLock<[Read]>(initialState: [])
    private let hooks = OSAllocatedUnfairLock<[String: @Sendable () -> Void]>(initialState: [:])

    /// Runs `hook`, once, when the content.md at `url` is read.
    func onRead(of url: URL, _ hook: @escaping @Sendable () -> Void) {
        hooks.withLock { $0[url.standardizedFileURL.path] = hook }
    }

    /// Notes a read of `url` on this thread, and runs its hook, if any.
    func note(_ url: URL) {
        let path = url.standardizedFileURL.path
        reads.withLock { $0.append(Read(path: path, qos: qos_class_self().rawValue)) }
        let hook = hooks.withLock { $0.removeValue(forKey: path) }
        hook?()
    }

    var all: [Read] { reads.withLock { $0 } }

    /// How many times the content.md at `url` was read.
    func count(of url: URL) -> Int {
        let path = url.standardizedFileURL.path
        return all.filter { $0.path == path }.count
    }

    /// A file access that notes every read here, and calls the files of
    /// `inCloud` dataless.
    func access(inCloud: Set<String> = []) -> MaintenanceFileAccess {
        MaintenanceFileAccess(
            isDataless: { inCloud.contains($0.standardizedFileURL.path) },
            refusesRead: { url in
                self.note(url)
                return false
            }
        )
    }
}

/// A preparer reached from a file access made before it.
private final class PreparerBox: Sendable {
    private let preparer = OSAllocatedUnfairLock<LibrarySearchPreparer?>(initialState: nil)

    var value: LibrarySearchPreparer? {
        get { preparer.withLock { $0 } }
        set { preparer.withLock { $0 = newValue } }
    }
}

/// Whether Low Power Mode is on, as a test sets it.
private final class PowerSwitch: Sendable {
    private let isOn = OSAllocatedUnfairLock(initialState: false)

    var lowPowerMode: Bool {
        get { isOn.withLock { $0 } }
        set { isOn.withLock { $0 = newValue } }
    }
}

/// A synthetic library: each book's content.md in a package of its own,
/// and a store in a folder of its own, all in the sandbox.
private struct PreparerLibrary {
    let books: [LibrarySearchBook]
    let store: LibrarySearchTextStore

    /// Whether the store holds a file for `book`.
    func isKept(_ book: LibrarySearchBook) -> Bool {
        FileManager.default.fileExists(atPath: store.url(for: book.id).path)
    }
}

extension XCTestCase {
    /// `count` books of two chapters each, with a store whose room on the
    /// disk `space` decides (the disk's own by default).
    fileprivate func makePreparerLibrary(_ count: Int, space: LibrarySearchTextSpace = LibrarySearchTextSpace()) throws -> PreparerLibrary {
        let folder = try makeSandboxDirectory("LibrarySearchPreparer")
        let books = try (0..<count).map { index -> LibrarySearchBook in
            let package = folder.appendingPathComponent("Library/Book \(index).tmb", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let content = package.appendingPathComponent("content.md")
            let markdown = "<!-- chapter: One -->\nThe fox of book \(index).\n\n<!-- chapter: Two -->\nThe hound ran on."
            try Data(markdown.utf8).write(to: content)
            return LibrarySearchBook(
                id: UUID(), title: "Book \(index)", author: "Test", contentURL: content, packageURL: package, isAudiobook: false
            )
        }
        let store = LibrarySearchTextStore(folder: folder.appendingPathComponent("Store", isDirectory: true), space: space)
        return PreparerLibrary(books: books, store: store)
    }

    /// A preparer of `library`'s store, reaching files through `access`,
    /// reading Low Power Mode from `power`, and reporting into `reports`.
    fileprivate func makePreparer(
        _ library: PreparerLibrary,
        access: MaintenanceFileAccess = .live,
        lanes: Int = 2,
        power: PowerSwitch = PowerSwitch(),
        reports: PassReports
    ) -> LibrarySearchPreparer {
        LibrarySearchPreparer(
            store: library.store,
            fileAccess: access,
            lanes: lanes,
            isLowPowerMode: { power.lowPowerMode },
            onPassEnded: { reports.record($0) }
        )
    }
}

// MARK: - The Preparer

/// Search Library's background preparation (`LibrarySearchPreparer`): a
/// pass prepares the books the store does not hold, finds the rest prepared
/// with a stat and a header read, yields to a search, ends in Low Power Mode
/// and on a full disk, never reads a book in the cloud, sweeps the texts of
/// other books after a pass, and prepares at the priority asked. Every book
/// is a synthetic one made by the test in the sandbox; none is the user's.
final class LibrarySearchPreparerTests: XCTestCase {

    // MARK: Preparing

    /// A pass prepares every book the store does not hold and ends finished;
    /// a search then prepares nothing; and a second pass over the unchanged
    /// library finds every book prepared, reading no content.md, so it costs
    /// a stat and a header read a book.
    func testAPassPreparesEveryBookAndASecondFindsThemPrepared() throws {
        let library = try makePreparerLibrary(12)
        let reads = ReadLog()
        let reports = PassReports()
        let preparer = makePreparer(library, access: reads.access(), reports: reports)

        preparer.start(library.books)
        XCTAssertTrue(reports.wait(for: 1), "the first pass never ended")

        let first = try XCTUnwrap(reports.all.first)
        XCTAssertEqual(first.ending, .finished)
        XCTAssertEqual(first.progress.booksPrepared, 12, "\(first.progress)")
        XCTAssertEqual(first.progress.booksDone, 12, "\(first.progress)")
        XCTAssertTrue(library.books.allSatisfy(library.isKept), "a book's text was not kept")
        XCTAssertFalse(preparer.isRunning)
        let outcome = LibrarySearchEngine.search(
            query: "fox", options: TextSearchOptions(), in: library.books, store: library.store,
            isCancelled: { false }, report: { _, _ in }
        )
        guard case .finished(let tally) = outcome else { return XCTFail("the search gave \(outcome)") }
        XCTAssertEqual(tally.booksPrepared, 0, "the search prepared books the pass had prepared: \(tally)")
        XCTAssertEqual(tally.matches, 12)

        let readsBefore = reads.all.count
        preparer.start(library.books)
        XCTAssertTrue(reports.wait(for: 2), "the second pass never ended")

        let second = try XCTUnwrap(reports.all.last)
        XCTAssertEqual(second.ending, .finished)
        XCTAssertEqual(second.progress.booksAlreadyPrepared, 12, "\(second.progress)")
        XCTAssertEqual(second.progress.booksPrepared, 0, "\(second.progress)")
        XCTAssertEqual(reads.all.count, readsBefore, "the pass over an unchanged library read a content.md")
    }

    /// A book whose content.md changed since its text was kept, as Edit Text
    /// changes it, is prepared again; the others are found prepared.
    func testAPassPreparesOnlyTheBooksThatChanged() throws {
        let library = try makePreparerLibrary(6)
        let reports = PassReports()
        let preparer = makePreparer(library, reports: reports)
        preparer.start(library.books)
        XCTAssertTrue(reports.wait(for: 1), "the first pass never ended")
        let changed = library.books[3]
        try Data("<!-- chapter: One -->\nA new text with the fox twice: fox.".utf8).write(to: changed.contentURL)

        preparer.start(library.books)
        XCTAssertTrue(reports.wait(for: 2), "the second pass never ended")

        let second = try XCTUnwrap(reports.all.last)
        XCTAssertEqual(second.progress.booksPrepared, 1, "\(second.progress)")
        XCTAssertEqual(second.progress.booksAlreadyPrepared, 5, "\(second.progress)")
    }

    // MARK: Out of the Way of a Search

    /// A pass started while a search pauses the preparer begins nothing until
    /// the search ends, and then prepares every book.
    func testAPassWaitsWhileASearchPausesIt() throws {
        let library = try makePreparerLibrary(5)
        let reports = PassReports()
        let preparer = makePreparer(library, reports: reports)

        preparer.pause()
        preparer.start(library.books)
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertTrue(preparer.isRunning, "a paused pass should wait, not end")
        XCTAssertEqual(preparer.progress.booksDone, 0, "a book was prepared while a search paused the preparer")
        XCTAssertFalse(library.books.contains(where: library.isKept), "a text was kept while paused")

        preparer.resume()
        XCTAssertTrue(reports.wait(for: 1), "the pass never ended after the search")
        XCTAssertEqual(reports.all.first?.progress.booksPrepared, 5)
    }

    /// A search that starts while a book is read stops the pass there: that
    /// book is read but not parsed or kept, no later book is begun, and the
    /// pass waits; once the search ends, it prepares the rest, the stopped
    /// book included, and finishes. The search starts from the file access,
    /// at the very moment of the read.
    func testASearchStartingDuringAReadStopsThePassBeforeItsParse() throws {
        let library = try makePreparerLibrary(6)
        let reads = ReadLog()
        let reports = PassReports()
        let box = PreparerBox()
        let preparer = makePreparer(library, access: reads.access(), lanes: 1, reports: reports)
        box.value = preparer
        let stopped = library.books[2]
        reads.onRead(of: stopped.contentURL) { box.value?.pause() }

        preparer.start(library.books)
        // The lane, stopped at the third book, ends its turn.
        let deadline = Date().addingTimeInterval(10)
        while reads.count(of: stopped.contentURL) == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertEqual(preparer.progress.booksPrepared, 2, "the books before the search: \(preparer.progress)")
        XCTAssertFalse(library.isKept(stopped), "the book read as the search started was parsed and kept")
        XCTAssertFalse(library.books[3...].contains(where: library.isKept), "a book after the search began was prepared")
        XCTAssertTrue(preparer.isRunning, "the paused pass ended")

        preparer.resume()
        XCTAssertTrue(reports.wait(for: 1), "the pass never ended after the search")
        XCTAssertEqual(reports.all.first?.ending, .finished)
        XCTAssertEqual(reports.all.first?.progress.booksPrepared, 6, "\(String(describing: reports.all.first))")
        XCTAssertTrue(library.books.allSatisfy(library.isKept), "a book was left unprepared")
        XCTAssertEqual(reads.count(of: stopped.contentURL), 2, "the stopped book is read again, once")
    }

    /// The engine's runner, which the Search Library window's searches and
    /// Show All run through, pauses the background preparation while it
    /// searches and lets it go once the search ends, so a search has the
    /// processor to itself.
    func testTheEngineRunnerPausesThePreparationWhileItSearches() throws {
        let library = try makePreparerLibrary(3)
        let preparer = makePreparer(library, reports: PassReports())
        let runner = LibrarySearchModel.engineRunner(store: library.store, preparer: preparer)
        let pausedAtEachBook = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        XCTAssertFalse(preparer.isPaused, "a new preparer is paused")

        let outcome = runner("fox", TextSearchOptions(), library.books, .library, { false }) { _, _ in
            pausedAtEachBook.withLock { $0.append(preparer.isPaused) }
        }

        guard case .finished(let tally) = outcome else { return XCTFail("the search gave \(outcome)") }
        XCTAssertEqual(tally.matches, 3, "\(tally)")
        XCTAssertEqual(pausedAtEachBook.withLock { $0 }, [true, true, true], "the preparation was not paused during the search")
        XCTAssertFalse(preparer.isPaused, "the preparation was left paused after the search")
    }

    // MARK: When Not to Prepare

    /// No pass starts in Low Power Mode, and Low Power Mode coming on ends
    /// a pass under way at its next book.
    func testLowPowerModeStartsNoPassAndEndsOneUnderWay() throws {
        let library = try makePreparerLibrary(6)
        let reads = ReadLog()
        let reports = PassReports()
        let power = PowerSwitch()
        let preparer = makePreparer(library, access: reads.access(), lanes: 1, power: power, reports: reports)

        power.lowPowerMode = true
        preparer.start(library.books)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(preparer.isRunning, "a pass started in Low Power Mode")
        XCTAssertEqual(reads.all.count, 0, "a content.md was read in Low Power Mode")

        power.lowPowerMode = false
        reads.onRead(of: library.books[1].contentURL) { power.lowPowerMode = true }
        preparer.start(library.books)
        XCTAssertTrue(reports.wait(for: 1), "the pass never ended when Low Power Mode came on")

        let report = try XCTUnwrap(reports.all.first)
        XCTAssertEqual(report.ending, .lowPowerMode)
        XCTAssertEqual(report.progress.booksPrepared, 2, "the book being read when it came on is still kept: \(report.progress)")
        XCTAssertFalse(library.books[2...].contains(where: library.isKept), "a book was begun in Low Power Mode")
    }

    /// A book whose content.md is only in the cloud is counted and never
    /// read, so the preparation downloads nothing.
    func testABookInTheCloudIsNeverRead() throws {
        let library = try makePreparerLibrary(3)
        let cloudBook = library.books[1]
        let reads = ReadLog()
        let reports = PassReports()
        let preparer = makePreparer(
            library, access: reads.access(inCloud: [cloudBook.contentURL.standardizedFileURL.path]), reports: reports
        )

        preparer.start(library.books)
        XCTAssertTrue(reports.wait(for: 1), "the pass never ended")

        XCTAssertEqual(reports.all.first?.progress.booksInCloud, 1)
        XCTAssertEqual(reports.all.first?.progress.booksPrepared, 2)
        XCTAssertEqual(reads.count(of: cloudBook.contentURL), 0, "the book in the cloud was read")
        XCTAssertFalse(library.isKept(cloudBook))
    }

    /// A disk without room for another text, the app's reserve kept, ends
    /// the pass before it reads or parses a book it could not keep.
    func testAFullDiskEndsThePassBeforeAnyParse() throws {
        let library = try makePreparerLibrary(4, space: LibrarySearchTextSpace(reserve: 1_000_000_000, freeSpace: { _ in 1_000 }))
        let reads = ReadLog()
        let reports = PassReports()
        let preparer = makePreparer(library, access: reads.access(), reports: reports)

        preparer.start(library.books)
        XCTAssertTrue(reports.wait(for: 1), "the pass never ended on a full disk")

        XCTAssertEqual(reports.all.first?.ending, .noRoom)
        XCTAssertEqual(reports.all.first?.progress.booksPrepared, 0)
        XCTAssertEqual(reads.all.count, 0, "a content.md was read for a text the disk had no room for")
        XCTAssertFalse(preparer.isRunning)
    }

    // MARK: Sweeping and Priority

    /// A pass that finished sweeps the store, keeping its books' texts and
    /// removing another book's; a pass that ended otherwise sweeps nothing.
    func testAFinishedPassSweepsTheTextsOfOtherBooks() throws {
        let library = try makePreparerLibrary(3)
        let reports = PassReports()
        let preparer = makePreparer(library, reports: reports)
        let stranger = UUID()
        try library.store.store(
            LibrarySearchTextBook(parsed: [Chapter(title: "One", text: "A book no longer in the library.")]),
            for: stranger,
            key: LibrarySearchTextKey(
                content: ContentFileIdentity(byteCount: 1, modificationTimeNanoseconds: 1, statusChangeTimeNanoseconds: 1, inode: 1),
                bookTitle: "Gone"
            )
        )

        preparer.start(library.books)
        XCTAssertTrue(reports.wait(for: 1), "the pass never ended")

        XCTAssertFalse(FileManager.default.fileExists(atPath: library.store.url(for: stranger).path), "another book's text was kept")
        XCTAssertTrue(library.books.allSatisfy(library.isKept), "a book of the pass lost its text")
    }

    /// Books are prepared at background priority, and at user-initiated
    /// priority once the preparer is raised, as the Search Library window
    /// raises it on opening: the read of each book is made on a thread of
    /// the priority asked by the time it begins.
    func testRaisingThePriorityPreparesTheNextBooksSooner() throws {
        let library = try makePreparerLibrary(5)
        let reads = ReadLog()
        let reports = PassReports()
        let box = PreparerBox()
        let preparer = makePreparer(library, access: reads.access(), lanes: 1, reports: reports)
        box.value = preparer
        reads.onRead(of: library.books[1].contentURL) { box.value?.setPriority(.raised) }
        XCTAssertEqual(preparer.priority, .background, "a preparer starts at background priority")

        preparer.start(library.books)
        XCTAssertTrue(reports.wait(for: 1), "the pass never ended")

        let qos = reads.all.map(\.qos)
        XCTAssertEqual(qos.count, 5, "reads: \(reads.all)")
        XCTAssertEqual(Array(qos.prefix(2)), [QOS_CLASS_BACKGROUND.rawValue, QOS_CLASS_BACKGROUND.rawValue], "before it was raised")
        XCTAssertEqual(Array(qos.suffix(3)), Array(repeating: QOS_CLASS_USER_INITIATED.rawValue, count: 3), "after it was raised")
        XCTAssertEqual(preparer.priority, .raised)
    }
}

// MARK: - When the App Prepares

/// When the app prepares (`LibrarySearchPreparation`): a pass starts once
/// the library is ready and not before, and again when the Search Library
/// window opens with none under way; the window raises the priority while
/// it is open; a data-directory move and Low Power Mode each stop a pass,
/// and a pass starts afresh once they are over; and a coordinator that is
/// not enabled, as in a process hosting tests, prepares nothing. Each
/// coordinator has a preparer, a notification center, and a power switch
/// of its own.
@MainActor
final class LibrarySearchPreparationTests: XCTestCase {

    /// A coordinator of `preparer` reading `power`, hearing the power state
    /// on `center`.
    private func makeCoordinator(
        _ preparer: LibrarySearchPreparer,
        power: PowerSwitch = PowerSwitch(),
        center: NotificationCenter = NotificationCenter(),
        isEnabled: Bool = true
    ) -> LibrarySearchPreparation {
        LibrarySearchPreparation(
            preparer: preparer, isEnabled: isEnabled, isLowPowerMode: { power.lowPowerMode }, notificationCenter: center
        )
    }

    /// No pass starts before the library is ready, not even for the window
    /// opening; the first starts as it becomes ready, and only the first
    /// readiness counts.
    func testAPassStartsOnceTheLibraryIsReady() throws {
        let library = try makePreparerLibrary(4)
        let reports = PassReports()
        let preparer = makePreparer(library, reports: reports)
        let coordinator = makeCoordinator(preparer)

        coordinator.searchWindowOpened()
        XCTAssertFalse(preparer.isRunning, "a pass started before the library was ready")
        XCTAssertEqual(preparer.progress.booksGiven, 0)

        coordinator.libraryIsReady(books: { library.books }, moves: Empty().eraseToAnyPublisher())
        XCTAssertTrue(reports.wait(for: 1), "the pass never ended")
        XCTAssertEqual(reports.all.first?.progress.booksPrepared, 4)
        XCTAssertEqual(preparer.priority, .raised, "the window opened before the library was ready still raises the pass")

        coordinator.libraryIsReady(books: { [] }, moves: Empty().eraseToAnyPublisher())
        XCTAssertEqual(preparer.progress.booksGiven, 4, "a second readiness replaced the library's books")
    }

    /// A coordinator that is not enabled, as the app's is in a process
    /// hosting tests and on the iPhone, prepares nothing; the app's says so
    /// for this process.
    func testADisabledCoordinatorPreparesNothing() throws {
        let library = try makePreparerLibrary(2)
        let preparer = makePreparer(library, reports: PassReports())
        let coordinator = makeCoordinator(preparer, isEnabled: false)

        coordinator.libraryIsReady(books: { library.books }, moves: Empty().eraseToAnyPublisher())
        coordinator.searchWindowOpened()

        XCTAssertFalse(preparer.isRunning, "a disabled coordinator started a pass")
        XCTAssertFalse(library.books.contains(where: library.isKept), "a disabled coordinator prepared a book")
        XCTAssertFalse(LibrarySearchPreparation.preparesInThisProcess, "a process hosting tests prepares the user's books")
    }

    /// Opening the window raises the priority, and a pass starts when none
    /// is under way, preparing what changed since the last; closing it puts
    /// the priority back.
    func testTheWindowRaisesThePriorityAndStartsAPassWhenNoneIsUnderWay() throws {
        let library = try makePreparerLibrary(3)
        let reports = PassReports()
        let preparer = makePreparer(library, reports: reports)
        let coordinator = makeCoordinator(preparer)
        coordinator.libraryIsReady(books: { library.books }, moves: Empty().eraseToAnyPublisher())
        XCTAssertTrue(reports.wait(for: 1), "the first pass never ended")
        XCTAssertEqual(preparer.priority, .background)

        coordinator.searchWindowOpened()

        XCTAssertEqual(preparer.priority, .raised)
        XCTAssertTrue(reports.wait(for: 2), "opening the window started no pass")
        XCTAssertEqual(reports.all.last?.progress.booksAlreadyPrepared, 3, "\(String(describing: reports.all.last))")
        coordinator.searchWindowClosed()
        XCTAssertEqual(preparer.priority, .background)
    }

    /// A data-directory move stops the pass under way, no pass starts while
    /// it lasts, and a pass starts afresh once it is over. A search holds the
    /// preparer paused throughout, so each pass stays under way to be seen.
    func testAMoveStopsThePassAndOneStartsAfresh() throws {
        let library = try makePreparerLibrary(3)
        let preparer = makePreparer(library, reports: PassReports())
        let coordinator = makeCoordinator(preparer)
        let moves = PassthroughSubject<Bool, Never>()
        preparer.pause()
        // Nothing more is begun once the test ends.
        defer { preparer.stop() }
        coordinator.libraryIsReady(books: { library.books }, moves: moves.eraseToAnyPublisher())
        XCTAssertTrue(preparer.isRunning, "no pass began once the library was ready")

        moves.send(true)
        XCTAssertFalse(preparer.isRunning, "the move left the pass under way")
        XCTAssertTrue(coordinator.isLibraryMoving)
        coordinator.searchWindowOpened()
        XCTAssertFalse(preparer.isRunning, "a pass started while the library moved")

        moves.send(false)
        XCTAssertFalse(coordinator.isLibraryMoving)
        XCTAssertTrue(preparer.isRunning, "no pass started once the move was over")
    }

    /// Once its startup maintenance has ended, the library hands the
    /// preparation its searchable books, those with a package, as they are
    /// at each pass, and its data directory's moves
    /// (`LibraryViewModel.startupMaintenanceDidEnd(preparation:)`, which the
    /// app's startup calls after its last pass): a move stops the pass and
    /// its end starts one afresh. The preparer is held paused, so the books,
    /// made up, are never read.
    func testTheLibraryHandsItsBooksAndItsMovesToThePreparation() throws {
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [
            Book(title: "Kept Apart", author: "A", format: .txt, filePath: "a.txt", md5Hash: "hash-a", tmbDirectoryName: "a.tmb"),
            Book(title: "Bare Bones", author: "B", format: .txt, filePath: "b.txt", md5Hash: "hash-b", tmbDirectoryName: ""),
            Book(title: "Another", author: "C", format: .txt, filePath: "c.txt", md5Hash: "hash-c", tmbDirectoryName: "c.tmb"),
        ])
        let store = LibrarySearchTextStore(folder: try makeSandboxDirectory("LibrarySearchPreparationHook"))
        let preparer = LibrarySearchPreparer(store: store, isLowPowerMode: { false }, onPassEnded: { _ in })
        let coordinator = makeCoordinator(preparer)
        preparer.pause()
        // Nothing more is begun once the test ends.
        defer { preparer.stop() }

        library.startupMaintenanceDidEnd(preparation: coordinator)

        XCTAssertTrue(preparer.isRunning, "no pass began once the library's maintenance ended")
        XCTAssertEqual(preparer.progress.booksGiven, 2, "the books of the library that have a package")
        XCTAssertFalse(coordinator.isLibraryMoving, "the library's publisher's first value started a move")

        library.dataDirectoryMove = DataDirectoryMoveProgress(destination: try makeSandboxDirectory("LibrarySearchPreparationMove"))
        XCTAssertTrue(coordinator.isLibraryMoving, "the library's move did not reach the preparation")
        XCTAssertFalse(preparer.isRunning, "the move left the pass under way")

        library.dataDirectoryMove = nil
        XCTAssertFalse(coordinator.isLibraryMoving)
        XCTAssertTrue(preparer.isRunning, "no pass started once the move was over")
    }

    /// Low Power Mode coming on stops the pass under way, and going off
    /// starts one afresh, as the system's power-state notification says.
    func testLowPowerModeStopsThePassAndItsEndStartsOne() throws {
        let library = try makePreparerLibrary(3)
        let power = PowerSwitch()
        let center = NotificationCenter()
        let preparer = makePreparer(library, power: power, reports: PassReports())
        let coordinator = makeCoordinator(preparer, power: power, center: center)
        preparer.pause()
        // Nothing more is begun once the test ends.
        defer { preparer.stop() }
        coordinator.libraryIsReady(books: { library.books }, moves: Empty().eraseToAnyPublisher())
        XCTAssertTrue(preparer.isRunning, "no pass began once the library was ready")

        power.lowPowerMode = true
        center.post(name: ProcessInfo.powerStateDidChangeNotification, object: nil)
        XCTAssertTrue(waitUntil(timeout: 5) { !preparer.isRunning }, "Low Power Mode left the pass under way")

        power.lowPowerMode = false
        center.post(name: ProcessInfo.powerStateDidChangeNotification, object: nil)
        XCTAssertTrue(waitUntil(timeout: 5) { preparer.isRunning }, "no pass started once Low Power Mode was off")
    }
}
