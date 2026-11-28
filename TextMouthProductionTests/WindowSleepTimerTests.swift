import AppKit
import AVFoundation
import Combine
import SwiftUI
import XCTest
@testable import TextMouth

/// Each reader window has a sleep timer of its own (November 13, 2026). The
/// user: "I noticed that the sleep timer still appeared when going from book
/// to book but playing had it stuck... I want each sleep timer to be
/// refactored to be per book view window not global". And on November 1: "the
/// sleeping timer in particular I would like to move still running to the new
/// book without a new window opening".
///
/// A window here is a stand-in (`TestReaderWindow`): the timer the scene's
/// window content keeps (`ReaderWindowContent`), given to every reader it
/// shows, and a switch to another book in place, which it records; the test
/// then makes the next book's reader in the same window, as SwiftUI does.
/// Nothing is heard: audiobooks are silent tracks, and a text book's one
/// chapter is longer than speech ever renders, so its speech goes to a
/// recorder in place of the synthesizer. Countdowns are moved by hand, and
/// every wait has a limit.
@MainActor
final class WindowSleepTimerTests: XCTestCase {
    /// The registry the test's windows' timers join, so the app's is never
    /// touched.
    private var registry: SleepTimerRegistry!
    /// Where the test's timers keep the duration last used.
    private var preferences: UserDefaults!
    /// The media session the test's readers join.
    private var coordinator: NowPlayingService!
    /// The world the test's books and readers live in.
    private var world: IntegrationWorld!
    /// Every utterance a text book's speech handed over in place of the
    /// synthesizer.
    private var utterances: [AVSpeechUtterance] = []
    /// Subscriptions a test keeps until it ends.
    private var subscriptions = Set<AnyCancellable>()

    override func setUp() async throws {
        try await super.setUp()
        registry = SleepTimerRegistry()
        preferences = makeSandboxedPreferences("window-sleep-timer")
        coordinator = NowPlayingService(installsSystemIntegrations: false, diagnosticSink: { _ in })
        world = try makeIntegrationWorld("Window Sleep Timer")
        world.settings.sleepFadeOutDuration = 0
        world.settings.punctuationPauseLevel = 0
        world.settings.endOfBookBehavior = .continueNext
        world.library.library.folders = [BookFolder(name: world.folder.path)]
        // Registered after the world's, so it runs first: no timer of the
        // test's runs on while the world's readers close.
        addTeardownBlock { [registry] in registry?._stopEveryTimerForTesting() }
    }

    /// Lets go of everything the test made. XCTest keeps every test case
    /// until the whole run ends, so a world left here would keep its readers,
    /// settings, and preference store alive to the host's exit, where the
    /// system then fails to read each removed store and says so in the log,
    /// after the last suite's verdict (GitHub run 43406442692).
    override func tearDown() async throws {
        subscriptions = []
        utterances = []
        heldLoad = nil
        world = nil
        coordinator = nil
        preferences = nil
        registry = nil
        try await super.tearDown()
    }

    // MARK: - The User's Case

    /// The user's case, from their timer log of November 13: a reader holding
    /// a paused timer, 2:40 left, and another book opened beside it, from the
    /// Library, in a window of its own, which the listener plays and pauses.
    /// The other window shows no timer, its Play and Pause leave the first
    /// window's timer as it was, and a timer it sets is its own, which the
    /// first window keeps beside it. For every pair of text and audiobook,
    /// the user's guess, a text book then an audiobook, first.
    ///
    /// On main one timer served the app and showed in every window: the
    /// second reader showed the first's timer, stuck, since its own playback
    /// did not own it, and the timer it set replaced the first's.
    func testABookOpenedBesideAPausedTimerShowsNoTimerAndRunsItsOwn() throws {
        let pairs: [(Kind, Kind)] = [(.text, .audio), (.audio, .text), (.text, .text), (.audio, .audio)]
        for (index, (first, second)) in pairs.enumerated() {
            let cell = "\(first.rawValue) then \(second.rawValue)"
            let a = openReader(for: try makeBook(first, titled: "Opened \(index) A"), in: makeWindow())
            a.startSleepTimer(duration: .minutes(15))
            a.sleepTimerService.remainingSeconds = 160
            a.pause(playingPauseSound: false)
            let shownInA = a.sleepTimerService.spokenLabel
            XCTAssertEqual(shownInA, "Sleep timer: 2:40 remaining", cell)

            let b = openReader(for: try makeBook(second, titled: "Opened \(index) B"), in: makeWindow())

            XCTAssertFalse(b.sleepTimerService.isActive, "\(cell): the other window shows the first window's timer")
            XCTAssertEqual(b.sleepTimerService.spokenLabel, "", "\(cell): the other window's status reads a timer")
            b.play()
            XCTAssertTrue(eventually { b.isPlaybackUnderWay }, "\(cell): the other book never started")
            a.sleepTimerService._advanceCountdownForTesting()
            b.pause(playingPauseSound: false)
            XCTAssertEqual(a.sleepTimerService.remainingSeconds, 160, "\(cell): the other book's playback ran the first's timer")
            XCTAssertEqual(a.sleepTimerService.ownerID, a.readerID, "\(cell)")

            b.startSleepTimer(duration: .minutes(5))

            XCTAssertEqual(b.sleepTimerService.ownerID, b.readerID, "\(cell)")
            XCTAssertEqual(b.sleepTimerService.duration, .minutes(5), "\(cell)")
            XCTAssertTrue(a.sleepTimerService.isActive, "\(cell): the other window's timer replaced the first's")
            XCTAssertEqual(a.sleepTimerService.spokenLabel, shownInA, "\(cell): the first window's timer changed")
            b.stop()
        }
    }

    // MARK: - Two Windows, Two Timers

