import XCTest
@testable import TextMouth

// MARK: - The Launch Waits for Each Feed's Index

/// Each feed's own index (FR11) is read at launch, on the main thread, with
/// library.json, so in a cloud data directory it must be on this Mac before
/// the library opens, as library.json must (REV10, item 2): the check of the
/// data directory counts a feed's index only in the cloud, and a folder
/// holding indexes whose listing is only in the cloud, among the files it
/// asks the sync service for and waits for. The sync service is scripted;
/// no real cloud drive is used.
final class LibraryFeedIndexCloudCheckTests: XCTestCase {

    /// A feed's index only in the cloud keeps the library waiting, with the
    /// download reason naming the service, and its download is asked for.
    func testAFeedIndexOnlyInTheCloudIsAskedForAndWaitedFor() throws {
        let library = try makeCloudLibrary()
        let index = FeedPaths.indexFile(of: library.feedID, in: library.root)
        library.cloud.setStatus(Self.status(.notDownloaded), of: index)

        let outcome = Self.check(library).run(itemStatus: library.cloud)

        XCTAssertEqual(outcome, .unavailable(.notDownloaded(.iCloudDrive, folder: library.root.path)))
        XCTAssertEqual(library.cloud.downloadRequests.map(\.path), [index.path])
    }

    /// A feed's folder whose listing is only in the cloud, which reading the
    /// index inside would download first, keeps the library waiting too.
    func testAFeedsFolderOnlyInTheCloudIsAskedForAndWaitedFor() throws {
        let library = try makeCloudLibrary()
        let folder = FeedPaths.itemsFolder(of: library.feedID, in: library.root)
        library.cloud.setStatus(Self.status(.downloading), of: folder)

        let outcome = Self.check(library).run(itemStatus: library.cloud)

        XCTAssertEqual(outcome, .unavailable(.notDownloaded(.iCloudDrive, folder: library.root.path)))
        XCTAssertEqual(library.cloud.downloadRequests.map(\.path), [folder.path])
    }

    /// The Feeds folder only in the cloud, whose listing names every feed's
    /// folder, keeps the library waiting.
    func testTheFeedsFolderOnlyInTheCloudIsAskedForAndWaitedFor() throws {
        let library = try makeCloudLibrary()
        let feeds = FeedPaths.recordsFolder(in: library.root)
        library.cloud.setStatus(Self.status(.notDownloaded), of: feeds)

        let outcome = Self.check(library).run(itemStatus: library.cloud)

        XCTAssertEqual(outcome, .unavailable(.notDownloaded(.iCloudDrive, folder: library.root.path)))
        XCTAssertEqual(library.cloud.downloadRequests.map(\.path), [feeds.path])
    }

    /// Feeds' indexes on this Mac let the library open, and nothing is asked
    /// of the sync service; a folder in Feeds named by no feed's ID is no
    /// feed's, and its files are no concern of the check's.
    func testFeedIndexesOnThisMacLetTheLibraryOpen() throws {
        let library = try makeCloudLibrary()
        library.cloud.setStatus(Self.status(.downloaded), of: FeedPaths.indexFile(of: library.feedID, in: library.root))
        let stray = FeedPaths.recordsFolder(in: library.root).appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        let strayIndex = stray.appendingPathComponent(FeedPaths.indexFileName)
        try Data("{}".utf8).write(to: strayIndex)
        library.cloud.setStatus(Self.status(.notDownloaded), of: strayIndex)

        let outcome = Self.check(library).run(itemStatus: library.cloud)

        XCTAssertEqual(outcome, .available(library.identity, relocatedTo: nil))
        XCTAssertEqual(library.cloud.downloadRequests, [])
    }

    // MARK: - Fixtures

    /// A library in a custom data directory a scripted sync service holds:
    /// its identity marker, library.json, and one feed's folder with its
    /// index, every file on this Mac until a test says otherwise.
    private struct CloudLibrary {
        /// The data directory.
        var root: URL
        /// The library's identity, which the check expects.
        var identity: LibraryIdentity
        /// The feed whose folder and index the data directory holds.
        var feedID: UUID
        /// The scripted sync service.
        var cloud: FakeCloudItemStatusProvider
    }

