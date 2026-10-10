import XCTest
@testable import TextMouth

// MARK: - Unsubscribe as a Switch (FR11, Branch D)

/// Unsubscribing is a switch (FR11, branch D; the listener's answer of
/// October 9: "just keep it a feed with rules kept except you can't check
/// it or manually check it for new items"): a feed's record says whether it
/// is subscribed, an absent field meaning subscribed, so every record
/// written before the switch, the listener's two among them, reads as
/// subscribed and is written exactly as it was.
final class FeedSubscriptionRecordTests: XCTestCase {

    // MARK: - The Record

    /// A record written before the switch, shaped like the listener's own
    /// two ("The Digital Antiquarian" and "Finish It!"), has no field for
    /// it, and reads as subscribed.
    func testARecordWrittenBeforeTheSwitchReadsAsSubscribed() throws {
        for (title, address) in [
            ("The Digital Antiquarian", "https://www.filfre.net/feed/"),
            ("Finish It!", "https://finish.example/feed.xml"),
        ] {
            let json = """
            {
              "feed" : {
                "feedURL" : "\(address)",
                "folderID" : "\(UUID().uuidString)",
                "id" : "\(UUID().uuidString)",
                "isSerial" : false,
                "newestItemDate" : "2026-10-03T18:00:00Z",
                "subscribedDate" : "2026-10-03T18:00:00Z",
                "title" : "\(title)",
                "usesInsecureTransport" : false
              },
              "formatVersion" : 1,
              "items" : [

              ]
            }
            """
            let record = try FeedRecordCoding.decoder().decode(FeedRecord.self, from: Data(json.utf8))
            XCTAssertNil(record.feed.unsubscribedDate, title)
            XCTAssertTrue(record.feed.isSubscribed, title)
        }
    }

    /// A subscribed feed's record writes no field for the switch, so its
    /// file is as it was; an unsubscribed feed's writes the date it was
    /// unsubscribed, and reads back unsubscribed, as it was written.
    func testOnlyAnUnsubscribedFeedWritesTheField() throws {
        let feed = Feed(
            feedURL: try XCTUnwrap(URL(string: "https://finish.example/feed.xml")),
            folderID: UUID(),
            subscribedDate: Date(timeIntervalSince1970: 1_790_000_000)
        )
        var record = FeedRecord(feed: feed, items: [FeedItem(id: "guid:ep-368", title: "Ep. 368", firstSeen: feed.subscribedDate)])
        XCTAssertTrue(record.feed.isSubscribed, "a new subscription was unsubscribed")

        let subscribed = try FeedRecordCoding.encoder().encode(record)
        let subscribedFeed = try XCTUnwrap(try JSONSerialization.jsonObject(with: subscribed) as? [String: Any])["feed"] as? [String: Any]
        XCTAssertNil(subscribedFeed?["unsubscribedDate"], "a subscribed feed's record wrote the field")

        record.feed.unsubscribedDate = Date(timeIntervalSince1970: 1_790_086_400)
        let unsubscribed = try FeedRecordCoding.encoder().encode(record)
        let unsubscribedFeed = try XCTUnwrap(try JSONSerialization.jsonObject(with: unsubscribed) as? [String: Any])["feed"] as? [String: Any]
        XCTAssertEqual(unsubscribedFeed?["unsubscribedDate"] as? String, "2026-09-22T14:13:20Z")

        let read = try FeedRecordCoding.decoder().decode(FeedRecord.self, from: unsubscribed)
        XCTAssertEqual(read, record)
        XCTAssertFalse(read.feed.isSubscribed)
    }
}

// MARK: - Checking Stops

/// Only checking stops for a feed the listener unsubscribed from (FR11,
/// branch D, item 2): no refresh at launch, on the interval, or in Refresh
/// All Feeds, and none by Check Feed; a refresh under way as it is
/// unsubscribed changes nothing. Its rules stay in force: the newest-N rule
/// downloads nothing for it by itself, takes back what it asked for, and
/// still removes its downloads beyond the newest, and Download by hand still
/// downloads a listed item. Each feed is unsubscribed here through its
/// record alone, as the engine's Unsubscribe leaves it, but in the test of
/// what the engine's Unsubscribe takes back at once. No test reaches the
/// network: every request goes to the world's stub server.
@MainActor
final class FeedSubscriptionCheckingTests: XCTestCase {

