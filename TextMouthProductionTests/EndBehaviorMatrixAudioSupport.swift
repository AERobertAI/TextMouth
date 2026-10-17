import XCTest
@testable import TextMouth

// What the audio columns of the end-behavior matrix share (multi-file,
// chaptered, and DAISY audio): playing a book saved a moment short of its end
// and checking what it does as it ends against its cell.

extension EndBehaviorMatrixTests {

    /// Open `book` in `world`, set the sleep timer of `cell`, play the book
    /// out silently in real time, and check what it did at its end against
    /// the cell (`assertEnd`), each failure naming the cell.
    ///
    /// The book must be saved a moment short of its end, so it plays out
    /// quickly: a loop then plays on for as long as the test lasts, which is
    /// why the book's last chapter must be long enough to outlast the
    /// moments the test spends after the end.
    ///
    /// - Parameters:
    ///   - cell: The behavior and timer under test; `book`'s own behavior is
    ///     the cell's.
    ///   - content: The kind of content, for the failure messages.
    ///   - world: The world that holds both books.
    ///   - book: The book under test.
    ///   - nextBook: The book after it in its folder, where Continue to Next
    ///     Book goes.
    ///   - layout: The layout the book must open in, so a fixture that opens
    ///     in another layout fails loudly.
    ///   - lastChapter: The index of the book's last chapter, where it rests
    ///     at its end.
    func assertAudioBookEnd(
        of cell: Cell,
        content: String,
        in world: IntegrationWorld,
        book: Book,
        nextBook: Book,
        layout: ReaderViewModel.AudioLayout,
        lastChapter: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let name = cell.name(of: content)
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader, file: file, line: line)
        XCTAssertNil(reader.errorMessage, "\(name): the book did not open", file: file, line: line)
        XCTAssertEqual(reader.audioLayout, layout, "\(name): the book opened in another layout", file: file, line: line)
        let service = reader.audioPlaybackService
        let continued = recordContinueRequests(in: world)
        defer {
            reader.stop()
            reader.cancelSleepTimer()
        }
        arm(cell.timer, in: reader)
        // A timer that ran out as it was set announced that, before the end.
        let announcedBefore = reader.lastAnnouncement

        var nextAsked = false
        let recorder = recordingAnnouncements {
            reader.play()
            XCTAssertTrue(service.isPlaying, "\(name): the book did not play", file: file, line: line)
            XCTAssertTrue(
                eventually(within: 10) { reader.lastAnnouncement != announcedBefore },
                "\(name): the book never ended", file: file, line: line
            )
            // Long enough for the player's last tick, as it stops at the end,
            // to have been handled.
            spinMainRunLoop(for: 0.3)
            nextAsked = nextBookAsked(for: cell, title: book.title, next: nextBook.title, continued)
        }

        assertEnd(
            Observed(
                announcements: recorder.announcements.map(\.message),
                playsAgain: service.isPlaying,
                finished: reader.hasFinishedBook,
                restsAtEnd: reader.cursorRestsAtEnd,
                chapter: reader.currentChapterIndex,
                nextAsked: nextAsked,
                nextRequested: world.autoplayRequests.hasRequest(for: nextBook.id),
                timerInEffect: SleepTimerService.shared.isActive
            ),
            is: cell, title: book.title, next: nextBook.title, lastChapter: lastChapter, content: content,
            file: file, line: line
        )
    }

    /// Whether the next book has been asked for, as `continued` records the
    /// requests, once a book's end has settled. A cell that expects the next
    /// book waits for the ask, which comes `ReaderViewModel.continueToNextBookDelay`
    /// after the announcement (`nextBookIsAskedFor`); any other cell reads
    /// what has been asked for so far, at once.
    ///
    /// That is as strong as the wait it replaces: the next book is asked
    /// for only by a hand-over (`ReaderViewModel.handOverToNextBook`, which
    /// its two callers, `goOnPastThisBook` and the episode download, reach
    /// at the end of a book), and a hand-over speaks "Starting: <title>" the
    /// moment it begins, before it asks. The cell's announcement assertion
    /// (`assertEnd`) fails on that announcement in every cell that is not to
    /// hand over, and the recorder that holds the announcements was running
    /// all along, so a hand-over that began would fail the cell whether or
    /// not this test then waited a second for its ask.
    ///
    /// - Parameters:
    ///   - cell: The behavior and timer under test.
    ///   - title: The title of the book that ended, for the expected outcome.
    ///   - next: The title of the book after it.
    ///   - continued: The reader of the requests posted so far
    ///     (`recordContinueRequests(in:)`).
    func nextBookAsked(
        for cell: Cell, title: String, next: String, _ continued: () -> [Notification]
    ) -> Bool {
        cell.outcome(title: title, next: next).nextAsked
            ? nextBookIsAskedFor(continued)
            : !continued().isEmpty
    }

    /// The offset, in a chapter of `seconds` seconds, half a second before
    /// its end: where the audio columns' books are saved, so they end in
    /// half a second.
    static func offsetHalfASecondBeforeTheEnd(ofChapterOf seconds: TimeInterval) -> Int {
        Int((seconds - 0.5) * ReaderViewModel.audioCharsPerSecond)
    }
}