    /// Two windows each run a timer of their own: each counts only while its
    /// own book plays, pauses with its own playback (one reader plays at a
    /// time, so playing one pauses the other and halts its count), and runs
    /// out only for its own book, which it pauses, saying so once. Each
    /// window's reader shows, and VoiceOver reads, only its own.
    func testTwoWindowsEachCountPauseAndRunOutTheirOwnTimer() throws {
        let windowA = makeWindow()
        let windowB = makeWindow()
        let a = openReader(for: try makeBook(.audio, titled: "Pair A"), in: windowA)
        let b = openReader(for: try makeBook(.audio, titled: "Pair B"), in: windowB)
        a.startSleepTimer(duration: .minutes(10))
        a.pause(playingPauseSound: false)
        b.startSleepTimer(duration: .minutes(20))
        b.pause(playingPauseSound: false)
        XCTAssertTrue(a.sleepTimerService === windowA.sleepTimer)
        XCTAssertTrue(b.sleepTimerService === windowB.sleepTimer)
        XCTAssertFalse(windowA.sleepTimer === windowB.sleepTimer, "The two windows share a timer")
        XCTAssertEqual(a.sleepTimerService.spokenLabel, "Sleep timer: 10:00 remaining")
        XCTAssertEqual(b.sleepTimerService.spokenLabel, "Sleep timer: 20:00 remaining")

        // A counting countdown also ticks on its own clock while a wait spins
        // the run loop, so each check counts from a reading taken just before
        // the hand's ticks, with no wait between them.
        a.play()
        XCTAssertTrue(eventually { a.audioPlaybackService.isPlaying }, "A never played")
        var aBefore = windowA.sleepTimer.remainingSeconds
        tick(windowA, 3)
        tick(windowB, 3)
        XCTAssertEqual(windowA.sleepTimer.remainingSeconds, aBefore - 3, "A's timer did not count while A played")
        XCTAssertEqual(windowB.sleepTimer.remainingSeconds, 1200, "B's timer counted while only A played")

        b.play()
        XCTAssertTrue(eventually { b.audioPlaybackService.isPlaying }, "B never played")
        XCTAssertTrue(a.isCurrentlyPaused, "Playing B did not pause A")
        aBefore = windowA.sleepTimer.remainingSeconds
        let bBefore = windowB.sleepTimer.remainingSeconds
        tick(windowA, 3)
        tick(windowB, 3)
        XCTAssertEqual(windowA.sleepTimer.remainingSeconds, aBefore, "A's timer counted while A was paused")
        XCTAssertEqual(windowB.sleepTimer.remainingSeconds, bBefore - 3, "B's timer did not count while B played")
        let aPaused = windowA.sleepTimer.remainingSeconds

        let bRunsOut = recordingAnnouncements {
            windowB.sleepTimer.remainingSeconds = 1
            tick(windowB, 1)
        }
        XCTAssertEqual(bRunsOut.announcements.map(\.message), [ReaderViewModel.sleepTimerExpiredAnnouncement])
        XCTAssertTrue(b.isCurrentlyPaused, "B's timer ran out without pausing B")
        XCTAssertFalse(windowB.sleepTimer.isActive)
        XCTAssertTrue(windowA.sleepTimer.isActive, "B's timer ran out A's")
        XCTAssertEqual(windowA.sleepTimer.remainingSeconds, aPaused, "B's timer running out moved A's")

        a.play()
        XCTAssertTrue(eventually { a.audioPlaybackService.isPlaying }, "A never played again")
        let aRunsOut = recordingAnnouncements {
            windowA.sleepTimer.remainingSeconds = 1
            tick(windowA, 1)
        }
        XCTAssertEqual(aRunsOut.announcements.map(\.message), [ReaderViewModel.sleepTimerExpiredAnnouncement])
        XCTAssertTrue(a.isCurrentlyPaused, "A's timer ran out without pausing A")
        XCTAssertFalse(b.isPlaybackUnderWay, "A's timer started B")
    }

    /// Closing a window stops its own timer and nothing else: the other
    /// window's timer runs on, still its own.
    func testClosingAWindowStopsItsOwnTimerOnly() throws {
        let windowA = makeWindow()
        let windowB = makeWindow()
        let a = openReader(for: try makeBook(.text, titled: "Close A"), in: windowA)
        let b = openReader(for: try makeBook(.audio, titled: "Close B"), in: windowB)
        a.startSleepTimer(duration: .minutes(10))
        b.startSleepTimer(duration: .endOfHeading)

        a.close()

        XCTAssertFalse(windowA.sleepTimer.isActive, "Closing the window left its timer running")
        XCTAssertTrue(windowB.sleepTimer.isActive, "Closing one window stopped the other's timer")
        XCTAssertEqual(windowB.sleepTimer.ownerID, b.readerID)
        XCTAssertEqual(windowB.sleepTimer.duration, .endOfHeading)
    }

    // MARK: - In Place to the Next Book

    /// A text book's window goes on to an audiobook in place, and its timer
    /// goes on with it, for each kind of timer.
    func testTheTimerGoesOnInPlaceFromATextBookToAnAudiobook() throws {
        try checkTheTimerGoesOnInPlace(from: .text, to: .audio)
    }

    /// An audiobook's window goes on to a text book in place, and its timer
    /// goes on with it, for each kind of timer.
    func testTheTimerGoesOnInPlaceFromAnAudiobookToATextBook() throws {
        try checkTheTimerGoesOnInPlace(from: .audio, to: .text)
    }

    /// A text book's window goes on to another text book in place, and its
    /// timer goes on with it, for each kind of timer.
    func testTheTimerGoesOnInPlaceFromATextBookToATextBook() throws {
        try checkTheTimerGoesOnInPlace(from: .text, to: .text)
    }

