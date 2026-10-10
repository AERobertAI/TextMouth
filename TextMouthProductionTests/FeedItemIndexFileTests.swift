import XCTest
@testable import TextMouth

/// Each feed's own index (FR11, branch A1): every write of library.json
/// writes each feed's rows to that feed's index first and never into
/// library.json, writes an index only when its bytes changed, and the
/// indexes are read with library.json, an unreadable one preserved and its
/// rows read from the feed's packages.
final class FeedItemIndexFileTests: FeedItemIndexTestCase {

    // MARK: - library.json

    /// library.json holds the library's own books and never a feed item's
    /// row, whether the library holds it among its books or on its shelf;
    /// and a row read from it is always a book of the library's own.
    func testLibraryJSONNeverHoldsAFeedItemsRow() throws {
        let plain = Book(title: "Plain", format: .txt, filePath: "/plain.txt", md5Hash: "p")
        let joined = try makeFeedItem(title: "Joined")
        let shelved = try makeFeedItem(title: "Shelved")
        let library = Library(books: [plain, joined], feedShelf: FeedShelf(rows: [shelved]))

        let data = try LibraryPersistenceService.encodedIndex(library)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(object["books"] as? [[String: Any]])

        XCTAssertEqual(rows.compactMap { $0["id"] as? String }, [plain.id.uuidString])
        XCTAssertEqual(Set(object.keys), ["books", "folders", "folderSortSettings", "readingList"])

        var linked = try XCTUnwrap(rows.first)
        linked["feedLink"] = ["feedID": feedID.uuidString, "itemID": "hand-edited"]
        var edited = object
        edited["books"] = [linked]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let read = try decoder.decode(Library.self, from: JSONSerialization.data(withJSONObject: edited))
        XCTAssertNil(read.books.first?.feedLink, "a row read from library.json is the library's own")
        XCTAssertTrue(read.feedShelf.isEmpty)
    }

    // MARK: - Every Writer

    /// A save writes each feed's rows to its own index and the library's own
    /// books to library.json.
    @MainActor
    func testASaveWritesTheFeedsRowsToItsIndex() throws {
        let plain = try makePackagedBook(title: "Plain Saved")
        let item = try makeFeedItem(title: "Saved Item")
        let model = makeModel(with: [plain, item])

        model.save()
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(try indexedRows().map(\.id), [item.id])
        try assertLibraryJSONHoldsNoFeedItem([item])
        XCTAssertTrue(try libraryJSONBookIDs().contains(plain.id))
    }

    /// A reading checkpoint of a feed item reaches its feed's index at its
    /// deadline, as it reaches library.json for a book, never library.json.
    @MainActor
    func testACheckpointReachesTheFeedsIndex() throws {
        let item = try makeFeedItem(title: "Checkpointed")
        let model = makeModel(with: [item])
        model.save()
        LibraryPersistenceService.flushPendingSave()
        var checkpointed = model.library
        checkpointed.updateReadingPosition(bookID: item.id, position: ReadingPosition(chapterIndex: 0, characterOffset: 77))

        LibraryPersistenceService.saveReadingCheckpoint(checkpointed, of: item.id, writingWithin: 0.3)
        XCTAssertTrue(waitUntil(timeout: 5) {
            (try? self.indexedRows().first?.readingPosition?.characterOffset) == 77
        }, "the checkpoint never reached the feed's index")

        try assertLibraryJSONHoldsNoFeedItem([item])
    }

