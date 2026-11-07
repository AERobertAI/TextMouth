import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// What the owner of the Move to Folder… presentation lends the test: the
/// two closures that open and close the sheet from outside any view update,
/// as a SwiftUI `Button` or a context-menu item calls its action.
@MainActor
private final class MoveSheetOwnerBox {
    /// Opens the sheet for the given books.
    var open: (([Book]) -> Void)?
    /// Closes the sheet.
    var close: (() -> Void)?
}

/// A view that applies `MoveToFolderSheetPresentation` to a line of text and
/// keeps the request in its own state, as the Library window does.
private struct MoveSheetOwner: View {
    let library: LibraryViewModel
    let box: MoveSheetOwnerBox
    /// What the sheet moves while it shows.
    @State private var request: MoveToFolderRequest?

    var body: some View {
        Text("Owner")
            .modifier(MoveToFolderSheetPresentation(
                request: $request,
                library: library,
                onMove: { _, _ in .success("moved") },
                onDismiss: {}
            ))
            .onAppear {
                box.open = { books in request = MoveToFolderRequest(books: books) }
                box.close = { request = nil }
            }
    }
}

/// Move to Folder… opens its sheet with the books it moves, every time:
/// VoiceOver found it empty on some presentations (October 17, 2026),
/// because the sheet was built from the owner's state as its body last
/// captured it, before the books were set, when nothing ran that body again
/// first, as after the edit bar's Move or a row's context menu.
@MainActor
final class MoveFolderSheetPresentationTests: XCTestCase {
    /// Counts the bodies `MoveFolderSheet` has run so far in this process.
    private var sheetBodies: Int { ViewBodyCounter.count(of: "MoveFolderSheet") }

    /// A book of the given title, in the given folder.
    private func book(_ title: String, in folderPath: String) -> Book {
        Book(
            title: title,
            author: "Author",
            format: .epub,
            filePath: "/nonexistent/\(title).epub",
            md5Hash: title,
            folderPath: folderPath
        )
    }

    /// The first presentation, opened by a closure called outside any view
    /// update, builds the sheet; so does the next one, for other books.
    func testTheFirstPresentationBuildsTheSheetForItsBooks() throws {
        let world = try FeedTestWorld(self, label: "MoveSheetPresentation")
        let base = world.bookFolder.fullPath
        let box = MoveSheetOwnerBox()
        let hosted = hostOffscreen(MoveSheetOwner(library: world.library, box: box))
        defer { takeDown(hosted.window) }
        settle(hosted.hostingView, seconds: 0.3)
        let open = try XCTUnwrap(box.open, "the owner never gave its open closure")
        let close = try XCTUnwrap(box.close, "the owner never gave its close closure")

        // The first presentation.
        let before = sheetBodies
        open([book("First", in: base)])
        settle(hosted.hostingView, seconds: 0.5)
        XCTAssertGreaterThan(sheetBodies, before, "the first presentation built no Move to Folder sheet")

        // A second presentation, for two other books.
        close()
        settle(hosted.hostingView, seconds: 0.5)
        let beforeSecond = sheetBodies
        open([book("Second", in: base), book("Third", in: base)])
        settle(hosted.hostingView, seconds: 0.5)
        XCTAssertGreaterThan(sheetBodies, beforeSecond, "the second presentation built no Move to Folder sheet")
    }

    /// Two requests for the same books are two requests, so a second Move
    /// opens a sheet of its own.
    func testTwoRequestsForTheSameBooksAreDifferentRequests() {
        let books = [book("Same", in: "")]
        let first = MoveToFolderRequest(books: books)
        let second = MoveToFolderRequest(books: books)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first, second)
    }

    /// The debug log's line for the sheet appearing names the command and
    /// counts, and nothing else.
    func testTheShownLineNamesTheCommandAndCountsOnly() {
        XCTAssertEqual(
            MoveFolderSheet.shownLine(command: "Move to Folder", places: 3, items: 2),
            "MOVE_SHEET_SHOWN: Move to Folder lists 3 place(s) for 2 item(s)"
        )
        XCTAssertEqual(
            MoveFolderSheet.shownLine(command: "Move to Library", places: 1, items: 1),
            "MOVE_SHEET_SHOWN: Move to Library lists 1 place(s) for 1 item(s)"
        )
    }

    /// The Library window opens the sheet for the selected book, and not for
    /// an empty selection.
    func testTheLibraryWindowOpensTheSheetForTheSelectedBook() throws {
        let world = try FeedTestWorld(self, label: "MoveSheetLibraryWindow")
        let base = world.bookFolder.fullPath
        _ = try world.library.createFolderReturningFolder(name: "Classics", parentPath: base)
        world.library.library.books.append(book("Middlemarch", in: base))
        world.library.library.books.append(book("Emma", in: base))
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        let hosted = hostOffscreen(
            LibraryView(
                currentFolderPath: .constant(base),
                category: .constant(.folders),
                showFileImporter: .constant(false),
                showTextInput: .constant(false),
                onOpenBook: { _ in },
                feedFolders: LibraryFeedFolders(center: world.center)
            )
            .environmentObject(world.library)
            .environmentObject(settings)
        )
        defer { takeDown(hosted.window) }
        settle(hosted.hostingView, seconds: 0.5)
        let userInfo: [AnyHashable: Any] = ["sourceWindow": hosted.window]
        let list = try XCTUnwrap(descendants(of: hosted.hostingView, as: NSTableView.self).first, "the window shows no list")

        // No row selected: no sheet. Checked first, since an open sheet's
        // content is built again as the window settles.
        let beforeNone = sheetBodies
        NotificationCenter.default.post(name: .moveToFolder, object: nil, userInfo: userInfo)
        settle(hosted.hostingView, seconds: 0.5)
        XCTAssertEqual(sheetBodies, beforeNone, "Move to Folder opened a sheet with nothing selected")

        // The last row, a book, selected: the sheet opens.
        // Guarded, never asserted: a row index below zero would raise and
        // take the test host down.
        guard list.numberOfRows > 0 else {
            return XCTFail("the list shows no rows")
        }
        list.selectRowIndexes(IndexSet(integer: list.numberOfRows - 1), byExtendingSelection: false)
        settle(hosted.hostingView, seconds: 0.3)
        let beforeSelected = sheetBodies
        NotificationCenter.default.post(name: .moveToFolder, object: nil, userInfo: userInfo)
        settle(hosted.hostingView, seconds: 0.5)
        XCTAssertGreaterThan(sheetBodies, beforeSelected, "Move to Folder built no sheet for the selected book")
    }
}
