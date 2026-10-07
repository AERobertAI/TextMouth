import XCTest
@testable import TextMouth

/// The feed engine's models and records (FR03): an item's identity, its
/// download state and how its record writes it, the link from a book's
/// package record to its feed item, and the two stores: the records in the
/// data directory's Feeds folder, which sync, and this Mac's fetch details
/// in Caches, which never do.
@MainActor
final class FeedRecordTests: XCTestCase {

    // MARK: - Identity

    /// An item is known by its guid, else its enclosure's address, else its
    /// link and title, else a digest of its summary, each kind of key with a
    /// prefix of its own; a blank guid counts as none.
    func testIdentityFollowsGuidThenEnclosureThenLinkAndTitle() throws {
        let enclosure = try XCTUnwrap(URL(string: "https://cdn.example/show/7.mp3"))
        let link = try XCTUnwrap(URL(string: "https://show.example/7"))

        XCTAssertEqual(
            FeedItemIdentity.key(guid: " ep-7 ", enclosureURL: enclosure, link: link, title: "Seven", summaryHTML: nil),
            "guid:ep-7"
        )
        XCTAssertEqual(
            FeedItemIdentity.key(guid: "  ", enclosureURL: enclosure, link: link, title: "Seven", summaryHTML: nil),
            "enclosure:https://cdn.example/show/7.mp3"
        )
        XCTAssertEqual(
            FeedItemIdentity.key(guid: nil, enclosureURL: nil, link: link, title: " Seven ", summaryHTML: nil),
            "link:https://show.example/7\u{1F}Seven"
        )
        XCTAssertEqual(
            FeedItemIdentity.key(guid: nil, enclosureURL: nil, link: nil, title: "Seven", summaryHTML: nil),
            "link:\u{1F}Seven"
        )
        let bySummary = FeedItemIdentity.key(guid: nil, enclosureURL: nil, link: nil, title: "", summaryHTML: "<p>Only words</p>")
        XCTAssertTrue(bySummary.hasPrefix("summary:"))
        XCTAssertEqual(bySummary, FeedItemIdentity.key(guid: nil, enclosureURL: nil, link: nil, title: " ", summaryHTML: "<p>Only words</p>"))
        XCTAssertNotEqual(bySummary, FeedItemIdentity.key(guid: nil, enclosureURL: nil, link: nil, title: "", summaryHTML: "<p>Other words</p>"))
    }

    /// A guid that is an address is still a guid: it never matches the same
    /// address as an enclosure, and a link and title split differently never
    /// match each other.
    func testIdentityKindsNeverCollide() throws {
        let address = try XCTUnwrap(URL(string: "https://cdn.example/a.mp3"))
        XCTAssertNotEqual(
            FeedItemIdentity.key(guid: address.absoluteString, enclosureURL: nil, link: nil, title: "", summaryHTML: nil),
            FeedItemIdentity.key(guid: nil, enclosureURL: address, link: nil, title: "", summaryHTML: nil)
        )
        XCTAssertNotEqual(
            FeedItemIdentity.key(guid: nil, enclosureURL: nil, link: URL(string: "https://x.example/a"), title: "bc", summaryHTML: nil),
            FeedItemIdentity.key(guid: nil, enclosureURL: nil, link: URL(string: "https://x.example/ab"), title: "c", summaryHTML: nil)
        )
    }

    // MARK: - Enclosures