    /// An audiobook's window goes on to another audiobook in place, and its
    /// timer goes on with it, for each kind of timer.
    func testTheTimerGoesOnInPlaceFromAnAudiobookToAnAudiobook() throws {
        try checkTheTimerGoesOnInPlace(from: .audio, to: .audio)
    }

    /// A timer a window has as it goes on to another book in place.
    enum InPlaceTimer: String, CaseIterable {
        /// Minutes, counting while the book played: the move's pause halts
        /// the count, and the next book's start resumes it.
        case minutesRunning = "minutes, running"
        /// Minutes, halted while the book was paused: the move only opens
        /// the next book, and the count waits for its Play.
        case minutesPaused = "minutes, paused"
        /// The end of the heading: it waits for the end of the heading the
        /// next book's playback reads in.
        case endOfHeading = "End of heading"
        /// The end of the book: it stops where the next book ends, as a
        /// timer for the end of a book that a command moves from goes on.
        case endOfBook = "End of book"

        /// What the timer waits for.
        var duration: SleepTimerDuration {
            switch self {
            case .minutesRunning, .minutesPaused: return .minutes(30)
            case .endOfHeading: return .endOfHeading
            case .endOfBook: return .endOfBook
            }
        }

        /// Whether the book was playing as the move began, so the move plays
        /// the next one.
        var plays: Bool { self != .minutesPaused }
    }

    /// Moves a window from a book of the kind `from` to a book of the kind
    /// `to` below it in their folder, with Next in Folder, under each
    /// in-place timer, and checks each: the window switches in place, the
    /// old reader's close leaves the timer running, and the next book's
    /// reader, made in the same window, takes the window's own timer, as it
    /// was: minutes keep their time and count once the book plays, End of
    /// heading waits for the end of the heading in the new book, and End of
    /// book for the new book's end.
    private func checkTheTimerGoesOnInPlace(from: Kind, to: Kind, file: StaticString = #filePath, line: UInt = #line) throws {
        for (index, timer) in InPlaceTimer.allCases.enumerated() {
            let cell = "\(from.rawValue) to \(to.rawValue), \(timer.rawValue)"
            let first = try makeBook(from, titled: "In Place \(index) A")
            let second = try makeBook(to, titled: "In Place \(index) B")
            let window = makeWindow()
            let old = openReader(for: first, in: window, file: file, line: line)
            old.startSleepTimer(duration: timer.duration)
            if case .minutes = timer.duration {
                window.sleepTimer.remainingSeconds = 1000
            }
            if timer.plays {
                // Counts as playing, without a sound: a Where Am I?
                // announcement that will play the book again.
                old.isWhereAmIResumePending = true
            } else {
                old.pause(playingPauseSound: false)
            }

            old.goThroughFolder(.down)
            XCTAssertTrue(
                eventually { window.switchedTo == [second.id] },
                "\(cell): the window never switched in place", file: file, line: line
            )
            // The switch takes the old view away, which closes its reader.
            old.close()
            XCTAssertTrue(window.sleepTimer.isActive, "\(cell): the old reader's close stopped the timer", file: file, line: line)
            let next = openReader(for: second, in: window, file: file, line: line)

            XCTAssertTrue(next.sleepTimerService === window.sleepTimer, "\(cell)", file: file, line: line)
            XCTAssertEqual(window.sleepTimer.ownerID, next.readerID, "\(cell): the next book did not take the timer", file: file, line: line)
            XCTAssertEqual(window.sleepTimer.duration, timer.duration, "\(cell)", file: file, line: line)
            XCTAssertFalse(window.sleepTimer.isHolding, "\(cell): the hold outlived the take", file: file, line: line)
            if timer.plays {
                XCTAssertTrue(
                    eventually { next.isPlaybackUnderWay },
                    "\(cell): the next book did not start", file: file, line: line
                )
            }
            switch timer {
            case .minutesRunning:
                let left = window.sleepTimer.remainingSeconds
                XCTAssertTrue(left <= 1000 && left > 1000 - 60, "\(cell): \(left) left, from 1000", file: file, line: line)
                tick(window, 1)
                XCTAssertEqual(window.sleepTimer.remainingSeconds, left - 1, "\(cell): the timer does not count", file: file, line: line)
            case .minutesPaused:
                XCTAssertFalse(next.isPlaybackUnderWay, "\(cell): a book only opened played", file: file, line: line)
                XCTAssertEqual(window.sleepTimer.remainingSeconds, 1000, "\(cell)", file: file, line: line)
                tick(window, 1)
                XCTAssertEqual(window.sleepTimer.remainingSeconds, 1000, "\(cell): it counted before Play", file: file, line: line)
                next.play()
                tick(window, 1)
                XCTAssertEqual(window.sleepTimer.remainingSeconds, 999, "\(cell): Play did not resume it", file: file, line: line)
            case .endOfHeading:
                XCTAssertTrue(window.sleepTimer.waitsForHeadingEnd(ownedBy: next.readerID), "\(cell)", file: file, line: line)
                let waited = try XCTUnwrap(next.sleepTimerNextHeading, "\(cell): no heading is waited for", file: file, line: line)
                let expected = try XCTUnwrap(secondHeading(of: next), "\(cell): the book has one heading", file: file, line: line)
                XCTAssertEqual(
                    [waited.chapterIndex, waited.characterOffset], [expected.chapterIndex, expected.characterOffset],
                    "\(cell): the timer waits for another heading than the one after the new book's start", file: file, line: line
                )
            case .endOfBook:
                XCTAssertTrue(
                    window.sleepTimer.stopsPlaybackAtChapterEnd(endingTheHeading: false, endingTheBook: true, ownedBy: next.readerID),
                    "\(cell): the timer does not stop the new book at its end", file: file, line: line
                )
                XCTAssertTrue(next.sleepTimerEndsListeningHere, "\(cell)", file: file, line: line)
            }
            next.stop()
        }
    }