    /// Makes a `CloudLibrary` in a sandbox directory of the test's own, in
    /// iCloud Drive as the scripted service says.
    private func makeCloudLibrary() throws -> CloudLibrary {
        let root = try makeSandboxDirectory("CloudFeedIndex")
        let identity = try LibraryIdentity.adopt(in: root).identity
        try Data("{}".utf8).write(to: root.appendingPathComponent("library.json"))
        let feedID = UUID()
        let index = FeedPaths.indexFile(of: feedID, in: root)
        try FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FeedIndexFiles.encoded(FeedIndex(feedID: feedID, books: [])).write(to: index)
        let cloud = FakeCloudItemStatusProvider()
        cloud.setLocation(.cloud(.iCloudDrive), of: root)
        return CloudLibrary(root: root, identity: identity, feedID: feedID, cloud: cloud)
    }

    /// The check of `library`'s custom data directory, expecting its
    /// identity.
    private static func check(_ library: CloudLibrary) -> DataDirectoryCheck {
        DataDirectoryCheck(root: library.root, isDefaultLocation: false, expectedIdentity: library.identity.id, bookmark: nil)
    }

    /// A status in `state`, as a sync service reports an item in it.
    private static func status(_ state: CloudItemState) -> CloudItemStatus {
        CloudItemStatus(state: state, isUploaded: true, byteCount: 120, hasUnresolvedConflicts: false, downloadError: nil)
    }
}

// MARK: - An Index Only in the Cloud Is Left Alone

/// A feed's index that a launch finds only in the cloud, as when it leaves
/// this Mac between the data directory's check and the read, is read with
/// dataless files left in the cloud, never waiting on the network, and is
/// no damage (REV10, item 2): it is not preserved as unreadable, its
/// download is asked for, its rows are read from the packages whose records
/// are here, and no save writes those rows over it until a launch reads it.
/// Real dataless files cannot be made in a hosted test, so the index's read
/// is refused as the system refuses a dataless file's.
final class LibraryFeedIndexCloudReadTests: FeedItemIndexTestCase {

