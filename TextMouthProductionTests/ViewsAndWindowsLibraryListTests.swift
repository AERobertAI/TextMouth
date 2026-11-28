import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Each change to the library draws every Library window's list again, so
/// the list must cost little to draw again (PERF28): it reads its books
/// once per draw, its rows are equatable, so a change to one book redraws
/// one row and builds one context menu, and Move Up and Move Down follow
/// the order the list shows instead of sorting the folder for every row.
@MainActor
final class ViewsAndWindowsLibraryListTests: XCTestCase {

    // MARK: - Move Up and Move Down

    /// Move Up and Move Down, read from the list's own manual order, are
    /// offered exactly where moving the book is possible, in random folders
    /// with positions that repeat, are missing, or tie on the title, and at
    /// the root of Folders, whose manual order is the root's.
    func testMovesFollowTheManualOrderTheListShows() {
        var generator = SeededGenerator(state: 0x5EED_2028)
        for round in 0..<40 {
            let model = LibraryViewModel(initializeServices: false)
            model.library = Self.randomLibrary(using: &generator)
            for location in [
                LibraryLocation(category: .folders, folderPath: "Shelf"),
                LibraryLocation(category: .folders, folderPath: ""),
            ] {
                model.library.folderSortSettings[location.sortSettingsKey] = FolderSortSetting(sortField: .manual, sortAscending: true)
                let shown = model.displayedBooks(at: location)
                let folder = location.manualOrderFolder ?? ""
                let moves = LibraryManualMoves.moves(in: shown)
                XCTAssertEqual(Set(moves.keys), Set(shown.map(\.id)), "round \(round)")
                for book in shown {
                    let expected = LibraryManualMoves(
                        canMoveUp: ManualBookOrder.canMove(in: model.library, bookID: book.id, direction: -1, folderPath: folder),
                        canMoveDown: ManualBookOrder.canMove(in: model.library, bookID: book.id, direction: 1, folderPath: folder)
                    )
                    XCTAssertEqual(moves[book.id], expected, "round \(round), \(location.category), \(book.title)")
                }
            }
        }
    }

    /// The first book cannot move up, the last cannot move down, and a
    /// folder of one book offers neither move.
    func testEndsOfTheOrderOfferOneMoveOrNone() {
        let books = (0..<3).map { Book(title: "Book \($0)", format: .txt, filePath: "/nonexistent/\($0).txt", md5Hash: "\($0)") }
        let moves = LibraryManualMoves.moves(in: books)
        XCTAssertEqual(moves[books[0].id], LibraryManualMoves(canMoveUp: false, canMoveDown: true))
        XCTAssertEqual(moves[books[1].id], LibraryManualMoves(canMoveUp: true, canMoveDown: true))
        XCTAssertEqual(moves[books[2].id], LibraryManualMoves(canMoveUp: true, canMoveDown: false))

        let alone = LibraryManualMoves.moves(in: [books[0]])
        XCTAssertEqual(alone[books[0].id], LibraryManualMoves(canMoveUp: false, canMoveDown: false))
        XCTAssertEqual(alone[books[0].id]?.canMove, false)
    }

    // MARK: - Equatable Rows

    /// Two rows are equal when they show the same thing, whatever their
    /// actions, and differ when anything they show differs.
    func testRowsCompareWhatTheyShowAndNotTheirActions() {
        let book = Book(title: "Compared", format: .txt, filePath: "/nonexistent/compared.txt", md5Hash: "compared")
        let other = Book(title: "Other", format: .txt, filePath: "/nonexistent/other.txt", md5Hash: "other")
        let live = LiveReadingPosition.inert
        let row = Self.row(book, livePosition: live)

        XCTAssertEqual(row, Self.row(book, livePosition: live, actions: Self.otherActions))
        var renamed = book
        renamed.title = "Renamed"
        let differing: [(String, LibraryBookListRow)] = [
            ("book", Self.row(renamed, livePosition: live)),
            // The Leading articles setting shows the title inverted.
            ("shown title", Self.row(book, shownTitle: "Compared, The", livePosition: live)),
            ("open in a window", Self.row(book, isOpenInWindow: true, livePosition: live)),
            ("speed", Self.row(book, wpm: 250, livePosition: live)),
            ("edit mode", Self.row(book, isEditMode: true, livePosition: live)),
            ("selected", Self.row(book, isEditSelected: true, livePosition: live)),
            ("cloud state", Self.row(book, cloudState: .inCloud, livePosition: live)),
            ("kept on this Mac", Self.row(book, isKeptOnThisMac: true, livePosition: live)),
            ("targets", Self.row(book, targets: [book, other], livePosition: live)),
            ("moves", Self.row(book, manualMoves: LibraryManualMoves(canMoveUp: true, canMoveDown: false), livePosition: live)),
            ("removal", Self.row(book, removal: RemovalPreferences(confirmsFirst: false, movesToTrash: false), livePosition: live)),
            ("live position", Self.row(book, livePosition: LiveReadingPosition())),
            ("in reading list", Self.row(book, livePosition: live, isInReadingList: true)),
            ("reading list commands", Self.row(
                book,
                livePosition: live,
                readingListCommands: ReadingListCommand.commands(for: [book], isSelection: false, inList: [])
            )),
        ]
        for (difference, changed) in differing {
            XCTAssertNotEqual(row, changed, difference)
        }
    }

