import XCTest
@testable import TextMouth

/// Rearranging a folder's manual order (TODO A06): dragging and Move Book
/// Up or Down save the new order at once, in the library index and in the
/// record of every book that moved, and leave the folder in manual order.
///
/// The tests make real packages in the test root's library, so each book's
/// own record can be read back, and put the library index back afterwards.
final class ManualOrderRearrangingTests: XCTestCase {
    private var sandbox: LibraryIndexSandbox!
    /// Folder directories created in the test root, removed with their packages.
    private var createdFolders: [URL] = []

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
        createdFolders = []
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when capturing failed in set-up.
        sandbox?.restore()
        for folder in createdFolders {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - Saving

    /// A drag saves the order at once: each moved book's record holds its new
    /// position, and the folder is still in manual order.
    @MainActor
    func testDraggingSavesEveryMovedBooksRecordAndKeepsManualOrder() throws {
        let shelf = try makeShelf(titles: ["Almanac", "Bestiary", "Chronicle"])

        shelf.model.reorderBooksInFolder(folderPath: shelf.folder, from: IndexSet(integer: 2), to: 0)

        XCTAssertEqual(shelf.orderedTitles(), ["Chronicle", "Almanac", "Bestiary"])
        try assertRecordsHoldTheOrderShown(shelf)
        XCTAssertEqual(shelf.model.library.folderSortSettings, [shelf.folder: Self.manual])
        XCTAssertEqual(shelf.model.sortState(at: shelf.location).titleFragment, "Manual Order")
    }

    /// Move Book Up saves the same way. It used to save only the library
    /// index, so an index rebuilt from the books lost a keyboard
    /// rearrangement that a drag would have kept.
    @MainActor
    func testMoveBookUpSavesEveryMovedBooksRecordAndKeepsManualOrder() throws {
        let shelf = try makeShelf(titles: ["Almanac", "Bestiary", "Chronicle"])
        let chronicle = try XCTUnwrap(shelf.model.library.books.first { $0.title == "Chronicle" })

        let moved = shelf.model.moveBookInManualOrder(bookID: chronicle.id, direction: -1, folderPath: shelf.folder)

        XCTAssertEqual(moved?.adjacentTitle, "Bestiary")
        XCTAssertEqual(shelf.orderedTitles(), ["Almanac", "Chronicle", "Bestiary"])
        try assertRecordsHoldTheOrderShown(shelf)
        XCTAssertEqual(shelf.model.library.folderSortSettings, [shelf.folder: Self.manual])
    }

    /// Offsets outside the folder, as a list showing something else could
    /// send, change nothing.
    func testDragOffsetsOutsideTheFolderChangeNothing() {
        var library = Library(books: [
            LibrarySortStateTests.shelvedBook("Almanac", in: "Shelf", manualOrder: 0),
            LibrarySortStateTests.shelvedBook("Bestiary", in: "Shelf", manualOrder: 1)
        ])
        let before = library.books

        XCTAssertFalse(ManualBookOrder.reorder(library: &library, folderPath: "Shelf", from: IndexSet(integer: 5), to: 0))
        XCTAssertFalse(ManualBookOrder.reorder(library: &library, folderPath: "Shelf", from: IndexSet(integer: 0), to: 7))
        XCTAssertFalse(ManualBookOrder.reorder(library: &library, folderPath: "Shelf", from: IndexSet(), to: 0))

        XCTAssertEqual(library.books.map(\.manualSortOrder), before.map(\.manualSortOrder))
    }

    // MARK: - The Next Book

    /// Continue to Next Book follows the folder's manual order: books with a
    /// manual position first, in that order, then the rest by title. Books
    /// in other folders never come next.
    @MainActor
    func testNextBookFollowsTheFoldersManualOrder() {
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [
            LibrarySortStateTests.shelvedBook("Chronicle", in: "Shelf", manualOrder: 1),
            Self.unplacedBook("Bestiary", in: "Shelf"),
            LibrarySortStateTests.shelvedBook("Ledger", in: "Shelf", manualOrder: 0),
            Self.unplacedBook("Almanac", in: "Shelf"),
            LibrarySortStateTests.shelvedBook("Elsewhere", in: "Other Shelf", manualOrder: 2)
        ])

        XCTAssertEqual(
            Self.titlesInContinuingOrder(from: "Ledger", in: model),
            ["Ledger", "Chronicle", "Almanac", "Bestiary"]
        )
    }

