import XCTest
@testable import TextMouth

/// A feed's next episode is downloaded before the one playing ends (FR19,
/// task C): when ten minutes or less of the episode are left and listening
/// would go on to another episode whose file is not here, the reader asks
/// for that file once, as the listener's, so the episode is ready when this
/// one ends.
///
/// The feed lists, newest first, Episode 1 to Episode 5, and the listener
/// plays Episode 3 (a silent two minutes, downloaded for real): "below" is
/// Episode 4 and then 5, "above" is Episode 2 and then 1. The other episodes
/// are served by the stub server as a second of silence. Each reader listens
/// on a notification center of its own, so the running app never sees it,
/// and nothing here is heard: the audio is silent.
@MainActor
final class NextEpisodePredownloadTests: FeedItemIndexTestCase {

    /// How many seconds the episode being played lasts: more than any test
    /// runs, so it never ends by itself, and within the default lead time.
    private static let playingDuration: TimeInterval = 120

    // MARK: - The Lead Time

    /// The lead time is ten minutes.
    func testTheLeadTimeIsTenMinutes() {
        XCTAssertEqual(ListeningOptions.predownloadLeadTime, 600)
    }

    // MARK: - What Is Downloaded

    /// The next listed episode is downloaded, as the listener's, once: a
    /// second call asks for nothing more, and the server is asked for the
    /// file once.
    func testTheNextEpisodeIsDownloadedOnceForTheListener() async throws {
        let setup = try await makeFeed(options: nil, global: .continueNext)
        let reader = try await playingReader(in: setup)
        XCTAssertFalse(reader.hasAskedForPredownload)

        reader.predownloadNextEpisodeIfDue()

        XCTAssertTrue(reader.hasAskedForPredownload)
        XCTAssertEqual(asked(of: setup), ["guid:ep-4"])
        _ = try await downloadedBook(setup.world, feed: setup.feed, item: "guid:ep-4")
        XCTAssertEqual(setup.world.center.store.record(of: setup.feed.id)?.item("guid:ep-4")?.downloadOrigin, .listener)

        reader.predownloadNextEpisodeIfDue()
        await settle()

        XCTAssertEqual(asked(of: setup), ["guid:ep-4"])
        XCTAssertEqual(setup.world.server.requests(to: "/audio/4.m4a").count, 1)
        XCTAssertEqual(setup.world.server.requests(to: "/audio/5.m4a"), [])
    }

