import XCTest
@testable import TextMouth

/// The acceptance matrix's "End behavior" row (TODO-2026-09-04.md): what a
/// book does when its last speech or audio finishes, for each end-of-book
/// behavior, kind of content, and sleep timer. Every cell has a test, so a
/// change to the end of a book, such as per-folder or per-feed end-of-book
/// options, cannot alter a default silently.
///
/// The grid is four behaviors (`EndOfBookBehavior`: stop, stop and Play
/// starts over, loop, continue to the next book) by five kinds of content
/// (text, single-file audio, chaptered audio, multi-file audio, DAISY) by
/// five sleep timers (none; End of book; End of heading, set in the last
/// heading, so the book's end ends it; minutes still running at the end;
/// minutes that ran out before it). In each cell the observable outcome is:
/// the one announcement VoiceOver hears (its wording pinned), whether the
/// book plays again, whether it rests finished, where its cursor rests, whether the next
/// book was asked for, and whether the timer is still in effect. The source
/// of truth is `ReaderViewModel.handleEndOfBook()`; the tests pin what it
/// does today, with the book's own behavior standing in for the global
/// setting (the same path, `effectiveEndOfBookBehavior`).
///
/// The inventory, one line per cell (`behavior | content | timer | cover`),
/// as of October 16, 2026. A test covers a cell only if it checks the
/// observable outcome of that combination, not merely runs near it.
///
/// stop | text | none | covered by SpeakableChapterAdvanceTests.testALastChapterSpokenToItsEndRestsAtTheBooksEnd
/// stop | text | endOfBook | covered by IntegrationSleepTimerTests.testEndOfBookTimerSpeaksATextBookToItsEndAndStartsNothingAfter
/// stop | text | endOfHeading | covered by IntegrationSleepTimerTests.testEndOfHeadingTimerInTheLastChapterEndsListeningWithTheBook
/// stop | text | minutes (running) | covered by EndBehaviorMatrixTests.testTextBookEndBehaviorMatrix
/// stop | text | minutes (expired) | covered by EndBehaviorMatrixTests.testTextBookEndBehaviorMatrix
/// stopAndPlayStartsOver | text | none | covered by EndBehaviorMatrixTests.testTextBookEndBehaviorMatrix
/// stopAndPlayStartsOver | text | endOfBook | covered by EndBehaviorMatrixTests.testTextBookEndBehaviorMatrix
/// stopAndPlayStartsOver | text | endOfHeading | covered by EndBehaviorMatrixTests.testTextBookEndBehaviorMatrix
/// stopAndPlayStartsOver | text | minutes (running) | covered by EndBehaviorMatrixTests.testTextBookEndBehaviorMatrix
/// stopAndPlayStartsOver | text | minutes (expired) | covered by EndBehaviorMatrixTests.testTextBookEndBehaviorMatrix
/// loop | text | none | covered by SpeakableChapterAdvanceTests.testLoopRestartsFromTheBeginningWhenAnythingIsSpeakable
/// loop | text | endOfBook | covered by IntegrationSleepTimerTests.testEndOfBookTimerSpeaksATextBookToItsEndAndStartsNothingAfter
/// loop | text | endOfHeading | covered by IntegrationSleepTimerTests.testEndOfHeadingTimerInTheLastChapterEndsListeningWithTheBook
/// loop | text | minutes (running) | covered by EndBehaviorMatrixTests.testTextBookEndBehaviorMatrix
/// loop | text | minutes (expired) | covered by EndBehaviorMatrixTests.testTextBookEndBehaviorMatrix
/// continueNext | text | none | covered by EndBehaviorMatrixTests.testTextBookEndBehaviorMatrix
/// continueNext | text | endOfBook | covered by IntegrationSleepTimerTests.testEndOfBookTimerSpeaksATextBookToItsEndAndStartsNothingAfter
/// continueNext | text | endOfHeading | covered by IntegrationSleepTimerTests.testEndOfHeadingTimerInTheLastChapterEndsListeningWithTheBook
/// continueNext | text | minutes (running) | covered by EndBehaviorMatrixTests.testTextBookEndBehaviorMatrix
/// continueNext | text | minutes (expired) | covered by EndBehaviorMatrixTests.testTextBookEndBehaviorMatrix
/// stop | single-file audio | none | covered by FinishedBookReaderTests.testEveryAudiobookLayoutRestsExactlyAtItsEnd (oneFile)
/// stop | single-file audio | endOfBook | covered by EndBehaviorMatrixTests.testSingleFileAudioEndBehaviorMatrix
/// stop | single-file audio | endOfHeading | covered by EndBehaviorMatrixTests.testSingleFileAudioEndBehaviorMatrix
/// stop | single-file audio | minutes (running) | covered by EndBehaviorMatrixTests.testSingleFileAudioEndBehaviorMatrix
/// stop | single-file audio | minutes (expired) | covered by EndBehaviorMatrixTests.testSingleFileAudioEndBehaviorMatrix
/// stopAndPlayStartsOver | single-file audio | none | covered by EndBehaviorMatrixTests.testSingleFileAudioEndBehaviorMatrix
/// stopAndPlayStartsOver | single-file audio | endOfBook | covered by EndBehaviorMatrixTests.testSingleFileAudioEndBehaviorMatrix
/// stopAndPlayStartsOver | single-file audio | endOfHeading | covered by EndBehaviorMatrixTests.testSingleFileAudioEndBehaviorMatrix
/// stopAndPlayStartsOver | single-file audio | minutes (running) | covered by EndBehaviorMatrixTests.testSingleFileAudioEndBehaviorMatrix
/// stopAndPlayStartsOver | single-file audio | minutes (expired) | covered by EndBehaviorMatrixTests.testSingleFileAudioEndBehaviorMatrix
/// loop | single-file audio | none | covered by EndBehaviorMatrixTests.testSingleFileAudioEndBehaviorMatrix
/// loop | single-file audio | endOfBook | covered by EndBehaviorMatrixTests.testSingleFileAudioEndBehaviorMatrix
/// loop | single-file audio | endOfHeading | covered by EndBehaviorMatrixTests.testSingleFileAudioEndBehaviorMatrix
/// loop | single-file audio | minutes (running) | covered by EndBehaviorMatrixTests.testSingleFileAudioEndBehaviorMatrix
/// loop | single-file audio | minutes (expired) | covered by EndBehaviorMatrixTests.testSingleFileAudioEndBehaviorMatrix
/// continueNext | single-file audio | none | covered by EndBehaviorMatrixTests.testSingleFileAudioEndBehaviorMatrix
/// continueNext | single-file audio | endOfBook | covered by EndBehaviorMatrixTests.testSingleFileAudioEndBehaviorMatrix
/// continueNext | single-file audio | endOfHeading | covered by EndBehaviorMatrixTests.testSingleFileAudioEndBehaviorMatrix
/// continueNext | single-file audio | minutes (running) | covered by EndBehaviorMatrixTests.testSingleFileAudioEndBehaviorMatrix
/// continueNext | single-file audio | minutes (expired) | covered by EndBehaviorMatrixTests.testSingleFileAudioEndBehaviorMatrix
/// stop | chaptered audio | none | covered by FinishedBookReaderTests.testEveryAudiobookLayoutRestsExactlyAtItsEnd (chapterMarks)
/// stop | chaptered audio | endOfBook | covered by EndBehaviorMatrixTests.testChapteredAudioEndBehaviorMatrix
/// stop | chaptered audio | endOfHeading | covered by EndBehaviorMatrixTests.testChapteredAudioEndBehaviorMatrix
/// stop | chaptered audio | minutes (running) | covered by EndBehaviorMatrixTests.testChapteredAudioEndBehaviorMatrix
/// stop | chaptered audio | minutes (expired) | covered by EndBehaviorMatrixTests.testChapteredAudioEndBehaviorMatrix
/// stopAndPlayStartsOver | chaptered audio | none | covered by EndBehaviorMatrixTests.testChapteredAudioEndBehaviorMatrix
/// stopAndPlayStartsOver | chaptered audio | endOfBook | covered by EndBehaviorMatrixTests.testChapteredAudioEndBehaviorMatrix
/// stopAndPlayStartsOver | chaptered audio | endOfHeading | covered by EndBehaviorMatrixTests.testChapteredAudioEndBehaviorMatrix
/// stopAndPlayStartsOver | chaptered audio | minutes (running) | covered by EndBehaviorMatrixTests.testChapteredAudioEndBehaviorMatrix
/// stopAndPlayStartsOver | chaptered audio | minutes (expired) | covered by EndBehaviorMatrixTests.testChapteredAudioEndBehaviorMatrix
/// loop | chaptered audio | none | covered by EndBehaviorMatrixTests.testChapteredAudioEndBehaviorMatrix
/// loop | chaptered audio | endOfBook | covered by EndBehaviorMatrixTests.testChapteredAudioEndBehaviorMatrix
/// loop | chaptered audio | endOfHeading | covered by EndBehaviorMatrixTests.testChapteredAudioEndBehaviorMatrix
/// loop | chaptered audio | minutes (running) | covered by EndBehaviorMatrixTests.testChapteredAudioEndBehaviorMatrix
/// loop | chaptered audio | minutes (expired) | covered by EndBehaviorMatrixTests.testChapteredAudioEndBehaviorMatrix
/// continueNext | chaptered audio | none | covered by EndBehaviorMatrixTests.testChapteredAudioEndBehaviorMatrix
/// continueNext | chaptered audio | endOfBook | covered by EndBehaviorMatrixTests.testChapteredAudioEndBehaviorMatrix
/// continueNext | chaptered audio | endOfHeading | covered by EndBehaviorMatrixTests.testChapteredAudioEndBehaviorMatrix
/// continueNext | chaptered audio | minutes (running) | covered by EndBehaviorMatrixTests.testChapteredAudioEndBehaviorMatrix
/// continueNext | chaptered audio | minutes (expired) | covered by EndBehaviorMatrixTests.testChapteredAudioEndBehaviorMatrix
/// stop | multi-file audio | none | covered by FinishedBookReaderTests.testEveryAudiobookLayoutRestsExactlyAtItsEnd (filePerChapter)
/// stop | multi-file audio | endOfBook | covered by IntegrationSleepTimerTests.testEndOfBookTimerPlaysAnAudiobookToItsEndAndStartsNothingAfter
/// stop | multi-file audio | endOfHeading | covered by EndBehaviorMatrixTests.testMultiFileAudioEndBehaviorMatrix
/// stop | multi-file audio | minutes (running) | covered by EndBehaviorMatrixTests.testMultiFileAudioEndBehaviorMatrix
/// stop | multi-file audio | minutes (expired) | covered by EndBehaviorMatrixTests.testMultiFileAudioEndBehaviorMatrix
/// stopAndPlayStartsOver | multi-file audio | none | covered by FinishedBookReaderTests.testWithStopAndPlayStartsOverPlayStartsAFinishedBookOver
/// stopAndPlayStartsOver | multi-file audio | endOfBook | covered by EndBehaviorMatrixTests.testMultiFileAudioEndBehaviorMatrix
/// stopAndPlayStartsOver | multi-file audio | endOfHeading | covered by EndBehaviorMatrixTests.testMultiFileAudioEndBehaviorMatrix
/// stopAndPlayStartsOver | multi-file audio | minutes (running) | covered by EndBehaviorMatrixTests.testMultiFileAudioEndBehaviorMatrix
/// stopAndPlayStartsOver | multi-file audio | minutes (expired) | covered by EndBehaviorMatrixTests.testMultiFileAudioEndBehaviorMatrix
/// loop | multi-file audio | none | covered by ContinueToNextBookTests.testWhereAFinishedBookRestsFollowsItsEndOfBookBehavior (loop)
/// loop | multi-file audio | endOfBook | covered by ContinueToNextBookTests.testWhereAFinishedBookRestsFollowsItsEndOfBookBehavior (loop with the timer)
/// loop | multi-file audio | endOfHeading | covered by EndBehaviorMatrixTests.testMultiFileAudioEndBehaviorMatrix
/// loop | multi-file audio | minutes (running) | covered by EndBehaviorMatrixTests.testMultiFileAudioEndBehaviorMatrix
/// loop | multi-file audio | minutes (expired) | covered by EndBehaviorMatrixTests.testMultiFileAudioEndBehaviorMatrix
/// continueNext | multi-file audio | none | covered by ContinueToNextBookTests.testFinishedBookAnnouncesTheNextOnceThenAsksForIt
/// continueNext | multi-file audio | endOfBook | covered by IntegrationSleepTimerTests.testEndOfBookTimerPlaysAnAudiobookToItsEndAndStartsNothingAfter
/// continueNext | multi-file audio | endOfHeading | covered by ContinueToNextBookTests.testEndOfHeadingTimerAtTheBooksEndKeepsTheNextBookFromStarting
/// continueNext | multi-file audio | minutes (running) | covered by ContinueToNextBookTests.testFinishedBooksRunningSleepTimerGoesOnWithTheNextBook
/// continueNext | multi-file audio | minutes (expired) | covered by EndBehaviorMatrixTests.testMultiFileAudioEndBehaviorMatrix
/// stop | DAISY | none | covered by FinishedBookReaderTests.testEveryAudiobookLayoutRestsExactlyAtItsEnd (clips)
/// stop | DAISY | endOfBook | covered by EndBehaviorMatrixTests.testDAISYEndBehaviorMatrix
/// stop | DAISY | endOfHeading | covered by EndBehaviorMatrixTests.testDAISYEndBehaviorMatrix
/// stop | DAISY | minutes (running) | covered by EndBehaviorMatrixTests.testDAISYEndBehaviorMatrix
/// stop | DAISY | minutes (expired) | covered by EndBehaviorMatrixTests.testDAISYEndBehaviorMatrix
/// stopAndPlayStartsOver | DAISY | none | covered by EndBehaviorMatrixTests.testDAISYEndBehaviorMatrix
/// stopAndPlayStartsOver | DAISY | endOfBook | covered by EndBehaviorMatrixTests.testDAISYEndBehaviorMatrix
/// stopAndPlayStartsOver | DAISY | endOfHeading | covered by EndBehaviorMatrixTests.testDAISYEndBehaviorMatrix
/// stopAndPlayStartsOver | DAISY | minutes (running) | covered by EndBehaviorMatrixTests.testDAISYEndBehaviorMatrix
/// stopAndPlayStartsOver | DAISY | minutes (expired) | covered by EndBehaviorMatrixTests.testDAISYEndBehaviorMatrix
/// loop | DAISY | none | covered by EndBehaviorMatrixTests.testDAISYEndBehaviorMatrix
/// loop | DAISY | endOfBook | covered by EndBehaviorMatrixTests.testDAISYEndBehaviorMatrix
/// loop | DAISY | endOfHeading | covered by EndBehaviorMatrixTests.testDAISYEndBehaviorMatrix
/// loop | DAISY | minutes (running) | covered by EndBehaviorMatrixTests.testDAISYEndBehaviorMatrix
/// loop | DAISY | minutes (expired) | covered by EndBehaviorMatrixTests.testDAISYEndBehaviorMatrix
/// continueNext | DAISY | none | covered by EndBehaviorMatrixTests.testDAISYEndBehaviorMatrix
/// continueNext | DAISY | endOfBook | covered by EndBehaviorMatrixTests.testDAISYEndBehaviorMatrix
/// continueNext | DAISY | endOfHeading | covered by EndBehaviorMatrixTests.testDAISYEndBehaviorMatrix
/// continueNext | DAISY | minutes (running) | covered by EndBehaviorMatrixTests.testDAISYEndBehaviorMatrix
/// continueNext | DAISY | minutes (expired) | covered by EndBehaviorMatrixTests.testDAISYEndBehaviorMatrix
///
/// This class covers the text and single-file audio columns' cells that no
/// other test did (`testTextBookEndBehaviorMatrix`,
/// `testSingleFileAudioEndBehaviorMatrix`); the other columns' uncovered
/// cells are for part 2, which lives in extensions of this class in files of
/// their own, so the grid's types and helpers (`TimerCase`, `Cell`,
/// `Outcome`, `Observed`, `cells(except:)`, `assertEnd`, `arm`) are internal
/// rather than private. No test plays sound: audio is silence, and speech is
/// stopped before the main run loop turns.
@MainActor
final class EndBehaviorMatrixTests: XCTestCase {