    /// Books the manual order cannot tell apart, such as two same-titled
    /// copies kept with Keep Both, follow one another in the order the list
    /// shows them, so continuing never skips or repeats one. The next book
    /// used to break such ties by the library's own order, while the list,
    /// Move Book Up and Down, and dragging break them by book ID.
    @MainActor
    func testNextBookBreaksTiesAsTheListDoes() throws {
        // Added in the reverse of the order their IDs give them.
        let laterID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000000B"))
        let earlierID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000000A"))
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [
            Self.unplacedBook("Atlas", in: "Shelf", id: laterID),
            Self.unplacedBook("Atlas", in: "Shelf", id: earlierID),
            Self.unplacedBook("Bestiary", in: "Shelf")
        ])
        let shown = ManualBookOrder.orderedBooks(in: model.library, folderPath: "Shelf")
        XCTAssertEqual(Array(shown.map(\.id).prefix(2)), [earlierID, laterID], "The list shows the copies by ID")

        for (position, book) in shown.enumerated() {
            let following = shown.indices.contains(position + 1) ? shown[position + 1].id : nil
            XCTAssertEqual(
                model.nextBookInFolder(after: book)?.id,
                following,
                "The book after \(book.title) (\(book.id)) should be the next one the list shows"
            )
        }
    }

    /// Continue to Next Book passes over books resting at their ends,
    /// finished (REV14): after Almanac comes Ledger, past two finished
    /// books, and a finished book goes on to the first unfinished one after
    /// it. Before only finished books nothing comes next, though books
    /// follow, which tells the reader to say "Every book after it in the
    /// folder is finished" rather than "No more books in folder". A book
    /// whose place is unknown to be its end, its length not yet measured,
    /// comes next as any unfinished book does.
    @MainActor
    func testNextBookPassesOverFinishedBooks() {
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [
            LibrarySortStateTests.shelvedBook("Almanac", in: "Shelf", manualOrder: 0),
            Self.finished(LibrarySortStateTests.shelvedBook("Bestiary", in: "Shelf", manualOrder: 1)),
            Self.finished(LibrarySortStateTests.shelvedBook("Chronicle", in: "Shelf", manualOrder: 2)),
            LibrarySortStateTests.shelvedBook("Ledger", in: "Shelf", manualOrder: 3),
            Self.finished(LibrarySortStateTests.shelvedBook("Margins", in: "Shelf", manualOrder: 4)),
            Self.finished(LibrarySortStateTests.shelvedBook("Notebook", in: "Shelf", manualOrder: 5)),
        ])
        /// The book titled `title` in the model's library.
        func book(_ title: String) -> Book? {
            model.library.books.first { $0.title == title }
        }
        /// The title of the book Continue to Next Book plays after `title`.
        func next(after title: String) -> String? {
            book(title).flatMap { model.nextBookInFolder(after: $0)?.title }
        }
        /// The titles of every book after `title`, finished or not.
        func later(than title: String) -> [String] {
            book(title).map { model.laterBooksInFolder(after: $0).map(\.title) } ?? []
        }

        XCTAssertEqual(Self.titlesInContinuingOrder(from: "Almanac", in: model), ["Almanac", "Ledger"])
        XCTAssertEqual(next(after: "Bestiary"), "Ledger")
        XCTAssertNil(next(after: "Ledger"), "Only finished books follow Ledger")
        XCTAssertEqual(later(than: "Ledger"), ["Margins", "Notebook"])
        XCTAssertNil(next(after: "Notebook"))
        XCTAssertEqual(later(than: "Notebook"), [])

        // Not measured, its place cannot be known to be its end.
        if let index = model.library.books.firstIndex(where: { $0.title == "Margins" }) {
            model.library.books[index].totalCharacterCount = nil
        }
        XCTAssertEqual(next(after: "Ledger"), "Margins")
    }

    // MARK: - Fixtures

    /// The setting of a folder in manual order.
    private static let manual = FolderSortSetting(sortField: .manual, sortAscending: true)

    /// `book`, measured at 1,000 units and resting at its end, finished
    /// (`Book.restsAtEnd`), as a book that played to its end rests.
    private static func finished(_ book: Book) -> Book {
        var finished = book
        finished.totalCharacterCount = 1_000
        finished.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: 1_000, globalCharacterOffset: 1_000)
        XCTAssertTrue(finished.restsAtEnd, "\(book.title) does not rest at its end")
        return finished
    }

    /// A book in `folder` with no manual position, as every book has until
    /// its folder is first rearranged. Nothing is written for it.
    private static func unplacedBook(_ title: String, in folder: String, id: UUID = UUID()) -> Book {
        Book(
            id: id,
            title: title,
            format: .txt,
            filePath: "/nonexistent/next-book/\(id.uuidString).txt",
            md5Hash: "next-book-\(id.uuidString)",
            folderPath: folder
        )
    }

    /// The titles Continue to Next Book plays in `model`'s library, starting
    /// with the book titled `first` and following `nextBookInFolder(after:)`
    /// until it finds no next book (or, should it ever loop, once every
    /// book has had a turn).
    @MainActor
    private static func titlesInContinuingOrder(from first: String, in model: LibraryViewModel) -> [String] {
        var book = model.library.books.first { $0.title == first }
        var titles: [String] = []
        while let current = book, titles.count <= model.library.books.count {
            titles.append(current.title)
            book = model.nextBookInFolder(after: current)
        }
        return titles
    }

    /// A folder of real packages in manual order, in an inert library model.
    private struct Shelf {
        let model: LibraryViewModel
        let folder: String

        /// The shelf's place in the library.
        var location: LibraryLocation {
            LibraryLocation(category: .folders, folderPath: folder)
        }

        /// The shelf's titles in its manual order, as the list shows them.
        @MainActor
        func orderedTitles() -> [String] {
            ManualBookOrder.orderedBooks(in: model.library, folderPath: folder).map(\.title)
        }
    }

    /// Makes a folder holding a real package for each title, in that manual
    /// order, and a model whose library holds them with the folder in manual
    /// order.
    @MainActor
    private func makeShelf(titles: [String]) throws -> Shelf {
        let folder = "Rearranging Shelf \(UUID().uuidString.prefix(8))"
        let directory = TextMouthPaths.libraryDir.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        createdFolders.append(directory)

        var books: [Book] = []
        for (position, title) in titles.enumerated() {
            let packageName = "ManualOrder-\(UUID().uuidString).tmb"
            let package = TextMouthPaths.tmbPath(folderPath: folder, tmbName: packageName)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let content = package.appendingPathComponent("book.txt")
            try Data("Pages of \(title), kept in the order chosen for them.".utf8).write(to: content)
            let book = Book(
                title: title,
                author: "Test Fixture",
                format: .txt,
                filePath: content.path,
                md5Hash: "manual-order-\(UUID().uuidString)",
                folderPath: folder,
                tmbDirectoryName: packageName,
                manualSortOrder: position
            )
            try book.saveBookInfoThrowing()
            books.append(book)
        }

        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(
            books: books,
            folders: [BookFolder(name: folder)],
            folderSortSettings: [folder: Self.manual]
        )
        return Shelf(model: model, folder: folder)
    }

    /// Asserts that every book's own record holds the position the shelf's
    /// manual order gives it, once pending writes are flushed.
    @MainActor
    private func assertRecordsHoldTheOrderShown(
        _ shelf: Shelf,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        LibraryPersistenceService.flushPendingSave()
        let ordered = ManualBookOrder.orderedBooks(in: shelf.model.library, folderPath: shelf.folder)
        for (position, book) in ordered.enumerated() {
            let record = try BookInfo.load(from: book.tmbDirectory)
            XCTAssertEqual(record.state.manualSortOrder, position, book.title, file: file, line: line)
        }
    }
}
