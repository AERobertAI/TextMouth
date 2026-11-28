import XCTest
@testable import TextMouth

/// The feed engine's and the library's half of syncing feeds (FR56, phase 1):
/// the host gives no feeds until its records load, a feed another device
/// subscribed to gets a record here, a synced setting goes through the
/// engine's commands, a feed deleted elsewhere is deleted here, and the keys
/// of a feed whose change did not land are not reported applied. On a feed
/// test world: stub network, sandboxed folders, no iCloud.
@MainActor
final class SyncFeedHostTests: XCTestCase {
    /// A feed of `address` in the world's folder, subscribed a day before the world's clock.
    private func feed(in world: FeedTestWorld, address: String = "https://sync.example/show.xml") throws -> Feed {
        Feed(
            feedURL: try XCTUnwrap(URL(string: address)), folderID: world.bookFolder.id,
            subscribedDate: world.clock.value.addingTimeInterval(-86_400)
        )
    }

    /// The host gives no feeds until the engine's records have loaded, then every feed.
    func testNoFeedsUntilTheRecordsLoad() async throws {
        let world = try FeedTestWorld(self, label: "SyncFeedHostLoad")
        XCTAssertNil(world.library.syncFeeds)
        await world.start()
        XCTAssertEqual(world.library.syncFeeds, [])
        let show = try feed(in: world)
        world.center.store.add(FeedRecord(feed: show))
        XCTAssertEqual(world.library.syncFeeds?.map(\.id), [show.id])
    }

    /// A feed another device subscribed to gets a record here, its episodes out before it arrived not new.
    func testNewFeedGetsARecord() async throws {
        let world = try FeedTestWorld(self, label: "SyncFeedHostAdd")
        await world.start()
        var show = try feed(in: world)
        show.itemPolicyOverride = FeedItemPolicy(choice: .onlyNewestListed, newestCount: 2)
        let failed = await world.center.applySync(SyncFeedApplication(feedsToAdd: [show]))
        XCTAssertEqual(failed, [])
        let record = try XCTUnwrap(world.center.store.record(of: show.id))
        XCTAssertEqual(record.feed.feedURL, show.feedURL)
        XCTAssertEqual(record.feed.itemPolicyOverride, show.itemPolicyOverride)
        XCTAssertEqual(record.feed.newestItemDate, world.clock.value)
        XCTAssertEqual(world.center.feed(inFolder: world.bookFolder.id)?.id, show.id)
    }

    /// A subscribed feed another device added is checked at once by an engine that works on its
    /// own, so its folder lists its episodes without waiting for the next scheduled check.
    func testNewFeedIsCheckedAtOnce() async throws {
        let world = try FeedTestWorld(self, label: "SyncFeedHostCheck", worksOnItsOwn: true)
        FeedSettings.refreshAtLaunchPreference.write(false, to: world.preferences)
        FeedSettings.refreshIntervalHoursPreference.write(0, to: world.preferences)
        world.server.serve("/synced.xml", .feed(FeedXML.rss(items: [FeedXML.Item(guid: "ep-1", title: "The first visit")])))
        await world.start()
        let show = Feed(
            feedURL: world.server.url("/synced.xml"), folderID: world.bookFolder.id,
            subscribedDate: world.clock.value.addingTimeInterval(-86_400)
        )
        let failed = await world.center.applySync(SyncFeedApplication(feedsToAdd: [show]))
        XCTAssertEqual(failed, [])
        await waitFor("the feed another device added is checked") {
            world.center.store.record(of: show.id)?.item("guid:ep-1") != nil
        }
    }

    /// A synced change of a feed's settings and its subscription lands through the engine.
    func testChangedSettingsLand() async throws {
        let world = try FeedTestWorld(self, label: "SyncFeedHostChange")
        await world.start()
        let show = try feed(in: world)
        world.center.store.add(FeedRecord(feed: show))
        var theirs = show
        theirs.deleteDownloadsDaysAfterPlayedOverride = 5
        theirs.listeningOptions = ListeningOptions(skipsFinished: false)
        theirs.itemPolicyOverride = FeedItemPolicy(choice: .everyListedDownloadsByHand, newestCount: 4)
        theirs.unsubscribedDate = Date(timeIntervalSince1970: 1_790_000_000)
        let failed = await world.center.applySync(SyncFeedApplication(feedsToChange: [theirs]))
        XCTAssertEqual(failed, [])
        let changed = try XCTUnwrap(world.center.store.record(of: show.id)?.feed)
        XCTAssertEqual(changed.deleteDownloadsDaysAfterPlayedOverride, 5)
        XCTAssertEqual(changed.listeningOptions, theirs.listeningOptions)
        XCTAssertEqual(changed.itemPolicyOverride, theirs.itemPolicyOverride)
        // The other device's date, so every device holds one value.
        XCTAssertEqual(changed.unsubscribedDate, theirs.unsubscribedDate)
        XCTAssertFalse(changed.isSubscribed)

        // Subscribed again elsewhere: subscribed here at once.
        theirs.unsubscribedDate = nil
        _ = await world.center.applySync(SyncFeedApplication(feedsToChange: [theirs]))
        XCTAssertEqual(world.center.store.record(of: show.id)?.feed.isSubscribed, true)
    }