    /// An enclosure's kind comes from its MIME type's top level, and from
    /// its address's extension when the type is generic or missing; video
    /// counts as playable, and anything else does not.
    func testEnclosureKindComesFromTypeThenExtension() throws {
        func kind(_ type: String?, _ address: String) throws -> FeedMediaKind {
            FeedEnclosure(url: try XCTUnwrap(URL(string: address)), mimeType: type, length: nil).kind
        }
        XCTAssertEqual(try kind("audio/mpeg", "https://a.example/x"), .audio)
        XCTAssertEqual(try kind("Audio/X-M4A ", "https://a.example/x"), .audio)
        XCTAssertEqual(try kind("video/mp4", "https://a.example/x"), .video)
        XCTAssertEqual(try kind("application/octet-stream", "https://a.example/x.m4b?token=1"), .audio)
        XCTAssertEqual(try kind(nil, "https://a.example/x.MOV"), .video)
        XCTAssertEqual(try kind("application/pdf", "https://a.example/x.pdf"), .other)
        XCTAssertTrue(FeedEnclosure(url: try XCTUnwrap(URL(string: "https://a.example/v.m4v")), mimeType: nil, length: nil).isPlayable)

        let article = FeedItem(id: "guid:1", title: "Notes", firstSeen: Date())
        XCTAssertTrue(article.isArticle)
    }

    // MARK: - Download State