    /// "Play the episode above" downloads the episode above, the newer one.
    func testTheEpisodeAboveIsDownloadedWhenTheFeedPlaysTheEpisodeAbove() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookAbove), global: .stop)
        let reader = try await playingReader(in: setup)

        reader.predownloadNextEpisodeIfDue()

        XCTAssertEqual(asked(of: setup), ["guid:ep-2"])
        _ = try await downloadedBook(setup.world, feed: setup.feed, item: "guid:ep-2")
        XCTAssertEqual(setup.world.server.requests(to: "/audio/4.m4a"), [])
    }

    /// "Skip finished episodes" passes over a next episode that was played
    /// and is not here, and downloads the one after it.
    func testASkippedPlayedEpisodeIsPassedOver() async throws {
        let setup = try await makeFeed(options: nil, global: .continueNext)
        setup.world.center.store.updateItem("guid:ep-4", of: setup.feed.id) { $0.playedDate = Self.date(5) }
        let reader = try await playingReader(in: setup)

        reader.predownloadNextEpisodeIfDue()

        XCTAssertEqual(asked(of: setup), ["guid:ep-5"])
        _ = try await downloadedBook(setup.world, feed: setup.feed, item: "guid:ep-5")
    }

    /// The same for a next episode downloaded and at its end.
    func testASkippedFinishedDownloadIsPassedOver() async throws {
        let setup = try await makeFeed(options: nil, global: .continueNext)
        _ = try putHere("guid:ep-4", in: setup, finished: true)
        let reader = try await playingReader(in: setup)

        reader.predownloadNextEpisodeIfDue()

        XCTAssertEqual(asked(of: setup), ["guid:ep-5"])
        _ = try await downloadedBook(setup.world, feed: setup.feed, item: "guid:ep-5")
    }

    /// With "Skip finished episodes" off, a next episode that was played is
    /// downloaded all the same.
    func testAPlayedEpisodeIsDownloadedWhenFinishedEpisodesAreNotSkipped() async throws {
        let setup = try await makeFeed(options: ListeningOptions(skipsFinished: false), global: .continueNext)
        setup.world.center.store.updateItem("guid:ep-4", of: setup.feed.id) { $0.playedDate = Self.date(5) }
        let reader = try await playingReader(in: setup)

        reader.predownloadNextEpisodeIfDue()

        XCTAssertEqual(asked(of: setup), ["guid:ep-4"])
        _ = try await downloadedBook(setup.world, feed: setup.feed, item: "guid:ep-4")
    }

    // MARK: - What Is Not Downloaded

    /// With more than the lead time left, nothing is asked for and nothing
    /// is looked up (the flag stays down); once the time left is within the
    /// lead time, the download starts.
    func testNothingIsDownloadedWhileMoreThanTheLeadTimeIsLeft() async throws {
        let setup = try await makeFeed(options: nil, global: .continueNext)
        let reader = try await playingReader(in: setup, leadTime: 30)

        reader.predownloadNextEpisodeIfDue()
        await settle()

        XCTAssertFalse(reader.hasAskedForPredownload, "The library was searched before the time came")
        XCTAssertEqual(asked(of: setup), [])

        reader.predownloadLeadTime = ListeningOptions.predownloadLeadTime
        reader.predownloadNextEpisodeIfDue()

        XCTAssertEqual(asked(of: setup), ["guid:ep-4"])
    }

    /// Nothing is downloaded while the episode has not started playing, or
    /// while it is paused.
    func testNothingIsDownloadedWhilePausedOrNotStarted() async throws {
        let setup = try await makeFeed(options: nil, global: .continueNext)
        let reader = try await playingReader(in: setup, startsPlaying: false)

        reader.predownloadNextEpisodeIfDue()
        XCTAssertFalse(reader.isPlaybackUnderWay)

        reader.play()
        await waitFor("the episode plays") { reader.isPlaybackUnderWay }
        reader.pause()
        XCTAssertFalse(reader.isPlaybackUnderWay)
        reader.predownloadNextEpisodeIfDue()
        await settle()

        XCTAssertFalse(reader.hasAskedForPredownload)
        XCTAssertEqual(asked(of: setup), [])
    }

    /// Nothing is downloaded when the feed's own choice is to stop at the end.
    func testNothingIsDownloadedWhenTheFeedStops() async throws {
        try await assertNothingIsDownloaded(options: ListeningOptions(continuation: .stop), global: .continueNext)
    }

    /// Nothing is downloaded when the feed's options are standard and the
    /// global setting stops at the end.
    func testNothingIsDownloadedWhenTheGlobalSettingStops() async throws {
        try await assertNothingIsDownloaded(options: nil, global: .stop)
    }

    /// Nothing is downloaded when the feed's pre-download option is off.
    func testNothingIsDownloadedWhenThePredownloadOptionIsOff() async throws {
        let setup = try await makeFeed(options: ListeningOptions(predownloadsNext: false), global: .continueNext)
        let reader = try await playingReader(in: setup)

        reader.predownloadNextEpisodeIfDue()
        await settle()

        XCTAssertEqual(asked(of: setup), [])
    }

    /// Nothing is downloaded when the next episode is here already; the
    /// search ran, so it does not run again.
    func testNothingIsDownloadedWhenTheNextEpisodeIsHere() async throws {
        let setup = try await makeFeed(options: nil, global: .continueNext)
        _ = try putHere("guid:ep-4", in: setup)
        let reader = try await playingReader(in: setup)

        reader.predownloadNextEpisodeIfDue()
        await settle()

        XCTAssertTrue(reader.hasAskedForPredownload)
        XCTAssertEqual(asked(of: setup), [])
        XCTAssertEqual(setup.world.server.requests(to: "/audio/4.m4a"), [])
    }

    /// Nothing more is asked for when the next episode's download is under
    /// way already: the one request stands.
    func testNothingIsAskedTwiceForADownloadAlreadyUnderWay() async throws {
        let setup = try await makeFeed(options: nil, global: .continueNext, slowNextEpisode: true)
        setup.world.center.download("guid:ep-4", of: setup.feed.id)
        await waitFor("the next episode's download is under way") {
            setup.world.center.store.record(of: setup.feed.id)?.item("guid:ep-4")?.state.isTransient == true
        }
        let reader = try await playingReader(in: setup)

        reader.predownloadNextEpisodeIfDue()
        _ = try await downloadedBook(setup.world, feed: setup.feed, item: "guid:ep-4")

        XCTAssertTrue(reader.hasAskedForPredownload)
        XCTAssertEqual(setup.world.server.requests(to: "/audio/4.m4a").count, 1)
    }

    /// Nothing is downloaded for a book that is not a feed's.
    func testNothingIsDownloadedForABookThatIsNotAFeedsItem() async throws {
        let setup = try await makeFeed(options: nil, global: .continueNext)
        let reader = try await playingReader(in: setup)
        reader.book.feedLink = nil

        reader.predownloadNextEpisodeIfDue()
        await settle()

        XCTAssertFalse(reader.hasAskedForPredownload)
        XCTAssertEqual(asked(of: setup), [])
    }

    /// Nothing is downloaded for a book read from the reading list: the
    /// books that follow it there are the library's, always here.
    func testNothingIsDownloadedForABookReadFromTheReadingList() async throws {
        let setup = try await makeFeed(options: nil, global: .continueNext)
        let reader = try await playingReader(in: setup)
        reader.readingListPlace = ReadingListPlace(position: 1, count: 2)

        reader.predownloadNextEpisodeIfDue()
        await settle()

        XCTAssertFalse(reader.hasAskedForPredownload)
        XCTAssertEqual(asked(of: setup), [])
    }

    /// Nothing is downloaded after the last episode; the search ran, so it
    /// does not run again.
    func testNothingIsDownloadedAfterTheLastEpisode() async throws {
        let setup = try await makeFeed(options: nil, global: .continueNext, playing: 5)
        let reader = try await playingReader(in: setup)

        reader.predownloadNextEpisodeIfDue()
        await settle()

        XCTAssertTrue(reader.hasAskedForPredownload)
        XCTAssertEqual(asked(of: setup), [])
    }

    // MARK: - The Newest-N Rule

    /// The newest-N rule leaves the pre-downloaded episode alone, though it
    /// lies outside the newest: it is the listener's download.
    func testTheNewestRuleLeavesThePredownloadedEpisode() async throws {
        let setup = try await makeFeed(options: nil, global: .continueNext)
        let reader = try await playingReader(in: setup)
        reader.predownloadNextEpisodeIfDue()
        let next = try await downloadedBook(setup.world, feed: setup.feed, item: "guid:ep-4")

        FeedSettings.newestCountPreference.write(2, to: setup.world.preferences)
        _ = await setup.world.center.applyItemPolicy(to: [setup.feed.id])
        _ = try await downloadedBook(setup.world, feed: setup.feed, item: "guid:ep-1")
        _ = try await downloadedBook(setup.world, feed: setup.feed, item: "guid:ep-2")
        FeedSettings.newestCountPreference.write(1, to: setup.world.preferences)
        let report = await setup.world.center.applyItemPolicy(to: [setup.feed.id])

        XCTAssertFalse(report.removedBookIDs.contains(next.id), "The rule removed the pre-downloaded episode")
        XCTAssertNotNil(setup.world.library.bookByID(next.id))
        XCTAssertEqual(setup.world.center.store.record(of: setup.feed.id)?.item("guid:ep-4")?.state, .downloaded(bookID: next.id))
    }

    // MARK: - Fixtures

    /// A feed of five episodes and the settings that go with it.
    private struct Setup {
        let world: FeedTestWorld
        let settings: SettingsViewModel
        let notifications: NotificationCenter
        let feed: Feed
        /// The episode being played, downloaded.
        let playing: Book
    }

    /// Subscribes to a feed listing Episode 1 (ep-1, the newest) to
    /// Episode 5, downloads the one being played, and sets the feed's
    /// options and the global "When book ends".
    ///
    /// - Parameters:
    ///   - options: The feed's listening options, or nil for none.
    ///   - global: The global "When book ends".
    ///   - playing: The number of the episode the listener plays, 3 by
    ///     default. It lasts `playingDuration`; the others a second.
    ///   - slowNextEpisode: Whether the server hands Episode 4's file over
    ///     slowly, so its download is still under way when a test looks.
    private func makeFeed(
        options: ListeningOptions?,
        global: EndOfBookBehavior,
        playing: Int = 3,
        slowNextEpisode: Bool = false
    ) async throws -> Setup {
        let statistics = preserveSharedStatistics()
        let world = try FeedTestWorld(self, label: "NextEpisodePredownload", statistics: statistics)
        let items = (1...5).map { number in
            FeedXML.Item(
                guid: "ep-\(number)",
                title: "Episode \(number)",
                published: world.day(-Double(number)),
                enclosure: world.server.url("/audio/\(number).m4a").absoluteString,
                enclosureType: "audio/mp4"
            )
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: items)))
        let brief = try FeedMediaFixtures.silentAAC(duration: 1)
        let long = try FeedMediaFixtures.silentAAC(duration: Self.playingDuration)
        for number in 1...5 {
            var file = FeedMediaFixtures.file(number == playing ? long : brief, mimeType: "audio/mp4")
            if slowNextEpisode, number == 4 {
                file.chunkSize = max(1, brief.count / 20)
                file.pause = 0.1
            }
            world.server.serve("/audio/\(number).m4a", file)
        }
        let feed = try await world.subscribe("/feed.xml")
        let itemID = "guid:ep-\(playing)"
        world.center.download(itemID, of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: itemID)
        world.center.setListeningOptions(options, of: feed.id)

        let configFile = try makeSandboxDirectory("PredownloadConfig").appendingPathComponent("config.json")
        let notifications = NotificationCenter()
        let settings = SettingsViewModel(
            notificationCenter: notifications,
            initializeServices: false,
            userDefaults: makeSandboxedPreferences("PredownloadSettings"),
            configService: ConfigService(fileURL: configFile)
        )
        settings.endOfBookBehavior = global
        return Setup(world: world, settings: settings, notifications: notifications, feed: feed, playing: book)
    }

    /// A reader of the episode being played, on the setup's own
    /// notification center; closed when the test ends. It has played the
    /// (silent) episode unless `startsPlaying` is false.
    ///
    /// - Parameters:
    ///   - setup: The feed and its settings.
    ///   - leadTime: The reader's lead time, set before playback starts so
    ///     that a reader that publishes its position cannot ask early.
    ///   - startsPlaying: Whether to press Play and wait for the audio.
    private func playingReader(
        in setup: Setup,
        leadTime: TimeInterval = ListeningOptions.predownloadLeadTime,
        startsPlaying: Bool = true
    ) async throws -> ReaderViewModel {
        let reader = ReaderViewModel(
            book: setup.playing,
            libraryViewModel: setup.world.library,
            settingsViewModel: setup.settings,
            substitutionService: TextSubstitutionService(rules: []),
            autoplayRequests: ReaderAutoplayRequests(),
            notificationCenter: setup.notifications,
            renderScheduler: nil
        )
        addTeardownBlock { @MainActor in reader.close() }
        await waitFor("the episode loads in its reader") { !reader.isLoading }
        XCTAssertNil(reader.errorMessage)
        reader.predownloadLeadTime = leadTime
        if startsPlaying {
            reader.play()
            await waitFor("the episode plays") { reader.isPlaybackUnderWay }
        }
        return reader
    }

    /// Puts the episode `itemID` among the downloaded as an article, a row
    /// in the library that is not played: at its end when `finished`.
    private func putHere(_ itemID: FeedItem.ID, in setup: Setup, finished: Bool = false) throws -> Book {
        let position = finished
            ? ReadingPosition(chapterIndex: 0, characterOffset: 40, globalCharacterOffset: 40)
            : nil
        var book = try makeFeedItem(title: itemID, itemID: itemID, of: setup.feed.id, position: position)
        if finished { book.totalCharacterCount = 40 }
        setup.world.library.addFeedBook(book)
        setup.world.center.store.updateItem(itemID, of: setup.feed.id) { $0.state = .downloaded(bookID: book.id) }
        return book
    }

    /// The episodes, besides the one playing, whose download has been asked
    /// for by the listener's side: waiting or running (a request's state is
    /// set at once, its origin as the file starts), or done as the
    /// listener's. Episodes put among the downloaded by a test do not
    /// count. In order of their IDs.
    private func asked(of setup: Setup) -> [FeedItem.ID] {
        let playingID = setup.playing.feedLink?.itemID
        let items = setup.world.center.store.record(of: setup.feed.id)?.items ?? []
        return items
            .filter { $0.id != playingID && ($0.state.isTransient || $0.downloadOrigin == .listener) }
            .map(\.id)
            .sorted()
    }

    /// Plays an episode of a feed with `options` under the global setting
    /// `global`, and shows that nothing is searched for or downloaded.
    private func assertNothingIsDownloaded(options: ListeningOptions?, global: EndOfBookBehavior) async throws {
        let setup = try await makeFeed(options: options, global: global)
        let reader = try await playingReader(in: setup)

        reader.predownloadNextEpisodeIfDue()
        await settle()

        XCTAssertFalse(reader.hasAskedForPredownload)
        XCTAssertEqual(asked(of: setup), [])
    }

    /// Waits long enough for a request that was wrongly made to show.
    private func settle() async {
        try? await Task.sleep(for: .seconds(0.4))
    }

    /// The app's shared statistics, which readers count in, emptied for the
    /// test and put back as they were when it ends.
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
