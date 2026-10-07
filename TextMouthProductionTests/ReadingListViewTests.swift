import SwiftUI
import XCTest
@testable import TextMouth

/// The Reading List in the Library window (FR09): the fifth category, which
/// lists the reading list's books from every folder in the list's own
/// order, which no sort changes; its Sort menu's one order; Move Book Up,
/// Move Book Down, and dragging there; and the "In reading list" a book's
/// row says everywhere else. These tests pin that wording and behavior.
final class ReadingListViewTests: XCTestCase {
    /// The isolated data root's index, put back after a test that saves.
    private var sandbox: LibraryIndexSandbox!

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // Tear-down also runs when capturing failed in set-up.
        sandbox?.restore()
    }

    // MARK: - The Category

    /// The View picker's fifth segment reads "Reading List", under the
    /// picker's own label; the window names the location the same way,
    /// alone, since its one order is its own.
    @MainActor
    func testTheReadingListIsTheFifthSegmentAndNamesItsWindow() {
        XCTAssertEqual(LibraryView.categoryPickerLabel, "Library category")
        XCTAssertEqual(LibraryCategory.allCases.last, .readingList)
        XCTAssertEqual(LibraryCategory.allCases.firstIndex(of: .readingList), 4)
        XCTAssertEqual(LibraryCategory.readingList.rawValue, "Reading List")

        let location = LibraryLocation(category: .readingList, folderPath: "Essays")
        XCTAssertEqual(location.name, "Reading List")
        XCTAssertEqual(location.windowTitle(sortedBy: Library().sortState(at: location)), "Library: Reading List")
    }

    /// The Reading List lists the reading list's books, from the root and
    /// any folder, in the list's order, whatever folder Folders showed
    /// last; a search narrows it and keeps the order. Books not in the list
    /// are not listed, and the folders' own lists are as they were.
    @MainActor
    func testTheReadingListListsItsBooksInItsOwnOrderFromEveryFolder() {
        let shelf = Self.shelf()
        shelf.model.addToReadingList(shelf.ids("Travel Notes", "Loose Pages", "Field Notes"))
        let readingList = LibraryLocation(category: .readingList, folderPath: "Essays")

        XCTAssertEqual(shelf.model.displayedBooks(at: readingList).map(\.title), ["Travel Notes", "Loose Pages", "Field Notes"])
        XCTAssertEqual(shelf.model.displayedBooks(at: readingList, matching: "notes").map(\.title), ["Travel Notes", "Field Notes"])
        XCTAssertEqual(
            Set(shelf.model.displayedBooks(at: LibraryLocation(category: .folders, folderPath: "Essays")).map(\.title)),
            ["Field Notes", "Unlisted Essay"]
        )
    }

    /// The list follows every change to the reading list the next time it
    /// is read: an addition, a move, and a removal.
    @MainActor
    func testTheListFollowsTheReadingList() {
        let shelf = Self.shelf()
        let readingList = LibraryLocation(category: .readingList, folderPath: "")
        XCTAssertEqual(shelf.model.displayedBooks(at: readingList), [])

        shelf.model.addToReadingList(shelf.ids("Loose Pages", "Field Notes"))
        XCTAssertEqual(shelf.model.displayedBooks(at: readingList).map(\.title), ["Loose Pages", "Field Notes"])
        shelf.model.moveInReadingList(bookID: shelf.id("Field Notes"), direction: .up)
        XCTAssertEqual(shelf.model.displayedBooks(at: readingList).map(\.title), ["Field Notes", "Loose Pages"])
        shelf.model.removeFromReadingList(shelf.ids("Field Notes"))
        XCTAssertEqual(shelf.model.displayedBooks(at: readingList).map(\.title), ["Loose Pages"])
    }

    /// Hosted, a Library window at the Reading List draws a row for each of
    /// the list's books.
    @MainActor
    func testTheWindowAtTheReadingListDrawsARowForEachBook() {
        let shelf = Self.shelf()
        shelf.model.addToReadingList(shelf.ids("Travel Notes", "Loose Pages", "Field Notes"))
        let rowsBefore = ViewBodyCounter.count(of: "BookRow")

        let hosted = Self.hostLibraryWindow(showing: .readingList, of: shelf.model, in: self)
        defer { takeDown(hosted.window) }
        settle(hosted.hostingView, seconds: 0.5)

        XCTAssertGreaterThanOrEqual(ViewBodyCounter.count(of: "BookRow") - rowsBefore, 3)
    }

    // MARK: - Its One Order

    /// The Reading List shows its own order, as manual order, whatever is
    /// saved under its key; choosing a sort there saves nothing and leaves
    /// that order shown. Its key is reserved, as every category's is, so
    /// no folder can take it.
    @MainActor
    func testTheReadingListKeepsItsOwnOrderAndSavesNoSort() {
        let model = LibraryViewModel(initializeServices: false)
        let readingList = LibraryLocation(category: .readingList, folderPath: "")
        let manual = LibrarySortState(restoring: FolderSortSetting(sortField: .manual, sortAscending: true))
        model.library = Library(folderSortSettings: ["__readingList__": FolderSortSetting(sortField: .title, sortAscending: false)])

        XCTAssertEqual(LibraryCategory.readingList.sortSettingsKey, "__readingList__")
        XCTAssertNil(BookFolder.normalizedName("__readingList__"))
        XCTAssertEqual(LibraryCategory.readingList.defaultSortSetting, .readingListOrder)
        XCTAssertEqual(model.sortState(at: readingList), manual)

        model.library.folderSortSettings = [:]
        for change in [LibrarySortChange.choose(.title), .choose(.fileSize), .reverseDirection, .choose(.manual)] {
            XCTAssertEqual(model.userChangedSort(change, at: readingList), manual, "\(change)")
        }
        XCTAssertEqual(model.library.folderSortSettings, [:])
    }

    /// The Sort menu at the Reading List names its one order, which its
    /// button says and choosing it announces, with a hint saying how the
    /// order changes.
    @MainActor
    func testTheSortMenuNamesTheReadingListsOrder() {
        XCTAssertEqual(ReadingListWording.orderName, "Reading List Order")
        XCTAssertEqual(ReadingListWording.sortMenuLabel, "Sort books by Reading List Order")
        XCTAssertEqual(ReadingListWording.orderAnnouncement, "Sorted by Reading List Order")
        XCTAssertEqual(
            ReadingListWording.orderHint,
            "The reading list keeps the order you arrange with Move Book Up, Move Book Down, or dragging"
        )
    }

    // MARK: - Rearranging

    /// The Reading List is rearranged wherever it is shown, whatever sort a
    /// folder would show, and never as a folder: it has no folder's manual
    /// order, and a folder is rearranged only in manual order, as before.
    @MainActor
    func testTheReadingListIsWhatMovesAndDragsRearrangeThere() {
        let readingList = LibraryLocation(category: .readingList, folderPath: "Essays")
        let folder = LibraryLocation(category: .folders, folderPath: "Essays")
        XCTAssertNil(readingList.manualOrderFolder)
        XCTAssertTrue(readingList.keepsItsOwnOrder)
        XCTAssertFalse(folder.keepsItsOwnOrder)
        for field in LibrarySortField.allCases {
            let sort = LibrarySortState(restoring: FolderSortSetting(sortField: field, sortAscending: true))
            XCTAssertEqual(readingList.reorderTarget(sortedBy: sort), .readingList, field.rawValue)
            XCTAssertNil(readingList.reorderableFolder(sortedBy: sort), field.rawValue)
            XCTAssertEqual(folder.reorderTarget(sortedBy: sort), field == .manual ? .folder("Essays") : nil, field.rawValue)
        }
    }

    /// Move Book Up and Move Book Down at the Reading List move a book in
    /// the list and say so exactly as they do in a folder: "Moved ... above
    /// ..." and "Moved ... below ...". A drag rearranges the list. Neither
    /// touches the folder's order.
    @MainActor
    func testMovesAtTheReadingListAnnounceAsInAFolder() {
        let shelf = Self.shelf()
        shelf.model.addToReadingList(shelf.ids("Loose Pages", "Field Notes", "Travel Notes"))

        let up = shelf.model.moveBook(shelf.id("Field Notes"), direction: -1, in: .readingList)
        XCTAssertEqual(up?.announcement, "Moved Field Notes above Loose Pages")
        let down = shelf.model.moveBook(shelf.id("Field Notes"), direction: 1, in: .readingList)
        XCTAssertEqual(down?.announcement, "Moved Field Notes below Loose Pages")
        XCTAssertNil(shelf.model.moveBook(shelf.id("Travel Notes"), direction: 1, in: .readingList), "the last book cannot move down")
        XCTAssertNil(shelf.model.moveBook(shelf.id("Loose Pages"), direction: 0, in: .readingList), "no direction moves nothing")

        shelf.model.reorderBooks(in: .readingList, from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(shelf.model.readingListBooks.map(\.title), ["Travel Notes", "Loose Pages", "Field Notes"])

        // In a folder in manual order, the same words.
        let essays = LibraryLocation(category: .folders, folderPath: "Essays")
        shelf.model.userChangedSort(.choose(.manual), at: essays)
        let ordered = shelf.model.displayedBooks(at: essays).map(\.title)
        let last = ordered.last ?? ""
        let other = ordered.first ?? ""
        XCTAssertEqual(
            shelf.model.moveBook(shelf.id(last), direction: -1, in: .folder("Essays"))?.announcement,
            "Moved \(last) above \(other)"
        )
        XCTAssertEqual(shelf.model.readingListBooks.map(\.title), ["Travel Notes", "Loose Pages", "Field Notes"])
    }

    // MARK: - The Rows Say "In reading list"

    /// A book's row says "In reading list" as its value, after its label,
    /// which stays the same; a row for a book not in the list says nothing
    /// more.
    @MainActor
    func testARowSaysInReadingListAsItsValueAndKeepsItsLabel() {
        let book = Self.book("Loose Pages", in: "")
        let listed = BookRow(book: book, isInReadingList: true)
        let unlisted = BookRow(book: book)

        XCTAssertEqual(ReadingListWording.inReadingListValue, "In reading list")
        XCTAssertEqual(listed.rowAccessibilityValue, "In reading list")
        XCTAssertNil(unlisted.rowAccessibilityValue)
        XCTAssertEqual(listed.rowAccessibilityLabel, unlisted.rowAccessibilityLabel)
        XCTAssertEqual(listed.rowAccessibilityLabel, "Loose Pages, by Ines Okonkwo-Varga, New, Plain Text")
    }

    /// Hosted, the row is one element whose label is the row's and whose
    /// value is "In reading list", as VoiceOver reads them; skipped where
    /// SwiftUI exposes no elements without an assistive app.
    @MainActor
    func testAHostedRowCarriesTheValue() throws {
        let row = BookRow(book: Self.book("Loose Pages", in: ""), isInReadingList: true)
        let label = row.rowAccessibilityLabel

        try withHostedView(row, until: { !self.accessibilityElements(labelled: label, in: $0).isEmpty }) { hostingView in
            let found = accessibilityElements(labelled: label, in: hostingView)
            guard let element = found.first else {
                throw XCTSkip("SwiftUI exposed no accessibility elements without an assistive app")
            }
            XCTAssertEqual(found.count, 1, "the row is one element")
            XCTAssertEqual(element.accessibilityValue() as? String, "In reading list")
        }
    }

    // MARK: - Fixtures

    /// A library model of four books: "Loose Pages" at the root, "Field
    /// Notes" and "Unlisted Essay" in Essays, and "Travel Notes" in
    /// Essays/Travel; none in the reading list.
    @MainActor
    private static func shelf() -> ReadingListShelf {
        let books = [
            book("Loose Pages", in: ""),
            book("Field Notes", in: "Essays"),
            book("Unlisted Essay", in: "Essays"),
            book("Travel Notes", in: "Essays/Travel"),
        ]
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(
            books: books,
            folders: [BookFolder(name: "Essays"), BookFolder(name: "Travel", parentPath: "Essays")]
        )
        return ReadingListShelf(model: model, books: books)
    }

    /// A text book titled `title` in the folder `folder`.
    private static func book(_ title: String, in folder: String) -> Book {
        ReadingListTests.book(title, in: folder)
    }

    /// A Library window's list showing `category` of `model`'s library, at
    /// the root, hosted offscreen in `test`; take it down with `takeDown`.
    @MainActor
    static func hostLibraryWindow(
        showing category: LibraryCategory,
        of model: LibraryViewModel,
        in test: XCTestCase
    ) -> (window: NSWindow, hostingView: NSView) {
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        return test.hostOffscreen(
            LibraryView(
                currentFolderPath: .constant(""),
                category: .constant(category),
                showFileImporter: .constant(false),
                showTextInput: .constant(false),
                onOpenBook: { _ in }
            )
            .environmentObject(model)
            .environmentObject(settings)
        )
    }
}
