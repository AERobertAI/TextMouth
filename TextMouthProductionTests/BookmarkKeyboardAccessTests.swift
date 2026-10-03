import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Keyboard- and VoiceOver-operable bookmarks (TODO A04): the reader
/// operations the bookmarks panel builds on, and the hosted windows its
/// rendered tests rely on.
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