    // MARK: - Refreshing

    /// Refreshing every feed, as Refresh All Feeds, the launch, and the
    /// interval do, checks only the feeds the listener is subscribed to: an
    /// unsubscribed feed's address is never asked for, and it has no report.
    func testRefreshingEveryFeedPassesOverAnUnsubscribedFeed() async throws {
        let world = try FeedTestWorld(self, label: "FeedSwitchRefreshAll")
        let checked = try await subscribe(world, path: "/checked.xml", title: "Checked")
        let stopped = try await subscribe(world, path: "/stopped.xml", title: "Stopped")
        markUnsubscribed(stopped, in: world)
        let checkedBefore = world.server.requests(to: "/checked.xml").count
        let stoppedBefore = world.server.requests(to: "/stopped.xml").count

        for origin in [FeedRefreshOrigin.listener, .launch, .scheduled] {
            let summary = await world.center.refreshAll(origin: origin)
            XCTAssertEqual(summary.reports.map(\.feedID), [checked.id], "the \(origin) refresh")
        }

        XCTAssertEqual(world.server.requests(to: "/stopped.xml").count, stoppedBefore, "an unsubscribed feed was checked")
        XCTAssertEqual(world.server.requests(to: "/checked.xml").count, checkedBefore + 3)
    }

    /// Check Feed checks nothing while the feed is unsubscribed: no request,
    /// no report, and the feed never shows as checking.
    func testCheckFeedChecksNothingWhileUnsubscribed() async throws {
        let world = try FeedTestWorld(self, label: "FeedSwitchCheck")
        let feed = try await subscribe(world, path: "/stopped.xml", title: "Stopped")
        markUnsubscribed(feed, in: world)
        let asked = world.server.requests(to: "/stopped.xml").count
        var shownChecking = false
        let watching = world.center.$refreshingFeedIDs.sink { shownChecking = shownChecking || $0.contains(feed.id) }
        defer { watching.cancel() }

        let report = await world.center.refresh(feed.id)

        XCTAssertNil(report)
        XCTAssertFalse(shownChecking, "an unsubscribed feed showed as checking")
        XCTAssertEqual(world.server.requests(to: "/stopped.xml").count, asked)
    }

    /// A refresh under way as its feed is unsubscribed changes nothing: it
    /// reports nothing, the record keeps its items as they were, still
    /// unsubscribed, and this Mac's fetch details stay as they were.
    func testARefreshUnderWayAsTheFeedIsUnsubscribedChangesNothing() async throws {
        let world = try FeedTestWorld(self, label: "FeedSwitchMidRefresh")
        let feed = try await subscribe(world, path: "/feed.xml", title: "Atlas")
        let fetchedBefore = world.center.fetchState(of: feed.id)
        var slow = StubResponse.feed(FeedXML.rss(title: "Atlas", items: [
            FeedXML.Item(guid: "b", title: "B"),
            FeedXML.Item(guid: "a", title: "A"),
        ]))
        slow.pause = 0.3
        world.server.serve("/feed.xml", slow)
        world.advance(by: 3_600)

        async let ending = world.center.refresh(feed.id)
        await waitFor("the feed is refreshing") { world.center.refreshingFeedIDs.contains(feed.id) }
        markUnsubscribed(feed, in: world)
        let report = await ending

        XCTAssertNil(report)
        let record = try XCTUnwrap(world.center.store.record(of: feed.id))
        XCTAssertFalse(record.feed.isSubscribed)
        XCTAssertEqual(record.items.map(\.id), ["guid:a"], "a refresh ending after the feed was unsubscribed merged")
        XCTAssertEqual(world.center.fetchState(of: feed.id), fetchedBefore)
    }

    // MARK: - The Rules

