import Combine
import XCTest
@testable import TextMouth

/// B22: a reader is built inside SwiftUI's update, where changing another
/// object's `@Published` state starts a transaction and aborts the app. The
/// library's open-book registry therefore keeps its truth at once (the
/// counts, the audio activity, `isBookOpenNow`) and publishes `openBookIDs`
/// on the main queue's next turn. These tests check the mechanism; none
/// reproduces the abort, which must never run on this Mac.
@MainActor
final class OpenBookRegistryTests: XCTestCase {
    /// A library with one text book, whose file is in a folder of the test's own.
    private func makeLibrary() throws -> (library: LibraryViewModel, book: Book) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("First chapter\nSecond chapter".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let book = Book(title: "Registry", format: .txt, filePath: file.path, md5Hash: UUID().uuidString)
        let library = LibraryViewModel()
        library.library = Library(books: [book])
        return (library, book)
    }

    /// A reader of `book`, built as the reader window builds it.
    private func makeReader(_ book: Book, in library: LibraryViewModel) -> ReaderViewModel {
        ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: SettingsViewModel(initializeServices: false)
        )
    }

    /// Building a reader publishes nothing on its library during `init`: the
    /// state a view update must not change.
    func testBuildingAReaderPublishesNothingOnTheLibraryDuringInit() throws {
        let (library, book) = try makeLibrary()
        var willChange = 0
        let watcher = library.objectWillChange.sink { willChange += 1 }
        defer { watcher.cancel() }

        let reader = makeReader(book, in: library)
        defer { reader.close() }

        XCTAssertEqual(willChange, 0, "the library published while a reader was built")
        XCTAssertTrue(library.openBookIDs.isEmpty, "the set changed during init")
    }

    /// One turn later the set holds the book.
    func testTheSetHoldsTheBookAfterOneTurn() throws {
        let (library, book) = try makeLibrary()
        let reader = makeReader(book, in: library)
        defer { reader.close() }

        waitForMainQueueTurn()

        XCTAssertEqual(library.openBookIDs, [book.id])
    }

    /// A register then an unregister within one turn leaves no book behind.
    func testARegisterThenAnUnregisterInOneTurnLeavesNoBook() throws {
        let (library, book) = try makeLibrary()

        library.registerOpenBook(book.id)
        library.unregisterOpenBook(book.id)
        waitForMainQueueTurn()

        XCTAssertTrue(library.openBookIDs.isEmpty)
        XCTAssertFalse(library.isBookOpenNow(book.id))
        XCTAssertTrue(library.openReaderCounts.isEmpty)
    }

    /// An unregister then a register in one turn leaves the book there.
    func testAnUnregisterThenARegisterInOneTurnKeepsTheBook() throws {
        let (library, book) = try makeLibrary()
        library.registerOpenBook(book.id)
        library.registerOpenBook(book.id)
        waitForMainQueueTurn()

        library.unregisterOpenBook(book.id)
        library.unregisterOpenBook(book.id)
        library.registerOpenBook(book.id)
        waitForMainQueueTurn()

        XCTAssertEqual(library.openBookIDs, [book.id])
        XCTAssertTrue(library.isBookOpenNow(book.id))
    }

    /// Two readers of one book, then one closing, keep it in the set.
    func testTwoReadersOfOneBookThenOneClosingKeepTheBook() throws {
        let (library, book) = try makeLibrary()
        let first = makeReader(book, in: library)
        let second = makeReader(book, in: library)
        defer { second.close() }
        waitForMainQueueTurn()
        XCTAssertEqual(library.openBookIDs, [book.id])

        first.close()
        waitForMainQueueTurn()

        XCTAssertEqual(library.openBookIDs, [book.id], "one window's close took the book from the set")
        XCTAssertTrue(library.isBookOpenNow(book.id))
    }

    /// The checks that decide something see the book at once, before the
    /// turn: the open-book check the sleep timer asks, the audio activity
    /// FR04's original policy reads, and the library's own query.
    func testTheChecksSeeTheBookAtOnceBeforeTheTurn() throws {
        let (library, book) = try makeLibrary()
        let reader = makeReader(book, in: library)

        XCTAssertTrue(reader.bookIsOpenCheck(book.id), "the open-book check missed it")
        XCTAssertTrue(library.audioEditActivity.isOpenInReader(book.id), "the audio activity missed it")
        XCTAssertTrue(library.isBookOpenNow(book.id))
        XCTAssertEqual(library.openBookIDsNow, [book.id])
        XCTAssertTrue(library.openBookIDs.isEmpty, "the published set was early")

        // And it leaves them at once too, the published set a turn later.
        reader.close()
        XCTAssertFalse(reader.bookIsOpenCheck(book.id), "the open-book check kept a closed book")
        XCTAssertFalse(library.audioEditActivity.isOpenInReader(book.id))
        waitForMainQueueTurn()
        XCTAssertTrue(library.openBookIDs.isEmpty)
    }

    /// Several changes in one turn publish the set once.
    func testChangesInOneTurnPublishOnce() throws {
        let (library, _) = try makeLibrary()
        var published = 0
        let watcher = library.$openBookIDs.dropFirst().sink { _ in published += 1 }
        defer { watcher.cancel() }

        for _ in 0..<3 { library.registerOpenBook(UUID()) }
        XCTAssertEqual(published, 0, "the set published before the turn")
        waitForMainQueueTurn()

        XCTAssertEqual(published, 1)
        XCTAssertEqual(library.openBookIDs.count, 3)
    }
}
