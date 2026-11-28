import Combine
import XCTest
@testable import TextMouth

/// `PhoneSession`, the iPhone's owner of its open readers, two at most. It runs
/// on the Mac's test host, since nothing can run on iOS tonight, over real
/// readers of silent audiobooks in a private world: its own library, settings,
/// notification center, requests, and media session, which records what it
/// would show the system. Nothing is heard: the sounds go to a player that
/// records them, and the media session installs nothing.
@MainActor
final class PhoneSessionTests: XCTestCase {
    /// Subscriptions a test keeps until it ends.
    private var subscriptions = Set<AnyCancellable>()

    // MARK: - Opening

    /// A book opens at once, with its reader held here and its sounds set
    /// before anything can play. The reader is loading, and nothing plays.
    func testOpeningMakesAReaderAndWaitsAtItsPlace() throws {
        let world = try makeIntegrationWorld("PhoneOpen")
        let book = try world.makeSilentAudioBook(
            title: "Tide Tables",
            trackDurations: [5, 5],
            savedPosition: ReadingPosition(chapterIndex: 1, characterOffset: 10, globalCharacterOffset: 60)
        )
        let sounds = makeSounds()
        let session = makeSession(in: world, sounds: sounds)

        let reader = try XCTUnwrap(session.open(book))

        XCTAssertTrue(session.reader === reader)
        XCTAssertTrue(reader.soundEffectService === sounds, "A Play from the AirPods could come before any view")
        XCTAssertEqual(session.snapshot?.bookID, book.id)
        XCTAssertEqual(session.snapshot?.title, "Tide Tables")
        XCTAssertEqual(session.snapshot?.isLoading, true)
        XCTAssertNil(session.listeningReader)
        waitForReaderToLoad(reader)
        XCTAssertTrue(eventually { session.snapshot?.isLoading == false }, "The snapshot never saw the load end")
        XCTAssertEqual(reader.currentChapterIndex, 1, "Not at its saved place")
        XCTAssertEqual(reader.currentCharacterOffset, 10, "Not at its saved place")
        XCTAssertFalse(reader.isPlaybackUnderWay, "A book waits at its place until Play")
    }

    /// Opening the book already on screen keeps its reader.
    func testOpeningTheOpenBookKeepsItsReader() throws {
        let world = try makeIntegrationWorld("PhoneOpenAgain")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let session = makeSession(in: world)
        let first = try XCTUnwrap(session.open(book))
        waitForReaderToLoad(first)

        XCTAssertTrue(session.open(book) === first)
        XCTAssertFalse(first.hasClosed)
    }