    /// The newest-N rule downloads nothing for an unsubscribed feed, however
    /// its number grows, while its removals go on: holding more of its
    /// downloads than a smaller number, it removes its oldest beyond the
    /// newest, as for any feed. The listener's Download still downloads a
    /// listed item.
    func testTheRuleOnlyRemovesForAnUnsubscribedFeed() async throws {
        let world = try FeedTestWorld(self, label: "FeedSwitchRule")
        FeedSettings.newestCountPreference.write(3, to: world.preferences)
        let feed = try await subscribeServed(world, episodes: 5)
        _ = await world.center.applyItemPolicy(to: [feed.id])
        let books = try await downloadedBooks(world, feed: feed, items: ["guid:ep-1", "guid:ep-2", "guid:ep-3"])
        markUnsubscribed(feed, in: world)

        FeedSettings.newestCountPreference.write(5, to: world.preferences)
        let wider = await world.center.applyItemPolicy(to: [feed.id])
        XCTAssertEqual(wider.requestedItemIDs, [], "the rule downloaded for an unsubscribed feed")
        XCTAssertEqual(world.server.requests(to: "/audio/4.m4a"), [])

        FeedSettings.newestCountPreference.write(1, to: world.preferences)
        let narrower = await world.center.applyItemPolicy(to: [feed.id])
        XCTAssertEqual(narrower.removedBookIDs, [books[2].id, books[1].id], "an unsubscribed feed's rule removed nothing")
        XCTAssertNotNil(world.library.bookByID(books[0].id))

        world.center.download("guid:ep-4", of: feed.id)
        let byHand = try await downloadedBook(world, feed: feed, item: "guid:ep-4")
        XCTAssertNotNil(world.library.bookByID(byHand.id), "Download by hand downloaded nothing")
    }

    /// The rule's downloads not yet under way go back at its first pass over
    /// a feed once it is unsubscribed; the one under way finishes, and stays.
    func testTheRuleTakesBackItsWaitingDownloadsOfAnUnsubscribedFeed() async throws {
        let world = try FeedTestWorld(self, label: "FeedSwitchWithdraw")
        FeedSettings.newestCountPreference.write(3, to: world.preferences)
        let feed = try await subscribeServed(world, episodes: 4, pausing: 0.05)
        _ = await world.center.applyItemPolicy(to: [feed.id])
        await waitFor("the first download is under way") { !world.server.requests(to: "/audio/1.m4a").isEmpty }
        markUnsubscribed(feed, in: world)

        let pass = await world.center.applyItemPolicy(to: [feed.id])

        XCTAssertEqual(pass.withdrawnItemIDs, ["guid:ep-2", "guid:ep-3"])
        XCTAssertEqual(pass.requestedItemIDs, [])
        let first = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        XCTAssertNotNil(world.library.bookByID(first.id))
        XCTAssertEqual(world.server.requests(to: "/audio/2.m4a"), [], "a download taken back was fetched")
    }

    /// The engine's Unsubscribe takes back the rule's downloads not yet under
    /// way at once, and leaves the listener's waiting downloads and the one
    /// under way to finish.
    func testUnsubscribingTakesBackTheRulesWaitingDownloadsAtOnce() async throws {
        let world = try FeedTestWorld(self, label: "FeedSwitchUnsubscribeWithdraws")
        FeedSettings.newestCountPreference.write(3, to: world.preferences)
        let feed = try await subscribeServed(world, episodes: 4, pausing: 0.05)
        _ = await world.center.applyItemPolicy(to: [feed.id])
        await waitFor("the first download is under way") { !world.server.requests(to: "/audio/1.m4a").isEmpty }
        world.center.download("guid:ep-4", of: feed.id)

        world.center.unsubscribe(feed.id)

        let record = try XCTUnwrap(world.center.store.record(of: feed.id))
        XCTAssertEqual(record.item("guid:ep-2")?.state, .notDownloaded)
        XCTAssertEqual(record.item("guid:ep-3")?.state, .notDownloaded)
        XCTAssertTrue(world.center.downloads.isDownloading("guid:ep-4", of: feed.id), "the listener's download was taken back")
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-4")
        XCTAssertEqual(world.server.requests(to: "/audio/2.m4a"), [], "a download taken back was fetched")
    }

    // MARK: - Helpers