    /// A reader's checkpoint and bookmark of a feed item, through the paths
    /// every book's take, reach the item's record in its package within
    /// half a second and its feed's index by the time the snapshot is
    /// written, never library.json: "make sure playback position is also
    /// saved".
    @MainActor
    func testAReadersCheckpointOfAFeedItemReachesItsRecordAndItsIndex() throws {
        let item = try makeFeedItem(title: "Played Episode")
        let model = makeModel(with: [item])
        model.save()
        LibraryPersistenceService.flushPendingSave()
        let position = Self.position(321, at: 100)

        model.persistReadingPosition(bookID: item.id, position: position)
        model.addBookmark(bookID: item.id, chapterIndex: 0, characterOffset: 300, label: "Kept here")
        waitPastLibrarySaveDebounce()

        let record = try BookInfo.load(from: item.tmbDirectory)
        XCTAssertEqual(record.state.readingPosition, position)
        XCTAssertEqual(record.bookmarks.map(\.label), ["Kept here"])
        LibraryPersistenceService.flushPendingSave()
        let row = try XCTUnwrap(indexedRows().first)
        XCTAssertEqual(row.readingPosition, position)
        XCTAssertEqual(row.bookmarks.map(\.label), ["Kept here"])
        try assertLibraryJSONHoldsNoFeedItem([item])
    }

    /// Quitting writes the waiting snapshot's feed rows to their index.
    @MainActor
    func testTheQuitFlushWritesTheFeedsIndex() throws {
        let item = try makeFeedItem(title: "Flushed")

        LibraryPersistenceService.save(Library(books: [item]))
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(try indexedRows().map(\.id), [item.id])
        try assertLibraryJSONHoldsNoFeedItem([item])
    }

    /// A feed's index that cannot be written stops the save before
    /// library.json, is reported naming the index, and its retry writes the
    /// same snapshot's rows to the index, never to library.json.
    @MainActor
    func testAFailedIndexWriteIsReportedAndItsRetryWritesTheIndex() throws {
        let center = cleanSharedFailureCenter()
        let item = try makeFeedItem(title: "Retried")
        let plain = try makePackagedBook(title: "Waits For The Index")
        let obstruction = try WriteObstruction.place(at: feedIndexURL)
        let indexBefore = contents(of: TextMouthPaths.libraryIndexFile)

        LibraryPersistenceService.save(Library(books: [plain, item]))
        LibraryPersistenceService.flushPendingSave()

        let failure = try XCTUnwrap(center.outstandingFailures().first)
        XCTAssertEqual(failure.subject, .libraryIndex)
        XCTAssertEqual(URL(fileURLWithPath: failure.path).standardizedFileURL, feedIndexURL.standardizedFileURL)
        XCTAssertEqual(contents(of: TextMouthPaths.libraryIndexFile), indexBefore, "library.json was written before the index")

        obstruction.restoreOriginal()
        center.retry(.libraryIndex)

        XCTAssertFalse(center.hasUnsavedChanges)
        XCTAssertEqual(try indexedRows().map(\.id), [item.id])
        try assertLibraryJSONHoldsNoFeedItem([item])
        XCTAssertTrue(try libraryJSONBookIDs().contains(plain.id))
    }

    /// Rebuild Library Index's write splits the library as every write does.
    func testReplacingAnUnreadableIndexWritesTheFeedsRowsToItsIndex() throws {
        let item = try makeFeedItem(title: "Rebuilt Into Its Index")
        let plain = try makePackagedBook(title: "Rebuilt Into library.json")

        try LibraryPersistenceService.replaceUnreadableIndex(with: Library(books: [plain, item]))

        XCTAssertEqual(try indexedRows().map(\.id), [item.id])
        try assertLibraryJSONHoldsNoFeedItem([item])
        XCTAssertTrue(try libraryJSONBookIDs().contains(plain.id))
    }

    // MARK: - Writing Only What Changed

    /// A save that changes nothing of a feed leaves its index as it was,
    /// while library.json takes the change.
    @MainActor
    func testAnUnchangedIndexIsNotWrittenAgain() throws {
        let item = try makeFeedItem(title: "Unchanged")
        let plain = try makePackagedBook(title: "Renamed")
        let model = makeModel(with: [plain, item])
        model.save()
        LibraryPersistenceService.flushPendingSave()
        let indexInode = try LibraryIndexSandbox.inode(of: feedIndexURL)

        model.updateBook(id: plain.id) { $0.title = "Renamed Again" }
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(try LibraryIndexSandbox.inode(of: feedIndexURL), indexInode, "the feed's index was written again")
        let titles = try libraryJSONRows().compactMap { $0["title"] as? String }
        XCTAssertTrue(titles.contains("Renamed Again"))
    }

