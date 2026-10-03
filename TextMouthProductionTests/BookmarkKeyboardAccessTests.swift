import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Keyboard- and VoiceOver-operable bookmarks (TODO A04): the reader
/// operations the bookmarks panel builds on, where the panel sends focus
/// after each operation, and the hosted windows its rendered tests rely on.
@MainActor
final class BookmarkKeyboardAccessTests: XCTestCase {
    // MARK: - Reader operations

    /// Adding a bookmark returns exactly the bookmark added, placed at the
    /// reading position and numbered after the others, so the panel can
    /// move focus to its row.
    func testAddingABookmarkReturnsTheBookmarkAdded() throws {
        let existing = makeBookmarks(count: 2)
        let reader = makeReader(
            bookmarks: existing,
            position: ReadingPosition(chapterIndex: 1, characterOffset: 30)
        )
        defer { reader.close() }

        var added: Bookmark?
        recordingAnnouncements {
            added = reader.addBookmarkAtCurrentPosition(label: "Check the map")
        }

        let bookmark = try XCTUnwrap(added)
        XCTAssertEqual(bookmark.number, 3)
        XCTAssertEqual(bookmark.chapterIndex, 1)
        XCTAssertEqual(bookmark.characterOffset, 30)
        XCTAssertEqual(bookmark.label, "Check the map")
        XCTAssertEqual(reader.bookmarks.map(\.id), existing.map(\.id) + [bookmark.id])
    }

    /// A reader whose book the library has no record of adds nothing, and
    /// says so by returning nil.
    func testAddingABookmarkForAnUnknownBookReturnsNil() {
        let reader = makeReader(isInLibrary: false)
        defer { reader.close() }

        var added: Bookmark?
        recordingAnnouncements {
            added = reader.addBookmarkAtCurrentPosition()
        }

        XCTAssertNil(added)
    }

    // MARK: - Where focus goes

    /// The panel lists bookmarks by number, the order they were added in.
    func testPanelListsBookmarksByNumber() {
        let bookmarks = [
            Bookmark(number: 3, chapterIndex: 0, characterOffset: 0),
            Bookmark(number: 1, chapterIndex: 2, characterOffset: 0),
            Bookmark(number: 2, chapterIndex: 1, characterOffset: 0),
        ]

        XCTAssertEqual(BookmarkPanelView.listOrder(of: bookmarks).map(\.number), [1, 2, 3])
    }

    /// Opening focuses the last bookmark at or before the reading position
    /// in the book, wherever the list puts it.
    func testOpeningFocusesTheLastBookmarkAtOrBeforeTheReadingPosition() {
        let listed = outOfBookOrderBookmarks()
        // Reading positions, and the index in `listed` of the bookmark the
        // panel opens on from each.
        let cases: [(chapterIndex: Int, characterOffset: Int, expected: Int)] = [
            (chapterIndex: 0, characterOffset: 50, expected: 1),  // at bookmark 2
            (chapterIndex: 0, characterOffset: 99, expected: 1),  // past bookmark 2
            (chapterIndex: 1, characterOffset: 19, expected: 1),  // just short of bookmark 3
            (chapterIndex: 1, characterOffset: 20, expected: 2),  // at bookmark 3
            (chapterIndex: 1, characterOffset: 500, expected: 2), // short of bookmark 1
            (chapterIndex: 9, characterOffset: 0, expected: 0),   // past every bookmark
        ]

        for step in cases {
            let opening = BookmarkPanelOperation.open(
                chapterIndex: step.chapterIndex,
                characterOffset: step.characterOffset
            )
            XCTAssertEqual(
                BookmarkPanelView.focusTarget(after: opening, in: listed),
                .bookmark(listed[step.expected].id),
                "Opening at \(step.chapterIndex), \(step.characterOffset)"
            )
        }
    }

    /// Opening before every bookmark focuses the first bookmark after the
    /// reading position: the earliest in the book, not the first listed.
    func testOpeningBeforeEveryBookmarkFocusesTheEarliestInTheBook() {
        let listed = outOfBookOrderBookmarks()

        XCTAssertEqual(
            BookmarkPanelView.focusTarget(after: .open(chapterIndex: 0, characterOffset: 49), in: listed),
            .bookmark(listed[1].id)
        )
    }

    /// Of bookmarks at one place, opening focuses the one listed first,
    /// whether the place lies behind the reading position or ahead of it.
    func testOpeningOnBookmarksAtOnePlaceFocusesTheFirstListed() {
        let listed = [
            Bookmark(number: 1, chapterIndex: 1, characterOffset: 5),
            Bookmark(number: 2, chapterIndex: 1, characterOffset: 5),
        ]

        XCTAssertEqual(
            BookmarkPanelView.focusTarget(after: .open(chapterIndex: 1, characterOffset: 9), in: listed),
            .bookmark(listed[0].id),
            "Behind the reading position"
        )
        XCTAssertEqual(
            BookmarkPanelView.focusTarget(after: .open(chapterIndex: 0, characterOffset: 0), in: listed),
            .bookmark(listed[0].id),
            "Ahead of the reading position"
        )
    }

