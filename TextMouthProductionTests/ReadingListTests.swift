import Combine
import SwiftUI
import XCTest
@testable import TextMouth

/// The reading list's model (FR09): books from anywhere in the library, in
/// the order the user arranges, each at most once, with what a book opened
/// from the list does when it ends and whether finished books are passed
/// over. These tests pin its defaults and its option names, how it is saved
/// in library.json and read back (an older index has none, and a damaged
/// one never makes the index unreadable), and that a book removed from the
/// library leaves the list.
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
    @MainActor
    func testANewListIsEmptyPlaysTheBookBelowAndSkipsFinishedBooks() {
        for list in [ReadingList(), Library().readingList] {
            XCTAssertEqual(list.bookIDs, [])
            XCTAssertEqual(list.continuation, .playBookBelow)
            XCTAssertTrue(list.skipsFinished)
            XCTAssertFalse(list.removesFinished, "a finished book leaves the list only when asked")
        }
    }

    /// The options are named as the options bar shows and speaks them, in
    /// that order; each is saved under a name of its own that the words can
    /// change without, and each continues down, up, or not at all.
    @MainActor
    func testTheContinuationsAreNamedInTheOptionsOrder() {
        XCTAssertEqual(ReadingList.Continuation.allCases.map(\.title), ["Play the book below", "Play the book above", "Stop"])
        XCTAssertEqual(ReadingList.Continuation.allCases.map(\.rawValue), ["playBookBelow", "playBookAbove", "stop"])
        XCTAssertEqual(ReadingList.Continuation.allCases.map(\.direction), [.down, .up, nil])
    }

    /// Move Book Up and Move Book Down give their direction as a step of -1
    /// or +1; a step of nothing is no direction.
    @MainActor
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
    @MainActor
    func testAListMadeWithRepeatsHoldsEachBookOnce() {
        let (first, second) = (UUID(), UUID())
        XCTAssertEqual(ReadingList(bookIDs: [first, second, first, second, first]).bookIDs, [first, second])
    }

    // MARK: - Saved with the Index

    /// The list is saved in library.json with the rest of the index, under
    /// its own key, its options by their saved names, and read back as it
    /// was.
    @MainActor
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
    @MainActor
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
    @MainActor
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
    @MainActor
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
    @MainActor
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
    @MainActor
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

    // MARK: - Membership

    /// Adding appends the books to the end of the list in the order given,
    /// which is the order the list showing them shows them, each once,
    /// leaving out books already there and any not in the library; it
    /// returns the books added, is one change of the library, and saves the
    /// list in the index.
    @MainActor
    func testAddingAppendsInTheOrderGivenAndLeavesOutBooksAlreadyThere() throws {
        let shelf = Self.shelf(["Almanac", "Bestiary", "Chronicle", "Dockside Ledger"])
        let changes = LibraryChangeCounter(shelf.model)

        XCTAssertEqual(shelf.model.addToReadingList(shelf.ids("Chronicle", "Almanac")).map(\.title), ["Chronicle", "Almanac"])
        let again = shelf.ids("Almanac", "Bestiary", "Bestiary") + [UUID()] + shelf.ids("Chronicle")
        XCTAssertEqual(shelf.model.addToReadingList(again).map(\.title), ["Bestiary"])
        XCTAssertEqual(shelf.model.readingListBooks.map(\.title), ["Chronicle", "Almanac", "Bestiary"])
        XCTAssertEqual(changes.count, 2, "each addition is one change of the library")

        LibraryPersistenceService.flushPendingSave()
        let saved = try Self.decode(Data(contentsOf: sandbox.indexURL))
        XCTAssertEqual(saved.readingList.bookIDs, shelf.ids("Chronicle", "Almanac", "Bestiary"))
    }

    /// Adding only books already in the list, none, or a book not in the
    /// library changes nothing and returns nothing.
    @MainActor
    func testAddingNothingNewChangesNothing() {
        let shelf = Self.shelf(["Almanac", "Bestiary"], listed: ["Almanac"])
        let changes = LibraryChangeCounter(shelf.model)

        XCTAssertEqual(shelf.model.addToReadingList(shelf.ids("Almanac")), [])
        XCTAssertEqual(shelf.model.addToReadingList([]), [])
        XCTAssertEqual(shelf.model.addToReadingList([UUID()]), [])

        XCTAssertEqual(changes.count, 0)
        XCTAssertEqual(shelf.model.readingList.bookIDs, shelf.ids("Almanac"))
    }

    /// Removing takes the books off the list and keeps the others in their
    /// order, returning those taken off in the list's order; removing books
    /// not in it changes nothing. The books stay in the library.
    @MainActor
    func testRemovingTakesBooksOffAndKeepsTheOthersInOrder() {
        let shelf = Self.shelf(
            ["Almanac", "Bestiary", "Chronicle", "Dockside Ledger"],
            listed: ["Dockside Ledger", "Almanac", "Chronicle", "Bestiary"]
        )
        let changes = LibraryChangeCounter(shelf.model)

        XCTAssertEqual(
            shelf.model.removeFromReadingList(shelf.ids("Bestiary", "Dockside Ledger")).map(\.title),
            ["Dockside Ledger", "Bestiary"]
        )
        XCTAssertEqual(shelf.model.readingListBooks.map(\.title), ["Almanac", "Chronicle"])
        XCTAssertEqual(shelf.model.removeFromReadingList(shelf.ids("Bestiary") + [UUID()]), [])

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(shelf.model.library.books.count, 4, "taking a book off the list never removes it from the library")
    }

    /// Whether a book is in the list follows every addition and removal.
    @MainActor
    func testMembershipFollowsAdditionsAndRemovals() {
        let shelf = Self.shelf(["Almanac", "Bestiary"])
        XCTAssertFalse(shelf.model.isInReadingList(shelf.id("Almanac")))

        shelf.model.addToReadingList(shelf.ids("Almanac"))
        XCTAssertTrue(shelf.model.isInReadingList(shelf.id("Almanac")))
        XCTAssertFalse(shelf.model.isInReadingList(shelf.id("Bestiary")))

        shelf.model.removeFromReadingList(shelf.ids("Almanac"))
        XCTAssertFalse(shelf.model.isInReadingList(shelf.id("Almanac")))
    }

    /// A book replaced by a new copy of itself, which has an ID of its own,
    /// gives the copy its place: the copy is where the book was, the others
    /// keep their order and the options stay. A book not in the list is
    /// replaced in nothing; a copy already in the list elsewhere gives that
    /// place up, so each book is held once; and a book replaced by itself
    /// stays as it is.
    func testAReplacedBooksCopyTakesItsPlace() {
        let (almanac, bestiary, chronicle, copy) = (UUID(), UUID(), UUID(), UUID())
        var list = ReadingList(bookIDs: [almanac, bestiary, chronicle], continuation: .stop, skipsFinished: false)

        XCTAssertTrue(list.replace(bestiary, with: copy))
        XCTAssertEqual(list, ReadingList(bookIDs: [almanac, copy, chronicle], continuation: .stop, skipsFinished: false))

        XCTAssertFalse(list.replace(UUID(), with: bestiary))
        XCTAssertEqual(list.bookIDs, [almanac, copy, chronicle])

        XCTAssertTrue(list.replace(chronicle, with: almanac))
        XCTAssertEqual(list.bookIDs, [copy, almanac])

        XCTAssertTrue(list.replace(copy, with: copy))
        XCTAssertEqual(list.bookIDs, [copy, almanac])
    }

    // MARK: - Order

    /// Move Book Up and Move Book Down at the list swap a book with the one
    /// beside it, report both titles for VoiceOver, and save at once; the
    /// first book cannot move up nor the last down, and a book not in the
    /// list cannot move at all, each changing nothing.
    @MainActor
    func testMovingUpAndDownSwapsWithTheBookBesideIt() {
        let titles = ["Almanac", "Bestiary", "Chronicle"]
        let shelf = Self.shelf(titles, listed: titles)
        let changes = LibraryChangeCounter(shelf.model)

        let up = shelf.model.moveInReadingList(bookID: shelf.id("Chronicle"), direction: .up)
        XCTAssertEqual(up?.movedTitle, "Chronicle")
        XCTAssertEqual(up?.adjacentTitle, "Bestiary")
        XCTAssertEqual(up?.direction, -1)
        XCTAssertEqual(up?.newIndex, 1)
        XCTAssertEqual(shelf.model.readingListBooks.map(\.title), ["Almanac", "Chronicle", "Bestiary"])

        let down = shelf.model.moveInReadingList(bookID: shelf.id("Almanac"), direction: .down)
        XCTAssertEqual(down?.movedTitle, "Almanac")
        XCTAssertEqual(down?.adjacentTitle, "Chronicle")
        XCTAssertEqual(down?.direction, 1)
        XCTAssertEqual(down?.newIndex, 1)
        XCTAssertEqual(shelf.model.readingListBooks.map(\.title), ["Chronicle", "Almanac", "Bestiary"])
        XCTAssertEqual(changes.count, 2)

        XCTAssertNil(shelf.model.moveInReadingList(bookID: shelf.id("Chronicle"), direction: .up), "the first book cannot move up")
        XCTAssertNil(shelf.model.moveInReadingList(bookID: shelf.id("Bestiary"), direction: .down), "the last book cannot move down")
        XCTAssertNil(shelf.model.moveInReadingList(bookID: UUID(), direction: .down), "a book not in the list cannot move")
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(shelf.model.readingListBooks.map(\.title), ["Chronicle", "Almanac", "Bestiary"])
    }

    /// A drag reorders the list as the list showed it and saves at once;
    /// offsets outside the list, as a list showing something else could
    /// send, and a drop where the books already are change nothing.
    @MainActor
    func testDraggingReordersTheList() throws {
        let titles = ["Almanac", "Bestiary", "Chronicle", "Dockside Ledger"]
        let shelf = Self.shelf(titles, listed: titles)

        shelf.model.reorderReadingList(from: IndexSet(integer: 3), to: 0)
        XCTAssertEqual(shelf.model.readingListBooks.map(\.title), ["Dockside Ledger", "Almanac", "Bestiary", "Chronicle"])
        shelf.model.reorderReadingList(from: IndexSet([1, 2]), to: 4)
        XCTAssertEqual(shelf.model.readingListBooks.map(\.title), ["Dockside Ledger", "Chronicle", "Almanac", "Bestiary"])

        let changes = LibraryChangeCounter(shelf.model)
        shelf.model.reorderReadingList(from: IndexSet(integer: 4), to: 0)
        shelf.model.reorderReadingList(from: IndexSet(integer: 0), to: 5)
        shelf.model.reorderReadingList(from: IndexSet(), to: 0)
        shelf.model.reorderReadingList(from: IndexSet(integer: 1), to: 1)
        XCTAssertEqual(changes.count, 0)

        LibraryPersistenceService.flushPendingSave()
        let saved = try Self.decode(Data(contentsOf: sandbox.indexURL))
        XCTAssertEqual(saved.readingList.bookIDs, shelf.ids("Dockside Ledger", "Chronicle", "Almanac", "Bestiary"))
    }

    /// A drag moves the list's books exactly as SwiftUI's
    /// `move(fromOffsets:toOffset:)` moves a list's rows, for every set of
    /// rows and every place to drop them in a list of five.
    @MainActor
    func testADragMovesBooksAsTheListMovesItsRows() {
        let ids = (0..<5).map { _ in UUID() }
        for mask in 1..<(1 << ids.count) {
            let source = IndexSet(ids.indices.filter { mask & (1 << $0) != 0 })
            for destination in 0...ids.count {
                var expected = ids
                expected.move(fromOffsets: source, toOffset: destination)
                var list = ReadingList(bookIDs: ids)
                XCTAssertTrue(list.move(fromOffsets: source, toOffset: destination))
                XCTAssertEqual(list.bookIDs, expected, "\(Array(source)) to \(destination)")
            }
        }
    }

    /// Rearranging the list leaves every book's place in its folder's own
    /// manual order alone: the two orders are separate.
    @MainActor
    func testRearrangingTheListNeverChangesAFoldersManualOrder() {
        let books = ["Shelved 0", "Shelved 1", "Shelved 2"].enumerated().map { position, title in
            LibrarySortStateTests.shelvedBook(title, in: "Shelf", manualOrder: position)
        }
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: books, folders: [BookFolder(name: "Shelf")], readingList: ReadingList(bookIDs: books.map(\.id)))
        let first = books.first?.id ?? UUID()

        model.moveInReadingList(bookID: first, direction: .down)
        model.reorderReadingList(from: IndexSet(integer: 2), to: 0)

        // Shelved 0 moved below Shelved 1, then Shelved 2 was dragged to the top.
        XCTAssertEqual(model.readingListBooks.map(\.title), ["Shelved 2", "Shelved 1", "Shelved 0"])
        XCTAssertEqual(model.library.books.map(\.manualSortOrder), [0, 1, 2])
        XCTAssertEqual(
            ManualBookOrder.orderedBooks(in: model.library, folderPath: "Shelf").map(\.title),
            ["Shelved 0", "Shelved 1", "Shelved 2"]
        )
    }

    // MARK: - Options

    /// Each option is saved when chosen, once; choosing the option already
    /// chosen changes nothing.
    @MainActor
    func testChoosingAnOptionSavesItOnce() throws {
        let shelf = Self.shelf(["Almanac"])
        let changes = LibraryChangeCounter(shelf.model)

        shelf.model.setReadingListContinuation(.playBookAbove)
        shelf.model.setReadingListContinuation(.playBookAbove)
        shelf.model.setReadingListSkipsFinished(false)
        shelf.model.setReadingListSkipsFinished(false)

        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(shelf.model.readingList.continuation, .playBookAbove)
        XCTAssertFalse(shelf.model.readingList.skipsFinished)
        LibraryPersistenceService.flushPendingSave()
        let saved = try Self.decode(Data(contentsOf: sandbox.indexURL))
        XCTAssertEqual(saved.readingList.continuation, .playBookAbove)
        XCTAssertFalse(saved.readingList.skipsFinished)
    }

    // MARK: - Removing Finished Books

    /// The option is saved under a key of its own, with the list, and read
    /// back as it was.
    @MainActor
    func testRemoveFinishedIsSavedWithTheListAndReadBack() throws {
        let shelf = Self.shelf(["Almanac", "Bestiary"])
        let list = ReadingList(bookIDs: shelf.ids("Bestiary"), continuation: .stop, skipsFinished: false, removesFinished: true)
        let library = Library(books: shelf.books, readingList: list)

        let saved = try XCTUnwrap(try JSONSerialization.jsonObject(with: LibraryIndexSandbox.encoded(library)) as? [String: Any])
        let savedList = try XCTUnwrap(saved["readingList"] as? [String: Any])
        XCTAssertEqual(savedList["removesFinished"] as? Bool, true)

        let reread = try LibrarySortStateTests.reread(library)
        XCTAssertEqual(reread.readingList, list)
        XCTAssertTrue(reread.readingList.removesFinished)
        // A list that keeps its finished books round trips as well.
        let keeping = try LibrarySortStateTests.reread(Library(books: shelf.books))
        XCTAssertFalse(keeping.readingList.removesFinished)
    }

    /// A list saved before the option existed has no key for it, and reads
    /// as off, with its other options and its books as they were; so does a
    /// key of the wrong kind, which never makes the index unreadable.
    @MainActor
    func testAListSavedBeforeRemoveFinishedReadsItAsOff() throws {
        let shelf = Self.shelf(["Almanac", "Bestiary"])
        let list = ReadingList(
            bookIDs: shelf.ids("Bestiary", "Almanac"),
            continuation: .playBookAbove,
            skipsFinished: false,
            removesFinished: true
        )
        let library = Library(books: shelf.books, readingList: list)

        let older = try Self.index(of: library) { index in
            var savedList = (index["readingList"] as? [String: Any]) ?? [:]
            savedList.removeValue(forKey: "removesFinished")
            index["readingList"] = savedList
        }
        let read = try Self.decode(older).readingList
        XCTAssertFalse(read.removesFinished)
        XCTAssertEqual(read.bookIDs, shelf.ids("Bestiary", "Almanac"))
        XCTAssertEqual(read.continuation, .playBookAbove)
        XCTAssertFalse(read.skipsFinished)

        for nonsense: Any in ["yes", 3, NSNull(), ["on"]] {
            let damaged = try Self.index(of: library) { index in
                var savedList = (index["readingList"] as? [String: Any]) ?? [:]
                savedList["removesFinished"] = nonsense
                index["readingList"] = savedList
            }
            let reread = try Self.decode(damaged)
            XCTAssertFalse(reread.readingList.removesFinished, "\(nonsense)")
            XCTAssertEqual(reread.readingList.bookIDs, shelf.ids("Bestiary", "Almanac"), "\(nonsense)")
        }
    }

    /// A TextMouth older than the option decodes the list with the keys it
    /// knew (`bookIDs`, `continuation`, `skipsFinished`) and ignores the
    /// new one, so a library saved by this version opens there. The older
    /// reading is stood in for by a type whose synthesized decoder names
    /// only the older keys, as `ReadingList`'s did.
    @MainActor
    func testAnOlderReaderIgnoresTheNewKey() throws {
        /// `ReadingList` as it was before `removesFinished`.
        struct OlderReadingList: Decodable {
            let bookIDs: [UUID]
            let continuation: String
            let skipsFinished: Bool
        }
        let shelf = Self.shelf(["Almanac", "Bestiary"])
        let list = ReadingList(bookIDs: shelf.ids("Almanac"), continuation: .stop, skipsFinished: false, removesFinished: true)

        let json = try JSONEncoder().encode(list)
        let older = try JSONDecoder().decode(OlderReadingList.self, from: json)

        XCTAssertEqual(older.bookIDs, shelf.ids("Almanac"))
        XCTAssertEqual(older.continuation, "stop")
        XCTAssertFalse(older.skipsFinished)
    }

    /// Choosing the option saves it once with the list, in one change of
    /// library; choosing the choice already made saves nothing. Turning it
    /// on takes no book off the list, the finished ones included: it acts
    /// on books finished from then on.
    @MainActor
    func testChoosingRemoveFinishedSavesItOnceAndTakesNoBookOff() throws {
        let shelf = Self.shelf(["Almanac", "Bestiary"], listed: ["Almanac", "Bestiary"])
        shelf.model.finishedBookIDs = { Set(shelf.ids("Almanac")) }
        let changes = LibraryChangeCounter(shelf.model)

        shelf.model.setReadingListRemovesFinished(true)
        shelf.model.setReadingListRemovesFinished(true)

        XCTAssertEqual(changes.count, 1)
        XCTAssertTrue(shelf.model.readingList.removesFinished)
        XCTAssertEqual(shelf.model.readingList.bookIDs, shelf.ids("Almanac", "Bestiary"), "the finished book left at once")
        LibraryPersistenceService.flushPendingSave()
        let saved = try Self.decode(Data(contentsOf: sandbox.indexURL))
        XCTAssertTrue(saved.readingList.removesFinished)
    }

    /// With the option on, a finished book on the list is taken off it, by
    /// the removal Remove from Reading List makes: the others keep their
    /// order and the options stay, the book stays in the library, and the
    /// index is saved. Nothing is said.
    @MainActor
    func testAFinishedBookOnTheListIsTakenOffWhenTheOptionIsOn() throws {
        let shelf = Self.shelf(["Almanac", "Bestiary", "Chronicle"], listed: ["Almanac", "Bestiary", "Chronicle"])
        shelf.model.setReadingListRemovesFinished(true)
        shelf.model.setReadingListContinuation(.playBookAbove)
        let changes = LibraryChangeCounter(shelf.model)

        let recorder = recordingAnnouncements {
            XCTAssertTrue(shelf.model.removeFinishedBookFromReadingList(shelf.id("Bestiary")))
        }

        XCTAssertEqual(shelf.model.readingList.bookIDs, shelf.ids("Almanac", "Chronicle"))
        XCTAssertEqual(shelf.model.readingList.continuation, .playBookAbove)
        XCTAssertTrue(shelf.model.readingList.removesFinished)
        XCTAssertEqual(shelf.model.library.books.count, 3, "the book left the library")
        XCTAssertEqual(changes.count, 1)
        LibraryPersistenceService.flushPendingSave()
        let saved = try Self.decode(Data(contentsOf: sandbox.indexURL))
        XCTAssertEqual(saved.readingList.bookIDs, shelf.ids("Almanac", "Chronicle"))
        XCTAssertEqual(recorder.announcements.map(\.message), [], "the removal said something")
    }

    /// With the option off, which is how a list starts, a finished book
    /// stays on the list; and with it on, a finished book that is not on
    /// the list, or is not in the library, changes nothing and saves
    /// nothing.
    @MainActor
    func testAFinishedBookIsKeptWhenTheOptionIsOffOrTheBookIsNotListed() {
        let shelf = Self.shelf(["Almanac", "Bestiary"], listed: ["Almanac"])
        let changes = LibraryChangeCounter(shelf.model)

        XCTAssertFalse(shelf.model.removeFinishedBookFromReadingList(shelf.id("Almanac")), "removed with the option off")
        XCTAssertEqual(shelf.model.readingList.bookIDs, shelf.ids("Almanac"))

        shelf.model.setReadingListRemovesFinished(true)
        let afterOption = changes.count
        XCTAssertFalse(shelf.model.removeFinishedBookFromReadingList(shelf.id("Bestiary")), "a book not on the list")
        XCTAssertFalse(shelf.model.removeFinishedBookFromReadingList(UUID()), "a book not in the library")
        XCTAssertEqual(shelf.model.readingList.bookIDs, shelf.ids("Almanac"))
        XCTAssertEqual(changes.count, afterOption, "a change that changed nothing was made")
    }

    /// The library hears of a finished book from the statistics service it
    /// observes, and acts one turn of the main queue after it is told,
    /// never within the telling: a reader that asks the list what follows
    /// its book in the same turn still finds the book there. Only the
    /// service it observes is heard, and only a book on the list leaves it.
    @MainActor
    func testTheLibraryTakesAFinishedBookOffOnTheTurnAfterItIsTold() throws {
        let shelf = Self.shelf(["Almanac", "Bestiary", "Chronicle"], listed: ["Almanac", "Bestiary", "Chronicle"])
        shelf.model.setReadingListRemovesFinished(true)
        let statistics = try makeStatistics("RemoveFinished")
        let other = try makeStatistics("RemoveFinishedOther")
        shelf.model.observeFinishedBooks(of: statistics)

        statistics.markBookFinished(bookID: shelf.id("Bestiary"), title: "Bestiary")
        XCTAssertEqual(shelf.model.readingList.bookIDs, shelf.ids("Almanac", "Bestiary", "Chronicle"), "removed within the telling")
        XCTAssertTrue(eventually { shelf.model.readingList.bookIDs == shelf.ids("Almanac", "Chronicle") }, "never removed")

        // Another service's finished book is none of this library's business.
        other.markBookFinished(bookID: shelf.id("Almanac"), title: "Almanac")
        // A book not on the list changes nothing.
        statistics.markBookFinished(bookID: UUID(), title: "Elsewhere")
        spinMainRunLoop(for: 0.2)
        XCTAssertEqual(shelf.model.readingList.bookIDs, shelf.ids("Almanac", "Chronicle"))
    }

    /// A statistics service over a file of its own in a sandbox folder
    /// named for `label`, shut down when the test ends.
    @MainActor
    private func makeStatistics(_ label: String) throws -> ReadingStatsService {
        let file = try makeSandboxDirectory(label).appendingPathComponent("reading_stats.json")
        let service = ReadingStatsService(fileURL: file)
        addTeardownBlock { @MainActor in service.shutdown() }
        return service
    }

    // MARK: - Neighbors

    /// Down is the book below, up the book above, and nothing lies beyond
    /// either end of the list; a book not in the list has no neighbors, nor
    /// has the only book of a list.
    @MainActor
    func testNeighborsAreTheBooksBelowAndAboveAndNothingPastTheEnds() {
        let shelf = Self.shelf(["Almanac", "Bestiary", "Chronicle"], listed: ["Bestiary", "Almanac", "Chronicle"])
        func neighbor(_ title: String, _ direction: ReadingList.Direction) -> String? {
            shelf.model.readingListNeighbor(of: shelf.id(title), direction: direction, skippingFinished: false)?.title
        }

        XCTAssertNil(neighbor("Bestiary", .up), "nothing is above the first book")
        XCTAssertEqual(neighbor("Bestiary", .down), "Almanac")
        XCTAssertEqual(neighbor("Almanac", .up), "Bestiary")
        XCTAssertEqual(neighbor("Almanac", .down), "Chronicle")
        XCTAssertEqual(neighbor("Chronicle", .up), "Almanac")
        XCTAssertNil(neighbor("Chronicle", .down), "nothing is below the last book")
        XCTAssertNil(shelf.model.readingListNeighbor(of: UUID(), direction: .down, skippingFinished: false))

        shelf.model.removeFromReadingList(shelf.ids("Almanac", "Chronicle"))
        XCTAssertNil(neighbor("Bestiary", .down), "the only book has no neighbor")
        XCTAssertNil(neighbor("Bestiary", .up))
        XCTAssertNil(neighbor("Almanac", .up), "a book off the list has none")
    }

    /// Skipping finished books passes over each finished book, however many
    /// lie together, to the nearest one not finished; past only finished
    /// books there is none, as at the end. Not skipping, the finished book
    /// beside is the neighbor. A finished book still has neighbors itself.
    @MainActor
    func testNeighborsPassOverFinishedBooksWhenAsked() {
        let titles = ["One", "Two", "Three", "Four", "Five"]
        let shelf = Self.shelf(titles, listed: titles)
        let finished = Set(shelf.ids("Two", "Three", "Five"))
        shelf.model.finishedBookIDs = { finished }
        func neighbor(_ title: String, _ direction: ReadingList.Direction, skipping: Bool) -> String? {
            shelf.model.readingListNeighbor(of: shelf.id(title), direction: direction, skippingFinished: skipping)?.title
        }

        XCTAssertEqual(neighbor("One", .down, skipping: true), "Four", "past two finished books")
        XCTAssertEqual(neighbor("One", .down, skipping: false), "Two")
        XCTAssertNil(neighbor("Four", .down, skipping: true), "only a finished book is below")
        XCTAssertEqual(neighbor("Four", .down, skipping: false), "Five")
        XCTAssertEqual(neighbor("Four", .up, skipping: true), "One")
        XCTAssertEqual(neighbor("Three", .up, skipping: true), "One", "a finished book has neighbors too")
        XCTAssertNil(neighbor("One", .up, skipping: true))
    }

    /// What follows a book opened from the list follows the options: the
    /// book below, the book above, or none for Stop, passing over finished
    /// books only while Skip Finished Books is on; nothing follows a book
    /// at that end of the list, or a book no longer in it.
    @MainActor
    func testTheContinuationFollowsTheListsOptions() {
        let titles = ["One", "Two", "Three"]
        let shelf = Self.shelf(titles, listed: titles)
        let finished = Set(shelf.ids("One", "Three"))
        shelf.model.finishedBookIDs = { finished }
        func continuation(after title: String) -> String? {
            shelf.model.readingListContinuation(after: shelf.id(title))?.title
        }

        // The default: the book below, passing over finished books.
        XCTAssertNil(continuation(after: "Two"), "only a finished book is below")
        shelf.model.setReadingListSkipsFinished(false)
        XCTAssertEqual(continuation(after: "Two"), "Three")
        XCTAssertNil(continuation(after: "Three"), "nothing is below the last book")

        shelf.model.setReadingListContinuation(.playBookAbove)
        XCTAssertEqual(continuation(after: "Two"), "One")
        shelf.model.setReadingListSkipsFinished(true)
        XCTAssertNil(continuation(after: "Two"), "only a finished book is above")
        XCTAssertEqual(continuation(after: "Three"), "Two")

        shelf.model.setReadingListContinuation(.stop)
        for title in titles {
            XCTAssertNil(continuation(after: title), title)
        }

        shelf.model.setReadingListContinuation(.playBookBelow)
        shelf.model.setReadingListSkipsFinished(false)
        shelf.model.removeFromReadingList(shelf.ids("Two"))
        XCTAssertNil(continuation(after: "Two"), "a book off the list has nothing after it")
        XCTAssertEqual(continuation(after: "One"), "Three")
    }

    /// The books Books Finished counts are those the statistics record, by
    /// ID, each once; an entry whose ID cannot be read is left out.
    @MainActor
    func testFinishedBooksAreThoseTheStatisticsRecord() {
        let finished = UUID()
        var stats = ReadingStats()
        stats.finishedBooks = [
            FinishedBookEntry(bookID: finished.uuidString, title: "Read", dateFinished: Date()),
            FinishedBookEntry(bookID: "not an ID", title: "Unreadable", dateFinished: Date()),
            FinishedBookEntry(bookID: finished.uuidString, title: "Read again", dateFinished: Date()),
        ]
        XCTAssertEqual(stats.finishedBookIDs, [finished])
    }

    // MARK: - An ID Naming No Book

    /// An ID naming no book, which only a removal that went around the
    /// library's own could leave, is never shown nor a neighbor, does not
    /// count in positions, and is dropped with the next change to the list.
    @MainActor
    func testAnIDNamingNoBookIsPassedOverAndDroppedAtTheNextChange() {
        let gone = UUID()
        let almanac = Self.book("Almanac")
        let bestiary = Self.book("Bestiary")
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [almanac, bestiary], readingList: ReadingList(bookIDs: [almanac.id, gone, bestiary.id]))

        XCTAssertEqual(model.readingListBooks.map(\.title), ["Almanac", "Bestiary"])
        XCTAssertEqual(model.readingListNeighbor(of: almanac.id, direction: .down, skippingFinished: false)?.title, "Bestiary")
        XCTAssertNil(model.readingListNeighbor(of: gone, direction: .down, skippingFinished: false))

        // Positions count the books shown: moving the second book up passes
        // the first.
        let moved = model.moveInReadingList(bookID: bestiary.id, direction: .up)
        XCTAssertEqual(moved?.adjacentTitle, "Almanac")
        XCTAssertEqual(moved?.newIndex, 0)
        XCTAssertEqual(model.readingList.bookIDs, [bestiary.id, almanac.id])
    }

    // MARK: - The Lists Library Windows Show

    /// The kept lists are derived again when the reading list's books or
    /// their order change, and kept when only an option changes.
    @MainActor
    func testTheListCacheSeesTheReadingListsBooksAndOrder() {
        let shelf = Self.shelf(["Almanac", "Bestiary"])
        var revision = shelf.model.listCache.listRevision

        shelf.model.addToReadingList(shelf.ids("Almanac", "Bestiary"))
        XCTAssertGreaterThan(shelf.model.listCache.listRevision, revision, "an addition")
        revision = shelf.model.listCache.listRevision

        shelf.model.moveInReadingList(bookID: shelf.id("Bestiary"), direction: .up)
        XCTAssertGreaterThan(shelf.model.listCache.listRevision, revision, "a move")
        revision = shelf.model.listCache.listRevision

        shelf.model.setReadingListContinuation(.stop)
        shelf.model.setReadingListSkipsFinished(false)
        shelf.model.setReadingListRemovesFinished(true)
        XCTAssertEqual(shelf.model.listCache.listRevision, revision, "an option")

        shelf.model.removeFromReadingList(shelf.ids("Almanac"))
        XCTAssertGreaterThan(shelf.model.listCache.listRevision, revision, "a removal")
    }

    // MARK: - Fixtures

    /// A library model of a book titled each of `titles`, at the root, whose
    /// reading list holds the books titled `listed`, in that order; with
    /// the books, found by title.
    @MainActor
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

// MARK: - Counting Changes

/// Counts the changes of a library model's library from the moment it is
/// made: each is one publish, which every Library window draws again for,
/// and at most one save of the index.
final class LibraryChangeCounter {
    /// The changes counted so far.
    private(set) var count = 0
    /// The subscription counting them, kept while the counter lives.
    private var subscription: AnyCancellable?

    /// Starts counting the changes of `model`'s library; the library as it
    /// is now, which a subscription is given first, is not counted.
    @MainActor
    init(_ model: LibraryViewModel) {
        subscription = model.$library.dropFirst().sink { [weak self] _ in
            self?.count += 1
        }
    }
}
