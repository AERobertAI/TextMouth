import XCTest
@testable import TextMouth

/// The feed downloads' progress as the download manager tells it (FR10's
/// feed half), against a stub server: each download from the queue to its
/// book, its file's bytes, its book being added, how it ended, and the
/// newest-N rule's downloads waiting apart for a network or for room. No
/// test reaches the network, and no episode is played.
@MainActor
final class FeedDownloadProgressEngineTests: XCTestCase {

    // MARK: - A Run of Downloads

    /// Two episodes asked for together run as one run of two: the first is
    /// named with its feed at once, the second waits with its size; each is
    /// being added to the library, its whole file counted, as its book is
    /// listed; and the run ends, forgotten, with the second.
    func testTheProgressFollowsEachDownloadFromTheQueueToItsBook() async throws {
        let world = try FeedTestWorld(self, label: "FeedProgressRun")
        let first = try FeedMediaFixtures.silentAAC()
        let second = try FeedMediaFixtures.silentAAC(duration: 2)
        let feed = try await subscribe(world, episodes: [("ep-1", "Episode One", first), ("ep-2", "Episode Two", second)])
        let progress = world.center.downloads.progress
        var atCommit: [FeedDownloadProgressState] = []
        world.center.downloads.beforeCommit = { _ in atCommit.append(progress.state) }

        world.center.download("guid:ep-1", of: feed.id)
        world.center.download("guid:ep-2", of: feed.id)

        XCTAssertTrue(progress.state.isRunning)
        XCTAssertEqual(progress.state.total, 2)
        XCTAssertEqual(progress.state.download?.title, "Episode One")
        XCTAssertEqual(progress.state.download?.feedTitle, "The Tactile Atlas")
        XCTAssertEqual(progress.state.download?.transfer?.totalBytes, Int64(first.count), "the feed's size was not the estimate")
        XCTAssertEqual(progress.state.queued, [Int64(second.count)])

        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-2")

        XCTAssertEqual(atCommit.count, 2)
        XCTAssertEqual(atCommit.first?.done, 0)
        XCTAssertEqual(atCommit.first?.download?.isAddingToLibrary, true)
        XCTAssertEqual(atCommit.first?.download?.transfer?.completedBytes, Int64(first.count), "the file's bytes never reached the progress")
        XCTAssertEqual(atCommit.last?.done, 1)
        XCTAssertEqual(atCommit.last?.download?.title, "Episode Two")
        XCTAssertEqual(atCommit.last?.download?.transfer?.completedBytes, Int64(second.count))
        XCTAssertEqual(atCommit.last?.timing.downloads, 1)
        XCTAssertEqual(atCommit.last?.timing.sizedBytes, Int64(first.count))
        XCTAssertFalse(progress.state.isRunning)
        XCTAssertEqual(progress.state, FeedDownloadProgressState(), "the ended run was not forgotten")
    }

    /// An article is named without bytes, then as being added to the
    /// library.
    func testAnArticleIsNamedWithoutBytes() async throws {
        let world = try FeedTestWorld(self, label: "FeedProgressArticle")
        let paragraphs = (1...30).map { "<p>Paragraph \($0) of the notes says what changed.</p>" }
        let items = [FeedXML.Item(guid: "post-1", title: "Corkboard 7.1.2 Released", published: world.day(-1), description: paragraphs.joined())]
        world.server.serve("/feed.xml", .feed(FeedXML.rss(title: "Corkboard News", items: items)))
        let feed = try await world.subscribe("/feed.xml")
        let progress = world.center.downloads.progress
        var atCommit: FeedDownloadProgressState?
        world.center.downloads.beforeCommit = { _ in atCommit = progress.state }

        world.center.download("guid:post-1", of: feed.id)
        XCTAssertEqual(
            progress.state.lines(at: Date()),
            ["0 of 1 done", "Download 1 of 1: “Corkboard 7.1.2 Released” from Corkboard News"]
        )
        _ = try await downloadedBook(world, feed: feed, item: "guid:post-1")

        XCTAssertNil(atCommit?.download?.transfer)
        XCTAssertEqual(atCommit?.download?.activity, "adding it to the library")
        XCTAssertFalse(progress.state.isRunning)
    }

    /// A download that fails is done, and counted as failed, before the
    /// next one runs.
    func testAFailedDownloadIsDoneAndCountedAsFailed() async throws {
        let world = try FeedTestWorld(self, label: "FeedProgressFailed")
        let audio = try FeedMediaFixtures.silentAAC()
        let feed = try await subscribe(world, episodes: [("ep-1", "Episode One", audio), ("ep-2", "Episode Two", audio)])
        world.server.serve("/audio/ep-1.m4a", StubResponse(status: 404))
        let progress = world.center.downloads.progress
        var atCommit: FeedDownloadProgressState?
        world.center.downloads.beforeCommit = { _ in atCommit = progress.state }

        world.center.download("guid:ep-1", of: feed.id)
        world.center.download("guid:ep-2", of: feed.id)
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-2")

        XCTAssertEqual(atCommit?.done, 1)
        XCTAssertEqual(atCommit?.failed, 1)
        XCTAssertEqual(atCommit?.lines(at: Date()).first, "1 of 2 done, 1 failed")
        XCTAssertEqual(atCommit?.timing.downloads, 0, "a failed download was timed")
    }

