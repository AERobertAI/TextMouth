import XCTest
@testable import TextMouth

/// The reading list's model (FR09): books from anywhere in the library, in
/// the order the user arranges, each at most once, with what a book opened
/// from the list does when it ends and whether finished books are passed
/// over. These tests pin its defaults and its option names, how it is saved
/// in library.json and read back (an older index has none, and a damaged
/// one never makes the index unreadable), and that a book removed from the
/// library leaves the list.
@MainActor
final class ReadingListTests: XCTestCase {
    /// The isolated data root's index, put back after a test that saves.
    private var sandbox: LibraryIndexSandbox!

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // Tear-down also runs when capturing failed in set-up.
        sandbox?.restore()
    }

    // MARK: - Defaults and Names

    /// A new list, and the list of a new library, is empty, plays the book
    /// below when a book ends, and passes over finished books.
    func testANewListIsEmptyPlaysTheBookBelowAndSkipsFinishedBooks() {
        for list in [ReadingList(), Library().readingList] {
            XCTAssertEqual(list.bookIDs, [])
            XCTAssertEqual(list.continuation, .playBookBelow)
            XCTAssertTrue(list.skipsFinished)
        }
    }

    /// The options are named as the options bar shows and speaks them, in
    /// that order; each is saved under a name of its own that the words can
    /// change without, and each continues down, up, or not at all.
    func testTheContinuationsAreNamedInTheOptionsOrder() {
        XCTAssertEqual(ReadingList.Continuation.allCases.map(\.title), ["Play the book below", "Play the book above", "Stop"])
        XCTAssertEqual(ReadingList.Continuation.allCases.map(\.rawValue), ["playBookBelow", "playBookAbove", "stop"])
        XCTAssertEqual(ReadingList.Continuation.allCases.map(\.direction), [.down, .up, nil])
    }

    /// Move Book Up and Move Book Down give their direction as a step of -1
    /// or +1; a step of nothing is no direction.
    func testADirectionIsTheSignOfAStep() {
        XCTAssertEqual(ReadingList.Direction(step: -1), .up)
        XCTAssertEqual(ReadingList.Direction(step: 1), .down)
        XCTAssertEqual(ReadingList.Direction(step: -3), .up)
        XCTAssertNil(ReadingList.Direction(step: 0))
        XCTAssertEqual(ReadingList.Direction.up.step, -1)
        XCTAssertEqual(ReadingList.Direction.down.step, 1)
    }

    /// A list made with a book listed twice holds it once, where it first
    /// appears.
    func testAListMadeWithRepeatsHoldsEachBookOnce() {
        let (first, second) = (UUID(), UUID())
        XCTAssertEqual(ReadingList(bookIDs: [first, second, first, second, first]).bookIDs, [first, second])
    }

    // MARK: - Saved with the Index

    /// The list is saved in library.json with the rest of the index, under
    /// its own key, its options by their saved names, and read back as it
    /// was.
    func testTheListIsSavedWithTheIndexAndReadBack() throws {
        let shelf = Self.shelf(["Almanac", "Bestiary", "Chronicle"])
        let list = ReadingList(bookIDs: shelf.ids("Chronicle", "Almanac"), continuation: .playBookAbove, skipsFinished: false)
        let library = Library(books: shelf.books, readingList: list)

        let saved = try XCTUnwrap(try JSONSerialization.jsonObject(with: LibraryIndexSandbox.encoded(library)) as? [String: Any])
        let savedList = try XCTUnwrap(saved["readingList"] as? [String: Any])
        XCTAssertEqual(savedList["bookIDs"] as? [String], shelf.ids("Chronicle", "Almanac").map(\.uuidString))
        XCTAssertEqual(savedList["continuation"] as? String, "playBookAbove")
        XCTAssertEqual(savedList["skipsFinished"] as? Bool, false)

        let reread = try LibrarySortStateTests.reread(library)
        XCTAssertEqual(reread.readingList, list)
        XCTAssertEqual(reread.books.map(\.id), shelf.books.map(\.id))
    }

    /// An index written before the reading list existed has none: it reads
    /// with an empty list, and everything else in it as before.
    func testAnIndexWrittenBeforeTheListReadsWithAnEmptyOne() throws {
        let books = [Self.book("Almanac", in: "Essays")]
        let library = Library(
            books: books,
            folders: [BookFolder(name: "Essays")],
            folderSortSettings: ["Essays": FolderSortSetting(sortField: .author, sortAscending: false)]
        )
        let older = try Self.index(of: library) { $0.removeValue(forKey: "readingList") }

        let read = try Self.decode(older)

        XCTAssertEqual(read.readingList, ReadingList())
        XCTAssertEqual(read.books.map(\.id), books.map(\.id))
        XCTAssertEqual(read.folders.map(\.fullPath), ["Essays"])
        XCTAssertEqual(read.folderSortSettings["Essays"], FolderSortSetting(sortField: .author, sortAscending: false))
    }

    /// A list that cannot be read never makes the index unreadable: an entry
    /// that is not an ID is skipped and the rest kept in order, an ID listed
    /// twice is kept once, and an option that is unknown, as a later version
    /// might write, or of the wrong kind reads as its default. A list that is
    /// not a list at all reads as an empty one, and the books are all there.
    func testAListThatCannotBeReadNeverMakesTheIndexUnreadable() throws {
        let shelf = Self.shelf(["Almanac", "Bestiary", "Chronicle"])
        let almanac = shelf.id("Almanac").uuidString
        let bestiary = shelf.id("Bestiary").uuidString
        let library = Library(books: shelf.books)

        let damaged = try Self.index(of: library) {
            $0["readingList"] = [
                "bookIDs": [bestiary, "not an ID", 42, bestiary, NSNull(), almanac],
                "continuation": "playBookSideways",
                "skipsFinished": "yes",
            ]
        }
        let read = try Self.decode(damaged)
        XCTAssertEqual(read.readingList.bookIDs, shelf.ids("Bestiary", "Almanac"))
        XCTAssertEqual(read.readingList.continuation, .playBookBelow)
        XCTAssertTrue(read.readingList.skipsFinished)
        XCTAssertEqual(read.books.count, 3)

        for nonsense: Any in ["a list", 7, [almanac], NSNull()] {
            let unreadable = try Self.index(of: library) { $0["readingList"] = nonsense }
            let read = try Self.decode(unreadable)
            XCTAssertEqual(read.readingList, ReadingList(), "\(nonsense)")
            XCTAssertEqual(read.books.map(\.id), shelf.books.map(\.id), "\(nonsense)")
        }
    }

    // MARK: - A Book Removed from the Library Leaves the List

    /// Removing a book from the library takes it off the list; the others
    /// keep their order, and the options stay as they were.
    func testRemovingABookFromTheLibraryTakesItOffTheList() {
        let shelf = Self.shelf(["Almanac", "Bestiary", "Chronicle"])
        var library = Library(
            books: shelf.books,
            readingList: ReadingList(bookIDs: shelf.ids("Chronicle", "Bestiary", "Almanac"), continuation: .stop, skipsFinished: false)
        )

        library.removeBook(id: shelf.id("Bestiary"))

        XCTAssertEqual(
            library.readingList,
            ReadingList(bookIDs: shelf.ids("Chronicle", "Almanac"), continuation: .stop, skipsFinished: false)
        )
        // Removing a book that is not in the list changes nothing more.
        library.removeBook(id: UUID())
        XCTAssertEqual(library.readingList.bookIDs, shelf.ids("Chronicle", "Almanac"))
    }

    /// Deleting a folder with everything in it takes every book inside it,
    /// in its subfolders too, off the list, and leaves the books elsewhere.
    func testDeletingAFolderWithItsContentsTakesItsBooksOffTheList() throws {
        let essays = BookFolder(name: "Essays")
        let travel = BookFolder(name: "Travel", parentPath: "Essays")
        let inEssays = Self.book("Field Notes", in: "Essays")
        let inTravel = Self.book("Harbour Days", in: "Essays/Travel")
        let atTheRoot = Self.book("Loose Pages", in: "")
        var library = Library(
            books: [inEssays, inTravel, atTheRoot],
            folders: [essays, travel],
            readingList: ReadingList(bookIDs: [inTravel.id, atTheRoot.id, inEssays.id])
        )

        let removed = library.removeFolderAndContents(id: essays.id)

        XCTAssertEqual(Set(removed.map(\.id)), [inEssays.id, inTravel.id])
        XCTAssertEqual(library.readingList.bookIDs, [atTheRoot.id])
    }

    /// A book removed with Remove and Delete, as the Library window and the
    /// Duplicate Finder remove one, leaves the list, and the list saved in
    /// the index no longer names it.
    func testABookRemovedFromTheLibraryModelLeavesTheSavedList() throws {
        let titles = ["Almanac", "Bestiary"]
        let shelf = Self.shelf(titles, listed: titles)

        let outcome = shelf.model.removeBooksAndDeleteReturningOutcome(shelf.books(titled: "Almanac"), deletePackage: { _ in })
        XCTAssertTrue(outcome.succeeded)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(shelf.model.library.readingList.bookIDs, shelf.ids("Bestiary"))
        let saved = try Self.decode(Data(contentsOf: sandbox.indexURL))
        XCTAssertEqual(saved.readingList.bookIDs, shelf.ids("Bestiary"))
    }

    // MARK: - Fixtures

    /// A library model of a book titled each of `titles`, at the root, whose
    /// reading list holds the books titled `listed`, in that order; with
    /// the books, found by title.
    static func shelf(_ titles: [String], listed: [String] = []) -> ReadingListShelf {
        let books = titles.map { book($0) }
        let model = LibraryViewModel(initializeServices: false)
        let shelf = ReadingListShelf(model: model, books: books)
        model.library = Library(books: books, readingList: ReadingList(bookIDs: listed.map(shelf.id)))
        return shelf
    }

    /// A text book titled `title` in the folder `folder`, which no file
    /// backs.
    static func book(_ title: String, in folder: String = "", id: UUID = UUID()) -> Book {
        Book(
            id: id,
            title: title,
            author: "Ines Okonkwo-Varga",
            format: .txt,
            filePath: "/nonexistent/reading-list/\(id.uuidString).txt",
            md5Hash: "reading-list-\(id.uuidString)",
            folderPath: folder
        )
    }

    /// `library`'s index as library.json holds it, changed by `edit` as a
    /// JSON object.
    private static func index(of library: Library, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: LibraryIndexSandbox.encoded(library)) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// An index read the way every index read reads it.
    private static func decode(_ data: Data) throws -> Library {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Library.self, from: data)
    }
}

// MARK: - Books Found by Title

/// A library model and its books, each found by its title, so a test names
/// the books it means rather than counting positions in an array.
struct ReadingListShelf {
    /// The library model holding the books.
    let model: LibraryViewModel
    /// The books, in the library's order.
    let books: [Book]

    /// The ID of the book titled `title`, or a new ID that no book has when
    /// none is, so a mistyped title fails its test rather than stopping the
    /// test host.
    func id(_ title: String) -> UUID {
        books.first { $0.title == title }?.id ?? UUID()
    }

    /// The IDs of the books titled `titles`, in that order.
    func ids(_ titles: String...) -> [UUID] {
        titles.map(id)
    }

    /// The books titled `titles`, in that order; a title no book has is
    /// left out.
    func books(titled titles: String...) -> [Book] {
        titles.compactMap { title in books.first { $0.title == title } }
    }
}
