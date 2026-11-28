import XCTest
@testable import TextMouth

// What the audio columns of the end-behavior matrix share (multi-file,
// chaptered, and DAISY audio): playing a book saved a moment short of its end
// and checking what it does as it ends against its cell.

extension EndBehaviorMatrixTests {

    /// Open `book` in `world`, set the sleep timer of `cell`, play the book
    /// out silently in real time (it has `secondsLeftWhenSaved` to play), and
    /// check what it did at its end against the cell (`assertEnd`), each
    /// failure naming the cell.
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
        // Kept before the play begins, so no report of the end is missed.
        let reports = PlayerReportLog(observing: service)
        // The log holds its service's hook by an unowned reference, and
        // `reader.stop()` (in the defer above) can still bring a last
        // report: the hook is cleared before the log goes, and before the stop.
        defer { service._reportHandledForTesting = nil }
        let recorder = recordingAnnouncements {
            reader.play()
            XCTAssertTrue(service.isPlaying, "\(name): the book did not play", file: file, line: line)
            XCTAssertTrue(
                eventually(within: 10) { reader.lastAnnouncement != announcedBefore },
                "\(name): the book never ended", file: file, line: line
            )
            waitForTheEndToSettle(of: service, reports: reports)
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
                timerInEffect: reader.sleepTimerService.isActive
            ),
            is: cell, title: book.title, next: nextBook.title, lastChapter: lastChapter, content: content,
            file: file, line: line
        )
    }

    /// Wait until the audio service has dealt with everything that follows a
    /// book's end, which the end's announcement does not yet prove: the
    /// file's end notice, which arrives after the tick that finished the
    /// clip or before it, and, when the book plays again (a loop), one tick
    /// of the new play, which would finish it again were the end handled
    /// twice. Each wait ends when the service's report arrives
    /// (`AudioPlaybackService._reportHandledForTesting`) and is bounded by
    /// the 0.3 seconds this test once waited whatever happened, so a report
    /// that never comes costs no more than before, and one that comes costs
    /// only until it does.
    ///
    /// What the reports do after the end, measured on October 17 for every
    /// cell (times from the end's announcement): in the chaptered and DAISY
    /// columns, the tick that finished the clip is followed within about 40
    /// ms by the stop tick (`.ignore`, the one of the P07 bug) and then by
    /// the end-of-file report, in that order, so waiting for the
    /// end-of-file report covers the stop tick; a DAISY loop gets no
    /// end-of-file report and waits the whole 0.3 seconds, as it always
    /// did. In the single-file and multi-file columns the end arrives as
    /// the end-of-file report alone, and no tick follows it in a stopping
    /// cell within 0.8 seconds, so there is nothing more to wait for; a
    /// loop there gets a tick of the new play about 6 ms after. Since
    /// October 30 a chaptered book's last chapter has no clip end
    /// (`ReaderViewModel.AudioLayout.clipEnd(ofChapter:chapterUTF16Lengths:)`),
    /// so the chaptered column's end arrives as the single-file column's
    /// does, which the wait covers as well.
    ///
    /// - Parameters:
    ///   - service: The audio service of the book's reader.
    ///   - reports: The service's reports, kept since before the play began.
    func waitForTheEndToSettle(of service: AudioPlaybackService, reports: PlayerReportLog) {
        _ = eventually(within: 0.3) { !reports.endOfFileOutcomes.isEmpty }
        guard service.isPlaying else { return }
        let ticksSoFar = reports.tickCount
        _ = eventually(within: 0.3) { reports.tickCount > ticksSoFar }
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

    /// How long a book of the audio columns has left to play when it is
    /// saved, in seconds: short, so a cell ends in moments, but long enough
    /// that the player is playing steadily before the end, and well clear of
    /// the start-of-play tolerance with which the audio service tells the
    /// late end of an earlier playthrough from a real end
    /// (`AudioEndNoticePolicy.playStartTolerance`). A tenth of a second is
    /// the offsets' granularity (`ReaderViewModel.audioCharsPerSecond`).
    static let secondsLeftWhenSaved: TimeInterval = 0.3

    /// The offset, in a chapter of `seconds` seconds, `secondsLeftWhenSaved`
    /// before its end: where the audio columns' books are saved, so they
    /// end in moments.
    static func offsetBeforeTheEnd(ofChapterOf seconds: TimeInterval) -> Int {
        Int(((seconds - secondsLeftWhenSaved) * ReaderViewModel.audioCharsPerSecond).rounded())
    }
}
