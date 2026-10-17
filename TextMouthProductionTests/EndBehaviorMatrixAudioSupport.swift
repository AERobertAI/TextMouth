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
            nextAsked = nextBookIsAskedFor(continued)
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

    /// The offset, in a chapter of `seconds` seconds, half a second before
    /// its end: where the audio columns' books are saved, so they end in
    /// half a second.
    static func offsetHalfASecondBeforeTheEnd(ofChapterOf seconds: TimeInterval) -> Int {
        Int((seconds - 0.5) * ReaderViewModel.audioCharsPerSecond)
    }
}
