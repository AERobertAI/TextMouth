import Combine
import XCTest
@testable import TextMouth

/// Subscribing and refreshing (FR03), against a stub server, so no test
/// reaches the network: conditional requests and the body's digest, merging
/// by identity with the kept-entries rule, new items announced, failures
/// worded and recorded for their feed alone, offline and constrained
/// networks, moved feeds, a launch that never holds the library back, and
/// the scheduled refreshes.
@MainActor
final class FeedRefresherTests: XCTestCase {

    // MARK: - Subscribing

    /// Subscribing reads the feed, keeps its 10 newest entries, newest
    /// first, in the folder chosen, records how it was fetched, announces
    /// the subscription, and marks none of the back catalog new.
    func testSubscribingReadsTheFeedAndKeepsItsNewestEntries() async throws {
        let world = try FeedTestWorld(self, label: "FeedSubscribe")
        let items = (1...12).map { number in
            FeedXML.Item(guid: "ep-\(number)", title: "Episode \(number)", published: world.day(-Double(number)),
                         enclosure: world.server.url("/audio/\(number).mp3").absoluteString)
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: items), headers: [
            "ETag": "\"v1\"", "Last-Modified": "Wed, 01 Oct 2026 10:00:00 GMT",
        ]))
        var events: [FeedEvent] = []
        let subscription = world.center.events.sink { events.append($0) }
        defer { subscription.cancel() }

        let feed = try await world.subscribe("/feed.xml")

        XCTAssertEqual(feed.title, "The Tactile Atlas")
        XCTAssertEqual(feed.folderID, world.bookFolder.id)
        XCTAssertEqual(feed.subscribedDate, world.clock.value)
        let record = try XCTUnwrap(world.center.store.record(of: feed.id))
        XCTAssertEqual(record.items.map(\.title), (1...10).map { "Episode \($0)" })
        XCTAssertEqual(events, [.subscribed(feedID: feed.id)])
        let state = world.center.fetchState(of: feed.id)
        XCTAssertEqual(state.etag, "\"v1\"")
        XCTAssertEqual(state.lastModified, "Wed, 01 Oct 2026 10:00:00 GMT")
        XCTAssertNotNil(state.bodyDigest)
        XCTAssertEqual(state.lastSuccess, world.clock.value)
        await world.center.store.flush()
        await world.center.fetchStates.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: FeedPaths.recordFile(of: feed.id, in: world.recordsFolder).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: FeedPaths.recordFile(of: feed.id, in: world.fetchStateFolder).path))
    }

    /// A feed already subscribed, at any spelling of its address, is not
    /// subscribed twice; an address that is no web address, and a folder no
    /// longer in the library, are refused before anything is fetched.
    func testSubscribingRefusesWhatItCannotDo() async throws {
        let world = try FeedTestWorld(self, label: "FeedSubscribeRefusals")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [FeedXML.Item(guid: "a", title: "A")])))
        _ = try await world.subscribe("/feed.xml")

        await assertSubscribing(world, to: world.server.url("/feed.xml/").absoluteString, throws: .alreadySubscribed(title: "The Tactile Atlas"))
        await assertSubscribing(world, to: world.server.insecureURL("/feed.xml").absoluteString, throws: .alreadySubscribed(title: "The Tactile Atlas"))
        await assertSubscribing(world, to: "ftp://files.example/feed.xml", throws: .invalidAddress)
        await assertSubscribing(world, to: world.server.url("/other.xml").absoluteString, folderID: UUID(), throws: .folderMissing)
        XCTAssertEqual(world.server.requests.count, 1)
    }

    /// A web page naming one feed subscribes to that feed; one naming
    /// several offers them to choose from, in order; one naming none says
    /// so.
    func testAWebPageLeadsToTheFeedsItNames() async throws {
        let world = try FeedTestWorld(self, label: "FeedSubscribePages")
        let html = ["Content-Type": "text/html; charset=utf-8"]
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [FeedXML.Item(guid: "a", title: "A")])))
        world.server.serve("/one.html", StubResponse(headers: html, body: Data(FeedXML.page(naming: [world.server.url("/feed.xml")]).utf8)))
        let several = [world.server.url("/news.xml"), world.server.url("/comments.xml")]
        world.server.serve("/two.html", StubResponse(headers: html, body: Data(FeedXML.page(naming: several).utf8)))
        world.server.serve("/none.html", StubResponse(headers: html, body: Data(FeedXML.page(naming: []).utf8)))

        let feed = try await world.subscribe("/one.html")
        XCTAssertEqual(feed.feedURL, world.server.url("/feed.xml"))

        let outcome = try await world.center.subscribe(to: world.server.url("/two.html").absoluteString, folderID: world.bookFolder.id)
        XCTAssertEqual(outcome, .choose(several.map { FeedLink(url: $0, title: nil, mimeType: "application/rss+xml") }))

        await assertSubscribing(world, to: world.server.url("/none.html").absoluteString, throws: .pageNamesNoFeed)
    }

    /// A feed fetched over plain http, or listing an enclosure at a plain
    /// http address, is flagged for the warning shown after it is added; a
    /// feed that uses https throughout is not.
    func testPlainHTTPIsFlagged() async throws {
        let world = try FeedTestWorld(self, label: "FeedInsecure")
        let secureItem = FeedXML.Item(guid: "s", title: "S", enclosure: world.server.url("/s.mp3").absoluteString)
        let insecureItem = FeedXML.Item(guid: "i", title: "I", enclosure: world.server.insecureURL("/i.mp3").absoluteString)
        world.server.serve("/secure.xml", .feed(FeedXML.rss(title: "Secure", items: [secureItem])))
        world.server.serve("/mixed.xml", .feed(FeedXML.rss(title: "Mixed", items: [insecureItem])))
        world.server.serve("/plain.xml", .feed(FeedXML.rss(title: "Plain", items: [secureItem])))

        let secure = try await world.subscribe("/secure.xml")
        let mixed = try await world.subscribe("/mixed.xml")
        let plainOutcome = try await world.center.subscribe(
            to: world.server.insecureURL("/plain.xml").absoluteString,
            folderID: world.bookFolder.id
        )

        XCTAssertFalse(secure.usesInsecureTransport)
        XCTAssertTrue(mixed.usesInsecureTransport)
        guard case .subscribed(let plain) = plainOutcome else { return XCTFail("subscribing ended with \(plainOutcome)") }
        XCTAssertTrue(plain.usesInsecureTransport)
    }

    /// Subscribing while offline fails at once, saying so, with no request.
    func testSubscribingOfflineFailsAtOnce() async throws {
        let world = try FeedTestWorld(self, label: "FeedSubscribeOffline")
        await world.start()
        world.online.value = false

        await assertSubscribing(
            world,
            to: world.server.url("/feed.xml").absoluteString,
            throws: .refreshFailed(.fetch(.offline), host: world.server.host)
        )
        XCTAssertEqual(world.server.requests, [])
    }

    // MARK: - Unchanged Feeds

    /// A refresh sends back the validators the last body came with, and a
    /// 304 leaves the record as it was, recording only the check.
    func testA304LeavesTheRecordAsItWas() async throws {
        let world = try FeedTestWorld(self, label: "Feed304")
        let markup = FeedXML.rss(items: [FeedXML.Item(guid: "a", title: "A", published: world.day(-1))])
        world.server.serve("/feed.xml", .feed(markup, headers: [
            "ETag": "\"v1\"", "Last-Modified": "Wed, 01 Oct 2026 10:00:00 GMT",
        ]), StubResponse(status: 304))
        let feed = try await world.subscribe("/feed.xml")
        let before = world.center.store.record(of: feed.id)
        world.advance(by: 3_600)

        let report = try await unwrap(world.center.refresh(feed.id))

        XCTAssertEqual(report.outcome, .unchanged)
        let conditional = try XCTUnwrap(world.server.requests(to: "/feed.xml").last)
        XCTAssertEqual(conditional.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
        XCTAssertEqual(conditional.value(forHTTPHeaderField: "If-Modified-Since"), "Wed, 01 Oct 2026 10:00:00 GMT")
        XCTAssertTrue(conditional.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("TextMouth/") ?? false)
        XCTAssertEqual(world.center.store.record(of: feed.id), before)
        XCTAssertEqual(world.center.fetchState(of: feed.id).lastCheck, world.clock.value)
    }

    /// A server that ignores the validators and sends the same bytes again
    /// changes nothing either: the body's digest matches the last one.
    func testTheSameBytesAgainChangeNothing() async throws {
        let world = try FeedTestWorld(self, label: "FeedSameBytes")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [FeedXML.Item(guid: "a", title: "A", published: world.day(-1))])))
        let feed = try await world.subscribe("/feed.xml")
        let before = world.center.store.record(of: feed.id)

        let report = try await unwrap(world.center.refresh(feed.id))

        XCTAssertEqual(report.outcome, .unchanged)
        XCTAssertEqual(world.server.requests(to: "/feed.xml").count, 2)
        XCTAssertEqual(world.center.store.record(of: feed.id), before)
    }

    // MARK: - Changed Feeds

    /// A changed feed adds its new items, announcing those published since
    /// the subscription, updates the ones it changed, and keeps what the
    /// listener did with them.
    func testAChangedFeedAddsAndUpdatesItems() async throws {
        let world = try FeedTestWorld(self, label: "FeedChanged")
        let first = (1...3).map { FeedXML.Item(guid: "ep-\($0)", title: "Episode \($0)", published: world.day(-Double($0))) }
        var second = first
        second[1].title = "Episode 2, corrected"
        second.insert(FeedXML.Item(guid: "ep-new", title: "A new episode", published: world.day(0.5)), at: 0)
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: first)), .feed(FeedXML.rss(items: second)))
        let feed = try await world.subscribe("/feed.xml")
        let played = Date(timeIntervalSince1970: 1_790_999_000)
        world.center.store.updateItem("guid:ep-2", of: feed.id) { $0.playedDate = played }
        var events: [FeedEvent] = []
        let subscription = world.center.events.sink { events.append($0) }
        defer { subscription.cancel() }
        world.advance(by: 86_400)

        let report = try await unwrap(world.center.refresh(feed.id))

        XCTAssertEqual(report.outcome, .updated(newItemIDs: ["guid:ep-new"]))
        XCTAssertEqual(events, [.refreshed(report)])
        let record = try XCTUnwrap(world.center.store.record(of: feed.id))
        XCTAssertEqual(record.items.map(\.title), ["A new episode", "Episode 1", "Episode 2, corrected", "Episode 3"])
        XCTAssertEqual(record.item("guid:ep-2")?.playedDate, played)
        XCTAssertEqual(record.item("guid:ep-new")?.firstSeen, world.clock.value)
        XCTAssertEqual(record.feed.newestItemDate, world.day(0.5))
    }

    /// The kept-entries rule: the newest entries are kept, the feed's own
    /// override first; an item the feed no longer lists counts among them
    /// like any other; a downloaded item is always kept; and a changed
    /// number applies at the next refresh, even of a feed that has not
    /// changed.
    func testTheKeptEntriesRuleKeepsTheNewestAndEveryDownload() async throws {
        let world = try FeedTestWorld(self, label: "FeedKeptEntries")
        FeedSettings.keepEntriesPreference.write(2, to: world.preferences)
        let items = ["a", "b", "c"].enumerated().map { index, guid in
            FeedXML.Item(guid: guid, title: guid.uppercased(), published: world.day(-Double(index + 1)))
        }
        let later = [
            FeedXML.Item(guid: "d", title: "D", published: world.day(0.5)),
            FeedXML.Item(guid: "c", title: "C", published: world.day(-3)),
        ]
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: items)), .feed(FeedXML.rss(items: later)))
        let feed = try await world.subscribe("/feed.xml")
        XCTAssertEqual(world.center.listedItems(of: feed.id).map(\.title), ["A", "B"])
        let bookID = UUID()
        world.center.store.updateItem("guid:b", of: feed.id) { $0.state = .downloaded(bookID: bookID) }

        _ = await world.center.refresh(feed.id)

        XCTAssertEqual(world.center.listedItems(of: feed.id).map(\.title), ["D", "A", "B"])

        world.center.setKeepEntries(-1, of: feed.id)
        let report = try await unwrap(world.center.refresh(feed.id))
        XCTAssertEqual(report.outcome, .updated(newItemIDs: []), "the unchanged feed was not read again")
        XCTAssertEqual(world.center.listedItems(of: feed.id).map(\.title), ["D", "A", "B", "C"])
    }

    /// An item the listener deleted stays deleted while the feed lists it,
    /// and is forgotten once the feed stops listing it.
    func testADeletedItemNeverComesBack() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeletedItem")
        let items = [FeedXML.Item(guid: "a", title: "A", published: world.day(-1)),
                     FeedXML.Item(guid: "b", title: "B", published: world.day(-2))]
        world.server.serve(
            "/feed.xml",
            .feed(FeedXML.rss(items: items)),
            .feed(FeedXML.rss(title: "Again", items: items)),
            .feed(FeedXML.rss(title: "Once more", items: [items[1]]))
        )
        let feed = try await world.subscribe("/feed.xml")
        world.center.store.updateItem("guid:a", of: feed.id) { $0.deletedDate = world.clock.value }

        _ = await world.center.refresh(feed.id)
        XCTAssertEqual(world.center.listedItems(of: feed.id).map(\.title), ["B"])
        XCTAssertNotNil(world.center.store.record(of: feed.id)?.item("guid:a")?.deletedDate)

        _ = await world.center.refresh(feed.id)
        XCTAssertNil(world.center.store.record(of: feed.id)?.item("guid:a"))
    }

    /// A feed that renumbers its guids keeps its items: each is found again
    /// by its enclosure, keeps its identity and what the listener did, and
    /// nothing arrives as new.
    func testAFeedThatRenumbersItsGuidsKeepsItsItems() async throws {
        let world = try FeedTestWorld(self, label: "FeedRenumbered")
        let audio = world.server.url("/audio/1.mp3").absoluteString
        let before = FeedXML.Item(guid: "old-1", title: "One", published: world.day(-1), enclosure: audio)
        var after = before
        after.guid = "new-1"
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [before])), .feed(FeedXML.rss(items: [after])))
        let feed = try await world.subscribe("/feed.xml")
        let bookID = UUID()
        world.center.store.updateItem("guid:old-1", of: feed.id) { $0.state = .downloaded(bookID: bookID) }

        let report = try await unwrap(world.center.refresh(feed.id))

        XCTAssertEqual(report.newItemIDs, [])
        let items = world.center.listedItems(of: feed.id)
        XCTAssertEqual(items.map(\.id), ["guid:old-1"])
        XCTAssertEqual(items.first?.guid, "new-1")
        XCTAssertEqual(items.first?.state, .downloaded(bookID: bookID))
    }

    // MARK: - Merging Undated Feeds

    /// A feed that dates none of its items, as LibriVox's, keeps its newest
    /// entries by its own order: a serial show's newest are at the bottom,
    /// an episodic show's at the top. Nothing in a first reading is new; a
    /// chapter added at the end later is, while the older chapters a later
    /// reading lists again, behind the ones kept, are not, and never push
    /// the kept ones out; keeping more entries brings them back in the
    /// feed's order, unannounced.
    func testUndatedItemsKeepTheirFeedsOrder() throws {
        let librivox = try FeedParserTests.parse("librivox.xml")
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        guard let address = URL(string: "https://librivox.org/rss/52") else { return XCTFail("a constant address") }
        var serial = FeedRecord(feed: Feed(feedURL: address, folderID: UUID(), subscribedDate: now))
        var texts = FeedTextCache()

        let first = FeedReconciler.merge(librivox, into: &serial, keepEntries: 10, now: now, texts: &texts)

        XCTAssertEqual(serial.items.map(\.title), (48...57).reversed().map { "Letter \($0)" })
        XCTAssertEqual(first.newItemIDs, [])
        XCTAssertTrue(serial.feed.isSerial)

        var episodicFeed = librivox
        episodicFeed.isSerial = false
        var episodic = FeedRecord(feed: Feed(feedURL: address, folderID: UUID(), subscribedDate: now))
        FeedReconciler.merge(episodicFeed, into: &episodic, keepEntries: 3, now: now, texts: &texts)
        XCTAssertEqual(episodic.items.map(\.title), ["Letter 1", "Letter 2", "Letter 3"])

        // A later reading that adds a chapter at the end announces it.
        var later = librivox
        let lastItem = try XCTUnwrap(later.items.last)
        var added = lastItem
        added.title = "Letter 58"
        added.position = lastItem.position + 1
        let addedAddress = try XCTUnwrap(URL(string: "https://www.archive.org/download/letters_58.mp3"))
        added.enclosure = FeedEnclosure(url: addedAddress, mimeType: "audio/mpeg", length: nil)
        later.items.append(added)
        let second = FeedReconciler.merge(later, into: &serial, keepEntries: 10, now: now.addingTimeInterval(60), texts: &texts)
        XCTAssertEqual(second.newItemIDs, ["enclosure:https://www.archive.org/download/letters_58.mp3"])
        XCTAssertEqual(serial.items.map(\.title), (49...58).reversed().map { "Letter \($0)" })

        // Keeping more entries brings older chapters back, in the feed's
        // order, and announces none of them.
        let third = FeedReconciler.merge(later, into: &serial, keepEntries: 12, now: now.addingTimeInterval(120), texts: &texts)
        XCTAssertEqual(third.newItemIDs, [])
        XCTAssertEqual(third.addedItemIDs.count, 2)
        XCTAssertEqual(serial.items.map(\.title), (47...58).reversed().map { "Letter \($0)" })
    }

    /// Items of one date sort by the feed's order, an item the feed still
    /// lists ahead of one it dropped, then by episode number, then by
    /// identity: one consistent order, whatever order they come in.
    func testItemsOfOneDateSortConsistently() {
        let date = Date(timeIntervalSince1970: 1_791_000_000)
        func item(_ id: String, number: Int? = nil) -> FeedItem {
            FeedItem(id: id, title: id, firstSeen: date, episodeNumber: number)
        }
        let items = [item("gone-b"), item("listed-2"), item("gone-a", number: 3), item("listed-1"), item("gone-c", number: 7)]
        let positions = ["listed-1": 0, "listed-2": 1]

        for isSerial in [false, true] {
            let orders = Set([items, items.reversed(), items.shuffled()].map { candidates in
                FeedReconciler.kept(candidates, keepEntries: -1, positions: positions, isSerial: isSerial).map(\.id)
            })
            let listed = isSerial ? ["listed-2", "listed-1"] : ["listed-1", "listed-2"]
            XCTAssertEqual(orders, [listed + ["gone-c", "gone-a", "gone-b"]], "serial: \(isSerial)")
        }
    }

    /// Texts are read only for the items kept, and once: a merge into the
    /// record as it is later reads every text from the cache.
    func testTextsAreReadOnceForTheItemsKept() throws {
        let npr = try FeedParserTests.parse("npr-episodic.xml")
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        guard let address = URL(string: "https://radio.example/feed.xml") else { return XCTFail("a constant address") }
        var record = FeedRecord(feed: Feed(feedURL: address, folderID: UUID(), subscribedDate: now))
        var texts = FeedTextCache()

        FeedReconciler.merge(npr, into: &record, keepEntries: 1, now: now, texts: &texts)

        XCTAssertEqual(record.items.count, 1)
        let kept = try XCTUnwrap(record.items.first)
        XCTAssertTrue(kept.summary?.plainText.hasPrefix("A coin mechanism") ?? false)
        XCTAssertTrue(kept.summary?.markdown.contains("[*Ledger Notes*](https://news.radio.example/ledger)") ?? false
            || kept.summary?.markdown.contains("Ledger Notes") ?? false)
        XCTAssertNil(kept.content, "content repeating the summary was kept")
        XCTAssertNotNil(record.feed.summary)
    }

    // MARK: - Failures

    /// A refresh of every feed refreshes each, records a failure for its
    /// feed alone, and summarizes them all.
    func testAFailureIsRecordedForItsFeedAlone() async throws {
        let world = try FeedTestWorld(self, label: "FeedFailureAlone")
        world.server.serve("/good.xml", .feed(FeedXML.rss(title: "Good Show", items: [FeedXML.Item(guid: "g", title: "G")])))
        world.server.serve("/bad.xml", .feed(FeedXML.rss(title: "Bad Show", items: [FeedXML.Item(guid: "b", title: "B")])), StubResponse(status: 404))
        let good = try await world.subscribe("/good.xml")
        let bad = try await world.subscribe("/bad.xml")

        let summary = await world.center.refreshAll()

        XCTAssertEqual(summary.reports.map(\.feedTitle), ["Bad Show", "Good Show"])
        XCTAssertEqual(summary.failedFeedTitles, ["Bad Show"])
        XCTAssertEqual(world.center.fetchState(of: bad.id).lastError?.message, "There's no feed at that address any more.")
        XCTAssertNil(world.center.fetchState(of: good.id).lastError)
        XCTAssertNotNil(world.center.store.record(of: bad.id), "a failure removed nothing")
        XCTAssertFalse(debugLogLines(containing: "FEED_REFRESH_FAILED: Bad Show (\(world.server.host))").isEmpty)
    }

    /// Each kind of failure is worded for the listener, naming the server
    /// by its host and never by its whole address.
    func testEachFailureIsWorded() async throws {
        let world = try FeedTestWorld(self, label: "FeedFailureWords")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [FeedXML.Item(guid: "a", title: "A")])))
        let feed = try await world.subscribe("/feed.xml")
        let host = world.server.host
        let cases: [(StubResponse, String)] = [
            (StubResponse(status: 401), "This feed needs a password, which TextMouth can't send yet."),
            (StubResponse(status: 403), "This feed needs a password, which TextMouth can't send yet."),
            (StubResponse(status: 503), "\(host) couldn't send the feed (error 503). Try again later."),
            (.failing(.cannotFindHost), "The server \(host) couldn't be found. Check the address."),
            (.failing(.timedOut), "\(host) didn't answer for 30 seconds."),
            (StubResponse(headers: ["Content-Length": "\(FeedParser.maximumBytes + 1)"], body: Data("x".utf8)),
             "The feed at \(host) is larger than the 25 MB TextMouth reads."),
            (StubResponse(body: Data()), "The feed at \(host) is empty."),
            (StubResponse(status: 410), "The publisher has removed this feed."),
        ]
        for (response, message) in cases {
            world.server.serve("/feed.xml", response)
            let report = await world.center.refresh(feed.id)
            XCTAssertEqual(report?.failure, message)
            XCTAssertEqual(world.center.fetchState(of: feed.id).lastError?.message, message)
            XCTAssertFalse(message.contains("/feed.xml"), "a message named the whole address")
        }
        XCTAssertTrue(world.center.fetchState(of: feed.id).isGone)
    }

    /// A feed the publisher removed is skipped by the refreshes TextMouth
    /// makes by itself, and tried again only when the listener asks.
    func testAGoneFeedWaitsForTheListener() async throws {
        let world = try FeedTestWorld(self, label: "FeedGone")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [FeedXML.Item(guid: "a", title: "A")])), StubResponse(status: 410))
        let feed = try await world.subscribe("/feed.xml")
        _ = await world.center.refresh(feed.id)
        XCTAssertTrue(world.center.fetchState(of: feed.id).isGone)
        let asked = world.server.requests.count

        let scheduled = await world.center.refreshAll(origin: .scheduled)
        XCTAssertEqual(scheduled.reports.map(\.outcome), [.skipped])
        XCTAssertEqual(world.server.requests.count, asked)

        _ = await world.center.refresh(feed.id)
        XCTAssertEqual(world.server.requests.count, asked + 1)
    }

    /// Offline, a refresh the listener asks for fails at once, saying so,
    /// without a request; one TextMouth makes by itself waits for its next
    /// turn, recording nothing.
    func testOfflineRefreshes() async throws {
        let world = try FeedTestWorld(self, label: "FeedOffline")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(title: "Night Shift", items: [FeedXML.Item(guid: "a", title: "A")])))
        let feed = try await world.subscribe("/feed.xml")
        world.online.value = false
        let asked = world.server.requests.count

        let scheduled = await world.center.refreshAll(origin: .scheduled)
        XCTAssertEqual(scheduled.reports.map(\.outcome), [.skipped])
        XCTAssertNil(world.center.fetchState(of: feed.id).lastError)

        let report = await world.center.refresh(feed.id)
        XCTAssertEqual(
            report?.failure,
            "This Mac is offline, so Night Shift can't be refreshed. Connect to the internet and try again."
        )
        XCTAssertEqual(world.server.requests.count, asked)
    }

    /// A refresh TextMouth makes by itself never uses an expensive or
    /// constrained network; the listener's may.
    func testOnlyTheListenersRefreshesUseExpensiveNetworks() async throws {
        let world = try FeedTestWorld(self, label: "FeedDiscretionary")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [FeedXML.Item(guid: "a", title: "A")])))
        let feed = try await world.subscribe("/feed.xml")

        _ = await world.center.refreshAll(origin: .scheduled)
        _ = await world.center.refresh(feed.id)

        let requests = world.server.requests(to: "/feed.xml")
        XCTAssertEqual(requests.map(\.allowsExpensiveNetworkAccess), [true, false, true])
        XCTAssertEqual(requests.map(\.allowsConstrainedNetworkAccess), [true, false, true])
    }

    // MARK: - Moved Feeds

    /// A feed that moved for good, by a permanent redirect or by naming its
    /// new address, is fetched from there from then on; a temporary
    /// redirect moves nothing.
    func testAFeedThatMovedForGoodIsFollowed() async throws {
        let world = try FeedTestWorld(self, label: "FeedMoved")
        let markup = FeedXML.rss(items: [FeedXML.Item(guid: "a", title: "A")])
        world.server.serve("/old.xml", .feed(markup), .redirect(301, to: world.server.url("/new.xml")))
        world.server.serve("/new.xml", .feed(markup), .redirect(302, to: world.server.url("/elsewhere.xml")))
        world.server.serve("/elsewhere.xml", .feed(FeedXML.rss(items: [FeedXML.Item(guid: "a", title: "A")], newFeedURL: world.server.url("/final.xml"))))
        let feed = try await world.subscribe("/old.xml")

        _ = await world.center.refresh(feed.id)
        XCTAssertEqual(world.center.store.record(of: feed.id)?.feed.feedURL, world.server.url("/new.xml"))

        _ = await world.center.refresh(feed.id)
        XCTAssertEqual(world.center.store.record(of: feed.id)?.feed.feedURL, world.server.url("/final.xml"))
        XCTAssertEqual(debugLogLines(containing: "FEED_MOVED: The Tactile Atlas: from \(world.server.host)").count, 2)
    }

    /// A feed that moved for good is followed even when its new address
    /// answers that nothing changed.
    func testAMovedFeedIsFollowedWhenItsNewAddressAnswers304() async throws {
        let world = try FeedTestWorld(self, label: "FeedMoved304")
        let markup = FeedXML.rss(items: [FeedXML.Item(guid: "a", title: "A", published: world.day(-1))])
        world.server.serve("/old.xml", .feed(markup, headers: ["ETag": "\"v1\""]), .redirect(308, to: world.server.url("/new.xml")))
        world.server.serve("/new.xml", StubResponse(status: 304))
        let feed = try await world.subscribe("/old.xml")

        let report = try await unwrap(world.center.refresh(feed.id))

        XCTAssertEqual(report.outcome, .unchanged)
        XCTAssertEqual(world.center.store.record(of: feed.id)?.feed.feedURL, world.server.url("/new.xml"))
    }

    // MARK: - Overlapping Refreshes

    /// Two refreshes of one feed asked for at once make one request, and
    /// both report how it ended; the feed counts as refreshing meanwhile.
    func testOverlappingRefreshesMakeOneRequest() async throws {
        let world = try FeedTestWorld(self, label: "FeedOverlap")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [FeedXML.Item(guid: "a", title: "A")])))
        let feed = try await world.subscribe("/feed.xml")
        var slow = StubResponse.feed(FeedXML.rss(title: "Slow", items: [FeedXML.Item(guid: "a", title: "A")]))
        slow.pause = 0.2
        world.server.serve("/feed.xml", slow)
        let asked = world.server.requests.count

        async let first = world.center.refresh(feed.id)
        async let second = world.center.refresh(feed.id)
        await waitFor("the feed is refreshing") { world.center.refreshingFeedIDs.contains(feed.id) }
        let reports = await [first, second]

        XCTAssertEqual(reports[0], reports[1])
        XCTAssertEqual(world.server.requests.count, asked + 1)
        XCTAssertEqual(world.center.refreshingFeedIDs, [])
    }

    /// A refresh that ends after its feed was unsubscribed changes nothing:
    /// it reports nothing, and makes no fetch details again.
    func testARefreshEndingAfterItsFeedWentChangesNothing() async throws {
        let world = try FeedTestWorld(self, label: "FeedGoneMidRefresh")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [FeedXML.Item(guid: "a", title: "A")])))
        let feed = try await world.subscribe("/feed.xml")
        var slow = StubResponse.feed(FeedXML.rss(title: "Slow", items: [FeedXML.Item(guid: "b", title: "B")]))
        slow.pause = 0.3
        world.server.serve("/feed.xml", slow)

        async let ending = world.center.refresh(feed.id)
        await waitFor("the feed is refreshing") { world.center.refreshingFeedIDs.contains(feed.id) }
        world.center.unsubscribe(feed.id)
        let report = await ending

        XCTAssertNil(report)
        XCTAssertNil(world.center.store.record(of: feed.id))
        XCTAssertNil(world.center.fetchStates.states[feed.id])
        await world.center.fetchStates.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: FeedPaths.recordFile(of: feed.id, in: world.fetchStateFolder).path))
    }

    // MARK: - A Damaged Feed

    /// A feed read through the tidy fallback is merged like any other, and
    /// the repair is logged with the feed's host.
    func testARepairedFeedIsReadAndLogged() async throws {
        let world = try FeedTestWorld(self, label: "FeedRepaired")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [])), try .fixture("fault-bare-ampersand.xml"))
        let feed = try await world.subscribe("/feed.xml")

        _ = await world.center.refresh(feed.id)

        XCTAssertTrue(world.center.listedItems(of: feed.id).map(\.title).contains("Q&A night"))
        XCTAssertFalse(debugLogLines(containing: "FEED_PARSE_REPAIRED: Fault Lines (\(world.server.host))").isEmpty)
    }

    // MARK: - JSON Feed

    /// A JSON Feed is subscribed to and refreshed through the same merge as
    /// an RSS feed: its items are kept newest first, by their ids; a refresh
    /// that lists a new item announces it; and what the listener did with
    /// an item stays.
    func testAJSONFeedMergesAsAnRSSFeedDoes() async throws {
        let world = try FeedTestWorld(self, label: "FeedJSONFeed")
        let old = (1...2).map { number in
            FeedXML.Item(guid: "ep-\(number)", title: "Episode \(number)", published: world.day(-Double(number)),
                         enclosure: "https://atlas.example/audio/\(number).mp3")
        }
        let new = FeedXML.Item(guid: "ep-new", title: "A new episode", published: world.day(0.5),
                               enclosure: "https://atlas.example/audio/new.mp3")
        world.server.serve("/feed.json", try .jsonFeed(items: old), try .jsonFeed(items: [new] + old))
        let feed = try await world.subscribe("/feed.json")
        XCTAssertEqual(feed.title, "The Tactile Atlas")
        XCTAssertEqual(feed.siteLink?.absoluteString, "https://show.example/")
        XCTAssertEqual(world.center.listedItems(of: feed.id).map(\.id), ["guid:ep-1", "guid:ep-2"])
        XCTAssertTrue(world.center.listedItems(of: feed.id).allSatisfy { $0.state == .notDownloaded && !$0.isArticle })
        let played = world.day(-0.5)
        world.center.store.updateItem("guid:ep-1", of: feed.id) { $0.playedDate = played }
        world.advance(by: 86_400)

        let report = try await unwrap(world.center.refresh(feed.id))

        XCTAssertEqual(report.outcome, .updated(newItemIDs: ["guid:ep-new"]))
        let record = try XCTUnwrap(world.center.store.record(of: feed.id))
        XCTAssertEqual(record.items.map(\.title), ["A new episode", "Episode 1", "Episode 2"])
        XCTAssertEqual(record.item("guid:ep-1")?.playedDate, played)
        XCTAssertEqual(record.item("guid:ep-new")?.enclosure?.url.absoluteString, "https://atlas.example/audio/new.mp3")
        XCTAssertEqual(record.feed.newestItemDate, world.day(0.5))
    }

    // MARK: - Launch and the Schedule

    /// At launch the engine starts at once and refreshes in the background:
    /// `start` returns before the records are even read, so the library is
    /// never held back, and the refresh follows.
    func testALaunchRefreshesWithoutHoldingTheLibraryBack() async throws {
        let world = try FeedTestWorld(self, label: "FeedLaunch", worksOnItsOwn: true)
        let feed = try savedSubscription(in: world, at: "/feed.xml")
        var slow = StubResponse.feed(FeedXML.rss(items: [FeedXML.Item(guid: "ep-1", title: "Episode 1")]))
        slow.pause = 0.3
        world.server.serve("/feed.xml", slow)

        let started = Date()
        let startup = world.center.start(library: world.library)
        let startTook = Date().timeIntervalSince(started)

        XCTAssertLessThan(startTook, 0.1, "starting the engine held the main actor")
        XCTAssertFalse(world.center.store.hasLoaded, "the records were read before start returned")
        await startup?.value
        XCTAssertTrue(world.center.store.hasLoaded)
        XCTAssertEqual(world.server.requests(to: "/feed.xml").count, 1)
        XCTAssertEqual(world.center.fetchState(of: feed.id).lastSuccess, world.clock.value)
        XCTAssertNil(world.center.start(library: world.library), "the engine started twice")
    }

    /// With the launch refresh turned off, starting reads the records and
    /// fetches nothing.
    func testTheLaunchRefreshCanBeTurnedOff() async throws {
        let world = try FeedTestWorld(self, label: "FeedNoLaunch", worksOnItsOwn: true)
        FeedSettings.refreshAtLaunchPreference.write(false, to: world.preferences)
        let feed = try savedSubscription(in: world, at: "/feed.xml")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [FeedXML.Item(guid: "a", title: "A")])))

        await world.start()

        XCTAssertNotNil(world.center.store.record(of: feed.id))
        XCTAssertEqual(world.server.requests, [])
    }

    /// While TextMouth runs, every feed refreshes on the interval setting;
    /// changing the setting reschedules at once, 0 stops the schedule, and
    /// Low Power Mode puts a turn off.
    func testScheduledRefreshesFollowTheIntervalSetting() async throws {
        let world = try FeedTestWorld(self, label: "FeedSchedule", worksOnItsOwn: true)
        FeedSettings.refreshAtLaunchPreference.write(false, to: world.preferences)
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [FeedXML.Item(guid: "a", title: "A")])))
        await world.start()
        _ = try await world.subscribe("/feed.xml")
        await waitFor("the first scheduled wait") { world.sleep.requestedWaits.count == 1 }
        XCTAssertEqual(world.sleep.requestedWaits, [.seconds(3_600)])
        let asked = world.server.requests.count

        world.sleep.wakeOldest()
        await waitFor("a scheduled refresh and the next wait") { world.sleep.requestedWaits.count == 2 }
        XCTAssertEqual(world.server.requests.count, asked + 1)
        XCTAssertFalse(world.server.requests.last?.allowsExpensiveNetworkAccess ?? true)

        FeedSettings.refreshIntervalHoursPreference.write(2, to: world.preferences)
        await waitFor("the rescheduled wait") { world.sleep.requestedWaits.count == 3 }
        XCTAssertEqual(world.sleep.requestedWaits.last, .seconds(7_200))

        world.lowPowerMode.value = true
        world.sleep.wakeOldest()
        await waitFor("the next wait after a turn put off") { world.sleep.requestedWaits.count == 4 }
        XCTAssertEqual(world.server.requests.count, asked + 1, "a refresh ran in Low Power Mode")

        FeedSettings.refreshIntervalHoursPreference.write(0, to: world.preferences)
        await waitFor("the scheduled refreshes stop") { !world.center.refreshesOnSchedule }
        world.sleep.wakeOldest()
        XCTAssertEqual(world.sleep.requestedWaits.count, 4, "a refresh was scheduled with the interval at 0")
    }

    // MARK: - The App's Own Engine

    /// In a process hosting tests, the app's engine has started with the
    /// library but never works on its own, and the app's network refuses
    /// every request, so no test reaches the network.
    func testTheAppsEngineNeverReachesTheNetworkInTests() async throws {
        XCTAssertTrue(FeedCenter.shared.hasStarted)
        XCTAssertNotNil(FeedCenter.shared.library)
        XCTAssertFalse(FeedCenter.shared.environment.worksOnItsOwn)
        let address = try XCTUnwrap(URL(string: "https://feeds.example/feed.xml"))
        do {
            _ = try await FeedNetwork.app.fetch(address, discretionary: false)
            XCTFail("the app's network answered a request in a test")
        } catch {
            XCTAssertEqual(error as? FeedFetchError, .offline)
        }
        XCTAssertTrue(FeedCenter.shared.environment.fetchStateFolder?.path.hasPrefix(MachineLocalPaths.feedCaches.path) ?? false)
    }

    // MARK: - Helpers

    /// A subscription to the feed at `path` on `world`'s server saved in its
    /// records folder, as an earlier launch left it.
    private func savedSubscription(in world: FeedTestWorld, at path: String) throws -> Feed {
        let record = FeedRecordTests.record(itemCount: 1, folderID: world.bookFolder.id)
        var feed = record.feed
        feed.feedURL = world.server.url(path)
        try FileManager.default.createDirectory(at: world.recordsFolder, withIntermediateDirectories: true)
        try FeedRecordCoding.encoder().encode(FeedRecord(feed: feed, items: record.items))
            .write(to: FeedPaths.recordFile(of: feed.id, in: world.recordsFolder))
        return feed
    }

    /// Asserts that subscribing `world`'s engine to `address` in `folderID`
    /// (the world's folder by default) throws `expected`.
    private func assertSubscribing(
        _ world: FeedTestWorld,
        to address: String,
        folderID: UUID? = nil,
        throws expected: FeedSubscribeError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let outcome = try await world.center.subscribe(to: address, folderID: folderID ?? world.bookFolder.id)
            XCTFail("subscribing to \(address) ended with \(outcome)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? FeedSubscribeError, expected, file: file, line: line)
        }
    }
}

/// `value` unwrapped, or a failure naming where: `XCTUnwrap` for a value
/// an `await` produces, which its autoclosure cannot hold.
func unwrap<Value>(_ value: Value?, file: StaticString = #filePath, line: UInt = #line) throws -> Value {
    try XCTUnwrap(value, file: file, line: line)
}