    // MARK: - The Grid

    /// The sleep timers of the grid, named as in the inventory above.
    enum TimerCase: String {
        /// No timer was set.
        case none
        /// A timer set for the end of the book.
        case endOfBook
        /// A timer set for the end of the heading, in the book's last heading.
        case endOfHeading
        /// A timer counting minutes that is still running as the book ends.
        case minutesRunning = "minutes (running)"
        /// A timer counting minutes that ran out before the book ended.
        case minutesExpired = "minutes (expired)"

        /// Whether the timer stops playback where the book ends, ending
        /// itself there.
        var stopsAtTheBooksEnd: Bool { self == .endOfBook || self == .endOfHeading }
    }

    /// One cell of the grid, for one kind of content.
    struct Cell: Equatable {
        /// What the book does at its end.
        let behavior: EndOfBookBehavior
        /// The sleep timer in the reader.
        let timer: TimerCase

        /// The cell's name for a failure message, as the inventory names it.
        func name(of content: String) -> String {
            "\(content) / \(behavior) / \(timer.rawValue)"
        }

        /// What the book does in this cell, the same for every kind of
        /// content, and what the listener hears, for a book titled `title`
        /// whose next book in its folder is titled `next`.
        func outcome(title: String, next: String) -> Outcome {
            // A timer that stops playback at the end keeps the next book from
            // starting. One still running does not (0.2.5): it goes on with
            // the next book.
            let timerEndsListening = timer.stopsAtTheBooksEnd
            switch behavior {
            case .stop, .stopAndPlayStartsOver:
                // The two stop alike at the end; only Play at the end differs.
                return Outcome(
                    announcement: timer.stopsAtTheBooksEnd
                        ? "Finished: \(title). Sleep timer expired."
                        : "Finished: \(title)",
                    playsAgain: false, finished: true, restsAtEnd: true, nextAsked: false
                )
            case .loop where timer.stopsAtTheBooksEnd:
                // The book waits at its beginning, where Play starts it again.
                return Outcome(
                    announcement: "Finished: \(title). Not restarted because of the sleep timer.",
                    playsAgain: false, finished: false, restsAtEnd: false, nextAsked: false
                )
            case .loop:
                // A running timer does not stop a book that starts again.
                return Outcome(
                    announcement: "Restarting: \(title)",
                    playsAgain: true, finished: false, restsAtEnd: false, nextAsked: false
                )
            case .continueNext where timerEndsListening:
                return Outcome(
                    announcement: "Finished: \(title). Next book not started because of the sleep timer.",
                    playsAgain: false, finished: true, restsAtEnd: true, nextAsked: false
                )
            case .continueNext:
                // The next book takes the media controls: this one no longer
                // rests finished, but its cursor rests at its end.
                return Outcome(
                    announcement: "Starting: \(next)",
                    playsAgain: false, finished: false, restsAtEnd: true, nextAsked: true
                )
            }
        }