    /// Unsubscribes `world` from `feed` through its record alone, as the
    /// engine's Unsubscribe leaves it, at the world's clock.
    private func markUnsubscribed(_ feed: Feed, in world: FeedTestWorld) {
        world.center.store.update(feed.id) { $0.feed.unsubscribedDate = world.clock.value }
    }

    /// Subscribes `world` to a feed titled `title` at `path` of one entry,
    /// "guid:a".
    private func subscribe(_ world: FeedTestWorld, path: String, title: String) async throws -> Feed {
        world.server.serve(path, .feed(FeedXML.rss(title: title, items: [FeedXML.Item(guid: "a", title: "A")])))
        return try await world.subscribe(path)
    }

    /// Subscribes `world` to a feed of `episodes` audio episodes, "guid:ep-1"
    /// the newest, each served as a second of silence at
    /// /audio/<number>.m4a, whose parts come `pausing` seconds apart when
    /// given, so a test can catch the downloads waiting behind the first.
    private func subscribeServed(_ world: FeedTestWorld, episodes: Int, pausing pause: TimeInterval? = nil) async throws -> Feed {
        let audio = try FeedMediaFixtures.silentAAC()
        var file = FeedMediaFixtures.file(audio, mimeType: "audio/mp4")
        if let pause {
            file.chunkSize = max(1, audio.count / 20)
            file.pause = pause
        }
        let items = (1...episodes).map { number in
            world.server.serve("/audio/\(number).m4a", file)
            return FeedXML.Item(guid: "ep-\(number)", title: "Episode \(number)", published: world.day(-Double(number)),
                                enclosure: world.server.url("/audio/\(number).m4a").absoluteString, enclosureType: "audio/mp4")
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: items)))
        return try await world.subscribe("/feed.xml")
    }

    /// The books the items `itemIDs` of `feed` download as, each waited for.
    private func downloadedBooks(_ world: FeedTestWorld, feed: Feed, items itemIDs: [FeedItem.ID]) async throws -> [Book] {
        var books: [Book] = []
        for itemID in itemIDs {
            books.append(try await downloadedBook(world, feed: feed, item: itemID))
        }
        return books
    }
}

// MARK: - The Switch Shown

/// The feed's context menu, its VoiceOver actions, and Feed Info offer
/// Unsubscribe… or Resubscribe by its state (FR11, branch D, item 3; the
/// listener's "subscribe / resubscribe toggling action in the contetxt menu
/// for feeds and changing the info menu"), and no Check Feed while it is not
/// checked; its row, its folder's row, entering its folder, Speak Info, and
/// Feed Info say it is unsubscribed and not checked; Resubscribe checks it
/// at once and says so; Add Feed with its address points to Resubscribe.
@MainActor
final class FeedSubscriptionShownTests: XCTestCase {

    // MARK: - The Words

    /// A subscribed feed offers Check Feed, Feed Info…, Mark All Played, and
    /// Unsubscribe…; an unsubscribed one Feed Info…, Mark All Played (Mark
    /// All Read for articles), and Resubscribe, which asks nothing first.
    func testAFeedOffersUnsubscribeOrResubscribeByItsState() {
        let feedID = UUID()
        XCTAssertEqual(
            FeedAction.actions(for: feedID, noun: .episode, isSubscribed: true).map(\.title),
            ["Check Feed", "Feed Info…", "Mark All Played", "Unsubscribe…"]
        )
        let unsubscribed = FeedAction.actions(for: feedID, noun: .article, isSubscribed: false)
        XCTAssertEqual(unsubscribed.map(\.title), ["Feed Info…", "Mark All Read", "Resubscribe"])
        XCTAssertEqual(unsubscribed.map(\.command), [.feedInfo, .markAllPlayed, .resubscribe])
        XCTAssertNil(unsubscribed.last?.role, "Resubscribe was offered as destructive")
    }