    /// A feed whose last row left the library gets an empty index, so the
    /// row does not come back at the next launch.
    @MainActor
    func testAFeedWhoseLastRowLeftIsWrittenEmpty() throws {
        let item = try makeFeedItem(title: "Leaving")
        let model = makeModel(with: [item])
        model.save()
        LibraryPersistenceService.flushPendingSave()
        XCTAssertEqual(try indexedRows().count, 1)

        model.library.removeBook(id: item.id)
        model.save()
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(try indexedRows().count, 0)
    }

    /// A download added to the library is a feed item's row, with no
    /// library folder, written to its feed's index; deleting it writes the
    /// index without it.
    @MainActor
    func testADownloadAddedThenDeletedIsWrittenToItsIndexThenOutOfIt() throws {
        var download = try makeFeedItem(title: "Added And Deleted")
        download.folderPath = "Where The Feed Was"
        let model = makeModel(with: [])

        model.addFeedBook(download)
        LibraryPersistenceService.flushPendingSave()
        let added = try XCTUnwrap(model.bookByID(download.id))
        XCTAssertEqual(added.folderPath, "")
        XCTAssertEqual(try indexedRows().map(\.id), [download.id])

        try FileManager.default.removeItem(at: added.tmbDirectory)
        model.removeFeedBook(added)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(try indexedRows(), [])
        try assertLibraryJSONHoldsNoFeedItem([download])
    }

    /// A feed the library keeps no row of, whose folder is gone, has nothing
    /// left to keep, and its folder is not made again.
    func testAFeedWithNoRowAndNoFolderIsNotMadeAgain() throws {
        try? FileManager.default.removeItem(at: feedFolderURL)

        LibraryPersistenceService.save(Library(feedShelf: FeedShelf(indexedFeedIDs: [feedID])))
        LibraryPersistenceService.flushPendingSave()

        XCTAssertFalse(FileManager.default.fileExists(atPath: feedFolderURL.path))
    }

    /// A library that never held a feed's rows never writes its index: a
    /// feed's index is written only by a library that read it or held its
    /// rows.
    func testALibraryThatNeverHeldAFeedLeavesItsIndexAlone() throws {
        let item = try makeFeedItem(title: "Untouched")
        LibraryPersistenceService.save(Library(books: [item]))
        LibraryPersistenceService.flushPendingSave()
        let before = contents(of: feedIndexURL)

        LibraryPersistenceService.save(Library(books: [try makePackagedBook(title: "Another Library")]))
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(contents(of: feedIndexURL), before)
    }

    // MARK: - Reading

    /// Loading the library reads each feed's index with library.json: its
    /// rows wait on the shelf, placed where their packages are, and the
    /// library's books hold none of them.
    @MainActor
    func testLoadingReadsEachFeedsRowsOntoTheShelf() throws {
        let item = try makeFeedItem(title: "Loaded")
        let plain = try makePackagedBook(title: "Loaded Book")
        LibraryPersistenceService.save(Library(books: [plain, item]))
        LibraryPersistenceService.flushPendingSave()

        let library = try XCTUnwrap(LibraryPersistenceService.load().library)

        XCTAssertFalse(library.books.contains { $0.id == item.id })
        XCTAssertTrue(library.books.contains { $0.id == plain.id })
        XCTAssertEqual(library.feedShelf.rows.first { $0.id == item.id }, item)
        XCTAssertTrue(library.feedShelf.indexedFeedIDs.contains(feedID))
    }