    // MARK: - Waiting Apart

    /// The newest-N rule's downloads that wait leave the run and are counted
    /// apart by their reason: for room on this Mac, and for a network
    /// without data limits. Cancel Download takes one back, and asking
    /// again for those put off runs them, waiting no more.
    func testTheRulesWaitingDownloadsAreCountedApartByTheirReason() async throws {
        let world = try FeedTestWorld(self, label: "FeedProgressWaits")
        let audio = try FeedMediaFixtures.silentAAC()
        let feed = try await subscribe(world, episodes: [("ep-1", "Episode One", audio), ("ep-2", "Episode Two", audio)])
        world.server.serve("/audio/ep-1.m4a", .refusedOnAMeteredNetwork(), FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        let downloads = world.center.downloads
        let progress = downloads.progress

        // No room for the second, beside the space TextMouth keeps free.
        world.freeSpace.value = 0
        downloads.download("guid:ep-2", of: feed.id, origin: .window)
        await waitFor("the second waits for room") { self.settled(world, feed: feed, item: "guid:ep-2") }
        world.freeSpace.value = 100_000_000_000
        downloads.download("guid:ep-1", of: feed.id, origin: .window)
        await waitFor("the first waits for a network") { self.settled(world, feed: feed, item: "guid:ep-1") }

        XCTAssertTrue(downloads.isPutOff("guid:ep-1", of: feed.id))
        XCTAssertFalse(progress.state.isRunning)
        XCTAssertEqual(progress.state.waits, FeedDownloadWaits(network: 1, room: 1))
        XCTAssertEqual(
            progress.spokenStatus(),
            "No feed download is under way. 1 waiting for a network without data limits. 1 waiting for room on this Mac."
        )

        world.center.cancelDownload("guid:ep-2", of: feed.id)
        XCTAssertEqual(progress.state.waits, FeedDownloadWaits(network: 1, room: 0))

        downloads.retryPutOffDownloads()
        XCTAssertEqual(progress.state.waits, FeedDownloadWaits())
        XCTAssertTrue(progress.state.isRunning)
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        XCTAssertEqual(progress.state, FeedDownloadProgressState())
    }

    /// Quitting clears the progress, the downloads waiting apart with it:
    /// each keeps its place for the next launch.
    func testQuittingClearsTheProgress() async throws {
        let world = try FeedTestWorld(self, label: "FeedProgressQuit")
        let audio = try FeedMediaFixtures.silentAAC()
        let feed = try await subscribe(world, episodes: [("ep-1", "Episode One", audio)])
        world.server.serve("/audio/ep-1.m4a", .refusedOnAMeteredNetwork())
        let downloads = world.center.downloads
        downloads.download("guid:ep-1", of: feed.id, origin: .window)
        await waitFor("the episode waits for a network") { self.settled(world, feed: feed, item: "guid:ep-1") }
        XCTAssertEqual(downloads.progress.state.waits, FeedDownloadWaits(network: 1))

        await downloads.stopForQuit()

        XCTAssertEqual(downloads.progress.state, FeedDownloadProgressState())
    }

    // MARK: - Helpers

    /// Starts `world`'s engine and subscribes it to a feed of `episodes`,
    /// newest first, each served at /audio/<id>.m4a, its length in the feed
    /// its file's.
    private func subscribe(_ world: FeedTestWorld, episodes: [(id: String, title: String, file: Data)]) async throws -> Feed {
        await world.start()
        let items = episodes.enumerated().map { index, episode in
            FeedXML.Item(
                guid: episode.id,
                title: episode.title,
                published: world.day(-Double(index + 1)),
                enclosure: world.server.url("/audio/\(episode.id).m4a").absoluteString,
                enclosureType: "audio/mp4",
                enclosureLength: episode.file.count
            )
        }
        for episode in episodes {
            world.server.serve("/audio/\(episode.id).m4a", FeedMediaFixtures.file(episode.file, mimeType: "audio/mp4"))
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: items)))
        return try await world.subscribe("/feed.xml")
    }

    /// Whether the download of the item `itemID` of `feed` in `world` has
    /// ended, waiting, failed, or downloaded, and no longer runs or waits to
    /// start.
    private func settled(_ world: FeedTestWorld, feed: Feed, item itemID: FeedItem.ID) -> Bool {
        let state = world.center.store.record(of: feed.id)?.item(itemID)?.state
        let ended = state?.waitingReason != nil || state?.failureReason != nil || state?.bookID != nil
        return ended && !world.center.downloads.isDownloading(itemID, of: feed.id)
    }
}