    /// A setting a person changed here after the merge was made keeps their value, as a book's
    /// field does; the merge's other fields land, and the feed's keys are offered again.
    func testAPersonsChangeSinceTheMergeStands() async throws {
        let world = try FeedTestWorld(self, label: "SyncFeedHostStale")
        await world.start()
        let show = try feed(in: world)
        world.center.store.add(FeedRecord(feed: show))
        let persons = ListeningOptions(predownloadsNext: false)
        world.center.setListeningOptions(persons, of: show.id)
        var theirs = show
        theirs.listeningOptions = ListeningOptions(skipsFinished: false)
        theirs.deleteDownloadsDaysAfterPlayedOverride = 5
        let failed = await world.center.applySync(SyncFeedApplication(feedsToChange: [theirs], startFeeds: [show.id: show]))
        XCTAssertEqual(failed, [show.id])
        let now = try XCTUnwrap(world.center.store.record(of: show.id)?.feed)
        XCTAssertEqual(now.listeningOptions, persons)
        XCTAssertEqual(now.deleteDownloadsDaysAfterPlayedOverride, 5)
    }

    /// A feed a person changed here after the merge was made is not deleted by it: their change
    /// may bring it back on every device.
    func testFeedChangedSinceTheMergeIsNotDeleted() async throws {
        let world = try FeedTestWorld(self, label: "SyncFeedHostStaleRemove")
        await world.start()
        let show = try feed(in: world)
        world.center.store.add(FeedRecord(feed: show))
        world.center.setDeleteDownloadsDaysAfterPlayed(3, of: show.id)
        let failed = await world.center.applySync(SyncFeedApplication(feedsToRemove: [show.id], startFeeds: [show.id: show]))
        XCTAssertEqual(failed, [show.id])
        XCTAssertNotNil(world.center.store.record(of: show.id))
    }

    /// A feed another device subscribed to, of an address subscribed here since the merge was
    /// made, is not added as a second feed of one show.
    func testFeedSubscribedHereMeanwhileIsNotAddedTwice() async throws {
        let world = try FeedTestWorld(self, label: "SyncFeedHostSameAddress")
        await world.start()
        let mine = try feed(in: world)
        world.center.store.add(FeedRecord(feed: mine))
        let theirs = try feed(in: world, address: "http://sync.example/show.xml/")
        let failed = await world.center.applySync(SyncFeedApplication(feedsToAdd: [theirs]))
        XCTAssertEqual(failed, [theirs.id])
        XCTAssertNil(world.center.store.record(of: theirs.id))
    }

    /// A feed deleted on another device, with nothing downloaded, is deleted here.
    func testRemovedFeedIsDeleted() async throws {
        let world = try FeedTestWorld(self, label: "SyncFeedHostRemove")
        await world.start()
        let show = try feed(in: world)
        world.center.store.add(FeedRecord(feed: show))
        let failed = await world.center.applySync(SyncFeedApplication(feedsToRemove: [show.id]))
        XCTAssertEqual(failed, [])
        XCTAssertNil(world.center.store.record(of: show.id))
        // Its library folder, empty here, is the deleting device's to remove: it may hold a book
        // there that hasn't arrived yet, and the folder's own keys carry what it chose.
        XCTAssertEqual(world.library.library.folders.map(\.id), [world.bookFolder.id])
    }

    /// Before the records load nothing lands, and every feed named is reported not landed.
    func testNothingLandsBeforeTheRecordsLoad() async throws {
        let world = try FeedTestWorld(self, label: "SyncFeedHostEarly")
        let show = try feed(in: world)
        let failed = await world.center.applySync(SyncFeedApplication(feedsToAdd: [show]))
        XCTAssertEqual(failed, [show.id])
        XCTAssertNil(world.center.store.record(of: show.id))
    }

    /// A feed arriving with a new folder waits, its keys unapplied, when a person changed the
    /// folders meanwhile and the merge's folders were left out: it never lists in no folder.
    func testFeedWaitsForAFolderTheApplyLeftOut() async throws {
        let world = try FeedTestWorld(self, label: "SyncFeedHostStaleFolders")
        await world.start()
        let source = world.library.library
        let arriving = BookFolder(name: "Show")
        var merged = source
        merged.folders.append(arriving)
        // A person makes a folder of their own before the merge lands.
        world.library.library.folders.append(BookFolder(name: "Mine"))
        var show = try feed(in: world)
        show.folderID = arriving.id
        let application = SyncApplication(
            library: merged, booksToAdd: [], booksToRemove: [], movesPackages: true, entriesToRecord: [:],
            appliedKeys: [.feed(show.id, .presence), .folder(arriving.id, .presence)],
            feeds: SyncFeedApplication(feedsToAdd: [show])
        )
        let applied = await world.library.applySync(application, from: source)
        XCTAssertNil(world.center.store.record(of: show.id))
        XCTAssertFalse(applied.contains(.feed(show.id, .presence)))
        XCTAssertFalse(applied.contains(.folder(arriving.id, .presence)))
    }

    /// The library's apply carries out the feeds and reports their keys applied, but not a failed feed's.
    func testLibraryApplyReportsFeedKeys() async throws {
        let world = try FeedTestWorld(self, label: "SyncFeedHostLibrary")
        await world.start()
        let show = try feed(in: world)
        let gone = UUID()
        let keys: Set<SyncKey> = [.feed(show.id, .presence), .feed(gone, .presence)]
        let source = world.library.library
        var changed = try feed(in: world, address: "https://sync.example/changed.xml")
        changed = Feed(id: gone, feedURL: changed.feedURL, folderID: changed.folderID, subscribedDate: changed.subscribedDate)
        let application = SyncApplication(
            library: source, booksToAdd: [], booksToRemove: [], movesPackages: false, entriesToRecord: [:],
            appliedKeys: keys, feeds: SyncFeedApplication(feedsToAdd: [show], feedsToChange: [changed])
        )
        let applied = await world.library.applySync(application, from: source)
        // The new feed landed; the change to a feed this device lacks did not.
        XCTAssertNotNil(world.center.store.record(of: show.id))
        XCTAssertTrue(applied.contains(.feed(show.id, .presence)))
        XCTAssertFalse(applied.contains(.feed(gone, .presence)))
    }
}
