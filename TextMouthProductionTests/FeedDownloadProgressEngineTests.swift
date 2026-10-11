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
        XCTAssertEqual(atCommit.last?.timing.items, 1)
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
        XCTAssertEqual(atCommit?.timing.items, 0, "a failed download was timed")
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
            "No feed download is under way. 1 waiting until this Mac is on a network without data limits. 1 waiting for room on this Mac."
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

    /// A download under way as TextMouth quits, with another queued behind
    /// it, shows nothing more once the quit has cleared the progress: its
    /// end republishes neither itself nor the queue, so the section never
    /// shows again while the quit waits (feed review item 21).
    func testQuittingWithDownloadsQueuedShowsNothingAgain() async throws {
        let world = try FeedTestWorld(self, label: "FeedProgressQuitQueued")
        let audio = try FeedMediaFixtures.silentAAC()
        let feed = try await subscribe(world, episodes: [("ep-1", "Episode One", audio), ("ep-2", "Episode Two", audio)])
        var slow = FeedMediaFixtures.file(audio, mimeType: "audio/mp4")
        slow.chunkSize = max(1, audio.count / 20)
        slow.pause = 0.05
        world.server.serve("/audio/ep-1.m4a", slow)
        let downloads = world.center.downloads
        downloads.download("guid:ep-1", of: feed.id, origin: .listener)
        downloads.download("guid:ep-2", of: feed.id, origin: .listener)
        await waitFor("the first download is under way") { !world.server.requests(to: "/audio/ep-1.m4a").isEmpty }

        await downloads.stopForQuit()
        await waitFor("the download under way stops") { downloads.current == nil }

        XCTAssertEqual(downloads.progress.state, FeedDownloadProgressState(), "the section came back while the quit waited")
        XCTAssertEqual(downloads.queue.map(\.itemID), ["guid:ep-2"], "quitting forgot the download queued")
    }

    // MARK: - Cancel

    /// Cancel stops the download under way and those waiting to start,
    /// whoever asked for each (FR14): each item is not downloaded, its
    /// resume data goes, and it stays whoever's it was, never made the
    /// listener's. The newest-N rule downloads none of them by itself until
    /// the feed's next check has ended, whatever asks for a pass meanwhile;
    /// after the check, it asks for each again. Cancel says what it stopped
    /// and when TextMouth tries again, and the run ends without announcing
    /// its end.
    func testCancelPausesTheRuleUntilTheFeedsNextCheck() async throws {
        let world = try FeedTestWorld(self, label: "FeedProgressCancel")
        let audio = try FeedMediaFixtures.silentAAC()
        let feed = try await subscribe(world, episodes: [("ep-1", "Episode One", audio), ("ep-2", "Episode Two", audio), ("ep-3", "Episode Three", audio)])
        let downloads = world.center.downloads
        let staleResume = downloads.resumeDataFile(for: "guid:ep-2", of: feed.id)
        try FileManager.default.createDirectory(at: staleResume.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: staleResume)
        var slow = FeedMediaFixtures.file(audio, mimeType: "audio/mp4")
        slow.chunkSize = max(1, audio.count / 20)
        slow.pause = 0.05
        world.server.serve("/audio/ep-1.m4a", slow)

        world.center.download("guid:ep-1", of: feed.id)
        downloads.download("guid:ep-2", of: feed.id, origin: .window)
        downloads.download("guid:ep-3", of: feed.id, origin: .window)
        let recorder = recordingAnnouncements {
            XCTAssertEqual(
                world.center.cancelEveryDownload(),
                "Stopped 3 feed downloads. " + FeedDownloadProgressWording.retryAfterCancel
            )
        }
        XCTAssertEqual(recorder.announcements, [], "Cancel spoke before the window moved VoiceOver's focus")
        XCTAssertEqual(downloads.queue, [])
        XCTAssertTrue(downloads.progress.state.isCancelling)
        await waitFor("the download under way stops") { !downloads.isDownloading("guid:ep-1", of: feed.id) }

        let items = try XCTUnwrap(world.center.store.record(of: feed.id)?.items)
        XCTAssertEqual(items.map(\.state), [.notDownloaded, .notDownloaded, .notDownloaded])
        XCTAssertFalse(items.contains { $0.downloadOrigin == .listener }, "Cancel made an item the listener's")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleResume.path), "a stopped download kept its resume data")
        XCTAssertEqual(downloads.progress.state, FeedDownloadProgressState())
        XCTAssertEqual(world.center.rulePauses, [feed.id: .untilNextCheck])
        let paused = await world.center.applyItemPolicy(to: [feed.id])
        XCTAssertEqual(paused.requestedItemIDs, [], "the rule downloaded again what Cancel stopped before a check")

        await world.center.refresh(feed.id)

        XCTAssertEqual(world.center.rulePauses, [:])
        let afterTheCheck = await world.center.applyItemPolicy(to: [feed.id])
        XCTAssertEqual(afterTheCheck.requestedItemIDs, ["guid:ep-1", "guid:ep-2", "guid:ep-3"])
    }

    /// A check under way as Cancel is pressed began before it, so its end
    /// leaves the pause to the check after it (FR14).
    func testACheckUnderWayAtCancelEndsNoPause() async throws {
        let world = try FeedTestWorld(self, label: "FeedProgressCancelChecking")
        let audio = try FeedMediaFixtures.silentAAC()
        let feed = try await subscribe(world, episodes: [("ep-1", "Episode One", audio)])
        var slowFeed = StubResponse.feed(FeedXML.rss(items: [
            FeedXML.Item(
                guid: "ep-1",
                title: "Episode One",
                published: world.day(-1),
                enclosure: world.server.url("/audio/ep-1.m4a").absoluteString,
                enclosureType: "audio/mp4",
                enclosureLength: audio.count
            ),
        ]))
        slowFeed.pause = 0.3
        world.server.serve("/feed.xml", slowFeed)
        var slow = FeedMediaFixtures.file(audio, mimeType: "audio/mp4")
        slow.chunkSize = max(1, audio.count / 20)
        slow.pause = 0.05
        world.server.serve("/audio/ep-1.m4a", slow)
        world.center.download("guid:ep-1", of: feed.id)
        let check = Task { await world.center.refresh(feed.id) }
        await waitFor("the check is under way") { world.center.refreshingFeedIDs.contains(feed.id) }

        world.center.cancelEveryDownload()
        XCTAssertEqual(world.center.rulePauses, [feed.id: .untilTheCheckAfterTheOneUnderWay])
        _ = await check.value

        XCTAssertEqual(world.center.rulePauses, [feed.id: .untilNextCheck], "a check begun before Cancel ended its pause")
        let stillPaused = await world.center.applyItemPolicy(to: [feed.id])
        XCTAssertEqual(stillPaused.requestedItemIDs, [])
        await world.center.refresh(feed.id)
        XCTAssertEqual(world.center.rulePauses, [:])
    }

    /// Cancel stops the rule's downloads waiting for a network or for room
    /// too: each no longer waits, is not downloaded, and stays the rule's;
    /// nothing is left waiting apart (FR14).
    func testCancelStopsTheRulesWaitingDownloadsToo() async throws {
        let world = try FeedTestWorld(self, label: "FeedProgressCancelWaits")
        let audio = try FeedMediaFixtures.silentAAC()
        let feed = try await subscribe(world, episodes: [("ep-1", "Episode One", audio), ("ep-2", "Episode Two", audio), ("ep-3", "Episode Three", audio)])
        world.server.serve("/audio/ep-1.m4a", .refusedOnAMeteredNetwork())
        let downloads = world.center.downloads
        downloads.download("guid:ep-1", of: feed.id, origin: .window)
        await waitFor("the first waits for a network") { self.settled(world, feed: feed, item: "guid:ep-1") }
        world.freeSpace.value = 0
        downloads.download("guid:ep-2", of: feed.id, origin: .window)
        await waitFor("the second waits for room") { self.settled(world, feed: feed, item: "guid:ep-2") }
        world.freeSpace.value = 100_000_000_000
        XCTAssertEqual(downloads.progress.state.waits, FeedDownloadWaits(network: 1, room: 1))
        var slow = FeedMediaFixtures.file(audio, mimeType: "audio/mp4")
        slow.chunkSize = max(1, audio.count / 20)
        slow.pause = 0.05
        world.server.serve("/audio/ep-3.m4a", slow)
        world.center.download("guid:ep-3", of: feed.id)

        let said = world.center.cancelEveryDownload()
        await waitFor("the download under way stops") { !downloads.isDownloading("guid:ep-3", of: feed.id) }

        XCTAssertEqual(said, "Stopped 3 feed downloads. " + FeedDownloadProgressWording.retryAfterCancel)
        XCTAssertFalse(downloads.isPutOff("guid:ep-1", of: feed.id))
        XCTAssertEqual(downloads.progress.state.waits, FeedDownloadWaits())
        let items = try XCTUnwrap(world.center.store.record(of: feed.id)?.items)
        XCTAssertEqual(items.map(\.state), [.notDownloaded, .notDownloaded, .notDownloaded])
        XCTAssertFalse(items.contains { $0.downloadOrigin == .listener }, "Cancel made an item the listener's")
    }

    /// Cancel promises that TextMouth downloads again by itself only what
    /// the newest-N rule will (REV14 feeds 5): with every feed set to
    /// download by hand, the download it stops comes back only by Download,
    /// and Cancel says so, as its button's hint said beforehand; with
    /// nothing left to stop, the hint promises nothing.
    func testCancelSaysDownloadGetsBackWhatTheRuleNeverDownloads() async throws {
        let world = try FeedTestWorld(self, label: "FeedProgressCancelByHand")
        FeedSettings.itemsPreference.write(.everyListedDownloadsByHand, to: world.preferences)
        let audio = try FeedMediaFixtures.silentAAC()
        let feed = try await subscribe(world, episodes: [("ep-1", "Episode One", audio)])
        world.server.serve("/audio/ep-1.m4a", slowly(audio))
        world.center.download("guid:ep-1", of: feed.id)
        XCTAssertEqual(world.center.cancelButtonHint(), FeedDownloadProgressWording.cancelButtonHint(FeedCancelReturn(byDownload: 1)))

        let said = world.center.cancelEveryDownload()

        XCTAssertEqual(said, "Stopped downloading “Episode One”. To download it again, choose Download on its row.")
        await waitFor("the download under way stops") { !world.center.downloads.isDownloading("guid:ep-1", of: feed.id) }
        XCTAssertEqual(world.center.cancelButtonHint(), FeedDownloadProgressWording.cancelButtonHint(FeedCancelReturn()))
    }

    /// When the newest-N rule downloads only some of what Cancel stopped
    /// again by itself, Cancel says how many, and that Download gets back
    /// the others (REV14 feeds 5): here the feed counts only its newest
    /// episode, and the listener had asked for an older one too. After the
    /// feed's next check, the rule asks for the newest alone, as promised.
    func testCancelSaysHowManyComeBackByThemselves() async throws {
        let world = try FeedTestWorld(self, label: "FeedProgressCancelMixed")
        FeedSettings.newestCountPreference.write(1, to: world.preferences)
        let audio = try FeedMediaFixtures.silentAAC()
        let feed = try await subscribe(world, episodes: [("ep-1", "Episode One", audio), ("ep-2", "Episode Two", audio)])
        world.server.serve("/audio/ep-1.m4a", slowly(audio))
        world.center.download("guid:ep-1", of: feed.id)
        world.center.download("guid:ep-2", of: feed.id)

        let said = world.center.cancelEveryDownload()

        XCTAssertEqual(
            said,
            "Stopped 2 feed downloads. TextMouth downloads 1 of them again at its feed's next check, or the next time it opens. "
                + "To download the other one again, choose Download on its row."
        )
        await waitFor("the download under way stops") { !world.center.downloads.isDownloading("guid:ep-1", of: feed.id) }
        await world.center.refresh(feed.id)
        let afterTheCheck = await world.center.applyItemPolicy(to: [feed.id])
        XCTAssertEqual(afterTheCheck.requestedItemIDs, ["guid:ep-1"])
    }

    /// `audio` served in parts a moment apart, so its download is still
    /// under way when the test acts on it.
    private func slowly(_ audio: Data) -> StubResponse {
        var slow = FeedMediaFixtures.file(audio, mimeType: "audio/mp4")
        slow.chunkSize = max(1, audio.count / 20)
        slow.pause = 0.05
        return slow
    }

    /// Cancel deletes every partial download on this Mac (FR14, "any in
    /// progress downloads should probably be deleted too, like mp3 parts"):
    /// the resume data a download stopped partway left, with the partial
    /// file the system kept for it and that data names, here a real one,
    /// and any file waiting to be imported; none remains.
    func testCancelLeavesNoPartialDownload() async throws {
        let world = try FeedTestWorld(self, label: "FeedProgressCancelParts")
        let audio = try FeedMediaFixtures.silentAAC(duration: 2)
        let feed = try await subscribe(world, episodes: [("ep-1", "Episode One", audio), ("ep-2", "Episode Two", audio)])
        var broken = FeedMediaFixtures.file(audio, mimeType: "audio/mp4")
        broken.chunkSize = audio.count / 2
        broken.failAfterBytes = audio.count / 2
        world.server.serve("/audio/ep-1.m4a", broken)
        let downloads = world.center.downloads
        downloads.download("guid:ep-1", of: feed.id, origin: .window)
        await waitFor("the first stops partway") { self.settled(world, feed: feed, item: "guid:ep-1") }
        let resumeFile = downloads.resumeDataFile(for: "guid:ep-1", of: feed.id)
        let resumeData = try Data(contentsOf: resumeFile)
        let partial = try XCTUnwrap(
            FeedPartialDownloads.partialFile(namedIn: resumeData, temporaryFolder: FileManager.default.temporaryDirectory),
            "the resume data names no partial file"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path), "the system kept no partial file")
        let leftover = world.downloadsFolder.appendingPathComponent("\(UUID().uuidString).download")
        try FileManager.default.createDirectory(at: world.downloadsFolder, withIntermediateDirectories: true)
        try Data("left by a crash".utf8).write(to: leftover)
        var slow = FeedMediaFixtures.file(audio, mimeType: "audio/mp4")
        slow.chunkSize = max(1, audio.count / 20)
        slow.pause = 0.05
        world.server.serve("/audio/ep-2.m4a", slow)
        world.center.download("guid:ep-2", of: feed.id)

        world.center.cancelEveryDownload()
        await waitFor("the download under way stops") { !downloads.isDownloading("guid:ep-2", of: feed.id) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path), "Cancel left the partial file")
        let resumeLeft = ((try? FileManager.default.contentsOfDirectory(atPath: world.resumeFolder.path)) ?? [])
            .filter { $0.hasSuffix(FeedPartialDownloads.resumeDataSuffix) }
        XCTAssertEqual(resumeLeft, [], "Cancel left resume data")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: world.downloadsFolder.path)) ?? [], [], "Cancel left a file to import")
    }

    /// A download whose book is already being added to the library when
    /// Cancel is pressed finishes, as Cancel says; those waiting to start
    /// stop, staying whoever's they were.
    func testCancelLetsADownloadBeingAddedFinish() async throws {
        let world = try FeedTestWorld(self, label: "FeedProgressCancelAdding")
        let audio = try FeedMediaFixtures.silentAAC()
        let feed = try await subscribe(world, episodes: [("ep-1", "Episode One", audio), ("ep-2", "Episode Two", audio)])
        let downloads = world.center.downloads
        var said: [String] = []
        downloads.beforeCommit = { _ in
            said.append(world.center.cancelEveryDownload())
        }

        world.center.download("guid:ep-1", of: feed.id)
        world.center.download("guid:ep-2", of: feed.id)
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(said, [
            "Stopped downloading “Episode Two”. “Episode One” is already being added to the library. "
                + FeedDownloadProgressWording.retryAfterCancel,
        ])
        let second = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-2"))
        XCTAssertEqual(second.state, .notDownloaded)
        XCTAssertNotEqual(second.downloadOrigin, .listener)
        XCTAssertFalse(downloads.progress.state.isRunning)
        XCTAssertEqual(world.server.requests(to: "/audio/ep-2.m4a"), [], "a download Cancel stopped was fetched")
    }

    /// A feed whose only download Cancel let finish, its book already being
    /// added, is paused too, so its end asks the rule for nothing more; with
    /// nothing stopped, Cancel says only that it finishes (FR14).
    func testAFeedWhoseDownloadFinishesAfterCancelIsPausedToo() async throws {
        let world = try FeedTestWorld(self, label: "FeedProgressCancelFinishing")
        let audio = try FeedMediaFixtures.silentAAC()
        let feed = try await subscribe(world, episodes: [("ep-1", "Episode One", audio)])
        var said: [String] = []
        world.center.downloads.beforeCommit = { _ in
            said.append(world.center.cancelEveryDownload())
        }

        world.center.downloads.download("guid:ep-1", of: feed.id, origin: .window)
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(said, ["“Episode One” is already being added to the library."])
        XCTAssertEqual(world.center.rulePauses, [feed.id: .untilNextCheck])
    }

    /// The next launch ends Cancel's pause: its first pass of the newest-N
    /// rule downloads the newest Cancel stopped (FR14).
    func testTheNextLaunchDownloadsWhatCancelStopped() async throws {
        let world = try FeedTestWorld(self, label: "FeedProgressCancelLaunch")
        let audio = try FeedMediaFixtures.silentAAC()
        let feed = try await subscribe(world, episodes: [("ep-1", "Episode One", audio)])
        var slow = FeedMediaFixtures.file(audio, mimeType: "audio/mp4")
        slow.chunkSize = max(1, audio.count / 20)
        slow.pause = 0.05
        world.server.serve("/audio/ep-1.m4a", slow)
        world.center.downloads.download("guid:ep-1", of: feed.id, origin: .window)
        world.center.cancelEveryDownload()
        await waitFor("the download under way stops") { !world.center.downloads.isDownloading("guid:ep-1", of: feed.id) }
        await FeedTestWorld.finish(world.center)
        world.server.serve("/audio/ep-1.m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))

        let next = await world.relaunch(self)

        XCTAssertEqual(next.rulePauses, [:])
        let book = try await downloadedBook(world, center: next, feed: feed, item: "guid:ep-1")
        XCTAssertEqual(next.store.record(of: feed.id)?.item("guid:ep-1")?.downloadOrigin, .window)
        XCTAssertEqual(book.feedLink?.feedID, feed.id)
    }

    /// An article stopped before its book is written is not written: its
    /// page's fetch stopping does not make its summary its book.
    func testAnArticleStoppedBeforeItsBookIsWrittenIsNotWritten() async throws {
        let world = try FeedTestWorld(self, label: "FeedProgressCancelArticle")
        let items = [FeedXML.Item(guid: "post-1", title: "A short note", published: world.day(-1),
                                  description: "<p>Read the rest on the site.</p>", link: world.server.url("/posts/1").absoluteString)]
        world.server.serve("/posts/1", StubResponse(headers: ["Content-Type": "text/html"], body: Data("<html><body><article><p>The whole note.</p></article></body></html>".utf8)))
        world.server.serve("/feed.xml", .feed(FeedXML.rss(title: "Corkboard News", items: items)))
        let feed = try await world.subscribe("/feed.xml")

        world.center.download("guid:post-1", of: feed.id)
        world.center.cancelDownload("guid:post-1", of: feed.id)
        await waitFor("the article's download stops") { !world.center.downloads.isDownloading("guid:post-1", of: feed.id) }

        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:post-1")?.state, .notDownloaded)
        XCTAssertNil(world.library.feedItemRows(of: feed.id).downloaded["guid:post-1"], "the stopped article was written")
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
