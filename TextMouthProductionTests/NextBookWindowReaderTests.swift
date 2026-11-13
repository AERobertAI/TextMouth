import AppKit
import Combine
import XCTest
@testable import TextMouth

/// A reader going on to the next book shows it in its own window or opens a
/// new one, as the setting says (0.2.5). The window's switch is injected, so
/// no window opens and nothing plays: the readers are of silent audiobooks,
/// ended by `handleEndOfBook()` or moved by the reading list's commands.
///
/// Each reader window has a sleep timer of its own (November 13, 2026). A
/// `SwitchRecorder` stands for one window and holds its timer: the readers
/// made with one, one after another as the window switches, are that window's
/// and share the timer. A reader in a window of its own (`inOwnWindow`, the
/// next book of a new window, a book open elsewhere, a book opened from the
/// Library) has a timer of its own, and a timer carried to it moves there.
@MainActor
final class NextBookWindowReaderTests: XCTestCase {
    /// Subscriptions a test keeps until it ends.
    private var subscriptions = Set<AnyCancellable>()

    // MARK: - The End of a Book

    /// With This Window, going on to the next book calls the switcher once,
    /// after the request to play it is made, and posts neither the
    /// notification that opens a window nor the one that brings it forward.
    func testTheEndOfABookSwitchesThisWindowAfterTheRequests() throws {
        let folder = try makeFolderWorld("EndSwitch")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let asked = record(.continueToNextBook, in: folder.world)
        let opened = record(.openBookWindow, in: folder.world)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)