        /// Whether the timer is still in effect after the book ends: only a
        /// timer counting minutes that is still running.
        var timerStaysInEffect: Bool { timer == .minutesRunning }
    }

    /// What a cell's book does at its end.
    struct Outcome: Equatable {
        /// The one announcement the listener hears.
        let announcement: String
        /// Whether the book plays again (a loop that restarts).
        let playsAgain: Bool
        /// Whether the book rests finished (`hasFinishedBook`).
        let finished: Bool
        /// Whether the cursor rests at the book's end; if not, at its beginning.
        let restsAtEnd: Bool
        /// Whether the next book was asked for.
        let nextAsked: Bool
    }

    /// What a test saw of a book's end.
    struct Observed {
        /// Every announcement made.
        let announcements: [String]
        /// Whether the book plays again.
        let playsAgain: Bool
        /// Whether the reader says the book is finished.
        let finished: Bool
        /// Whether the cursor rests at the book's end.
        let restsAtEnd: Bool
        /// The chapter the cursor is in.
        let chapter: Int
        /// Whether the next book was asked for through a notification.
        let nextAsked: Bool
        /// Whether the next book has a request waiting in the world.
        let nextRequested: Bool
        /// Whether the shared sleep timer is in effect.
        let timerInEffect: Bool
    }

