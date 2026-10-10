import XCTest
@testable import TextMouth

/// The newest-N rule of the "List and download" choice (FR11, branch B), and
/// what it needs: each download knowing who asked for it, so the rule
/// manages its own downloads alone. No test reaches the network: every
/// request goes to the world's stub server.
@MainActor
final class FeedNewestRuleTests: XCTestCase {

    // MARK: - Who Asked for a Download

    /// A download records who asked for it: the listener's as the listener's,
    /// over any network; the rule's as the rule's, as discretionary work; and
    /// the listener asking while the rule's download runs makes it the
    /// listener's. Opening an episode the rule downloaded leaves it the
    /// rule's: started and not finished, it may still go once older.
    func testADownloadRecordsWhoAskedForIt() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleOrigin")
        let audio = try FeedMediaFixtures.silentAAC()
        var slow = FeedMediaFixtures.file(audio, mimeType: "audio/mp4")
        slow.chunkSize = max(1, audio.count / 20)
        slow.pause = 0.05
        world.server.serve("/audio/1.m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        world.server.serve("/audio/2.m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        world.server.serve("/audio/3.m4a", slow)
        let feed = try await subscribe(world, episodes: 3)

        world.center.download("guid:ep-1", of: feed.id)
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        XCTAssertEqual(origin(of: "guid:ep-1", in: feed, world), .listener)
        XCTAssertEqual(world.server.requests(to: "/audio/1.m4a").map(\.allowsExpensiveNetworkAccess), [true])

        world.center.downloads.download("guid:ep-2", of: feed.id, origin: .window)
        let ruleBook = try await downloadedBook(world, feed: feed, item: "guid:ep-2")
        XCTAssertEqual(origin(of: "guid:ep-2", in: feed, world), .window)
        XCTAssertEqual(world.server.requests(to: "/audio/2.m4a").map(\.allowsExpensiveNetworkAccess), [false])
        var opened: [UUID] = []
        world.library.readerOpener = { opened.append($0) }
        world.center.open("guid:ep-2", of: feed.id)
        XCTAssertEqual(opened, [ruleBook.id])
        XCTAssertEqual(origin(of: "guid:ep-2", in: feed, world), .window, "opening a download made it the listener's")

        world.center.downloads.download("guid:ep-3", of: feed.id, origin: .window)
        await waitFor("the rule's download is under way") { !world.server.requests(to: "/audio/3.m4a").isEmpty }
        world.center.download("guid:ep-3", of: feed.id)
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-3")
        XCTAssertEqual(origin(of: "guid:ep-3", in: feed, world), .listener)
    }

    /// Deleting a download, or stopping one, leaves the item to the
    /// listener, so the rule never asks for it again by itself: Delete
    /// Download of a download the rule made, Cancel Download of one the rule
    /// queued, and of one under way.
    func testDeletingOrStoppingADownloadLeavesTheItemToTheListener() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleOriginDeclined")
        let audio = try FeedMediaFixtures.silentAAC()
        var slow = FeedMediaFixtures.file(audio, mimeType: "audio/mp4")
        slow.chunkSize = max(1, audio.count / 20)
        slow.pause = 0.1
        world.server.serve("/audio/1.m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        world.server.serve("/audio/2.m4a", slow)
        world.server.serve("/audio/3.m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        let feed = try await subscribe(world, episodes: 3)

        world.center.downloads.download("guid:ep-1", of: feed.id, origin: .window)
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        try world.center.deleteDownload("guid:ep-1", of: feed.id)
        let deleted = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))
        XCTAssertEqual(deleted.state, .notDownloaded)
        XCTAssertEqual(deleted.downloadDeletedDate, world.clock.value)
        XCTAssertEqual(deleted.downloadOrigin, .listener)

        world.center.downloads.download("guid:ep-2", of: feed.id, origin: .window)
        world.center.downloads.download("guid:ep-3", of: feed.id, origin: .window)
        await waitFor("the first download is under way") { !world.server.requests(to: "/audio/2.m4a").isEmpty }
        world.center.cancelDownload("guid:ep-3", of: feed.id)
        world.center.cancelDownload("guid:ep-2", of: feed.id)
        await waitFor("the download under way stops") { world.center.downloads.current == nil }

