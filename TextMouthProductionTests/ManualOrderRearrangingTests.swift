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

    // MARK: - Fixtures

    /// The setting of a folder in manual order.
    private static let manual = FolderSortSetting(sortField: .manual, sortAscending: true)

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
