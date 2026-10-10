import XCTest
@testable import TextMouth

/// The feed reader from end to end (FR03), against a stub server and with
/// real readers: an episode a refresh finds new downloads by itself, opens
/// in a reader, counts among Books Finished when the reader reaches its end,
/// and has its download deleted once its reader closes; an article read
/// from its web page opens as an HTML book whose text the reader shows. No
/// reader plays anything aloud: each one's end is reached directly, as the
/// reader reaches it when its last chapter ends.
@MainActor
final class FeedEndToEndTests: XCTestCase {

    /// An episode, from the refresh that finds it to the deletion of its
    /// download: it downloads by itself into the feed's folder, opens in a
    /// real reader, is played when the reader reaches its end, which Books
    /// Finished counts, waits while the reader has it open, and is deleted,
    /// its item kept, once the reader closes.
    func testAnEpisodeFromItsFeedToTheDeletionOfItsDownload() async throws {
        let statistics = preserveSharedStatistics()
        let world = try FeedTestWorld(self, label: "FeedEndToEnd", worksOnItsOwn: true, statistics: statistics)
        FeedSettings.refreshAtLaunchPreference.write(false, to: world.preferences)
        FeedSettings.refreshIntervalHoursPreference.write(0, to: world.preferences)
        FeedSettings.autoDownloadPreference.write(true, to: world.preferences)
        FeedSettings.deleteDownloadsDaysAfterPlayedPreference.write(0, to: world.preferences)
        world.server.serve("/audio/2.m4a", FeedMediaFixtures.file(try FeedMediaFixtures.silentAAC(duration: 2), mimeType: "audio/mp4"))
        let old = FeedXML.Item(guid: "ep-1", title: "The first visit", published: world.day(-3))
        let new = FeedXML.Item(guid: "ep-2", title: "A map you can touch", published: world.day(0.5),
                               enclosure: world.server.url("/audio/2.m4a").absoluteString, enclosureType: "audio/mp4")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [old])), .feed(FeedXML.rss(items: [new, old])))

        await world.start()
        let feed = try await world.subscribe("/feed.xml")
        world.advance(by: 86_400)
        let summary = await world.center.refreshAll()
        XCTAssertEqual(summary.newItemCount, 1)
        // The refresh found it new, and downloads it by itself.
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-2")
        // A feed item's, in its feed's own folder (FR11).
        XCTAssertEqual(book.folderPath, "")
        XCTAssertEqual(book.feedLink, FeedBookLink(feedID: feed.id, itemID: "guid:ep-2"))
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).metadata.feedLink, FeedBookLink(feedID: feed.id, itemID: "guid:ep-2"))

        let reader = try openReader(for: book, in: world)
        await waitFor("the episode loads in its reader") { !reader.isLoading }
        XCTAssertNil(reader.errorMessage)
        XCTAssertTrue(world.library.openBookIDs.contains(book.id))

        reader.handleEndOfBook()

        let played = world.center.store.record(of: feed.id)?.item("guid:ep-2")?.playedDate
        XCTAssertEqual(played, world.clock.value)
        XCTAssertEqual(statistics.stats.finishedBooks.map(\.bookID), [book.id.uuidString])
        // Played, the episode asks for a sweep, which must pass it by while
        // its reader has it open.
        await waitFor("the sweep the finished episode asked for ends") { !world.center.isSweeping }
        XCTAssertNotNil(world.library.bookByID(book.id), "a download open in a reader was deleted")

        reader.close()
        await waitFor("the played download is deleted once its reader closes") { world.library.bookByID(book.id) == nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
        let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-2"))
        XCTAssertEqual(item.state, .notDownloaded)
        XCTAssertEqual(item.playedDate, played)
        XCTAssertEqual(world.center.listedItems(of: feed.id).map(\.title), ["A map you can touch", "The first visit"])
    }

    /// An article whose feed gives only a summary is opened from the
    /// library: it downloads its web page first, becomes an HTML book in the
    /// feed's folder, opens in a reader, and the reader shows the page's
    /// article.
    func testAnArticleOpensAsItsWebPagesText() async throws {
        preserveSharedStatistics()
        let world = try FeedTestWorld(self, label: "FeedArticleEndToEnd")
        let story = (1...240).map { "The tram climbs past stop \($0)." }.joined(separator: " ")
        let page = "<html><body><header>Site menu</header><article><h2>Night trams</h2><p>\(story)</p></article></body></html>"
        world.server.serve("/stories/trams", StubResponse(headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(page.utf8)))
        let item = FeedXML.Item(guid: "story-1", title: "Night trams", published: world.day(-1),
                                description: "Which routes still run after midnight [...]", link: world.server.url("/stories/trams").absoluteString)
        world.server.serve("/feed.xml", .feed(FeedXML.rss(title: "City Notes", items: [item])))
        let feed = try await world.subscribe("/feed.xml")
        var opened: [UUID] = []
        world.library.readerOpener = { opened.append($0) }

        world.center.open("guid:story-1", of: feed.id)
        await waitFor("the article downloads and opens", timeout: 20) { !opened.isEmpty }
        let book = try XCTUnwrap(world.library.bookByID(try XCTUnwrap(opened.first)))
        XCTAssertEqual(book.format, .html)
        XCTAssertEqual(book.title, "Night trams")

        let reader = try openReader(for: book, in: world)
        await waitFor("the article loads in its reader") { !reader.isLoading }
        defer { reader.close() }
        let text = reader.content?.chapters.map(\.text).joined(separator: "\n") ?? ""
        XCTAssertTrue(text.contains("The tram climbs past stop 240."), "the page's article was not read")
        XCTAssertTrue(text.contains("City Notes"))
        XCTAssertFalse(text.contains("Site menu"), "the page's header was read")
    }

    // MARK: - Helpers

    /// A reader of `book` in `world`'s library, as a reader window makes
    /// one, with settings of the test's own that stop at the end of a book;
    /// closed when the test ends, if the test has not closed it.
    private func openReader(for book: Book, in world: FeedTestWorld) throws -> ReaderViewModel {
        let configFile = try makeSandboxDirectory("FeedReaderConfig").appendingPathComponent("config.json")
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: makeSandboxedPreferences("FeedReaderSettings"),
            configService: ConfigService(fileURL: configFile)
        )
        // A finished book stops, so no next book starts, and counts among
        // Books Finished, as every end-of-book behavior but looping does.
        settings.endOfBookBehavior = .stop
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: world.library,
            settingsViewModel: settings,
            substitutionService: TextSubstitutionService(rules: []),
            autoplayRequests: ReaderAutoplayRequests(),
            notificationCenter: NotificationCenter(),
            renderScheduler: nil
        )
        addTeardownBlock { @MainActor in reader.close() }
        return reader
    }

    /// The app's shared statistics, which readers count finished books in,
    /// emptied for the test and put back as they were when it ends, as the
    /// integration tests' worlds do.
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