    /// Every cell of the grid, in the inventory's order, but `covered`: those
    /// another test pins.
    static func cells(except covered: [Cell]) -> [Cell] {
        let behaviors: [EndOfBookBehavior] = [.stop, .stopAndPlayStartsOver, .loop, .continueNext]
        let timers: [TimerCase] = [.none, .endOfBook, .endOfHeading, .minutesRunning, .minutesExpired]
        return behaviors.flatMap { behavior in
            timers.map { Cell(behavior: behavior, timer: $0) }
        }
        .filter { !covered.contains($0) }
    }

    /// The text column's cells no other test pins: the inventory's text
    /// column, less its covered cells.
    private static let textCells = cells(except: [
        Cell(behavior: .stop, timer: .none), Cell(behavior: .loop, timer: .none),
        Cell(behavior: .stop, timer: .endOfBook), Cell(behavior: .loop, timer: .endOfBook),
        Cell(behavior: .continueNext, timer: .endOfBook),
        Cell(behavior: .stop, timer: .endOfHeading), Cell(behavior: .loop, timer: .endOfHeading),
        Cell(behavior: .continueNext, timer: .endOfHeading),
    ])

    /// The single-file audio column's cells no other test pins.
    private static let singleFileAudioCells = cells(except: [Cell(behavior: .stop, timer: .none)])

