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

    /// The View pop-up's fifth item reads "Reading List", under the
    /// pop-up's own label, "Library view" since October 30, 2026 (it was
    /// "Library category" while the picker was segmented); the window names
    /// the location the same way, alone, since its one order is its own.
    @MainActor
    func testTheReadingListIsTheFifthSegmentAndNamesItsWindow() {
        XCTAssertEqual(LibraryView.categoryPickerLabel, "Library view")
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

    // MARK: - Moving a Row with VoiceOver

    /// Move Up and Move Down have one name each, which a row's context menu
    /// and its VoiceOver actions both give them, and each moves one place:
    /// a book offers Move Up unless it is first, and Move Down unless it is
    /// last, Move Up first; a book alone in its order offers neither.
    func testTheMovesAreNamedOnceForTheMenuAndVoiceOver() {
        XCTAssertEqual(LibraryManualMove.up.title, "Move Up")
        XCTAssertEqual(LibraryManualMove.down.title, "Move Down")
        XCTAssertEqual(LibraryManualMove.up.direction, -1)
        XCTAssertEqual(LibraryManualMove.down.direction, 1)

        let almanac = Self.book("Almanac", in: "")
        let bestiary = Self.book("Bestiary", in: "")
        let chronicle = Self.book("Chronicle", in: "")
        let moves = LibraryManualMoves.moves(in: [almanac, bestiary, chronicle])
        XCTAssertEqual(moves[almanac.id]?.offered, [.down])
        XCTAssertEqual(moves[bestiary.id]?.offered, [.up, .down])
        XCTAssertEqual(moves[chronicle.id]?.offered, [.up])

        let alone = LibraryManualMoves.moves(in: [almanac])
        XCTAssertEqual(alone[almanac.id]?.offered, [])
        XCTAssertEqual(alone[almanac.id]?.canMove, false)
    }

    /// A row offers its moves as its first VoiceOver actions, before every
    /// other action, under the names its context menu gives them; a row
    /// whose list shows no order the user arranges offers none.
    @MainActor
    func testARowOffersItsMovesAsItsFirstVoiceOverActions() {
        let book = Self.book("Loose Pages", in: "")
        let removing = ReadingListCommand.commands(for: [book], isSelection: false, inList: [book.id])
        func names(_ moves: LibraryManualMoves?) -> [String] {
            BookRow(book: book, manualMoves: moves, readingListCommands: removing).accessibilityActionNames
        }

        XCTAssertEqual(
            names(LibraryManualMoves(canMoveUp: true, canMoveDown: true)),
            ["Move Up", "Move Down", "Remove from Reading List"]
        )
        XCTAssertEqual(names(LibraryManualMoves(canMoveUp: false, canMoveDown: true)), ["Move Down", "Remove from Reading List"])
        XCTAssertEqual(names(LibraryManualMoves(canMoveUp: true, canMoveDown: false)), ["Move Up", "Remove from Reading List"])
        XCTAssertEqual(names(LibraryManualMoves(canMoveUp: false, canMoveDown: false)), ["Remove from Reading List"])
        XCTAssertEqual(names(nil), ["Remove from Reading List"])
    }

    /// A row's VoiceOver action runs the move it names: Move Up asks the
    /// list to move the row's book one place up, and Move Down one place
    /// down, through the list's own actions.
    @MainActor
    func testARowsMoveActionMovesItsOwnBook() {
        let book = Self.book("Loose Pages", in: "")
        var asked: [Int] = []
        let row = BookRow(
            book: book,
            manualMoves: LibraryManualMoves(canMoveUp: true, canMoveDown: true),
            performManualMove: { asked.append($0.direction) }
        )
        for move in row.manualMoves?.offered ?? [] {
            row.performManualMove(move)
        }
        XCTAssertEqual(asked, [-1, 1])
    }

    /// A move from a row's VoiceOver action says the book's new place in
    /// the order, counted from 1 at the top, "Field Notes, 2 of 4", in the
    /// reading list, counted as the list shows it, and in a folder in
    /// manual order alike; the menu's words are unchanged.
    @MainActor
    func testAMoveFromAVoiceOverActionSaysTheBooksNewPlace() {
        let shelf = Self.shelf()
        shelf.model.addToReadingList(shelf.ids("Loose Pages", "Unlisted Essay", "Field Notes", "Travel Notes"))

        let up = shelf.model.moveBook(shelf.id("Field Notes"), direction: -1, in: .readingList)
        XCTAssertEqual(up?.placeAnnouncement, "Field Notes, 2 of 4")
        XCTAssertEqual(up?.announcement, "Moved Field Notes above Unlisted Essay")
        let down = shelf.model.moveBook(shelf.id("Loose Pages"), direction: 1, in: .readingList)
        XCTAssertEqual(down?.placeAnnouncement, "Loose Pages, 2 of 4")
        XCTAssertEqual(shelf.model.readingListBooks.map(\.title), ["Field Notes", "Loose Pages", "Unlisted Essay", "Travel Notes"])

        // In a folder in manual order: the folder's two books.
        let essays = LibraryLocation(category: .folders, folderPath: "Essays")
        shelf.model.userChangedSort(.choose(.manual), at: essays)
        let ordered = shelf.model.displayedBooks(at: essays).map(\.title)
        let last = ordered.last ?? ""
        XCTAssertEqual(shelf.model.moveBook(shelf.id(last), direction: -1, in: .folder("Essays"))?.placeAnnouncement, "\(last), 1 of 2")
    }

    /// The place a move says counts only the books the Reading List shows:
    /// an ID naming no book, which the next change drops, is not counted.
    @MainActor
    func testTheSaidPlaceCountsOnlyTheBooksShown() {
        let shelf = Self.shelf()
        let gone = UUID()
        shelf.model.library.readingList = ReadingList(bookIDs: [shelf.id("Loose Pages"), gone, shelf.id("Field Notes")])

        let moved = shelf.model.moveBook(shelf.id("Field Notes"), direction: -1, in: .readingList)

        XCTAssertEqual(moved?.placeAnnouncement, "Field Notes, 1 of 2")
    }

    /// A move a row's VoiceOver action can no longer make, as when the
    /// list changed after the row offered it, says so.
    func testAMoveThatCanNoLongerBeMadeSaysSo() {
        XCTAssertEqual(ManualBookOrder.cannotMoveAnnouncement("Dune", direction: -1), "Dune can't move up.")
        XCTAssertEqual(ManualBookOrder.cannotMoveAnnouncement("Dune", direction: 1), "Dune can't move down.")
    }

    /// Move Book Up and Move Book Down from the Library menu and the
    /// keyboard never stay silent: with no book or several selected, a
    /// feed's item, or the book at the edge, the sentence says why, and a
    /// move that is made says what moved (the follow-up noted with TODO A06:
    /// "do nothing silently"). What it tells a listener to do where nothing
    /// can move is the next test's.
    @MainActor
    func testMoveCommandsAlwaysSayWhatHappened() {
        let shelf = Self.shelf()
        shelf.model.addToReadingList(shelf.ids("Field Notes", "Loose Pages"))
        let fieldNotes = shelf.id("Field Notes")
        let loosePages = shelf.id("Loose Pages")
        let readingList = LibraryLocation(category: .readingList, folderPath: "")
        let sort = shelf.model.library.sortState(at: readingList)

        // Nothing selected, and several selected.
        XCTAssertEqual(
            shelf.model.moveSelection([], direction: 1, at: readingList, sortedBy: sort),
            ManualBookOrder.noBookToMoveAnnouncement
        )
        XCTAssertEqual(
            shelf.model.moveSelection([fieldNotes, loosePages], direction: 1, at: readingList, sortedBy: sort),
            ManualBookOrder.severalBooksToMoveAnnouncement
        )
        // At the top, the book cannot move up, and the order is unchanged.
        XCTAssertEqual(
            shelf.model.moveSelection([fieldNotes], direction: -1, at: readingList, sortedBy: sort),
            "Field Notes can't move up."
        )
        XCTAssertEqual(shelf.model.library.readingList.bookIDs, [fieldNotes, loosePages])
        // A move that can be made says what moved, and does it.
        XCTAssertEqual(
            shelf.model.moveSelection([loosePages], direction: -1, at: readingList, sortedBy: sort),
            "Moved Loose Pages above Field Notes"
        )
        XCTAssertEqual(shelf.model.library.readingList.bookIDs, [loosePages, fieldNotes])
    }

    /// Where the list shows no order to arrange, the sentence sends the
    /// listener somewhere they can go. A folder in Folders not sorted by
    /// Manual Order is one Sort menu choice from it. Every other view
    /// (All Items, Unopened, Recently Opened, Feeds) mixes folders, has no
    /// Manual Order to choose, and keeps its sort whatever is chosen, so it
    /// sends the listener to a folder or the Reading List and never to the
    /// Sort menu. A folder in manual order, and the Reading List, move.
    @MainActor
    func testMoveCommandsSendTheListenerSomewhereTheyCanMoveBooks() throws {
        let shelf = Self.shelf()
        let book = shelf.id("Field Notes")
        let byTitle = LibrarySortState(restoring: .defaultSort)
        let manual = LibrarySortState(restoring: FolderSortSetting(sortField: .manual, sortAscending: true))
        let feeds = try XCTUnwrap(LibraryViewDefinition.shipped(.feeds))
        func say(_ location: LibraryLocation, _ sort: LibrarySortState) -> String {
            shelf.model.moveSelection([book], direction: 1, at: location, sortedBy: sort)
        }

        // A folder not in manual order: choose Manual Order.
        let essays = LibraryLocation(category: .folders, folderPath: "Essays")
        let chooseManual = say(essays, byTitle)
        XCTAssertTrue(chooseManual.contains("Choose Manual Order in the Sort menu"), chooseManual)
        // The root of Folders is a folder too.
        XCTAssertEqual(say(LibraryLocation(category: .folders, folderPath: ""), byTitle), chooseManual)

        // Every other view, in either sort: go to a folder or the Reading List.
        let elsewhere = "Books can't be moved in this view. Go to a folder in Folders, or to the Reading List, then try again."
        let views = [
            LibraryLocation(category: .allItems, folderPath: "Essays"),
            LibraryLocation(category: .unopened, folderPath: "Essays"),
            LibraryLocation(category: .recent, folderPath: "Essays"),
            LibraryLocation(view: feeds, folderPath: "Essays"),
        ]
        for location in views {
            for sort in [byTitle, manual] {
                XCTAssertEqual(say(location, sort), elsewhere, "\(location.name), \(sort.field)")
            }
        }
        XCTAssertFalse(elsewhere.contains("Sort menu"))
        XCTAssertFalse(elsewhere.contains("Manual"))

        // A folder in manual order moves its books; the book is first, so
        // it moves down past the other, and cannot then move down further.
        let before = shelf.model.library.booksInFolder("Essays").map(\.title).sorted()
        XCTAssertEqual(before, ["Field Notes", "Unlisted Essay"])
        XCTAssertEqual(say(essays, manual), "Moved Field Notes below Unlisted Essay")
        XCTAssertEqual(say(essays, manual), "Field Notes can't move down.")
    }

    /// A feed's item has no place in a folder's manual order, so the command
    /// says that instead of "can't move up" and "can't move down". In the
    /// Reading List, which holds episodes and articles and orders them, it
    /// moves like any book, as a row's own Move Up and Move Down move it.
    @MainActor
    func testMoveCommandsSayAFeedItemCannotMove() {
        let shelf = Self.shelf()
        var episode = Self.book("Episode Nine", in: "Essays")
        episode.feedLink = FeedBookLink(feedID: UUID(), itemID: "guid:nine")
        shelf.model.library.books.append(episode)
        let essays = LibraryLocation(category: .folders, folderPath: "Essays")
        let manual = LibrarySortState(restoring: FolderSortSetting(sortField: .manual, sortAscending: true))

        XCTAssertEqual(
            shelf.model.moveSelection([episode.id], direction: -1, at: essays, sortedBy: manual),
            ManualBookOrder.feedItemCannotMoveAnnouncement("Episode Nine")
        )
        XCTAssertEqual(
            ManualBookOrder.feedItemCannotMoveAnnouncement("Episode Nine"),
            "Episode Nine is an item of a feed, and a feed's items can't be moved."
        )

        // In the Reading List the same episode moves, for real, up and down.
        shelf.model.addToReadingList(shelf.ids("Field Notes", "Loose Pages") + [episode.id])
        let readingList = LibraryLocation(category: .readingList, folderPath: "")
        let listSort = shelf.model.library.sortState(at: readingList)
        let fieldNotes = shelf.id("Field Notes")
        let loosePages = shelf.id("Loose Pages")
        XCTAssertEqual(shelf.model.library.readingList.bookIDs, [fieldNotes, loosePages, episode.id])

        XCTAssertEqual(
            shelf.model.moveSelection([episode.id], direction: -1, at: readingList, sortedBy: listSort),
            "Moved Episode Nine above Loose Pages"
        )
        XCTAssertEqual(shelf.model.library.readingList.bookIDs, [fieldNotes, episode.id, loosePages])
        XCTAssertEqual(
            shelf.model.moveSelection([episode.id], direction: 1, at: readingList, sortedBy: listSort),
            "Moved Episode Nine below Loose Pages"
        )
        XCTAssertEqual(shelf.model.library.readingList.bookIDs, [fieldNotes, loosePages, episode.id])
    }

    // MARK: - The Edit-Mode Bar

    /// The edit-mode bar offers the reading list's commands for the
    /// selection beside Move, by membership as a selection's row does: Add
    /// for the books not in the list, Remove for those in it, each with its
    /// own books. With nothing selected it offers the one the view suggests,
    /// with no books, which it shows dimmed: Remove at the Reading List and
    /// Add elsewhere.
    @MainActor
    func testTheEditBarOffersTheListsCommandsForTheSelection() {
        let shelf = Self.shelf()
        let inList = Set(shelf.ids("Field Notes"))
        func commands(_ titles: String..., atReadingList: Bool = false) -> [ReadingListCommand] {
            let selection = titles.compactMap { title in shelf.books.first { $0.title == title } }
            return ReadingListCommand.editBarCommands(for: selection, inList: inList, atReadingList: atReadingList)
        }

        let none = commands()
        XCTAssertEqual(none.map(\.kind), [.add])
        XCTAssertEqual(none.map(\.books), [[]])
        let noneAtTheList = commands(atReadingList: true)
        XCTAssertEqual(noneAtTheList.map(\.kind), [.remove])
        XCTAssertEqual(noneAtTheList.map(\.books), [[]])

        XCTAssertEqual(commands("Loose Pages").map(\.kind), [.add])
        XCTAssertEqual(commands("Field Notes", atReadingList: true).map(\.kind), [.remove])
        let mixed = commands("Loose Pages", "Field Notes", "Travel Notes")
        XCTAssertEqual(mixed.map(\.kind), [.add, .remove])
        XCTAssertEqual(mixed.first?.books.map(\.title), ["Loose Pages", "Travel Notes"])
        XCTAssertEqual(mixed.last?.books.map(\.title), ["Field Notes"])
    }

    /// The bar's buttons are titled with the commands' plain names, as the
    /// Library menu names them, and VoiceOver hears how many books each
    /// acts on, as the bar's Move button counts them, with a hint saying
    /// what it does; a dimmed button is called by its plain name.
    func testTheEditBarsCommandsAreWordedAndCounted() {
        XCTAssertEqual(ReadingListWording.editBarTitle(.add), "Add to Reading List")
        XCTAssertEqual(ReadingListWording.editBarTitle(.remove), "Remove from Reading List")
        XCTAssertEqual(ReadingListWording.editBarLabel(.add, count: 3), "Add 3 books to the reading list")
        XCTAssertEqual(ReadingListWording.editBarLabel(.add, count: 1), "Add 1 book to the reading list")
        XCTAssertEqual(ReadingListWording.editBarLabel(.remove, count: 2), "Remove 2 books from the reading list")
        XCTAssertEqual(ReadingListWording.editBarLabel(.add, count: 0), "Add to Reading List")
        XCTAssertEqual(ReadingListWording.editBarLabel(.remove, count: 0), "Remove from Reading List")
        XCTAssertEqual(ReadingListWording.editBarHint(.add), "Adds the selected books to the end of the reading list.")
        XCTAssertEqual(
            ReadingListWording.editBarHint(.remove),
            "Takes the selected books off the reading list. They stay in the library."
        )
    }

    /// The bar's commands act on their own books and say what they did as
    /// the context menu's do, through the same model commands.
    @MainActor
    func testTheEditBarsCommandsSayWhatTheyDidAsTheMenusDo() {
        let shelf = Self.shelf()
        shelf.model.addToReadingList(shelf.ids("Field Notes"))
        let selection = shelf.books(titled: "Loose Pages", "Field Notes", "Travel Notes")
        let commands = ReadingListCommand.editBarCommands(
            for: selection,
            inList: Set(shelf.model.readingList.bookIDs),
            atReadingList: false
        )

        let recorder = recordingAnnouncements {
            for command in commands {
                switch command.kind {
                case .add: shelf.model.addToReadingList(command.books, announcingFrom: nil)
                case .remove: shelf.model.removeFromReadingList(command.books, announcingFrom: nil)
                }
            }
        }

        XCTAssertEqual(recorder.announcements.map(\.message), [
            "Added 2 books to the reading list.",
            "Removed from reading list: Field Notes",
        ])
        XCTAssertEqual(shelf.model.readingListBooks.map(\.title), ["Loose Pages", "Travel Notes"])
    }

    /// Hosted, the bar's reading list buttons reach accessibility under
    /// their counted labels, the dimmed one by its plain name; skipped
    /// where SwiftUI exposes no buttons to accessibility, as on this Mac,
    /// where the wording tests above pin the labels.
    @MainActor
    func testTheEditBarsReadingListButtonsReachAccessibility() throws {
        try skipUnlessSwiftUIExposesItsOwnElements()
        let shelf = Self.shelf()
        let bar = EditModeBar(
            selectedCount: 3,
            totalCount: 4,
            removalPreferences: RemovalPreferences(confirmsFirst: true, movesToTrash: true),
            onSelectAll: {},
            onDeselectAll: {},
            onMove: {},
            onRemove: {},
            readingListCommands: ReadingListCommand.editBarCommands(
                for: shelf.books(titled: "Loose Pages", "Field Notes", "Travel Notes"),
                inList: Set(shelf.ids("Field Notes")),
                atReadingList: false
            )
        )
        try withHostedControls(bar) { controls in
            let labels = controls.filter { $0.role == .button }.map(\.label)
            guard !labels.isEmpty else {
                throw XCTSkip("SwiftUI exposed no AppKit button to accessibility in this run")
            }
            XCTAssertTrue(labels.contains("Add 2 books to the reading list"), "\(labels)")
            XCTAssertTrue(labels.contains("Remove 1 book from the reading list"), "\(labels)")
        }
    }

    // MARK: - The Rows Say "In reading list"

    /// A book's row says "In reading list" in its label, right after its
    /// title and author and before every other part, and a row for a book
    /// not in the list says nothing more. The row carries no value.
    @MainActor
    func testARowSaysInReadingListRightAfterItsTitleAndAuthor() {
        let book = Self.book("Loose Pages", in: "")
        // The same book, opened and partly read, for the rows that speak
        // a progress.
        var read = book
        read.lastOpened = Date()
        read.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: 0, globalCharacterOffset: 420)
        read.totalCharacterCount = 1_000

        XCTAssertEqual(ReadingListWording.inReadingListNote, "In reading list")

        // Listed and unlisted: the note is the only difference.
        XCTAssertEqual(
            BookRow(book: book, isInReadingList: true).rowAccessibilityLabel,
            "Loose Pages, by Ines Okonkwo-Varga, In reading list, New, Plain Text"
        )
        XCTAssertEqual(
            BookRow(book: book).rowAccessibilityLabel,
            "Loose Pages, by Ines Okonkwo-Varga, New, Plain Text"
        )

        // "Selected" still begins a selected row in edit mode.
        XCTAssertEqual(
            BookRow(book: book, isEditMode: true, isEditSelected: true, isInReadingList: true)
                .rowAccessibilityLabel,
            "Selected, Loose Pages, by Ines Okonkwo-Varga, In reading list, New, Plain Text"
        )

        // The note comes before the cloud note and the progress.
        XCTAssertEqual(
            BookRow(book: read, cloudState: .downloaded, isInReadingList: true).rowAccessibilityLabel,
            "Loose Pages, by Ines Okonkwo-Varga, In reading list, Downloaded, 42 percent, Plain Text"
        )

        // And before "Now Reading" for a book open in a reader.
        XCTAssertEqual(
            BookRow(book: read, isOpenInWindow: true, isInReadingList: true).rowAccessibilityLabel,
            "Loose Pages, by Ines Okonkwo-Varga, In reading list, Now Reading, 42 percent, Plain Text"
        )
    }

    /// Hosted, the row is one element whose label is the row's, saying "In
    /// reading list", and which carries no value, as VoiceOver reads it;
    /// skipped where SwiftUI exposes no elements without an assistive app.
    @MainActor
    func testAHostedRowSaysItInItsLabel() throws {
        let row = BookRow(book: Self.book("Loose Pages", in: ""), isInReadingList: true)
        let label = row.rowAccessibilityLabel
        XCTAssertTrue(label.contains("In reading list"), label)
        // The label above is checked without a window; what follows reads
        // SwiftUI's own elements in-process.
        try skipUnlessSwiftUIExposesItsOwnElements()

        try withHostedView(row, until: { !self.accessibilityElements(labelled: label, in: $0).isEmpty }) { hostingView in
            let found = accessibilityElements(labelled: label, in: hostingView)
            guard let element = found.first else {
                throw XCTSkip("SwiftUI exposed no accessibility elements without an assistive app")
            }
            XCTAssertEqual(found.count, 1, "the row is one element")
            let value = element.accessibilityValue() as? String
            XCTAssertTrue(value == nil || value?.isEmpty == true, "the row carries no value: \(String(describing: value))")
        }
    }

    // MARK: - The Commands

    /// A row's own book is offered exactly one command, by membership,
    /// under the name the Library menu gives it; a selection is offered one
    /// for its books outside the list and one for those in it, each acting
    /// on its own books and counting them in its title.
    @MainActor
    func testTheCommandsAreOfferedByMembership() {
        let shelf = Self.shelf()
        let inList = Set(shelf.ids("Field Notes"))
        func titles(_ books: [Book], selection: Bool, in list: Set<UUID>) -> [String] {
            ReadingListCommand.commands(for: books, isSelection: selection, inList: list).map(\.title)
        }

        XCTAssertEqual(titles(shelf.books(titled: "Loose Pages"), selection: false, in: inList), ["Add to Reading List"])
        XCTAssertEqual(titles(shelf.books(titled: "Field Notes"), selection: false, in: inList), ["Remove from Reading List"])

        let selection = shelf.books(titled: "Loose Pages", "Field Notes", "Travel Notes")
        let commands = ReadingListCommand.commands(for: selection, isSelection: true, inList: inList)
        XCTAssertEqual(commands.map(\.title), ["Add 2 Books to Reading List", "Remove 1 Book from Reading List"])
        XCTAssertEqual(commands.map(\.kind), [.add, .remove])
        XCTAssertEqual(commands.first?.books.map(\.title), ["Loose Pages", "Travel Notes"])
        XCTAssertEqual(commands.last?.books.map(\.title), ["Field Notes"])

        let everyBook = Set(shelf.ids("Loose Pages", "Field Notes", "Travel Notes"))
        XCTAssertEqual(titles(selection, selection: true, in: everyBook), ["Remove 3 Books from Reading List"])
        XCTAssertEqual(titles(selection, selection: true, in: []), ["Add 3 Books to Reading List"])
        XCTAssertEqual(titles([], selection: false, in: inList), [])
    }

    /// The Library menu's commands are named as a row names them for one
    /// book, and listed in Settings under Library, with no keys until the
    /// user gives them some.
    @MainActor
    func testTheLibraryMenusCommandsHaveNoKeysUntilGivenSome() {
        XCTAssertEqual(ShortcutAction.addToReadingList.title, "Add to Reading List")
        XCTAssertEqual(ShortcutAction.removeFromReadingList.title, "Remove from Reading List")
        for action in [ShortcutAction.addToReadingList, .removeFromReadingList] {
            XCTAssertEqual(action.category, "Library", action.rawValue)
            XCTAssertEqual(action.defaultScope, .app, action.rawValue)
            XCTAssertEqual(ShortcutAction.defaultBindings[action], [], action.rawValue)
        }
        XCTAssertEqual(ShortcutAction.addToReadingList.notificationName, .addToReadingList)
        XCTAssertEqual(ShortcutAction.removeFromReadingList.notificationName, .removeFromReadingList)
        XCTAssertEqual(Notification.Name.addToReadingList.rawValue, "addToReadingList")
        XCTAssertEqual(Notification.Name.removeFromReadingList.rawValue, "removeFromReadingList")
    }

    /// Add to Reading List says what it did: the book added, or how many,
    /// and how many were in the list already; or why it added none: every
    /// book chosen is in the list already, or none is chosen.
    @MainActor
    func testAddingSaysWhatItDid() {
        let shelf = Self.shelf()
        let recorder = recordingAnnouncements {
            shelf.model.addToReadingList(shelf.books(titled: "Loose Pages"), announcingFrom: nil)
            shelf.model.addToReadingList(shelf.books(titled: "Field Notes", "Travel Notes"), announcingFrom: nil)
            shelf.model.addToReadingList(shelf.books(titled: "Loose Pages", "Unlisted Essay", "Field Notes"), announcingFrom: nil)
            shelf.model.addToReadingList(shelf.books(titled: "Loose Pages"), announcingFrom: nil)
            shelf.model.addToReadingList(shelf.books(titled: "Loose Pages", "Field Notes"), announcingFrom: nil)
            shelf.model.addToReadingList([], announcingFrom: nil)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), [
            "Added to reading list: Loose Pages",
            "Added 2 books to the reading list.",
            "Added to reading list: Unlisted Essay. 2 books were already in it.",
            "Loose Pages is already in the reading list.",
            "The 2 selected books are already in the reading list.",
            "No books are selected.",
        ])
        XCTAssertEqual(shelf.model.readingListBooks.map(\.title), ["Loose Pages", "Field Notes", "Travel Notes", "Unlisted Essay"])
    }

    /// Remove from Reading List says what it did: the book taken off, or
    /// how many, and how many were not in the list; or why it took none
    /// off. The books stay in the library.
    @MainActor
    func testRemovingSaysWhatItDid() {
        let shelf = Self.shelf()
        shelf.model.addToReadingList(shelf.ids("Loose Pages", "Field Notes", "Travel Notes", "Unlisted Essay"))
        let recorder = recordingAnnouncements {
            shelf.model.removeFromReadingList(shelf.books(titled: "Field Notes"), announcingFrom: nil)
            shelf.model.removeFromReadingList(shelf.books(titled: "Travel Notes", "Unlisted Essay"), announcingFrom: nil)
            shelf.model.removeFromReadingList(shelf.books(titled: "Loose Pages", "Field Notes", "Travel Notes"), announcingFrom: nil)
            shelf.model.removeFromReadingList(shelf.books(titled: "Loose Pages"), announcingFrom: nil)
            shelf.model.removeFromReadingList(shelf.books(titled: "Loose Pages", "Field Notes"), announcingFrom: nil)
            shelf.model.removeFromReadingList([], announcingFrom: nil)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), [
            "Removed from reading list: Field Notes",
            "Removed 2 books from the reading list.",
            "Removed from reading list: Loose Pages. 2 books were not in it.",
            "Loose Pages isn't in the reading list.",
            "None of the 2 selected books is in the reading list.",
            "No books are selected.",
        ])
        XCTAssertEqual(shelf.model.readingListBooks, [])
        XCTAssertEqual(shelf.model.library.books.count, 4)
    }

    /// An import made at the Reading List says that its books joined the
    /// list, as Add to Reading List does, and, since the list is no folder,
    /// where the books themselves went, naming the folder as the folder
    /// pickers do: its path, or "Library Root" for the top of the library.
    func testAnImportAtTheReadingListSaysWhereItsBooksWent() {
        XCTAssertEqual(LibraryFolderOption.rootLabel, "Library Root")
        XCTAssertEqual(
            ReadingListWording.importedAnnouncement(added: ["Moby-Dick"], folderPath: "Essays/Sea"),
            "Added to reading list: Moby-Dick. The book is in Essays/Sea."
        )
        XCTAssertEqual(
            ReadingListWording.importedAnnouncement(added: ["Almanac", "Bestiary", "Chronicle"], folderPath: ""),
            "Added 3 books to the reading list. The books are in Library Root."
        )
        XCTAssertFalse(ImportRequest().addsToReadingList, "an import joins the list only when asked")
    }

    /// A row offers its reading list command as a VoiceOver action, after
    /// its other actions, under the name its context menu gives it.
    @MainActor
    func testARowOffersItsCommandAsAVoiceOverAction() {
        let book = Self.book("Loose Pages", in: "")
        let adding = BookRow(book: book, readingListCommands: ReadingListCommand.commands(for: [book], isSelection: false, inList: []))
        let removing = BookRow(book: book, readingListCommands: ReadingListCommand.commands(for: [book], isSelection: false, inList: [book.id]))

        XCTAssertEqual(adding.accessibilityActionNames, ["Add to Reading List"])
        XCTAssertEqual(removing.accessibilityActionNames, ["Remove from Reading List"])
    }

    /// An empty Reading List says so, and how a book joins it, naming the
    /// command as the menus do.
    func testAnEmptyReadingListSaysHowABookJoinsIt() {
        XCTAssertEqual(
            ReadingListWording.emptyList,
            "The reading list is empty. To add a book, choose Add to Reading List from its context menu, "
                + "its VoiceOver actions, or the Library menu."
        )
    }

    // MARK: - The Options Bar

    /// The options bar's words: the picker's label and hint, and each
    /// checkbox's label and hint, which each control speaks for itself.
    func testTheOptionsBarsWordsArePinned() {
        XCTAssertEqual(ReadingListWording.continuationLabel, "When a book ends")
        XCTAssertEqual(
            ReadingListWording.continuationHint,
            "For a book opened from the reading list: play the book below it or the book above it when it ends, or stop"
        )
        XCTAssertEqual(ReadingListWording.skipFinishedLabel, "Skip finished books")
        XCTAssertEqual(
            ReadingListWording.skipFinishedHint,
            "When a book opened from the reading list ends, pass over the books already finished"
        )
        XCTAssertEqual(ReadingListWording.removeFinishedLabel, "Remove books when finished")
        XCTAssertEqual(
            ReadingListWording.removeFinishedHint,
            "Takes a finished book off the reading list once its reader window moves on or closes. "
                + "Books finished before you turn this on stay on it."
        )
        XCTAssertEqual(ReadingListWording.keepBooksLabel, "Keep these books on this Mac")
        XCTAssertEqual(
            ReadingListWording.keepBooksHint,
            "Keeps the books on the reading list downloaded on this Mac, as Keep on This Mac does. "
                + "This choice is this Mac's alone. Clearing it removes no download."
        )
        // Four controls, each told apart by its own label.
        XCTAssertEqual(
            Set([
                ReadingListWording.continuationLabel, ReadingListWording.skipFinishedLabel,
                ReadingListWording.removeFinishedLabel, ReadingListWording.keepBooksLabel,
            ]).count,
            4
        )
    }

    /// The bar's row wraps rather than truncates: when the controls do not
    /// fit the width, the one that does not starts a second line, in the
    /// order they were declared, which is the order VoiceOver visits them;
    /// wide enough, they stay on one line; and a control wider than the
    /// window keeps its place, alone on its line, however narrow it gets.
    func testTheOptionsBarWrapsOntoASecondLineInsteadOfTruncating() {
        // The pop-up, then the three checkboxes of a cloud library.
        let sizes = [CGSize(width: 140, height: 24), CGSize(width: 160, height: 20),
                     CGSize(width: 190, height: 20), CGSize(width: 230, height: 20)]
        func arrange(_ width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
            WrappingRow.arrange(sizes, width: width, spacing: 16, lineSpacing: 4)
        }

        let wide = arrange(2_000)
        XCTAssertEqual(wide.origins, [CGPoint(x: 0, y: 0), CGPoint(x: 156, y: 0), CGPoint(x: 332, y: 0), CGPoint(x: 538, y: 0)])
        XCTAssertEqual(wide.size, CGSize(width: 768, height: 24))

        // At the window's minimum width the last control starts a second line.
        let minimum = arrange(600)
        XCTAssertEqual(minimum.origins, [CGPoint(x: 0, y: 0), CGPoint(x: 156, y: 0), CGPoint(x: 332, y: 0), CGPoint(x: 0, y: 28)])
        XCTAssertEqual(minimum.size, CGSize(width: 522, height: 48))

        // Narrower than any control, each has a line of its own, in order.
        let narrow = arrange(100)
        XCTAssertEqual(narrow.origins.map(\.x), [0, 0, 0, 0])
        XCTAssertEqual(narrow.origins.map(\.y), [0, 28, 52, 76])
        XCTAssertEqual(WrappingRow.arrange([], width: 100, spacing: 16, lineSpacing: 4).size, .zero)
    }

    /// Hosted, the choice to keep the list's books on this Mac is a third
    /// checkbox, shown only while the library is in the cloud, and checked as
    /// the choice stands; outside the cloud the bar holds the two checkboxes
    /// it always held. Read from the AppKit buttons, in layout order, as
    /// `testTheOptionsBarsControlsSpeakTheirLabelsValuesAndHints` reads
    /// them.
    @MainActor
    func testTheKeepChoiceIsShownOnlyInACloudLibrary() throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        for (inCloud, keeps) in [(false, true), (true, true), (true, false)] {
            let bar = ReadingListOptionsBar(
                continuation: .playBookBelow,
                skipsFinished: true,
                removesFinished: false,
                keepsBooks: keeps,
                showsKeepChoice: inCloud,
                chooseContinuation: { _ in },
                chooseSkipsFinished: { _ in },
                chooseRemovesFinished: { _ in },
                chooseKeepsBooks: { _ in }
            )
            withHostedView(bar, until: { Self.picker(in: self.accessibleControls(in: $0)) != nil }) { hostingView in
                let checkboxes = Self.checkboxes(in: hostingView, test: self)
                XCTAssertEqual(checkboxes.count, inCloud ? 3 : 2, "in the cloud: \(inCloud)")
                if inCloud {
                    XCTAssertEqual(checkboxes.last?.state, keeps ? .on : .off)
                }
            }
        }
    }

    /// Hosted, the picker is a pop-up button VoiceOver reads by its label,
    /// "When a book ends", with the option chosen as its value and its
    /// hint, for each option; and each checkbox is checked while its option
    /// is on. SwiftUI exposes the pop-up button to accessibility in a hosted
    /// window, but not the checkboxes, whose states are read here from the
    /// AppKit buttons behind them, in the order the bar lays them out
    /// (Skip finished books, then Remove books when finished); their labels
    /// and hints are pinned by `testTheOptionsBarsWordsArePinned`.
    @MainActor
    func testTheOptionsBarsControlsSpeakTheirLabelsValuesAndHints() throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        let choices: [(ReadingList.Continuation, Bool, Bool)] = [
            (.playBookBelow, true, false), (.playBookAbove, false, true), (.stop, true, true), (.stop, false, false),
        ]
        for (continuation, skipsFinished, removesFinished) in choices {
            let bar = ReadingListOptionsBar(
                continuation: continuation,
                skipsFinished: skipsFinished,
                removesFinished: removesFinished,
                keepsBooks: true,
                showsKeepChoice: false,
                chooseContinuation: { _ in },
                chooseSkipsFinished: { _ in },
                chooseRemovesFinished: { _ in },
                chooseKeepsBooks: { _ in }
            )
            try withHostedView(bar, until: { Self.picker(in: self.accessibleControls(in: $0)) != nil }) { hostingView in
                let picker = try XCTUnwrap(Self.picker(in: accessibleControls(in: hostingView)), "\(continuation)")
                XCTAssertEqual(picker.label, "When a book ends")
                XCTAssertEqual(picker.element.accessibilityValue() as? String, continuation.title)
                XCTAssertEqual(picker.hint, ReadingListWording.continuationHint)

                let checkboxes = Self.checkboxes(in: hostingView, test: self)
                XCTAssertEqual(checkboxes.count, 2, "\(continuation)")
                XCTAssertEqual(checkboxes.first?.state, skipsFinished ? .on : .off, "skip finished, \(continuation)")
                XCTAssertEqual(checkboxes.last?.state, removesFinished ? .on : .off, "remove finished, \(continuation)")
            }
        }
    }

    /// Hosted, a Library window shows the options bar at the Reading List,
    /// with the list's own options, and nowhere else.
    @MainActor
    func testTheWindowShowsTheOptionsBarAtTheReadingListAlone() {
        let shelf = Self.shelf()
        shelf.model.setReadingListContinuation(.playBookAbove)

        for category in [LibraryCategory.readingList, .folders] {
            let hosted = Self.hostLibraryWindow(showing: category, of: shelf.model, in: self)
            defer { takeDown(hosted.window) }
            let shown = waitUntil(timeout: 2) {
                hosted.hostingView.layoutSubtreeIfNeeded()
                return self.descendants(of: hosted.hostingView, as: NSPopUpButton.self)
                    .contains { $0.titleOfSelectedItem == "Play the book above" }
            }
            XCTAssertEqual(shown, category == .readingList, "\(category)")
        }
    }

    /// The pop-up button VoiceOver reads as "When a book ends" among
    /// `controls`, if any.
    private static func picker(in controls: [AccessibleControl]) -> AccessibleControl? {
        controls.first { $0.role == .popUpButton && $0.label == ReadingListWording.continuationLabel }
    }

    /// The AppKit buttons behind the options bar's checkboxes in `view`,
    /// whose states are the checkboxes', in the order the bar lays them out:
    /// the bar's buttons that are not the pop-up button.
    @MainActor
    private static func checkboxes(in view: NSView, test: XCTestCase) -> [NSButton] {
        test.descendants(of: view, as: NSButton.self).filter { !($0 is NSPopUpButton) }
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
