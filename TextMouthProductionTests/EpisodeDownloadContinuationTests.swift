import Combine
import XCTest
@testable import TextMouth

/// A feed's episode that ends goes on to the next *listed* episode, whether
/// or not its file is here (FR19, task B3): when it is not, the reader
/// downloads it, says so, and hands listening over once it arrives, or says
/// why playback stopped when the download fails.
///
/// The feed lists, newest first, Top part, Middle part, and Bottom part. The
/// middle one is downloaded, an article whose reader plays nothing: its end
/// is reached directly (`handleEndOfBook()`). The others are audio
/// episodes, short and silent, served by the stub server, or downloaded
/// already as the test says. Announcements are recorded instead of spoken,
/// and each reader listens on a notification center of its own with a
/// request store of its own, so the running app never sees them.
@MainActor
final class EpisodeDownloadContinuationTests: FeedItemIndexTestCase {

    /// Subscriptions a test keeps until it ends.
    private var subscriptions = Set<AnyCancellable>()

    // MARK: - The Episode Below

    /// With "Play the episode below" and the next episode not here, the end
    /// says that it downloads, the download starts once, as the listener's,
    /// and when it arrives "Starting" is said and its book is asked for.
    func testTheEpisodeBelowIsDownloadedAndStartsOnceItArrives() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookBelow), global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.handleEndOfBook()

        XCTAssertEqual(heard.announced, ["Finished: Middle part. Downloading the next episode: Bottom part."])
        await waitFor("the next episode asks to start") { !heard.asked.isEmpty }
        // Long enough for a second request to arrive.
        try? await Task.sleep(for: .seconds(ReaderViewModel.continueToNextBookDelay * 2))

        let bottom = try XCTUnwrap(book(of: "guid:ep-1", in: setup))
        XCTAssertEqual(heard.announced, [
            "Finished: Middle part. Downloading the next episode: Bottom part.",
            "Starting: Bottom part",
        ])
        XCTAssertEqual(heard.asked, [bottom.id])
        XCTAssertEqual(heard.downloadsStarted, ["guid:ep-1"])
        XCTAssertEqual(setup.world.center.store.record(of: setup.feedID)?.item("guid:ep-1")?.downloadOrigin, .listener)
        XCTAssertNil(reader.nextEpisodeWait, "The wait outlived the download")
    }

    /// The same where the feed's options are standard and the global setting
    /// is Continue to Next Book.
    func testTheGlobalContinueToNextBookDownloadsTheEpisodeBelow() async throws {
        let setup = try await makeFeed(options: nil, global: .continueNext)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.handleEndOfBook()
        await waitFor("the next episode asks to start") { !heard.asked.isEmpty }

        XCTAssertEqual(heard.announced, [
            "Finished: Middle part. Downloading the next episode: Bottom part.",
            "Starting: Bottom part",
        ])
        XCTAssertEqual(heard.asked, [try XCTUnwrap(book(of: "guid:ep-1", in: setup)).id])
        XCTAssertEqual(heard.downloadsStarted, ["guid:ep-1"])
    }

    /// "Play the episode above" downloads the one above, the newer.
    func testTheEpisodeAboveIsDownloadedWhenTheFeedPlaysTheEpisodeAbove() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookAbove), global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.handleEndOfBook()
        await waitFor("the next episode asks to start") { !heard.asked.isEmpty }

        XCTAssertEqual(heard.announced, [
            "Finished: Middle part. Downloading the next episode: Top part.",
            "Starting: Top part",
        ])
        XCTAssertEqual(heard.asked, [try XCTUnwrap(book(of: "guid:ep-3", in: setup)).id])
        XCTAssertEqual(heard.downloadsStarted, ["guid:ep-3"])
    }

    // MARK: - When the Download Fails

    /// A download that fails says why playback stopped, in the item's own
    /// sentence, and nothing plays.
    func testAFailedDownloadSaysWhyPlaybackStopped() async throws {
        let setup = try await makeFeed(
            options: ListeningOptions(continuation: .playBookBelow),
            global: .stop,
            bottomAnswer: StubResponse(status: 404)
        )
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.handleEndOfBook()
        await waitFor("the failure is announced") { heard.announced.count == 2 }
        try? await Task.sleep(for: .seconds(ReaderViewModel.continueToNextBookDelay * 2))

        XCTAssertEqual(heard.announced, [
            "Finished: Middle part. Downloading the next episode: Bottom part.",
            "The next episode could not be downloaded, so playback stopped. The server says the file is gone.",
        ])
        XCTAssertEqual(heard.asked, [])
        XCTAssertNil(reader.nextEpisodeWait, "The wait outlived the failure")
        XCTAssertNil(book(of: "guid:ep-1", in: setup))
    }

    // MARK: - When the Listener Moves On

    /// The reader plays again while the download runs: when the episode
    /// arrives nothing is handed over.
    func testNothingIsHandedOverWhenTheReaderPlaysAgainMeanwhile() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookBelow), global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.handleEndOfBook()
        // The listener rewinds or plays on: the book no longer rests finished.
        // The download cannot arrive before this line, which runs first on
        // the main actor.
        reader.hasFinishedBook = false
        await waitFor("the download arrives") { book(of: "guid:ep-1", in: setup) != nil }
        try? await Task.sleep(for: .seconds(ReaderViewModel.continueToNextBookDelay * 2))

        XCTAssertEqual(heard.announced, ["Finished: Middle part. Downloading the next episode: Bottom part."])
        XCTAssertEqual(heard.asked, [])
        XCTAssertNil(reader.nextEpisodeWait, "The wait outlived the download")
    }

    /// The reader closes while the download runs: nothing is handed over, and
    /// nothing is said, when it arrives.
    func testNothingIsHandedOverWhenTheReaderClosesMeanwhile() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookBelow), global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.handleEndOfBook()
        reader.close()
        XCTAssertNil(reader.nextEpisodeWait, "Closing left the wait")
        await waitFor("the download arrives") { book(of: "guid:ep-1", in: setup) != nil }
        try? await Task.sleep(for: .seconds(ReaderViewModel.continueToNextBookDelay * 2))

        XCTAssertEqual(heard.announced, ["Finished: Middle part. Downloading the next episode: Bottom part."])
        XCTAssertEqual(heard.asked, [])
    }

    /// A failure after the listener moved on says nothing.
    func testAFailureAfterTheListenerMovedOnSaysNothing() async throws {
        let setup = try await makeFeed(
            options: ListeningOptions(continuation: .playBookBelow),
            global: .stop,
            bottomAnswer: StubResponse(status: 404)
        )
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.handleEndOfBook()
        reader.hasFinishedBook = false
        await waitFor("the download fails") {
            setup.world.center.store.record(of: setup.feedID)?.item("guid:ep-1")?.state.failureReason != nil
        }
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(heard.announced, ["Finished: Middle part. Downloading the next episode: Bottom part."])
        XCTAssertNil(reader.nextEpisodeWait, "The wait outlived the failure")
    }

    // MARK: - The Sleep Timer

    /// A running timer counting minutes does not keep the next episode from
    /// being downloaded (0.2.5): it goes on with the episode, which starts
    /// once it arrives, and the timer is asked for by the episode's reader.
    func testARunningSleepTimerGoesOnWithTheNextEpisode() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookBelow), global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }
        startSleepTimer(.minutes(30), for: reader)

        reader.handleEndOfBook()
        await waitFor("the next episode asks to start") { !heard.asked.isEmpty }

        let bottom = try XCTUnwrap(book(of: "guid:ep-1", in: setup))
        XCTAssertEqual(heard.announced, [
            "Finished: Middle part. Downloading the next episode: Bottom part.",
            "Starting: Bottom part",
        ])
        XCTAssertEqual(heard.asked, [bottom.id])
        XCTAssertEqual(heard.downloadsStarted, ["guid:ep-1"])
        XCTAssertTrue(reader.sleepTimerService.isActive, "The timer ended with the episode")
        XCTAssertTrue(reader.sleepTimerService.isHeld(forBook: bottom.id), "The timer was not held for the episode")
    }

    /// The timer runs out while the next episode downloads: it has ended
    /// listening, and the episode is not started when it arrives; the timer's
    /// own expiry is all that is said after the download began.
    func testATimerThatRunsOutWhileTheEpisodeDownloadsKeepsItFromStarting() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookBelow), global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }
        startSleepTimer(.minutes(30), for: reader)
        reader.startSleepTimer(duration: .minutes(30))

        reader.handleEndOfBook()
        reader.sleepTimerService._expireForTesting()
        await waitFor("the download arrives") { book(of: "guid:ep-1", in: setup) != nil }
        try? await Task.sleep(for: .seconds(ReaderViewModel.continueToNextBookDelay * 2))

        XCTAssertEqual(heard.announced, [
            "Finished: Middle part. Downloading the next episode: Bottom part.",
            ReaderViewModel.sleepTimerExpiredAnnouncement,
        ])
        XCTAssertEqual(heard.asked, [], "The episode started after the timer ran out")
        XCTAssertNil(reader.nextEpisodeWait)
    }

    /// This reader's sleep timer set for the end of the book, which ends
    /// listening at the book's end: the note, and no download.
    func testATimerForTheBooksEndKeepsTheNextEpisodeFromBeingDownloaded() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookBelow), global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }
        startSleepTimer(.endOfBook, for: reader)

        reader.handleEndOfBook()
        try? await Task.sleep(for: .seconds(ReaderViewModel.continueToNextBookDelay * 2))

        XCTAssertEqual(heard.announced, ["Finished: Middle part. Next book not started because of the sleep timer."])
        XCTAssertEqual(heard.downloadsStarted, [])
        XCTAssertEqual(heard.asked, [])
        XCTAssertNil(reader.nextEpisodeWait)
        XCTAssertEqual(setup.world.center.store.record(of: setup.feedID)?.item("guid:ep-1")?.state, .notDownloaded)
    }

    // MARK: - Later End Decisions End the Wait

    /// A timer counting minutes started during the wait goes on with the
    /// episode (0.2.5): it starts once it arrives.
    func testASleepTimerStartedDuringTheWaitGoesOnWithTheEpisode() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookBelow), global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.handleEndOfBook()
        startSleepTimer(.minutes(30), for: reader)
        await waitFor("the next episode asks to start") { !heard.asked.isEmpty }

        let bottom = try XCTUnwrap(book(of: "guid:ep-1", in: setup))
        XCTAssertEqual(heard.announced, [
            "Finished: Middle part. Downloading the next episode: Bottom part.",
            "Starting: Bottom part",
        ])
        XCTAssertEqual(heard.asked, [bottom.id])
        XCTAssertTrue(reader.sleepTimerService.isHeld(forBook: bottom.id))
    }

    /// A sleep timer for the end of the book is started during the wait, after
    /// the book ended, and the download then finishes: the timer has not run
    /// out, so it goes on with the episode like a running timer (0.2.5). Its
    /// old expectation, that the episode did not start, was the bug: the timer
    /// stayed set for an end already past and blocked every later Play.
    func testATimerForTheBooksEndStartedDuringTheWaitGoesOnWithTheEpisode() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookBelow), global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.handleEndOfBook()
        startSleepTimer(.endOfBook, for: reader)
        await waitFor("the next episode asks to start") { !heard.asked.isEmpty }

        let bottom = try XCTUnwrap(book(of: "guid:ep-1", in: setup))
        XCTAssertEqual(heard.announced, [
            "Finished: Middle part. Downloading the next episode: Bottom part.",
            "Starting: Bottom part",
        ])
        XCTAssertEqual(heard.asked, [bottom.id])
        XCTAssertTrue(reader.sleepTimerService.isActive, "The timer ended with the episode")
        XCTAssertTrue(reader.sleepTimerService.isHeld(forBook: bottom.id), "The timer was not held for the episode")
        XCTAssertNil(reader.nextEpisodeWait, "The wait outlived the download")
    }

    /// A timer set during the wait that runs out before the episode arrives
    /// has ended listening, as one set before the wait does: the episode is
    /// not started, and the expiry is all that is said.
    func testATimerSetDuringTheWaitThatRunsOutBeforeTheEpisodeArrivesEndsListening() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookBelow), global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.handleEndOfBook()
        startSleepTimer(.minutes(30), for: reader)
        reader.startSleepTimer(duration: .minutes(30))
        reader.sleepTimerService._expireForTesting()
        await waitFor("the download arrives") { book(of: "guid:ep-1", in: setup) != nil }
        try? await Task.sleep(for: .seconds(ReaderViewModel.continueToNextBookDelay * 2))

        XCTAssertEqual(heard.announced, [
            "Finished: Middle part. Downloading the next episode: Bottom part.",
            ReaderViewModel.sleepTimerExpiredAnnouncement,
        ])
        XCTAssertEqual(heard.asked, [], "The episode started after the timer ran out")
    }

    /// Play during the wait, with a sleep timer fading out meanwhile, says
    /// that the next book was not started, and ends the wait: the download's
    /// arrival hands nothing over and says nothing more. (A timer for the end
    /// of the book set after the book ended has not run out: it goes on with
    /// the next book, and does not end listening, 0.2.5.)
    func testPlayWithASleepTimerEndsTheWait() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookBelow), global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.handleEndOfBook()
        startSleepTimer(.minutes(1), for: reader)
        reader.sleepTimerService.start(duration: .minutes(1), ownerID: reader.readerID, onExpire: {}, fadeOutDuration: 5)
        reader.sleepTimerService._expireForTesting()
        XCTAssertTrue(reader.sleepTimerService.isFadingOut)
        reader.play()
        XCTAssertEqual(heard.announced.last, "Finished: Middle part. Next book not started because of the sleep timer.")
        XCTAssertNil(reader.nextEpisodeWait, "Play left the wait")
        let saidSoFar = heard.announced

        await waitFor("the download arrives") { book(of: "guid:ep-1", in: setup) != nil }
        try? await Task.sleep(for: .seconds(ReaderViewModel.continueToNextBookDelay * 2))

        XCTAssertEqual(heard.announced, saidSoFar, "The arrival said something after the wait ended")
        XCTAssertEqual(heard.asked, [])
    }

    /// The feed's options are set to Stop during the wait, and Play is
    /// pressed: the end stops, and the download's arrival hands nothing over.
    func testPlayAfterTheOptionsChangedToStopEndsTheWait() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookBelow), global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.handleEndOfBook()
        setup.world.center.setListeningOptions(ListeningOptions(continuation: .stop), of: setup.feedID)
        reader.play()
        XCTAssertEqual(heard.announced.last, "Finished: Middle part")
        XCTAssertNil(reader.nextEpisodeWait, "Play left the wait")

        await waitFor("the download arrives") { book(of: "guid:ep-1", in: setup) != nil }
        try? await Task.sleep(for: .seconds(ReaderViewModel.continueToNextBookDelay * 2))

        XCTAssertEqual(heard.announced, [
            "Finished: Middle part. Downloading the next episode: Bottom part.",
            "Finished: Middle part",
        ])
        XCTAssertEqual(heard.asked, [])
    }

    /// A second end decision that finds nothing to follow ends the wait too.
    func testASecondEndDecisionWithNothingToFollowEndsTheWait() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookBelow), global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.handleEndOfBook()
        XCTAssertNotNil(reader.nextEpisodeWait, "The wait did not begin")
        // The bottom episode is played meanwhile, so nothing below remains
        // that the feed does not skip.
        setup.world.center.store.updateItem("guid:ep-1", of: setup.feedID) { $0.playedDate = Self.date(5) }
        reader.play()
        XCTAssertEqual(heard.announced.last, "Finished: Middle part. Every book after it in the folder is finished.")
        XCTAssertNil(reader.nextEpisodeWait, "The second decision left the wait")

        await waitFor("the download arrives") { book(of: "guid:ep-1", in: setup) != nil }
        try? await Task.sleep(for: .seconds(ReaderViewModel.continueToNextBookDelay * 2))

        XCTAssertEqual(heard.asked, [])
        XCTAssertEqual(heard.announced.count, 2, "The arrival said something after the wait ended")
    }

    // MARK: - Another Reader Takes the Controls

    /// Two readers, one of the middle episode and one of the top episode
    /// (downloaded), joined to one private Now Playing coordinator.
    private struct TwoReaders {
        let setup: Setup
        let heard: Heard
        let coordinator: NowPlayingService
        /// Reads the middle episode, whose end starts the wait.
        let ending: ReaderViewModel
        /// Reads the top episode, the other window.
        let other: ReaderViewModel
    }

    /// A feed whose middle and top episodes are downloaded, each open in a
    /// loaded reader on one coordinator of its own. `bottomAnswer` is what
    /// the server answers for the bottom episode, which the end downloads.
    private func openTwoReaders(bottomAnswer: StubResponse? = nil) async throws -> TwoReaders {
        let setup = try await makeFeed(
            options: ListeningOptions(continuation: .playBookBelow),
            global: .stop,
            topIsDownloaded: true,
            bottomAnswer: bottomAnswer
        )
        let heard = listen(to: setup)
        let coordinator = NowPlayingService(installsSystemIntegrations: false, diagnosticSink: { _ in })
        let ending = try openReader(for: setup.middle, in: setup, nowPlaying: coordinator)
        let top = try XCTUnwrap(book(of: "guid:ep-3", in: setup))
        let other = try openReader(for: top, in: setup, nowPlaying: coordinator)
        await waitFor("both episodes load in their readers") { !ending.isLoading && !other.isLoading }
        return TwoReaders(setup: setup, heard: heard, coordinator: coordinator, ending: ending, other: other)
    }

    /// Waits for the bottom episode's download to finish (or fail), and for
    /// any hand-over to be asked for.
    private func waitForTheDownloadToSettle(_ setup: Setup) async {
        await waitFor("the download settles") {
            let state = setup.world.center.store.record(of: setup.feedID)?.item("guid:ep-1")?.state
            return state?.failureReason != nil || book(of: "guid:ep-1", in: setup) != nil
        }
        try? await Task.sleep(for: .seconds(ReaderViewModel.continueToNextBookDelay * 2))
    }

    /// Another reader takes the controls (it plays, so it is the active
    /// owner) while the download runs: the arrival hands nothing over and
    /// says nothing.
    func testNothingIsHandedOverWhenAnotherReaderTakesTheControls() async throws {
        let readers = try await openTwoReaders()

        readers.ending.handleEndOfBook()
        readers.other.nowPlayingService.activateRemoteCommandsIfNeeded()
        XCTAssertEqual(readers.coordinator.activeOwnerID, readers.other.readerID, "The other reader did not take the controls")
        await waitForTheDownloadToSettle(readers.setup)

        XCTAssertEqual(readers.heard.announced, ["Finished: Middle part. Downloading the next episode: Bottom part."])
        XCTAssertEqual(readers.heard.asked, [])
        XCTAssertNil(readers.ending.nextEpisodeWait, "The wait outlived the download")
    }

    /// The same with a download that fails: "could not be downloaded" is not
    /// said over the other book.
    func testAFailureIsNotSaidWhenAnotherReaderTakesTheControls() async throws {
        let readers = try await openTwoReaders(bottomAnswer: StubResponse(status: 404))

        readers.ending.handleEndOfBook()
        readers.other.nowPlayingService.activateRemoteCommandsIfNeeded()
        await waitForTheDownloadToSettle(readers.setup)

        XCTAssertEqual(readers.heard.announced, ["Finished: Middle part. Downloading the next episode: Bottom part."])
        XCTAssertNil(readers.ending.nextEpisodeWait, "The wait outlived the failure")
    }

    /// The other reader's window merely becomes the focused one: the same
    /// silence.
    func testNothingIsHandedOverWhenAnotherReadersWindowBecomesKey() async throws {
        let readers = try await openTwoReaders()

        readers.ending.handleEndOfBook()
        readers.other.windowBecameKey()
        XCTAssertEqual(readers.coordinator.activeOwnerID, readers.other.readerID, "The other window did not take the focus")
        await waitForTheDownloadToSettle(readers.setup)

        XCTAssertEqual(readers.heard.announced, ["Finished: Middle part. Downloading the next episode: Bottom part."])
        XCTAssertEqual(readers.heard.asked, [])
        XCTAssertNil(readers.ending.nextEpisodeWait, "The wait outlived the download")
    }

    /// The controls were another reader's already as the episode ended, and
    /// stay so: that is no move, and the hand-over happens.
    func testTheHandOverHappensWhenTheControlsWereAnotherReadersAlready() async throws {
        let readers = try await openTwoReaders()
        readers.other.nowPlayingService.activateRemoteCommandsIfNeeded()

        readers.ending.handleEndOfBook()
        await waitFor("the next episode asks to start") { !readers.heard.asked.isEmpty }

        XCTAssertEqual(readers.heard.announced.last, "Starting: Bottom part")
        XCTAssertEqual(readers.heard.asked, [try XCTUnwrap(book(of: "guid:ep-1", in: readers.setup)).id])
    }

    /// The ending reader's own window becomes key again meanwhile: the
    /// controls are its own, and the hand-over happens.
    func testTheHandOverHappensWhenTheEndingReadersWindowBecomesKeyAgain() async throws {
        let readers = try await openTwoReaders()

        readers.ending.handleEndOfBook()
        readers.ending.windowBecameKey()
        XCTAssertEqual(readers.coordinator.activeOwnerID, readers.ending.readerID, "The window did not take the focus")
        await waitFor("the next episode asks to start") { !readers.heard.asked.isEmpty }

        XCTAssertEqual(readers.heard.announced.last, "Starting: Bottom part")
        XCTAssertEqual(readers.heard.asked, [try XCTUnwrap(book(of: "guid:ep-1", in: readers.setup)).id])
    }

    // MARK: - The Wait Goes First in the Queue

    /// With a download under way and another queued behind it, ending the
    /// episode puts the next episode first in the queue, and Play during the
    /// wait leaves it there.
    func testTheNextEpisodeGoesFirstInTheQueue() async throws {
        let setup = try await makeFeed(
            options: ListeningOptions(continuation: .playBookBelow), global: .stop, withAnOlderEpisode: true
        )
        _ = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }
        // The top episode downloads, the oldest waits behind it. Nothing
        // suspends before the checks below, so neither can finish first.
        setup.world.center.download("guid:ep-3", of: setup.feedID)
        setup.world.center.download("guid:ep-0", of: setup.feedID)
        XCTAssertEqual(setup.world.center.downloads.current?.itemID, "guid:ep-3")
        XCTAssertEqual(setup.world.center.downloads.queue.map(\.itemID), ["guid:ep-0"])

        reader.handleEndOfBook()
        XCTAssertEqual(setup.world.center.downloads.queue.map(\.itemID), ["guid:ep-1", "guid:ep-0"])

        // Play asks again: the episode keeps the first place.
        reader.play()
        XCTAssertEqual(setup.world.center.downloads.queue.map(\.itemID), ["guid:ep-1", "guid:ep-0"])
    }

    // MARK: - A Cancelled Download

    /// Cancel Download on the episode the end waits for says so once, and
    /// nothing is handed over.
    func testACancelledDownloadSaysSoOnce() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookBelow), global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.handleEndOfBook()
        setup.world.center.cancelDownload("guid:ep-1", of: setup.feedID)
        try? await Task.sleep(for: .seconds(ReaderViewModel.continueToNextBookDelay * 2))

        XCTAssertEqual(heard.announced, [
            "Finished: Middle part. Downloading the next episode: Bottom part.",
            "Download cancelled, so playback stopped.",
        ])
        XCTAssertEqual(heard.asked, [])
        XCTAssertNil(reader.nextEpisodeWait, "The wait outlived the cancel")
    }

    /// The downloads section's Cancel does the same.
    func testCancellingEveryDownloadSaysSo() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookBelow), global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.handleEndOfBook()
        _ = setup.world.center.cancelEveryDownload()
        try? await Task.sleep(for: .seconds(ReaderViewModel.continueToNextBookDelay * 2))

        XCTAssertEqual(heard.announced.last, "Download cancelled, so playback stopped.")
        XCTAssertEqual(heard.announced.count, 2)
        XCTAssertEqual(heard.asked, [])
        XCTAssertNil(reader.nextEpisodeWait, "The wait outlived the cancel")
    }

    /// A cancel after the listener played the book again says nothing.
    func testACancelAfterTheListenerPlayedAgainSaysNothing() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookBelow), global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.handleEndOfBook()
        reader.hasFinishedBook = false
        setup.world.center.cancelDownload("guid:ep-1", of: setup.feedID)
        // The cancel is heard once the download task has wound up.
        await waitFor("the wait hears the cancel") { reader.nextEpisodeWait == nil }

        XCTAssertEqual(heard.announced, ["Finished: Middle part. Downloading the next episode: Bottom part."])
    }

    /// A cancel after the reader closed says nothing.
    func testACancelAfterTheReaderClosedSaysNothing() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookBelow), global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.handleEndOfBook()
        reader.close()
        setup.world.center.cancelDownload("guid:ep-1", of: setup.feedID)

        XCTAssertEqual(heard.announced, ["Finished: Middle part. Downloading the next episode: Bottom part."])
    }

    /// Another item's download is cancelled while the wait's item waits
    /// behind it: the wait is not confused with it, and the episode starts
    /// once it arrives.
    func testAnotherItemsCancelDoesNotEndTheWait() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookBelow), global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }
        setup.world.center.download("guid:ep-3", of: setup.feedID)

        reader.handleEndOfBook()
        setup.world.center.cancelDownload("guid:ep-3", of: setup.feedID)
        XCTAssertNotNil(reader.nextEpisodeWait, "Another item's cancel ended the wait")
        await waitFor("the next episode asks to start") { !heard.asked.isEmpty }

        XCTAssertEqual(heard.announced, [
            "Finished: Middle part. Downloading the next episode: Bottom part.",
            "Starting: Bottom part",
        ])
        XCTAssertEqual(heard.asked, [try XCTUnwrap(book(of: "guid:ep-1", in: setup)).id])
    }

    // MARK: - An Episode Already Here, Played, or Finished

    /// The next episode is downloaded already: no download, and listening is
    /// handed over as before.
    func testAnEpisodeDownloadedAlreadyIsHandedOverWithoutADownload() async throws {
        let setup = try await makeFeed(
            options: ListeningOptions(continuation: .playBookBelow), global: .stop, bottomIsDownloaded: true
        )
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.handleEndOfBook()
        await waitFor("the next episode asks to start") { !heard.asked.isEmpty }

        XCTAssertEqual(heard.announced, ["Starting: Bottom part"])
        XCTAssertEqual(heard.asked, [try XCTUnwrap(book(of: "guid:ep-1", in: setup)).id])
        XCTAssertEqual(heard.downloadsStarted, [])
        XCTAssertNil(reader.nextEpisodeWait)
    }

    /// An episode played, whose file is gone, is passed over while the feed
    /// skips finished items: nothing is downloaded, and the end says that
    /// every episode below is finished.
    func testAPlayedEpisodeWithNoFileIsPassedOverWhenSkippingFinished() async throws {
        let setup = try await makeFeed(
            options: ListeningOptions(continuation: .playBookBelow), global: .stop, bottomIsPlayed: true
        )
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.handleEndOfBook()
        try? await Task.sleep(for: .seconds(ReaderViewModel.continueToNextBookDelay * 2))

        XCTAssertEqual(heard.announced, ["Finished: Middle part. Every book after it in the folder is finished."])
        XCTAssertEqual(heard.downloadsStarted, [])
        XCTAssertEqual(heard.asked, [])
    }

    /// With Skip finished off the same episode is downloaded and played.
    func testAPlayedEpisodeWithNoFileIsDownloadedWhenNotSkippingFinished() async throws {
        let setup = try await makeFeed(
            options: ListeningOptions(continuation: .playBookBelow, skipsFinished: false),
            global: .stop,
            bottomIsPlayed: true
        )
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.handleEndOfBook()
        await waitFor("the next episode asks to start") { !heard.asked.isEmpty }

        XCTAssertEqual(heard.announced, [
            "Finished: Middle part. Downloading the next episode: Bottom part.",
            "Starting: Bottom part",
        ])
        XCTAssertEqual(heard.downloadsStarted, ["guid:ep-1"])
    }

    // MARK: - Play on the Finished Episode

    /// Play on an episode that rests at its end does what its end does: the
    /// next episode is downloaded, said, and started.
    func testPlayOnTheFinishedEpisodeDownloadsTheNextOne() async throws {
        let setup = try await makeFeed(
            options: ListeningOptions(continuation: .playBookBelow), global: .stop, middleIsFinished: true
        )
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }
        XCTAssertTrue(reader.hasFinishedBook, "The episode does not rest finished")

        reader.play()
        XCTAssertEqual(heard.announced, ["Finished: Middle part. Downloading the next episode: Bottom part."])
        await waitFor("the next episode asks to start") { !heard.asked.isEmpty }

        XCTAssertEqual(heard.announced.last, "Starting: Bottom part")
        XCTAssertEqual(heard.asked, [try XCTUnwrap(book(of: "guid:ep-1", in: setup)).id])
        XCTAssertEqual(heard.downloadsStarted, ["guid:ep-1"])
    }

    // MARK: - Nothing Below

    /// Nothing below the last episode: the end says so, as before.
    func testNothingBelowTheLastEpisodeIsSaidAsBefore() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookBelow), global: .stop)
        let heard = listen(to: setup)
        let bottom = try makeFeedItem(title: "Bottom part", itemID: "guid:ep-1", of: setup.feedID)
        setup.world.library.addFeedBook(bottom)
        setup.world.center.store.updateItem("guid:ep-1", of: setup.feedID) { $0.state = .downloaded(bookID: bottom.id) }
        let reader = try openReader(for: bottom, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.handleEndOfBook()
        try? await Task.sleep(for: .seconds(ReaderViewModel.continueToNextBookDelay * 2))

        XCTAssertEqual(heard.announced, ["Finished: Bottom part. No more books in folder."])
        XCTAssertEqual(heard.downloadsStarted, [])
        XCTAssertEqual(heard.asked, [])
    }

    // MARK: - Next and Previous in Folder (0.2.5)

    /// Next in Folder, from an episode not playing, downloads the episode
    /// below (the feed's own download, as the end of an episode asks for
    /// it), says so, and, once it arrives, says "Opening" and opens its
    /// window without asking for it to play.
    func testNextInFolderDownloadsTheEpisodeBelowAndOpensItOnceItArrives() async throws {
        let setup = try await makeFeed(options: nil, global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.goThroughFolder(.down)

        XCTAssertEqual(heard.announced, ["Downloading the next episode: Bottom part"])
        await waitFor("the episode opens") { !heard.opened.isEmpty }
        let bottom = try XCTUnwrap(book(of: "guid:ep-1", in: setup))
        XCTAssertEqual(heard.announced, ["Downloading the next episode: Bottom part", "Opening: Bottom part"])
        XCTAssertEqual(heard.opened, [bottom.id])
        XCTAssertEqual(heard.asked, [], "Asked for it to play")
        XCTAssertEqual(heard.downloadsStarted, ["guid:ep-1"])
        XCTAssertNil(reader.nextEpisodeWait, "The wait outlived the download")
    }

    /// Previous in Folder downloads the episode above, and says "previous".
    func testPreviousInFolderDownloadsTheEpisodeAbove() async throws {
        let setup = try await makeFeed(options: nil, global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.goThroughFolder(.up)
        await waitFor("the episode opens") { !heard.opened.isEmpty }

        XCTAssertEqual(heard.announced.first, "Downloading the previous episode: Top part")
        XCTAssertEqual(heard.downloadsStarted, ["guid:ep-3"])
    }

    /// An episode here already is opened with no download.
    func testNextInFolderOpensAnEpisodeThatIsHereWithoutADownload() async throws {
        let setup = try await makeFeed(options: nil, global: .stop, bottomIsDownloaded: true)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.goThroughFolder(.down)
        await waitFor("the episode opens") { !heard.opened.isEmpty }

        XCTAssertEqual(heard.announced, ["Opening: Bottom part"])
        XCTAssertEqual(heard.opened, [try XCTUnwrap(book(of: "guid:ep-1", in: setup)).id])
        XCTAssertEqual(heard.downloadsStarted, [])
    }

    /// Nothing below the last episode: the command says so, and nothing
    /// opens or downloads.
    func testNextInFolderBelowTheLastEpisodeSaysSo() async throws {
        let setup = try await makeFeed(options: nil, global: .stop)
        let heard = listen(to: setup)
        let bottom = try makeFeedItem(title: "Bottom part", itemID: "guid:ep-1", of: setup.feedID)
        setup.world.library.addFeedBook(bottom)
        setup.world.center.store.updateItem("guid:ep-1", of: setup.feedID) { $0.state = .downloaded(bookID: bottom.id) }
        let reader = try openReader(for: bottom, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.goThroughFolder(.down)
        try? await Task.sleep(for: .seconds(ReaderViewModel.continueToNextBookDelay * 2))

        XCTAssertEqual(heard.announced, ["No more books in folder."])
        XCTAssertEqual(heard.opened, [])
        XCTAssertEqual(heard.downloadsStarted, [])
    }

    /// A reader that closes while the episode downloads ends the wait:
    /// nothing opens when the episode arrives.
    func testNextInFolderWaitEndsWhenTheReaderCloses() async throws {
        let setup = try await makeFeed(options: nil, global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.goThroughFolder(.down)
        reader.close()
        try? await Task.sleep(for: .seconds(ReaderViewModel.continueToNextBookDelay * 3))

        XCTAssertEqual(heard.opened, [], "A closed reader opened the episode")
        XCTAssertNil(reader.nextEpisodeWait)
    }

    /// Going up with nothing playing, a failed download names "previous" and
    /// does not say that playback stopped, since none was playing.
    func testPreviousInFolderFailedDownloadNamesPreviousAndNoStoppedPlayback() async throws {
        let setup = try await makeFeed(options: nil, global: .stop, topAnswer: StubResponse(status: 404))
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.goThroughFolder(.up)
        await waitFor("the failure is announced") { heard.announced.count == 2 }

        XCTAssertEqual(heard.announced, [
            "Downloading the previous episode: Top part",
            "The previous episode could not be downloaded. The server says the file is gone.",
        ])
        XCTAssertEqual(heard.opened, [])
        XCTAssertNil(reader.nextEpisodeWait, "The wait outlived the failure")
    }

    /// Going up with nothing playing, a cancelled download names "previous"
    /// too, once.
    func testPreviousInFolderCancelledDownloadNamesPrevious() async throws {
        let setup = try await makeFeed(options: nil, global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }

        reader.goThroughFolder(.up)
        setup.world.center.cancelDownload("guid:ep-3", of: setup.feedID)
        try? await Task.sleep(for: .seconds(ReaderViewModel.continueToNextBookDelay * 2))

        XCTAssertEqual(heard.announced, [
            "Downloading the previous episode: Top part",
            "Download of the previous episode cancelled.",
        ])
        XCTAssertEqual(heard.opened, [])
    }

    /// Going down from a book that counts as playing (a Where Am I?
    /// announcement that will play it again, so no sound is made), a failed
    /// download says that playback stopped, and a cancelled one says so too.
    func testNextInFolderFromAPlayingBookSaysThatPlaybackStopped() async throws {
        let setup = try await makeFeed(options: nil, global: .stop, bottomAnswer: StubResponse(status: 404))
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }
        reader.isWhereAmIResumePending = true

        reader.goThroughFolder(.down)
        await waitFor("the failure is announced") { heard.announced.count == 2 }

        XCTAssertEqual(heard.announced, [
            "Downloading the next episode: Bottom part",
            "The next episode could not be downloaded, so playback stopped. The server says the file is gone.",
        ])
        XCTAssertEqual(heard.asked, [])
        XCTAssertEqual(
            FolderNavigationWording.downloadCancelled(isArticle: false, going: .down, playbackStopped: true),
            "Download of the next episode cancelled, so playback stopped."
        )
    }

    /// Going down from a book that counts as playing, an episode that
    /// arrives starts: "Starting: <title>", asked for to play, and not
    /// opened.
    func testNextInFolderFromAPlayingBookStartsTheEpisodeOnceItArrives() async throws {
        let setup = try await makeFeed(options: nil, global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }
        reader.isWhereAmIResumePending = true

        reader.goThroughFolder(.down)
        await waitFor("the episode asks to start") { !heard.asked.isEmpty }

        let bottom = try XCTUnwrap(book(of: "guid:ep-1", in: setup))
        XCTAssertEqual(heard.announced, ["Downloading the next episode: Bottom part", "Starting: Bottom part"])
        XCTAssertEqual(heard.asked, [bottom.id])
        XCTAssertEqual(heard.opened, [])
    }

    /// With this reader's sleep timer running at the press, the episode starts
    /// as any playing book's next does, "Starting: <title>", and the timer is
    /// asked for by the episode's reader (0.2.5): "Not started because of the
    /// sleep timer" is said no more.
    func testNextInFolderWithTheSleepTimerRunningStartsTheEpisodeAndCarriesTheTimer() async throws {
        let setup = try await makeFeed(options: nil, global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }
        startSleepTimer(.minutes(30), for: reader)
        reader.isWhereAmIResumePending = true

        reader.goThroughFolder(.down)
        await waitFor("the episode asks to start") { !heard.asked.isEmpty }

        let bottom = try XCTUnwrap(book(of: "guid:ep-1", in: setup))
        XCTAssertEqual(heard.announced, ["Downloading the next episode: Bottom part", "Starting: Bottom part"])
        XCTAssertEqual(heard.asked, [bottom.id])
        XCTAssertTrue(reader.sleepTimerService.isActive, "The move stopped the timer")
        XCTAssertTrue(reader.sleepTimerService.isHeld(forBook: bottom.id))
    }

    /// A command pressed after one that went to a book here, within the half
    /// second, cancels that book's ask: the episode that must download is the
    /// one that plays, once it arrives, and the first book is never asked for.
    func testACommandCancelsAnEarlierCommandsAskBeforeItDownloads() async throws {
        let setup = try await makeFeed(options: nil, global: .stop, bottomIsDownloaded: true)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }
        reader.isWhereAmIResumePending = true

        reader.goThroughFolder(.down)
        reader.goThroughFolder(.up)
        await waitFor("the episode above asks to start") { !heard.asked.isEmpty }
        try? await Task.sleep(for: .seconds(ReaderViewModel.continueToNextBookDelay * 2))

        let top = try XCTUnwrap(book(of: "guid:ep-3", in: setup))
        XCTAssertEqual(heard.asked, [top.id], "The first command's book was asked for, or the episode did not play")
        XCTAssertEqual(heard.opened, [])
        XCTAssertEqual(heard.downloadsStarted, ["guid:ep-3"])
    }

    /// The same command pressed again during the download counts the book as
    /// playing, since the first press paused it: the episode starts when it
    /// arrives, and is not only opened.
    func testASecondPressDuringTheDownloadStillPlaysTheEpisode() async throws {
        let setup = try await makeFeed(options: nil, global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }
        reader.isWhereAmIResumePending = true

        reader.goThroughFolder(.down)
        reader.goThroughFolder(.down)
        await waitFor("the episode asks to start") { !heard.asked.isEmpty }

        let bottom = try XCTUnwrap(book(of: "guid:ep-1", in: setup))
        XCTAssertEqual(heard.announced.last, "Starting: Bottom part")
        XCTAssertEqual(heard.asked, [bottom.id])
        XCTAssertEqual(heard.opened, [])
    }

    /// A command that goes to an episode that must download says that it ended
    /// a fading sleep timer, as the others do, after current speech.
    func testTheDownloadBranchSaysTheFadeEndedByTheMove() async throws {
        let setup = try await makeFeed(options: nil, global: .stop)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }
        startSleepTimer(.minutes(1), for: reader)
        reader.sleepTimerService.start(duration: .minutes(1), ownerID: reader.readerID, onExpire: {}, fadeOutDuration: 5)
        reader.sleepTimerService._expireForTesting()
        XCTAssertTrue(reader.sleepTimerService.isFadingOut)
        reader.isWhereAmIResumePending = true

        reader.goThroughFolder(.down)

        XCTAssertEqual(heard.announced, [
            "Downloading the next episode: Bottom part",
            SleepTimerHandOverWording.fadeEndedByTheMove,
        ])
        XCTAssertFalse(reader.sleepTimerService.isActive, "The fade went on after the move")
    }

    /// Next in Reading List pressed during the wait for an episode a folder
    /// command began ends the wait through the command itself: the episode is
    /// not started when it arrives, and only the list's book is asked for.
    func testNextInReadingListDuringAnEpisodeWaitEndsTheWait() async throws {
        let setup = try await makeFeed(options: nil, global: .stop, bottomIsDownloaded: true)
        let heard = listen(to: setup)
        let bottom = try XCTUnwrap(book(of: "guid:ep-1", in: setup))
        setup.world.library.library.readingList = ReadingList(bookIDs: [setup.middle.id, bottom.id])
        let requests = ReadingListOpenRequests()
        requests.request(for: setup.middle.id)
        let reader = ReaderViewModel(
            book: setup.middle,
            libraryViewModel: setup.world.library,
            settingsViewModel: setup.settings,
            substitutionService: TextSubstitutionService(rules: []),
            autoplayRequests: ReaderAutoplayRequests(),
            readingListRequests: requests,
            notificationCenter: setup.notifications,
            renderScheduler: nil,
            sleepTimer: SleepTimerService()
        )
        addTeardownBlock { @MainActor in reader.close() }
        await waitFor("the episode loads in its reader") { !reader.isLoading }
        XCTAssertTrue(reader.isOpenedFromReadingList, "The reader does not read its book from the list")
        reader.isWhereAmIResumePending = true
        reader.goThroughFolder(.up)
        XCTAssertNotNil(reader.nextEpisodeWait, "No wait began")

        reader.goThroughReadingList(.down)

        XCTAssertNil(reader.nextEpisodeWait, "The command left the wait")
        await waitFor("the list's book is asked for") { !heard.asked.isEmpty }
        try? await Task.sleep(for: .seconds(ReaderViewModel.continueToNextBookDelay * 2))
        XCTAssertEqual(heard.asked, [bottom.id], "The episode was started, or the list's book was not asked for")
    }

    /// Any move ends the wait for an episode that a folder command began, and
    /// counts the book as playing when that wait was to play its episode: the
    /// start every move shares, Next in Reading List's included.
    func testAnyMoveEndsTheWaitForAnEpisodeAndCountsItAsPlaying() async throws {
        let setup = try await makeFeed(options: nil, global: .stop)
        _ = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }
        reader.isWhereAmIResumePending = true
        reader.goThroughFolder(.down)
        XCTAssertNotNil(reader.nextEpisodeWait, "No wait began")
        XCTAssertTrue(reader.episodeWaitPlays)

        let start = reader.beginMoveToAnotherBook()

        XCTAssertTrue(start.wasPlaying, "The wait was to play its episode")
        XCTAssertNil(reader.nextEpisodeWait, "The move left the wait")
        XCTAssertFalse(reader.episodeWaitPlays)
    }

    /// Next, then within the half second Previous onto an episode that must
    /// download: the cancelled move leaves no trace. The timer is the reader's
    /// own again, not held, and still active; VoiceOver is never told a book
    /// could not be opened.
    func testACancelledMoveLeavesTheTimerTheReadersOwnWhenTheNextMustDownload() async throws {
        let setup = try await makeFeed(options: nil, global: .stop, bottomIsDownloaded: true)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }
        startSleepTimer(.minutes(30), for: reader)
        let timer = reader.sleepTimerService
        let bottom = try XCTUnwrap(book(of: "guid:ep-1", in: setup))
        reader.isWhereAmIResumePending = true

        reader.goThroughFolder(.down)
        XCTAssertTrue(timer.isHeld(forBook: bottom.id), "The first move did not hold the timer")
        reader.goThroughFolder(.up)

        XCTAssertFalse(timer.isHolding, "The cancelled move left its hold")
        XCTAssertTrue(timer.isActive)
        XCTAssertEqual(timer.ownerID, reader.readerID)
        XCTAssertNil(timer.expiredWhileHeldBookID)
        XCTAssertTrue(timer.isCarriable(by: reader.readerID), "The timer is not the reader's own to carry again")
        XCTAssertFalse(heard.announced.contains(SleepTimerHandOverWording.noBook))
    }

    /// The same, and the download fails and the reader closes: the timer stops,
    /// since the reader owned it, with no hold left to keep it alive.
    func testAFailedDownloadAfterACancelledMoveThenCloseStopsTheReadersTimer() async throws {
        let setup = try await makeFeed(
            options: nil, global: .stop, bottomIsDownloaded: true, topAnswer: StubResponse(status: 404)
        )
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }
        startSleepTimer(.minutes(30), for: reader)
        reader.isWhereAmIResumePending = true

        reader.goThroughFolder(.down)
        reader.goThroughFolder(.up)
        await waitFor("the failure is said") { heard.announced.contains { $0.contains("could not be downloaded") } }
        reader.close()

        XCTAssertFalse(reader.sleepTimerService.isActive, "A timer nobody runs was left active")
        XCTAssertFalse(reader.sleepTimerService.isHolding)
    }

    /// The same, and the timer runs out during the wait: no run-out mark is
    /// left for the first book, and a later move to it plays.
    func testATimerThatRunsOutDuringTheWaitLeavesNoMarkForTheCancelledBook() async throws {
        let setup = try await makeFeed(options: nil, global: .stop, bottomIsDownloaded: true)
        let heard = listen(to: setup)
        let reader = try openReader(for: setup.middle, in: setup)
        await waitFor("the episode loads in its reader") { !reader.isLoading }
        startSleepTimer(.minutes(30), for: reader)
        reader.startSleepTimer(duration: .minutes(30))
        let bottom = try XCTUnwrap(book(of: "guid:ep-1", in: setup))
        reader.isWhereAmIResumePending = true

        reader.goThroughFolder(.down)
        // The timer runs out in the half second before the cancel.
        reader.sleepTimerService._expireForTesting()
        XCTAssertEqual(
            reader.sleepTimerService.expiredWhileHeldBookID, bottom.id, "The timer's run-out was not marked for the held book"
        )
        reader.goThroughFolder(.up)

        XCTAssertNil(reader.sleepTimerService.expiredWhileHeldBookID, "The cancelled move left a mark for its book")
        reader.isWhereAmIResumePending = true
        reader.goThroughFolder(.down)
        await waitFor("a later move to the first book asks for it") { heard.asked.contains(bottom.id) }
    }

    /// The words of a folder move's download failing or being cancelled, for
    /// both directions, both kinds of item, and with or without playback.
    func testTheFolderMoveDownloadWords() {
        XCTAssertEqual(
            FolderNavigationWording.episodeNotDownloaded(reason: "No network.", isArticle: false, going: .down, playbackStopped: false),
            "The next episode could not be downloaded. No network."
        )
        XCTAssertEqual(
            FolderNavigationWording.episodeNotDownloaded(reason: "No network.", isArticle: true, going: .up, playbackStopped: true),
            "The previous article could not be downloaded, so playback stopped. No network."
        )
        XCTAssertEqual(
            FolderNavigationWording.downloadCancelled(isArticle: true, going: .up, playbackStopped: false),
            "Download of the previous article cancelled."
        )
        // The end of a book's own sentences are unchanged.
        XCTAssertEqual(
            EndOfBookWording.nextEpisodeNotDownloaded(reason: "No network."),
            "The next episode could not be downloaded, so playback stopped. No network."
        )
        XCTAssertEqual(EndOfBookWording.nextEpisodeDownloadCancelled, "Download cancelled, so playback stopped.")
    }

    // MARK: - The Words

    /// What the end says of an episode being downloaded, and of a download
    /// that fails, each word for word, for an episode and for an article.
    func testTheWords() {
        let episode = FeedItem(
            id: "guid:e",
            title: "Part Two",
            firstSeen: Self.date(),
            enclosure: FeedEnclosure(url: URL(fileURLWithPath: "/part-two.m4a"), mimeType: "audio/mp4")
        )
        let article = FeedItem(id: "guid:a", title: "Night Trams", firstSeen: Self.date())

        XCTAssertFalse(episode.isArticle)
        XCTAssertTrue(article.isArticle)
        XCTAssertEqual(EndOfBookWording.downloadingNextNote(episode), "Downloading the next episode: Part Two")
        XCTAssertEqual(EndOfBookWording.downloadingNextNote(article), "Downloading the next article: Night Trams")
        XCTAssertEqual(
            EndOfBookWording.nextEpisodeNotDownloaded(reason: "The server says the file is gone."),
            "The next episode could not be downloaded, so playback stopped. The server says the file is gone."
        )
        XCTAssertEqual(
            EndOfBookWording.nextEpisodeNotDownloaded(reason: "The server says the file is gone.", isArticle: true),
            "The next article could not be downloaded, so playback stopped. The server says the file is gone."
        )
        XCTAssertEqual(EndOfBookWording.downloadNotStartedReason, "TextMouth is not downloading right now.")
        XCTAssertEqual(EndOfBookWording.nextEpisodeDownloadCancelled, "Download cancelled, so playback stopped.")
        XCTAssertEqual(
            EndOfBookWording.finished("Part One", notes: [EndOfBookWording.downloadingNextNote(episode)]),
            "Finished: Part One. Downloading the next episode: Part Two."
        )
    }

    // MARK: - Fixtures

    /// A feed of three items and the settings that go with it.
    private struct Setup {
        let world: FeedTestWorld
        let settings: SettingsViewModel
        let notifications: NotificationCenter
        let feedID: UUID
        /// The middle item, downloaded, an article.
        let middle: Book
    }

    /// What a test heard while it ran.
    @MainActor
    private final class Heard {
        /// Every VoiceOver announcement, oldest first.
        var announced: [String] = []
        /// The books `.continueToNextBook` asked for, in order.
        var asked: [UUID] = []
        /// The items whose downloads started, in order.
        var downloadsStarted: [FeedItem.ID] = []
        /// The books `.openBookWindow` asked to open, in order.
        var opened: [UUID] = []
    }

    /// Subscribes to a feed listing Top part (ep-3), Middle part (ep-2), and
    /// Bottom part (ep-1), newest first, with the middle one downloaded, and
    /// `options` the feed's and `global` the global "When book ends".
    ///
    /// The top and bottom items are served by the stub server, as short
    /// silent audio, unless `bottomIsDownloaded` has the bottom one here
    /// already. Both are here already when `topIsDownloaded`.
    ///
    /// - Parameters:
    ///   - options: The feed's listening options, or nil for none.
    ///   - global: The global "When book ends".
    ///   - topIsDownloaded: Whether the top item's file is here.
    ///   - bottomIsDownloaded: Whether the bottom item's file is here.
    ///   - bottomIsPlayed: Whether the bottom item was played, its file
    ///     (if it was here) since deleted.
    ///   - topAnswer: What the server answers a request for the top item's
    ///     file; the file itself by default.
    ///   - bottomAnswer: What the server answers a request for the bottom
    ///     item's file; the file itself by default.
    ///   - middleIsFinished: Whether the middle item rests at its end.
    ///   - withAnOlderEpisode: Whether the feed lists a fourth item, Last part
    ///     (ep-0), older than the bottom one and served like the top one.
    private func makeFeed(
        options: ListeningOptions?,
        global: EndOfBookBehavior,
        topIsDownloaded: Bool = false,
        bottomIsDownloaded: Bool = false,
        bottomIsPlayed: Bool = false,
        bottomAnswer: StubResponse? = nil,
        topAnswer: StubResponse? = nil,
        middleIsFinished: Bool = false,
        withAnOlderEpisode: Bool = false
    ) async throws -> Setup {
        let statistics = preserveSharedStatistics()
        let world = try FeedTestWorld(self, label: "EpisodeDownload", statistics: statistics)
        let guids = ["ep-3", "ep-2", "ep-1"] + (withAnOlderEpisode ? ["ep-0"] : [])
        let titles = ["ep-3": "Top part", "ep-2": "Middle part", "ep-1": "Bottom part", "ep-0": "Last part"]
        let items = guids.enumerated().map { offset, guid in
            FeedXML.Item(
                guid: guid,
                title: titles[guid] ?? guid,
                published: world.day(-Double(offset + 1)),
                enclosure: world.server.url("/audio/\(guid).m4a").absoluteString,
                enclosureType: "audio/mp4"
            )
        }
        world.server.serve("/atlas.xml", .feed(FeedXML.rss(items: items)))
        let silence = FeedMediaFixtures.file(try FeedMediaFixtures.silentAAC(duration: 1), mimeType: "audio/mp4")
        world.server.serve("/audio/ep-3.m4a", topAnswer ?? silence)
        world.server.serve("/audio/ep-0.m4a", silence)
        world.server.serve("/audio/ep-1.m4a", bottomAnswer ?? silence)
        let feed = try await world.subscribe("/atlas.xml")

        /// Puts the item `guid` among the downloaded, as an article.
        func here(_ title: String, _ guid: String, finished: Bool = false) throws -> Book {
            let position = finished
                ? ReadingPosition(chapterIndex: 0, characterOffset: 40, globalCharacterOffset: 40)
                : nil
            var item = try makeFeedItem(title: title, itemID: "guid:\(guid)", of: feed.id, position: position)
            if finished { item.totalCharacterCount = 40 }
            world.library.addFeedBook(item)
            world.center.store.updateItem("guid:\(guid)", of: feed.id) { $0.state = .downloaded(bookID: item.id) }
            return item
        }
        let middle = try here("Middle part", "ep-2", finished: middleIsFinished)
        if topIsDownloaded { _ = try here("Top part", "ep-3") }
        if bottomIsDownloaded { _ = try here("Bottom part", "ep-1") }
        if bottomIsPlayed {
            world.center.store.updateItem("guid:ep-1", of: feed.id) { $0.playedDate = Self.date(5) }
        }
        world.center.setListeningOptions(options, of: feed.id)

        let configFile = try makeSandboxDirectory("EpisodeDownloadConfig").appendingPathComponent("config.json")
        let configService = ConfigService(fileURL: configFile)
        // A reader can outlive its test for a moment: a move asks for its
        // book half a second after saying so, and holds the reader, with
        // these settings, until then. A settings save still waiting when a
        // short test ends would then run after the sandbox above is gone,
        // fail, and be announced in the next test. Teardown blocks run
        // last-added first, so this one writes the save before the sandbox
        // goes.
        addTeardownBlock { @MainActor in configService.flushScheduledSave() }
        let notifications = NotificationCenter()
        let settings = SettingsViewModel(
            notificationCenter: notifications,
            initializeServices: false,
            userDefaults: makeSandboxedPreferences("EpisodeDownloadSettings"),
            configService: configService
        )
        settings.endOfBookBehavior = global
        return Setup(world: world, settings: settings, notifications: notifications, feedID: feed.id, middle: middle)
    }

    /// A reader of `book` in `setup`'s world, listening on the setup's own
    /// notification center and sharing no request store with the app;
    /// closed when the test ends. The reader is in a window of its own, with
    /// a sleep timer of its own (`sleepTimerService`). Readers given the same
    /// `nowPlaying` coordinator share its media controls, as two reader
    /// windows do. Every timer there is stops when the test ends, and the
    /// duration last used is put back, with the reader closed first.
    private func openReader(
        for book: Book,
        in setup: Setup,
        nowPlaying: NowPlayingService? = nil
    ) throws -> ReaderViewModel {
        // Before the reader exists, so the reader is closed before this runs
        // at the test's end; and before any timer of the test starts, since
        // it stops every timer that runs.
        preserveSleepTimers()
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: setup.world.library,
            settingsViewModel: setup.settings,
            substitutionService: TextSubstitutionService(rules: []),
            autoplayRequests: ReaderAutoplayRequests(),
            notificationCenter: setup.notifications,
            renderScheduler: nil,
            nowPlaying: nowPlaying,
            sleepTimer: SleepTimerService()
        )
        addTeardownBlock { @MainActor in reader.close() }
        return reader
    }

    /// Records, from now until the test ends, what the setup's world and
    /// readers do: announcements (instead of speaking them), the books asked
    /// for, and the downloads that start.
    private func listen(to setup: Setup) -> Heard {
        let heard = Heard()
        let previousPoster = VoiceOverAnnouncer.poster
        VoiceOverAnnouncer.poster = { announcement, _ in heard.announced.append(announcement.message) }
        addTeardownBlock { @MainActor in VoiceOverAnnouncer.poster = previousPoster }
        setup.notifications.publisher(for: .continueToNextBook)
            .sink { note in
                if let nextBookID = note.nextBookID { heard.asked.append(nextBookID) }
            }
            .store(in: &subscriptions)
        setup.notifications.publisher(for: .openBookWindow)
            .sink { note in
                if let bookID = note.object as? UUID { heard.opened.append(bookID) }
            }
            .store(in: &subscriptions)
        setup.world.center.events
            .sink { event in
                if case .downloadStarted(_, let itemID) = event { heard.downloadsStarted.append(itemID) }
            }
            .store(in: &subscriptions)
        return heard
    }

    /// The book the item `itemID` of the setup's feed downloaded as, if it
    /// is in the library.
    private func book(of itemID: FeedItem.ID, in setup: Setup) -> Book? {
        setup.world.library.library.books.first {
            $0.feedLink == FeedBookLink(feedID: setup.feedID, itemID: itemID)
        }
    }

    /// Starts the sleep timer of `reader`'s window for `reader`, which owns
    /// it. The timer is stopped, and the user's last-used duration put back,
    /// when the test ends (`openReader` arranged it, with
    /// `preserveSleepTimers()`).
    ///
    /// - Returns: The reader's window's timer.
    @discardableResult
    private func startSleepTimer(_ duration: SleepTimerDuration, for reader: ReaderViewModel) -> SleepTimerService {
        let timer = reader.sleepTimerService
        timer.start(duration: duration, ownerID: reader.readerID, onExpire: {})
        return timer
    }

    /// The app's shared statistics, which readers count finished books in,
    /// emptied for the test and put back as they were when it ends.
    @discardableResult
    private func preserveSharedStatistics() -> ReadingStatsService {
        let statistics = ReadingStatsService.shared
        let saved = statistics.stats
        statistics.endSession()
        statistics.stats = ReadingStats()
        addTeardownBlock { @MainActor in
            statistics.endSession()
            statistics.stats = saved
            statistics.save()
        }
        return statistics
    }
}