    /// Check what a test `observed` of a book's end against what `cell` does,
    /// each failure naming the cell.
    ///
    /// - Parameters:
    ///   - lastChapter: The index of the book's last chapter, where it rests
    ///     at its end.
    ///   - content: The kind of content, for the failure messages.
    func assertEnd(
        _ observed: Observed,
        is cell: Cell,
        title: String,
        next: String,
        lastChapter: Int,
        content: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let name = cell.name(of: content)
        let expected = cell.outcome(title: title, next: next)
        XCTAssertEqual(observed.announcements, [expected.announcement], "\(name): what was announced", file: file, line: line)
        XCTAssertEqual(observed.playsAgain, expected.playsAgain, "\(name): whether the book played again", file: file, line: line)
        XCTAssertEqual(observed.finished, expected.finished, "\(name): whether the book rests finished", file: file, line: line)
        XCTAssertEqual(observed.restsAtEnd, expected.restsAtEnd, "\(name): whether the cursor rests at the end", file: file, line: line)
        XCTAssertEqual(
            observed.chapter, expected.restsAtEnd ? lastChapter : 0,
            "\(name): the chapter the cursor is in", file: file, line: line
        )
        XCTAssertEqual(observed.nextAsked, expected.nextAsked, "\(name): whether the next book was asked for", file: file, line: line)
        XCTAssertEqual(observed.nextRequested, expected.nextAsked, "\(name): whether the next book has a request", file: file, line: line)
        XCTAssertEqual(observed.timerInEffect, cell.timerStaysInEffect, "\(name): whether the timer is still in effect", file: file, line: line)
    }