    /// The reader starts from the library's own row, not from a row a view read
    /// a while ago, which could hold an older place.
    func testAStaleRowOpensAtTheLibrarysPlace() throws {
        let world = try makeIntegrationWorld("PhoneStaleRow")
        let stale = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5, 5])
        let index = try XCTUnwrap(world.library.library.books.firstIndex { $0.id == stale.id })
        world.library.library.books[index].readingPosition = ReadingPosition(
            chapterIndex: 1, characterOffset: 20, globalCharacterOffset: 70
        )
        let session = makeSession(in: world)

        let reader = try XCTUnwrap(session.open(stale))
        waitForReaderToLoad(reader)

        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertEqual(reader.currentCharacterOffset, 20)
    }

    /// A book no longer in the library is refused, never stood in for with a
    /// placeholder, as the Mac's window does for a missing book.
    func testABookNoLongerInTheLibraryIsRefused() throws {
        let world = try makeIntegrationWorld("PhoneOpenMissing")
        let session = makeSession(in: world)
        let missing = Book(title: "Missing Volume", format: .txt, filePath: "/nonexistent/missing.txt", md5Hash: "m")

        XCTAssertNil(session.open(missing))
        XCTAssertNil(session.reader)
        XCTAssertNil(session.snapshot)
    }

    // MARK: - Two Readers at Most

    /// Opening another book leaves the first going on behind it, still playing,
    /// and in the Continue row.
    func testOpeningAnotherBookLeavesTheFirstPlaying() throws {
        let pair = try makePlayingPair("PhonePairOpen")

        XCTAssertTrue(pair.session.reader === pair.second)
        XCTAssertTrue(pair.session.listeningReader === pair.first)
        XCTAssertFalse(pair.first.hasClosed)
        XCTAssertTrue(pair.first.isPlaybackActivelyAdvancing, "Opening a book stopped the one playing")
        XCTAssertEqual(pair.session.continueSnapshot?.bookID, pair.firstBook.id)
        XCTAssertEqual(pair.session.listeningSnapshot?.isPlaying, true)
    }

    /// Play in the second book pauses the first, closes it, and leaves the
    /// second the one reader.
    func testPlayingTheSecondPausesAndClosesTheFirst() throws {
        let pair = try makePlayingPair("PhonePairPlay")

        pair.session.togglePlayPause()

        XCTAssertTrue(eventually(within: 30) { pair.session.snapshot?.isPlaying == true }, "The second never played")
        XCTAssertTrue(eventually { pair.first.hasClosed }, "The first is still open")
        XCTAssertNil(pair.session.listeningReader)
        XCTAssertNil(pair.session.listeningSnapshot)
        XCTAssertTrue(pair.session.reader === pair.second)
        XCTAssertEqual(pair.session.continueSnapshot?.bookID, pair.secondBook.id)
    }

    /// Leaving the second book's screen before it plays closes it, and the
    /// first is as it was, playing.
    func testLeavingTheSecondUnplayedLeavesTheFirstAsItWas() throws {
        let pair = try makePlayingPair("PhonePairLeave")

        pair.session.leaveReader()

        XCTAssertTrue(pair.second.hasClosed)
        XCTAssertTrue(pair.session.reader === pair.first)
        XCTAssertNil(pair.session.listeningReader)
        XCTAssertEqual(pair.session.snapshot?.bookID, pair.firstBook.id)
        XCTAssertTrue(pair.first.isPlaybackActivelyAdvancing, "The first stopped")
    }

    /// Opening the book behind brings it forward, and the one on screen gives
    /// way; a third book takes the place of the one on screen, and the book
    /// behind stays.
    func testOpeningTheBookBehindOrAThirdKeepsTwoAtMost() throws {
        let pair = try makePlayingPair("PhonePairThird")
        let third = try pair.world.makeSilentAudioBook(title: "Third Volume", trackDurations: [5])

        let thirdReader = try XCTUnwrap(pair.session.open(third))
        XCTAssertTrue(pair.second.hasClosed, "Three readers were open")
        XCTAssertTrue(pair.session.reader === thirdReader)
        XCTAssertTrue(pair.session.listeningReader === pair.first)

        XCTAssertTrue(pair.session.open(pair.firstBook) === pair.first)
        XCTAssertTrue(thirdReader.hasClosed)
        XCTAssertTrue(pair.session.reader === pair.first)
        XCTAssertNil(pair.session.listeningReader)
        XCTAssertFalse(pair.first.hasClosed)
    }

    // MARK: - Closing One Book

    /// Removing the book that plays on behind the screen closes it alone: the
    /// book on screen stays open, with nothing behind it any more, and is the
    /// one kept for the next launch (board message #5368: both readers used
    /// to close).
    func testClosingTheBookBehindLeavesTheBookOnScreenOpen() throws {
        let pair = try makePlayingPair("PhoneCloseBehind")

        pair.session.closeBook(id: pair.firstBook.id)

        XCTAssertTrue(pair.first.hasClosed, "The book behind is still open")
        XCTAssertFalse(pair.second.hasClosed, "The book on screen closed with it")
        XCTAssertTrue(pair.session.reader === pair.second)
        XCTAssertNil(pair.session.listeningReader)
        XCTAssertNil(pair.session.listeningSnapshot)
        XCTAssertEqual(pair.session.snapshot?.bookID, pair.secondBook.id)
        XCTAssertEqual(
            pair.preferences.string(forKey: PhoneSession.reopenBookKey), pair.secondBook.id.uuidString,
            "The next launch should reopen the book that is left"
        )
    }

    /// Removing the book on screen closes it alone: the book that plays behind
    /// it comes forward and goes on playing.
    func testClosingTheBookOnScreenBringsTheBookBehindForward() throws {
        let media = NowPlayingService(installsSystemIntegrations: false, diagnosticSink: { _ in })
        let pair = try makePlayingPair("PhoneCloseOnScreen", nowPlaying: media)
        XCTAssertEqual(media.focusedOwnerID, pair.second.nowPlayingService.ownerID, "The book on screen isn't focused to begin with")

        pair.session.closeBook(id: pair.secondBook.id)

        // A remote Play reaches the book that came forward.
        XCTAssertEqual(media.focusedOwnerID, pair.first.nowPlayingService.ownerID, "The book that came forward is not focused")

        XCTAssertTrue(pair.second.hasClosed, "The book on screen is still open")
        XCTAssertFalse(pair.first.hasClosed, "The book behind closed with it")
        XCTAssertTrue(pair.session.reader === pair.first)
        XCTAssertNil(pair.session.listeningReader)
        XCTAssertEqual(pair.session.snapshot?.bookID, pair.firstBook.id)
        XCTAssertTrue(pair.first.isPlaybackActivelyAdvancing, "The book that plays on stopped")
    }

    /// With a single book open, closing it leaves no reader and nothing to
    /// reopen.
    func testClosingTheOnlyOpenBookLeavesNothingOpen() throws {
        let world = try makeIntegrationWorld("PhoneCloseOnly")
        let book = try world.makeSilentAudioBook(title: "Lone Volume", trackDurations: [5])
        let preferences = makeSandboxedPreferences("PhoneCloseOnly")
        let session = makeSession(in: world, preferences: preferences)
        let reader = try XCTUnwrap(session.open(book))
        waitForReaderToLoad(reader)

        session.closeBook(id: book.id)

        XCTAssertTrue(reader.hasClosed)
        XCTAssertNil(session.reader)
        XCTAssertNil(session.snapshot)
        XCTAssertNil(preferences.string(forKey: PhoneSession.reopenBookKey), "A closed book is still kept for reopening")
    }

    /// Closing a book that isn't open touches neither reader.
    func testClosingABookThatIsNotOpenChangesNothing() throws {
        let pair = try makePlayingPair("PhoneCloseOther")
        let other = try pair.world.makeSilentAudioBook(title: "Shelved Volume", trackDurations: [5])

        pair.session.closeBook(id: other.id)

        XCTAssertFalse(pair.first.hasClosed)
        XCTAssertFalse(pair.second.hasClosed)
        XCTAssertTrue(pair.session.reader === pair.second)
        XCTAssertTrue(pair.session.listeningReader === pair.first)
        XCTAssertTrue(pair.first.isPlaybackActivelyAdvancing)
    }

    // MARK: - Engaging

    /// A mistaken double-tap on a row leaves the book as it was: still "New",
    /// unopened, and not the last opened, once its screen is left.
    func testAMistakenOpenLeavesTheBookAsItWas() throws {
        let world = try makeIntegrationWorld("PhoneMistake")
        preserveLastOpenedBook()
        let earlier = try world.makeSilentAudioBook(title: "Earlier Volume", trackDurations: [5])
        let mistaken = try world.makeSilentAudioBook(title: "Mistaken Volume", trackDurations: [5])
        ConfigService.shared.config.lastOpenedBookID = earlier.id.uuidString
        let session = makeSession(in: world)

        let reader = try XCTUnwrap(session.open(mistaken))
        waitForReaderToLoad(reader)
        session.leaveReader()

        XCTAssertTrue(reader.hasClosed, "A book opened by mistake stays in the Continue row")
        XCTAssertNil(session.reader)
        XCTAssertEqual(world.library.bookByID(mistaken.id)?.isUnopened, true, "The book lost New and Unopened")
        XCTAssertEqual(ConfigService.shared.config.lastOpenedBookID, earlier.id.uuidString, "The last opened book changed")
    }

    /// A book counts as opened once engaged; one engaged and not played stays
    /// open as its screen is left.
    func testABookCountsAsOpenedWhenEngaged() throws {
        let world = try makeIntegrationWorld("PhoneEngaged")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let session = makeSession(in: world)
        let reader = try XCTUnwrap(session.open(book))
        waitForReaderToLoad(reader)

        session.noteBookEngaged()
        session.leaveReader()

        XCTAssertFalse(reader.hasClosed, "An engaged book closed as its screen was left")
        XCTAssertEqual(world.library.bookByID(book.id)?.isUnopened, false)
    }

    // MARK: - The Magic Tap

    /// With a book audible behind the one on screen, the magic tap pauses it;
    /// from silence, the next plays the book on screen.
    func testTheMagicTapPausesWhatIsAudibleThenPlaysTheBookOnScreen() throws {
        let pair = try makePlayingPair("PhoneTapPair")

        XCTAssertTrue(pair.session.togglePlayPauseFromAnywhere())
        XCTAssertTrue(eventually(within: 30) { !pair.first.isPlaybackActivelyAdvancing }, "The audible book played on")
        XCTAssertFalse(pair.second.isPlaybackUnderWay, "The tap played the book on screen")

        XCTAssertTrue(pair.session.togglePlayPauseFromAnywhere())
        XCTAssertTrue(eventually(within: 30) { pair.session.snapshot?.isPlaying == true }, "Never played")
        XCTAssertEqual(pair.session.snapshot?.bookID, pair.secondBook.id)
    }

    /// With no reader open, the magic tap opens the book in reach, here the
    /// last opened, and plays it once it has loaded.
    func testTheMagicTapOpensAndPlaysTheBookInReach() throws {
        let world = try makeIntegrationWorld("PhoneTapLast")
        preserveLastOpenedBook()
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5, 5])
        ConfigService.shared.config.lastOpenedBookID = book.id.uuidString
        let session = makeSession(in: world)

        XCTAssertTrue(session.togglePlayPauseFromAnywhere())

        let reader = try XCTUnwrap(session.reader, "No reader opened")
        XCTAssertEqual(reader.book.id, book.id)
        XCTAssertTrue(session.playWhenLoaded, "The press was not kept for the load's end")
        XCTAssertTrue(eventually(within: 30) { session.snapshot?.isPlaying == true }, "Never played")
    }

    /// With no book in reach, the magic tap answers false, so that the
    /// system's fallback runs, and opens nothing.
    func testTheMagicTapAnswersFalseWithNoBookInReach() throws {
        let world = try makeIntegrationWorld("PhoneTapNone")
        preserveLastOpenedBook()
        _ = try world.makeSilentAudioBook(title: "Never Opened", trackDurations: [5])
        let session = makeSession(in: world)
        ConfigService.shared.config.lastOpenedBookID = UUID().uuidString

        XCTAssertNil(session.bookInReach)
        XCTAssertFalse(session.togglePlayPauseFromAnywhere())
        XCTAssertNil(session.reader)
    }

    /// With the last opened book gone, the book in reach is the row opened most
    /// recently.
    func testTheBookInReachFallsToTheNewestOpenedRow() throws {
        let world = try makeIntegrationWorld("PhoneInReach")
        preserveLastOpenedBook()
        let older = try world.makeSilentAudioBook(title: "Older Volume", trackDurations: [5])
        let newer = try world.makeSilentAudioBook(title: "Newer Volume", trackDurations: [5])
        for (book, opened) in [(older, Date(timeIntervalSinceNow: -86_400)), (newer, Date(timeIntervalSinceNow: -60))] {
            let index = try XCTUnwrap(world.library.library.books.firstIndex { $0.id == book.id })
            world.library.library.books[index].lastOpened = opened
        }
        ConfigService.shared.config.lastOpenedBookID = UUID().uuidString
        let session = makeSession(in: world)

        XCTAssertEqual(session.bookInReach?.id, newer.id)
    }

    /// The magic tap on a finished book does what Play does there: says
    /// "Finished: <title>", as the user decided on October 10, 2026, and leaves
    /// the book at its end. It is not a finished book's request to go on, which
    /// would start the book over without a word.
    func testTheMagicTapOnAFinishedBookSaysWhatPlaySays() throws {
        let world = try makeIntegrationWorld("PhoneTapFinished")
        preserveLastOpenedBook()
        // A place past the last chapter's end opens at the book's end, finished.
        let book = try world.makeSilentAudioBook(
            title: "Harbour Soundings",
            trackDurations: [5],
            savedPosition: ReadingPosition(chapterIndex: 0, characterOffset: 1_000)
        )
        ConfigService.shared.config.lastOpenedBookID = book.id.uuidString
        let session = makeSession(in: world)

        let recorder = recordingAnnouncements {
            XCTAssertTrue(session.togglePlayPauseFromAnywhere())
            XCTAssertTrue(eventually(within: 30) { session.reader?.isLoading == false }, "Never loaded")
            spinMainRunLoop(for: 0.2)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Finished: Harbour Soundings"])
        let reader = try XCTUnwrap(session.reader)
        XCTAssertTrue(reader.cursorRestsAtEnd, "The book moved from its end")
        XCTAssertFalse(reader.isPlaybackUnderWay, "The book played")
    }

    // MARK: - Play While Loading

    /// A press while the book loads waits for the load to end; a second takes
    /// it back.
    func testAPressWhileLoadingWaitsForTheLoad() throws {
        let world = try makeIntegrationWorld("PhonePressLoading")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5, 5])
        let session = makeSession(in: world)
        let reader = try XCTUnwrap(session.open(book))
        XCTAssertTrue(reader.isLoading, "The load should still be under way")

        session.togglePlayPause()
        XCTAssertTrue(session.playWhenLoaded)
        session.togglePlayPause()
        XCTAssertFalse(session.playWhenLoaded, "A second press did not take it back")
        session.play()
        XCTAssertTrue(session.playWhenLoaded, "A remote Play while loading was lost")

        XCTAssertTrue(eventually(within: 30) { session.snapshot?.isPlaying == true }, "The press was lost")
        XCTAssertFalse(session.playWhenLoaded)
    }

    /// Two presses while loading leave the book at rest.
    func testTwoPressesWhileLoadingLeaveTheBookAtRest() throws {
        let world = try makeIntegrationWorld("PhonePressTwice")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5, 5])
        let session = makeSession(in: world)
        let reader = try XCTUnwrap(session.open(book))

        session.togglePlayPause()
        session.togglePlayPause()
        waitForReaderToLoad(reader)
        spinMainRunLoop(for: 0.2)

        XCTAssertFalse(reader.isPlaybackUnderWay, "The press taken back still played")
    }

    /// A press while a book loads that a finished book asked for means stop:
    /// that book was about to play.
    func testAPressWhileLoadingStopsABookAboutToPlay() throws {
        let world = try makeIntegrationWorld("PhonePressRequest")
        let previous = try world.makeSilentAudioBook(title: "Previous Volume", trackDurations: [5])
        let book = try world.makeSilentAudioBook(title: "Next Volume", trackDurations: [5, 5])
        world.autoplayRequests.request(for: book.id, from: previous.id)
        let session = makeSession(in: world)
        let reader = try XCTUnwrap(session.open(book))

        session.togglePlayPause()

        XCTAssertFalse(world.autoplayRequests.hasRequest(for: book.id), "The request still waits")
        waitForReaderToLoad(reader)
        spinMainRunLoop(for: 0.2)
        XCTAssertFalse(reader.isPlaybackUnderWay, "The book played though the press said stop")
    }

    /// A book that could not load has nothing to play: the press that waited
    /// for it is dropped.
    func testAPressWaitingForABookThatCannotLoadIsDropped() throws {
        let world = try makeIntegrationWorld("PhonePressFailure")
        let book = Book(
            title: "Missing Volume",
            format: .txt,
            filePath: "/nonexistent/\(UUID().uuidString).txt",
            md5Hash: UUID().uuidString
        )
        world.library.library.addBook(book)
        let session = makeSession(in: world)
        let reader = try XCTUnwrap(session.open(book))

        session.togglePlayPause()
        waitForReaderToLoad(reader)
        spinMainRunLoop(for: 0.2)

        XCTAssertNotNil(reader.loadErrorMessage, "The book should have failed to load")
        XCTAssertFalse(session.playWhenLoaded)
        XCTAssertFalse(reader.isPlaybackUnderWay)
    }

    // MARK: - Going On to the Next Book

    /// A book's end asks for the next by notification: the new reader is made,
    /// the old closed, and the new claims the request as it loads, so it plays.
    /// Nothing asks the navigation to change, and the hold ends with the load.
    func testTheNextBookOpensAndPlaysThroughTheNotification() throws {
        let folder = try makeFolderWorld("PhoneNext")
        let session = makeSession(in: folder.world)
        var holds: [String] = []
        var ended = 0
        session.beginHold = { name in
            holds.append(name)
            return { ended += 1 }
        }
        let shown = recordScreenRequests(of: session)
        let first = try XCTUnwrap(session.open(folder.first))
        waitForReaderToLoad(first)

        first.handleEndOfBook()

        XCTAssertTrue(
            eventually(within: 30) { session.reader?.book.id == folder.second.id },
            "Continue to Next Book said its book's name, and nothing started"
        )
        XCTAssertTrue(first.hasClosed, "The finished book's reader is still open")
        XCTAssertTrue(eventually(within: 30) { session.snapshot?.isPlaying == true }, "The next book never played")
        XCTAssertFalse(folder.world.autoplayRequests.hasRequest(for: folder.second.id), "The request was not claimed")
        XCTAssertEqual(session.bookToReopenAtLaunch?.id, folder.second.id)
        XCTAssertTrue(shown().isEmpty, "A listener in the Library stays there")
        XCTAssertEqual(holds.count, 1, "The hand-over was not held")
        XCTAssertTrue(eventually { ended >= 1 }, "The hold never ended")
    }

    /// TextMouth stays the Now Playing app through the hand-over (F1): as the
    /// old reader closes, the new one's item is already there, paused, and the
    /// system is left showing it, not nothing.
    func testTheNextBookKeepsTextMouthTheNowPlayingApp() throws {
        let folder = try makeFolderWorld("PhoneNextNowPlaying")
        var shownItems: [NowPlayingItem?] = []
        let media = NowPlayingService(
            installsSystemIntegrations: false,
            diagnosticSink: { _ in },
            systemNowPlaying: { shownItems.append($0) }
        )
        let session = makeSession(in: folder.world, nowPlaying: media)
        let first = try XCTUnwrap(session.open(folder.first))
        waitForReaderToLoad(first)
        session.togglePlayPause()
        XCTAssertTrue(eventually(within: 30) { session.snapshot?.isPlaying == true }, "The first never played")

        first.handleEndOfBook()
        XCTAssertTrue(eventually(within: 30) { first.hasClosed }, "The hand-over never happened")

        let lastShown = try XCTUnwrap(shownItems.last, "Nothing was ever shown")
        XCTAssertEqual(lastShown?.title, "B Volume", "The system was left showing nothing, or the old book")
        let firstOfNext = try XCTUnwrap(shownItems.firstIndex { $0?.title == "B Volume" })
        XCTAssertFalse(shownItems[firstOfNext...].contains { $0 == nil }, "The system showed nothing after the next book")
    }

    // MARK: - A Play That Wakes the App, the Press That Waits, and Focus

    /// A lock-screen Play that opens the book in reach holds the app until the
    /// book has loaded, as a hand-over does, and the hold ends with the load.
    func testARemotePlayThatOpensABookHoldsTheAppUntilItLoads() throws {
        let world = try makeIntegrationWorld("PhoneRemoteHold")
        preserveLastOpenedBook()
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5, 5])
        ConfigService.shared.config.lastOpenedBookID = book.id.uuidString
        let session = makeSession(in: world)
        var holds: [String] = []
        var ended = 0
        session.beginHold = { name in
            holds.append(name)
            return { ended += 1 }
        }

        XCTAssertTrue(session.togglePlayPauseFromAnywhere())

        XCTAssertEqual(holds.count, 1, "The load was not held")
        XCTAssertEqual(ended, 0, "The hold ended before the load")
        XCTAssertTrue(eventually(within: 30) { session.snapshot?.isPlaying == true }, "Never played")
        XCTAssertTrue(eventually { ended == 1 }, "The hold never ended, or ended twice")
    }

    /// A Play with no book to open begins no hold that is left running.
    func testARemotePlayWithNoBookInReachLeavesNoHold() throws {
        let world = try makeIntegrationWorld("PhoneRemoteNoHold")
        preserveLastOpenedBook()
        let session = makeSession(in: world)
        ConfigService.shared.config.lastOpenedBookID = UUID().uuidString
        var begun = 0
        var ended = 0
        session.beginHold = { _ in
            begun += 1
            return { ended += 1 }
        }

        XCTAssertFalse(session.togglePlayPauseFromAnywhere())

        XCTAssertEqual(begun, ended, "A hold was left running")
    }

    /// The guard against a book that closes the app is read as the session is
    /// made: the mark a run writes for its own opening is never taken for a
    /// crash, as a lock-screen Play's was before the first activation.
    func testAnOpeningThisRunIsNotTakenForACrash() throws {
        let world = try makeIntegrationWorld("PhoneOwnMark")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5, 5])
        let preferences = makeSandboxedPreferences("PhoneOwnMark")
        let session = makeSession(in: world, preferences: preferences)

        _ = try XCTUnwrap(session.open(book))
        XCTAssertEqual(preferences.string(forKey: PhoneSession.openingBookKey), book.id.uuidString)

        XCTAssertEqual(session.takeReopeningAtLaunch(fileOpened: true), .nothing)
        XCTAssertEqual(
            preferences.string(forKey: PhoneSession.openingBookKey), book.id.uuidString,
            "This run's mark was cleared as a crash"
        )
    }

    /// A press that waits for the load keeps the book open through Back.
    func testBackKeepsABookWhosePlayWaitsForTheLoad() throws {
        let world = try makeIntegrationWorld("PhoneBackWaiting")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5, 5])
        let session = makeSession(in: world)
        let reader = try XCTUnwrap(session.open(book))
        XCTAssertTrue(reader.isLoading)

        session.togglePlayPause()
        session.leaveReader()

        XCTAssertTrue(session.reader === reader, "Back closed the book that was to play")
        XCTAssertFalse(reader.hasClosed)
        XCTAssertTrue(eventually(within: 30) { session.snapshot?.isPlaying == true }, "The press was lost")
    }

    /// The book on screen is the one a remote Play reaches, not an older book
    /// behind it.
    func testTheBookOnScreenIsTheFocusedOwnerOfRemotePlay() throws {
        let folder = try makeFolderWorld("PhoneFocus")
        let media = NowPlayingService(installsSystemIntegrations: false, diagnosticSink: { _ in })
        let session = makeSession(in: folder.world, nowPlaying: media)
        let first = try XCTUnwrap(session.open(folder.first))
        waitForReaderToLoad(first)
        session.togglePlayPause()
        XCTAssertTrue(eventually(within: 30) { session.snapshot?.isPlaying == true })

        let second = try XCTUnwrap(session.open(folder.second))
        XCTAssertEqual(media.focusedOwnerID, second.nowPlayingService.ownerID, "The new book on screen is not focused")

        session.leaveReader()
        XCTAssertEqual(media.focusedOwnerID, first.nowPlayingService.ownerID, "The book that came back is not focused")
    }

    // MARK: - Is Any Book Playing

    /// A book playing behind an unplayed one counts: both snapshots are read.
    func testAnyBookPlayingReadsBothSnapshots() throws {
        let pair = try makePlayingPair("PhonePlayingAny")

        XCTAssertNotEqual(pair.session.snapshot?.isPlaying, true)
        XCTAssertTrue(pair.session.isAnyBookPlaying, "The book behind was not counted")
    }

    /// A book going on behind the one on screen goes on there: the next book
    /// takes its place behind, and the book on screen stays.
    func testTheNextBookOfTheBookBehindGoesOnBehind() throws {
        let folder = try makeFolderWorld("PhoneNextBehind")
        let session = makeSession(in: folder.world)
        let first = try XCTUnwrap(session.open(folder.first))
        waitForReaderToLoad(first)
        session.togglePlayPause()
        XCTAssertTrue(eventually(within: 30) { session.snapshot?.isPlaying == true }, "The first never played")
        let onScreen = try XCTUnwrap(session.open(folder.third))
        waitForReaderToLoad(onScreen)

        first.handleEndOfBook()

        XCTAssertTrue(
            eventually(within: 30) { session.listeningReader?.book.id == folder.second.id },
            "The next book did not take the place behind"
        )
        XCTAssertTrue(session.reader === onScreen, "The book on screen was replaced")
        XCTAssertTrue(first.hasClosed)
    }

    /// Every reader the session makes is announced once, whichever slot it
    /// takes: the opened book, and the next book that goes straight behind
    /// the screen, which the life cycle's hooks once missed.
    func testEveryReaderMadeIsAnnouncedOnceWhateverSlotItTakes() throws {
        let folder = try makeFolderWorld("PhoneReaderMade")
        let session = makeSession(in: folder.world)
        var made: [ReaderViewModel] = []
        session.readerMade.sink { made.append($0) }.store(in: &subscriptions)
        let first = try XCTUnwrap(session.open(folder.first))
        waitForReaderToLoad(first)
        session.togglePlayPause()
        XCTAssertTrue(eventually(within: 30) { session.snapshot?.isPlaying == true }, "The first never played")
        let onScreen = try XCTUnwrap(session.open(folder.third))
        waitForReaderToLoad(onScreen)

        first.handleEndOfBook()

        XCTAssertTrue(
            eventually(within: 30) { session.listeningReader?.book.id == folder.second.id },
            "The next book did not take the place behind"
        )
        let behind = try XCTUnwrap(session.listeningReader)
        XCTAssertEqual(made.count, 3, "Each reader is announced once")
        XCTAssertTrue(made.contains { $0 === behind }, "The next book behind the screen was not announced")
        XCTAssertTrue(made.contains { $0 === onScreen })
    }

    /// A running sleep timer goes on with the next book, as the phone's one
    /// timer, which every reader of its session shares.
    func testASleepTimerGoesOnWithTheNextBook() throws {
        preserveSleepTimers()
        let folder = try makeFolderWorld("PhoneNextTimer")
        let session = makeSession(in: folder.world)
        let first = try XCTUnwrap(session.open(folder.first))
        waitForReaderToLoad(first)
        let timer = first.sleepTimerService
        timer.start(duration: .minutes(30), ownerID: first.readerID, onExpire: {})

        first.handleEndOfBook()
        XCTAssertTrue(eventually(within: 30) { session.reader?.book.id == folder.second.id }, "The next book never opened")
        let second = try XCTUnwrap(session.reader)
        waitForReaderToLoad(second)

        XCTAssertTrue(first.hasClosed)
        XCTAssertTrue(second.sleepTimerService === timer, "The phone's readers do not share its one timer")
        XCTAssertTrue(timer.isActive, "Closing the old reader stopped the timer")
        XCTAssertEqual(timer.ownerID, second.readerID, "The new reader did not take the timer")
        XCTAssertEqual(timer.duration, .minutes(30))
    }

    /// A request for the book already open leaves its reader to claim it.
    func testARequestForTheOpenBookLeavesItsReaderToClaimIt() throws {
        let world = try makeIntegrationWorld("PhoneNextOpen")
        let previous = try world.makeSilentAudioBook(title: "Previous Volume", trackDurations: [5])
        let book = try world.makeSilentAudioBook(title: "Next Volume", trackDurations: [5, 5])
        let session = makeSession(in: world)
        let reader = try XCTUnwrap(session.open(book))
        waitForReaderToLoad(reader)

        let request = world.autoplayRequests.request(for: book.id, from: previous.id)
        world.notifications.post(name: .continueToNextBook, object: nil, userInfo: request.notificationUserInfo)

        XCTAssertTrue(eventually(within: 30) { session.snapshot?.isPlaying == true }, "The reader did not claim it")
        XCTAssertTrue(session.reader === reader)
    }

    /// Next in Folder's request opens the book, a turn after the post, and does
    /// not play it.
    func testARequestToOpenABookOpensItWithoutPlaying() throws {
        let world = try makeIntegrationWorld("PhoneOpenRequest")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5, 5])
        let session = makeSession(in: world)

        world.notifications.post(name: .openBookWindow, object: book.id)
        XCTAssertNil(session.reader, "Handled inside the post, not a turn later")

        XCTAssertTrue(eventually { session.reader?.book.id == book.id }, "The book never opened")
        let reader = try XCTUnwrap(session.reader)
        waitForReaderToLoad(reader)
        spinMainRunLoop(for: 0.2)
        XCTAssertFalse(reader.isPlaybackUnderWay, "Opening alone played the book")
    }

    /// A notification posted off the main thread reaches the session safely, on
    /// the main actor: a main-actor closure run on another thread stops the app.
    func testARequestPostedOffTheMainThreadIsHandledOnTheMainActor() throws {
        let world = try makeIntegrationWorld("PhoneOffMain")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let session = makeSession(in: world)
        let center = world.notifications
        let bookID = book.id

        DispatchQueue.global().async {
            center.post(name: .openBookWindow, object: bookID)
        }

        XCTAssertTrue(eventually { session.reader?.book.id == bookID }, "The book never opened")
    }

    /// A book that has left the library opens nothing, keeps the book open, and
    /// leaves no request waiting.
    func testARequestForAMissingBookOpensNothing() throws {
        let world = try makeIntegrationWorld("PhoneMissing")
        let open = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let session = makeSession(in: world)
        let reader = try XCTUnwrap(session.open(open))
        waitForReaderToLoad(reader)
        let missing = UUID()

        let request = world.autoplayRequests.request(for: missing, from: open.id)
        world.notifications.post(name: .continueToNextBook, object: nil, userInfo: request.notificationUserInfo)

        XCTAssertTrue(eventually { !world.autoplayRequests.hasRequest(for: missing) }, "The request still waits")
        XCTAssertTrue(session.reader === reader)
        XCTAssertFalse(reader.hasClosed)
    }

    /// An import that opens its book goes through `readerOpener`: the book
    /// opens, and the navigation is asked to show its screen; a book that is
    /// gone asks for nothing.
    func testTheLibrarysOpenerOpensTheBookAndAsksForItsScreen() throws {
        let world = try makeIntegrationWorld("PhoneOpener")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let session = makeSession(in: world)
        let shown = recordScreenRequests(of: session)

        world.library.readerOpener(book.id)
        world.library.readerOpener(UUID())

        XCTAssertEqual(session.reader?.book.id, book.id)
        XCTAssertEqual(shown(), [book.id])
    }

    // MARK: - The Snapshot

    /// The reader publishing, and its place moving, changes nothing a view of
    /// the session would hear. A check that the reader did publish keeps this
    /// from passing with nothing to do.
    func testThePlaceMovingPublishesNothing() throws {
        let world = try makeIntegrationWorld("PhoneSnapshotPlace")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5, 5])
        let session = makeSession(in: world)
        let reader = try XCTUnwrap(session.open(book))
        waitForReaderToLoad(reader)
        XCTAssertTrue(eventually { session.snapshot?.isLoading == false })
        spinMainRunLoop(for: 0.1)

        var sessionPublishes = 0
        var readerPublishes = 0
        session.objectWillChange.sink { sessionPublishes += 1 }.store(in: &subscriptions)
        reader.objectWillChange.sink { readerPublishes += 1 }.store(in: &subscriptions)
        for offset in stride(from: 5, through: 45, by: 5) {
            reader.currentCharacterOffset = offset
            reader.objectWillChange.send()
            spinMainRunLoop(for: 0.02)
        }

        XCTAssertGreaterThan(readerPublishes, 0, "The reader never published, so this checked nothing")
        XCTAssertEqual(sessionPublishes, 0, "A view of the session would redraw as the book's place moves")
    }

    /// While a book plays, with its reader publishing as it goes, a snapshot is
    /// published only when it differs from the last.
    func testTheSnapshotChangesOnlyAsPlayStartsAndStops() throws {
        let world = try makeIntegrationWorld("PhoneSnapshotPlay")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [30])
        let session = makeSession(in: world)
        let reader = try XCTUnwrap(session.open(book))
        waitForReaderToLoad(reader)
        XCTAssertTrue(eventually { session.snapshot?.isLoading == false })
        spinMainRunLoop(for: 0.1)

        var published: [PhoneReaderSnapshot] = []
        session.$snapshot.dropFirst().compactMap { $0 }.sink { published.append($0) }.store(in: &subscriptions)

        session.togglePlayPause()
        XCTAssertTrue(eventually(within: 30) { session.snapshot?.isPlaying == true }, "Never played")
        spinMainRunLoop(for: 0.5)
        session.togglePlayPause()
        XCTAssertTrue(eventually(within: 30) { session.snapshot?.isPlaying == false }, "Never paused")

        XCTAssertEqual(published.first?.isPlaying, true)
        XCTAssertEqual(published.last?.isPlaying, false)
        for (earlier, later) in zip(published, published.dropFirst()) {
            XCTAssertNotEqual(earlier, later, "A snapshot was published with nothing changed")
        }
    }

    /// The title follows a rename; a closed reader's changes reach nothing.
    func testTheSnapshotFollowsTheOpenReaderAlone() throws {
        let world = try makeIntegrationWorld("PhoneSnapshotRename")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let session = makeSession(in: world)
        let reader = try XCTUnwrap(session.open(book))
        waitForReaderToLoad(reader)
        session.noteBookEngaged()

        reader.book.title = "Harbour Tide Tables"
        XCTAssertTrue(eventually { session.snapshot?.title == "Harbour Tide Tables" }, "The title never changed")

        session.closeReader()
        reader.book.title = "Renamed After Closing"
        spinMainRunLoop(for: 0.1)
        XCTAssertNil(session.snapshot)
    }

    /// The snapshot carries the reader's error alert, the Mac's, as it comes
    /// and as it goes, so the reader's screen can show it without observing
    /// the reader.
    func testTheSnapshotCarriesTheReadersErrorAlert() throws {
        let world = try makeIntegrationWorld("PhoneSnapshotError")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let session = makeSession(in: world)
        let reader = try XCTUnwrap(session.open(book))
        waitForReaderToLoad(reader)
        XCTAssertTrue(eventually { session.snapshot?.isLoading == false })
        XCTAssertNil(session.snapshot?.errorAlert)

        reader.errorMessage = "The audio file could not be played."
        XCTAssertTrue(eventually { session.snapshot?.errorAlert != nil }, "The error never reached the snapshot")
        XCTAssertEqual(session.snapshot?.errorAlert, reader.errorAlert)
        XCTAssertEqual(session.snapshot?.errorAlert?.message, "The audio file could not be played.")

        reader.errorMessage = nil
        XCTAssertTrue(eventually { session.snapshot?.errorAlert == nil }, "The error never went from the snapshot")
    }

    // MARK: - Reopening

    /// The book open is kept for the next launch, with whether its screen was
    /// showing, and a new session finds it there; closing keeps nothing.
    func testTheOpenBookIsKeptForTheNextLaunch() throws {
        let world = try makeIntegrationWorld("PhoneReopen")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let preferences = makeSandboxedPreferences("PhoneReopen")
        let session = makeSession(in: world, preferences: preferences)
        let reader = try XCTUnwrap(session.open(book))
        waitForReaderToLoad(reader)
        XCTAssertTrue(eventually { preferences.string(forKey: PhoneSession.openingBookKey) == nil }, "Still opening")
        session.noteAppLeavingForeground(readerScreenShowing: true)

        let nextLaunch = makeSession(in: world, preferences: preferences)
        guard case let .reopen(reopening) = nextLaunch.takeReopeningAtLaunch(fileOpened: false) else {
            return XCTFail("Nothing to reopen")
        }
        XCTAssertEqual(reopening.book.id, book.id)
        XCTAssertTrue(reopening.showsReaderScreen)
        XCTAssertFalse(reopening.readFromReadingList)

        session.closeReader()
        XCTAssertNil(nextLaunch.bookToReopenAtLaunch, "A closed book opens again")
    }

    /// A file opened at launch wins over reopening.
    func testAFileOpenedAtLaunchWinsOverReopening() throws {
        let world = try makeIntegrationWorld("PhoneReopenFile")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let preferences = makeSandboxedPreferences("PhoneReopenFile")
        preferences.set(book.id.uuidString, forKey: PhoneSession.reopenBookKey)
        let session = makeSession(in: world, preferences: preferences)

        XCTAssertEqual(session.takeReopeningAtLaunch(fileOpened: true), .nothing)
    }

    /// A book the app closed while opening is not opened again: the marks are
    /// cleared, and the sentence to say names it. Once its load ends, the mark
    /// goes by itself.
    func testABookThatClosedTheAppWhileOpeningIsNotReopened() throws {
        let world = try makeIntegrationWorld("PhoneOpeningCrash")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let preferences = makeSandboxedPreferences("PhoneOpeningCrash")
        let session = makeSession(in: world, preferences: preferences)

        let reader = try XCTUnwrap(session.open(book))
        XCTAssertEqual(preferences.string(forKey: PhoneSession.openingBookKey), book.id.uuidString, "Not marked first")
        waitForReaderToLoad(reader)
        XCTAssertTrue(
            eventually { preferences.string(forKey: PhoneSession.openingBookKey) == nil },
            "The mark outlived the load"
        )

        // As a launch finds it after the app ended during the load.
        preferences.set(book.id.uuidString, forKey: PhoneSession.openingBookKey)
        let nextLaunch = makeSession(in: world, preferences: preferences)
        XCTAssertNil(nextLaunch.bookToReopenAtLaunch)
        XCTAssertEqual(
            nextLaunch.takeReopeningAtLaunch(fileOpened: false),
            .closedWhileOpening("TextMouth closed while opening Tide Tables, so it wasn't reopened.")
        )
        XCTAssertNil(preferences.string(forKey: PhoneSession.openingBookKey))
        XCTAssertNil(preferences.string(forKey: PhoneSession.reopenBookKey))
    }

    /// The reopen keys go with the crash guard, as the session is made, not
    /// only when the first activation acts on the verdict: the guard is gone
    /// from disk at that moment, so an app that ends again before its first
    /// activation must find no keys naming the book it ended opening. The
    /// launch after that one reopens nothing and says nothing.
    func testTheReopenKeysGoWithTheCrashGuardWhenTheSessionIsMade() throws {
        let world = try makeIntegrationWorld("PhoneReopenKeysGuard")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let preferences = makeSandboxedPreferences("PhoneReopenKeysGuard")
        // As the run that ended while opening the book left the disk.
        preferences.set(book.id.uuidString, forKey: PhoneSession.openingBookKey)
        preferences.set(book.id.uuidString, forKey: PhoneSession.reopenBookKey)
        preferences.set(true, forKey: PhoneSession.reopenShowsReaderKey)
        preferences.set(true, forKey: PhoneSession.reopenFromReadingListKey)

        // This launch's session is made; the app ends before the first
        // activation, so `takeReopeningAtLaunch` never runs.
        let crashedLaunch = makeSession(in: world, preferences: preferences)
        let keys = [
            PhoneSession.openingBookKey, PhoneSession.reopenBookKey,
            PhoneSession.reopenShowsReaderKey, PhoneSession.reopenFromReadingListKey,
        ]
        let leftOnDisk = keys.filter { preferences.object(forKey: $0) != nil }
        XCTAssertEqual(leftOnDisk, [], "These keys outlived the crash guard's clearing: \(leftOnDisk)")

        // The next launch, made before the crashed launch ever takes its
        // verdict, as after a crash before activation: nothing to reopen.
        // (With the keys still on disk, it would reopen the book.)
        let nextLaunch = makeSession(in: world, preferences: preferences)
        XCTAssertNil(nextLaunch.bookToReopenAtLaunch, "The book that crashed the app reopens")
        XCTAssertEqual(nextLaunch.takeReopeningAtLaunch(fileOpened: false), .nothing)

        // The launch that decides still knows, from memory, to say so.
        XCTAssertNil(crashedLaunch.bookToReopenAtLaunch)
        XCTAssertEqual(
            crashedLaunch.takeReopeningAtLaunch(fileOpened: false),
            .closedWhileOpening("TextMouth closed while opening Tide Tables, so it wasn't reopened.")
        )
    }

    /// A book opened since the session was made, as a Play from the lock
    /// screen opens one before the first activation, keeps its reopen keys
    /// when the verdict on the crashed book is taken: the verdict says the
    /// crashed book wasn't reopened, and clears nothing of the open one's.
    /// (The keys of the crashed book were cleared as the session was made.)
    func testTheVerdictLeavesTheKeysOfABookOpenedSince() throws {
        let world = try makeIntegrationWorld("PhoneReopenKeysSince")
        let crashed = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let playing = try world.makeSilentAudioBook(title: "Salt Marsh", trackDurations: [5])
        let preferences = makeSandboxedPreferences("PhoneReopenKeysSince")
        // The last run ended while opening Tide Tables.
        preferences.set(crashed.id.uuidString, forKey: PhoneSession.openingBookKey)
        let session = makeSession(in: world, preferences: preferences)

        // A Play from the lock screen opens Salt Marsh before any activation.
        let reader = try XCTUnwrap(session.open(playing))
        waitForReaderToLoad(reader)
        XCTAssertEqual(preferences.string(forKey: PhoneSession.reopenBookKey), playing.id.uuidString, "Salt Marsh's keys were not written")

        // The first activation: a book is open, so no file or reopening wins,
        // and the verdict on the crashed book is taken.
        XCTAssertEqual(
            session.takeReopeningAtLaunch(fileOpened: true),
            .closedWhileOpening("TextMouth closed while opening Tide Tables, so it wasn't reopened.")
        )
        XCTAssertEqual(
            preferences.string(forKey: PhoneSession.reopenBookKey), playing.id.uuidString,
            "The verdict cleared the keys of the book opened since"
        )
    }

    /// With no crash guard, the session being made leaves the reopen keys for
    /// the first activation, which opens the book.
    func testTheReopenKeysStandWhenNoCrashGuardIsFound() throws {
        let world = try makeIntegrationWorld("PhoneReopenKeysStand")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let preferences = makeSandboxedPreferences("PhoneReopenKeysStand")
        preferences.set(book.id.uuidString, forKey: PhoneSession.reopenBookKey)
        preferences.set(true, forKey: PhoneSession.reopenShowsReaderKey)

        let session = makeSession(in: world, preferences: preferences)

        XCTAssertEqual(preferences.string(forKey: PhoneSession.reopenBookKey), book.id.uuidString)
        XCTAssertEqual(session.bookToReopenAtLaunch?.id, book.id)
    }

    /// A book no longer in the library, or a damaged value, clears what is kept.
    func testABookGoneFromTheLibraryClearsWhatIsKept() throws {
        let world = try makeIntegrationWorld("PhoneReopenGone")
        let preferences = makeSandboxedPreferences("PhoneReopenGone")
        let session = makeSession(in: world, preferences: preferences)
        for value in [UUID().uuidString, "not an identifier"] {
            preferences.set(value, forKey: PhoneSession.reopenBookKey)
            XCTAssertEqual(session.takeReopeningAtLaunch(fileOpened: false), .nothing)
            XCTAssertNil(preferences.string(forKey: PhoneSession.reopenBookKey), value)
        }
    }

    /// With a book behind the one on screen, the book behind is kept, without
    /// its screen: the one on screen has not been played.
    func testTheBookBehindIsTheOneKept() throws {
        let pair = try makePlayingPair("PhoneReopenPair")

        pair.session.noteAppLeavingForeground(readerScreenShowing: true)

        XCTAssertEqual(pair.session.bookToReopenAtLaunch?.id, pair.firstBook.id)
        XCTAssertFalse(pair.preferences.bool(forKey: PhoneSession.reopenShowsReaderKey))
    }

    // MARK: - Support

    /// A world with one book playing and a second opened over it, loaded.
    private struct PlayingPair {
        let world: IntegrationWorld
        let session: PhoneSession
        let preferences: UserDefaults
        let firstBook: Book
        let secondBook: Book
        let first: ReaderViewModel
        let second: ReaderViewModel
    }

    /// Makes a `PlayingPair`, failing the test when the first never plays.
    private func makePlayingPair(_ label: String, nowPlaying: NowPlayingService? = nil) throws -> PlayingPair {
        let world = try makeIntegrationWorld(label)
        let firstBook = try world.makeSilentAudioBook(title: "Playing Volume", trackDurations: [30])
        let secondBook = try world.makeSilentAudioBook(title: "Looked-At Volume", trackDurations: [30])
        let preferences = makeSandboxedPreferences(label)
        let session = makeSession(in: world, preferences: preferences, nowPlaying: nowPlaying)
        let first = try XCTUnwrap(session.open(firstBook))
        waitForReaderToLoad(first)
        session.togglePlayPause()
        XCTAssertTrue(eventually(within: 30) { first.isPlaybackActivelyAdvancing }, "The first never played")
        let second = try XCTUnwrap(session.open(secondBook))
        waitForReaderToLoad(second)
        XCTAssertTrue(eventually { preferences.string(forKey: PhoneSession.openingBookKey) == nil }, "Still opening")
        return PlayingPair(
            world: world,
            session: session,
            preferences: preferences,
            firstBook: firstBook,
            secondBook: secondBook,
            first: first,
            second: second
        )
    }

    /// A sound service whose sounds reach a player that records them and plays
    /// nothing aloud.
    private func makeSounds() -> SoundEffectService {
        SoundEffectService(
            preferences: makeSandboxedPreferences("Sounds"),
            player: HeldSoundEffectPlayer(holding: false)
        )
    }

    /// A session over `world`, whose readers the world makes, over its own
    /// notification center and a media session of the test's own, which shows
    /// nothing to the system. Its readers close when the test ends, before the
    /// world is taken apart: tear-down blocks run last registered first.
    private func makeSession(
        in world: IntegrationWorld,
        sounds: SoundEffectService? = nil,
        preferences: UserDefaults? = nil,
        nowPlaying: NowPlayingService? = nil
    ) -> PhoneSession {
        let media = nowPlaying ?? NowPlayingService(installsSystemIntegrations: false, diagnosticSink: { _ in })
        // The phone shows one reader at a time, and its readers share one
        // sleep timer, as `SleepTimerService.shared` is on an iPhone.
        let phoneTimer = SleepTimerService()
        let session = PhoneSession(
            library: world.library,
            settings: world.settings,
            soundEffects: sounds ?? makeSounds(),
            notificationCenter: world.notifications,
            autoplayRequests: world.autoplayRequests,
            preferences: preferences ?? makeSandboxedPreferences("Session"),
            makeReader: { book in world.openReader(for: book, nowPlaying: media, sleepTimer: phoneTimer) }
        )
        addTeardownBlock { session.closeReader() }
        return session
    }

    /// Puts the app's last opened book back when the test ends: every reader
    /// made in a test records itself there.
    private func preserveLastOpenedBook() {
        let config = ConfigService.shared
        let saved = config.config.lastOpenedBookID
        addTeardownBlock { config.config.lastOpenedBookID = saved }
    }

    /// Records each request to show the reader's screen, and returns them when
    /// called.
    private func recordScreenRequests(of session: PhoneSession) -> () -> [UUID] {
        var requested: [UUID] = []
        session.showReaderRequests.sink { requested.append($0) }.store(in: &subscriptions)
        return { requested }
    }

    /// Three books in one folder of a world that goes on to the next book at
    /// each one's end.
    private struct FolderWorld {
        let world: IntegrationWorld
        let first: Book
        let second: Book
        let third: Book
    }

    /// Makes a `FolderWorld`. The titles order the books in their folder, and
    /// the tracks are longer than any test runs.
    private func makeFolderWorld(_ label: String) throws -> FolderWorld {
        let world = try makeIntegrationWorld(label)
        let book: (String) throws -> Book = { title in
            try world.makeSilentAudioBook(title: title, trackDurations: [5, 5], endOfBook: .continueNext)
        }
        let first = try book("A Volume")
        let second = try book("B Volume")
        let third = try book("C Volume")
        world.library.library.folders = [BookFolder(name: world.folder.path)]
        world.settings.endOfBookBehavior = .continueNext
        return FolderWorld(world: world, first: first, second: second, third: third)
    }
}
