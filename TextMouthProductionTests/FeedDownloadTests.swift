import Combine
import UniformTypeIdentifiers
import XCTest
@testable import TextMouth

/// Downloading feed items (FR03), against a stub server: an episode becomes
/// an audiobook in its feed's folder through the import pipeline, a video
/// episode too, and an article an HTML book; progress is published as the
/// bytes arrive; a download that stops partway goes on from where it
/// stopped; failures keep their reason; downloads run one at a time;
/// opening an item downloads it first; and quitting keeps each download's
/// place for the next launch. No episode is ever played.
@MainActor
final class FeedDownloadTests: XCTestCase {

    // MARK: - Episodes

    /// An episode downloads into the feed's folder as an audiobook, named
    /// after the item and its show, its record linking it to the item, and
    /// the item linking to it.
    func testAnEpisodeBecomesAnAudiobookInTheFeedsFolder() async throws {
        let world = try FeedTestWorld(self, label: "FeedEpisode")
        let audio = try FeedMediaFixtures.silentAAC()
        world.server.serve("/audio/1.m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        let feed = try await subscribe(world, enclosure: "/audio/1.m4a", type: "audio/x-m4a")
        var events: [FeedEvent] = []
        let subscription = world.center.events.sink { events.append($0) }
        defer { subscription.cancel() }
        // Other tests download an "Episode One" too, so the lines are
        // counted before and after.
        let finished = "FEED_DOWNLOAD_FINISHED: Episode One (The Tactile Atlas)"
        let finishedBefore = debugLogLines(containing: finished).count

        world.center.download("guid:ep-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(book.title, "Episode One")
        XCTAssertEqual(book.author, "The Tactile Atlas")
        XCTAssertEqual(book.audioAlbum, "The Tactile Atlas")
        XCTAssertEqual(book.format, .audio)
        // A feed item's: in its feed's own folder, outside the Library
        // folder, its row naming its feed and item and no folder (FR11).
        XCTAssertEqual(book.folderPath, "")
        XCTAssertEqual(book.feedLink, FeedBookLink(feedID: feed.id, itemID: "guid:ep-1"))
        XCTAssertEqual(book.bookFileURL.pathExtension, "m4a")
        XCTAssertEqual(book.dateAdded, world.clock.value)
        XCTAssertGreaterThan(book.audioDuration ?? 0, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
        XCTAssertTrue(book.tmbDirectory.path.hasPrefix(FeedPaths.itemsFolder(of: feed.id, in: TextMouthPaths.root).path + "/"))
        XCTAssertTrue(book.bookFileURL.path.hasPrefix(book.tmbDirectory.path + "/"))
        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.metadata.feedLink, FeedBookLink(feedID: feed.id, itemID: "guid:ep-1"))
        // Saved to the feed's index, never to library.json.
        LibraryPersistenceService.flushPendingSave()
        let index = try FeedIndexFiles.decoded(Data(contentsOf: FeedPaths.indexFile(of: feed.id, in: TextMouthPaths.root)))
        XCTAssertEqual(index.books.map(\.id), [book.id])
        let libraryJSON = try String(contentsOf: TextMouthPaths.libraryIndexFile, encoding: .utf8)
        XCTAssertFalse(libraryJSON.contains(book.id.uuidString), "library.json holds the download")
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state, .downloaded(bookID: book.id))
        XCTAssertEqual(events, [
            .downloadStarted(feedID: feed.id, itemID: "guid:ep-1"),
            .downloadFinished(feedID: feed.id, itemID: "guid:ep-1", bookID: book.id),
        ])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: world.downloadsFolder.path), [])
        XCTAssertEqual(debugLogLines(containing: finished).count, finishedBefore + 1)
    }

    /// A video episode downloads as an audiobook whose sound plays, and its
    /// package imports again, as a library rebuilt or a package added does:
    /// its video file is an audiobook's content, as Open Book reads it.
    func testAVideoEpisodeBecomesAnAudiobookWhosePackageImportsAgain() async throws {
        let world = try FeedTestWorld(self, label: "FeedVideo")
        let video = try await FeedMediaFixtures.silentVideo()
        world.server.serve("/video/tour.mp4", FeedMediaFixtures.file(video, mimeType: "video/mp4"))
        let feed = try await subscribe(world, enclosure: "/video/tour.mp4", type: "video/mp4")

        world.center.download("guid:ep-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(book.format, .audio)
        XCTAssertEqual(book.bookFileURL.pathExtension, "mp4")
        XCTAssertGreaterThan(book.audioDuration ?? 0, 0)
        XCTAssertEqual(BookFormat.detect(from: book.bookFileURL), .audio)
        let inspection = try FileImportService.inspectTMBPackage(at: book.tmbDirectory)
        XCTAssertEqual(inspection.info.metadata.feedLink, FeedBookLink(feedID: feed.id, itemID: "guid:ep-1"))

        // A copy of the package, taken elsewhere, imports as a book of its own.
        let elsewhere = try makeSandboxDirectory("FeedVideoPackage").appendingPathComponent(book.tmbDirectoryName)
        try FileManager.default.copyItem(at: book.tmbDirectory, to: elsewhere)
        try FileManager.default.removeItem(at: book.tmbDirectory)
        let imported = try FileImportService.importTMBPackageWithReport(from: elsewhere).book
        addTeardownBlock { try? FileManager.default.removeItem(at: imported.tmbDirectory) }

        XCTAssertEqual(imported.id, book.id)
        XCTAssertEqual(imported.format, .audio)
        XCTAssertEqual(imported.bookFileURL.pathExtension, "mp4")
        XCTAssertEqual(try Data(contentsOf: imported.bookFileURL), video)
    }

    /// Open Book takes a video file, MPEG-4, M4V, or QuickTime, and imports
    /// it as an audiobook whose sound plays; feeds still tell a video
    /// enclosure from an audio one by its extension alone.
    func testAVideoFileOpensAsAnAudiobook() async throws {
        let world = try FeedTestWorld(self, label: "FeedVideoOpen")
        let video = try await FeedMediaFixtures.silentVideo()
        let source = try makeSandboxDirectory("FeedVideoSource").appendingPathComponent("Harbour Tour.mp4")
        try video.write(to: source)

        let book = try FileImportService.importFileWithReport(from: source, toFolder: world.folder.path).book

        XCTAssertEqual(book.format, .audio)
        XCTAssertEqual(book.bookFileURL.pathExtension, "mp4")
        XCTAssertEqual(book.folderPath, world.folder.path)
        XCTAssertGreaterThan(book.audioDuration ?? 0, 0)
        for name in ["Tour.mp4", "Tour.M4V", "Tour.mov"] {
            XCTAssertEqual(BookFormat.detect(from: URL(fileURLWithPath: "/Videos/\(name)")), .audio, name)
        }
        let types = FileImportService.supportedTypes
        XCTAssertTrue(types.contains(.mpeg4Movie))
        XCTAssertTrue(types.contains(.quickTimeMovie))
        XCTAssertTrue(types.contains { $0.identifier == "com.apple.m4v-video" })
        let address = try XCTUnwrap(URL(string: "https://atlas.example/video/tour.mp4"))
        XCTAssertEqual(FeedMediaKind.of(mimeType: nil, url: address), .video)
        XCTAssertEqual(FeedMediaKind.of(mimeType: "audio/mp4", url: address), .audio)
        XCTAssertFalse(FeedMediaKind.audioExtensions.contains("mp4"))
    }

    /// Progress is published in the item's state as the bytes arrive, in
    /// whole percents that only grow, worded as a cloud download's is.
    func testProgressIsPublishedAsTheBytesArrive() async throws {
        let world = try FeedTestWorld(self, label: "FeedProgress")
        var file = FeedMediaFixtures.file(try FeedMediaFixtures.silentAAC(duration: 2), mimeType: "audio/mp4")
        file.chunkSize = max(1, file.body.count / 4 + 1)
        file.pause = 0.05
        world.server.serve("/audio/1.m4a", file)
        let feed = try await subscribe(world, enclosure: "/audio/1.m4a", type: "audio/mp4")
        var percents: [Int] = []
        var notes: [String] = []
        let subscription = world.center.store.$records.sink { records in
            if case .downloading(let progress)? = records[feed.id]?.item("guid:ep-1")?.state {
                percents.append(progress.percent)
                notes.append(FeedItemState.downloading(progress).spokenNote)
            }
        }
        defer { subscription.cancel() }

        world.center.download("guid:ep-1", of: feed.id)
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        XCTAssertEqual(percents.first, 0, "a waiting download did not say 0 percent")
        XCTAssertGreaterThan(Set(percents).count, 2, "too few steps of progress: \(percents)")
        XCTAssertEqual(percents, percents.sorted(), "progress went back: \(percents)")
        XCTAssertTrue(percents.allSatisfy { $0 < 100 }, "100 percent was said before the book was in")
        XCTAssertTrue(notes.contains("Downloading, 0 percent"))
    }

    /// A download that stops partway keeps its resume data in this Mac's
    /// folder and fails with its reason; the next download goes on from where
    /// it stopped, asking only for the rest, and the resume data goes.
    func testADownloadThatStopsPartwayGoesOnFromWhereItStopped() async throws {
        let world = try FeedTestWorld(self, label: "FeedResume")
        let audio = try FeedMediaFixtures.silentAAC(duration: 2)
        var broken = FeedMediaFixtures.file(audio, mimeType: "audio/mp4")
        broken.chunkSize = audio.count / 2
        broken.failAfterBytes = audio.count / 2
        world.server.serve("/audio/1.m4a", broken, FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        let feed = try await subscribe(world, enclosure: "/audio/1.m4a", type: "audio/mp4")
        let resumeFile = world.center.downloads.resumeDataFile(for: "guid:ep-1", of: feed.id)

        world.center.download("guid:ep-1", of: feed.id)
        await waitFor("the download fails") {
            world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state.failureReason != nil
        }
        XCTAssertEqual(
            world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state.failureReason?.hasPrefix("\(world.server.host) couldn't be reached"),
            true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: resumeFile.path), "no resume data was kept")
        XCTAssertTrue(resumeFile.path.hasPrefix(world.resumeFolder.path))

        world.center.download("guid:ep-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")

        let resumed = try XCTUnwrap(world.server.requests(to: "/audio/1.m4a").last)
        XCTAssertEqual(resumed.value(forHTTPHeaderField: "Range"), "bytes=\(audio.count / 2)-")
        XCTAssertEqual(try Data(contentsOf: book.bookFileURL), audio, "the resumed file differs from the original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: resumeFile.path), "the resume data stayed")
    }

    /// A download that fails keeps its reason, in the record too, and can be
    /// tried again.
    func testAFailedDownloadKeepsItsReasonAndCanBeTriedAgain() async throws {
        let world = try FeedTestWorld(self, label: "FeedFailedDownload")
        world.server.serve(
            "/audio/1.m4a",
            StubResponse(status: 404),
            FeedMediaFixtures.file(try FeedMediaFixtures.silentAAC(), mimeType: "audio/mp4")
        )
        let feed = try await subscribe(world, enclosure: "/audio/1.m4a", type: "audio/mp4")

        world.center.download("guid:ep-1", of: feed.id)
        await waitFor("the download fails") {
            world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state.failureReason != nil
        }
        let failed = world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state
        XCTAssertEqual(failed, .failed("The server says the file is gone."))
        XCTAssertEqual(failed?.visibleNote, "Download Failed")
        await world.center.store.flush()
        let saved = try FeedRecordCoding.decoder().decode(
            FeedRecord.self,
            from: Data(contentsOf: FeedPaths.recordFile(of: feed.id, in: world.recordsFolder))
        )
        XCTAssertEqual(saved.item("guid:ep-1")?.state, failed)

        world.center.download("guid:ep-1", of: feed.id)
        _ = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
    }

    /// Without room on the library's disk for the episode and the space
    /// TextMouth keeps free, the download fails before anything is fetched;
    /// a file of a kind TextMouth does not play fails before it is fetched
    /// too.
    func testDownloadsThatCannotBeKeptFailBeforeTheyStart() async throws {
        let world = try FeedTestWorld(self, label: "FeedNoRoom")
        world.freeSpace.value = 1_500_000_000
        let items = [
            FeedXML.Item(guid: "big", title: "Big", published: world.day(-1),
                         enclosure: world.server.url("/audio/big.mp3").absoluteString, enclosureLength: 600_000_000),
            FeedXML.Item(guid: "ogg", title: "Ogg", published: world.day(-2),
                         enclosure: world.server.url("/audio/talk.ogg").absoluteString, enclosureType: "audio/ogg"),
        ]
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: items)))
        let feed = try await world.subscribe("/feed.xml")

        world.center.download("guid:big", of: feed.id)
        world.center.download("guid:ogg", of: feed.id)
        await waitFor("both downloads fail") {
            world.center.listedItems(of: feed.id).allSatisfy { $0.state.failureReason != nil }
        }

        let items2 = world.center.store.record(of: feed.id)
        XCTAssertEqual(items2?.item("guid:big")?.state.failureReason, "There isn't room on this Mac for this episode (600 MB).")
        XCTAssertEqual(items2?.item("guid:ogg")?.state.failureReason, "TextMouth can't play this kind of file (audio/ogg).")
        XCTAssertEqual(world.server.requests(to: "/audio/big.mp3"), [])
        XCTAssertEqual(world.server.requests(to: "/audio/talk.ogg"), [])
    }

    // MARK: - Articles

    /// An article whose feed gives its whole text becomes an HTML book: its
    /// title as a heading, the show and date, the text, and its link.
    func testAnArticleBecomesAnHTMLBook() async throws {
        let world = try FeedTestWorld(self, label: "FeedArticle")
        let paragraphs = (1...30).map { "<p>Paragraph \($0) of the release notes says what changed and why it matters.</p>" }
        let items = [FeedXML.Item(guid: "post-1", title: "Corkboard 7.1.2 Released", published: world.day(-1),
                                  description: paragraphs.joined(), link: "https://news.example/corkboard-7-1-2")]
        world.server.serve("/feed.xml", .feed(FeedXML.rss(title: "Corkboard News", items: items)))
        let feed = try await world.subscribe("/feed.xml")

        world.center.download("guid:post-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:post-1")

        XCTAssertEqual(book.format, .html)
        XCTAssertEqual(book.title, "Corkboard 7.1.2 Released")
        let html = try String(contentsOf: book.bookFileURL, encoding: .utf8)
        XCTAssertTrue(html.contains("<h1>Corkboard 7.1.2 Released</h1>"))
        XCTAssertTrue(html.contains("Paragraph 30 of the release notes"))
        XCTAssertTrue(html.contains("<a href=\"https://news.example/corkboard-7-1-2\">news.example</a>"))
        let markdown = try String(contentsOf: TextMouthPaths.contentMarkdownPath(in: book.tmbDirectory), encoding: .utf8)
        XCTAssertTrue(markdown.contains("Paragraph 1 of the release notes"))
        XCTAssertEqual(world.server.requests.filter { $0.url?.host == "news.example" }, [], "a whole article fetched its page")
    }

    /// An article the feed gives only a summary of reads its web page's
    /// article instead, when that is longer; when the page can't be fetched,
    /// the summary is its book.
    func testAShortArticleReadsItsWebPage() async throws {
        let world = try FeedTestWorld(self, label: "FeedArticlePage")
        let words = (1...300).map { "word\($0)" }.joined(separator: " ")
        let page = "<html><body><nav>Home About</nav><article><h2>The whole story</h2><p>\(words)</p></article></body></html>"
        world.server.serve("/posts/1", StubResponse(headers: ["Content-Type": "text/html"], body: Data(page.utf8)))
        world.server.serve("/posts/2", StubResponse(status: 500))
        let items = [
            FeedXML.Item(guid: "post-1", title: "First", published: world.day(-1), description: "A short summary [...]",
                         link: world.server.url("/posts/1").absoluteString),
            FeedXML.Item(guid: "post-2", title: "Second", published: world.day(-2), description: "Another short summary",
                         link: world.server.url("/posts/2").absoluteString),
        ]
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: items)))
        let feed = try await world.subscribe("/feed.xml")

        world.center.download("guid:post-1", of: feed.id)
        world.center.download("guid:post-2", of: feed.id)
        let first = try await downloadedBook(world, feed: feed, item: "guid:post-1")
        let second = try await downloadedBook(world, feed: feed, item: "guid:post-2")

        let firstHTML = try String(contentsOf: first.bookFileURL, encoding: .utf8)
        XCTAssertTrue(firstHTML.contains("word300"))
        XCTAssertTrue(firstHTML.contains("The whole story"))
        XCTAssertFalse(firstHTML.contains("Home About"), "the page's navigation was read")
        let secondHTML = try String(contentsOf: second.bookFileURL, encoding: .utf8)
        XCTAssertTrue(secondHTML.contains("Another short summary"))
    }

    // MARK: - The Queue

    /// Downloads run one at a time, in the order asked: every one waiting
    /// says Downloading 0%, and each request starts once the one before it
    /// has finished.
    func testDownloadsRunOneAtATime() async throws {
        let world = try FeedTestWorld(self, label: "FeedQueue")
        let audio = try FeedMediaFixtures.silentAAC()
        var slow = FeedMediaFixtures.file(audio, mimeType: "audio/mp4")
        slow.pause = 0.1
        let items = (1...3).map { number -> FeedXML.Item in
            world.server.serve("/audio/\(number).m4a", slow)
            return FeedXML.Item(guid: "ep-\(number)", title: "Episode \(number)", published: world.day(-Double(number)),
                                enclosure: world.server.url("/audio/\(number).m4a").absoluteString, enclosureType: "audio/mp4")
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: items)))
        let feed = try await world.subscribe("/feed.xml")

        for number in 1...3 {
            world.center.download("guid:ep-\(number)", of: feed.id)
        }
        XCTAssertEqual(world.center.downloads.queue.map(\.itemID), ["guid:ep-2", "guid:ep-3"])
        XCTAssertEqual(world.center.downloads.current?.itemID, "guid:ep-1")
        for item in world.center.listedItems(of: feed.id) {
            XCTAssertEqual(item.state.visibleNote, "Downloading 0%")
        }
        for number in 1...3 {
            _ = try await downloadedBook(world, feed: feed, item: "guid:ep-\(number)")
        }

        let order = world.server.requests.compactMap(\.url?.path).filter { $0.hasPrefix("/audio/") }
        XCTAssertEqual(order, ["/audio/1.m4a", "/audio/2.m4a", "/audio/3.m4a"])
    }

    /// Opening an item that is not downloaded downloads it first, ahead of
    /// those waiting, and opens its book once it is in the library; opening
    /// it again opens it at once.
    func testOpeningAnItemDownloadsItFirst() async throws {
        let world = try FeedTestWorld(self, label: "FeedOpen")
        let audio = try FeedMediaFixtures.silentAAC()
        world.server.serve("/audio/1.m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        let feed = try await subscribe(world, enclosure: "/audio/1.m4a", type: "audio/mp4")
        var opened: [UUID] = []
        world.library.readerOpener = { opened.append($0) }

        world.center.open("guid:ep-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        await waitFor("the book opens") { !opened.isEmpty }
        XCTAssertEqual(opened, [book.id])
        let asked = world.server.requests.count

        world.center.open("guid:ep-1", of: feed.id)
        XCTAssertEqual(opened, [book.id, book.id])
        XCTAssertEqual(world.server.requests.count, asked)
    }

    /// Cancelling a download under way stops it, keeps nothing of it, and
    /// leaves the item not downloaded; one waiting leaves the queue.
    func testCancellingStopsADownload() async throws {
        let world = try FeedTestWorld(self, label: "FeedCancel")
        var slow = FeedMediaFixtures.file(try FeedMediaFixtures.silentAAC(duration: 2), mimeType: "audio/mp4")
        slow.chunkSize = max(1, slow.body.count / 10)
        slow.pause = 0.1
        world.server.serve("/audio/1.m4a", slow)
        let feed = try await subscribe(world, enclosure: "/audio/1.m4a", type: "audio/mp4")

        world.center.download("guid:ep-1", of: feed.id)
        await waitFor("the download is under way") { world.server.requests(to: "/audio/1.m4a").count == 1 }
        world.center.cancelDownload("guid:ep-1", of: feed.id)
        await waitFor("the download stops") { world.center.downloads.current == nil }

        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state, .notDownloaded)
        XCTAssertEqual(world.library.library.books, [])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: world.center.downloads.resumeDataFile(for: "guid:ep-1", of: feed.id).path
        ))
    }

    // MARK: - Automatic Downloads

    /// With automatic downloads on, a refresh downloads the items it finds
    /// new, on a network without data limits; with them off, or for the
    /// back catalog a subscription finds, nothing downloads by itself.
    func testNewItemsDownloadByThemselvesWhenAsked() async throws {
        let world = try FeedTestWorld(self, label: "FeedAutoDownload")
        FeedSettings.autoDownloadPreference.write(true, to: world.preferences)
        let audio = try FeedMediaFixtures.silentAAC()
        world.server.serve("/audio/old.m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        world.server.serve("/audio/new.m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        let old = FeedXML.Item(guid: "old", title: "Old", published: world.day(-1),
                               enclosure: world.server.url("/audio/old.m4a").absoluteString, enclosureType: "audio/mp4")
        let new = FeedXML.Item(guid: "new", title: "New", published: world.day(0.5),
                               enclosure: world.server.url("/audio/new.m4a").absoluteString, enclosureType: "audio/mp4")
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [old])), .feed(FeedXML.rss(items: [new, old])))
        let feed = try await world.subscribe("/feed.xml")
        XCTAssertNil(world.center.downloads.current, "the back catalog downloaded by itself")
        world.advance(by: 86_400)

        _ = await world.center.refreshAll(origin: .scheduled)
        _ = try await downloadedBook(world, feed: feed, item: "guid:new")

        XCTAssertEqual(world.server.requests(to: "/audio/old.m4a"), [])
        XCTAssertEqual(world.server.requests(to: "/audio/new.m4a").map(\.allowsExpensiveNetworkAccess), [false])
    }

    /// An automatic download a network with data limits refuses says it
    /// waits for one without them, and is tried again at the next refresh
    /// TextMouth makes by itself that reaches the network, since such a
    /// refresh is refused on that network too. A refresh the listener asks
    /// for says nothing of the network's limits, and one put off by them
    /// shows they are still there: neither tries it again.
    func testAnAutomaticDownloadPutOffByAMeteredNetworkIsTriedAgainLater() async throws {
        let world = try FeedTestWorld(self, label: "FeedMetered")
        FeedSettings.autoDownloadPreference.write(true, to: world.preferences)
        let audio = try FeedMediaFixtures.silentAAC()
        world.server.serve("/audio/new.m4a", .refusedOnAMeteredNetwork(), FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        let old = FeedXML.Item(guid: "old", title: "Old", published: world.day(-1),
                               enclosure: world.server.url("/audio/old.m4a").absoluteString, enclosureType: "audio/mp4")
        let new = FeedXML.Item(guid: "new", title: "New", published: world.day(0.5),
                               enclosure: world.server.url("/audio/new.m4a").absoluteString, enclosureType: "audio/mp4")
        let withNew = StubResponse.feed(FeedXML.rss(items: [new, old]))
        world.server.serve(
            "/feed.xml",
            .feed(FeedXML.rss(items: [old])), withNew, withNew, .refusedOnAMeteredNetwork(), withNew
        )
        let feed = try await world.subscribe("/feed.xml")
        world.advance(by: 86_400)

        _ = await world.center.refreshAll(origin: .scheduled)
        await waitFor("the new episode's download is put off") {
            world.center.store.record(of: feed.id)?.item("guid:new")?.state.failureReason != nil
                && world.center.downloads.current == nil
        }
        XCTAssertEqual(
            world.center.store.record(of: feed.id)?.item("guid:new")?.state.failureReason,
            "“New” waits for a network without data limits to download by itself."
        )
        XCTAssertEqual(world.center.downloads.putOff.map(\.itemID), ["guid:new"])

        _ = await world.center.refresh(feed.id)
        let skipped = await world.center.refreshAll(origin: .scheduled)
        XCTAssertEqual(skipped.reports.map(\.outcome), [.skipped])
        XCTAssertEqual(world.server.requests(to: "/audio/new.m4a").count, 1, "the download was tried again too soon")
        XCTAssertEqual(world.center.downloads.putOff.map(\.itemID), ["guid:new"])

        _ = await world.center.refreshAll(origin: .scheduled)
        _ = try await downloadedBook(world, feed: feed, item: "guid:new")

        XCTAssertEqual(world.server.requests(to: "/audio/new.m4a").map(\.allowsExpensiveNetworkAccess), [false, false])
        XCTAssertTrue(world.center.downloads.putOff.isEmpty)
        XCTAssertEqual(world.server.requests(to: "/audio/old.m4a"), [])
    }

    // MARK: - Quitting

    /// Quitting while an episode downloads and another waits holds the quit
    /// until both have kept their place: the one under way keeps its resume
    /// data in this Mac's folder, both are listed there in order, and the
    /// quit is answered once, with yes. At the next launch both download
    /// again, the first going on from where it stopped, asking only for the
    /// rest, and the list is gone.
    func testDownloadsUnderWayAtQuitGoOnAtTheNextLaunch() async throws {
        let world = try FeedTestWorld(self, label: "FeedQuitResume")
        let audio = try FeedMediaFixtures.silentAAC(duration: 4)
        var slow = FeedMediaFixtures.file(audio, mimeType: "audio/mp4")
        slow.chunkSize = max(1, audio.count / 20)
        slow.pause = 0.1
        world.server.serve("/audio/1.m4a", slow, FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        world.server.serve("/audio/2.m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
        await world.start()
        let items = (1...2).map { number in
            FeedXML.Item(guid: "ep-\(number)", title: "Episode \(number)", published: world.day(-Double(number)),
                         enclosure: world.server.url("/audio/\(number).m4a").absoluteString, enclosureType: "audio/mp4")
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: items)))
        let feed = try await world.subscribe("/feed.xml")
        world.center.download("guid:ep-1", of: feed.id)
        world.center.download("guid:ep-2", of: feed.id)
        await waitFor("some of the first episode arrives") {
            guard case .downloading(let progress)? = world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state else {
                return false
            }
            return progress.completedBytes > 0
        }

        var replies: [Bool] = []
        XCTAssertTrue(FeedQuitHold.hold(world.center.downloads) { replies.append($0) })
        await waitFor("the quit is answered") { !replies.isEmpty }

        XCTAssertEqual(replies, [true])
        let downloads = world.center.downloads
        XCTAssertTrue(downloads.isStoppedForQuit)
        let resumeFile = downloads.resumeDataFile(for: "guid:ep-1", of: feed.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resumeFile.path), "the download under way kept no resume data")
        let listed = try JSONDecoder().decode(
            [FeedDownloadManager.SavedDownload].self,
            from: Data(contentsOf: downloads.savedAtQuitFile)
        )
        XCTAssertEqual(listed, [
            FeedDownloadManager.SavedDownload(feedID: feed.id, itemID: "guid:ep-1", origin: .listener),
            FeedDownloadManager.SavedDownload(feedID: feed.id, itemID: "guid:ep-2", origin: .listener),
        ])
        XCTAssertEqual(world.server.requests(to: "/audio/2.m4a"), [], "a download started while TextMouth quit")
        // A second hold finds nothing left to hold.
        XCTAssertFalse(FeedQuitHold.hold(downloads) { _ in XCTFail("a stopped engine held the quit again") })
        await world.center.store.flush()

        let relaunched = await world.relaunch(self)
        let first = try await downloadedBook(world, center: relaunched, feed: feed, item: "guid:ep-1")
        let second = try await downloadedBook(world, center: relaunched, feed: feed, item: "guid:ep-2")

        let resumed = try XCTUnwrap(world.server.requests(to: "/audio/1.m4a").last)
        let range = try XCTUnwrap(resumed.value(forHTTPHeaderField: "Range"), "the download started over")
        XCTAssertTrue(range.hasPrefix("bytes=") && range != "bytes=0-", range)
        XCTAssertEqual(try Data(contentsOf: first.bookFileURL), audio, "the resumed file differs from the original")
        XCTAssertEqual(try Data(contentsOf: second.bookFileURL), audio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: relaunched.downloads.savedAtQuitFile.path), "the list stayed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: resumeFile.path), "the resume data stayed")
    }

    /// A quit with no download waiting or running is not held, and the next
    /// launch finds nothing to ask for again.
    func testAQuitWithNoDownloadIsNotHeld() async throws {
        let world = try FeedTestWorld(self, label: "FeedQuitIdle")
        await world.start()

        XCTAssertFalse(FeedQuitHold.hold(world.center.downloads) { _ in XCTFail("an idle engine held the quit") })
        XCTAssertFalse(world.center.downloads.isStoppedForQuit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.center.downloads.savedAtQuitFile.path))

        let relaunched = await world.relaunch(self)
        XCTAssertNil(relaunched.downloads.current)
        XCTAssertTrue(relaunched.downloads.queue.isEmpty)
    }

    /// A download listed at quit is not asked for again at the next launch
    /// when its item was deleted meanwhile, or its feed is no longer
    /// subscribed; the list goes either way.
    func testTheNextLaunchSkipsItemsNoLongerWanted() async throws {
        let world = try FeedTestWorld(self, label: "FeedQuitSkipped")
        let items = (1...2).map { number in
            FeedXML.Item(guid: "ep-\(number)", title: "Episode \(number)", published: world.day(-Double(number)),
                         enclosure: world.server.url("/audio/\(number).m4a").absoluteString, enclosureType: "audio/mp4")
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: items)))
        let feed = try await world.subscribe("/feed.xml")
        let list = world.center.downloads.savedAtQuitFile
        try FileManager.default.createDirectory(at: list.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode([
            FeedDownloadManager.SavedDownload(feedID: feed.id, itemID: "guid:ep-1", origin: .automatic),
            FeedDownloadManager.SavedDownload(feedID: UUID(), itemID: "guid:ep-1", origin: .listener),
        ]).write(to: list)
        try world.center.deleteItem("guid:ep-1", of: feed.id)
        await world.center.store.flush()

        let relaunched = await world.relaunch(self)

        XCTAssertNil(relaunched.downloads.current, "a deleted item downloaded again")
        XCTAssertTrue(relaunched.downloads.queue.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: list.path), "the list stayed")
        XCTAssertEqual(world.server.requests(to: "/audio/1.m4a"), [])
    }

    // MARK: - Leftovers

    /// At start, the engine removes the finished downloads an interrupted
    /// import left waiting, and resume data older than a week.
    func testLeftoversAreSweptAtStart() async throws {
        let world = try FeedTestWorld(self, label: "FeedLeftovers")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: world.downloadsFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: world.resumeFolder, withIntermediateDirectories: true)
        let leftover = world.downloadsFolder.appendingPathComponent("\(UUID().uuidString).download")
        try Data("partial".utf8).write(to: leftover)
        let stale = world.resumeFolder.appendingPathComponent("stale.resume")
        let fresh = world.resumeFolder.appendingPathComponent("fresh.resume")
        try Data("old".utf8).write(to: stale)
        try Data("new".utf8).write(to: fresh)
        try fileManager.setAttributes([.modificationDate: world.clock.value.addingTimeInterval(-8 * 86_400)], ofItemAtPath: stale.path)
        try fileManager.setAttributes([.modificationDate: world.clock.value.addingTimeInterval(-86_400)], ofItemAtPath: fresh.path)

        await world.start()

        XCTAssertFalse(fileManager.fileExists(atPath: leftover.path))
        XCTAssertFalse(fileManager.fileExists(atPath: stale.path))
        XCTAssertTrue(fileManager.fileExists(atPath: fresh.path))
    }

    // MARK: - Helpers

    /// Starts `world`'s engine and subscribes it to a feed of one episode,
    /// "Episode One", whose file is at `enclosure` on the world's server.
    private func subscribe(_ world: FeedTestWorld, enclosure: String, type: String) async throws -> Feed {
        await world.start()
        let item = FeedXML.Item(guid: "ep-1", title: "Episode One", published: world.day(-1),
                                enclosure: world.server.url(enclosure).absoluteString, enclosureType: type)
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [item])))
        return try await world.subscribe("/feed.xml")
    }
}