        for itemID in ["guid:ep-2", "guid:ep-3"] {
            let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item(itemID))
            XCTAssertEqual(item.state, .notDownloaded, itemID)
            XCTAssertEqual(item.downloadOrigin, .listener, itemID)
        }
        XCTAssertEqual(world.server.requests(to: "/audio/3.m4a"), [], "a stopped download was fetched")
    }

    /// A download the listener asked for that fails is the listener's, to
    /// try again by hand; one the rule asked for that fails is the rule's
    /// (REV11 F4), which a pass takes back once the item no longer counts.
    func testAFailedDownloadKeepsWhoAskedForIt() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleOriginFailed")
        world.server.serve("/audio/1.m4a", StubResponse(status: 404))
        world.server.serve("/audio/2.m4a", StubResponse(status: 404))
        let feed = try await subscribe(world, episodes: 2)

        world.center.download("guid:ep-1", of: feed.id)
        world.center.downloads.download("guid:ep-2", of: feed.id, origin: .window)
        await waitFor("both downloads fail") {
            let items = world.center.store.record(of: feed.id)?.items ?? []
            return items.allSatisfy { $0.state.failureReason != nil } && world.center.downloads.current == nil
        }

        let listeners = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))
        XCTAssertEqual(listeners.state, .failed("The server says the file is gone."))
        XCTAssertEqual(listeners.downloadOrigin, .listener)
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-2")?.downloadOrigin, .window)
    }

    // MARK: - Failures Nobody Asked For (REV11 F4)

    /// Offline, as at a first launch away from any network, the rule's
    /// downloads wait for a network rather than fail, saying so, fetching
    /// nothing, and never written as failures; the listener's own download
    /// fails, saying the Mac is offline. Online again, the next refresh
    /// TextMouth makes by itself tries the rule's again, and they download.
    func testOfflineTheRulesDownloadsWaitForANetwork() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleOffline")
        FeedSettings.newestCountPreference.write(2, to: world.preferences)
        let feed = try await subscribeServed(world, episodes: 3)
        world.online.value = false

        let report = await world.center.applyItemPolicy(to: [feed.id])
        world.center.download("guid:ep-3", of: feed.id)
        await waitFor("every download ends") {
            let items = world.center.store.record(of: feed.id)?.items ?? []
            return items.allSatisfy { !$0.state.isDownloading } && world.center.downloads.current == nil
        }

        XCTAssertEqual(report.requestedItemIDs, ["guid:ep-1", "guid:ep-2"])
        for itemID in ["guid:ep-1", "guid:ep-2"] {
            let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item(itemID))
            XCTAssertEqual(item.state, .waiting(FeedDownloadWait.network.reason), itemID)
            XCTAssertFalse(item.hasRulesFailedDownload, itemID)
        }
        XCTAssertEqual(world.center.downloads.putOff.map(\.itemID), ["guid:ep-1", "guid:ep-2"])
        XCTAssertEqual(
            world.center.store.record(of: feed.id)?.item("guid:ep-3")?.state,
            .failed("This Mac is offline, so “Episode 3” can't be downloaded. Connect to the internet and try again.")
        )
        XCTAssertEqual(world.server.requests(to: "/audio/1.m4a"), [], "an offline download reached the server")

        world.online.value = true
        _ = await world.center.refreshAll(origin: .scheduled)
        _ = try await downloadedBooks(world, feed: feed, items: ["guid:ep-1", "guid:ep-2"])
        XCTAssertTrue(world.center.downloads.putOff.isEmpty)
    }

    /// The rule's failed download is the rule's, and a pass that no longer
    /// counts its item, as when the number shrinks, takes the failure back:
    /// the item is not downloaded, so no row keeps "Download Failed" for a
    /// download nobody asked for. A failure the rule still counts stays,
    /// tried again after a refresh, and the listener's own failure stays
    /// whatever the rule counts.
    func testTheRulesFailureIsTakenBackOnceItsItemNoLongerCounts() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleFailureTakenBack")
        FeedSettings.newestCountPreference.write(2, to: world.preferences)
        for number in 1...3 {
            world.server.serve("/audio/\(number).m4a", StubResponse(status: 404))
        }
        let feed = try await subscribe(world, episodes: 3)

        _ = await world.center.applyItemPolicy(to: [feed.id])
        world.center.download("guid:ep-3", of: feed.id)
        await waitFor("every download fails") {
            let items = world.center.store.record(of: feed.id)?.items ?? []
            return items.allSatisfy { $0.state.failureReason != nil } && world.center.downloads.current == nil
        }
        XCTAssertEqual(origin(of: "guid:ep-2", in: feed, world), .window)

        FeedSettings.newestCountPreference.write(1, to: world.preferences)
        let report = await world.center.applyItemPolicy(to: [feed.id])

        XCTAssertEqual(report.withdrawnItemIDs, ["guid:ep-2"])
        let record = try XCTUnwrap(world.center.store.record(of: feed.id))
        XCTAssertEqual(record.item("guid:ep-2")?.state, .notDownloaded)
        XCTAssertEqual(record.item("guid:ep-2")?.downloadOrigin, .window, "the item stopped being the rule's")
        XCTAssertNotNil(record.item("guid:ep-1")?.state.failureReason, "a failure the rule still counts went")
        XCTAssertNotNil(record.item("guid:ep-3")?.state.failureReason, "the listener's failure went")
        XCTAssertEqual(record.item("guid:ep-3")?.downloadOrigin, .listener)
    }

    /// Who asked is read without ever making a record unreadable: a name
    /// this version does not know, or a value that is no name, reads as the
    /// listener's, whose downloads the rule leaves alone, and none as no one
    /// asked; it is written only when someone did. The list of downloads at
    /// quit that a version before FR11 wrote names a download that started
    /// by itself "automatic", which reads as the rule's.
    func testWhoAskedIsReadWithoutFail() throws {
        let cases: [(json: String, expected: FeedDownloadOrigin?)] = [
            (#""window""#, .window),
            (#""listener""#, .listener),
            (#""someoneLater""#, .listener),
            ("5", .listener),
            ("null", nil),
        ]
        for (json, expected) in cases {
            let item = #"{"id": "guid:a", "title": "A", "firstSeen": "2026-10-03T00:00:00Z", "state": {"kind": "notDownloaded"}, "downloadOrigin": \#(json)}"#
            let read = try FeedRecordCoding.decoder().decode(FeedItem.self, from: Data(item.utf8))
            XCTAssertEqual(read.downloadOrigin, expected, json)
        }
        let none = #"{"id": "guid:a", "title": "A", "firstSeen": "2026-10-03T00:00:00Z", "state": {"kind": "notDownloaded"}}"#
        let unasked = try FeedRecordCoding.decoder().decode(FeedItem.self, from: Data(none.utf8))
        XCTAssertNil(unasked.downloadOrigin)
        XCTAssertFalse(String(decoding: try FeedRecordCoding.encoder().encode(unasked), as: UTF8.self).contains("downloadOrigin"))
        var asked = unasked
        asked.downloadOrigin = .window
        XCTAssertTrue(String(decoding: try FeedRecordCoding.encoder().encode(asked), as: UTF8.self).contains(#""downloadOrigin" : "window""#))

        let feedID = UUID()
        let list = #"[{"feedID": "\#(feedID.uuidString)", "itemID": "guid:a", "origin": "automatic"}, {"feedID": "\#(feedID.uuidString)", "itemID": "guid:b", "origin": "listener"}]"#
        let saved = try JSONDecoder().decode([FeedDownloadManager.SavedDownload].self, from: Data(list.utf8))
        XCTAssertEqual(saved.map(\.origin), [.window, .listener])
    }

    // MARK: - Waiting to Download

    /// Without room for a file beside the space TextMouth keeps free, the
    /// rule's download waits, saying it needs room, fetching nothing and
    /// never put off for a network; the listener's fails, saying there
    /// isn't room. Cancel Download ends the wait, and with room again the
    /// rule's download goes ahead.
    func testADownloadWithoutRoomWaitsWhileTheListenersFails() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleRoom")
        let audio = try FeedMediaFixtures.silentAAC()
        world.server.serve("/audio/1.m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        world.server.serve("/audio/2.m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        let feed = try await subscribe(world, episodes: 2)
        // Room for 500 bytes beside the reserve; each episode says 1,000.
        world.freeSpace.value = ArchiveLimits.standard.freeSpaceReserve + 500

        world.center.downloads.download("guid:ep-1", of: feed.id, origin: .window)
        world.center.download("guid:ep-2", of: feed.id)
        await waitFor("both downloads end") {
            let record = world.center.store.record(of: feed.id)
            return record?.item("guid:ep-1")?.state.waitingReason != nil
                && record?.item("guid:ep-2")?.state.failureReason != nil
                && world.center.downloads.current == nil
        }

        let rules = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state)
        XCTAssertEqual(rules, .waiting("it needs room for 1 KB on this Mac"))
        XCTAssertEqual(rules.visibleNote, "Waiting to Download")
        XCTAssertFalse(world.center.downloads.isPutOff("guid:ep-1", of: feed.id), "a wait for room waits for a network")
        XCTAssertEqual(
            world.center.store.record(of: feed.id)?.item("guid:ep-2")?.state,
            .failed("There isn't room on this Mac for this episode (1 KB).")
        )
        XCTAssertEqual(world.server.requests(to: "/audio/1.m4a"), [], "a file was fetched without room for it")

        world.center.cancelDownload("guid:ep-1", of: feed.id)
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state, .notDownloaded)

        world.freeSpace.value = 100_000_000_000
        world.center.downloads.download("guid:ep-1", of: feed.id, origin: .window)
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        XCTAssertEqual(origin(of: "guid:ep-1", in: feed, world), .window)
    }

    /// A wait, like a download under way, ends with the app: the record's
    /// file holds the item as not downloaded.
    func testAWaitIsNeverWrittenToDisk() throws {
        let waiting = FeedItemState.waiting(FeedDownloadWait.network.reason)
        XCTAssertTrue(waiting.isTransient)
        XCTAssertEqual(waiting.waitingReason, "it downloads on a network without data limits")
        XCTAssertNil(waiting.failureReason)
        XCTAssertEqual(FeedDownloadWait.room(bytes: 61_000_000).reason, "it needs room for 61 MB on this Mac")
        XCTAssertNil(FeedDownloadWait(.transfer(.notFound)))

        let item = FeedItem(id: "guid:a", title: "A", firstSeen: Date(timeIntervalSince1970: 1_791_000_000), state: waiting)
        let record = FeedRecord(feed: Feed(feedURL: try XCTUnwrap(URL(string: "https://atlas.example/feed.xml")), folderID: UUID(), subscribedDate: item.firstSeen), items: [item])
        XCTAssertEqual(record.durable.items.first?.state, .notDownloaded)
        let written = try FeedRecordCoding.decoder().decode(FeedRecord.self, from: FeedRecordCoding.encoder().encode(record))
        XCTAssertEqual(written.items.first?.state, .notDownloaded)
    }

    // MARK: - The Rule's Pass

    /// A pass asks for the newest items not played, as the rule's, one at a
    /// time, newest first: never one the listener declined, nor one whose
    /// download, made before the rule, went; a played item keeps its place
    /// among the newest, so no older one takes it. A second pass asks for
    /// nothing more.
    func testAPassDownloadsTheNewestNotPlayed() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleNewest")
        FeedSettings.newestCountPreference.write(4, to: world.preferences)
        let feed = try await subscribeServed(world, episodes: 6)
        world.center.store.updateItem("guid:ep-1", of: feed.id) { $0.downloadOrigin = .listener }
        world.center.markPlayed("guid:ep-2", of: feed.id)
        world.center.store.updateItem("guid:ep-3", of: feed.id) { $0.downloadDeletedDate = world.day(-2) }

        let report = await world.center.applyItemPolicy(to: [feed.id])

        XCTAssertEqual(report.requestedItemIDs, ["guid:ep-4"])
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-4")
        XCTAssertEqual(origin(of: "guid:ep-4", in: feed, world), .window)
        XCTAssertEqual(world.server.requests(to: "/audio/4.m4a").map(\.allowsExpensiveNetworkAccess), [false])
        XCTAssertEqual(world.server.requests(to: "/audio/5.m4a"), [], "an older episode took a played one's place")
        let again = await world.center.applyItemPolicy(to: [feed.id])
        XCTAssertEqual(again, FeedItemPolicyPassReport())
    }

    /// A download the rule asked for that failed is asked for again only at
    /// a pass that follows a refresh, so a broken file never strains its
    /// server more than once a check.
    func testAFailedDownloadIsTriedAgainOnlyAfterARefresh() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleRetry")
        FeedSettings.newestCountPreference.write(1, to: world.preferences)
        let feed = try await subscribe(world, episodes: 2)
        let audio = try FeedMediaFixtures.silentAAC()
        world.server.serve("/audio/1.m4a", StubResponse(status: 503), FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))

        _ = await world.center.applyItemPolicy(to: [feed.id])
        await waitFor("the download fails") {
            world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state.failureReason != nil
                && world.center.downloads.current == nil
        }
        let quiet = await world.center.applyItemPolicy(to: [feed.id])
        XCTAssertEqual(quiet.requestedItemIDs, [], "a failed download was tried again without a refresh")

        let afterARefresh = await world.center.applyItemPolicy(to: [feed.id], retrying: [feed.id])
        XCTAssertEqual(afterARefresh.requestedItemIDs, ["guid:ep-1"])
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        XCTAssertEqual(world.server.requests(to: "/audio/1.m4a").count, 2)
    }

    /// Holding more of its downloads than the number, the rule removes its
    /// oldest outside the newest until it holds the number: each a download
    /// never opened, so its package goes whole, and its item, not
    /// downloaded, stays the rule's, so a larger number downloads it again.
    func testAPassRemovesTheRulesOldestDownloadsBeyondTheNumber() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleRemoves")
        FeedSettings.newestCountPreference.write(4, to: world.preferences)
        let feed = try await subscribeServed(world, episodes: 5)
        _ = await world.center.applyItemPolicy(to: [feed.id])
        let books = try await downloadedBooks(world, feed: feed, items: (1...4).map { "guid:ep-\($0)" })

        FeedSettings.newestCountPreference.write(2, to: world.preferences)
        let report = await world.center.applyItemPolicy(to: [feed.id])

        XCTAssertEqual(report.removedBookIDs, [books[3].id, books[2].id], "not the oldest first")
        XCTAssertEqual(report.keptPackageBookIDs, [])
        for (index, book) in books.enumerated() {
            let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-\(index + 1)"))
            if index < 2 {
                XCTAssertEqual(item.state, .downloaded(bookID: book.id))
                XCTAssertNotNil(world.library.bookByID(book.id))
            } else {
                XCTAssertEqual(item.state, .notDownloaded)
                XCTAssertEqual(item.downloadDeletedDate, world.clock.value)
                XCTAssertEqual(item.downloadOrigin, .window)
                XCTAssertNil(world.library.bookByID(book.id))
                XCTAssertFalse(FileManager.default.fileExists(atPath: book.tmbDirectory.path), "a package never opened stayed")
            }
        }

        FeedSettings.newestCountPreference.write(4, to: world.preferences)
        let wider = await world.center.applyItemPolicy(to: [feed.id])
        XCTAssertEqual(wider.requestedItemIDs, ["guid:ep-3", "guid:ep-4"])
        _ = try await downloadedBooks(world, feed: feed, items: ["guid:ep-3", "guid:ep-4"])
    }

    /// The rule never removes a download the listener asked for, one on the
    /// reading list, or one open in a reader, which covers one playing; it
    /// may remove one started and not finished, keeping its package with
    /// its place (the listener's answer 5). One open in a reader is looked
    /// at again at the next pass, once its reader has closed.
    func testAPassLeavesWhatTheListenerKeeps() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleKeeps")
        FeedSettings.newestCountPreference.write(4, to: world.preferences)
        let feed = try await subscribeServed(world, episodes: 5)
        _ = await world.center.applyItemPolicy(to: [feed.id])
        let books = try await downloadedBooks(world, feed: feed, items: (1...4).map { "guid:ep-\($0)" })
        world.center.download("guid:ep-5", of: feed.id)
        let listeners = try await downloadedBook(world, feed: feed, item: "guid:ep-5")
        // Episode 4 open in a reader, episode 3 on the reading list, and
        // episode 2 started.
        world.library.openBookIDs = [books[3].id]
        _ = world.library.library.readingList.append([books[2].id])
        let started = try XCTUnwrap(world.library.library.books.firstIndex { $0.id == books[1].id })
        world.library.library.books[started].lastOpened = world.clock.value

        FeedSettings.newestCountPreference.write(1, to: world.preferences)
        let report = await world.center.applyItemPolicy(to: [feed.id])

        XCTAssertEqual(report.inUseBookIDs, [books[3].id])
        XCTAssertEqual(report.onReadingListBookIDs, [books[2].id])
        XCTAssertEqual(report.removedBookIDs, [books[1].id])
        XCTAssertEqual(report.keptPackageBookIDs, [books[1].id], "the started episode's place was not kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: books[1].filePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.bookInfoPath(in: books[1].tmbDirectory).path))
        XCTAssertTrue(world.library.library.feedShelf.rows.contains { $0.id == books[1].id })
        XCTAssertNotNil(world.library.bookByID(books[0].id), "the newest download went")
        XCTAssertNotNil(world.library.bookByID(listeners.id), "the listener's download went")

        world.library.openBookIDs = []
        let next = await world.center.applyItemPolicy(to: [feed.id])
        XCTAssertEqual(next.removedBookIDs, [books[3].id])
        XCTAssertEqual(next.onReadingListBookIDs, [books[2].id])
        XCTAssertNotNil(world.library.bookByID(books[2].id), "a download on the reading list went")
    }

    /// The rule never removes a download in use (REV11 F1): one being
    /// transcribed, whose transcript would be thrown away with its file, and
    /// one being exported, are passed over and looked at again at the next
    /// pass, which removes them once neither work is under way.
    func testAPassLeavesADownloadBeingTranscribedOrExported() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleInUse")
        FeedSettings.newestCountPreference.write(3, to: world.preferences)
        let feed = try await subscribeServed(world, episodes: 3)
        _ = await world.center.applyItemPolicy(to: [feed.id])
        let books = try await downloadedBooks(world, feed: feed, items: (1...3).map { "guid:ep-\($0)" })
        let transcriptions = TranscribedBooks.shared
        let transcribingBefore = transcriptions.transcribingBookID
        addTeardownBlock { @MainActor in transcriptions.setTranscribing(transcribingBefore) }

        // Episode 3, the oldest, is being transcribed, and episode 2 exported.
        transcriptions.setTranscribing(books[2].id)
        BookExportModel.noteExportStarted([books[1].id])
        FeedSettings.newestCountPreference.write(1, to: world.preferences)
        let report = await world.center.applyItemPolicy(to: [feed.id])
        BookExportModel.noteExportEnded([books[1].id])
        transcriptions.setTranscribing(nil)

        XCTAssertEqual(report.inUseBookIDs, [books[2].id, books[1].id])
        XCTAssertEqual(report.removedBookIDs, [])
        for book in books {
            XCTAssertNotNil(world.library.bookByID(book.id), "a download in use went: \(book.title)")
        }

        let next = await world.center.applyItemPolicy(to: [feed.id])
        XCTAssertEqual(next.inUseBookIDs, [])
        XCTAssertEqual(next.removedBookIDs, [books[2].id, books[1].id])
    }

    /// Under the choices that download by hand, a pass takes back the rule's
    /// downloads not yet under way and removes nothing; the one under way
    /// finishes, and stays.
    func testAPassUnderTheOtherChoicesTakesBackTheRulesDownloadsAndRemovesNothing() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleByHand")
        FeedSettings.newestCountPreference.write(3, to: world.preferences)
        let feed = try await subscribeServed(world, episodes: 4, pausing: 0.05)
        _ = await world.center.applyItemPolicy(to: [feed.id])
        await waitFor("the first download is under way") { !world.server.requests(to: "/audio/1.m4a").isEmpty }

        FeedSettings.itemsPreference.write(.everyListedDownloadsByHand, to: world.preferences)
        let byHand = await world.center.applyItemPolicy(to: [feed.id])

        XCTAssertEqual(byHand.withdrawnItemIDs, ["guid:ep-2", "guid:ep-3"])
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-2")?.state, .notDownloaded)
        let first = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        XCTAssertEqual(world.server.requests(to: "/audio/2.m4a"), [], "a download taken back was fetched")

        FeedSettings.itemsPreference.write(.onlyNewestListed, to: world.preferences)
        FeedSettings.newestCountPreference.write(1, to: world.preferences)
        world.center.markPlayed("guid:ep-1", of: feed.id)
        let shortList = await world.center.applyItemPolicy(to: [feed.id])
        XCTAssertEqual(shortList, FeedItemPolicyPassReport())
        XCTAssertNotNil(world.library.bookByID(first.id), "a choice that downloads by hand removed a download")
    }

    // MARK: - Removing Off the Main Thread

    /// The engine's rules remove files off the main thread, on the queue
    /// imports run on, so a restore never interleaves with a removal.
    func testWorkBesideImportsRunsOffTheMainThread() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleOffMain")
        let onMainThread = await world.center.downloads.runBesideImports { Thread.isMainThread }
        XCTAssertFalse(onMainThread)
    }

    /// A file the rule cannot remove, off the main thread, stays: its row
    /// goes back among the books, its feed's index lists it again, and its
    /// item stays downloaded, so nothing of it is lost; the next pass tries
    /// again, and removes it once it can.
    func testAFileTheRuleCannotRemoveStaysWithItsRow() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleRemoveFails")
        FeedSettings.newestCountPreference.write(2, to: world.preferences)
        let feed = try await subscribeServed(world, episodes: 2)
        _ = await world.center.applyItemPolicy(to: [feed.id])
        let books = try await downloadedBooks(world, feed: feed, items: ["guid:ep-1", "guid:ep-2"])
        let package = books[1].tmbDirectory
        // A package whose entries cannot be deleted.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: package.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.path) }

        FeedSettings.newestCountPreference.write(1, to: world.preferences)
        let report = await world.center.applyItemPolicy(to: [feed.id])

        XCTAssertEqual(report.removedBookIDs, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: books[1].filePath))
        XCTAssertNotNil(world.library.bookByID(books[1].id), "the row whose file stayed was not put back")
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-2")?.state, .downloaded(bookID: books[1].id))
        LibraryPersistenceService.flushPendingSave()
        let indexed = try FeedIndexFiles.decoded(Data(contentsOf: FeedPaths.indexFile(of: feed.id, in: TextMouthPaths.root))).books
        XCTAssertTrue(indexed.contains { $0.id == books[1].id }, "the feed's index lost the row whose file stayed")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.path)
        let next = await world.center.applyItemPolicy(to: [feed.id])
        XCTAssertEqual(next.removedBookIDs, [books[1].id])
    }

    // MARK: - When the Rule Runs

    /// Working on its own, the engine downloads a feed's newest at once when
    /// it is subscribed to, and a new one a refresh brings; once that one has
    /// finished, the rule holds more than the number, and its oldest outside
    /// the newest goes.
    func testSubscribingAndRefreshingDownloadTheNewestAndTheOldestGoes() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleOnItsOwn", worksOnItsOwn: true)
        FeedSettings.refreshAtLaunchPreference.write(false, to: world.preferences)
        FeedSettings.refreshIntervalHoursPreference.write(0, to: world.preferences)
        FeedSettings.newestCountPreference.write(2, to: world.preferences)
        await world.start()
        let audio = try FeedMediaFixtures.silentAAC()
        for number in 0...3 {
            world.server.serve("/audio/\(number).m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        }
        let episodes = (0...3).map { number in
            FeedXML.Item(guid: "ep-\(number)", title: "Episode \(number)", published: world.day(number == 0 ? 0.5 : -Double(number)),
                         enclosure: world.server.url("/audio/\(number).m4a").absoluteString, enclosureType: "audio/mp4")
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: Array(episodes.dropFirst()))), .feed(FeedXML.rss(items: episodes)))

        let feed = try await world.subscribe("/feed.xml")
        let second = try await downloadedBooks(world, feed: feed, items: ["guid:ep-1", "guid:ep-2"])[1]
        XCTAssertEqual(world.server.requests(to: "/audio/3.m4a"), [], "more than the newest 2 downloaded")

        world.advance(by: 86_400)
        _ = await world.center.refresh(feed.id)
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-0")
        await waitFor("the oldest of the rule's downloads goes") {
            world.center.store.record(of: feed.id)?.item("guid:ep-2")?.state == .notDownloaded
        }
        XCTAssertNil(world.library.bookByID(second.id))
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state.bookID.map { _ in true }, true)
        await waitFor("the engine's own work ends") { !world.center.isSweeping }
    }

    /// Mark Played and Mark All Played ask for the rule's pass over their
    /// feed at once (REV11 F3), which takes back its downloads of the played
    /// items still waiting in the queue: marked during the batch the rule
    /// started, no played episode downloads after the one under way, which
    /// finishes.
    func testMarkingPlayedTakesBackTheRulesQueuedDownloads() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleMarkPlayed", worksOnItsOwn: true)
        FeedSettings.refreshAtLaunchPreference.write(false, to: world.preferences)
        FeedSettings.refreshIntervalHoursPreference.write(0, to: world.preferences)
        FeedSettings.newestCountPreference.write(4, to: world.preferences)
        await world.start()
        // Subscribing asks for the rule's pass, which asks for the newest 4,
        // each file arriving over a second or more.
        let feed = try await subscribeServed(world, episodes: 4, pausing: 0.05)
        await waitFor("the first download is under way") { !world.server.requests(to: "/audio/1.m4a").isEmpty }
        XCTAssertEqual(world.center.downloads.queue.map(\.itemID), ["guid:ep-2", "guid:ep-3", "guid:ep-4"])

        world.center.markPlayed("guid:ep-2", of: feed.id)
        await waitFor("the pass takes back the played episode's download") {
            world.center.downloads.queue.map(\.itemID) == ["guid:ep-3", "guid:ep-4"]
        }
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-2")?.state, .notDownloaded)

        XCTAssertEqual(world.center.markAllPlayed(of: feed.id), 3)
        await waitFor("the pass takes back the queue") { world.center.downloads.queue.isEmpty }
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        await waitFor("the engine's own work ends") { !world.center.isSweeping && world.center.downloads.current == nil }

        for number in 2...4 {
            XCTAssertEqual(world.server.requests(to: "/audio/\(number).m4a"), [], "played episode \(number) downloaded")
            XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-\(number)")?.state, .notDownloaded)
        }
    }

    /// A refresh TextMouth makes by itself that reaches the network asks for
    /// the rule's pass, and tries again only the put-off downloads the rule
    /// still counts (REV11 F3): one whose item was played meanwhile stays put
    /// off, never fetched, for the pass to take back.
    func testARefreshTriesAgainOnlyThePutOffDownloadsTheRuleStillCounts() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleRetryCounted")
        FeedSettings.newestCountPreference.write(2, to: world.preferences)
        let audio = FeedMediaFixtures.file(try FeedMediaFixtures.silentAAC(), mimeType: "audio/mp4")
        world.server.serve("/audio/1.m4a", .refusedOnAMeteredNetwork(), audio)
        world.server.serve("/audio/2.m4a", .refusedOnAMeteredNetwork(), audio)
        let feed = try await subscribe(world, episodes: 2)
        _ = await world.center.applyItemPolicy(to: [feed.id])
        await waitFor("both downloads are put off") {
            world.center.downloads.putOff.count == 2 && world.center.downloads.current == nil
        }

        // This engine does not work on its own, so marking runs no pass.
        world.center.markPlayed("guid:ep-2", of: feed.id)
        _ = await world.center.refreshAll(origin: .scheduled)
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(world.server.requests(to: "/audio/2.m4a").count, 1, "a put-off download the rule no longer counts was tried again")
        XCTAssertEqual(world.center.downloads.putOff.map(\.itemID), ["guid:ep-2"])
        let pass = await world.center.applyItemPolicy(to: [feed.id])
        XCTAssertEqual(pass.withdrawnItemIDs, ["guid:ep-2"])
        XCTAssertTrue(world.center.downloads.putOff.isEmpty)
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-2")?.state, .notDownloaded)
    }

    /// A reader closing lets the sweep of played downloads run, never the
    /// rule: a download open in a reader stays when its reader closes, and
    /// goes at the rule's next pass, after a refresh (the listener's answer
    /// 5, as the design note's section 5 times it).
    func testAReaderClosingNeverRunsTheRule() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleReaderClose", worksOnItsOwn: true)
        FeedSettings.refreshAtLaunchPreference.write(false, to: world.preferences)
        FeedSettings.refreshIntervalHoursPreference.write(0, to: world.preferences)
        FeedSettings.newestCountPreference.write(2, to: world.preferences)
        await world.start()
        let feed = try await subscribeServed(world, episodes: 2)
        let books = try await downloadedBooks(world, feed: feed, items: ["guid:ep-1", "guid:ep-2"])
        await waitFor("the engine's own work ends") { !world.center.isSweeping }
        world.library.openBookIDs = [books[1].id]
        FeedSettings.newestCountPreference.write(1, to: world.preferences)
        _ = await world.center.refresh(feed.id)
        await waitFor("the pass after the refresh ends") { !world.center.isSweeping }
        XCTAssertNotNil(world.library.bookByID(books[1].id), "a download open in a reader went")

        world.library.openBookIDs = []
        XCTAssertTrue(world.center.isSweeping, "a reader closing ran no sweep")
        await waitFor("the sweep the closing reader asked for ends") { !world.center.isSweeping }
        XCTAssertNotNil(world.library.bookByID(books[1].id), "a reader closing ran the rule")

        _ = await world.center.refresh(feed.id)
        await waitFor("the next pass removes it") { world.library.bookByID(books[1].id) == nil }
        await waitFor("the engine's own work ends") { !world.center.isSweeping }
    }

    /// A changed number applies once it has stayed unchanged for ten seconds:
    /// typing 15 passes through 1, which removes nothing while it is
    /// replaced within the wait; 15, once it stays, downloads what it newly
    /// counts; and a smaller number, once it stays, removes the rule's
    /// downloads beyond it.
    func testAChangedNumberAppliesOnceItHasStayedUnchanged() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleQuiet", worksOnItsOwn: true)
        FeedSettings.refreshAtLaunchPreference.write(false, to: world.preferences)
        FeedSettings.refreshIntervalHoursPreference.write(0, to: world.preferences)
        FeedSettings.newestCountPreference.write(2, to: world.preferences)
        await world.start()
        let feed = try await subscribeServed(world, episodes: 4)
        let books = try await downloadedBooks(world, feed: feed, items: ["guid:ep-1", "guid:ep-2"])
        await waitFor("the engine's own work ends") { !world.center.isSweeping }
        XCTAssertEqual(world.sleep.requestedWaits, [])

        FeedSettings.newestCountPreference.write(1, to: world.preferences)
        await waitFor("the wait starts") { world.sleep.requestedWaits.count == 1 }
        XCTAssertEqual(world.sleep.requestedWaits, [FeedCenter.itemPolicyQuietTime])
        XCTAssertEqual(FeedCenter.itemPolicyQuietTime, .seconds(10))
        FeedSettings.newestCountPreference.write(15, to: world.preferences)
        await waitFor("the wait starts over") { world.sleep.requestedWaits.count == 2 }

        world.sleep.wakeOldest()
        _ = try await downloadedBooks(world, feed: feed, items: ["guid:ep-3", "guid:ep-4"])
        XCTAssertNotNil(world.library.bookByID(books[1].id), "the number passed through 1")

        FeedSettings.newestCountPreference.write(1, to: world.preferences)
        await waitFor("the next wait starts") { world.sleep.requestedWaits.count == 3 }
        world.sleep.wakeOldest()
        await waitFor("the downloads beyond the newest go") {
            world.center.store.record(of: feed.id)?.items.filter { $0.state.bookID != nil }.map(\.id) == ["guid:ep-1"]
        }
        await waitFor("the engine's own work ends") { !world.center.isSweeping }
    }

    /// A feed's own choice applies after the same wait, to that feed: its
    /// own larger number downloads what it newly counts, and its own choice
    /// that downloads by hand removes nothing.
    func testAFeedsOwnChoiceAppliesAfterTheWait() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleOwnChoice", worksOnItsOwn: true)
        FeedSettings.refreshAtLaunchPreference.write(false, to: world.preferences)
        FeedSettings.refreshIntervalHoursPreference.write(0, to: world.preferences)
        FeedSettings.newestCountPreference.write(1, to: world.preferences)
        await world.start()
        let feed = try await subscribeServed(world, episodes: 2)
        let first = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        await waitFor("the engine's own work ends") { !world.center.isSweeping }

        world.center.setItemPolicy(FeedItemPolicy(choice: .everyListedNewestDownloaded, newestCount: 2), of: feed.id)
        await waitFor("the wait starts") { world.sleep.requestedWaits.count == 1 }
        XCTAssertEqual(world.server.requests(to: "/audio/2.m4a"), [], "the feed's own number applied before the wait ended")
        world.sleep.wakeOldest()
        let second = try await downloadedBook(world, feed: feed, item: "guid:ep-2")

        world.center.setItemPolicy(FeedItemPolicy(choice: .everyListedDownloadsByHand, newestCount: 1), of: feed.id)
        await waitFor("the next wait starts") { world.sleep.requestedWaits.count == 2 }
        world.sleep.wakeOldest()
        await waitFor("the pass runs and ends") { !world.center.isWaitingOnItemPolicyChange && !world.center.isSweeping }
        XCTAssertNotNil(world.library.bookByID(first.id))
        XCTAssertNotNil(world.library.bookByID(second.id), "a choice that downloads by hand removed a download")
    }

    /// The first launch of the version that brings the rule, on records and
    /// settings shaped like the user's (FEED-ITEMS-RESEARCH-2026-10-07.md,
    /// section 6): "Finish It!" downloads its newest 5, 315.8 MB as its feed
    /// gives their sizes, and nothing older, "Ep. 368" among them; "The
    /// Digital Antiquarian" downloads the 4 of its newest 5 not downloaded,
    /// 2 articles and both episodes, and its downloaded article, the
    /// listener's, stays as it was. Every download is the rule's, made as
    /// discretionary work, which a network with data limits puts off; a
    /// second pass asks for nothing and removes nothing.
    func testTheFirstLaunchDownloadsTheUsersNewestFive() async throws {
        let world = try FeedTestWorld(self, label: "FeedRuleFirstLaunch")
        FeedSettings.refreshAtLaunchPreference.write(false, to: world.preferences)
        FeedSettings.refreshIntervalHoursPreference.write(0, to: world.preferences)
        let users = try UsersFeeds(world)
        try users.write(to: world)
        let article = users.articleRow(in: world)
        world.library.library.books.append(article)
        let audio = try FeedMediaFixtures.silentAAC()
        for number in 377...381 {
            world.server.serve("/finish-it/\(number).m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        }
        world.server.serve("/antiquarian/museum.mp4", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        world.server.serve("/antiquarian/reading.m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))

        let relaunched = await world.relaunch(self)

        let finishIt = users.finishIt.feed
        let newestFive = (377...381).reversed().map { "guid:finish-it-\($0)" }
        for itemID in newestFive {
            _ = try await downloadedBook(world, center: relaunched, feed: finishIt, item: itemID)
            XCTAssertEqual(relaunched.store.record(of: finishIt.id)?.item(itemID)?.downloadOrigin, .window, itemID)
        }
        let bytes = newestFive.compactMap { relaunched.store.record(of: finishIt.id)?.item($0)?.enclosure?.length }.reduce(0, +)
        XCTAssertEqual(bytes, 315_800_000)
        let fetched = world.server.requests.compactMap(\.url?.path).filter { $0.hasPrefix("/finish-it/") }
        XCTAssertEqual(Set(fetched), Set((377...381).map { "/finish-it/\($0).m4a" }), "more than the newest 5 downloaded")
        XCTAssertNil(relaunched.store.record(of: finishIt.id)?.item("guid:finish-it-368")?.downloadOrigin)

        let antiquarian = users.antiquarian.feed
        for index in [0, 2, 3, 4] {
            _ = try await downloadedBook(world, center: relaunched, feed: antiquarian, item: "guid:antiquarian-\(index)")
        }
        let kept = try XCTUnwrap(relaunched.store.record(of: antiquarian.id)?.item("guid:antiquarian-1"))
        XCTAssertEqual(kept.state, .downloaded(bookID: users.articleBookID))
        XCTAssertNil(kept.downloadOrigin, "the listener's article became the rule's")
        XCTAssertNotNil(world.library.bookByID(users.articleBookID))
        XCTAssertEqual(Set(world.server.requests.map(\.allowsExpensiveNetworkAccess)), [false], "a download was not discretionary")

        await waitFor("the engine's own work ends") { !relaunched.isSweeping && relaunched.downloads.current == nil }
        let again = await relaunched.applyItemPolicy()
        XCTAssertEqual(again, FeedItemPolicyPassReport())
    }

    // MARK: - Helpers

    /// Subscribes `world` to a feed of `episodes` audio episodes, each served
    /// as a second of silence, whose parts come `pausing` seconds apart when
    /// given, so a test can catch the downloads waiting behind the first.
    private func subscribeServed(_ world: FeedTestWorld, episodes: Int, pausing pause: TimeInterval? = nil) async throws -> Feed {
        let audio = try FeedMediaFixtures.silentAAC()
        var file = FeedMediaFixtures.file(audio, mimeType: "audio/mp4")
        if let pause {
            file.chunkSize = max(1, audio.count / 20)
            file.pause = pause
        }
        for number in 1...episodes {
            world.server.serve("/audio/\(number).m4a", file)
        }
        return try await subscribe(world, episodes: episodes)
    }

    /// The books the items `itemIDs` of `feed` download as, each waited for.
    private func downloadedBooks(_ world: FeedTestWorld, feed: Feed, items itemIDs: [FeedItem.ID]) async throws -> [Book] {
        var books: [Book] = []
        for itemID in itemIDs {
            books.append(try await downloadedBook(world, feed: feed, item: itemID))
        }
        return books
    }

    /// Subscribes `world` to a feed of `episodes` audio episodes, "guid:ep-1"
    /// the newest, each at /audio/<number>.m4a, published before the
    /// subscription.
    private func subscribe(_ world: FeedTestWorld, episodes: Int) async throws -> Feed {
        let items = (1...episodes).map { number in
            FeedXML.Item(guid: "ep-\(number)", title: "Episode \(number)", published: world.day(-Double(number)),
                         enclosure: world.server.url("/audio/\(number).m4a").absoluteString, enclosureType: "audio/mp4")
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: items)))
        return try await world.subscribe("/feed.xml")
    }

    /// Who asked for the item `itemID` of `feed`'s download, as its record
    /// says now.
    private func origin(of itemID: FeedItem.ID, in feed: Feed, _ world: FeedTestWorld) -> FeedDownloadOrigin? {
        world.center.store.record(of: feed.id)?.item(itemID)?.downloadOrigin
    }
}