    /// The read refuses the index, so its rows come from the package whose
    /// record is here; the index is left alone, untouched and not preserved,
    /// one FEED_INDEX_IN_CLOUD line says so, and its download is asked for.
    @MainActor
    func testAFeedIndexOnlyInTheCloudIsNeitherReadNorTakenForDamage() async throws {
        let cloud = installFakeCloudItemStatus()
        let fixture = try makeIndexWithAnItemInTheCloud()
        let logLine = "FEED_INDEX_IN_CLOUD: \(feedID.uuidString.prefix(8))"
        let linesBefore = debugLogLines(containing: logLine).count

        let read = FeedIndexFiles.read(feedID: feedID, in: TextMouthPaths.root, reader: refusingIndex)

        XCTAssertTrue(read.isLeftAlone)
        XCTAssertNil(read.indexBytes)
        XCTAssertEqual(read.rows.map(\.id), [fixture.here.id], "the rows did not come from the package here")
        XCTAssertEqual(contents(of: feedIndexURL), fixture.indexBytes, "the index changed")
        let names = try FileManager.default.contentsOfDirectory(atPath: feedFolderURL.path)
        XCTAssertFalse(names.contains { $0.contains(LibraryIndexQuarantine.nameMarker) }, "the index was preserved as damaged: \(names)")
        XCTAssertEqual(debugLogLines(containing: logLine).count, linesBefore + 1)
        let indexPath = feedIndexURL.path
        let requested = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in cloud.downloadRequests.contains { $0.path == indexPath } },
            object: nil
        )
        await fulfillment(of: [requested], timeout: 5)
    }

    /// The shelf a launch reads leaves the index alone, and no save writes
    /// it: not the launch's own, and not one after a download of the same
    /// feed joined the library; library.json is written all the same, with
    /// none of the feed's rows.
    func testNoSaveWritesAFeedIndexLeftInTheCloud() throws {
        let fixture = try makeIndexWithAnItemInTheCloud()

        let shelf = LibraryPersistenceService.loadFeedShelf(reader: refusingIndex)
        XCTAssertEqual(shelf.indexesLeftAlone, [feedID])
        var library = Library(feedShelf: shelf)
        saveNow(library)
        XCTAssertEqual(contents(of: feedIndexURL), fixture.indexBytes, "the launch's save wrote the index")

        let downloaded = try makeFeedItem(title: "Downloaded Meanwhile")
        library.books.append(downloaded)
        XCTAssertTrue(LibraryPersistenceService.saveAndWait(library))

        XCTAssertEqual(contents(of: feedIndexURL), fixture.indexBytes, "a later save wrote the index")
        try assertLibraryJSONHoldsNoFeedItem([fixture.here, downloaded])
    }

    /// While a feed's index is left alone it holds none of the session's
    /// reading checkpoints, so the checkpoint journal stays after library.json
    /// is written, for the next launch to take the position from the record;
    /// without such an index the same write clears it.
    func testTheCheckpointJournalStaysWhileAFeedIndexIsLeftAlone() throws {
        let fixture = try makeIndexWithAnItemInTheCloud()
        var item = fixture.here
        item.readingPosition = Self.position(400, at: 7_200)

        let leftAlone = Library(books: [item], feedShelf: FeedShelf(indexesLeftAlone: [feedID]))
        LibraryPersistenceService.saveReadingCheckpoint(leftAlone, of: item.id, writingWithin: 0.05)
        LibraryPersistenceService.flushPendingSave()
        XCTAssertTrue(LibraryPersistenceService.booksWithCheckpointsAhead().contains(item.id))

        LibraryPersistenceService.saveReadingCheckpoint(Library(books: [item]), of: item.id, writingWithin: 0.05)
        LibraryPersistenceService.flushPendingSave()
        XCTAssertFalse(LibraryPersistenceService.booksWithCheckpointsAhead().contains(item.id))
    }

    /// Every writer of a feed's index writes from `Library.feedIndexRows`,
    /// the save and the data-directory move's staging alike, and it leaves
    /// out a feed whose index is left alone, rows and all, while keeping
    /// every other feed's.
    func testEveryWriterLeavesOutAFeedIndexLeftAlone() throws {
        let item = try makeFeedItem(title: "In The Cloud's Feed")
        let other = UUID()
        let library = Library(books: [item], feedShelf: FeedShelf(indexedFeedIDs: [other], indexesLeftAlone: [feedID]))

        XCTAssertEqual(Set(library.feedIndexRows.keys), [other])
    }

    /// A library read again after the data directory came back keeps a
    /// feed's index left alone when its rows come from that library, and
    /// not when the session's own rows of the feed, read before, are kept.
    func testARecoveredLibraryLeavesAnIndexAloneOnlyWhenItsRowsStandIn() throws {
        let item = try makeFeedItem(title: "Read Before")
        let elsewhere = UUID()
        let session = Library(books: [item])
        let loaded = Library(feedShelf: FeedShelf(indexedFeedIDs: [feedID, elsewhere], indexesLeftAlone: [feedID, elsewhere]))

        let shelf = LibraryViewModel.feedItems(of: session, over: loaded)

        XCTAssertEqual(shelf.indexesLeftAlone, [elsewhere])
        XCTAssertEqual(shelf.rows.map(\.id), [item.id])
    }

    // MARK: - Fixtures

    /// The index `makeIndexWithAnItemInTheCloud()` wrote, and its item here.
    private struct IndexInTheCloud {
        /// The item whose package and record are here.
        var here: Book
        /// The index's bytes on disk, listing that item and another whose
        /// package is not here.
        var indexBytes: Data?
    }

    /// This test's feed's index on disk, listing an item whose package and
    /// record are here and one whose package is not, as when its record is
    /// only in the cloud.
    private func makeIndexWithAnItemInTheCloud() throws -> IndexInTheCloud {
        let here = try makeFeedItem(title: "Kept Here")
        let away = Book(
            title: "Only in the Cloud",
            format: .html,
            filePath: feedFolderURL.appendingPathComponent("Only in the Cloud.tmb/away.html").path,
            md5Hash: UUID().uuidString,
            tmbDirectoryName: "Only in the Cloud.tmb",
            feedLink: FeedBookLink(feedID: feedID, itemID: "guid:away")
        )
        try FeedIndexFiles.encoded(FeedIndex(feedID: feedID, books: [here, away])).write(to: feedIndexURL)
        return IndexInTheCloud(here: here, indexBytes: contents(of: feedIndexURL))
    }

    /// Reads a saved file as the app does, refusing this test's feed's index
    /// as the system refuses a dataless file while downloads are off.
    private var refusingIndex: SavedFile.Reader {
        let index = feedIndexURL.standardizedFileURL.path
        return { url in
            if url.standardizedFileURL.path == index {
                throw POSIXError(.EDEADLK)
            }
            return try SavedFile.readWithoutDownloading(url)
        }
    }

    /// Makes `CloudServices.itemStatus` a scripted service for this test,
    /// put back when it ends, and returns it.
    @MainActor
    private func installFakeCloudItemStatus() -> FakeCloudItemStatusProvider {
        let cloud = FakeCloudItemStatusProvider()
        let previous = CloudServices.itemStatus
        CloudServices.itemStatus = cloud
        addTeardownBlock { @MainActor in CloudServices.itemStatus = previous }
        return cloud
    }
}
