import XCTest
@testable import TextMouth

/// `PhoneRowWording`: the Continue row, search's count, the empty states,
/// removal, and the screens' titles, each the Mac's word or the spec's.
@MainActor
final class PhoneRowWordingTests: XCTestCase {
    // MARK: - The Continue Row

    /// Not playing, the row says the Mac's words, with the time left; playing,
    /// "Now Playing:" and the title alone.
    func testTheContinueRowsWords() {
        let book = PhoneLibraryFixture.book("Emma", percent: 50)

        let label = PhoneRowWording.continueLabel(for: book, wordsPerMinute: 200)
        XCTAssertEqual(label, LibraryView.continueAccessibilityLabel(for: book, wpm: 200))
        XCTAssertTrue(label.hasPrefix("Continue listening to Emma, "), label)
        XCTAssertTrue(label.hasSuffix(" remaining"), label)
        XCTAssertEqual(PhoneRowWording.nowPlayingLabel(title: "Emma"), "Now Playing: Emma")
        XCTAssertEqual(PhoneRowWording.continueHint, "Opens the last book you were reading")
        XCTAssertEqual(PhoneRowWording.continueVisibleTitle(for: book), "Continue: Emma")
        XCTAssertEqual(PhoneRowWording.continueTimeText(for: book, wordsPerMinute: 200), LibraryView.continueTimeText(for: book, wpm: 200))
    }

    /// A finished book's row has no time left to say.
    func testAFinishedBookHasNoTimeLeft() {
        let book = PhoneLibraryFixture.book("Emma", percent: 100)

        XCTAssertEqual(PhoneRowWording.continueLabel(for: book, wordsPerMinute: 200), "Continue listening to Emma")
        XCTAssertNil(PhoneRowWording.continueTimeText(for: book, wordsPerMinute: 200))
    }

    // MARK: - Searching

    /// The count is the Mac's counted books; with nothing at all found, the
    /// row's sentence.
    func testSearchsCount() {
        XCTAssertEqual(PhoneRowWording.searchCount(books: 3, folders: 0), "3 books")
        XCTAssertEqual(PhoneRowWording.searchCount(books: 1, folders: 2), "1 book")
        XCTAssertEqual(PhoneRowWording.searchCount(books: 0, folders: 1), "0 books")
        XCTAssertEqual(PhoneRowWording.searchCount(books: 0, folders: 0), "No books match.")
    }

    // MARK: - Empty States

    /// Each empty state's sentence is the spec's, and a view's is the Mac's.
    func testTheEmptySentences() {
        XCTAssertEqual(PhoneRowWording.sentence(for: .emptyLibrary), "Your library is empty. Add to Library adds a book.")
        XCTAssertEqual(PhoneRowWording.sentence(for: .emptyFolder), "This folder is empty.")
        XCTAssertEqual(PhoneRowWording.sentence(for: .noMatches), "No books match.")
        XCTAssertEqual(
            PhoneRowWording.sentence(for: .emptyReadingList),
            "The reading list is empty. To add a book, choose Add to Reading List from its actions."
        )
        XCTAssertEqual(PhoneRowWording.sentence(for: .emptyView), LibraryViewPickerWording.emptyView)
        XCTAssertFalse(PhoneRowWording.emptyReadingList.contains("Library menu"))
    }

    // MARK: - Removing a Book

    /// The one question's words: the Mac's title and button, the spec's
    /// message, and the Mac's sentence once the book is deleted.
    func testTheRemovalWords() {
        let book = PhoneLibraryFixture.book("Dune")

        XCTAssertEqual(PhoneRowWording.removalTitle(for: book), "Remove Book?")
        XCTAssertEqual(PhoneRowWording.removalDeleteButton, "Delete Permanently")
        XCTAssertEqual(PhoneRowWording.removalDone(title: "Dune"), "Deleted “Dune” permanently.")
        XCTAssertEqual(
            PhoneRowWording.removalMessage,
            "This deletes the book and its files from this iPhone, and they can't be recovered. Your Mac's library isn't touched."
        )
        XCTAssertFalse(PhoneRowWording.removalMessage.contains("Trash"))
    }

    // MARK: - Titles and Arrival

    /// "Library" at the top, the folder's name in a folder, and "Library:"
    /// with the view's name elsewhere.
    func testTheScreensTitles() {
        XCTAssertEqual(PhoneRowWording.screenTitle(for: LibraryLocation(category: .folders, folderPath: "")), "Library")
        XCTAssertEqual(PhoneRowWording.screenTitle(for: LibraryLocation(category: .folders, folderPath: "Fiction/Old")), "Old")
        XCTAssertEqual(PhoneRowWording.screenTitle(for: LibraryLocation(category: .allItems, folderPath: "Fiction")), "Library: All Items")
        XCTAssertEqual(PhoneRowWording.screenTitle(for: LibraryLocation(category: .readingList, folderPath: "")), "Library: Reading List")
    }

    /// A folder's arrival says the Mac's name and count.
    func testAFoldersArrivalWords() {
        let library = Library(
            books: [PhoneLibraryFixture.book("Weir", in: "Fiction"), PhoneLibraryFixture.book("Orchard", in: "Fiction/Old")],
            folders: [BookFolder(name: "Fiction"), BookFolder(name: "Old", parentPath: "Fiction")]
        )

        XCTAssertEqual(PhoneRowWording.folderArrival(at: "Fiction", in: library), "Fiction, 2 books")
    }
}
