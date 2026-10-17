import Combine
import XCTest
@testable import TextMouth

/// A feed's item at its end follows its feed's listening options (FR19,
/// task B2): the item above or below plays, finished items are passed over
/// or not as the feed says, "Stop" stops, and a feed with standard options
/// follows the global "When book ends" as it always did, except that an
/// item that is not downloaded is downloaded, not passed over (task B3).
///
/// The items are downloaded articles of the feed, newest first as the
/// feed's folder lists them: Third, Second, First. Their readers play
/// nothing: each one's end is reached directly, and announcements are
/// recorded instead of spoken.
@MainActor
final class FeedEndOfBookRuleTests: FeedItemIndexTestCase {

    /// Subscriptions a test keeps until it ends.
    private var subscriptions = Set<AnyCancellable>()

    // MARK: - The Feed's Own Choice

    /// "Play the book above" goes up the feed's folder, the way the newest
    /// is: from First to Second, and from the top item, Third, to nothing,
    /// which the item says as a folder's book does.
    func testAFeedThatPlaysTheItemAboveGoesUpItsFolder() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookAbove), global: .stop)

        let up = await end(setup.first, in: setup, expectingARequest: true)
        XCTAssertEqual(up.announced, ["Starting: Second"])
        XCTAssertEqual(up.asked, [setup.second.id])

        let top = await end(setup.third, in: setup, expectingARequest: false)
        XCTAssertEqual(top.announced, ["Finished: Third. No more books in folder."])
        XCTAssertEqual(top.asked, [])
    }

    /// "Play the book below" goes down the feed's folder, even where the
    /// global setting is Stop.
    func testAFeedThatPlaysTheItemBelowGoesDownItsFolder() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .playBookBelow), global: .stop)

        let down = await end(setup.third, in: setup, expectingARequest: true)
        XCTAssertEqual(down.announced, ["Starting: Second"])
        XCTAssertEqual(down.asked, [setup.second.id])
    }

    /// "Stop" stops, though the global setting is Continue to Next Book.
    func testAFeedThatStopsStopsWhereTheGlobalSettingContinues() async throws {
        let setup = try await makeFeed(options: ListeningOptions(continuation: .stop), global: .continueNext)

        let stopped = await end(setup.third, in: setup, expectingARequest: false)
        XCTAssertEqual(stopped.announced, ["Finished: Third"])
        XCTAssertEqual(stopped.asked, [])
    }

    /// The item's own end behavior beats its feed's choice.
    func testAnItemsOwnEndBehaviorBeatsItsFeeds() async throws {
        let setup = try await makeFeed(
            options: ListeningOptions(continuation: .playBookBelow),
            global: .continueNext,
            thirdEndsWith: .stop
        )

        let stopped = await end(setup.third, in: setup, expectingARequest: false)
        XCTAssertEqual(stopped.announced, ["Finished: Third"])
        XCTAssertEqual(stopped.asked, [])
    }

    // MARK: - Skip Finished

    /// A finished item below is passed over while the feed skips finished
    /// items, and played when it does not.
    func testSkipFinishedPassesOverAFinishedItem() async throws {
        let skipping = try await makeFeed(
            options: ListeningOptions(continuation: .playBookBelow),
            global: .stop,
            finished: ["Second"]
        )
        let passedOver = await end(skipping.third, in: skipping, expectingARequest: true)
        XCTAssertEqual(passedOver.announced, ["Starting: First"])
        XCTAssertEqual(passedOver.asked, [skipping.first.id])
    }

    /// With "Skip finished" off the finished item beside the ending one
    /// plays.
    func testSkipFinishedOffPlaysTheFinishedItem() async throws {
        let setup = try await makeFeed(
            options: ListeningOptions(continuation: .playBookBelow, skipsFinished: false),
            global: .stop,
            finished: ["Second"]
        )
        let played = await end(setup.third, in: setup, expectingARequest: true)
        XCTAssertEqual(played.announced, ["Starting: Second"])
        XCTAssertEqual(played.asked, [setup.second.id])
    }

    /// Going up with only finished items above, the item says so, in the
    /// words of a folder going up.
    func testOnlyFinishedItemsAboveAreSaidSo() async throws {
        let setup = try await makeFeed(
            options: ListeningOptions(continuation: .playBookAbove),
            global: .stop,
            finished: ["Second", "Third"]
        )
        let nothing = await end(setup.first, in: setup, expectingARequest: false)
        XCTAssertEqual(nothing.announced, ["Finished: First. Every book before it in the folder is finished."])
        XCTAssertEqual(nothing.asked, [])
    }

    // MARK: - Standard Options

    /// A feed with standard options follows the global Continue to Next
    /// Book: an item below that is not downloaded is not passed over (task
    /// B3 changed that from passing it over): it is downloaded, and the
    /// downloaded item beyond it does not play meanwhile. What the download
    /// brings is the business of `EpisodeDownloadContinuationTests`.
    func testAFeedWithStandardOptionsFollowsTheGlobalSettingToAnItemNotHere() async throws {
        let setup = try await makeFeed(options: nil, global: .continueNext, secondIsDownloaded: false)

        let down = await end(setup.third, in: setup, expectingARequest: false)
        XCTAssertEqual(down.announced.first, "Finished: Third. Downloading the next episode: Episode ep-2.")
        XCTAssertFalse(down.announced.contains("Starting: First"), "The item beyond the one not here played")
        XCTAssertEqual(down.asked, [])
    }

    /// A feed with standard options and the global setting at Stop stops.
    func testAFeedWithStandardOptionsStopsWhereTheGlobalSettingStops() async throws {
        let setup = try await makeFeed(options: .standard, global: .stop)

        let stopped = await end(setup.third, in: setup, expectingARequest: false)
        XCTAssertEqual(stopped.announced, ["Finished: Third"])
        XCTAssertEqual(stopped.asked, [])
    }

    // MARK: - Fixtures

    /// A feed of three articles, Third, Second, First, newest first, in a
    /// world whose settings are `global`.
    private struct FeedSetup {
        let world: FeedTestWorld
        let settings: SettingsViewModel
        let notifications: NotificationCenter
        let third: Book
        let second: Book
        let first: Book
    }

    /// Subscribes to a feed of three items and downloads them as the rules
    /// say, with the feed's `options` and the global setting `global`.
    ///
    /// - Parameters:
    ///   - options: The feed's listening options, or nil for none.
    ///   - global: The global "When book ends".
    ///   - thirdEndsWith: The newest item's own end behavior, if any.
    ///   - finished: The titles of the items that rest at their ends.
    ///   - secondIsDownloaded: Whether the middle item's file is here.
    private func makeFeed(
        options: ListeningOptions?,
        global: EndOfBookBehavior,
        thirdEndsWith: EndOfBookBehavior? = nil,
        finished: Set<String> = [],
        secondIsDownloaded: Bool = true
    ) async throws -> FeedSetup {
        let statistics = preserveSharedStatistics()
        let world = try FeedTestWorld(self, label: "FeedEndOfBookRule", statistics: statistics)
        let guids: [String] = ["ep-3", "ep-2", "ep-1"]
        let items = guids.enumerated().map { offset, guid in
            FeedXML.Item(
                guid: guid,
                title: "Episode \(guid)",
                published: world.day(-Double(offset + 1)),
                enclosure: "https://atlas.example/audio/\(guid).mp3"
            )
        }
        world.server.serve("/atlas.xml", .feed(FeedXML.rss(items: items)))
        let feed = try await world.subscribe("/atlas.xml")

        /// One item of the feed, resting at its end (`Book.restsAtEnd`)
        /// when `finished` names it.
        func makeItem(_ title: String, _ guid: String) throws -> Book {
            let isFinished = finished.contains(title)
            let position = isFinished
                ? ReadingPosition(chapterIndex: 0, characterOffset: 40, globalCharacterOffset: 40)
                : nil
            var item = try makeFeedItem(title: title, itemID: "guid:\(guid)", of: feed.id, position: position)
            if isFinished {
                item.totalCharacterCount = 40
                XCTAssertTrue(item.restsAtEnd, "\(title) does not rest at its end")
            }
            return item
        }
        var third = try makeItem("Third", "ep-3")
        third.localEndOfBookBehavior = thirdEndsWith?.rawValue
        let second = try makeItem("Second", "ep-2")
        let first = try makeItem("First", "ep-1")

        for book in [third, second, first] where secondIsDownloaded || book.id != second.id {
            world.library.addFeedBook(book)
            world.center.store.updateItem(book.feedLink?.itemID ?? "", of: feed.id) { $0.state = .downloaded(bookID: book.id) }
        }
        world.center.setListeningOptions(options, of: feed.id)

        let configFile = try makeSandboxDirectory("FeedEndRuleConfig").appendingPathComponent("config.json")
        let notifications = NotificationCenter()
        let settings = SettingsViewModel(
            notificationCenter: notifications,
            initializeServices: false,
            userDefaults: makeSandboxedPreferences("FeedEndRuleSettings"),
            configService: ConfigService(fileURL: configFile)
        )
        settings.endOfBookBehavior = global
        return FeedSetup(world: world, settings: settings, notifications: notifications, third: third, second: second, first: first)
    }

    /// Ends `book` in a reader of `setup`'s world, as the reader reaches
    /// its last chapter's end, and says what it announced and which books it
    /// asked for.
    ///
    /// - Parameters:
    ///   - book: The item whose reader ends.
    ///   - setup: The feed and the settings.
    ///   - expectingARequest: Whether the end is meant to ask for another
    ///     item, so the wait for the request ends as soon as it is made.
    private func end(
        _ book: Book,
        in setup: FeedSetup,
        expectingARequest: Bool
    ) async -> (announced: [String], asked: [UUID]) {
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: setup.world.library,
            settingsViewModel: setup.settings,
            substitutionService: TextSubstitutionService(rules: []),
            autoplayRequests: ReaderAutoplayRequests(),
            notificationCenter: setup.notifications,
            renderScheduler: nil
        )
        addTeardownBlock { @MainActor in reader.close() }
        await waitFor("the item loads in its reader") { !reader.isLoading }

        var asked: [UUID] = []
        let subscription = setup.notifications.publisher(for: .continueToNextBook)
            .sink { note in
                if let nextBookID = note.nextBookID { asked.append(nextBookID) }
            }
        defer { subscription.cancel() }

        // Everything a book's end says, it says as it ends; the request for
        // the next item follows after a moment (`continueToNextBookDelay`).
        // The wait is by suspending, not by turning the run loop: an async
        // test's own main-actor work would be run inside it.
        let recorder = recordingAnnouncements {
            reader.handleEndOfBook()
        }
        if expectingARequest {
            await waitFor("the item asks for the next one") { !asked.isEmpty }
        }
        // Long enough for any second request to arrive.
        try? await Task.sleep(for: .seconds(ReaderViewModel.continueToNextBookDelay * 2))
        return (recorder.announcements.map(\.message), asked)
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