    /// A lone bookmark takes focus from any reading position; with no
    /// bookmark, opening focuses the Add button.
    func testOpeningWithOneBookmarkOrNone() {
        let lone = [Bookmark(number: 1, chapterIndex: 1, characterOffset: 10)]

        for (chapterIndex, characterOffset) in [(0, 0), (1, 10), (4, 0)] {
            XCTAssertEqual(
                BookmarkPanelView.focusTarget(
                    after: .open(chapterIndex: chapterIndex, characterOffset: characterOffset),
                    in: lone
                ),
                .bookmark(lone[0].id),
                "Opening at \(chapterIndex), \(characterOffset)"
            )
        }
        XCTAssertEqual(
            BookmarkPanelView.focusTarget(after: .open(chapterIndex: 0, characterOffset: 0), in: []),
            .addButton
        )
    }

    /// After an Add, focus goes to the new bookmark. An Add that added
    /// nothing, and a cancelled Add, return focus to the Add button.
    func testAddFocusesTheNewBookmark() {
        let listed = makeBookmarks(count: 3)

        XCTAssertEqual(BookmarkPanelView.focusTarget(after: .add(listed[2].id), in: listed), .bookmark(listed[2].id))
        XCTAssertEqual(BookmarkPanelView.focusTarget(after: .add(nil), in: listed), .addButton)
        XCTAssertEqual(BookmarkPanelView.focusTarget(after: .add(UUID()), in: listed), .addButton)
        XCTAssertEqual(BookmarkPanelView.focusTarget(after: .cancelAdd, in: listed), .addButton)
        XCTAssertEqual(BookmarkPanelView.focusTarget(after: .cancelAdd, in: []), .addButton)
    }

    /// Saving or cancelling an edit returns focus to the edited bookmark,
    /// whichever row it is. If it went meanwhile, focus goes to the first
    /// bookmark, or to the Add button when none is left.
    func testEditReturnsFocusToTheEditedBookmark() {
        let listed = makeBookmarks(count: 3)

        for bookmark in listed {
            XCTAssertEqual(
                BookmarkPanelView.focusTarget(after: .edit(bookmark.id), in: listed),
                .bookmark(bookmark.id),
                "Bookmark \(bookmark.number)"
            )
        }
        XCTAssertEqual(BookmarkPanelView.focusTarget(after: .edit(UUID()), in: listed), .bookmark(listed[0].id))
        XCTAssertEqual(BookmarkPanelView.focusTarget(after: .edit(UUID()), in: []), .addButton)
    }

    /// After a delete, focus goes to the bookmark listed after the deleted
    /// one: from the first row and a middle row to the row below, from the
    /// last row to the row above, and from the only bookmark to the Add
    /// button.
    func testDeleteFocusesTheNextBookmarkElseThePrevious() {
        let listed = makeBookmarks(count: 3)
        let only = makeBookmarks(count: 1)

        XCTAssertEqual(BookmarkPanelView.focusTarget(after: .delete(listed[0].id), in: listed), .bookmark(listed[1].id))
        XCTAssertEqual(BookmarkPanelView.focusTarget(after: .delete(listed[1].id), in: listed), .bookmark(listed[2].id))
        XCTAssertEqual(BookmarkPanelView.focusTarget(after: .delete(listed[2].id), in: listed), .bookmark(listed[1].id))
        XCTAssertEqual(BookmarkPanelView.focusTarget(after: .delete(only[0].id), in: only), .addButton)
    }

    /// Deleting a bookmark the list no longer holds sends focus to the first
    /// bookmark listed, or to the Add button when none is.
    func testDeletingAnUnlistedBookmarkFocusesTheFirstBookmark() {
        let listed = makeBookmarks(count: 2)

        XCTAssertEqual(BookmarkPanelView.focusTarget(after: .delete(UUID()), in: listed), .bookmark(listed[0].id))
        XCTAssertEqual(BookmarkPanelView.focusTarget(after: .delete(UUID()), in: []), .addButton)
    }

    /// A neighbor is one step away in list order. There is none past either
    /// end of the list, and none for a bookmark that is not listed.
    func testNeighborIsOneStepAwayAndNonePastTheEnds() {
        let listed = makeBookmarks(count: 3)

        XCTAssertEqual(BookmarkPanelView.neighbor(of: listed[1].id, offset: -1, in: listed)?.id, listed[0].id)
        XCTAssertEqual(BookmarkPanelView.neighbor(of: listed[1].id, offset: 1, in: listed)?.id, listed[2].id)
        XCTAssertNil(BookmarkPanelView.neighbor(of: listed[0].id, offset: -1, in: listed))
        XCTAssertNil(BookmarkPanelView.neighbor(of: listed[2].id, offset: 1, in: listed))
        XCTAssertNil(BookmarkPanelView.neighbor(of: UUID(), offset: 1, in: listed))
    }

