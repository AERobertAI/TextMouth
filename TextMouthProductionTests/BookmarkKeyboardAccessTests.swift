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

    // MARK: - Bookmark commands

    /// The commands come in a fixed order under fixed names, each pictured
    /// by an SF Symbol that exists, so no button or menu item is drawn
    /// blank. Only Delete is destructive, and Edit Note and Delete are the
    /// buttons drawn beside each row.
    func testCommandsHaveFixedNamesSymbolsAndRoles() {
        XCTAssertEqual(BookmarkCommand.allCases.map(\.title), ["Go To", "Edit Note", "Delete"])
        for command in BookmarkCommand.allCases {
            XCTAssertNotNil(
                NSImage(systemSymbolName: command.systemImage, accessibilityDescription: nil),
                command.title
            )
        }
        XCTAssertEqual(BookmarkCommand.allCases.map(\.role), [nil, nil, .destructive])
        XCTAssertEqual(BookmarkCommand.rowButtons, [.editNote, .delete])
    }

    /// Each command's button names its bookmark by number.
    func testCommandButtonsNameTheirBookmarkByNumber() {
        XCTAssertEqual(BookmarkCommand.goTo.buttonLabel(forBookmarkNumber: 3), "Go to bookmark 3")
        XCTAssertEqual(BookmarkCommand.editNote.buttonLabel(forBookmarkNumber: 3), "Edit note for bookmark 3")
        XCTAssertEqual(BookmarkCommand.delete.buttonLabel(forBookmarkNumber: 12), "Delete bookmark 12")
    }

    // MARK: - Rendered panel

    /// For VoiceOver each row holds three buttons: the row itself, named
    /// after its bookmark, and Edit Note and Delete buttons naming the
    /// bookmark by number. The row offers all three commands as actions.
    ///
    /// SwiftUI builds these accessibility elements only for a connected
    /// assistive app such as VoiceOver. Without one the test is skipped;
    /// the wording tests above still cover every label.
    func testRenderedRowsExposeGoToEditNoteAndDeleteToAccessibility() throws {
        let reader = makeReader(bookmarks: makeBookmarks(count: 3))
        defer { reader.close() }

        try withRenderedPanel(for: reader) { hostingView in
            let buttonLabels = accessibleControls(in: hostingView)
                .filter { $0.role == .button }
                .map(\.label)
            guard !buttonLabels.isEmpty else {
                throw XCTSkip("SwiftUI exposed no button to accessibility without an assistive app")
            }

            for bookmark in reader.bookmarks {
                let rowLabel = "Bookmark \(bookmark.number)"
                for label in [rowLabel] + BookmarkCommand.rowButtons.map({ $0.buttonLabel(forBookmarkNumber: bookmark.number) }) {
                    XCTAssertTrue(buttonLabels.contains(label), "\(label) is not among \(buttonLabels)")
                }
                let offersEveryCommand = accessibilityElements(labelled: rowLabel, in: hostingView).contains { element in
                    let actions = Set((element.accessibilityCustomActions() ?? []).map(\.name))
                    return actions.isSuperset(of: BookmarkCommand.allCases.map(\.title))
                }
                XCTAssertTrue(offersEveryCommand, "\(rowLabel) offers Go To, Edit Note, and Delete as actions")
            }
        }
    }

    /// Every row draws its Edit Note and Delete buttons, the rows out of
    /// view too: the list keeps every row alive, so each can take focus.
    func testEveryRowDrawsItsButtonsEvenOutOfView() throws {
        // Far more rows than the panel shows at once. A lazy list draws only
        // the rows near the visible ones (two dozen of these, offscreen),
        // so a shorter list could not tell the two apart.
        let count = 60
        let reader = makeReader(bookmarks: makeBookmarks(count: count))
        defer { reader.close() }

        try withRenderedPanel(for: reader) { hostingView in
            XCTAssertTrue(waitUntil { renderedRowButtons(in: hostingView).count == count })
            XCTAssertEqual(
                renderedRowButtons(in: hostingView).map(\.count),
                Array(repeating: BookmarkCommand.rowButtons.count, count: count)
            )
        }
    }

    /// Pressing a row's rendered Delete button deletes that row's bookmark,
    /// and the bookmarks after it move up a number.
    func testPressingARenderedDeleteButtonDeletesThatBookmark() throws {
        let bookmarks = makeBookmarks(count: 3)
        let reader = makeReader(bookmarks: bookmarks)
        defer { reader.close() }

        try withRenderedPanel(for: reader) { hostingView in
            let delete = try XCTUnwrap(renderedButton(.delete, row: 1, in: hostingView))
            delete.performClick(nil)

            // SwiftUI may deliver the button's action on a later turn of the
            // run loop.
            XCTAssertTrue(waitUntil { reader.bookmarks.count == 2 })
            XCTAssertEqual(reader.bookmarks.map(\.id), [bookmarks[0].id, bookmarks[2].id])
            XCTAssertEqual(reader.bookmarks.map(\.number), [1, 2])
        }
    }

    /// Pressing a row's rendered Edit Note button opens that bookmark's note
    /// for editing.
    func testPressingARenderedEditNoteButtonOpensThatBookmarksNote() throws {
        let bookmarks = makeBookmarks(count: 3).map { bookmark -> Bookmark in
            var noted = bookmark
            noted.label = "Note \(bookmark.number)"
            return noted
        }
        let reader = makeReader(bookmarks: bookmarks)
        defer { reader.close() }

        try withRenderedPanel(for: reader) { hostingView in
            let editNote = try XCTUnwrap(renderedButton(.editNote, row: 1, in: hostingView))
            editNote.performClick(nil)

            let opened = waitUntil {
                hostingView.layoutSubtreeIfNeeded()
                return noteFields(in: hostingView).count == 1
            }
            XCTAssertTrue(opened, "Edit Note shows a note field")
            XCTAssertEqual(noteFields(in: hostingView).first?.stringValue, "Note 2")
        }
    }

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

    /// The buttons AppKit drew beside each row of the list, row by row from
    /// the top and left to right within a row; empty while there is no list.
    ///
    /// SwiftUI draws the borderless Edit Note and Delete buttons with AppKit
    /// buttons and the row's own button itself, so these are the only AppKit
    /// buttons in the list. A row's buttons share a vertical center.
    private func renderedRowButtons(in hostingView: NSView) -> [[NSButton]] {
        guard let list = descendants(of: hostingView, as: NSScrollView.self).first?.documentView else {
            return []
        }
        // Window coordinates, in which y grows upward.
        func frame(_ button: NSButton) -> NSRect {
            button.convert(button.bounds, to: nil)
        }
        let rows = Dictionary(grouping: descendants(of: list, as: NSButton.self)) { frame($0).midY.rounded() }
        return rows.keys.sorted(by: >).map { center in
            (rows[center] ?? []).sorted { frame($0).minX < frame($1).minX }
        }
    }

    /// The rendered button for `command` beside row `row` (counted from zero
    /// at the top), or nil when the list has no such row or button.
    private func renderedButton(_ command: BookmarkCommand, row: Int, in hostingView: NSView) -> NSButton? {
        let rows = renderedRowButtons(in: hostingView)
        guard rows.indices.contains(row),
              let index = BookmarkCommand.rowButtons.firstIndex(of: command),
              rows[row].indices.contains(index) else { return nil }
        return rows[row][index]
    }

    /// The editable text fields AppKit drew: the note field while adding or
    /// editing a bookmark.
    private func noteFields(in hostingView: NSView) -> [NSTextField] {
        descendants(of: hostingView, as: NSTextField.self).filter(\.isEditable)
    }

    /// Every accessibility element below `root` whose label is `label`,
    /// groups included.
    private func accessibilityElements(labelled label: String, in root: Any) -> [NSAccessibilityProtocol] {
        guard let node = root as? NSAccessibilityProtocol else { return [] }
        let match = node.accessibilityLabel() == label ? [node] : []
        return match + (node.accessibilityChildren() ?? []).flatMap {
            accessibilityElements(labelled: label, in: $0)
        }
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