    /// The second heading of `reader`'s book in book order: the end of the
    /// first, where the heading playback starts in ends.
    private func secondHeading(of reader: ReaderViewModel) -> Heading? {
        let ordered = reader.headings.sorted {
            ($0.chapterIndex, $0.characterOffset) < ($1.chapterIndex, $1.characterOffset)
        }
        return ordered.count > 1 ? ordered[1] : nil
    }

    // MARK: - The Next Book in Another Window

    /// With A New Window, the timer goes with listening to the new window:
    /// held in the old window, still the old reader's, until the next book's
    /// reader has loaded, when the new window's timer takes it, with the time
    /// it had left, and counts on as the book plays; the old window then
    /// shows no timer, and its reader's close changes nothing.
    func testTheTimerGoesToTheNewWindowAsItsBookLoads() throws {
        world.settings.nextBookWindow = .newWindow
        let first = try makeBook(.audio, titled: "New Window A")
        let second = try makeBook(.text, titled: "New Window B")
        let oldWindow = makeWindow()
        let old = openReader(for: first, in: oldWindow)
        old.startSleepTimer(duration: .minutes(30))
        oldWindow.sleepTimer.remainingSeconds = 1000
        old.isWhereAmIResumePending = true
        let continued = record(.continueToNextBook)

        old.goThroughFolder(.down)
        XCTAssertTrue(eventually { !continued().isEmpty }, "The next book's window was never asked for")
        XCTAssertTrue(oldWindow.switchedTo.isEmpty, "The old window switched")
        XCTAssertTrue(oldWindow.sleepTimer.isHeld(forBook: second.id), "The timer was not held for the next book")
        XCTAssertEqual(oldWindow.sleepTimer.ownerID, old.readerID, "Exactly one owner until the next book takes it")

        let newWindow = makeWindow()
        let next = openReader(for: second, in: newWindow)

        XCTAssertEqual(newWindow.sleepTimer.ownerID, next.readerID, "The new window's reader did not take the timer")
        XCTAssertEqual(newWindow.sleepTimer.duration, .minutes(30))
        XCTAssertFalse(oldWindow.sleepTimer.isActive, "The old window still shows the timer")
        XCTAssertEqual(oldWindow.sleepTimer.spokenLabel, "")
        XCTAssertNil(registry.timer(heldForBook: second.id), "The hold outlived the take")
        XCTAssertTrue(eventually { next.isPlaybackUnderWay }, "The next book never started")
        // Read after the wait, which the counting countdown ticks through on
        // its own clock, and just before the hand's tick.
        let left = newWindow.sleepTimer.remainingSeconds
        XCTAssertTrue(left <= 1000 && left > 1000 - 60, "\(left) left in the new window, from 1000")
        tick(newWindow, 1)
        XCTAssertEqual(newWindow.sleepTimer.remainingSeconds, left - 1, "The timer does not count in the new window")

        old.close()
        XCTAssertTrue(newWindow.sleepTimer.isActive, "The old reader's close stopped the timer in the new window")
    }

    /// The next book open already in a window of its own is brought forward,
    /// and that window's timer takes the running one at the ask, replacing a
    /// timer of its own: one timer goes on, with listening.
    func testTheBooksOpenWindowBroughtForwardTakesTheTimerAtTheAsk() throws {
        let first = try makeBook(.audio, titled: "Forward A")
        let second = try makeBook(.audio, titled: "Forward B")
        let otherWindow = makeWindow()
        let other = openReader(for: second, in: otherWindow)
        other.startSleepTimer(duration: .minutes(5))
        other.pause(playingPauseSound: false)
        let oldWindow = makeWindow()
        let old = openReader(for: first, in: oldWindow)
        old.startSleepTimer(duration: .minutes(30))
        oldWindow.sleepTimer.remainingSeconds = 1000
        old.isWhereAmIResumePending = true

        old.goThroughFolder(.down)
        XCTAssertTrue(
            eventually { otherWindow.sleepTimer.duration == .minutes(30) },
            "The book's open window never took the timer"
        )

        XCTAssertEqual(otherWindow.sleepTimer.ownerID, other.readerID)
        XCTAssertLessThanOrEqual(otherWindow.sleepTimer.remainingSeconds, 1000)
        XCTAssertFalse(oldWindow.sleepTimer.isActive, "The old window still shows the timer")
        XCTAssertTrue(oldWindow.switchedTo.isEmpty, "The old window switched to a book open elsewhere")
    }

    // MARK: - A Timer on Its Way Here

    /// A timer started in the window of a book a timer is on its way to, from
    /// another window, replaces it, as a new timer replaces the one there is:
    /// the window's own runs, and the one coming stops, so the book takes
    /// nothing as it loads. Cancelling there ends the one coming too.
    func testATimerStartedOrCancelledWhereOneIsComingStopsTheOneComing() throws {
        for cancels in [false, true] {
            let label = cancels ? "cancelled" : "started"
            let (source, next, newWindow) = try timerOnItsWayToALoadingBook(label)

            if cancels {
                next.cancelSleepTimer()
            } else {
                next.startSleepTimer(duration: .minutes(5))
            }

            XCTAssertFalse(source.isActive, "\(label): the timer on its way here runs on")
            XCTAssertEqual(newWindow.sleepTimer.isActive, !cancels, label)
            heldLoad?.activate()
            waitForReaderToLoad(next)
            XCTAssertEqual(
                newWindow.sleepTimer.duration, cancels ? nil : .minutes(5),
                "\(label): the book took the timer that was on its way"
            )
        }
    }