    /// An unsubscribed feed's last check says it is not checked, since when
    /// this Mac last checked it, a failed check included; its row, its
    /// folder's row and rotor entry, entering its folder, and Speak Info say
    /// "unsubscribed" after "Feed".
    func testTheUnsubscribedStateIsSaidWhereverTheFeedIs() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_US")
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 9)))
        /// The check as an unsubscribed feed reads it, a narrow space before
        /// AM or PM made a plain one, as some systems write it.
        func reading(_ fetch: FeedFetchState) -> FeedWording.Check {
            let check = FeedWording.check(fetch, isRefreshing: false, isSubscribed: false, now: now, calendar: calendar, locale: locale)
            return FeedWording.Check(
                visible: check.visible.replacingOccurrences(of: "\u{202F}", with: " "),
                spoken: check.spoken.replacingOccurrences(of: "\u{202F}", with: " "),
                failed: check.failed
            )
        }
        var fetch = FeedFetchState()
        XCTAssertEqual(reading(fetch), FeedWording.Check(visible: "Not checked", spoken: "not checked", failed: false))
        fetch.lastCheck = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 15, minute: 5))
        let check = reading(fetch)
        XCTAssertEqual(check, FeedWording.Check(
            visible: "Not checked since yesterday at 3:05 PM",
            spoken: "not checked since yesterday at 3:05 PM",
            failed: false
        ))
        fetch.lastError = FeedRefreshFailure(message: "The server didn't answer.", date: try XCTUnwrap(fetch.lastCheck))
        XCTAssertEqual(reading(fetch), check, "an unsubscribed feed's old failure was read as its check")

        var counts = FeedItemCounts(listed: 10, total: FeedEntryTotal(count: 381), downloaded: 2, noun: .episode)
        counts.isSubscribed = false
        XCTAssertEqual(
            FeedWording.feedRowLabel(title: "Finish It!", counts: counts, check: check, folderMissing: false),
            "Finish It!, Feed, unsubscribed, 10 of 381 episodes listed, 2 downloaded, not checked since yesterday at 3:05 PM"
        )
        XCTAssertEqual(
            FeedWording.feedRowLabel(title: "Finish It!", counts: counts, check: check, folderMissing: true),
            "Finish It!, Feed, unsubscribed, Folder missing, 10 of 381 episodes listed, 2 downloaded, not checked since yesterday at 3:05 PM"
        )
        let announcement = "Finish It!, Feed, unsubscribed, 10 of 381 episodes listed, 2 downloaded"
        XCTAssertEqual(FeedWording.folderAnnouncement(name: "Finish It!", counts: counts), announcement)
        XCTAssertEqual(FolderRow.accessibilityLabel(name: "Finish It!", bookCount: 0, feedCounts: counts), announcement)
        let facts = FeedInfoFacts(title: "Finish It!", counts: counts, check: check.visible, folderPath: "Podcasts/Finish It!", address: nil)
        XCTAssertEqual(
            LibraryInfoWording.briefParts(of: facts),
            ["Finish It!", "Feed", "Unsubscribed", "10 of 381 episodes listed, 2 downloaded", "Not checked since yesterday at 3:05 PM"]
        )
        counts.isSubscribed = true
        XCTAssertEqual(FeedWording.folderAnnouncement(name: "Finish It!", counts: counts), "Finish It!, Feed, 10 of 381 episodes listed, 2 downloaded")
    }

    // MARK: - Through the Commands

    /// Unsubscribe… from Feed Info leaves the sheet open, its feed now
    /// counted unsubscribed and its commands Feed Info…, Mark All Played,
    /// and Resubscribe; Check Feed from a menu drawn before checks nothing
    /// and says why; Resubscribe says it checks the feed now, checks it, and
    /// says what came; and the folders' publisher tells the Library window of
    /// each toggle.
    func testUnsubscribeAndResubscribeThroughTheCommands() async throws {
        let world = try FeedTestWorld(self, label: "FeedSwitchCommands")
        let episodeA = FeedXML.Item(guid: "a", title: "A", published: world.day(-1), enclosure: "https://atlas.example/a.mp3")
        let episodeB = FeedXML.Item(guid: "b", title: "B", published: world.day(1), enclosure: "https://atlas.example/b.mp3")
        world.server.serve("/atlas.xml", .feed(FeedXML.rss(items: [episodeA])))
        let feed = try await world.subscribe("/atlas.xml")
        let folders = LibraryFeedFolders(center: world.center)
        var publishes = 0
        let watching = folders.objectWillChange.sink { publishes += 1 }
        defer { watching.cancel() }
        let presenter = LibraryFeedsPresenter()
        var heard: [String] = []
        presenter.announce = { message, _ in heard.append(message) }
        let context = FeedCommandContext(center: world.center, library: world.library, window: nil)
        let checkFeed = try XCTUnwrap(FeedAction.actions(for: feed.id, in: world.center).first { $0.command == .checkFeed })
        presenter.perform(try XCTUnwrap(FeedAction.actions(for: feed.id, in: world.center).first { $0.command == .feedInfo }), in: context)
        let info = try XCTUnwrap(presenter.feedInfo)

        presenter.unsubscribe(feed.id, in: context)

        XCTAssertTrue(presenter.feedInfo === info, "Feed Info closed as the feed was unsubscribed")
        XCTAssertEqual(info.feed?.isSubscribed, false)
        XCTAssertFalse(world.center.counts(of: feed.id).isSubscribed)
        XCTAssertEqual(FeedAction.actions(for: feed.id, in: world.center).map(\.command), [.feedInfo, .markAllPlayed, .resubscribe])
        XCTAssertEqual(folders.unsubscribedFeedIDs, [feed.id])
        XCTAssertGreaterThan(publishes, 0, "the Library window heard nothing of the toggle")
        let row = try XCTUnwrap(LibraryFeedsSectionRows.rows(at: LibraryLocation(category: .allItems, folderPath: ""), center: world.center).first)
        XCTAssertTrue(row.label.hasPrefix("The Tactile Atlas, Feed, unsubscribed, 1 episode"), row.label)

        let asked = world.server.requests(to: "/atlas.xml").count
        XCTAssertNil(presenter.perform(checkFeed, in: context))
        XCTAssertEqual(heard.last, "The Tactile Atlas is unsubscribed, so TextMouth doesn't check it. Choose Resubscribe to check it again.")
        XCTAssertEqual(world.server.requests(to: "/atlas.xml").count, asked, "Check Feed checked an unsubscribed feed")

        world.server.serve("/atlas.xml", .feed(FeedXML.rss(items: [episodeB, episodeA])))
        world.advance(by: 2 * 86_400)
        let resubscribe = try XCTUnwrap(FeedAction.actions(for: feed.id, in: world.center).last)
        await presenter.perform(resubscribe, in: context)?.value

        XCTAssertEqual(heard.suffix(2), ["Resubscribed to The Tactile Atlas. Checking it now…", "The Tactile Atlas: 1 new episode."])
        XCTAssertEqual(info.feed?.isSubscribed, true)
        XCTAssertEqual(folders.unsubscribedFeedIDs, [])
        XCTAssertEqual(FeedAction.actions(for: feed.id, in: world.center).map(\.command), [.checkFeed, .feedInfo, .markAllPlayed, .unsubscribe])
    }

    /// Add Feed with the address of a feed the listener unsubscribed from
    /// subscribes nothing new, and says to choose Resubscribe.
    func testAddFeedPointsAnUnsubscribedFeedToResubscribe() async throws {
        let world = try FeedTestWorld(self, label: "FeedSwitchAddFeed")
        world.server.serve("/atlas.xml", .feed(FeedXML.rss(items: [FeedXML.Item(guid: "a", title: "A")])))
        let feed = try await world.subscribe("/atlas.xml")
        world.center.unsubscribe(feed.id)

        do {
            _ = try await world.center.subscribe(to: world.server.url("/atlas.xml").absoluteString, folderID: world.bookFolder.id)
            XCTFail("an unsubscribed feed was subscribed to again")
        } catch let error as FeedSubscribeError {
            XCTAssertEqual(error, .unsubscribedAlready(title: "The Tactile Atlas"))
            XCTAssertEqual(
                error.message,
                "The Tactile Atlas is in your library, unsubscribed. Choose Resubscribe on its row, or in its Feed Info, to check it again."
            )
        }
        XCTAssertEqual(world.center.feeds.map(\.id), [feed.id])
    }
}
