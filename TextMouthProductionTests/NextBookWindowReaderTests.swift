import AppKit
import Combine
import XCTest
@testable import TextMouth

/// A reader going on to the next book shows it in its own window or opens a
/// new one, as the setting says (0.2.5). The window's switch is injected, so
/// no window opens and nothing plays: the readers are of silent audiobooks,
/// ended by `handleEndOfBook()` or moved by the reading list's commands.
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
    /// with its time left as it was. The old reader's close leaves it running,
    /// and the restart gesture's last owner is the new reader.
    func testARunningSleepTimerGoesOnWithASwitchedWindow() throws {
        preserveSharedSleepTimer()
        let folder = try makeFolderWorld("SwitchTimer")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = SleepTimerService.shared
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        let before = timer.remainingSeconds

        old.goThroughFolder(.down)
        XCTAssertTrue(timer.isHeld(forBook: folder.second.id), "The timer was not held from the announcement")
        XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "Never switched")
        XCTAssertEqual(timer.ownerID, old.readerID, "Exactly one owner until the next reader takes the timer")
        XCTAssertTrue(timer.isActive)

        let new = makeReader(for: folder.second, in: folder.world, switcher: switcher)
        XCTAssertEqual(timer.ownerID, new.readerID, "The reader that took the window does not own the timer")
        XCTAssertFalse(timer.isHeld(forBook: folder.second.id), "The hold was left")
        XCTAssertEqual(timer.duration, .minutes(30))
        XCTAssertLessThanOrEqual(timer.remainingSeconds, before)
        XCTAssertGreaterThan(timer.remainingSeconds, before - 60, "The countdown was reset")

        old.close()
        XCTAssertTrue(timer.isActive, "The old reader's close stopped the timer")
        XCTAssertEqual(timer.ownerID, new.readerID)
        XCTAssertEqual(timer.lastOwnerID, new.readerID, "Restart Sleep Timer would go to the closed reader")
    }

    /// The timer goes on in a new window too, as a busy window or A New
    /// Window opens one: the old reader stays open, and the new window's
    /// reader takes the timer when it has loaded.
    func testARunningSleepTimerGoesOnWithANewWindow() throws {
        preserveSharedSleepTimer()
        let folder = try makeFolderWorld("NewWindowTimer")
        folder.world.settings.nextBookWindow = .newWindow
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let opened = record(.openBookWindow, in: folder.world)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = SleepTimerService.shared
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})

        old.goThroughFolder(.down)
        XCTAssertTrue(eventually { !opened().isEmpty }, "Never opened the next book")
        XCTAssertTrue(switcher.shown.isEmpty)
        XCTAssertTrue(timer.isHeld(forBook: folder.second.id))
        XCTAssertEqual(timer.ownerID, old.readerID)

        let new = makeReader(for: folder.second, in: folder.world, switcher: switcher)
        XCTAssertEqual(timer.ownerID, new.readerID)
        XCTAssertTrue(timer.isActive)
    }

    /// A timer fading out is not held for the next book: it is putting the
    /// listener to sleep, and ends listening.
    func testATimerFadingOutIsNotHeld() throws {
        preserveSharedSleepTimer()
        let folder = try makeFolderWorld("FadeTimer")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = SleepTimerService.shared
        timer.start(duration: .minutes(1), ownerID: old.readerID, onExpire: {}, fadeOutDuration: 5)
        timer._expireForTesting()
        XCTAssertTrue(timer.isFadingOut)

        old.holdSleepTimer(forBook: folder.second.id)

        XCTAssertFalse(timer.isHeld(forBook: folder.second.id), "A fading timer was held")
        XCTAssertFalse(old.ownsCarriableSleepTimer)
        XCTAssertTrue(timer.endedListening(ownedBy: old.readerID))
    }

    /// Command-W in the half second between "Starting" and the ask does not
    /// stop the timer: it is held for the next book, which is opened in a new
    /// window as announced, and takes it.
    func testClosingTheWindowBeforeTheAskKeepsTheTimerForTheNextBook() throws {
        preserveSharedSleepTimer()
        let folder = try makeFolderWorld("CloseBeforeAsk")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let opened = record(.openBookWindow, in: folder.world)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = SleepTimerService.shared
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})

        old.goThroughFolder(.down)
        old.close()
        XCTAssertTrue(timer.isActive, "Closing the window stopped the timer")
        XCTAssertEqual(timer.ownerID, old.readerID)
        XCTAssertTrue(eventually { !opened().isEmpty }, "Never opened the next book")
        XCTAssertTrue(switcher.shown.isEmpty, "A closed reader switched a window that is gone")

        let new = makeReader(for: folder.second, in: folder.world, switcher: switcher)
        XCTAssertEqual(timer.ownerID, new.readerID, "The book opened without the timer")
        XCTAssertTrue(timer.isActive)
    }

    /// A second move before the first move's book has loaded passes the
    /// timer on: the book that is still loading counts as playing, goes on to
    /// the next book, and the reader of that book takes the timer and plays.
    func testASecondMoveBeforeTheFirstBookLoadedPassesTheTimerOn() throws {
        preserveSharedSleepTimer()
        let folder = try makeFolderWorld("SecondMove")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let first = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = SleepTimerService.shared
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
        XCTAssertEqual(timer.ownerID, third.readerID, "The last book's reader does not own the timer")
        XCTAssertTrue(eventually(within: 15) { third.isCurrentlyPlaying }, "The last book never played")
    }

    /// Next then Previous within the half second ask once, for the book the
    /// last command went to, and it still plays: the first command's pause
    /// does not turn the second into an open.
    func testNextThenPreviousAsksOnce() throws {
        preserveSharedSleepTimer()
        let folder = try makeFolderWorld("NextThenPrevious")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let reader = makeReader(for: folder.second, in: folder.world, switcher: switcher)
        let timer = SleepTimerService.shared
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

    /// An End of heading timer taken by a finished book that starts over waits
    /// for the heading after its beginning, not for the end of the book: the
    /// heading looked for at its end found none.
    func testAnEndOfHeadingTimerTakenByAFinishedBookWaitsForTheHeadingAfterItsBeginning() throws {
        preserveSharedSleepTimer()
        let folder = try makeFolderWorld("FinishedHeading")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let finished = makeReader(for: folder.second, in: folder.world, switcher: switcher)
        let place = try XCTUnwrap(finished.endOfBookPlace)
        finished.currentChapterIndex = place.chapterIndex
        finished.currentCharacterOffset = place.characterOffset
        finished.hasFinishedBook = true
        SleepTimerService.shared.start(duration: .endOfHeading, ownerID: finished.readerID, onExpire: {})
        finished.refreshSleepTimerHeading()
        XCTAssertNil(finished.sleepTimerNextHeading, "a heading was found after the book's end")

        // Play on a book resting at its end starts it over, as a move onto a
        // finished book does when the folder does not skip it.
        _ = folder.world.autoplayRequests.request(for: folder.second.id, from: folder.first.id)
        finished.claimAutoplayRequest()

        XCTAssertEqual(finished.currentChapterIndex, 0, "the book did not start over")
        XCTAssertEqual(finished.sleepTimerNextHeading?.chapterIndex, 1, "the timer still waits for the book's end")
    }

    /// A timer held for a book that nothing ever takes is stopped at the
    /// deadline, as a last resort, and the listener is told after current
    /// speech.
    func testAHeldTimerNobodyTakesIsStoppedAtTheDeadline() throws {
        preserveSharedSleepTimer()
        let timer = SleepTimerService.shared
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
    /// loaded: the timer is stopped, and the listener is told after current
    /// speech, rather than left with a book that will never play.
    func testClosingTheTargetsWindowBeforeItLoadsReleasesTheTimer() throws {
        preserveSharedSleepTimer()
        let folder = try makeFolderWorld("TargetCloses")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = SleepTimerService.shared
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        let loading = makeLoadingReader(for: folder.second, in: folder.world, switcher: switcher)
        old.holdSleepTimer(forBook: folder.second.id)
        XCTAssertTrue(timer.isHeld(forBook: folder.second.id), "The loading reader took the timer")

        let recorder = recordingAnnouncements {
            loading.close()
        }

        XCTAssertFalse(timer.isActive, "The timer went on counting with no book to pause")
        XCTAssertEqual(
            recorder.announcements,
            [VoiceOverAnnouncement(message: SleepTimerHandOverWording.noBook, priority: .medium)]
        )
    }

    /// The Library refuses to open the book a timer is held for: the timer is
    /// released with the book's other requests.
    func testARefusedOpenReleasesTheTimer() throws {
        preserveSharedSleepTimer()
        let folder = try makeFolderWorld("RefusedOpen")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = SleepTimerService.shared
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
        preserveSharedSleepTimer()
        let folder = try makeFolderWorld("DeletedBook")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let old = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        let timer = SleepTimerService.shared
        timer.start(duration: .minutes(30), ownerID: old.readerID, onExpire: {})
        let deleted = UUID()
        XCTAssertTrue(timer.hold(forBook: deleted, from: old.readerID))
        let placeholder = Book(title: "Unknown", format: .txt, filePath: "", md5Hash: "")

        let reader = BookReaderWindowView.makeReader(
            book: placeholder,
            libraryViewModel: folder.world.library,
            settingsViewModel: folder.world.settings,
            showBook: nil,
            requestedBookID: deleted
        )
        addTeardownBlock { reader.close() }

        XCTAssertFalse(timer.isActive, "The timer was left held for a book that is gone")
        XCTAssertFalse(timer.isHeld(forBook: deleted))
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
        _ = folder.world.openReader(for: folder.second)
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
        let reader = folder.world.openReader(for: folder.first)
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
        let first = makeReader(for: folder.first, in: folder.world, switcher: switcher)

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
        let middle = makeReader(for: folder.second, in: folder.world, switcher: switcher)
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
            loadQueue: held
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

        let new = makeReader(for: folder.second, in: folder.world, switcher: switcher, windowSwitchRequests: claims)
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
        let old = folder.world.openReader(for: folder.first, nowPlaying: coordinator)
        let new = folder.world.openReader(for: folder.second, nowPlaying: coordinator)
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

    /// A reader for `book` in `folder`'s world, loaded, with `switcher` as
    /// its window and its window on screen. It is closed when the test ends.
    private func makeReader(
        for book: Book,
        in world: IntegrationWorld,
        switcher: SwitchRecorder,
        readingListRequests: ReadingListOpenRequests? = nil,
        windowSwitchRequests: WindowSwitchRequests = WindowSwitchRequests()
    ) -> ReaderViewModel {
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: world.library,
            settingsViewModel: world.settings,
            substitutionService: TextSubstitutionService(rules: []),
            autoplayRequests: world.autoplayRequests,
            readingListRequests: readingListRequests,
            windowSwitchRequests: windowSwitchRequests,
            notificationCenter: world.notifications
        )
        reader.nextBookWindowSwitcher = { switcher.show($0) }
        reader.windowStandingOverride = .onScreen
        addTeardownBlock { reader.close() }
        waitForReaderToLoad(reader)
        return reader
    }

    /// A reader for `book` in `world` whose load is held, as a book that takes
    /// a long time to open is: it has not loaded, so it has taken no sleep
    /// timer. `switcher` is its window and its window is on screen. Its load
    /// is let go, and it is closed, when the test ends.
    private func makeLoadingReader(
        for book: Book,
        in world: IntegrationWorld,
        switcher: SwitchRecorder
    ) -> ReaderViewModel {
        let held = DispatchQueue(label: "nextbook-held-load")
        held.suspend()
        addTeardownBlock { held.resume() }
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: world.library,
            settingsViewModel: world.settings,
            substitutionService: TextSubstitutionService(rules: []),
            autoplayRequests: world.autoplayRequests,
            windowSwitchRequests: WindowSwitchRequests(),
            notificationCenter: world.notifications,
            loadQueue: held
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

/// A stand-in for the window's switch: records each book shown, and whether
/// the requests for it were waiting at that moment.
@MainActor
private final class SwitchRecorder {
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