    /// Restart Sleep Timer reaching the window of a book a timer is on its
    /// way to restarts that timer where it is, as it reached the one timer
    /// there was: the hold and its owner kept, its minutes from the full
    /// duration, and the book takes it so as it loads.
    func testRestartWhereATimerIsComingRestartsTheOneComing() throws {
        let (source, next, newWindow) = try timerOnItsWayToALoadingBook("Restart")

        let recorder = recordingAnnouncements { next.restartOrStartLastSleepTimer() }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Timer reset."])
        XCTAssertEqual(source.remainingSeconds, 30 * 60, "The timer on its way was not restarted")
        XCTAssertFalse(newWindow.sleepTimer.isActive, "The restart started a timer of the window's own")
        heldLoad?.activate()
        waitForReaderToLoad(next)
        XCTAssertEqual(newWindow.sleepTimer.ownerID, next.readerID)
        XCTAssertGreaterThan(newWindow.sleepTimer.remainingSeconds, 30 * 60 - 60, "The book took a timer not restarted")
    }

    /// The queue holding the load of the reader `timerOnItsWayToALoadingBook`
    /// made last: a test lets the load go with `activate()`, which a second
    /// activation leaves alone.
    private var heldLoad: DispatchQueue?

    /// A timer of 30 minutes, 1000 seconds left, on its way from one window
    /// to the next book's new window, whose reader is still loading: held for
    /// the book and asked for, as A New Window leaves it.
    ///
    /// - Returns: The old window's timer, the next book's reader, and its
    ///   window.
    private func timerOnItsWayToALoadingBook(_ label: String) throws -> (SleepTimerService, ReaderViewModel, TestReaderWindow) {
        let first = try makeBook(.audio, titled: "\(label) Coming A")
        let second = try makeBook(.audio, titled: "\(label) Coming B")
        let oldWindow = makeWindow()
        let old = openReader(for: first, in: oldWindow)
        old.startSleepTimer(duration: .minutes(30))
        oldWindow.sleepTimer.remainingSeconds = 1000
        XCTAssertTrue(oldWindow.sleepTimer.hold(forBook: second.id, from: old.readerID, isBookOpen: old.bookIsOpenCheck))
        oldWindow.sleepTimer.markAsked(forBook: second.id)
        // Inactive until activated, which a second activation leaves alone,
        // so the load is let go however the test ends.
        let held = DispatchQueue(label: "window-timer-held-load-\(label)", attributes: .initiallyInactive)
        heldLoad = held
        addTeardownBlock { held.activate() }
        let newWindow = makeWindow()
        let next = world.openReader(
            for: second,
            renderScheduler: HeldRenderQueue(),
            nowPlaying: coordinator,
            loadQueue: held,
            sleepTimer: newWindow.sleepTimer
        )
        XCTAssertTrue(next.sleepTimerComingHere === oldWindow.sleepTimer, "\(label): no timer is on its way")
        return (oldWindow.sleepTimer, next, newWindow)
    }

    // MARK: - Commands

    /// Restart Sleep Timer's key acts in the window it was pressed in, on
    /// that window's timer: a window with no timer starts one of the
    /// duration last used, and the other window's timer is left as it was.
    func testRestartSleepTimersKeyActsInTheWindowItWasPressedIn() throws {
        let windowA = makeWindow()
        let windowB = makeWindow()
        let a = openReader(for: try makeBook(.audio, titled: "Key A"), in: windowA)
        let b = openReader(for: try makeBook(.audio, titled: "Key B"), in: windowB)
        let hostA = NSWindow()
        let hostB = NSWindow()
        a.attach(to: hostA)
        b.attach(to: hostB)
        a.startSleepTimer(duration: .minutes(30))
        windowA.sleepTimer.remainingSeconds = 1000
        a.pause(playingPauseSound: false)

        let inB = recordingAnnouncements {
            world.notifications.post(name: .restartSleepTimer, object: nil, userInfo: ["sourceWindow": hostB])
        }

        XCTAssertEqual(inB.announcements.map(\.message), ["Timer restarted: 30 minutes."])
        XCTAssertEqual(windowB.sleepTimer.ownerID, b.readerID, "The key pressed in B's window did not start B's timer")
        XCTAssertEqual(windowA.sleepTimer.remainingSeconds, 1000, "The key pressed in B's window restarted A's timer")

        let inA = recordingAnnouncements {
            world.notifications.post(name: .restartSleepTimer, object: nil, userInfo: ["sourceWindow": hostA])
        }

        XCTAssertEqual(inA.announcements.map(\.message), ["Timer reset."])
        XCTAssertEqual(windowA.sleepTimer.remainingSeconds, 30 * 60, "The key pressed in A's window did not restart A's timer")
        XCTAssertEqual(windowB.sleepTimer.ownerID, b.readerID)
        withExtendedLifetime((hostA, hostB)) {}
    }