        let recorder = recordingAnnouncements {
            reader.handleEndOfBook()
            XCTAssertTrue(switcher.shown.isEmpty, "Switched before the announcement had a moment")
            XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "Never switched")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: B Volume"])
        XCTAssertEqual(switcher.shown, [folder.second.id])
        XCTAssertEqual(switcher.requestWaitingAtTheSwitch, [true], "The request came after the switch")
        XCTAssertTrue(asked().isEmpty, "Opened a window as well")
        XCTAssertTrue(opened().isEmpty, "Opened a window as well")
        XCTAssertTrue(reader.hasSwitchedWindow)
    }

    /// With A New Window, going on posts as before 0.2.5, and never calls
    /// the switcher.
    func testANewWindowPostsAsBefore() throws {
        let folder = try makeFolderWorld("EndNewWindow")
        folder.world.settings.nextBookWindow = .newWindow
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let asked = record(.continueToNextBook, in: folder.world)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)

        reader.handleEndOfBook()
        XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book")

        XCTAssertEqual(asked().map(\.nextBookID), [folder.second.id])
        XCTAssertTrue(switcher.shown.isEmpty)
        XCTAssertFalse(reader.hasSwitchedWindow)
    }

    /// A feed's or folder's own choice wins over the global one, either way,
    /// while its books go on.
    func testTheFoldersOwnChoiceWinsOverTheGlobalSetting() throws {
        for (own, global, switches) in [
            (NextBookWindow.newWindow, NextBookWindow.thisWindow, false),
            (NextBookWindow.thisWindow, NextBookWindow.newWindow, true),
        ] {
            let folder = try makeFolderWorld("EndOwn \(own.rawValue)", options: ListeningOptions(
                continuation: .playBookBelow, nextBookWindow: own
            ))
            folder.world.settings.nextBookWindow = global
            let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
            let asked = record(.continueToNextBook, in: folder.world)
            let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)

            reader.handleEndOfBook()
            XCTAssertTrue(eventually { !asked().isEmpty || !switcher.shown.isEmpty }, "Never went on: \(own)")

            XCTAssertEqual(!switcher.shown.isEmpty, switches, "own \(own.rawValue), global \(global.rawValue)")
            XCTAssertEqual(!asked().isEmpty, !switches, "own \(own.rawValue), global \(global.rawValue)")
        }
    }

    /// A reader that has no window on screen, as one whose window closed,
    /// opens a new window as before, and calls no switcher.
    func testAReaderWithNoWindowOnScreenOpensANewWindow() throws {
        let folder = try makeFolderWorld("EndOffScreen")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let asked = record(.continueToNextBook, in: folder.world)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        reader.windowStandingOverride = .noWindow

        reader.handleEndOfBook()
        XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book")

        XCTAssertEqual(asked().map(\.nextBookID), [folder.second.id])
        XCTAssertTrue(switcher.shown.isEmpty)
    }

    /// Ends the first book of a fresh folder world, whose window stands as
    /// `standing` and which `prepare` has made busy, and says whether the
    /// next book opened in a new window (the notification posted, the
    /// switcher not called) or this window switched.
    ///
    /// - Returns: True when a new window opened, false when this window
    ///   switched.
    private func endOpensANewWindow(
        _ label: String,
        standing: NextBookWindowStanding = .onScreen,
        prepare: (FolderWorld) -> Void = { _ in },
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Bool {
        let folder = try makeFolderWorld(label)
        prepare(folder)
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let asked = record(.continueToNextBook, in: folder.world)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        reader.windowStandingOverride = standing

        reader.handleEndOfBook()
        XCTAssertTrue(
            eventually { !asked().isEmpty || !switcher.shown.isEmpty },
            "\(label): never went on", file: file, line: line
        )
        // Exactly one of the two happened.
        XCTAssertEqual(asked().isEmpty, !switcher.shown.isEmpty, "\(label)", file: file, line: line)
        return !asked().isEmpty
    }

    /// A sheet or an alert open over the window, or a field being typed in
    /// (Go to Percent, Time, or Page), opens a new window: a switch would
    /// take them away.
    func testASheetOrAFieldBeingEditedOpensANewWindow() throws {
        var sheet = NextBookWindowStanding.onScreen
        sheet.hasSheet = true
        XCTAssertTrue(try endOpensANewWindow("BusySheet", standing: sheet))
        var field = NextBookWindowStanding.onScreen
        field.fieldIsBeingEdited = true
        XCTAssertTrue(try endOpensANewWindow("BusyField", standing: field))
    }

    /// An Edit Text session of the book, the library moving, and the library
    /// being unavailable each open a new window: the app refuses to open a
    /// book while the library moves or is unavailable, which a switch would
    /// go around.
    func testAnEditSessionAMoveOrAnUnavailableLibraryOpensANewWindow() throws {
        XCTAssertTrue(try endOpensANewWindow("BusyEdit") { folder in
            let sessions = BookTextEditSessions()
            let baseline = BookTextBaseline(
                source: nil,
                cache: FileFingerprint(stamp: FileStamp(byteCount: 0, modificationTimeNanoseconds: 0), digest: "")
            )
            sessions.begin(folder.first.id, BookTextEditSessions.Session(baseline: baseline, report: { _, _ in }))
            folder.world.library.textEditSessions = sessions
            self.addTeardownBlock { sessions.end(folder.first.id) }
        })
        XCTAssertTrue(try endOpensANewWindow("BusyMove") { folder in
            folder.world.library.dataDirectoryMove = DataDirectoryMoveProgress(
                destination: URL(fileURLWithPath: "/Volumes/Backup/Library")
            )
        })
        XCTAssertTrue(try endOpensANewWindow("BusyUnavailable") { folder in
            folder.world.library.noteDataDirectoryUnavailable(
                .driveNotConnected(volume: "Spare Disk", folder: "/Volumes/Spare Disk/TextMouth")
            )
        })
    }

    /// A window minimized to the Dock, and a window hidden with the app
    /// (Command-H orders every window out), still switch: a book shown there
    /// is there when the window returns. A window that has closed does not.
    func testAMinimizedWindowAndAHiddenAppStillSwitch() throws {
        var minimized = NextBookWindowStanding.noWindow
        minimized.isMiniaturized = true
        XCTAssertFalse(try endOpensANewWindow("StandingMinimized", standing: minimized))
        var hidden = NextBookWindowStanding.noWindow
        hidden.appIsHidden = true
        XCTAssertFalse(try endOpensANewWindow("StandingHidden", standing: hidden))
        XCTAssertFalse(try endOpensANewWindow("StandingVisible", standing: .onScreen))
        XCTAssertTrue(try endOpensANewWindow("StandingClosed", standing: .noWindow))
    }

    /// A running sleep timer goes on with the next book when this window
    /// switches to it (0.2.5): it is held for the book from the announcement,
    /// still this reader's, with exactly one owner, until the reader that
    /// takes the window over has loaded; then it is that reader's, running,
    /// with its time left as it was. The old reader's close leaves it running.
    func testARunningSleepTimerGoesOnWithASwitchedWindow() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("SwitchTimer")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        let before = timer.remainingSeconds

        old.goThroughFolder(.down)
        XCTAssertTrue(timer.isHeld(forBook: folder.second.id), "The timer was not held from the announcement")
        XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "Never switched")
        XCTAssertEqual(timer.ownerID, old.readerID, "Exactly one owner until the next reader takes the timer")
        XCTAssertTrue(timer.isActive)

        let new = makeReader(for: folder.second, in: folder.world, switcher: switcher)
        XCTAssertTrue(new.sleepTimerService === timer, "The window's next book has another timer than the window's")
        XCTAssertEqual(timer.ownerID, new.readerID, "The reader that took the window does not own the timer")
        XCTAssertFalse(timer.isHeld(forBook: folder.second.id), "The hold was left")
        XCTAssertEqual(timer.duration, .minutes(30))
        XCTAssertLessThanOrEqual(timer.remainingSeconds, before)
        XCTAssertGreaterThan(timer.remainingSeconds, before - 60, "The countdown was reset")

        old.close()
        XCTAssertTrue(timer.isActive, "The old reader's close stopped the timer")
        XCTAssertEqual(timer.ownerID, new.readerID)
    }

    /// The timer goes on in a new window too, as a busy window or A New
    /// Window opens one: the old reader stays open, and the new window's
    /// reader takes the timer when it has loaded, into its own window's timer,
    /// while the old window's timer stops.
    func testARunningSleepTimerGoesOnWithANewWindow() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("NewWindowTimer")
        folder.world.settings.nextBookWindow = .newWindow
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let opened = record(.openBookWindow, in: folder.world)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})

        old.goThroughFolder(.down)
        XCTAssertTrue(eventually { !opened().isEmpty }, "Never opened the next book")
        XCTAssertTrue(switcher.shown.isEmpty)
        XCTAssertTrue(timer.isHeld(forBook: folder.second.id))
        XCTAssertEqual(timer.ownerID, old.readerID)

        // The next book is in a new window, with a timer of its own.
        let new = makeReader(for: folder.second, in: folder.world, switcher: switcher, inOwnWindow: true)
        let taken = new.sleepTimerService
        XCTAssertEqual(taken.ownerID, new.readerID)
        XCTAssertTrue(taken.isActive)
        XCTAssertFalse(timer.isActive, "The old window's timer ran on beside the one carried to the new window")
    }

    /// A timer fading out is not held for the next book: it is putting the
    /// listener to sleep, and ends listening.
    func testATimerFadingOutIsNotHeld() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("FadeTimer")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        timer.start(duration: .minutes(1), ownerID: old.readerID, onExpire: {}, fadeOutDuration: 5)
        timer._expireForTesting()
        XCTAssertTrue(timer.isFadingOut)

        old.holdSleepTimer(forBook: folder.second.id)

        XCTAssertFalse(timer.isHeld(forBook: folder.second.id), "A fading timer was held")
        XCTAssertFalse(old.ownsCarriableSleepTimer)
        XCTAssertTrue(timer.endedListening(ownedBy: old.readerID))
    }

    /// A command pressed while the timer fades out ends the fade and the timer,
    /// as a Pause does, and the book moved to starts; the listener did not ask
    /// to cancel the timer, so it is said after "Starting: <title>", and after
    /// current speech.
    func testACommandWhileTheTimerFadesOutSaysTheTimerWasCancelled() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("CommandDuringFade")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = reader.sleepTimerService
        timer.start(duration: .minutes(1), ownerID: reader.readerID, onExpire: {}, fadeOutDuration: 5)
        timer._expireForTesting()
        XCTAssertTrue(timer.isFadingOut)
        reader.isWhereAmIResumePending = true

        let recorder = recordingAnnouncements {
            reader.goThroughFolder(.down)
            XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "The book moved to never started")
        }

        XCTAssertEqual(
            recorder.announcements,
            [
                VoiceOverAnnouncement(message: "Starting: B Volume", priority: .high),
                VoiceOverAnnouncement(message: SleepTimerHandOverWording.fadeEndedByTheMove, priority: .medium),
            ]
        )
        XCTAssertFalse(timer.isActive, "The fade went on after the move")
        XCTAssertEqual(switcher.shown, [folder.second.id])
        XCTAssertEqual(
            SleepTimerHandOverWording.fadeEndedByTheMove,
            "Sleep timer cancelled, because you moved to another book while it faded out."
        )
        XCTAssertEqual(
            SleepTimerHandOverWording.noBook,
            "Sleep timer cancelled, because the next book could not be opened."
        )
    }

    /// Command-W in the half second between "Starting" and the ask does not
    /// stop the timer: it is held for the next book, which is opened in a new
    /// window as announced, and takes it.
    func testClosingTheWindowBeforeTheAskKeepsTheTimerForTheNextBook() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("CloseBeforeAsk")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let opened = record(.openBookWindow, in: folder.world)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})

        old.goThroughFolder(.down)
        old.close()
        XCTAssertTrue(timer.isActive, "Closing the window stopped the timer")
        XCTAssertEqual(timer.ownerID, old.readerID)
        XCTAssertTrue(eventually { !opened().isEmpty }, "Never opened the next book")
        XCTAssertTrue(switcher.shown.isEmpty, "A closed reader switched a window that is gone")

        // The old window is gone: the book opens in a new window, with a timer of its own.
        let new = makeReader(for: folder.second, in: folder.world, switcher: switcher, inOwnWindow: true)
        let taken = new.sleepTimerService
        XCTAssertEqual(taken.ownerID, new.readerID, "The book opened without the timer")
        XCTAssertTrue(taken.isActive)
        XCTAssertFalse(timer.isActive, "The closed window's timer ran on beside the one carried to the new window")
    }

    /// A second move before the first move's book has loaded passes the
    /// timer on: the book that is still loading counts as playing, goes on to
    /// the next book, and the reader of that book takes the timer and plays.
    func testASecondMoveBeforeTheFirstBookLoadedPassesTheTimerOn() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("SecondMove")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let first = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = first.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: first.readerID, onExpire: {})
        // Counts as playing, without a sound: a Where Am I? announcement that
        // will play the book again.
        first.isWhereAmIResumePending = true

        first.goThroughFolder(.down)
        XCTAssertTrue(eventually { switcher.shown.count == 1 }, "The first move never asked")
        XCTAssertEqual(switcher.shown, [folder.second.id])

        // B's reader has not loaded; it is moved on from before it plays.
        let second = makeLoadingReader(for: folder.second, in: folder.world, switcher: switcher)
        XCTAssertTrue(timer.isHeld(forBook: folder.second.id))
        let recorder = recordingAnnouncements {
            second.goThroughFolder(.down)
            XCTAssertTrue(eventually { switcher.shown.count == 2 }, "The second move never asked")
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: C Volume"], "The loading book did not count as playing")
        XCTAssertEqual(switcher.shown, [folder.second.id, folder.third.id])
        XCTAssertTrue(timer.isActive, "The second move stopped the timer")
        XCTAssertTrue(timer.isHeld(forBook: folder.third.id), "The timer was not passed on")
        XCTAssertFalse(timer.isHeld(forBook: folder.second.id))

        let third = makeReader(for: folder.third, in: folder.world, switcher: switcher)
        XCTAssertTrue(third.sleepTimerService === timer, "The window's last book has another timer than the window's")
        XCTAssertEqual(timer.ownerID, third.readerID, "The last book's reader does not own the timer")
        XCTAssertTrue(eventually(within: 15) { third.isCurrentlyPlaying }, "The last book never played")
    }

    /// Next then Previous within the half second ask once, for the book the
    /// last command went to, and it still plays: the first command's pause
    /// does not turn the second into an open.
    func testNextThenPreviousAsksOnce() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("NextThenPrevious")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let reader = makeReader(for: folder.second, in: folder.world, switcher: switcher)
        let timer = reader.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: reader.readerID, onExpire: {})
        reader.isWhereAmIResumePending = true

        let recorder = recordingAnnouncements {
            reader.goThroughFolder(.down)
            reader.goThroughFolder(.up)
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 3)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: C Volume", "Starting: A Volume"])
        XCTAssertEqual(switcher.shown, [folder.first.id], "The commands asked more than once")
        XCTAssertTrue(timer.isHeld(forBook: folder.first.id), "The timer is held for the book the first command went to")
        XCTAssertFalse(timer.isHeld(forBook: folder.third.id))
        XCTAssertTrue(timer.isActive)
    }

    /// A timer held for a book whose reader is still opening it, in a download
    /// or a load that outlasts the deadline, stays held: the reader exists and
    /// is responsible for it. The deadline does not stop it, VoiceOver is not
    /// told the book could not be opened, and when the load ends the reader
    /// owns the timer and plays.
    func testAHeldTimerIsKeptWhileItsBooksReaderIsOpeningIt() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("DeadlineWhileOpening")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        let opening = makeLoadingReader(for: folder.second, in: folder.world, switcher: switcher, inOwnWindow: true)
        _ = folder.world.autoplayRequests.request(for: folder.second.id, from: folder.first.id)
        XCTAssertTrue(timer.hold(
            forBook: folder.second.id, from: old.readerID, deadline: 0.2, isBookOpen: opening.bookIsOpenCheck
        ))
        timer.markAsked(forBook: folder.second.id)

        let recorder = recordingAnnouncements {
            spinMainRunLoop(for: 1.0)
        }

        XCTAssertTrue(timer.isActive, "The deadline stopped a timer held for a book that is still opening")
        XCTAssertTrue(timer.isHeld(forBook: folder.second.id))
        XCTAssertFalse(
            recorder.announcements.contains { $0.message == SleepTimerHandOverWording.noBook },
            "VoiceOver said the book could not be opened"
        )

        heldLoadQueue?.activate()
        waitForReaderToLoad(opening)
        XCTAssertEqual(
            opening.sleepTimerService.ownerID, opening.readerID, "The reader that opened the book did not take the timer"
        )
        XCTAssertFalse(timer.isActive, "The old window's timer ran on beside the one carried to the book's window")
        XCTAssertTrue(eventually(within: 15) { opening.isCurrentlyPlaying }, "The book never played")
        XCTAssertFalse(recorder.announcements.contains { $0.message == SleepTimerHandOverWording.noBook })
    }

    /// N1's slow load through a reader: the book takes longer to open than a
    /// request to a reader lives (30 seconds, on a clock the test sets), its
    /// request to play held as an opening download holds it, and the reader
    /// still takes the timer and plays.
    func testASlowLoadPastTheRequestLifetimeStillTakesTheTimer() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("SlowLoad")
        let clock = RequestClock()
        let requests = ReaderAutoplayRequests(now: { clock.now })
        let switcher = SwitchRecorder(requests: requests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        let slow = makeLoadingReader(
            for: folder.second, in: folder.world, switcher: switcher, autoplayRequests: requests, inOwnWindow: true
        )
        _ = requests.request(for: folder.second.id, from: folder.first.id)
        requests.hold(for: folder.second.id)
        old.holdSleepTimer(forBook: folder.second.id)
        timer.markAsked(forBook: folder.second.id)
        old.close()

        clock.advance(by: ReaderRequestStore<ReaderAutoplayRequest>.lifetime + 30)
        XCTAssertTrue(timer.isHeld(forBook: folder.second.id), "The hold lapsed with the requests' lifetime")
        heldLoadQueue?.activate()
        waitForReaderToLoad(slow)

        XCTAssertEqual(slow.sleepTimerService.ownerID, slow.readerID, "The slow book did not take the timer")
        XCTAssertTrue(slow.sleepTimerService.isActive)
        XCTAssertFalse(timer.isActive, "The old window's timer ran on beside the one carried to the slow book's window")
        XCTAssertTrue(eventually(within: 15) { slow.isCurrentlyPlaying }, "The slow book never played")
    }

    /// An End of heading timer taken by a finished book that starts over waits
    /// for the heading after its beginning, not for the end of the book: the
    /// heading looked for at its end found none.
    func testAnEndOfHeadingTimerTakenByAFinishedBookWaitsForTheHeadingAfterItsBeginning() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("FinishedHeading")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let finished = makeReader(for: folder.second, in: folder.world, switcher: switcher)
        let place = try XCTUnwrap(finished.endOfBookPlace)
        finished.currentChapterIndex = place.chapterIndex
        finished.currentCharacterOffset = place.characterOffset
        finished.hasFinishedBook = true
        finished.sleepTimerService.start(duration: .endOfHeading, ownerID: finished.readerID, onExpire: {})
        finished.refreshSleepTimerHeading()
        XCTAssertNil(finished.sleepTimerNextHeading, "a heading was found after the book's end")

        // Play on a book resting at its end starts it over, as a move onto a
        // finished book does when the folder does not skip it.
        _ = folder.world.autoplayRequests.request(for: folder.second.id, from: folder.first.id)
        finished.claimAutoplayRequest()

        XCTAssertEqual(finished.currentChapterIndex, 0, "the book did not start over")
        XCTAssertEqual(finished.sleepTimerNextHeading?.chapterIndex, 1, "the timer still waits for the book's end")
    }

    /// A command pressed in the half second after a book's end cancels the
    /// end's hand-over: the book that ended counts as playing, one ask is made,
    /// for the book the command went to, and the timer is held for that book
    /// and not for the one the end announced.
    func testACommandAfterTheEndOfABookCancelsTheHandOver() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("CommandAfterEnd")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let reader = makeReader(for: folder.second, in: folder.world, switcher: switcher)
        let timer = reader.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: reader.readerID, onExpire: {})

        let recorder = recordingAnnouncements {
            reader.handleEndOfBook()
            reader.goThroughFolder(.up)
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 3)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: C Volume", "Starting: A Volume"])
        XCTAssertEqual(switcher.shown, [folder.first.id], "The end's hand-over asked as well as the command")
        XCTAssertFalse(folder.world.autoplayRequests.hasRequest(for: folder.third.id), "The cancelled hand-over left a request")
        XCTAssertTrue(timer.isHeld(forBook: folder.first.id), "The timer is not held for the book the command went to")
        XCTAssertFalse(timer.isHeld(forBook: folder.third.id))
    }

    /// A timer held for a book is never replaced by a hold the ask of another
    /// book makes: the later move's hold stands.
    func testTheAskOfAnEarlierBookDoesNotReplaceAHoldMadeForALaterOne() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("AskKeepsLaterHold")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = reader.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: reader.readerID, onExpire: {})
        XCTAssertTrue(timer.hold(forBook: folder.third.id, from: reader.readerID))

        reader.showNextBook(folder.second.id, under: .newWindow) {}

        XCTAssertTrue(timer.isHeld(forBook: folder.third.id), "A hold made for another book was replaced")
        XCTAssertFalse(timer.isHeld(forBook: folder.second.id))
    }

    /// Restart Sleep Timer during a hold, from the old reader, whose window's
    /// timer is held, restarts the held countdown at its full duration and
    /// keeps the hold and its owner: the book the timer is held for takes it
    /// at that duration, and no reader is given it back. A third book's reader,
    /// in a window of its own, restarts its own window's timer, which it
    /// starts at the duration last used, and leaves the held timer as it was.
    func testRestartSleepTimerDuringAHoldKeepsTheHoldAndTheOwner() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("RestartHeld")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let other = makeReader(for: folder.third, in: folder.world, switcher: switcher, inOwnWindow: true)
        let timer = old.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        for _ in 0..<90 { timer._advanceCountdownForTesting() }
        XCTAssertEqual(timer.remainingSeconds, 30 * 60 - 90)
        XCTAssertTrue(timer.hold(forBook: folder.second.id, from: old.readerID))

        // The gesture reaches a reader of a third book, in a window of its own:
        // it acts on its own window's timer, which had none, and starts one of
        // the duration last used. The timer held for the second book, in the
        // old reader's window, is not its to restart.
        other.restartOrStartLastSleepTimer()
        let othersTimer = other.sleepTimerService
        XCTAssertTrue(othersTimer.isActive, "The third window's restart started no timer of its own")
        XCTAssertEqual(othersTimer.duration, .minutes(30), "The third window's timer is not of the duration last used")
        XCTAssertEqual(othersTimer.ownerID, other.readerID)
        XCTAssertEqual(timer.remainingSeconds, 30 * 60 - 90, "A third window's restart reached the held timer")

        // Then the old reader, whose window's timer is the one held.
        old.restartOrStartLastSleepTimer()
        XCTAssertEqual(timer.remainingSeconds, 30 * 60, "The held countdown was not restarted")

        XCTAssertTrue(timer.isHeld(forBook: folder.second.id), "The restart ended the hold")
        XCTAssertEqual(timer.ownerID, old.readerID, "The restart changed the owner")
        XCTAssertFalse(old.isPlaybackUnderWay, "The restart resumed the reader that moved on")
        timer.markAsked(forBook: folder.second.id)
        // The second book opens in a window of its own and takes the held timer there.
        let taker = makeReader(for: folder.second, in: folder.world, switcher: switcher, inOwnWindow: true)
        let taken = taker.sleepTimerService
        XCTAssertEqual(taken.ownerID, taker.readerID)
        XCTAssertGreaterThan(taken.remainingSeconds, 30 * 60 - 60, "The book took a timer that was not restarted")
        XCTAssertFalse(timer.isActive, "The old window's timer ran on beside the one carried to the book's window")
        XCTAssertTrue(othersTimer.isActive, "The take stopped the third window's timer")
    }

    /// A restart after a mid-book Next does not resume the book that moved on:
    /// it stays paused, and the timer's countdown is not resumed for it.
    func testRestartSleepTimerAfterANextDoesNotResumeTheBookThatMovedOn() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("RestartAfterNext")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        old.isWhereAmIResumePending = true
        old.goThroughFolder(.down)
        XCTAssertTrue(timer.isHeld(forBook: folder.second.id))

        old.restartOrStartLastSleepTimer()

        XCTAssertFalse(old.isPlaybackUnderWay, "The restart resumed the book that moved on")
        XCTAssertFalse(old.isWhereAmIUnderWay)
        XCTAssertTrue(timer.isHeld(forBook: folder.second.id))
        XCTAssertEqual(timer.remainingSeconds, 30 * 60)
        XCTAssertEqual(timer.ownerID, old.readerID)
    }

    /// Closing the old reader while the held timer fades out gives the result
    /// not closing it gives: the timer runs out, and the book it was held for
    /// does not start. The close does not stop the timer.
    func testClosingTheOldReaderDuringAHeldFadeLeavesTheFadeToRunOut() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("HeldFade")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        timer.start(duration: .minutes(1), ownerID: old.readerID, onExpire: {}, fadeOutDuration: 5)
        XCTAssertTrue(timer.hold(forBook: folder.second.id, from: old.readerID))
        timer.markAsked(forBook: folder.second.id)
        timer._expireForTesting()
        XCTAssertTrue(timer.isFadingOut)
        _ = folder.world.autoplayRequests.request(for: folder.second.id, from: folder.first.id)

        old.close()
        XCTAssertTrue(timer.isFadingOut, "Closing the reader stopped a timer that was fading out")
        let next = makeReader(for: folder.second, in: folder.world, switcher: switcher, inOwnWindow: true)
        spinMainRunLoop(for: 1.0)

        XCTAssertFalse(next.isCurrentlyPlaying, "The book started after the timer began to fade out")
        XCTAssertFalse(folder.world.autoplayRequests.hasRequest(for: folder.second.id))
        XCTAssertNotEqual(timer.ownerID, next.readerID, "The book took a timer that was fading out")
        XCTAssertNotEqual(next.sleepTimerService.ownerID, next.readerID, "The book's window took a timer that was fading out")
        XCTAssertFalse(next.sleepTimerService.isActive, "The book's window runs a timer that was fading out")
    }

    /// A Pause reaching the old reader during a held fade leaves the fade to
    /// run out, as closing it does: the timer ends listening, its expiry is said
    /// once, and the book it was held for does not start. The expiry's own pause
    /// stops the timer, with nothing left held.
    func testAPauseDuringAHeldFadeLeavesTheFadeToRunOut() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("PauseHeldFade")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        startOneMinuteSleepTimer(for: old, fade: 1)
        XCTAssertTrue(timer.hold(forBook: folder.second.id, from: old.readerID))
        timer.markAsked(forBook: folder.second.id)
        timer._expireForTesting()
        XCTAssertTrue(timer.isFadingOut)
        _ = folder.world.autoplayRequests.request(for: folder.second.id, from: folder.first.id)

        let recorder = recordingAnnouncements {
            old.pause(playingPauseSound: false)
            XCTAssertTrue(timer.isFadingOut, "The pause ended a fade that was held")
            XCTAssertTrue(timer.isHeld(from: old.readerID), "The pause ended the hold")
            XCTAssertTrue(eventually(within: 10) { !timer.isActive }, "The fade never ran out")
        }

        XCTAssertEqual(
            recorder.announcements.filter { $0.message == ReaderViewModel.sleepTimerExpiredAnnouncement }.count, 1,
            "The expiry was not said exactly once"
        )
        XCTAssertFalse(timer.isHolding, "The hold outlived the expiry")
        XCTAssertNil(timer.ownerID)
        let next = makeReader(for: folder.second, in: folder.world, switcher: switcher, inOwnWindow: true)
        spinMainRunLoop(for: 1.0)
        XCTAssertFalse(next.isCurrentlyPlaying, "The book started after the timer ran out")
    }

    /// A Next pressed while a held fade runs, with the move before it still
    /// pending, ends the fade and the timer: the move cancelled by this one
    /// leaves no hold, so its own pause ends the fade as any move's does. The
    /// book moved to starts, and the fade's end is said.
    func testANextDuringAHeldFadeWithAMovePendingEndsTheFadeAndStartsTheBook() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("NextDuringHeldFade")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        startOneMinuteSleepTimer(for: old, fade: 1)
        old.isWhereAmIResumePending = true
        old.goThroughFolder(.down)
        XCTAssertTrue(timer.isHeld(forBook: folder.second.id))
        timer._expireForTesting()
        XCTAssertTrue(timer.isFadingOut)

        let recorder = recordingAnnouncements {
            old.goThroughFolder(.down)
            XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "The book moved to never started")
        }

        XCTAssertFalse(timer.isActive, "The fade went on after the move")
        XCTAssertFalse(timer.isHolding)
        XCTAssertEqual(switcher.shown, [folder.second.id])
        XCTAssertEqual(
            recorder.announcements,
            [
                VoiceOverAnnouncement(message: "Starting: B Volume", priority: .high),
                VoiceOverAnnouncement(message: SleepTimerHandOverWording.fadeEndedByTheMove, priority: .medium),
            ]
        )
    }

    /// Restart Sleep Timer during a held fade is the listener saying they are
    /// awake: the fade is cancelled and the old reader's volume restored, the
    /// countdown starts again at its full duration, the hold and owner are
    /// kept, no reader is resumed, and "Timer reset." is said. The book the
    /// timer is held for takes it, at that duration, and plays.
    func testRestartSleepTimerDuringAHeldFadeCancelsTheFadeAndTheNextBookTakesTheTimer() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("RestartHeldFade")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        var fadesCancelled = 0
        let handlers = old.makeSleepTimerHandlers(fadeOutDuration: 5)
        timer.start(
            duration: .minutes(1),
            ownerID: old.readerID,
            onExpire: handlers.onExpire,
            onFadeStep: handlers.onFadeStep,
            onFadeCancelled: {
                fadesCancelled += 1
                handlers.onFadeCancelled()
            },
            fadeOutDuration: 5
        )
        for _ in 0..<20 { timer._advanceCountdownForTesting() }
        XCTAssertTrue(timer.hold(forBook: folder.second.id, from: old.readerID))
        timer.markAsked(forBook: folder.second.id)
        timer._expireForTesting()
        XCTAssertTrue(timer.isFadingOut)

        let recorder = recordingAnnouncements { old.restartOrStartLastSleepTimer() }

        XCTAssertFalse(timer.isFadingOut, "The fade went on after the restart")
        XCTAssertEqual(fadesCancelled, 1, "The old reader's volume was not restored")
        XCTAssertTrue(timer.isActive)
        XCTAssertTrue(timer.isHeld(forBook: folder.second.id), "The restart ended the hold")
        XCTAssertEqual(timer.ownerID, old.readerID, "The restart changed the owner")
        XCTAssertEqual(timer.remainingSeconds, 60, "The countdown did not restart at its full duration")
        XCTAssertFalse(old.isPlaybackUnderWay, "The restart resumed the reader that moved on")
        XCTAssertTrue(recorder.announcements.contains { $0.message == "Timer reset." })

        _ = folder.world.autoplayRequests.request(for: folder.second.id, from: folder.first.id)
        let taker = makeReader(for: folder.second, in: folder.world, switcher: switcher, inOwnWindow: true)
        let taken = taker.sleepTimerService
        XCTAssertEqual(taken.ownerID, taker.readerID, "The next book did not take the timer")
        XCTAssertTrue(eventually(within: 15) { taker.isCurrentlyPlaying }, "The next book never played")
        XCTAssertGreaterThan(taken.remainingSeconds, 60 - 10)
        XCTAssertFalse(timer.isActive, "The old window's timer ran on beside the one carried to the next book's window")
        XCTAssertFalse(old.isCurrentlyPlaying)
    }

    /// The sentence that the timer was cancelled because the book could not be
    /// opened, delayed until the reason has been read, is not said over a timer
    /// the listener started meanwhile: that timer is running.
    func testTheDelayedCouldNotBeOpenedSentenceIsNotSaidOverATimerStartedMeanwhile() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("DelayedSentence")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        XCTAssertTrue(timer.hold(forBook: folder.second.id, from: old.readerID))

        let meanwhile = recordingAnnouncements {
            XCTAssertTrue(timer.releaseHeld(forBook: folder.second.id, announcingAfter: 0.3))
            timer.start(duration: .minutes(10), ownerID: old.readerID, onExpire: {})
            spinMainRunLoop(for: 0.8)
        }
        XCTAssertFalse(
            meanwhile.announcements.contains { $0.message == SleepTimerHandOverWording.noBook },
            "The sentence was said over a timer that is running"
        )
        XCTAssertTrue(timer.isActive)

        // With nothing started meanwhile, the sentence is said after the delay.
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        XCTAssertTrue(timer.hold(forBook: folder.second.id, from: old.readerID))
        let alone = recordingAnnouncements {
            XCTAssertTrue(timer.releaseHeld(forBook: folder.second.id, announcingAfter: 0.3))
            spinMainRunLoop(for: 0.8)
        }
        XCTAssertTrue(alone.announcements.contains { $0.message == SleepTimerHandOverWording.noBook })
    }

    /// The expiry is said even if the reader whose handler it is has gone: a
    /// held timer outlives the reader that held it, and the listener is owed
    /// the word that it ran out. The handler calls one function with its
    /// reader weakly, so the test calls it with none, which no retained
    /// reader can get in the way of.
    func testTheExpiryIsSaidEvenWhenTheReaderIsGone() {
        let recorder = recordingAnnouncements { ReaderViewModel.sleepTimerRanOut(for: nil) }

        XCTAssertEqual(
            recorder.announcements,
            [VoiceOverAnnouncement(message: ReaderViewModel.sleepTimerExpiredAnnouncement, priority: .high)]
        )
    }

    /// A closed reader leaves the library's registry of open readers, so the
    /// hold's deadline, which asks it, acts: the timer held for the book is
    /// stopped and the listener told. While the reader was open the deadline
    /// left the hold alone, and the reader's own close stopped it silently.
    func testAClosedReaderLeavesTheRegistryAndTheDeadlineActs() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("RegistryDeadline")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        let opening = makeLoadingReader(for: folder.second, in: folder.world, switcher: switcher, inOwnWindow: true)
        XCTAssertTrue(folder.world.library.openBookIDs.contains(folder.second.id))
        XCTAssertTrue(timer.hold(
            forBook: folder.second.id, from: old.readerID, deadline: 0.2, isBookOpen: opening.bookIsOpenCheck
        ))
        timer.markAsked(forBook: folder.second.id)
        spinMainRunLoop(for: 0.7)
        XCTAssertTrue(timer.isHeld(forBook: folder.second.id), "The deadline acted while the book's reader was open")

        let silent = recordingAnnouncements { opening.close() }
        XCTAssertFalse(folder.world.library.openBookIDs.contains(folder.second.id), "A close left the book registered")
        XCTAssertFalse(timer.isActive, "The close left a timer nothing will play")
        XCTAssertTrue(silent.announcements.isEmpty, "The close said something")

        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        XCTAssertTrue(timer.hold(
            forBook: folder.second.id, from: old.readerID, deadline: 0.2, isBookOpen: opening.bookIsOpenCheck
        ))
        let deadline = recordingAnnouncements { spinMainRunLoop(for: 0.7) }
        XCTAssertFalse(timer.isActive, "The deadline did not stop a timer held for a book nobody has open")
        XCTAssertTrue(deadline.announcements.contains { $0.message == SleepTimerHandOverWording.noBook })
    }

    /// Two readers of one book: one closing leaves the book registered and the
    /// timer held for it, which the other reader takes; the last to close
    /// stops it.
    func testOneOfTwoReadersOfABookClosingLeavesTheHold() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("TwoReaders")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        let firstWindow = makeLoadingReader(for: folder.second, in: folder.world, switcher: switcher, inOwnWindow: true)
        let secondWindow = makeLoadingReader(for: folder.second, in: folder.world, switcher: switcher, inOwnWindow: true)
        XCTAssertTrue(timer.hold(forBook: folder.second.id, from: old.readerID))
        timer.markAsked(forBook: folder.second.id)

        firstWindow.close()
        XCTAssertTrue(folder.world.library.openBookIDs.contains(folder.second.id), "The book left the registry with one reader open")
        XCTAssertTrue(timer.isHeld(forBook: folder.second.id), "One window's close stopped the timer the other takes")

        secondWindow.close()
        XCTAssertFalse(folder.world.library.openBookIDs.contains(folder.second.id))
        XCTAssertFalse(timer.isActive, "The last window's close left the timer")
    }

    /// The last move wins until its book has started (the user's question 17):
    /// with A New Window, Next holds the timer and asks for a book whose reader
    /// is still loading, and Previous from the same window cancels that
    /// start: the request to play the book is discarded, the hold undone, the
    /// book moved to now starts and owns the timer, and the first, when it
    /// loads, neither plays nor takes the timer.
    func testALaterMoveBeforeTheFirstBookStartsCancelsItsStartAndTakesTheTimer() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("LastMoveWins")
        folder.world.settings.nextBookWindow = .newWindow
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.second, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        old.isWhereAmIResumePending = true
        old.goThroughFolder(.down)
        XCTAssertTrue(
            eventually { folder.world.autoplayRequests.hasRequest(for: folder.third.id) },
            "The first move never asked for its book"
        )
        XCTAssertTrue(timer.isAsked(forBook: folder.third.id))
        let first = makeLoadingReader(for: folder.third, in: folder.world, switcher: switcher, inOwnWindow: true)

        let recorder = recordingAnnouncements { old.goThroughFolder(.up) }

        XCTAssertFalse(
            folder.world.autoplayRequests.hasRequest(for: folder.third.id), "The first book's request to play was left"
        )
        XCTAssertTrue(recorder.announcements.contains(
            VoiceOverAnnouncement(message: "Starting: A Volume", priority: .high)
        ), "The second move did not count the book as playing")
        XCTAssertFalse(timer.isHeld(forBook: folder.third.id), "The first move's hold was left")
        XCTAssertTrue(timer.isHeld(forBook: folder.first.id), "The second move did not hold the timer")
        XCTAssertEqual(timer.ownerID, old.readerID)

        XCTAssertTrue(
            eventually { folder.world.autoplayRequests.hasRequest(for: folder.first.id) },
            "The second move never asked for its book"
        )
        let second = makeReader(for: folder.first, in: folder.world, switcher: switcher, inOwnWindow: true)
        XCTAssertTrue(eventually(within: 15) { second.isCurrentlyPlaying }, "The book moved to never played")
        XCTAssertEqual(second.sleepTimerService.ownerID, second.readerID, "The book moved to does not own the timer")
        XCTAssertFalse(timer.isActive, "The old window's timer ran on beside the one carried to the book moved to")

        heldLoadQueue?.activate()
        waitForReaderToLoad(first)
        XCTAssertFalse(first.isCurrentlyPlaying, "The first book played after its start was cancelled")
        XCTAssertEqual(second.sleepTimerService.ownerID, second.readerID, "The first book took the timer")
        XCTAssertFalse(first.sleepTimerService.isActive, "The first book's window runs a timer it took")
    }

    /// The same, once the first book has claimed its request and plays and owns
    /// the timer: Previous from the old window is an ordinary move from a book
    /// that is not playing. It only opens the book, and the first book keeps
    /// the timer.
    func testALaterMoveAfterTheFirstBookStartedOnlyOpensTheBookAndLeavesTheTimer() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("LastMoveAfterStart")
        folder.world.settings.nextBookWindow = .newWindow
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.second, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        old.isWhereAmIResumePending = true
        old.goThroughFolder(.down)
        XCTAssertTrue(eventually { folder.world.autoplayRequests.hasRequest(for: folder.third.id) })
        let first = makeReader(for: folder.third, in: folder.world, switcher: switcher, inOwnWindow: true)
        XCTAssertTrue(eventually(within: 15) { first.isCurrentlyPlaying }, "The first book never played")
        XCTAssertEqual(first.sleepTimerService.ownerID, first.readerID)
        XCTAssertFalse(timer.isActive, "The old window's timer ran on beside the one carried to the first book's window")

        let recorder = recordingAnnouncements { old.goThroughFolder(.up) }

        XCTAssertTrue(recorder.announcements.contains { $0.message == "Opening: A Volume" })
        XCTAssertFalse(recorder.announcements.contains { $0.message.hasPrefix("Starting") })
        XCTAssertEqual(first.sleepTimerService.ownerID, first.readerID, "The old window's move took a timer a playing book owns")
        XCTAssertFalse(first.sleepTimerService.isHolding)
        XCTAssertFalse(timer.isHolding, "The old window's move held a timer")
        XCTAssertTrue(first.isCurrentlyPlaying)
    }

    /// A move ends a fade of the timer it carries when the timer is held for the
    /// book moved from: a target still loading passes the hold on, the timer
    /// begins to fade, and a second move from that target ends the fade and the
    /// timer, as the owner's move does. The book moved to starts, the sentence
    /// is said once, and no hold is left.
    func testAMoveFromALoadingTargetEndsTheFadeOfThePassedOnTimer() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("PassedOnFade")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        startOneMinuteSleepTimer(for: old, fade: 5)
        XCTAssertTrue(timer.hold(forBook: folder.second.id, from: old.readerID))
        timer.markAsked(forBook: folder.second.id)
        _ = folder.world.autoplayRequests.request(for: folder.second.id, from: folder.first.id)
        let target = makeLoadingReader(for: folder.second, in: folder.world, switcher: switcher, inOwnWindow: true)
        target.goThroughFolder(.down)
        XCTAssertTrue(timer.isHeld(forBook: folder.third.id), "The loading target did not pass the hold on")
        timer._expireForTesting()
        XCTAssertTrue(timer.isFadingOut)

        let recorder = recordingAnnouncements {
            target.goThroughFolder(.down)
            XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "The book moved to never started")
        }

        XCTAssertFalse(timer.isActive, "The fade went on after the move")
        XCTAssertFalse(timer.isHolding, "A hold was left")
        XCTAssertEqual(switcher.shown, [folder.third.id])
        XCTAssertEqual(
            recorder.announcements,
            [
                VoiceOverAnnouncement(message: "Starting: C Volume", priority: .high),
                VoiceOverAnnouncement(message: SleepTimerHandOverWording.fadeEndedByTheMove, priority: .medium),
            ]
        )
    }

    /// A restart during a held fade, the taker only opened (no request to play
    /// it), then played: the countdown, halted until then, runs from the full
    /// duration the restart gave it.
    func testARestartedHeldFadeRunsFromItsFullDurationWhenTheOpenedTakerPlays() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("RestartThenPlay")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        startOneMinuteSleepTimer(for: old, fade: 5)
        XCTAssertTrue(timer.hold(forBook: folder.second.id, from: old.readerID))
        timer.markAsked(forBook: folder.second.id)
        timer._expireForTesting()
        XCTAssertTrue(timer.isFadingOut)
        old.restartOrStartLastSleepTimer()
        XCTAssertEqual(timer.remainingSeconds, 60)

        // The taker is in a window of its own: the timer moves to its window's.
        let taker = makeReader(for: folder.second, in: folder.world, switcher: switcher, inOwnWindow: true)
        let taken = taker.sleepTimerService
        XCTAssertEqual(taken.ownerID, taker.readerID, "The opened book did not take the timer")
        XCTAssertFalse(timer.isActive, "The old window's timer ran on beside the one carried to the opened book's window")
        XCTAssertFalse(taker.isCurrentlyPlaying, "A book only opened played")
        spinMainRunLoop(for: 1.3)
        XCTAssertEqual(taken.remainingSeconds, 60, "The countdown ran before the taker played")

        taker.play()
        XCTAssertTrue(eventually(within: 15) { taker.isCurrentlyPlaying }, "The taker never played")
        XCTAssertTrue(
            eventually(within: 3) { taken.remainingSeconds < 60 }, "The countdown did not run once the taker played"
        )
        XCTAssertGreaterThanOrEqual(taken.remainingSeconds, 55)
    }

    /// A move ends the fade of the reader's own timer wherever it is held: held
    /// for another book that an earlier move only opened (asked, no request
    /// waiting), with the reader playing again. The pause leaves a held fade
    /// alone, so the move stops it itself: the timer ends, "Starting: C" and the
    /// fade sentence are said, C plays, and no hold is left (Y1).
    func testAMoveEndsTheFadeOfTheReadersOwnTimerHeldForAnotherBook() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("OwnFadeHeldElsewhere")
        folder.world.settings.nextBookWindow = .newWindow
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.second, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        startOneMinuteSleepTimer(for: old, fade: 5)
        // An earlier move only opened A Volume: held and asked, with no request.
        XCTAssertTrue(timer.hold(forBook: folder.first.id, from: old.readerID))
        timer.markAsked(forBook: folder.first.id)
        timer._expireForTesting()
        XCTAssertTrue(timer.isFadingOut)
        old.isWhereAmIResumePending = true

        let recorder = recordingAnnouncements { old.goThroughFolder(.down) }

        XCTAssertFalse(timer.isActive, "The fade ran on after the move")
        XCTAssertFalse(timer.isHolding, "A hold was left")
        XCTAssertEqual(
            recorder.announcements,
            [
                VoiceOverAnnouncement(message: "Starting: C Volume", priority: .high),
                VoiceOverAnnouncement(message: SleepTimerHandOverWording.fadeEndedByTheMove, priority: .medium),
            ]
        )
        XCTAssertTrue(eventually { folder.world.autoplayRequests.hasRequest(for: folder.third.id) })
        let next = makeReader(for: folder.third, in: folder.world, switcher: switcher, inOwnWindow: true)
        XCTAssertTrue(eventually(within: 15) { next.isCurrentlyPlaying }, "The book moved to never played")
        XCTAssertFalse(timer.isActive, "The old window's timer ran on after it was ended")
        XCTAssertFalse(next.sleepTimerService.isActive, "The book moved to took a timer that was ended")
    }

    /// A request made later for the book a move asked for, by another window's
    /// move, is not the first move's: once that book had claimed its request
    /// the first move is over, and a later move from the old window does not
    /// discard the new request or count itself as playing (Y2).
    func testARequestMadeLaterForTheSameBookDoesNotReviveAClaimedMove() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("ClaimedNotRevived")
        folder.world.settings.nextBookWindow = .newWindow
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.second, in: folder.world, switcher: switcher)
        old.sleepTimerService.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        old.isWhereAmIResumePending = true
        old.goThroughFolder(.down)
        XCTAssertTrue(eventually { folder.world.autoplayRequests.hasRequest(for: folder.third.id) })
        let claimed = makeReader(for: folder.third, in: folder.world, switcher: switcher, inOwnWindow: true)
        XCTAssertTrue(eventually(within: 15) { claimed.isCurrentlyPlaying })
        claimed.close()
        // Another window's move makes a new request for the same book.
        _ = folder.world.autoplayRequests.request(for: folder.third.id, from: UUID())

        let recorder = recordingAnnouncements { old.goThroughFolder(.up) }

        XCTAssertTrue(
            folder.world.autoplayRequests.hasRequest(for: folder.third.id),
            "A request another move made was discarded as the first move's"
        )
        XCTAssertTrue(recorder.announcements.contains { $0.message == "Opening: A Volume" })
        XCTAssertFalse(recorder.announcements.contains { $0.message.hasPrefix("Starting") })
    }

    /// The hold an asked move made is undone while the timer fades out, with
    /// the request still waiting: the later move discards the request, ends the
    /// fade and the timer, and says so, and the book first moved to neither
    /// plays nor takes anything when it loads (Y3).
    func testAnAskedHoldUndoneWhileItFadesEndsTheFadeWithTheMove() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("AskedHoldFades")
        folder.world.settings.nextBookWindow = .newWindow
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.second, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        startOneMinuteSleepTimer(for: old, fade: 5)
        old.isWhereAmIResumePending = true
        old.goThroughFolder(.down)
        XCTAssertTrue(eventually { folder.world.autoplayRequests.hasRequest(for: folder.third.id) })
        XCTAssertTrue(timer.isAsked(forBook: folder.third.id))
        let loading = makeLoadingReader(for: folder.third, in: folder.world, switcher: switcher, inOwnWindow: true)
        timer._expireForTesting()
        XCTAssertTrue(timer.isFadingOut)

        let recorder = recordingAnnouncements { old.goThroughFolder(.up) }

        XCTAssertFalse(timer.isActive, "The fade ran on after the move")
        XCTAssertFalse(timer.isHolding)
        XCTAssertFalse(folder.world.autoplayRequests.hasRequest(for: folder.third.id))
        XCTAssertEqual(
            recorder.announcements,
            [
                VoiceOverAnnouncement(message: "Starting: A Volume", priority: .high),
                VoiceOverAnnouncement(message: SleepTimerHandOverWording.fadeEndedByTheMove, priority: .medium),
            ]
        )
        heldLoadQueue?.activate()
        waitForReaderToLoad(loading)
        XCTAssertFalse(loading.isCurrentlyPlaying, "The cancelled book played")
    }

    /// A second move after an "Opening" move, with a timer: the book only
    /// opened is not playing, so nothing is cancelled; the timer's hold moves
    /// to the book the second move opens.
    func testASecondMoveAfterAnOpeningMoveMovesTheHold() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("OpeningThenOpening")
        folder.world.settings.nextBookWindow = .newWindow
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.second, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        old.goThroughFolder(.down)
        XCTAssertTrue(eventually { timer.isAsked(forBook: folder.third.id) }, "The first move never asked")

        let recorder = recordingAnnouncements { old.goThroughFolder(.up) }

        XCTAssertTrue(recorder.announcements.contains { $0.message == "Opening: A Volume" })
        XCTAssertTrue(timer.isHeld(forBook: folder.first.id), "The second move did not hold the timer")
        XCTAssertFalse(timer.isHeld(forBook: folder.third.id), "The first move's hold was left")
        XCTAssertEqual(timer.ownerID, old.readerID)
        XCTAssertTrue(timer.isActive)
    }

    /// The mark that a timer ran out for a book is cleared when the book's
    /// reader is released or closed: a later move to that book, with no timer
    /// started since, plays it.
    func testTheRunOutMarkDoesNotOutliveTheMoveItWasMadeFor() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("MarkCleared")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        timer.start(duration: .minutes(1), ownerID: old.readerID, onExpire: {})
        XCTAssertTrue(timer.hold(forBook: folder.second.id, from: old.readerID))
        timer._expireForTesting()
        XCTAssertEqual(timer.expiredWhileHeldBookID, folder.second.id)

        timer.releaseHeld(forBook: folder.second.id)

        XCTAssertNil(timer.expiredWhileHeldBookID, "The mark outlived the release")
        _ = folder.world.autoplayRequests.request(for: folder.second.id, from: folder.first.id)
        let later = makeReader(for: folder.second, in: folder.world, switcher: switcher, inOwnWindow: true)
        XCTAssertTrue(eventually(within: 15) { later.isCurrentlyPlaying }, "A later move to the book did not play it")
    }

    /// A target still loading passes the hold on with a move, and a move that
    /// cancels it returns the timer to how it was: held for the target again,
    /// asked as before, and the target takes it when its load ends.
    func testACancelledMoveFromALoadingTargetHoldsTheTimerForItAgain() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("PassedOnThenCancelled")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        XCTAssertTrue(timer.hold(forBook: folder.second.id, from: old.readerID))
        timer.markAsked(forBook: folder.second.id)
        _ = folder.world.autoplayRequests.request(for: folder.second.id, from: folder.first.id)
        let target = makeLoadingReader(for: folder.second, in: folder.world, switcher: switcher, inOwnWindow: true)

        // The move announces itself, as `showNextBook`'s half second does.
        target.noteMoveAnnounced(to: folder.third.id)
        XCTAssertTrue(timer.isHeld(forBook: folder.third.id), "The loading target did not pass the hold on")
        XCTAssertFalse(timer.isHeld(forBook: folder.second.id))
        target.cancelPendingMoves()

        XCTAssertTrue(timer.isHeld(forBook: folder.second.id), "The cancelled move left the hold for its own book undone")
        XCTAssertTrue(timer.isAsked(forBook: folder.second.id), "The hold is not asked as it was")
        XCTAssertFalse(timer.isHeld(forBook: folder.third.id))
        heldLoadQueue?.activate()
        waitForReaderToLoad(target)
        XCTAssertEqual(
            target.sleepTimerService.ownerID, target.readerID, "The target did not take the timer when it loaded"
        )
        XCTAssertFalse(timer.isActive, "The old window's timer ran on beside the one carried to the target's window")
    }

    /// A timer held for a book that nothing ever takes is stopped at the
    /// deadline, as a last resort, and the listener is told after current
    /// speech.
    func testAHeldTimerNobodyTakesIsStoppedAtTheDeadline() throws {
        preserveSleepTimers()
        // A window's timer with no reader to show it.
        let timer = SleepTimerService()
        let owner = UUID()
        let book = UUID()
        timer.start(duration: .minutes(30), ownerID: owner, onExpire: {})
        XCTAssertTrue(timer.hold(forBook: book, from: owner, deadline: 0.2))

        let recorder = recordingAnnouncements {
            XCTAssertTrue(eventually(within: 5) { !timer.isActive }, "The deadline never stopped the timer")
        }

        XCTAssertFalse(timer.isHeld(forBook: book))
        XCTAssertEqual(
            recorder.announcements,
            [VoiceOverAnnouncement(message: SleepTimerHandOverWording.noBook, priority: .medium)]
        )
    }

    /// The window of the book a timer is held for closes before the book
    /// loaded: the timer is stopped without a word, as closing the window a
    /// timer belongs to stops it, rather than left with a book that will never
    /// play, and the mark that it ran out for that book goes with it.
    func testClosingTheTargetsWindowBeforeItLoadsReleasesTheTimer() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("TargetCloses")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        let loading = makeLoadingReader(for: folder.second, in: folder.world, switcher: switcher, inOwnWindow: true)
        old.holdSleepTimer(forBook: folder.second.id)
        XCTAssertTrue(timer.isHeld(forBook: folder.second.id), "The loading reader took the timer")

        let recorder = recordingAnnouncements {
            loading.close()
            spinMainRunLoop(for: 0.5)
        }

        XCTAssertFalse(timer.isActive, "The timer went on counting with no book to pause")
        XCTAssertEqual(recorder.announcements, [], "Closing a window said the book could not be opened")
        XCTAssertNil(timer.expiredWhileHeldBookID)
    }

    /// The Library refuses to open the book a timer is held for: the timer is
    /// released with the book's other requests.
    func testARefusedOpenReleasesTheTimer() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("RefusedOpen")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        old.holdSleepTimer(forBook: folder.second.id)

        ReaderOpenRefusal.dropRequests(for: .openBookWindow(folder.second.id))

        XCTAssertFalse(timer.isActive, "A refused open left the timer counting")
        XCTAssertFalse(timer.isHeld(forBook: folder.second.id))
    }

    /// A book deleted since the window was asked for opens as a placeholder
    /// with an ID of its own: the timer held for the book asked for is
    /// released, not left for a reader that will never come.
    func testAPlaceholderForADeletedBookReleasesTheTimer() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("DeletedBook")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = old.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        let deleted = UUID()
        XCTAssertTrue(timer.hold(forBook: deleted, from: old.readerID))
        let placeholder = Book(title: "Unknown", format: .txt, filePath: "", md5Hash: "")

        var stoppedAtOnce = false
        var reader: ReaderViewModel?
        let recorder = recordingAnnouncements {
            // Stores and a center of the test's own, not the app's.
            reader = BookReaderWindowView.makeReader(
                book: placeholder,
                libraryViewModel: folder.world.library,
                settingsViewModel: folder.world.settings,
                showBook: nil,
                requestedBookID: deleted,
                autoplayRequests: ReaderAutoplayRequests(),
                readingListRequests: ReadingListOpenRequests(),
                windowSwitchRequests: WindowSwitchRequests(),
                notificationCenter: folder.world.notifications,
                sleepTimer: SleepTimerService()
            )
            // True at once, the sentence waits for the error view's reason.
            stoppedAtOnce = !timer.isActive
            XCTAssertTrue(
                SleepTimerHandOverWording.afterTheReason > 1.2,
                "The sentence would come before the error view's own focus reads the reason"
            )
            spinMainRunLoop(for: SleepTimerHandOverWording.afterTheReason + 1)
        }
        if let reader {
            addTeardownBlock { reader.close() }
        }

        XCTAssertTrue(stoppedAtOnce, "The timer was left held for a book that is gone")
        XCTAssertFalse(timer.isHeld(forBook: deleted))
        XCTAssertEqual(
            recorder.announcements.filter { $0.message == SleepTimerHandOverWording.noBook },
            [VoiceOverAnnouncement(message: SleepTimerHandOverWording.noBook, priority: .medium)],
            "The sentence is said once, after current speech"
        )
    }

    /// The listener closes the window in the half second between "Starting"
    /// and the request: the hand-over goes on as announced, in a new window,
    /// and the closed reader calls no switcher.
    func testAHandOverAfterTheReaderClosedPostsAsBefore() throws {
        let folder = try makeFolderWorld("EndClosed")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let asked = record(.continueToNextBook, in: folder.world)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)

        reader.handleEndOfBook()
        reader.close()
        XCTAssertTrue(reader.switchingTheWindowCouldLoseWork)
        XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book")

        XCTAssertEqual(asked().map(\.nextBookID), [folder.second.id])
        XCTAssertTrue(switcher.shown.isEmpty, "A closed reader switched a window that is gone")
        XCTAssertFalse(reader.hasSwitchedWindow)
    }

    /// A reader reaching a book already open in another window brings that
    /// window forward, as before, and does not switch this one.
    func testABookAlreadyOpenElsewhereIsBroughtForward() throws {
        let folder = try makeFolderWorld("EndAlreadyOpen")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let asked = record(.continueToNextBook, in: folder.world)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        // Open in a window of its own, with a timer of its own.
        _ = folder.world.openReader(for: folder.second, sleepTimer: SleepTimerService())
        XCTAssertTrue(folder.world.library.openBookIDs.contains(folder.second.id))

        reader.handleEndOfBook()
        XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book")

        XCTAssertEqual(asked().map(\.nextBookID), [folder.second.id])
        XCTAssertTrue(switcher.shown.isEmpty, "Replaced a book that is open in another window")
    }

    /// A reader with no switcher, as in any test of the old behavior, opens
    /// a new window whatever the setting says.
    func testAReaderWithNoSwitcherOpensANewWindow() throws {
        let folder = try makeFolderWorld("EndNoSwitcher")
        let asked = record(.continueToNextBook, in: folder.world)
        let reader = folder.world.openReader(for: folder.first, sleepTimer: SleepTimerService())
        waitForReaderToLoad(reader)

        reader.handleEndOfBook()
        XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book")
        XCTAssertEqual(asked().map(\.nextBookID), [folder.second.id])
    }

    // MARK: - The Reading List

    /// Next in Reading List, from a book not playing, follows the global
    /// setting even in a folder with a choice of its own: with This Window it
    /// switches, after the reading-list request, and posts nothing.
    func testNextInReadingListFollowsTheGlobalSetting() throws {
        let folder = try makeFolderWorld("ListSwitch", options: ListeningOptions(
            continuation: .playBookBelow, nextBookWindow: .newWindow
        ))
        let world = folder.world
        world.library.library.readingList = ReadingList(
            bookIDs: [folder.first.id, folder.second.id], continuation: .playBookBelow, skipsFinished: true
        )
        let requests = ReadingListOpenRequests()
        requests.request(for: folder.first.id)
        let switcher = SwitchRecorder(requests: world.autoplayRequests, readingListRequests: requests)
        let opened = record(.openBookWindow, in: world)
        let reader = makeReader(for: folder.first, in: world, switcher: switcher, readingListRequests: requests)
        XCTAssertTrue(reader.isOpenedFromReadingList)

        let recorder = recordingAnnouncements {
            reader.goThroughReadingList(.down)
            XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "Never switched")
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Opening: B Volume"])
        XCTAssertEqual(switcher.shown, [folder.second.id])
        XCTAssertEqual(switcher.readingListRequestWaitingAtTheSwitch, [true], "The request came after the switch")
        XCTAssertTrue(opened().isEmpty)
    }

    /// With A New Window, Next in Reading List posts as before.
    func testNextInReadingListWithANewWindowPostsAsBefore() throws {
        let folder = try makeFolderWorld("ListNewWindow")
        let world = folder.world
        world.settings.nextBookWindow = .newWindow
        world.library.library.readingList = ReadingList(
            bookIDs: [folder.first.id, folder.second.id], continuation: .playBookBelow, skipsFinished: true
        )
        let requests = ReadingListOpenRequests()
        requests.request(for: folder.first.id)
        let switcher = SwitchRecorder(requests: world.autoplayRequests, readingListRequests: requests)
        let opened = record(.openBookWindow, in: world)
        let reader = makeReader(for: folder.first, in: world, switcher: switcher, readingListRequests: requests)

        reader.goThroughReadingList(.down)
        XCTAssertTrue(eventually { !opened().isEmpty }, "Never opened the next book")

        XCTAssertEqual(opened().map { $0.object as? UUID }, [folder.second.id])
        XCTAssertTrue(switcher.shown.isEmpty)
    }

    // MARK: - Next and Previous in Folder

    /// Next in Folder, from a book not playing, opens the book below it:
    /// "Opening: <title>", then its window alone is asked for, with no
    /// request to play it and none to read it from the reading list.
    func testNextInFolderOpensTheBookBelowWithANewWindow() throws {
        let folder = try makeFolderWorld("FolderNextNew")
        folder.world.settings.nextBookWindow = .newWindow
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let asked = record(.continueToNextBook, in: folder.world)
        let opened = record(.openBookWindow, in: folder.world)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)

        let recorder = recordingAnnouncements {
            reader.goThroughFolder(.down)
            XCTAssertTrue(opened().isEmpty, "Opened before the announcement had a moment")
            XCTAssertTrue(eventually { !opened().isEmpty }, "Never opened the next book")
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Opening: B Volume"])
        XCTAssertEqual(opened().map { $0.object as? UUID }, [folder.second.id])
        XCTAssertTrue(asked().isEmpty, "Asked for the next book to start")
        XCTAssertFalse(folder.world.autoplayRequests.hasRequest(for: folder.second.id))
        XCTAssertTrue(switcher.shown.isEmpty)
    }

    /// With This Window the same command switches the window instead.
    func testNextInFolderSwitchesThisWindow() throws {
        let folder = try makeFolderWorld("FolderNextSwitch")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let opened = record(.openBookWindow, in: folder.world)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)

        reader.goThroughFolder(.down)
        XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "Never switched")

        XCTAssertEqual(switcher.shown, [folder.second.id])
        XCTAssertTrue(opened().isEmpty)
    }

    /// Previous in Folder opens the book above.
    func testPreviousInFolderOpensTheBookAbove() throws {
        let folder = try makeFolderWorld("FolderPrevious")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let reader = makeReader(for: folder.third, in: folder.world, switcher: switcher)

        let recorder = recordingAnnouncements {
            reader.goThroughFolder(.up)
            XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "Never switched")
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Opening: B Volume"])
        XCTAssertEqual(switcher.shown, [folder.second.id])
    }

    /// At either end the command says so, and changes nothing.
    func testTheEndsOfTheFolderSayNoMoreBooks() throws {
        let folder = try makeFolderWorld("FolderEnds")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let opened = record(.openBookWindow, in: folder.world)
        let last = makeReader(for: folder.third, in: folder.world, switcher: switcher)
        let first = makeReader(for: folder.first, in: folder.world, switcher: switcher, inOwnWindow: true)

        let down = recordingAnnouncements { last.goThroughFolder(.down) }
        let up = recordingAnnouncements { first.goThroughFolder(.up) }
        spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)

        XCTAssertEqual(down.announcements.map(\.message), ["No more books in folder."])
        XCTAssertEqual(up.announcements.map(\.message), ["No more books in folder."])
        XCTAssertTrue(switcher.shown.isEmpty)
        XCTAssertTrue(opened().isEmpty)
    }

    /// A finished book is passed over while the folder skips finished books,
    /// and visited when it does not; with only finished books beyond, the
    /// command says why.
    func testFinishedBooksArePassedOverAsTheFolderSays() throws {
        let folder = try makeFolderWorld("FolderFinished")
        markFinished(folder.second, in: folder.world)
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)

        reader.goThroughFolder(.down)
        XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "Never switched")
        XCTAssertEqual(switcher.shown, [folder.third.id], "went to the finished book")

        // The folder's own options keep finished books in the way.
        setFolderOptions(ListeningOptions(skipsFinished: false), in: folder.world)
        reader.goThroughFolder(.down)
        XCTAssertTrue(eventually { switcher.shown.count == 2 }, "Never switched the second time")
        XCTAssertEqual(switcher.shown.last, folder.second.id)

        // Only a finished book lies below the second one.
        markFinished(folder.third, in: folder.world)
        setFolderOptions(nil, in: folder.world)
        let middle = makeReader(for: folder.second, in: folder.world, switcher: switcher, inOwnWindow: true)
        let said = recordingAnnouncements { middle.goThroughFolder(.down) }
        XCTAssertEqual(said.announcements.map(\.message), ["Every book after it in the folder is finished."])
    }

    /// Next in Folder from a book that plays pauses it, says "Starting", and
    /// asks for the book below to play, after the request, in this window.
    func testNextInFolderFromAPlayingBookStartsTheBookBelow() throws {
        let folder = try makeFolderWorld("FolderPlaying")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        reader.play()
        XCTAssertTrue(eventually(within: 15) { reader.audioPlaybackService.isPlaying }, "The book did not play")

        let recorder = recordingAnnouncements {
            reader.goThroughFolder(.down)
            XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "Never switched")
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: B Volume"])
        XCTAssertTrue(reader.audioPlaybackService.isPaused, "This book was not paused")
        XCTAssertEqual(switcher.shown, [folder.second.id])
        XCTAssertEqual(switcher.requestWaitingAtTheSwitch, [true], "The request to play came after the switch")
    }

    /// The folder's own choice of window decides the command's window, and a
    /// dimmed choice, with items that do not go on, does not.
    func testTheCommandFollowsTheFoldersChoiceWhileItIsInEffect() throws {
        let folder = try makeFolderWorld("FolderChoice", options: ListeningOptions(
            continuation: .playBookBelow, nextBookWindow: .newWindow
        ))
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let opened = record(.openBookWindow, in: folder.world)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)

        reader.goThroughFolder(.down)
        XCTAssertTrue(eventually { !opened().isEmpty }, "Never opened the next book")
        XCTAssertTrue(switcher.shown.isEmpty, "The folder's choice of a new window was not followed")

        // Stop dims the choice, so the global This Window decides.
        setFolderOptions(ListeningOptions(continuation: .stop, nextBookWindow: .newWindow), in: folder.world)
        reader.goThroughFolder(.down)
        XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "A dimmed choice was followed")
    }

    /// Returns `book` with no end behavior of its own, so its feed's or
    /// folder's options decide how its end goes on (the folder world's books
    /// each end with Continue to Next Book of their own, which goes down).
    private func followingItsFolder(_ book: Book) -> Book {
        var copy = book
        copy.localEndOfBookBehavior = nil
        return copy
    }

    /// Next in Folder goes the way the end of the book would go on: up in a
    /// folder that plays the book above, down otherwise, Stop included;
    /// Previous in Folder goes the other way.
    func testNextInFolderFollowsTheListeningDirection() throws {
        let folder = try makeFolderWorld("FolderDirection", options: ListeningOptions(continuation: .playBookAbove))
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let reader = makeReader(for: followingItsFolder(folder.second), in: folder.world, switcher: switcher)

        reader.goThroughFolder(.down)
        XCTAssertTrue(eventually { switcher.shown.count == 1 }, "Next never switched")
        reader.goThroughFolder(.up)
        XCTAssertTrue(eventually { switcher.shown.count == 2 }, "Previous never switched")

        XCTAssertEqual(switcher.shown, [folder.first.id, folder.third.id], "Next went up, Previous went down")
    }

    /// With Stop, or the folder's options playing the book below, Next goes
    /// down and Previous up, as before.
    func testNextInFolderGoesDownWhenTheEndStopsOrPlaysBelow() throws {
        for continuation in [ReadingList.Continuation.stop, .playBookBelow] {
            let folder = try makeFolderWorld("FolderDown \(continuation)", options: ListeningOptions(continuation: continuation))
            let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
            let reader = makeReader(for: followingItsFolder(folder.second), in: folder.world, switcher: switcher)

            reader.goThroughFolder(.down)
            XCTAssertTrue(eventually { switcher.shown.count == 1 }, "Next never switched: \(continuation)")
            reader.goThroughFolder(.up)
            XCTAssertTrue(eventually { switcher.shown.count == 2 }, "Previous never switched: \(continuation)")

            XCTAssertEqual(switcher.shown, [folder.third.id, folder.first.id], "\(continuation)")
        }
    }

    /// What lies that way is said for the way looked: Next in a folder that
    /// plays the book above finds only finished books above, and says
    /// "before it", as the end of a book would.
    func testTheNoteFollowsTheWayLooked() throws {
        let folder = try makeFolderWorld("FolderDirectionNote", options: ListeningOptions(continuation: .playBookAbove))
        markFinished(folder.first, in: folder.world)
        markFinished(folder.second, in: folder.world)
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let reader = makeReader(for: followingItsFolder(folder.third), in: folder.world, switcher: switcher)

        let said = recordingAnnouncements { reader.goThroughFolder(.down) }

        XCTAssertEqual(said.announcements.map(\.message), ["Every book before it in the folder is finished."])
        XCTAssertTrue(switcher.shown.isEmpty)
    }

    // MARK: - The Commands

    /// The two commands are listed under Navigation with no keys until the
    /// user gives them some, in the app's scope, each posting its own
    /// notification.
    func testTheFolderCommandsHaveNoKeysUntilGivenSome() {
        XCTAssertEqual(ShortcutAction.nextInFolder.rawValue, "Next in Folder")
        XCTAssertEqual(ShortcutAction.previousInFolder.rawValue, "Previous in Folder")
        for action in [ShortcutAction.nextInFolder, .previousInFolder] {
            XCTAssertEqual(action.title, action.rawValue)
            XCTAssertEqual(action.category, "Navigation", action.rawValue)
            XCTAssertEqual(action.defaultScope, .app, action.rawValue)
            XCTAssertEqual(ShortcutAction.defaultBindings[action], [], action.rawValue)
        }
        XCTAssertEqual(ShortcutAction.nextInFolder.notificationName, .nextInFolder)
        XCTAssertEqual(ShortcutAction.previousInFolder.notificationName, .previousInFolder)
        XCTAssertEqual(Notification.Name.nextInFolder.rawValue, "nextInFolder")
        XCTAssertEqual(Notification.Name.previousInFolder.rawValue, "previousInFolder")
    }

    /// The Navigate menu has both, offered in a reader window alone. SwiftUI
    /// builds the menu where a test cannot read it, so this reads the menu's
    /// source for the items and for the condition that dims them.
    func testTheNavigateMenuOffersThemInReaderWindowsOnly() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TextMouth/App/MenuCommands.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        for name in ["nextInFolder", "previousInFolder"] {
            XCTAssertTrue(text.contains("Button(ShortcutAction.\(name).title)"), name)
            XCTAssertTrue(text.contains("post(name: .\(name), object: nil)"), name)
        }
        // Gated on a scene value the reader's window publishes, so the items
        // stay offered while VoiceOver reads the text, which holds no
        // keyboard focus; a plain focused value would dim them then.
        XCTAssertTrue(text.contains(".disabled(isReaderWindow != true)"))
        XCTAssertFalse(text.contains("activeWindowType != .reader"))
        let view = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TextMouth/Views/Reader/BookReaderWindowView.swift")
        let viewText = try String(contentsOf: view, encoding: .utf8)
        XCTAssertTrue(viewText.contains(".focusedSceneValue(\\.isReaderWindow, true)"))
    }

    /// The notification reaches the key reader and moves it.
    func testTheNotificationsMoveTheReader() throws {
        let folder = try makeFolderWorld("FolderNotification")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let reader = makeReader(for: folder.second, in: folder.world, switcher: switcher)
        _ = reader

        folder.world.notifications.post(name: .previousInFolder, object: nil)
        XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "Previous in Folder did not reach the reader")
        XCTAssertEqual(switcher.shown, [folder.first.id])
    }

    // MARK: - Focus After a Switch

    /// A window to hand a reader, never shown.
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    /// A switch leaves a request for the new reader to see to the window's
    /// focus, with the others and before the switch; the reader that takes
    /// the window over claims it once its window is found, and asks for the
    /// focus once, however often the window is found.
    func testASwitchLeavesAClaimTheNewReaderTakesOnce() throws {
        let folder = try makeFolderWorld("FocusClaim")
        let claims = WindowSwitchRequests()
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests, windowSwitchRequests: claims)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher, windowSwitchRequests: claims)

        old.goThroughFolder(.down)
        XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "Never switched")
        XCTAssertEqual(switcher.windowClaimWaitingAtTheSwitch, [true], "The claim came after the switch")
        XCTAssertTrue(claims.hasRequest(for: folder.second.id))

        let new = makeReader(for: folder.second, in: folder.world, switcher: switcher, windowSwitchRequests: claims)
        var placed: [NSWindow] = []
        new.placeFocusAfterSwitch = { placed.append($0) }
        let window = makeWindow()
        new.attach(to: window)
        new.attach(to: window)

        XCTAssertEqual(placed.count, 1, "The focus was asked for \(placed.count) times")
        XCTAssertTrue(placed.first === window)
        XCTAssertTrue(new.hostWindow === window)
        XCTAssertFalse(claims.hasRequest(for: folder.second.id), "The claim was left waiting")
    }

    /// The focus of a switched window is seen to once the book has loaded, not
    /// when the window is found: the book's own focus trigger runs only then.
    func testAWindowFoundBeforeTheBookLoadedHasItsFocusSeenToAfterTheLoad() throws {
        let folder = try makeFolderWorld("FocusAfterLoad")
        let claims = WindowSwitchRequests()
        claims.request(for: folder.second.id)
        // Inactive until activated, which a second activation leaves alone, so
        // the load is let go however the test ends.
        let held = DispatchQueue(label: "nextbook-held-load", attributes: .initiallyInactive)
        addTeardownBlock { held.activate() }
        let reader = ReaderViewModel(
            book: folder.second,
            libraryViewModel: folder.world.library,
            settingsViewModel: folder.world.settings,
            substitutionService: TextSubstitutionService(rules: []),
            autoplayRequests: folder.world.autoplayRequests,
            windowSwitchRequests: claims,
            notificationCenter: folder.world.notifications,
            loadQueue: held,
            sleepTimer: SleepTimerService()
        )
        addTeardownBlock { reader.close() }
        var placed: [NSWindow] = []
        reader.placeFocusAfterSwitch = { placed.append($0) }
        let window = makeWindow()

        reader.attach(to: window)
        XCTAssertTrue(placed.isEmpty, "The focus was seen to before the book loaded")
        XCTAssertTrue(reader.isLoading)

        held.activate()
        waitForReaderToLoad(reader)
        XCTAssertEqual(placed.count, 1, "The focus was asked for \(placed.count) times after the load")
        XCTAssertTrue(placed.first === window)
    }

    /// A reader opened for a new window finds no claim, and asks for no
    /// focus: a new window places its own, as before; and a move that opens a
    /// new window leaves no claim for the book.
    func testAReaderOpenedForANewWindowAsksForNoFocus() throws {
        let folder = try makeFolderWorld("FocusNone")
        folder.world.settings.nextBookWindow = .newWindow
        let claims = WindowSwitchRequests()
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests, windowSwitchRequests: claims)
        let opened = record(.openBookWindow, in: folder.world)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher, windowSwitchRequests: claims)

        old.goThroughFolder(.down)
        XCTAssertTrue(eventually { !opened().isEmpty }, "Never opened the next book")
        XCTAssertFalse(claims.hasRequest(for: folder.second.id), "A new window left a claim")

        let new = makeReader(
            for: folder.second, in: folder.world, switcher: switcher, windowSwitchRequests: claims, inOwnWindow: true
        )
        var placed: [NSWindow] = []
        new.placeFocusAfterSwitch = { placed.append($0) }
        new.attach(to: makeWindow())
        XCTAssertTrue(placed.isEmpty, "A reader opened for a new window asked for the focus")
    }

    /// A reader that has closed claims nothing.
    func testAClosedReaderTakesNoClaim() throws {
        let folder = try makeFolderWorld("FocusClosed")
        let claims = WindowSwitchRequests()
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests, windowSwitchRequests: claims)
        let reader = makeReader(for: folder.second, in: folder.world, switcher: switcher, windowSwitchRequests: claims)
        claims.request(for: folder.second.id)
        var placed: [NSWindow] = []
        reader.placeFocusAfterSwitch = { placed.append($0) }
        reader.close()

        reader.attach(to: makeWindow())

        XCTAssertTrue(placed.isEmpty)
    }

    // MARK: - Teardown Against Start

    /// The reader moved from closes without touching the media session of the
    /// reader that took over: its owner stays the active one.
    func testTheOldReadersCloseLeavesTheNewReadersMediaSessionAlone() throws {
        let folder = try makeFolderWorld("Teardown")
        let coordinator = NowPlayingService(installsSystemIntegrations: false, diagnosticSink: { _ in })
        let old = folder.world.openReader(for: folder.first, nowPlaying: coordinator, sleepTimer: SleepTimerService())
        let new = folder.world.openReader(for: folder.second, nowPlaying: coordinator, sleepTimer: SleepTimerService())
        waitForReaderToLoad(old)
        waitForReaderToLoad(new)
        new.windowBecameKey()
        XCTAssertEqual(coordinator.activeOwnerID, new.readerID)

        old.close()

        XCTAssertEqual(coordinator.activeOwnerID, new.readerID, "The old reader's close took the new reader's session")
        XCTAssertTrue(folder.world.library.openBookIDs.contains(folder.second.id))
        XCTAssertFalse(folder.world.library.openBookIDs.contains(folder.first.id))
    }

    // MARK: - Helpers

    /// A folder of three silent audiobooks, "A Volume", "B Volume", and "C
    /// Volume", in a world whose global "When book ends" is Continue to Next
    /// Book, so each ends into the next; the folder has `options`.
    struct FolderWorld {
        let world: IntegrationWorld
        let first: Book
        let second: Book
        let third: Book
    }

    private func makeFolderWorld(_ label: String, options: ListeningOptions? = nil) throws -> FolderWorld {
        let world = try makeIntegrationWorld(label)
        // Titles order the books in their folder; the folder's own row holds
        // the options, set directly so nothing is saved.
        let titles = ["A Volume", "B Volume", "C Volume"]
        var books: [Book] = []
        for title in titles {
            // Longer than any test runs, so no chapter ends by itself.
            books.append(try world.makeSilentAudioBook(title: title, trackDurations: [5, 5], endOfBook: .continueNext))
        }
        var row = BookFolder(name: world.folder.path)
        row.listeningOptions = options
        world.library.library.folders = [row]
        world.settings.endOfBookBehavior = .continueNext
        return FolderWorld(world: world, first: books[0], second: books[1], third: books[2])
    }

    /// Gives the world's folder `options`, as library.json holds them
    /// (nothing is saved), or none for nil; fails the test when the world has
    /// no such folder.
    private func setFolderOptions(
        _ options: ListeningOptions?,
        in world: IntegrationWorld,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let index = world.library.library.folders.firstIndex(where: { $0.fullPath == world.folder.path }) else {
            return XCTFail("The world has no folder row", file: file, line: line)
        }
        world.library.library.folders[index].listeningOptions = options
    }

    /// Makes `book`'s row in `world`'s library rest at its end, as a book
    /// that played to its end does (`Book.restsAtEnd`): its place at the
    /// last character of a measured total.
    private func markFinished(_ book: Book, in world: IntegrationWorld) {
        guard let index = world.library.library.books.firstIndex(where: { $0.id == book.id }) else {
            return XCTFail("\(book.title) is not in the library")
        }
        world.library.library.books[index].totalCharacterCount = 100
        world.library.library.books[index].readingPosition = ReadingPosition(
            chapterIndex: 0, characterOffset: 100, globalCharacterOffset: 100
        )
        XCTAssertTrue(world.library.library.books[index].restsAtEnd, "\(book.title) does not rest at its end")
    }

    /// The sleep timer of the window a reader made for `switcher` is in.
    ///
    /// Each reader window has a timer of its own (November 13, 2026), kept
    /// above the books it shows. `switcher` stands for one window, so the
    /// readers made with it, one after another as the window switches, share
    /// its timer. A reader in a window of its own (a book opened from the
    /// Library, a second window of a book, the next book in a new window, a
    /// book open in another window) has a timer of its own.
    ///
    /// - Parameters:
    ///   - switcher: The window the reader is in, unless it is in its own.
    ///   - inOwnWindow: Whether the reader is in a window of its own.
    private func windowTimer(for switcher: SwitchRecorder, inOwnWindow: Bool) -> SleepTimerService {
        inOwnWindow ? SleepTimerService() : switcher.sleepTimer
    }

    /// A reader for `book` in `folder`'s world, loaded, with `switcher` as
    /// its window and its window on screen. It is closed when the test ends.
    /// It shares `switcher`'s window's sleep timer, as the next book of a
    /// window that switched in place does, unless `inOwnWindow` puts it in a
    /// window of its own, with a timer of its own.
    private func makeReader(
        for book: Book,
        in world: IntegrationWorld,
        switcher: SwitchRecorder,
        readingListRequests: ReadingListOpenRequests? = nil,
        windowSwitchRequests: WindowSwitchRequests = WindowSwitchRequests(),
        inOwnWindow: Bool = false
    ) -> ReaderViewModel {
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: world.library,
            settingsViewModel: world.settings,
            substitutionService: TextSubstitutionService(rules: []),
            autoplayRequests: world.autoplayRequests,
            readingListRequests: readingListRequests,
            windowSwitchRequests: windowSwitchRequests,
            notificationCenter: world.notifications,
            sleepTimer: windowTimer(for: switcher, inOwnWindow: inOwnWindow)
        )
        reader.nextBookWindowSwitcher = { switcher.show($0) }
        reader.windowStandingOverride = .onScreen
        addTeardownBlock { reader.close() }
        waitForReaderToLoad(reader)
        return reader
    }

    /// Starts `reader`'s window's sleep timer for `reader` as the reader does,
    /// with its handlers, counting 1 minute and fading out for `fade` seconds.
    private func startOneMinuteSleepTimer(for reader: ReaderViewModel, fade: TimeInterval) {
        let handlers = reader.makeSleepTimerHandlers(fadeOutDuration: fade)
        reader.sleepTimerService.start(
            duration: .minutes(1),
            ownerID: reader.readerID,
            onExpire: handlers.onExpire,
            onFadeStep: handlers.onFadeStep,
            onFadeCancelled: handlers.onFadeCancelled,
            fadeOutDuration: fade
        )
    }

    /// The queue holding the load of the reader `makeLoadingReader` made last:
    /// a test lets the load go with `activate()`, which a second activation
    /// leaves alone.
    private var heldLoadQueue: DispatchQueue?

    /// A reader for `book` in `world` whose load is held, as a book that takes
    /// a long time to open is: it has not loaded, so it has taken no sleep
    /// timer. `switcher` is its window and its window is on screen. Its load
    /// is let go (`heldLoadQueue`), and it is closed, when the test ends.
    ///
    /// - Parameters:
    ///   - autoplayRequests: The requests it claims from, the world's unless a
    ///     test gives it a store with a clock of its own.
    ///   - inOwnWindow: Whether it is in a window of its own, with a sleep
    ///     timer of its own, and not in `switcher`'s window sharing its timer
    ///     (`windowTimer(for:inOwnWindow:)`).
    private func makeLoadingReader(
        for book: Book,
        in world: IntegrationWorld,
        switcher: SwitchRecorder,
        autoplayRequests: ReaderAutoplayRequests? = nil,
        inOwnWindow: Bool = false
    ) -> ReaderViewModel {
        // Inactive until activated, which a second activation leaves alone, so
        // the load is let go however the test ends.
        let held = DispatchQueue(label: "nextbook-held-load", attributes: .initiallyInactive)
        heldLoadQueue = held
        addTeardownBlock { held.activate() }
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: world.library,
            settingsViewModel: world.settings,
            substitutionService: TextSubstitutionService(rules: []),
            autoplayRequests: autoplayRequests ?? world.autoplayRequests,
            windowSwitchRequests: WindowSwitchRequests(),
            notificationCenter: world.notifications,
            loadQueue: held,
            sleepTimer: windowTimer(for: switcher, inOwnWindow: inOwnWindow)
        )
        reader.nextBookWindowSwitcher = { switcher.show($0) }
        reader.windowStandingOverride = .onScreen
        addTeardownBlock { reader.close() }
        return reader
    }

    /// Records every notification named `name` posted on `world`'s center,
    /// returning a function that reads them.
    private func record(_ name: Notification.Name, in world: IntegrationWorld) -> () -> [Notification] {
        var posted: [Notification] = []
        world.notifications.publisher(for: name)
            .sink { posted.append($0) }
            .store(in: &subscriptions)
        return { posted }
    }
}