    /// A download's notes are the cloud downloads' own: "Downloading 40%" to
    /// see and "Downloading, 40 percent" to hear; the others say what they
    /// are, the same both ways.
    func testStateNotesShareTheCloudWording() {
        let progress = BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: 40, totalBytes: 100)
        XCTAssertEqual(FeedItemState.downloading(progress).visibleNote, "Downloading 40%")
        XCTAssertEqual(FeedItemState.downloading(progress).spokenNote, "Downloading, 40 percent")
        XCTAssertEqual(FeedItemState.notDownloaded.spokenNote, "Not Downloaded")
        XCTAssertEqual(FeedItemState.failed("The server says the file is gone.").visibleNote, "Download Failed")
        XCTAssertEqual(FeedItemState.downloaded(bookID: UUID()).spokenNote, "Downloaded")
        XCTAssertEqual(FeedItemState.failed("Gone.").failureReason, "Gone.")
    }

    /// A record writes a download in progress as not downloaded, and reads
    /// back failures and downloads as they were; a state it can't make sense
    /// of reads as not downloaded instead of failing the record.
    func testStatesRoundTripExceptADownloadInProgress() throws {
        let bookID = UUID()
        let progress = BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: 1, totalBytes: 2)
        for (state, expected) in [
            (FeedItemState.notDownloaded, FeedItemState.notDownloaded),
            (.downloading(progress), .notDownloaded),
            (.failed("The server didn't answer."), .failed("The server didn't answer.")),
            (.downloaded(bookID: bookID), .downloaded(bookID: bookID)),
        ] {
            let data = try JSONEncoder().encode(state)
            XCTAssertEqual(try JSONDecoder().decode(FeedItemState.self, from: data), expected)
        }
        for odd in [#"{"kind": "streaming"}"#, #"{"kind": "downloaded"}"#, #"{}"#] {
            XCTAssertEqual(try JSONDecoder().decode(FeedItemState.self, from: Data(odd.utf8)), .notDownloaded, odd)
        }
    }

    /// A record round-trips through its file with its format version, and
    /// its durable form, which is what the file holds, has no download in
    /// progress.
    func testARecordRoundTripsAndItsDurableFormHasNoDownloadInProgress() throws {
        let progress = BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: 1, totalBytes: 2)
        var record = Self.record(itemCount: 2)
        record.items[0].state = .downloading(progress)
        record.items[1].playedDate = Date(timeIntervalSince1970: 1_800_000_000)

        let data = try FeedRecordCoding.encoder().encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["formatVersion"] as? Int, FeedRecord.currentFormatVersion)
        let decoded = try FeedRecordCoding.decoder().decode(FeedRecord.self, from: data)

        XCTAssertEqual(decoded, record.durable)
        XCTAssertEqual(decoded.items[0].state, .notDownloaded)
        XCTAssertEqual(record.durable.items[1], record.items[1])
    }

    /// A record keeps its feed's size, with whether the feed lists more
    /// entries than TextMouth reads; a record written before TextMouth
    /// recorded the size loads without it, as a new subscription is before
    /// its feed is read. The size exceeds a number kept only when the feed
    /// lists more.
    func testAFeedsSizeRoundTripsAndAnOlderRecordLoadsWithoutIt() throws {
        var record = Self.record(itemCount: 2)
        XCTAssertNil(record.feed.entryTotal, "a subscription knew its feed's size before reading it")
        record.feed.entryTotal = FeedEntryTotal(count: 2_000, listsMore: true)
        let data = try FeedRecordCoding.encoder().encode(record)
        XCTAssertEqual(try FeedRecordCoding.decoder().decode(FeedRecord.self, from: data), record)

        // The same file as a TextMouth that recorded no size wrote it.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var feed = try XCTUnwrap(object["feed"] as? [String: Any])
        XCTAssertNotNil(feed.removeValue(forKey: "entryTotal"), "the record wrote no size")
        object["feed"] = feed
        let older = try FeedRecordCoding.decoder().decode(FeedRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(older.feed.entryTotal)
        record.feed.entryTotal = nil
        XCTAssertEqual(older, record)

        XCTAssertTrue(FeedEntryTotal(count: 381).exceeds(10))
        XCTAssertFalse(FeedEntryTotal(count: 10).exceeds(10))
        XCTAssertFalse(FeedEntryTotal(count: 5).exceeds(10), "a feed listing fewer entries than the record keeps")
        XCTAssertTrue(FeedEntryTotal(count: 2_000, listsMore: true).exceeds(2_000))
    }

    /// The items a library lists leave out the ones the listener deleted,
    /// which the record keeps so a refresh never brings them back.
    func testListedItemsLeaveOutDeletedOnes() {
        var record = Self.record(itemCount: 3)
        record.items[1].deletedDate = Date()
        XCTAssertEqual(record.listedItems.map(\.id), [record.items[0].id, record.items[2].id])
    }

    // MARK: - The Link From a Book

    /// A book's package record keeps the feed item it came from through
    /// every save of the book's state, though the library row never holds
    /// it; an ordinary book's record names none, and writes no key for it.
    func testTheFeedLinkSurvivesSavesOfTheBooksState() throws {
        let folder = try makeSandboxDirectory("FeedLink")
        let package = folder.appendingPathComponent("Episode.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let book = Book(
            title: "Episode",
            format: .audio,
            filePath: package.appendingPathComponent("episode.mp3").path,
            md5Hash: "abc",
            folderPath: "",
            tmbDirectoryName: package.lastPathComponent
        )
        var info = book.makeBookInfo()
        XCTAssertNil(info.metadata.feedLink)
        let link = FeedBookLink(feedID: UUID(), itemID: "guid:ep-1")
        info.metadata.feedLink = link
        try info.save(to: package)

        var moved = book
        moved.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: 120)
        try moved.saveBookInfoThrowing(inPackageAt: package)

        XCTAssertEqual(try BookInfo.load(from: package).metadata.feedLink, link)

        let ordinary = try FeedRecordCoding.encoder().encode(book.makeBookInfo())
        XCTAssertFalse(String(decoding: ordinary, as: UTF8.self).contains("feedLink"))
    }

    // MARK: - The Record Store

    /// A new subscription's record is written to Feeds/<feed ID>.json, a
    /// change of a download's progress alone writes nothing, a durable
    /// change writes the file again, and removing the feed deletes it.
    func testRecordsAreWrittenOnlyWhenTheirDurableFormChanges() async throws {
        let folder = try makeSandboxDirectory("FeedStore").appendingPathComponent("Feeds", isDirectory: true)
        let store = FeedStore(location: .folder(folder))
        let record = Self.record(itemCount: 1)
        let file = FeedPaths.recordFile(of: record.feed.id, in: folder)

        store.add(record)
        await store.flush()
        XCTAssertEqual(try FeedRecordCoding.decoder().decode(FeedRecord.self, from: Data(contentsOf: file)), record)
        let written = try Data(contentsOf: file)

        try FileManager.default.removeItem(at: file)
        let progress = BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: 5, totalBytes: 10)
        store.updateItem(record.items[0].id, of: record.feed.id) { $0.state = .downloading(progress) }
        await store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "progress alone was written")
        XCTAssertEqual(store.record(of: record.feed.id)?.items[0].state, .downloading(progress))

        store.updateItem(record.items[0].id, of: record.feed.id) { $0.playedDate = Date() }
        await store.flush()
        XCTAssertNotEqual(try Data(contentsOf: file), written)
        XCTAssertEqual(
            try FeedRecordCoding.decoder().decode(FeedRecord.self, from: Data(contentsOf: file)).items[0].state,
            .notDownloaded
        )

        store.remove(record.feed.id)
        await store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(store.record(of: record.feed.id))
    }

    /// Loading reads every record named by a feed's ID, takes the ID from
    /// the file's name, leaves a sync service's conflict copy unread, and
    /// preserves a damaged record beside itself, leaving it out.
    func testLoadingReadsRecordsAndPreservesDamagedOnes() async throws {
        let folder = try makeSandboxDirectory("FeedStoreLoad").appendingPathComponent("Feeds", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kept = Self.record(itemCount: 2)
        let encoder = FeedRecordCoding.encoder()
        try encoder.encode(kept).write(to: FeedPaths.recordFile(of: kept.feed.id, in: folder))
        try encoder.encode(Self.record(itemCount: 1))
            .write(to: folder.appendingPathComponent("\(kept.feed.id.uuidString) 2.json"))
        let copiedID = UUID()
        try encoder.encode(kept).write(to: FeedPaths.recordFile(of: copiedID, in: folder))
        let damagedID = UUID()
        let damagedFile = FeedPaths.recordFile(of: damagedID, in: folder)
        let damaged = Data(#"{"formatVersion": 1, "feed": {"id""#.utf8)
        try damaged.write(to: damagedFile)

        let store = FeedStore(location: .folder(folder))
        await store.load()

        XCTAssertTrue(store.hasLoaded)
        XCTAssertEqual(Set(store.records.keys), [kept.feed.id, copiedID])
        XCTAssertEqual(store.record(of: kept.feed.id), kept)
        XCTAssertEqual(store.record(of: copiedID)?.feed.id, copiedID)
        let copies = LibraryIndexQuarantine.existingCopies(of: damagedFile)
        XCTAssertEqual(copies.count, 1, "the damaged record was not preserved")
        XCTAssertEqual(try copies.first.map { try Data(contentsOf: $0) }, damaged)
        XCTAssertFalse(debugLogLines(containing: "FEED_RECORD_UNREADABLE: could not read \(damagedFile.lastPathComponent)").isEmpty)
    }

    /// Only a file named exactly by a feed's ID and ".json" holds a record.
    func testOnlyAFeedsOwnNameHoldsItsRecord() {
        let id = UUID()
        XCTAssertEqual(FeedPaths.feedID(ofRecordNamed: "\(id.uuidString).json"), id)
        XCTAssertNil(FeedPaths.feedID(ofRecordNamed: "\(id.uuidString.lowercased()).json"))
        XCTAssertNil(FeedPaths.feedID(ofRecordNamed: "\(id.uuidString) 2.json"))
        XCTAssertNil(FeedPaths.feedID(ofRecordNamed: "\(id.uuidString).json.unreadable-20261004T101500Z"))
        XCTAssertNil(FeedPaths.feedID(ofRecordNamed: "\(id.uuidString).txt"))
        XCTAssertNil(FeedPaths.feedID(ofRecordNamed: ".json"))
    }

    /// A record written while a data-directory move holds storage work waits
    /// for the move, and lands in the data directory the move published,
    /// never in the old one.
    func testARecordWrittenDuringAMoveLandsInTheNewDataDirectory() async throws {
        let oldRoot = try makeSandboxDirectory("FeedMoveOld")
        let newRoot = try makeSandboxDirectory("FeedMoveNew")
        let boundary = StorageBoundary(root: oldRoot)
        let location = FeedStore.Location(
            currentFolder: { FeedPaths.recordsFolder(in: boundary.current.root) },
            folder: { FeedPaths.recordsFolder(in: $0.root) },
            boundary: boundary,
            isUnavailable: { false }
        )
        let store = FeedStore(location: location)
        let record = Self.record(itemCount: 1)

        let hold = try boundary.holdWork(for: .movingDataDirectory)
        store.add(record)
        boundary.publish(root: newRoot)
        hold.release()
        await store.flush()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: FeedPaths.recordFile(of: record.feed.id, in: FeedPaths.recordsFolder(in: newRoot)).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: FeedPaths.recordsFolder(in: oldRoot).path))
    }

    /// While the data directory is unavailable a change is kept in memory
    /// and written nowhere; once the data directory is back, it is written.
    func testAChangeWaitsWhileTheDataDirectoryIsUnavailable() async throws {
        let folder = try makeSandboxDirectory("FeedUnavailable").appendingPathComponent("Feeds", isDirectory: true)
        let unavailable = LockedValue(true)
        let location = FeedStore.Location(
            currentFolder: { folder },
            folder: { _ in folder },
            boundary: StorageBoundary(root: folder.deletingLastPathComponent()),
            isUnavailable: { unavailable.value }
        )
        let store = FeedStore(location: location)
        let record = Self.record(itemCount: 1)
        let file = FeedPaths.recordFile(of: record.feed.id, in: folder)

        store.add(record)
        await store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(store.unsavedFeedIDs, [record.feed.id])

        unavailable.value = false
        store.saveUnsavedRecords()
        await store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(store.unsavedFeedIDs, [])
    }

    /// A record that can't be written is reported to the failure center as
    /// every other save is: naming the feed and its file, with a retry, as
    /// an unsaved change. A retry that still fails says so; one that works
    /// writes the record as it is now, settles the failure, and says the
    /// subscriptions are saved. Unsubscribing withdraws a failure still
    /// outstanding, since nothing is left to save.
    func testARecordThatCannotBeSavedIsReportedAndRetried() async throws {
        let folder = try makeSandboxDirectory("FeedSaveFailure").appendingPathComponent("Feeds", isDirectory: true)
        let center = PersistenceFailureCenter()
        let store = FeedStore(location: .folder(folder), failureCenter: center)
        let record = Self.record(itemCount: 1)
        let feedID = record.feed.id
        let itemID = record.items[0].id
        let file = FeedPaths.recordFile(of: feedID, in: folder)
        store.add(record)
        await store.flush()
        XCTAssertTrue(center.outstandingFailures().isEmpty)

        let obstruction = try WriteObstruction.place(at: file)
        let played = Date(timeIntervalSince1970: 1_790_100_000)
        store.updateItem(itemID, of: feedID) { $0.playedDate = played }
        await store.flush()

        let failure = try XCTUnwrap(center.outstandingFailures().first)
        XCTAssertEqual(failure.subject, .feedRecord(feedID: feedID, title: "The Tactile Atlas"))
        XCTAssertEqual(failure.subsystem, .feedRecords)
        XCTAssertEqual(failure.path, file.path)
        XCTAssertNotNil(failure.retry)
        XCTAssertTrue(
            failure.sentence.hasPrefix("Changes to the feed “The Tactile Atlas” could not be saved: "),
            failure.sentence
        )
        XCTAssertTrue(center.hasUnsavedChanges, "quitting would not ask about the feed")
        XCTAssertEqual(store.unsavedFeedIDs, [feedID])

        let stillFailing = recordingAnnouncements { center.retry(.feedRecords) }
        XCTAssertEqual(center.outstandingFailures().count, 1)
        XCTAssertEqual(stillFailing.announcements.first?.message.hasPrefix("Retry did not succeed."), true)

        obstruction.clear()
        let saved = recordingAnnouncements { center.retry(.feedRecords) }
        XCTAssertTrue(center.outstandingFailures().isEmpty)
        XCTAssertEqual(saved.announcements.map(\.message), ["Feed subscriptions saved."])
        let written = try FeedRecordCoding.decoder().decode(FeedRecord.self, from: Data(contentsOf: file))
        XCTAssertEqual(written.items[0].playedDate, played)
        XCTAssertEqual(store.unsavedFeedIDs, [])

        let again = try WriteObstruction.place(at: file)
        store.updateItem(itemID, of: feedID) { $0.playedDate = nil }
        await store.flush()
        XCTAssertEqual(center.outstandingFailures().count, 1)
        store.remove(feedID)
        XCTAssertTrue(center.outstandingFailures().isEmpty, "an unsubscribed feed's failure stayed")
        again.clear()
    }

    // MARK: - This Mac's Fetch Details

    /// Fetch details round-trip through this Mac's folder, one file per
    /// feed; a damaged file counts as missing, and removing a feed's details
    /// deletes its file.
    func testFetchDetailsRoundTripThroughThisMacsFolder() async throws {
        let folder = try makeSandboxDirectory("FeedFetchStates")
        let feedID = UUID()
        let checked = Date(timeIntervalSince1970: 1_800_000_000)

        let states = FeedFetchStates(folder: folder)
        states.update(feedID) {
            $0.etag = "\"v1\""
            $0.lastModified = "Wed, 01 Oct 2026 10:00:00 GMT"
            $0.bodyDigest = "00ff"
            $0.lastCheck = checked
            $0.lastError = FeedRefreshFailure(message: "feeds.example didn't answer for 30 seconds.", date: checked)
        }
        await states.flush()
        try Data("not json".utf8).write(to: FeedPaths.recordFile(of: UUID(), in: folder))

        let read = FeedFetchStates(folder: folder)
        await read.load()

        XCTAssertEqual(read.states.count, 1)
        XCTAssertEqual(read.state(of: feedID), states.state(of: feedID))
        XCTAssertEqual(read.state(of: UUID()), FeedFetchState())

        read.remove(feedID)
        await read.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: FeedPaths.recordFile(of: feedID, in: folder).path))
    }

    /// This Mac's feed folders are in its own Caches and Application
    /// Support, never in the data directory, and in the test sandbox here.
    func testThisMacsFeedFoldersAreItsOwn() {
        XCTAssertTrue(MachineLocalPaths.feedCaches.path.hasPrefix(MachineLocalPaths.caches.path + "/"))
        XCTAssertTrue(MachineLocalPaths.feedDownloads.path.hasPrefix(MachineLocalPaths.root.path + "/"))
        XCTAssertTrue(MachineLocalPaths.feedCaches.path.hasPrefix(HostedTestSandbox.home.path))
        XCTAssertFalse(MachineLocalPaths.feedCaches.path.hasPrefix(TextMouthPaths.root.path + "/"))
        XCTAssertEqual(FeedPaths.recordsFolder(in: TextMouthPaths.root).lastPathComponent, "Feeds")
    }

    // MARK: - Fixtures

    /// A record of a feed with `itemCount` items, newest first.
    static func record(itemCount: Int, folderID: UUID = UUID()) -> FeedRecord {
        let subscribed = Date(timeIntervalSince1970: 1_790_000_000)
        guard let address = URL(string: "https://feeds.example/show.xml") else {
            preconditionFailure("a constant address")
        }
        var feed = Feed(feedURL: address, folderID: folderID, subscribedDate: subscribed)
        feed.title = "The Tactile Atlas"
        let items = (0..<itemCount).map { number in
            FeedItem(
                id: "guid:ep-\(itemCount - number)",
                guid: "ep-\(itemCount - number)",
                title: "Episode \(itemCount - number)",
                published: subscribed.addingTimeInterval(TimeInterval(-86_400 * number)),
                firstSeen: subscribed,
                enclosure: URL(string: "https://cdn.example/\(itemCount - number).mp3")
                    .map { FeedEnclosure(url: $0, mimeType: "audio/mpeg", length: 1_000) }
            )
        }
        return FeedRecord(feed: feed, items: items)
    }
}