    // MARK: - Rendered panel

    /// Changing one bookmark's note, and any other reader update, redraws
    /// the list without re-creating its rows. A re-created row would ask for
    /// VoiceOver focus again and pull VoiceOver back to it, so the request
    /// made when the panel opened must be the only one, and unchanged.
    func testRowsKeepTheirIdentityWhenTheReaderUpdates() throws {
        let bookmarks = makeBookmarks(count: 3)
        let reader = makeReader(bookmarks: bookmarks)
        defer { reader.close() }

        try withRenderedPanel(for: reader) { hostingView in
            let opening = focusTriggers(in: hostingView).map(ObjectIdentifier.init)

            reader.updateBookmarkLabel(bookmarks[2], label: "Revised")
            reader.currentChapterIndex = 2
            // Let SwiftUI apply both updates.
            _ = waitUntil(timeout: 0.5) {
                hostingView.layoutSubtreeIfNeeded()
                return false
            }

            XCTAssertEqual(reader.bookmarks.map(\.label), ["", "", "Revised"])
            XCTAssertEqual(focusTriggers(in: hostingView).map(ObjectIdentifier.init), opening)
        }
    }

    // MARK: - Hosted test windows

    /// The panel asks for VoiceOver focus, so the window hosting it in a
    /// test must never be taken for a sheet, which the request would bring
    /// forward and make key: the window is titled, and it stays hidden after
    /// the request runs.
    func testHostedWindowStaysHiddenWhenVoiceOverFocusIsRequested() {
        let target = Button("Target") {}
            .modifier(InitialVoiceOverFocusModifier(isTarget: true, delay: 0.05))

        withHostedView(target, until: { _ in true }) { hostingView in
            let window = hostingView.window
            XCTAssertEqual(window?.title.isEmpty, false, "An untitled window is taken for a sheet")
            // Give the request time to run.
            _ = waitUntil(timeout: 0.5) { false }
            XCTAssertEqual(window?.isVisible, false)
            XCTAssertEqual(window?.isKeyWindow, false)
        }
    }

    // MARK: - Helpers

    /// `count` bookmarks numbered from one, each in its own content unit so
    /// list order and book order agree.
    private func makeBookmarks(count: Int) -> [Bookmark] {
        (0..<count).map { index in
            Bookmark(number: index + 1, chapterIndex: index, characterOffset: 10)
        }
    }

    /// Three bookmarks in list order that is not book order: bookmark 1 is
    /// last in the book, bookmark 2 first, and bookmark 3 between them.
    private func outOfBookOrderBookmarks() -> [Bookmark] {
        [
            Bookmark(number: 1, chapterIndex: 2, characterOffset: 0),
            Bookmark(number: 2, chapterIndex: 0, characterOffset: 50),
            Bookmark(number: 3, chapterIndex: 1, characterOffset: 20),
        ]
    }

    /// Render the bookmarks panel for `reader` offscreen, wait until it has
    /// opened and asked for VoiceOver focus, and pass the hosting view to
    /// `body` while the panel is still on its window.
    private func withRenderedPanel(for reader: ReaderViewModel, _ body: (NSView) throws -> Void) throws {
        try withHostedView(
            BookmarkPanelView(viewModel: reader),
            size: NSSize(width: 380, height: 400),
            until: { !focusTriggers(in: $0).isEmpty }
        ) { hostingView in
            XCTAssertEqual(focusTriggers(in: hostingView).count, 1, "The open panel asks for VoiceOver focus once")
            try body(hostingView)
        }
    }

    /// The panel's requests for VoiceOver focus: the trigger view
    /// `InitialVoiceOverFocusModifier` places behind the control it targets.
    private func focusTriggers(in hostingView: NSView) -> [VoiceOverFocusTriggerView] {
        descendants(of: hostingView, as: VoiceOverFocusTriggerView.self)
    }

    /// A reader for a book holding `bookmarks`, opened at `position`.
    ///
    /// The book's file does not exist, so the reader's background load fails
    /// harmlessly and nothing plays. The library is inert (no migration,
    /// timers, or observers) and saves only to the hosted test sandbox, and
    /// the reader listens to a notification center of its own, so no app
    /// command reaches it. Callers close the returned reader.
    private func makeReader(
        bookmarks: [Bookmark] = [],
        position: ReadingPosition? = nil,
        isInLibrary: Bool = true
    ) -> ReaderViewModel {
        let book = Book(
            title: "Bookmark Focus",
            format: .txt,
            filePath: "/tmp/\(UUID().uuidString)-bookmark-focus.txt",
            md5Hash: UUID().uuidString,
            readingPosition: position,
            bookmarks: bookmarks
        )
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: isInLibrary ? [book] : [])
        return ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false),
            notificationCenter: NotificationCenter()
        )
    }
}
