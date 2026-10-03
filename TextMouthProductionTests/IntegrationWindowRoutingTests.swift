import AppKit
import XCTest
@testable import TextMouth

/// Window routing at the real boundary (TODO Q04; repair P02, with the
/// router of A05): a book that plays to its end with Continue to Next Book
/// posts `.continueToNextBook` itself, a router listening where that reader
/// posts decides who opens the next book, and the reader opened for it
/// starts playing.
@MainActor
final class IntegrationWindowRoutingTests: XCTestCase {
    /// With no Library window registered, as after the user closed every
    /// Library window to listen from a reader, a book that finishes with
    /// Continue to Next Book has exactly one reader opened for the next book:
    /// through the router's fallback, the opener the finished book's reader
    /// window lent it, and without asking for a Library window. That reader
    /// claims the request and starts playing, and only the finished book
    /// says anything ("Starting: Second Volume").
    ///
    /// The first book really plays its last one-second chapter of silence
    /// to the end, so the notification comes from the reader's own end of
    /// book. The opener counts each reader it opens and builds the reader's
    /// model as the reader window would, without showing a window.
    ///
    /// Before the repair, only a Library window's own view opened the next
    /// book, so with none open nothing did. With that rule restored in the
    /// router's decision (the repair's commits went into AppDelegate and no
    /// longer revert cleanly since A05 moved the fallback into the router),
    /// this test fails with "XCTAssertTrue failed - The next book never
    /// started playing in a reader of its own", then "Not exactly one reader
    /// was opened, for the next book" (none was) and a Library window asked
    /// for instead.
    func testFinishedBookOpensOneReaderForTheNextBookWithNoLibraryWindow() throws {
        let world = try makeIntegrationWorld("Integration Routing")
        let finished = try world.makeSilentAudioBook(
            title: "First Volume",
            trackDurations: [1, 1],
            // Its last chapter, from the start: one second from the end.
            savedPosition: ReadingPosition(chapterIndex: 1, characterOffset: 0),
            endOfBook: .continueNext
        )
        let next = try world.makeSilentAudioBook(title: "Second Volume", trackDurations: [30])

        // No Library window is registered, and none is key.
        let router = LibraryWindowRouter(keyWindow: { nil })
        var libraryWindowRequests = 0
        router.openLibraryWindow = {
            libraryWindowRequests += 1
            return false
        }
        router.listen(to: world.notifications)

        let finishedReader = world.openReader(for: finished)
        waitForReaderToLoad(finishedReader)
        // The finished book's reader window lends the router its way of
        // opening readers, as BookReaderWindowView does. It is never shown.
        let readerWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        readerWindow.isReleasedWhenClosed = false
        var openedBooks: [UUID] = []
        var nextReader: ReaderViewModel?
        router.registerReaderWindow(readerWindow) { bookID in
            openedBooks.append(bookID)
            if let book = world.library.bookByID(bookID) {
                nextReader = world.openReader(for: book)
            }
        }

        let recorder = recordingAnnouncements {
            finishedReader.play()
            XCTAssertTrue(
                waitUntil(timeout: 8) { nextReader?.isCurrentlyPlaying == true },
                "The next book never started playing in a reader of its own"
            )
            // A second opening, or a Library window asked for, would follow
            // within the finished book's continue delay; none may.
            XCTAssertFalse(
                waitUntil(timeout: ReaderViewModel.continueToNextBookDelay * 2) {
                    openedBooks.count > 1 || libraryWindowRequests > 0
                },
                "A second reader or a Library window was asked for"
            )
        }

        XCTAssertEqual(openedBooks, [next.id], "Not exactly one reader was opened, for the next book")
        XCTAssertEqual(libraryWindowRequests, 0, "A Library window was asked for")
        XCTAssertEqual(router.recordedDecisions, [
            GlobalActionDecision(action: .continueToNextBook(next.id), handler: .readerWindow(readerWindow)),
        ])
        XCTAssertEqual(nextReader?.audioPlaybackService.isPlaying, true)
        XCTAssertFalse(world.autoplayRequests.hasRequest(for: next.id), "The request was left unclaimed")
        XCTAssertFalse(finishedReader.isCurrentlyPlaying)
        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Second Volume"])
    }
}
