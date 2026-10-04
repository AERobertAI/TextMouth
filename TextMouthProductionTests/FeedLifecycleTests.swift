import Combine
import XCTest
@testable import TextMouth

/// What happens to a feed item after it downloads (FR03): it is played when
/// its book plays to the end, through the completion that counts Books
/// Finished; its download is deleted the set number of days after, with the
/// clock moved by hand, never while a reader has it open, and in a cloud
/// library only by a Mac holding it whole; its entry stays; and the
/// listener's own commands: Mark as Played, Delete Download, Delete
/// Episode, and ending a subscription.
@MainActor
final class FeedLifecycleTests: XCTestCase {

    // MARK: - Played

    /// A downloaded item's book finishing, as the statistics count Books
    /// Finished, marks the item played at that moment; another book
    /// finishing marks nothing.
    func testABookFinishingMarksItsItemPlayed() async throws {
        let world = try FeedTestWorld(self, label: "FeedPlayed")
        let (feed, book) = try await downloadedEpisode(in: world)

        world.stats.markBookFinished(bookID: UUID(), title: "Another book")
        XCTAssertNil(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.playedDate)

        world.advance(by: 600)
        world.stats.markBookFinished(bookID: book.id, title: book.title)

        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.playedDate, world.clock.value)
        XCTAssertEqual(world.stats.stats.finishedBooks.map(\.bookID).last, book.id.uuidString, "the episode no longer counts as a finished book")
    }

    /// Books Finished counts a finished book with its kind, which this engine
    /// tells as the book finishes: a podcast episode for an episode it
    /// downloaded, which stays one once its download is deleted; an
    /// audiobook for any other audio; a text book for anything else; and
    /// none for a book the library does not hold.
    func testFinishedBooksAreCountedByKind() async throws {
        let world = try FeedTestWorld(self, label: "FeedFinishedKinds")
        let (feed, episode) = try await downloadedEpisode(in: world)
        let audiobook = Book(title: "Ferry Songs", format: .audio, filePath: "/Ferry Songs.m4a", md5Hash: "")
        let novel = Book(title: "Harbour Lights", format: .epub, filePath: "/Harbour Lights.epub", md5Hash: "")
        world.library.library.books += [audiobook, novel]

        for book in [episode, audiobook, novel] {
            world.stats.markBookFinished(bookID: book.id, title: book.title)
        }
        world.stats.markBookFinished(bookID: UUID(), title: "Not in the library")
        try world.center.deleteDownload("guid:ep-1", of: feed.id)

        XCTAssertEqual(world.stats.stats.finishedBooks.map(\.kind), [.episode, .audiobook, .text, nil])
        XCTAssertNil(world.center.finishedBookKind(of: episode.id), "the deleted download is still in the library")
        XCTAssertEqual(world.stats.booksFinishedAllTimeByKind, FinishedBookCounts(textBooks: 1, audiobooks: 1, episodes: 1))
    }

    /// Mark as Played and Mark as Unplayed set and clear the played date.
    func testMarkingPlayedAndUnplayed() async throws {
        let world = try FeedTestWorld(self, label: "FeedMarkPlayed")
        let (feed, _) = try await downloadedEpisode(in: world)

        world.center.markPlayed("guid:ep-1", of: feed.id)
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.playedDate, world.clock.value)

        world.center.markUnplayed("guid:ep-1", of: feed.id)
        XCTAssertNil(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.playedDate)
    }

    // MARK: - Deleted After Playing

    /// A played download is deleted once the set number of days has passed,
    /// and not before: its package goes for good, its book leaves the
    /// library, and its item stays, not downloaded, with the date its
    /// download went.
    func testAPlayedDownloadIsDeletedAfterTheSetDays() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeleteAfter")
        let (feed, book) = try await downloadedEpisode(in: world)
        world.stats.markBookFinished(bookID: book.id, title: book.title)
        // Other tests delete an "Episode One" too, so the lines are counted
        // before and after.
        let deleted = "FEED_DOWNLOAD_DELETED: Episode One"
        let deletedBefore = debugLogLines(containing: deleted).count

        world.advance(by: 86_400 - 60)
        var report = await world.center.sweepPlayedDownloads()
        XCTAssertEqual(report.deletedBookIDs, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.tmbDirectory.path))

        world.advance(by: 120)
        report = await world.center.sweepPlayedDownloads()

        XCTAssertEqual(report.deletedBookIDs, [book.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
        XCTAssertNil(world.library.bookByID(book.id))
        let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))
        XCTAssertEqual(item.state, .notDownloaded)
        XCTAssertEqual(item.downloadDeletedDate, world.clock.value)
        XCTAssertNotNil(item.playedDate)
        XCTAssertEqual(debugLogLines(containing: deleted).count, deletedBefore + 1)
    }

    /// 0 days deletes a played download at the next sweep, -1 never does,
    /// and a feed's own number wins over the setting.
    func testTheDaysSettingAndAFeedsOverride() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeleteDays")
        let (feed, book) = try await downloadedEpisode(in: world)
        world.center.markPlayed("guid:ep-1", of: feed.id)

        FeedSettings.deleteDownloadsDaysAfterPlayedPreference.write(-1, to: world.preferences)
        world.advance(by: 400 * 86_400)
        var report = await world.center.sweepPlayedDownloads()
        XCTAssertEqual(report.deletedBookIDs, [], "-1 deleted a download")

        world.center.setDeleteDownloadsDaysAfterPlayed(0, of: feed.id)
        report = await world.center.sweepPlayedDownloads()
        XCTAssertEqual(report.deletedBookIDs, [book.id])
    }

    /// An unplayed download is never deleted, however old.
    func testAnUnplayedDownloadStays() async throws {
        let world = try FeedTestWorld(self, label: "FeedUnplayedStays")
        let (_, book) = try await downloadedEpisode(in: world)
        world.advance(by: 30 * 86_400)

        let report = await world.center.sweepPlayedDownloads()

        XCTAssertEqual(report.deletedBookIDs, [])
        XCTAssertNotNil(world.library.bookByID(book.id))
    }

    /// A due download open in a reader waits; once its reader closes, the
    /// engine, working on its own, deletes it at once.
    func testADownloadOpenInAReaderWaitsUntilItCloses() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeleteOpen", worksOnItsOwn: true)
        FeedSettings.refreshAtLaunchPreference.write(false, to: world.preferences)
        FeedSettings.refreshIntervalHoursPreference.write(0, to: world.preferences)
        let (feed, book) = try await downloadedEpisode(in: world)
        FeedSettings.deleteDownloadsDaysAfterPlayedPreference.write(0, to: world.preferences)
        world.library.openBookIDs = [book.id]
        world.center.markPlayed("guid:ep-1", of: feed.id)

        let report = await world.center.sweepPlayedDownloads()
        XCTAssertEqual(report.openBookIDs, [book.id])
        XCTAssertNotNil(world.library.bookByID(book.id))

        world.library.openBookIDs = []
        await waitFor("the download is deleted once its reader closes") { world.library.bookByID(book.id) == nil }
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state, .notDownloaded)
    }

    /// In a cloud library, a due download is deleted only when this Mac
    /// holds its package whole; one only in the cloud is left, with one log
    /// line, for a Mac that has it.
    func testACloudLibraryDeletesOnlyWhatThisMacHolds() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeleteCloud")
        let (feed, book) = try await downloadedEpisode(in: world)
        world.center.markPlayed("guid:ep-1", of: feed.id)
        FeedSettings.deleteDownloadsDaysAfterPlayedPreference.write(0, to: world.preferences)
        world.cloud.setLibraryLocation(.cloud(.iCloudDrive))
        world.cloud.setState(.inCloud, of: book.id)
        let leftInCloud = "FEED_SWEEP_LEFT_IN_CLOUD: 1 played download(s)"
        let leftInCloudBefore = debugLogLines(containing: leftInCloud).count

        var report = await world.center.sweepPlayedDownloads()
        XCTAssertEqual(report.leftInCloudBookIDs, [book.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state, .downloaded(bookID: book.id))
        XCTAssertEqual(debugLogLines(containing: leftInCloud).count, leftInCloudBefore + 1)

        world.cloud.setState(.downloaded, of: book.id)
        report = await world.center.sweepPlayedDownloads()
        XCTAssertEqual(report.deletedBookIDs, [book.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
    }

    /// An item whose book the listener deleted from the library becomes not
    /// downloaded at the next sweep.
    func testAnItemWhoseBookWasDeletedIsNotDownloaded() async throws {
        let world = try FeedTestWorld(self, label: "FeedBookGone")
        let (feed, book) = try await downloadedEpisode(in: world)
        world.library.removeFeedBook(book)
        XCTAssertEqual(world.center.state(of: try XCTUnwrap(world.center.listedItems(of: feed.id).first)), .notDownloaded)

        let report = await world.center.sweepPlayedDownloads()

        XCTAssertEqual(report.forgottenItemIDs, ["guid:ep-1"])
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state, .notDownloaded)
    }

    /// Nothing is swept while the library's index is recovered: a due
    /// download stays, and an item whose book the provisional list lacks
    /// keeps its book.
    func testNothingIsSweptWhileTheIndexIsRecovered() async throws {
        let world = try FeedTestWorld(self, label: "FeedSweepRecovery")
        let (feed, book) = try await downloadedEpisode(in: world)
        FeedSettings.deleteDownloadsDaysAfterPlayedPreference.write(0, to: world.preferences)
        world.center.markPlayed("guid:ep-1", of: feed.id)
        world.library.indexRecovery = LibraryIndexRecovery(failure: LibraryIndexReadFailure(
            indexURL: world.folder.url.appendingPathComponent("library.json"),
            quarantineURL: nil,
            error: CocoaError(.fileReadCorruptFile),
            byteCount: 0
        ))
        world.library.library.books.removeAll()

        let report = await world.center.sweepPlayedDownloads()

        XCTAssertEqual(report.deletedBookIDs, [])
        XCTAssertEqual(report.forgottenItemIDs, [])
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state, .downloaded(bookID: book.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
    }

    // MARK: - The Listener's Commands

    /// Delete Download deletes the book and keeps the item, not downloaded;
    /// it is refused while a reader has the book open.
    func testDeleteDownloadKeepsTheItem() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeleteDownload")
        let (feed, book) = try await downloadedEpisode(in: world)
        world.library.openBookIDs = [book.id]
        XCTAssertThrowsError(try world.center.deleteDownload("guid:ep-1", of: feed.id)) { error in
            XCTAssertEqual(error as? BookCloudError, .bookIsOpen)
        }
        world.library.openBookIDs = []

        try world.center.deleteDownload("guid:ep-1", of: feed.id)

        XCTAssertNil(world.library.bookByID(book.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
        XCTAssertEqual(world.center.listedItems(of: feed.id).map(\.state), [.notDownloaded])
    }

    /// Delete Episode deletes the download and the item, which no refresh
    /// brings back.
    func testDeleteEpisodeTakesTheItemAway() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeleteEpisode")
        let (feed, book) = try await downloadedEpisode(in: world)

        try world.center.deleteItem("guid:ep-1", of: feed.id)

        XCTAssertNil(world.library.bookByID(book.id))
        XCTAssertEqual(world.center.listedItems(of: feed.id), [])
        XCTAssertNotNil(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.deletedDate)
    }

    /// Ending a subscription removes its record and this Mac's fetch details
    /// and leaves every book it downloaded in its folder.
    func testUnsubscribingLeavesTheBooks() async throws {
        let world = try FeedTestWorld(self, label: "FeedUnsubscribe")
        let (feed, book) = try await downloadedEpisode(in: world)
        await world.center.store.flush()

        world.center.unsubscribe(feed.id)
        await world.center.store.flush()
        await world.center.fetchStates.flush()

        XCTAssertNil(world.center.store.record(of: feed.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: FeedPaths.recordFile(of: feed.id, in: world.recordsFolder).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: FeedPaths.recordFile(of: feed.id, in: world.fetchStateFolder).path))
        XCTAssertNotNil(world.library.bookByID(book.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
    }

    // MARK: - Helpers

    /// Starts `world`'s engine, subscribes it to a feed of one episode,
    /// "Episode One", and downloads it; returns the feed and the book.
    private func downloadedEpisode(in world: FeedTestWorld) async throws -> (Feed, Book) {
        await world.start()
        world.server.serve("/audio/1.m4a", FeedMediaFixtures.file(try FeedMediaFixtures.silentAAC(), mimeType: "audio/mp4"))
        let item = FeedXML.Item(guid: "ep-1", title: "Episode One", published: world.day(-1),
                                enclosure: world.server.url("/audio/1.m4a").absoluteString, enclosureType: "audio/mp4")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [item])))
        let feed = try await world.subscribe("/feed.xml")
        world.center.download("guid:ep-1", of: feed.id)
        return (feed, try await downloadedBook(world, feed: feed, item: "guid:ep-1"))
    }
}