    /// Set the sleep timer of `cell` in `reader`, from the reader's side as
    /// the sleep timer sheet sets it. A timer that has run out is set and
    /// run out at once, before the book plays, which leaves it spent as
    /// one that ran out earlier would be.
    func arm(_ timer: TimerCase, in reader: ReaderViewModel) {
        switch timer {
        case .none:
            break
        case .endOfBook:
            reader.startSleepTimer(duration: .endOfBook)
        case .endOfHeading:
            reader.startSleepTimer(duration: .endOfHeading)
        case .minutesRunning:
            reader.startSleepTimer(duration: .minutes(60))
        case .minutesExpired:
            reader.startSleepTimer(duration: .minutes(1))
            SleepTimerService.shared._expireForTesting()
        }
    }

    // MARK: - Text

    /// A text book spoken to its last chapter's end does what the cell says,
    /// for each cell of the text column that no other test pins: the
    /// announcement, whether it speaks again, whether it rests finished at
    /// its end or waits at its beginning, whether the next book is asked
    /// for, and whether the timer is still in effect.
    func testTextBookEndBehaviorMatrix() throws {
        preserveSleepTimers()
        for cell in Self.textCells {
            try withSpeechReader(
                "Matrix Text \(cell.behavior) \(cell.timer)", endOfBook: cell.behavior, chapters: headedChapters()
            ) { speech in
                let reader = speech.reader
                let continued = recordContinueRequests(in: speech.world)
                defer {
                    reader.stop()
                    reader.cancelSleepTimer()
                }
                // The timer is set in the last heading, which begins the last
                // chapter.
                reader.navigateTo(chapterIndex: 2, characterOffset: 0)
                arm(cell.timer, in: reader)
                let endOfLastChapter = try startSpeakingSilentlyUntilItsEnd(reader)

                var spokeAgain = false
                var nextAsked = false
                let recorder = recordingAnnouncements {
                    spokeAgain = endSpeechSilently(endOfLastChapter, of: reader)
                    nextAsked = nextBookAsked(
                        for: cell, title: speech.book.title, next: speech.nextBook.title, continued
                    )
                }

                assertEnd(
                    Observed(
                        announcements: recorder.announcements.map(\.message),
                        playsAgain: spokeAgain,
                        finished: reader.hasFinishedBook,
                        restsAtEnd: reader.cursorRestsAtEnd,
                        chapter: reader.currentChapterIndex,
                        nextAsked: nextAsked,
                        nextRequested: speech.world.autoplayRequests.hasRequest(for: speech.nextBook.id),
                        timerInEffect: SleepTimerService.shared.isActive
                    ),
                    is: cell, title: speech.book.title, next: speech.nextBook.title, lastChapter: 2, content: "text"
                )
            }
        }
    }

    // MARK: - Single-File Audio

    /// An audiobook of one file played to its end does what the cell says,
    /// for each cell of the single-file audio column that no other test
    /// pins. The book is saved a moment (`secondsLeftWhenSaved`) from its
    /// end, so it plays out in real time, silently, and a loop plays on for
    /// long after.
    func testSingleFileAudioEndBehaviorMatrix() throws {
        preserveSleepTimers()
        let seconds: TimeInterval = 10
        for cell in Self.singleFileAudioCells {
            let world = try makeIntegrationWorld("Matrix Audio \(cell.behavior) \(cell.timer)")
            world.settings.sleepFadeOutDuration = 0
            let book = try world.makeSilentAudioFileBook(
                title: "Ferry Timetable",
                duration: seconds,
                savedPosition: ReadingPosition(
                    chapterIndex: 0, characterOffset: Self.offsetBeforeTheEnd(ofChapterOf: seconds)
                ),
                endOfBook: cell.behavior
            )
            let nextBook = try world.makeSilentAudioBook(title: "Harbour Almanac", trackDurations: [5])
            assertAudioBookEnd(
                of: cell, content: "single-file audio", in: world, book: book, nextBook: nextBook,
                layout: .singleFile, lastChapter: 0
            )
        }
    }
}