    // MARK: - Drawing Again

    /// A change to one book in a 134-book folder in manual order draws the
    /// list once, redraws the changed book's row alone, and leaves every
    /// other row as it was; a publish that changes nothing redraws no row.
    func testOneChangedBookRedrawsOneRow() throws {
        let model = LibraryViewModel(initializeServices: false)
        model.library = ViewsAndWindowsFixtures.shapedLibrary()
        let folder = ViewsAndWindowsFixtures.manualFolder
        let location = LibraryLocation(category: .folders, folderPath: folder)
        model.library.folderSortSettings[location.sortSettingsKey] = FolderSortSetting(sortField: .manual, sortAscending: true)
        // The first book in the folder's order, on screen at the top.
        let changing = try XCTUnwrap(model.displayedBooks(at: location).first?.id)
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        let hosted = hostOffscreen(
            LibraryView(
                currentFolderPath: .constant(folder),
                category: .constant(.folders),
                showFileImporter: .constant(false),
                showTextInput: .constant(false),
                onOpenBook: { _ in }
            )
            .environmentObject(model)
            .environmentObject(settings)
        )
        defer { takeDown(hosted.window) }
        settle(hosted.hostingView, seconds: 0.5)
        let watched = ["LibraryView.list", "LibraryBookListRow"]

        var offset = 1_000
        let publishes = 10
        let changeOneBook = bodyRuns(of: watched, in: hosted.hostingView, publishing: publishes) { _ in
            offset += 1
            ViewsAndWindowsFixtures.move(changing, to: offset, in: model)
        }
        XCTAssertEqual(changeOneBook["LibraryView.list"], publishes, "The list drew other than once per change")
        let rowsRedrawn = changeOneBook["LibraryBookListRow", default: 0]
        XCTAssertGreaterThan(rowsRedrawn, 0, "The changed book's row never drew again")
        XCTAssertLessThanOrEqual(rowsRedrawn, publishes, "Rows the change left alone drew again")

        let republish = bodyRuns(of: watched, in: hosted.hostingView, publishing: publishes) { _ in
            model.objectWillChange.send()
        }
        XCTAssertEqual(republish["LibraryBookListRow"], 0, "A publish that changed nothing redrew rows")
    }

    // MARK: - Fixtures

    /// Actions that do nothing, for rows that are only compared.
    private static let noActions = LibraryBookRowActions(
        open: { _ in }, showInfo: { _ in }, select: { _ in }, toggleSelection: { _ in },
        moveToFolder: { _ in }, moveInManualOrder: { _, _ in }, performCloudCommand: { _ in }, remove: { _ in }
    )

    /// Other actions that do nothing, which a row must not compare.
    private static let otherActions = LibraryBookRowActions(
        open: { _ in }, showInfo: { _ in }, select: { _ in }, toggleSelection: { _ in },
        moveToFolder: { _ in }, moveInManualOrder: { _, _ in }, performCloudCommand: { _ in }, remove: { _ in }
    )

    /// A row for `book` with the given inputs, the defaults a plain row has.
    private static func row(
        _ book: Book,
        shownTitle: String? = nil,
        isOpenInWindow: Bool = false,
        wpm: Double = 200,
        isEditMode: Bool = false,
        isEditSelected: Bool = false,
        cloudState: BookCloudState? = nil,
        isKeptOnThisMac: Bool = false,
        targets: [Book]? = nil,
        manualMoves: LibraryManualMoves? = nil,
        removal: RemovalPreferences = RemovalPreferences(confirmsFirst: true, movesToTrash: true),
        livePosition: LiveReadingPosition,
        isInReadingList: Bool = false,
        readingListCommands: [ReadingListCommand] = [],
        actions: LibraryBookRowActions = noActions
    ) -> LibraryBookListRow {
        LibraryBookListRow(
            book: book,
            shownTitle: shownTitle,
            isOpenInWindow: isOpenInWindow,
            wpm: wpm,
            isEditMode: isEditMode,
            isEditSelected: isEditSelected,
            cloudState: cloudState,
            isKeptOnThisMac: isKeptOnThisMac,
            targets: targets ?? [book],
            cloudCommands: [],
            manualMoves: manualMoves,
            removalPreferences: removal,
            livePosition: livePosition,
            isInReadingList: isInReadingList,
            readingListCommands: readingListCommands,
            actions: actions
        )
    }

    /// A library of 1 to 30 books, each in "Shelf" or at the root, with a
    /// manual position that is often repeated or missing and a title that
    /// often ties, so the order falls back on titles and IDs.
    private static func randomLibrary(using generator: inout SeededGenerator) -> Library {
        let count = Int.random(in: 1...30, using: &generator)
        let books = (0..<count).map { number in
            Book(
                title: "Title \(Int.random(in: 0...4, using: &generator))",
                format: .txt,
                filePath: "/nonexistent/random-\(number).txt",
                md5Hash: "random-\(number)",
                folderPath: Bool.random(using: &generator) ? "Shelf" : "",
                manualSortOrder: Int.random(in: 0...3, using: &generator) == 0 ? nil : Int.random(in: 0...6, using: &generator)
            )
        }
        return Library(books: books, folders: [BookFolder(name: "Shelf")])
    }
}