    /// The restart gesture of the AirPods or the media keys, which belongs to
    /// no window, names the reader that owns Now Playing as it ends, and that
    /// reader acts on its own window's timer. The user's case again: a paused
    /// timer in one window and another book playing in another; the gesture
    /// starts the playing book's own timer, of the duration last used, and
    /// leaves the first window's timer and book alone. Until November 13 it
    /// went to the reader that set the last timer: it restarted the paused
    /// book's timer and played that book, pausing the one being heard.
    func testTheRestartGestureReachesTheBookBeingHeard() throws {
        let windowA = makeWindow()
        let windowB = makeWindow()
        let a = openReader(for: try makeBook(.text, titled: "Gesture A"), in: windowA)
        a.startSleepTimer(duration: .minutes(15))
        windowA.sleepTimer.remainingSeconds = 160
        a.pause(playingPauseSound: false)
        let b = openReader(for: try makeBook(.audio, titled: "Gesture B"), in: windowB)
        b.play()
        XCTAssertTrue(eventually { b.audioPlaybackService.isPlaying }, "B never played")
        XCTAssertEqual(coordinator.activeOwnerID, b.readerID, "The book being heard does not own Now Playing")

        let gesture = try restartGesture(through: coordinator)
        XCTAssertEqual(
            gesture[NowPlayingService.restartGestureOwnerKey] as? UUID, b.readerID,
            "The gesture does not name the reader that owns Now Playing"
        )
        let recorder = recordingAnnouncements {
            world.notifications.post(name: .restartSleepTimer, object: nil, userInfo: gesture)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Timer restarted: 15 minutes."])
        XCTAssertEqual(windowB.sleepTimer.ownerID, b.readerID, "The book being heard did not start its own timer")
        XCTAssertEqual(windowB.sleepTimer.duration, .minutes(15))
        XCTAssertEqual(windowA.sleepTimer.remainingSeconds, 160, "The gesture restarted the paused book's timer")
        XCTAssertFalse(a.isPlaybackUnderWay, "The gesture played the paused book")
        XCTAssertTrue(b.isPlaybackUnderWay, "The gesture paused the book being heard")
    }

    /// Makes `coordinator` see the restart gesture, twice Previous Track, as
    /// the AirPods send it, and returns what its Restart Sleep Timer carries.
    /// The coordinator posts it to the app's notification center, where no
    /// reader of the test listens; the test hands it to its own.
    private func restartGesture(
        through coordinator: NowPlayingService,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [AnyHashable: Any] {
        var posted: Notification?
        NotificationCenter.default.publisher(for: .restartSleepTimer)
            .sink { posted = $0 }
            .store(in: &subscriptions)
        coordinator.updateGestureSettings(enabled: true, pattern: "previousTrack,previousTrack", window: 5)
        defer { coordinator.updateGestureSettings(enabled: false, pattern: "previousTrack,previousTrack", window: 5) }
        XCTAssertEqual(coordinator.acceptRemoteCommand(.previousTrack), .success, file: file, line: line)
        XCTAssertEqual(coordinator.acceptRemoteCommand(.previousTrack), .success, file: file, line: line)
        XCTAssertTrue(eventually { posted != nil }, "The gesture posted nothing", file: file, line: line)
        return try XCTUnwrap(posted?.userInfo, "The gesture named no reader", file: file, line: line)
    }

    /// A menu command, which carries no window, is the key window's, and a
    /// sheet's command its window's: Show Sleep Timer opens the sheet of that
    /// window's reader, which shows that window's timer.
    func testAMenuCommandIsTheKeyWindowsAndItsSheetShowsThatWindowsTimer() throws {
        let hostA = NSWindow()
        let hostB = NSWindow()
        XCTAssertTrue(WindowCommandRouting.shouldAccept(sourceWindow: nil, hostWindow: hostB, keyWindow: hostB))
        XCTAssertFalse(WindowCommandRouting.shouldAccept(sourceWindow: nil, hostWindow: hostA, keyWindow: hostB))

        let windowA = makeWindow()
        let windowB = makeWindow()
        let a = openReader(for: try makeBook(.audio, titled: "Menu A"), in: windowA)
        let b = openReader(for: try makeBook(.audio, titled: "Menu B"), in: windowB)
        a.startSleepTimer(duration: .minutes(10))
        b.startSleepTimer(duration: .endOfBook)

        XCTAssertTrue(SleepTimerView.sheet(for: a, onClose: {}).sleepTimerService === windowA.sleepTimer)
        XCTAssertTrue(SleepTimerView.sheet(for: b, onClose: {}).sleepTimerService === windowB.sleepTimer)
        XCTAssertEqual(windowA.sleepTimer.spokenLabel, "Sleep timer: 10:00 remaining")
        XCTAssertEqual(windowB.sleepTimer.spokenLabel, "Sleep timer: stops at the end of the book")
    }

    /// Two windows' sleep timer sheets stay open together, each about its
    /// own window's timer: one opening no longer closes the other, as it did
    /// while every sheet showed the one timer there was. Each sheet is hosted
    /// in a window of its own that is never shown.
    func testTwoWindowsSheetsStayOpenTogether() throws {
        let a = openReader(for: try makeBook(.audio, titled: "Sheet A"), in: makeWindow())
        let b = openReader(for: try makeBook(.audio, titled: "Sheet B"), in: makeWindow())
        a.startSleepTimer(duration: .minutes(10))
        var closed: [String] = []

        withHostedView(SleepTimerView.sheet(for: a) { closed.append("A") }, until: { _ in true }) { _ in
            withHostedView(SleepTimerView.sheet(for: b) { closed.append("B") }, until: { _ in true }) { _ in
                // Lets SwiftUI make each sheet appear, and deliver what it
                // posts as it does.
                spinMainRunLoop(for: 0.5)
            }
        }

        XCTAssertEqual(closed, [], "A window's sleep timer sheet closed another's")
    }

    // MARK: - What a Tick Draws

    /// A tick of the window's sleep timer does not run the body of the
    /// window's content, and so not `BookReaderWindowView.init` below it
    /// (finding 5 of the review): the content keeps its timer in a holder
    /// that publishes nothing, since the sheet observes the timer itself.
    /// Before, the window's `@StateObject` timer drew the content once a
    /// second in every window with a counting timer.
    func testATickOfTheWindowsTimerDoesNotDrawTheWindowContent() throws {
        let library = LibraryViewModel(initializeServices: false)
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: makeSandboxedPreferences("window-content-tick")
        )
        // The content makes its timer in the app's registry; the new timer
        // is the one that was not there before.
        let before = Set(SleepTimerRegistry.shared.timers.map(ObjectIdentifier.init))
        let hosted = hostOffscreen(
            ReaderWindowContent(bookID: .constant(nil), libraryViewModel: library, settingsViewModel: settings)
        )
        defer { takeDown(hosted.window) }
        settle(hosted.hostingView, seconds: 0.3)
        let timer = try XCTUnwrap(
            SleepTimerRegistry.shared.timers.first { !before.contains(ObjectIdentifier($0)) },
            "The window content made no timer"
        )
        XCTAssertGreaterThan(ViewBodyCounter.count(of: "ReaderWindowContent"), 0, "The window content never drew")

        // Each change is what a tick of a counting timer publishes.
        let runs = bodyRuns(of: ["ReaderWindowContent"], in: hosted.hostingView, publishing: 5, warmUps: 2) { _ in
            timer.remainingSeconds += 1
        }

        XCTAssertEqual(runs["ReaderWindowContent"], 0, "A tick of the timer drew the window's content")
    }

    // MARK: - Commands Nobody Names a Window For

    /// The restart gesture names the reader that owns Now Playing, and that
    /// reader acts although no window is focused: the gesture often comes
    /// while another app is in front, or while no window of the app is key,
    /// and the owner key needs no focus. Both readers sit in windows that are
    /// not key, and only the one named acts.
    func testTheRestartGestureNamingTheOwnerActsWithNoWindowFocused() throws {
        let windowA = makeWindow()
        let windowB = makeWindow()
        let a = openReader(for: try makeBook(.audio, titled: "Unfocused A"), in: windowA)
        let b = openReader(for: try makeBook(.audio, titled: "Unfocused B"), in: windowB)
        let hostA = NSWindow()
        let hostB = NSWindow()
        a.attach(to: hostA)
        b.attach(to: hostB)
        XCTAssertFalse(hostA.isKeyWindow || hostB.isKeyWindow, "A window the test made is key")
        a.startSleepTimer(duration: .minutes(15))
        windowA.sleepTimer.remainingSeconds = 160
        a.pause(playingPauseSound: false)

        let recorder = recordingAnnouncements {
            world.notifications.post(
                name: .restartSleepTimer,
                object: nil,
                userInfo: NowPlayingService.restartGestureUserInfo(owner: b.readerID)
            )
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Timer restarted: 15 minutes."])
        XCTAssertEqual(windowB.sleepTimer.ownerID, b.readerID, "The owner did not act with no window focused")
        XCTAssertEqual(windowA.sleepTimer.remainingSeconds, 160, "The reader not named acted")
        withExtendedLifetime((hostA, hostB)) {}
    }

    /// A Restart Sleep Timer that names neither a window nor an owner (the
    /// gesture while no reader owns Now Playing, as the app posted it before
    /// November 13) is the focused reader's alone: no reader whose window is
    /// not key acts, and the key window's reader acts, on its own timer.
    func testRestartNamingNeitherAWindowNorAnOwnerIsTheFocusedReadersAlone() throws {
        let windowA = makeWindow()
        let windowB = makeWindow()
        let a = openReader(for: try makeBook(.audio, titled: "Fallback A"), in: windowA)
        let b = openReader(for: try makeBook(.audio, titled: "Fallback B"), in: windowB)
        let hostA = NSWindow()
        let hostB = NSWindow()
        a.attach(to: hostA)
        b.attach(to: hostB)
        b.startSleepTimer(duration: .minutes(30))
        windowB.sleepTimer.remainingSeconds = 1000

        let unfocused = recordingAnnouncements {
            world.notifications.post(name: .restartSleepTimer, object: nil)
        }

        XCTAssertEqual(unfocused.announcements.map(\.message), [], "A reader in a window that is not key acted")
        XCTAssertFalse(windowA.sleepTimer.isActive)
        XCTAssertEqual(windowB.sleepTimer.remainingSeconds, 1000)

        // Now the first reader's window is the key window.
        let keyHost = KeyStubWindow()
        a.attach(to: keyHost)
        let focused = recordingAnnouncements {
            world.notifications.post(name: .restartSleepTimer, object: nil)
        }

        XCTAssertEqual(focused.announcements.map(\.message), ["Timer restarted: 30 minutes."])
        XCTAssertEqual(windowA.sleepTimer.ownerID, a.readerID, "The focused reader did not start its own timer")
        XCTAssertEqual(windowB.sleepTimer.remainingSeconds, 1000, "The unfocused reader's timer was restarted")
        withExtendedLifetime((hostA, hostB, keyHost)) {}
    }

    /// The Show Sleep Timer menu command, posted as the menu posts it, with no
    /// window named, opens the sheet of the reader whose window is key and no
    /// other (the reader's own panel commands receive it, as in the app).
    func testTheShowSleepTimerCommandPostedForRealOpensTheKeyWindowsSheetOnly() throws {
        let a = openReader(for: try makeBook(.audio, titled: "Command A"), in: makeWindow())
        let b = openReader(for: try makeBook(.audio, titled: "Command B"), in: makeWindow())
        // A menu command follows the key window: the app's own, if one is key
        // while the test runs (a window an earlier test left key), else one
        // that says it is.
        let keyHost: NSWindow = PlatformApplication.keyWindow ?? KeyStubWindow()
        let otherHost = NSWindow()
        a.attach(to: keyHost)
        b.attach(to: otherHost)
        let boxA = PanelBox()
        let boxB = PanelBox()

        withHostedView(PanelCommandsProbe(reader: a, box: boxA), until: { _ in true }) { _ in
            withHostedView(PanelCommandsProbe(reader: b, box: boxB), until: { _ in true }) { _ in
                // Posts the command until the key window's view has taken it:
                // SwiftUI subscribes a hosted view to it a moment after the
                // view is made, and a command posted before then is lost. A
                // view that is not the key window's takes none; both are given
                // a moment to subscribe first, so that a command the other
                // view wrongly took would show.
                spinMainRunLoop(for: 0.3)
                let opened = waitUntil(timeout: 5) {
                    NotificationCenter.default.post(name: .showSleepTimer, object: nil)
                    return boxA.panels.sleepTimer
                }
                XCTAssertTrue(opened, "The key window's view never took the command")
            }
        }

        XCTAssertTrue(boxA.panels.sleepTimer, "The key window's sheet did not open")
        XCTAssertFalse(boxB.panels.sleepTimer, "A window that is not key opened its sheet")
        withExtendedLifetime((keyHost, otherHost)) {}
    }

    /// What a reader's panels are, kept where a test can read them.
    private final class PanelBox {
        var panels = ReaderPanels()
    }

    /// A view that receives a reader's panel commands (`ReaderPanelCommands`),
    /// as the reader's own view does, and keeps the panels they open in `box`.
    private struct PanelCommandsProbe: View {
        let reader: ReaderViewModel
        let box: PanelBox

        var body: some View {
            Color.clear.modifier(
                ReaderPanelCommands(
                    viewModel: reader,
                    panels: Binding(get: { box.panels }, set: { box.panels = $0 })
                )
            )
        }
    }

    // MARK: - Helpers

    /// The two kinds of book a window shows.
    enum Kind: String, CaseIterable {
        case text
        case audio
    }

    /// A window of the test's own, whose timer joins the test's registry.
    private func makeWindow() -> TestReaderWindow {
        TestReaderWindow(registry: registry, preferences: preferences)
    }

    /// A reader for `book` in `window`, as the window's content makes one:
    /// with the window's timer, the window's switch, and its window on
    /// screen. Its speech goes to the recorder, and its look-ahead renders
    /// are held. The world closes it when the test ends.
    ///
    /// - Parameter loaded: Whether to wait for its book to load.
    private func openReader(
        for book: Book,
        in window: TestReaderWindow,
        loaded: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ReaderViewModel {
        let reader = world.openReader(
            for: book,
            renderScheduler: HeldRenderQueue(),
            nowPlaying: coordinator,
            sleepTimer: window.sleepTimer
        )
        reader.speechService._directUtteranceRecorderForTesting = { [weak self] in self?.utterances.append($0) }
        reader.nextBookWindowSwitcher = { [weak window] bookID in window?.switchTo(bookID) }
        reader.windowStandingOverride = .onScreen
        if loaded {
            waitForReaderToLoad(reader, file: file, line: line)
            XCTAssertNil(reader.errorMessage, "\(book.title) did not open", file: file, line: line)
        }
        return reader
    }

    /// A book of `kind` titled `title`, in the world's folder: an audiobook
    /// of two silent tracks, each a heading, or a Markdown book of one
    /// chapter longer than speech renders, with two headings, the title at
    /// its start and Tides after it.
    private func makeBook(_ kind: Kind, titled title: String) throws -> Book {
        switch kind {
        case .audio:
            return try world.makeSilentAudioBook(title: title, trackDurations: [30, 30])
        case .text:
            let source = try makeSandboxDirectory("Window Timer Text").appendingPathComponent("\(title).md")
            try Data(Self.ledger(titled: title).utf8).write(to: source)
            return try world.importBook(from: source)
        }
    }

    /// The Markdown of a text book titled `title`: a heading of its title,
    /// moorings, then a heading Tides, and tides, one chapter longer than
    /// speech ever renders, so its speech is direct and goes to the recorder.
    static func ledger(titled title: String) -> String {
        var text = "# \(title)\n\n"
        for entry in 1...1_400 {
            text += "Mooring \(entry) of the harbour ledger is checked. "
        }
        text += "\n\n# Tides\n\n"
        for entry in 1...1_200 {
            text += "Tide \(entry) of the harbour ledger is noted. "
        }
        return text + "\n"
    }

    /// Counts `window`'s timer down by `seconds`, as its countdown would,
    /// without waiting; a countdown halted by a pause does not move.
    private func tick(_ window: TestReaderWindow, _ seconds: Int) {
        for _ in 0..<seconds {
            window.sleepTimer._advanceCountdownForTesting()
        }
    }

    /// Records every notification named `name` posted in the world.
    ///
    /// - Returns: A function reading the notifications posted so far.
    private func record(_ name: Notification.Name) -> () -> [Notification] {
        var posted: [Notification] = []
        world.notifications.publisher(for: name)
            .sink { posted.append($0) }
            .store(in: &subscriptions)
        return { posted }
    }
}

/// A reader window, as the scene's window content makes one, without a window
/// on screen: the window's sleep timer, which every reader it shows is given
/// (`ReaderWindowContent`), and its switch to another book in place, which it
/// records, the test then making that book's reader in it.
@MainActor
final class TestReaderWindow {
    /// The window's sleep timer.
    let sleepTimer: SleepTimerService
    /// The books the window was switched to in place, in order.
    private(set) var switchedTo: [UUID] = []

    /// A window whose timer joins `registry` and keeps the duration last
    /// used in `preferences`.
    init(registry: SleepTimerRegistry, preferences: UserDefaults) {
        sleepTimer = SleepTimerService(userDefaults: preferences, registry: registry)
    }

    /// Notes that the window was asked to show `bookID` in place.
    func switchTo(_ bookID: UUID) {
        switchedTo.append(bookID)
    }
}

/// A window that says it is the key window, without being on screen: the
/// window a menu command and a gesture with no one named follow, so a test
/// can tell the focused reader from one in a window that is not key.
final class KeyStubWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