    /// An index that cannot be read is preserved beside itself, and its
    /// feed's rows are read from the packages, each of which names its feed
    /// and item in its record.
    func testAnUnreadableIndexIsPreservedAndItsRowsReadFromThePackages() throws {
        let item = try makeFeedItem(title: "Recovered", lastOpened: Self.date(60))
        try Data("{ damaged".utf8).write(to: feedIndexURL)

        let shelf = LibraryPersistenceService.loadFeedShelf()

        XCTAssertEqual(shelf.rows.first { $0.id == item.id }, item)
        XCTAssertEqual(LibraryIndexQuarantine.existingCopies(of: feedIndexURL).count, 1)
        let lines = debugLogLines(containing: "the rows of feed \(feedID.uuidString) are read from its packages")
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines.first?.contains("FEED_INDEX_UNREADABLE: could not read \(FeedPaths.indexFileName)") == true, "\(lines)")
        for copy in LibraryIndexQuarantine.existingCopies(of: feedIndexURL) {
            try? FileManager.default.removeItem(at: copy)
        }
    }

    /// A package in the feed's folder its index does not list, as a
    /// download whose save a crash cut short leaves, is read from its
    /// record beside the index's rows.
    func testAPackageTheIndexDoesNotListIsReadFromItsRecord() throws {
        let listed = try makeFeedItem(title: "Listed")
        LibraryPersistenceService.save(Library(books: [listed]))
        LibraryPersistenceService.flushPendingSave()
        let unlisted = try makeFeedItem(title: "Unlisted", dateAdded: Self.date(10))

        let contents = FeedIndexFiles.read(feedID: feedID, in: TextMouthPaths.root)

        XCTAssertEqual(Set(contents.rows.map(\.id)), [listed.id, unlisted.id])
        XCTAssertEqual(contents.rows.first { $0.id == unlisted.id }, unlisted)
        XCTAssertNotNil(contents.indexBytes)
    }

    /// A row is placed where its package is whatever its index says: in its
    /// feed's folder in the data directory in use, as a feed item of the
    /// feed whose folder holds it, with no library folder.
    func testARowIsPlacedWhereItsPackageIs() throws {
        let item = try makeFeedItem(title: "Moved Elsewhere")
        var stale = item
        stale.filePath = "/Volumes/Old/.TextMouth/Feeds/\(UUID().uuidString)/\(item.tmbDirectoryName)/\(item.title).html"
        stale.folderPath = "Somewhere"
        stale.feedLink = FeedBookLink(feedID: UUID(), itemID: item.feedLink?.itemID ?? "")
        try FileManager.default.createDirectory(at: feedFolderURL, withIntermediateDirectories: true)
        try FeedIndexFiles.encoded(FeedIndex(feedID: feedID, books: [stale])).write(to: feedIndexURL)

        let contents = FeedIndexFiles.read(feedID: feedID, in: TextMouthPaths.root)

        XCTAssertEqual(contents.rows, [item])
    }

    // MARK: - The Shelf

    /// The shelf keeps one row per book, keeps the index of every feed it
    /// held a row of, and asks once for each row it may take.
    func testTheShelfKeepsOneRowPerBookAndEveryFeedsIndex() throws {
        let first = try makeFeedItem(title: "First")
        var newer = first
        newer.lastOpened = Self.date(5)
        var shelf = FeedShelf()
        shelf.put(first)
        shelf.put(newer)
        shelf.put(Book(title: "No Feed", format: .txt, filePath: "/x.txt", md5Hash: "x"))

        XCTAssertEqual(shelf.rows, [newer])
        XCTAssertEqual(shelf.indexedFeedIDs, [feedID])

        var asked = 0
        let taken = shelf.takeRows { _ in
            asked += 1
            return true
        }
        XCTAssertEqual(taken, [newer])
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(shelf.isEmpty)
        XCTAssertEqual(shelf.indexedFeedIDs, [feedID], "taking a row keeps its feed's index")
    }
}