/// A stand-in for a reader window and its switch: records each book shown,
/// and whether the requests for it were waiting at that moment. It holds the
/// window's sleep timer, which every reader of the window shares, one after
/// another as the window switches (November 13, 2026).
@MainActor
private final class SwitchRecorder {
    /// The window's sleep timer, given to the readers made for this window.
    let sleepTimer = SleepTimerService()
    /// The books shown, in order.
    private(set) var shown: [UUID] = []
    /// For each switch, whether the autoplay request for the book waited.
    private(set) var requestWaitingAtTheSwitch: [Bool] = []
    /// For each switch, whether the reading-list request for the book waited.
    private(set) var readingListRequestWaitingAtTheSwitch: [Bool] = []
    /// For each switch, whether the request for the new reader to see to the
    /// window's focus waited.
    private(set) var windowClaimWaitingAtTheSwitch: [Bool] = []
    private let requests: ReaderAutoplayRequests
    private let readingListRequests: ReadingListOpenRequests?
    private let windowSwitchRequests: WindowSwitchRequests?

    init(
        requests: ReaderAutoplayRequests,
        readingListRequests: ReadingListOpenRequests? = nil,
        windowSwitchRequests: WindowSwitchRequests? = nil
    ) {
        self.requests = requests
        self.readingListRequests = readingListRequests
        self.windowSwitchRequests = windowSwitchRequests
    }

    /// Notes that the window was asked to show `bookID`.
    func show(_ bookID: UUID) {
        shown.append(bookID)
        requestWaitingAtTheSwitch.append(requests.hasRequest(for: bookID))
        readingListRequestWaitingAtTheSwitch.append(readingListRequests?.hasRequest(for: bookID) ?? false)
        windowClaimWaitingAtTheSwitch.append(windowSwitchRequests?.hasRequest(for: bookID) ?? false)
    }
}

/// A clock a test moves, for the stores whose requests age.
@MainActor
private final class RequestClock {
    private(set) var now = Date()

    /// Moves the clock on by `seconds`.
    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}
