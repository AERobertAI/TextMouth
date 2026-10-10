import XCTest
@testable import TextMouth

// MARK: - A Feed's Downloads Return to the Library

/// A feed whose record is truly gone (lost, or deleted by an Unsubscribe of a
/// build before FR11's branch D, which keeps the record now) gets its
/// downloads back as books of the library's own, at launch (REV10, item 3):
/// each keeps its book ID, place, bookmarks, and place on the reading list,
/// and what the feed kept of downloads removed earlier is deleted. A crash
/// between any two steps is finished at the next launch. The fixture is this
/// test's feed's folder, holding one download the listener opened and one
/// package kept after its download went, with this test's library folder as
/// the feed's own.
final class LibraryFeedDownloadReturnTests: FeedItemIndexTestCase {

    // MARK: - One Feed

    /// The download becomes a book of the library's own in the feed's
    /// folder, keeping its ID, place, bookmarks, and reading-list place;
    /// library.json lists it; the kept package and the feed's folder go; and
    /// the next launch finds the book there.
    @MainActor
    func testTheDownloadsBecomeBooksInTheFeedsFolder() async throws {
        let fixture = try makeUnsubscribedFeed()
        let model = launchedModel()

        let outcome = await model.returnDownloads(ofFeed: feedID, toFolderID: fixture.folder.id, removingWith: Self.deleteForGood)

        XCTAssertEqual(outcome.returned.map(\.id), [fixture.download.id])
        XCTAssertEqual(outcome.stayed, [])
        XCTAssertEqual(outcome.deletedKeptPackages, 1)
        XCTAssertTrue(outcome.removedFeedFolder)
        XCTAssertFalse(model.library.feedShelf.indexedFeedIDs.contains(feedID), "the gone feed's index is still kept")
        try assertReturned(fixture, toFolder: folderPath, in: model)
    }

    /// When the feed's library folder is gone, its downloads become books at
    /// the library's top level.
    @MainActor
    func testTheDownloadsOfAFeedWhoseFolderIsGoneGoToTheTopLevel() async throws {
        let fixture = try makeUnsubscribedFeed()
        removeAtTheEnd(topLevelPackageNamed: fixture.download.tmbDirectoryName)
        let model = launchedModel()

        let outcome = await model.returnDownloads(ofFeed: feedID, toFolderID: UUID(), removingWith: Self.deleteForGood)

        XCTAssertEqual(outcome.returned.map(\.id), [fixture.download.id])
        try assertReturned(fixture, toFolder: "", in: model)
    }

    /// The return of a feed that left nothing, no download, no row kept, no
    /// index, and no folder, as one unsubscribed before it downloaded
    /// anything, does nothing: it writes no library.json, and it holds no
    /// storage work, so another operation holding it puts nothing off.
    @MainActor
    func testTheReturnOfAFeedThatLeftNothingDoesNothing() async throws {
        saveNow(Library())
        let model = launchedModel()
        // Whatever the launch saved is on disk before the measuring begins.
        LibraryPersistenceService.flushPendingSave()
        let leftNothing = UUID()
        let index = TextMouthPaths.libraryIndexFile
        let before = try FileManager.default.attributesOfItem(atPath: index.path)
        let logged = debugLogLines(containing: "FEED_DOWNLOADS_RETURN").count

        let outcome = await model.returnDownloads(ofFeed: leftNothing, toFolderID: nil, removingWith: Self.deleteForGood)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(outcome, FeedDownloadReturn())
        let after = try FileManager.default.attributesOfItem(atPath: index.path)
        XCTAssertEqual(after[.systemFileNumber] as? NSNumber, before[.systemFileNumber] as? NSNumber, "library.json was written")
        XCTAssertEqual(after[.modificationDate] as? Date, before[.modificationDate] as? Date, "library.json was written")

        let hold = try StorageBoundary.shared.holdWork(for: .rebuildingDirectory)
        let whileHeld = await model.returnDownloads(ofFeed: leftNothing, toFolderID: nil, removingWith: Self.deleteForGood)
        hold.release()

        XCTAssertEqual(whileHeld, FeedDownloadReturn())
        XCTAssertEqual(debugLogLines(containing: "FEED_DOWNLOADS_RETURN").count, logged, "the return asked for the storage work, or saved")
    }

    /// A feed that left only its folder, its index listing nothing, left
    /// something: its return removes the folder.
    @MainActor
    func testTheReturnOfAFeedThatLeftOnlyItsFolderRemovesIt() async throws {
        // A save writes an index of no rows only into a folder that is there.
        try FileManager.default.createDirectory(at: feedFolderURL, withIntermediateDirectories: true)
        saveNow(Library(feedShelf: FeedShelf(indexedFeedIDs: [feedID])))
        XCTAssertTrue(FileManager.default.fileExists(atPath: feedIndexURL.path), "the feed's empty index was not written")
        let model = launchedModel()

        let outcome = await model.returnDownloads(ofFeed: feedID, toFolderID: nil, removingWith: Self.deleteForGood)

        XCTAssertTrue(outcome.removedFeedFolder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: feedFolderURL.path), "the feed's folder stayed")
    }

    /// A row that is no feed item's, or names no package the library
    /// manages, is refused before anything on disk is touched.
    func testTheReturnRefusesARowNamingNoManagedPackage() throws {
        let fixture = try makeUnsubscribedFeed()
        var unnamed = fixture.download
        unnamed.tmbDirectoryName = ""
        var ownBook = fixture.download
        ownBook.feedLink = nil

        for row in [unnamed, ownBook] {
            XCTAssertThrowsError(try LibraryViewModel.moveIntoTheLibrary(row, folderPath: folderPath, root: TextMouthPaths.root)) { error in
                XCTAssertEqual(error as? FeedItemMoveError, .packageNotManaged)
            }
        }
        XCTAssertThrowsError(try LibraryViewModel.moveIntoTheLibrary(fixture.download, folderPath: "../Outside", root: TextMouthPaths.root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.download.filePath), "the download moved")
    }

    // MARK: - At Launch

    /// The launch finds the feed's folder with no record of it, and returns
    /// its download to the library's top level, since nothing names the
    /// feed's folder any more; a subscribed feed, and a feed whose record
    /// file is there though it could not be read, are left alone.
    @MainActor
    func testTheLaunchReturnsTheDownloadsOfAFeedWhoseRecordIsGone() async throws {
        let fixture = try makeUnsubscribedFeed()
        removeAtTheEnd(topLevelPackageNamed: fixture.download.tmbDirectoryName)
        let model = launchedModel()
        let others = model.library.feedShelf.indexedFeedIDs.subtracting([feedID])

        XCTAssertEqual(model.feedsWithoutRecords(knownFeeds: others.union([feedID])), [])
        let record = FeedPaths.recordFile(of: feedID, in: FeedPaths.recordsFolder(in: TextMouthPaths.root))
        try Data("{ unreadable".utf8).write(to: record)
        XCTAssertEqual(model.feedsWithoutRecords(knownFeeds: others), [], "a feed whose record file is there was taken for gone")
        try FileManager.default.removeItem(at: record)
        XCTAssertEqual(model.feedsWithoutRecords(knownFeeds: others), [feedID])

        let returned = await model.returnDownloadsOfFeedsWithoutRecords(knownFeeds: others, removingWith: Self.deleteForGood)

        XCTAssertEqual(returned, 1)
        try assertReturned(fixture, toFolder: "", in: model)
    }

    /// A feed whose index is left alone, as one only in the cloud, is never
    /// taken for gone: its rows here may be only some of its own.
    @MainActor
    func testAFeedWhoseIndexIsLeftAloneIsNotTakenForGone() throws {
        _ = try makeUnsubscribedFeed()
        let model = launchedModel()
        let others = model.library.feedShelf.indexedFeedIDs.subtracting([feedID])
        model.library.feedShelf.leaveIndexAlone(of: feedID)

        XCTAssertEqual(model.feedsWithoutRecords(knownFeeds: others), [])
    }

    // MARK: - At Launch, in a Cloud Library

    /// Unsubscribe on another Mac moves the feed's downloads itself, and the
    /// record's removal can reach this Mac before those moves: in a cloud
    /// library the first launch that finds the record gone returns nothing
    /// and notes it, asking twice at that launch counts once, and a later
    /// launch that finds it still gone returns the download as the library's
    /// own, the note going with the feed's folder.
    @MainActor
    func testInACloudLibraryARecordGoneAtTwoLaunchesReturnsTheDownloads() async throws {
        let fixture = try makeUnsubscribedFeed()
        removeAtTheEnd(topLevelPackageNamed: fixture.download.tmbDirectoryName)
        let model = launchedModel()
        let others = model.library.feedShelf.indexedFeedIDs.subtracting([feedID])
        let first = Self.thisMac(at: UUID())

        let atFirst = await model.returnDownloadsOfFeedsWithoutRecords(knownFeeds: others, absence: first, removingWith: Self.deleteForGood)
        let again = await model.returnDownloadsOfFeedsWithoutRecords(knownFeeds: others, absence: first, removingWith: Self.deleteForGood)

        XCTAssertEqual(atFirst, 0, "a record gone at one launch returned the downloads")
        XCTAssertEqual(again, 0, "one launch counted as two")
        try assertStaysInItsFeed(fixture.download, in: model)
        XCTAssertEqual(try absenceNotes(), [Self.noteName(at: first)])

        let atSecond = await model.returnDownloadsOfFeedsWithoutRecords(
            knownFeeds: others,
            absence: Self.thisMac(at: UUID()),
            removingWith: Self.deleteForGood
        )

        XCTAssertEqual(atSecond, 1)
        try assertReturned(fixture, toFolder: "", in: model)
    }

    /// A feed subscribed on another Mac can reach this one as its folder
    /// before its record: the first launch returns nothing and notes the
    /// absence, and once the record is here the next launch returns nothing
    /// and takes the note away, so a later absence begins again: a launch
    /// after that, the record gone, only notes it.
    @MainActor
    func testInACloudLibraryAFolderThatArrivesBeforeItsRecordStaysInItsFeed() async throws {
        let fixture = try makeUnsubscribedFeed()
        let model = launchedModel()
        let others = model.library.feedShelf.indexedFeedIDs.subtracting([feedID])
        let third = Self.thisMac(at: UUID())

        let beforeTheRecord = await model.returnDownloadsOfFeedsWithoutRecords(
            knownFeeds: others,
            absence: Self.thisMac(at: UUID()),
            removingWith: Self.deleteForGood
        )
        XCTAssertEqual(try absenceNotes().count, 1)
        let withTheRecord = await model.returnDownloadsOfFeedsWithoutRecords(
            knownFeeds: others.union([feedID]),
            absence: Self.thisMac(at: UUID()),
            removingWith: Self.deleteForGood
        )
        XCTAssertEqual(try absenceNotes(), [], "the note outlived the record's arrival")
        let goneAgain = await model.returnDownloadsOfFeedsWithoutRecords(knownFeeds: others, absence: third, removingWith: Self.deleteForGood)

        XCTAssertEqual([beforeTheRecord, withTheRecord, goneAgain], [0, 0, 0])
        try assertStaysInItsFeed(fixture.download, in: model)
        XCTAssertEqual(try absenceNotes(), [Self.noteName(at: third)])
    }

    /// Another Mac's note of the absence counts for nothing on this Mac, and
    /// stays; a record the records' folder shows only as an older iCloud
    /// Drive's placeholder is a record here, so nothing is returned and this
    /// Mac's note goes; and in a library not in the cloud, the first launch
    /// returns the download, as it always did.
    @MainActor
    func testOnlyThisMacsEarlierLaunchCountsAndAPlaceholderIsARecord() async throws {
        let fixture = try makeUnsubscribedFeed()
        removeAtTheEnd(topLevelPackageNamed: fixture.download.tmbDirectoryName)
        let model = launchedModel()
        let others = model.library.feedShelf.indexedFeedIDs.subtracting([feedID])
        let otherMac = FeedRecordAbsence(isCloud: true, macID: UUID().uuidString, launchID: UUID())
        XCTAssertFalse(otherMac.wasGoneAtAnEarlierLaunch(feed: feedID, folder: feedFolderURL))

        let afterTheOtherMac = await model.returnDownloadsOfFeedsWithoutRecords(
            knownFeeds: others,
            absence: Self.thisMac(at: UUID()),
            removingWith: Self.deleteForGood
        )
        XCTAssertEqual(afterTheOtherMac, 0, "another Mac's note counted on this one")
        XCTAssertEqual(try absenceNotes().count, 2)

        let records = FeedPaths.recordsFolder(in: TextMouthPaths.root)
        let placeholder = records.appendingPathComponent(FeedRecordAbsence.placeholderName(of: "\(feedID.uuidString).json"))
        XCTAssertEqual(placeholder.lastPathComponent, ".\(feedID.uuidString).json.icloud")
        try Data().write(to: placeholder)
        addTeardownBlock { try? FileManager.default.removeItem(at: placeholder) }
        XCTAssertEqual(model.feedsWithoutRecords(knownFeeds: others), [], "a placeholder of the record was taken for none")
        let withAPlaceholder = await model.returnDownloadsOfFeedsWithoutRecords(
            knownFeeds: others,
            absence: Self.thisMac(at: UUID()),
            removingWith: Self.deleteForGood
        )
        XCTAssertEqual(withAPlaceholder, 0)
        XCTAssertEqual(try absenceNotes().map { $0.hasPrefix(FeedRecordAbsence.notePrefix + otherMac.macID) }, [true])
        try assertStaysInItsFeed(fixture.download, in: model)

        try FileManager.default.removeItem(at: placeholder)
        let local = FeedRecordAbsence(isCloud: false, macID: Self.thisMacID, launchID: UUID())
        let returned = await model.returnDownloadsOfFeedsWithoutRecords(knownFeeds: others, absence: local, removingWith: Self.deleteForGood)

        XCTAssertEqual(returned, 1)
        try assertReturned(fixture, toFolder: "", in: model)
    }

    // MARK: - A Crash Between Two Steps

    /// A crash once the download's package moved into the library folder,
    /// before its record was written there.
    @MainActor
    func testACrashAfterThePackageMovesIsFinished() async throws {
        try await assertCrashIsFinished(after: .packageMoved)
    }

    /// A crash once the record was written, before library.json was.
    @MainActor
    func testACrashAfterTheRecordIsWrittenIsFinished() async throws {
        try await assertCrashIsFinished(after: .recordWritten)
    }

    /// A crash once library.json listed the book, before the kept package
    /// and the feed's folder went.
    @MainActor
    func testACrashAfterLibraryJSONIsWrittenIsFinished() async throws {
        try await assertCrashIsFinished(after: .libraryWritten)
    }

    /// A crash once the kept package went, before the feed's folder did.
    @MainActor
    func testACrashAfterTheKeptPackageGoesIsFinished() async throws {
        try await assertCrashIsFinished(after: .keptPackageDeleted)
    }

    // MARK: - The Fixture

    /// The steps of the return after which a crash is finished.
    enum Step {
        /// The download's package moved into the feed's library folder.
        case packageMoved
        /// Its record was written there.
        case recordWritten
        /// library.json listed it as a book.
        case libraryWritten
        /// The package kept for a removed download went.
        case keptPackageDeleted
    }

    /// A feed whose record is gone, as its folder holds it.
    struct UnsubscribedFeed {
        /// The library folder that was the feed's: this test's folder.
        var folder: BookFolder
        /// A book of the library's own in that folder.
        var book: Book
        /// The download the listener opened, with a place and a bookmark,
        /// on the reading list.
        var download: Book
        /// The row kept after another download went, its package without
        /// its file.
        var kept: Book
    }

    /// This test's feed's folder holding a download the listener opened,
    /// with a place and a bookmark, and a package kept after its download
    /// went, beside a book of the library's own in this test's folder, the
    /// feed's library folder; the reading list holds the download, then the
    /// book; library.json and the feed's index are on disk.
    private func makeUnsubscribedFeed() throws -> UnsubscribedFeed {
        let folder = BookFolder(name: folderPath)
        let book = try makePackagedBook(title: "Middlemarch")
        var download = try makeFeedItem(title: "Lamentable Lemmings", lastOpened: Self.date(60), position: Self.position(1_234, at: 60))
        // A whole second, which ISO 8601 dates keep exactly, so the bookmark
        // read back compares equal.
        download.bookmarks = [Bookmark(number: 1, chapterIndex: 0, characterOffset: 300, label: "The cliff", dateCreated: Self.date(45))]
        try download.makeBookInfo().save(to: download.tmbDirectory)
        let kept = try makeFeedItem(title: "Kept Article", lastOpened: Self.date(30), position: Self.position(55, at: 30))
        try FileManager.default.removeItem(at: kept.bookFileURL)
        var list = ReadingList()
        _ = list.append([download.id, book.id])
        saveNow(Library(books: [book, download], folders: [folder], readingList: list, feedShelf: FeedShelf(rows: [kept])))
        return UnsubscribedFeed(folder: folder, book: book, download: download, kept: kept)
    }

    /// Leaves on disk what a crash after `step` of Unsubscribe's return into
    /// the feed's folder leaves, then launches, finds the feed without its
    /// record, and saves, as the next launch does, and asserts that the
    /// download ends as an uninterrupted return leaves it.
    @MainActor
    private func assertCrashIsFinished(after step: Step, file: StaticString = #filePath, line: UInt = #line) async throws {
        let fixture = try makeUnsubscribedFeed()
        let root = TextMouthPaths.root
        if step == .packageMoved {
            var moved = fixture.download
            moved.feedLink = nil
            moved.folderPath = folderPath
            try FileManager.default.moveItem(at: fixture.download.tmbDirectory, to: moved.packageDirectory(inDataDirectory: root))
        } else {
            let returned = try LibraryViewModel.moveIntoTheLibrary(fixture.download, folderPath: folderPath, root: root)
            if step != .recordWritten {
                var list = ReadingList()
                _ = list.append([returned.id, fixture.book.id])
                saveNow(Library(
                    books: [fixture.book, returned],
                    folders: [fixture.folder],
                    readingList: list,
                    feedShelf: FeedShelf(rows: [fixture.kept], indexesLeftAlone: [feedID])
                ))
            }
            if step == .keptPackageDeleted {
                try FileManager.default.removeItem(at: fixture.kept.tmbDirectory)
            }
        }

        let model = launchedModel()
        let others = model.library.feedShelf.indexedFeedIDs.subtracting([feedID])
        await model.returnDownloadsOfFeedsWithoutRecords(knownFeeds: others, removingWith: Self.deleteForGood)
        model.save()
        LibraryPersistenceService.flushPendingSave()

        try assertReturned(fixture, toFolder: folderPath, in: model, file: file, line: line)
    }

    /// Asserts that the download is a book of the library's own in the
    /// library folder `folder`, with everything the listener left, as `model`
    /// holds it, as library.json and its record hold it, and as the next
    /// launch finds it; that the kept package and the feed's folder are gone;
    /// and that the book of the library's own is as it was.
    @MainActor
    private func assertReturned(
        _ fixture: UnsubscribedFeed,
        toFolder folder: String,
        in model: LibraryViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let download = fixture.download
        let row = try XCTUnwrap(model.bookByID(download.id), "the download left the library", file: file, line: line)
        XCTAssertNil(row.feedLink, file: file, line: line)
        XCTAssertEqual(row.folderPath, folder, file: file, line: line)
        XCTAssertEqual(row.readingPosition, download.readingPosition, file: file, line: line)
        XCTAssertEqual(row.bookmarks, download.bookmarks, file: file, line: line)
        XCTAssertEqual(row.lastOpened, download.lastOpened, file: file, line: line)
        let library = TextMouthPaths.libraryDir
        let expectedFolder = folder.isEmpty ? library : library.appendingPathComponent(folder, isDirectory: true)
        XCTAssertEqual(row.tmbDirectory.standardizedFileURL.path, expectedFolder.appendingPathComponent(download.tmbDirectoryName).standardizedFileURL.path, file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.filePath), "the book's file is not where its row says", file: file, line: line)
        XCTAssertEqual(model.library.books.filter { $0.id == download.id }.count, 1, file: file, line: line)
        XCTAssertFalse(model.library.feedShelf.rows.contains { $0.feedLink?.feedID == feedID }, "a row of the feed is still on the shelf", file: file, line: line)
        XCTAssertEqual(model.readingList.bookIDs, [download.id, fixture.book.id], file: file, line: line)

        XCTAssertTrue(try libraryJSONBookIDs().contains(download.id), "library.json does not list the book", file: file, line: line)
        try assertLibraryJSONHoldsNoFeedItem(file: file, line: line)
        let record = try BookInfo.load(from: row.tmbDirectory)
        XCTAssertEqual(record.metadata.bookID, download.id, file: file, line: line)
        XCTAssertEqual(record.metadata.folderPath, folder, file: file, line: line)
        XCTAssertEqual(record.metadata.feedLink, download.feedLink, "the record forgot the feed the book came from", file: file, line: line)
        XCTAssertEqual(record.state.readingPosition, download.readingPosition, file: file, line: line)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.kept.tmbDirectory.path), "the kept package stayed", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: feedFolderURL.path), "the feed's folder stayed", file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.book.filePath), file: file, line: line)

        let next = launchedModel()
        XCTAssertEqual(next.bookByID(download.id)?.folderPath, folder, file: file, line: line)
        XCTAssertNil(next.bookByID(download.id)?.feedLink, file: file, line: line)
        XCTAssertEqual(next.bookByID(download.id)?.readingPosition, download.readingPosition, file: file, line: line)
    }

    /// The ID of the Mac these tests run as, as a note of a record's absence
    /// names it.
    private static let thisMacID = UUID().uuidString

    /// How this Mac judges a record gone in a cloud library at the launch
    /// `launch`.
    private static func thisMac(at launch: UUID) -> FeedRecordAbsence {
        FeedRecordAbsence(isCloud: true, macID: thisMacID, launchID: launch)
    }

    /// The name of the note `absence` leaves at its launch.
    private static func noteName(at absence: FeedRecordAbsence) -> String {
        "\(FeedRecordAbsence.notePrefix)\(absence.macID)-\(absence.launchID.uuidString)"
    }

    /// The notes of a record's absence in this test's feed's folder, by
    /// name, in order.
    private func absenceNotes() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: feedFolderURL.path)
            .filter { $0.hasPrefix(FeedRecordAbsence.notePrefix) }
            .sorted()
    }

    /// Asserts that `download` is still its feed's item among `model`'s
    /// books, its package in its feed's folder, as no return touched it.
    @MainActor
    private func assertStaysInItsFeed(_ download: Book, in model: LibraryViewModel, file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try XCTUnwrap(model.bookByID(download.id), "the download left the library", file: file, line: line)
        XCTAssertEqual(row.feedLink, download.feedLink, "the download left its feed", file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.filePath), "the download's file moved", file: file, line: line)
        XCTAssertEqual(model.library.feedShelf.rows.filter { $0.feedLink?.feedID == feedID }.count, 1, "the kept row left", file: file, line: line)
    }

    /// Removes, when the test ends, the package named `name` that a return
    /// to the library's top level puts there, outside this test's folder.
    private func removeAtTheEnd(topLevelPackageNamed name: String) {
        let package = TextMouthPaths.libraryDir.appendingPathComponent(name, isDirectory: true)
        addTeardownBlock {
            LibraryPersistenceService.flushPendingSave()
            try? FileManager.default.removeItem(at: package)
        }
    }

    /// Removes the item at `url` for good, never to the Trash, as a test
    /// must.
    private static func deleteForGood(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

// MARK: - The Unsubscribe Command

/// Unsubscribe… through the feed commands' runner, as the Library window runs
/// it (FR11, branch D): its question says the feed stays with its download
/// and what it kept of removed downloads goes; confirmed, only checking
/// stops: the feed keeps its record, its folder, its settings, and its
/// download, its item in its own folder, VoiceOver hears so at once, and the
/// package kept after another download went is deleted. Resubscribe checks
/// it again at once.
final class LibraryFeedUnsubscribeCommandTests: XCTestCase {

    /// The download the listener kept and the package kept after another
    /// download went: the question says so, and Unsubscribe keeps the first
    /// in its feed and deletes the second, the feed's index written without
    /// it first; a second Unsubscribe changes nothing.
    @MainActor
    func testUnsubscribeKeepsTheFeedAndDeletesWhatItKeptOfRemovedDownloads() async throws {
        let world = try FeedTestWorld(self, label: "LibraryFeedUnsubscribe")
        let (feed, books) = try await downloadedEpisodes(2, in: world)
        let keptBook = try XCTUnwrap(books.first)
        let download = try XCTUnwrap(books.last)
        world.library.persistReadingPosition(bookID: keptBook.id, position: ReadingPosition(chapterIndex: 0, characterOffset: 42))
        try world.center.deleteDownload("guid:ep-1", of: feed.id)
        XCTAssertEqual(world.library.feedItemRows(of: feed.id).kept["guid:ep-1"]?.id, keptBook.id, "the opened download's package was not kept")
        world.center.setDeleteDownloadsDaysAfterPlayed(3, of: feed.id)
        let presenter = LibraryFeedsPresenter()
        let heard = Heard()
        presenter.announce = { message, _ in heard.lines.append(message) }
        let context = FeedCommandContext(center: world.center, library: world.library, window: nil)

        // It deletes something, so it asks first (FR14), naming only what
        // the kept package holds, a place (REV13 item 5).
        let action = try XCTUnwrap(FeedAction.actions(for: feed.id, in: world.center).first { $0.command == .unsubscribe })
        XCTAssertEqual(action.title, "Unsubscribe…")
        XCTAssertEqual(action.role, .destructive)
        XCTAssertTrue(FeedInfoModel(feedID: feed.id, center: world.center, library: world.library).unsubscribeAsks, "Feed Info's button would not ask")
        let confirmation = try XCTUnwrap(presenter.requestUnsubscribe(feed.id, in: context))
        XCTAssertEqual(
            confirmation.message,
            "TextMouth stops checking this feed for new episodes. The feed stays in your library with its settings and its "
                + "downloaded episode, and Resubscribe checks it again. It also deletes the place kept for 1 removed download."
        )
        XCTAssertEqual(world.center.store.record(of: feed.id)?.feed.isSubscribed, true, "asking unsubscribed")
        // The question carries the items whose kept packages it names, and
        // confirming deletes those (REV14 feeds 1).
        guard case let .unsubscribe(questionFeedID, keptItemIDs) = confirmation.kind else {
            return XCTFail("Unsubscribe asked another question: \(confirmation.kind)")
        }
        XCTAssertEqual(questionFeedID, feed.id)
        XCTAssertEqual(keptItemIDs, ["guid:ep-1"])

        let title = try XCTUnwrap(world.center.store.record(of: feed.id)?.feed.title)
        let outcome = presenter.unsubscribe(feed.id, deletingKeptOf: keptItemIDs, in: context)

        XCTAssertEqual(outcome, FeedUnsubscribeOutcome(downloadCount: 1, deletedKeptCount: 1))
        // Said once the question's alert has closed (REV13 item 1).
        let unsubscribed = "Unsubscribed from \(title): TextMouth no longer checks it for new episodes; its downloaded episode stays. "
            + "The place kept for 1 removed download was deleted."
        await waitFor("the unsubscription is said") { heard.lines.last == unsubscribed }
        let record = try XCTUnwrap(world.center.store.record(of: feed.id), "unsubscribing removed the feed's record")
        XCTAssertFalse(record.feed.isSubscribed)
        XCTAssertEqual(record.feed.unsubscribedDate, world.clock.value)
        XCTAssertEqual(record.feed.folderID, feed.folderID)
        XCTAssertEqual(record.feed.deleteDownloadsDaysAfterPlayedOverride, 3, "unsubscribing dropped the feed's own setting")
        XCTAssertEqual(record.items.map(\.id), ["guid:ep-1", "guid:ep-2"])
        let stays = try XCTUnwrap(world.library.bookByID(download.id))
        XCTAssertEqual(stays.feedLink, download.feedLink, "the download left its feed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stays.filePath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: keptBook.tmbDirectory.path), "the kept package stayed")
        XCTAssertEqual(world.library.library.feedShelf.rows, [])
        let indexed = try FeedIndexFiles.decoded(Data(contentsOf: FeedPaths.indexFile(of: feed.id, in: TextMouthPaths.root))).books
        XCTAssertEqual(indexed.map(\.id), [download.id], "the feed's index still lists the deleted package")
        XCTAssertNil(presenter.unsubscribeConfirmation(for: feed.id, in: context), "an unsubscribed feed asked to unsubscribe")
        XCTAssertNil(presenter.unsubscribe(feed.id, in: context), "a second Unsubscribe did something")
    }

    /// A package kept after its download went whose item is downloading
    /// again as Unsubscribe is chosen stays, and its download restores it:
    /// the same book, with its place. Unsubscribe would delete nothing
    /// then, so it asks nothing (FR14; REV13 item 5).
    @MainActor
    func testAKeptPackageWhoseItemDownloadsAgainStays() async throws {
        let world = try FeedTestWorld(self, label: "LibraryFeedUnsubscribeRestore")
        let (feed, books) = try await downloadedEpisodes(1, in: world)
        let book = try XCTUnwrap(books.first)
        let place = ReadingPosition(chapterIndex: 0, characterOffset: 42)
        world.library.persistReadingPosition(bookID: book.id, position: place)
        try world.center.deleteDownload("guid:ep-1", of: feed.id)
        XCTAssertEqual(world.center.counts(of: feed.id).keptForRemovedDownloads, 1)
        var slow = FeedMediaFixtures.file(try FeedMediaFixtures.silentAAC(), mimeType: "audio/mp4")
        slow.chunkSize = 512
        slow.pause = 0.05
        world.server.serve("/audio/1.m4a", slow)
        world.center.download("guid:ep-1", of: feed.id)
        await waitFor("the download is under way") { !world.server.requests(to: "/audio/1.m4a").dropFirst().isEmpty }

        XCTAssertEqual(world.center.counts(of: feed.id).keptForRemovedDownloads, 0, "a package downloading again was counted")
        let context = FeedCommandContext(center: world.center, library: world.library, window: nil)
        XCTAssertNil(LibraryFeedsPresenter().unsubscribeConfirmation(for: feed.id, in: context), "Unsubscribe asked about a package it keeps")
        XCTAssertEqual(FeedAction.actions(for: feed.id, in: world.center).first { $0.command == .unsubscribe }?.title, "Unsubscribe")
        let outcome = world.center.unsubscribe(feed.id)

        XCTAssertEqual(outcome?.deletedKeptCount, 0, "a package downloading again was deleted")
        let restored = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        XCTAssertEqual(restored.id, book.id)
        XCTAssertEqual(restored.readingPosition?.characterOffset, place.characterOffset)
    }

    /// The case REV14 found (feeds 1): a package the newest-N rule kept
    /// when it removed the download, its item queued by the rule to download
    /// again and not yet started. Unsubscribe would delete nothing, so it
    /// asks nothing and acts at once; taking back the rule's queued download
    /// then leaves that package with no download to restore it, and it
    /// stays, kept with its place, never deleted unasked. VoiceOver hears no
    /// deletion.
    @MainActor
    func testUnsubscribeAtOnceKeepsAPackageWhoseQueuedDownloadItTakesBack() async throws {
        let world = try FeedTestWorld(self, label: "LibraryFeedUnsubscribeQueued")
        let feed = try await subscribedToEpisodes(2, in: world)
        let kept = try await packageTheRuleKept("guid:ep-1", of: feed, in: world)
        // Episode 2 downloads, slowly, as the listener asked, so the rule's
        // download of episode 1 waits in the queue behind it.
        var slow = FeedMediaFixtures.file(try FeedMediaFixtures.silentAAC(), mimeType: "audio/mp4")
        slow.chunkSize = 512
        slow.pause = 0.05
        world.server.serve("/audio/2.m4a", slow)
        world.center.download("guid:ep-2", of: feed.id)
        world.center.downloads.download("guid:ep-1", of: feed.id, origin: .window)
        XCTAssertEqual(world.center.downloads.current?.itemID, "guid:ep-2")
        XCTAssertEqual(world.center.downloads.queue.map(\.itemID), ["guid:ep-1"], "the rule's download of the kept episode is not queued")
        let presenter = LibraryFeedsPresenter()
        let heard = Heard()
        presenter.announce = { message, _ in heard.lines.append(message) }
        let context = FeedCommandContext(center: world.center, library: world.library, window: nil)
        XCTAssertNil(presenter.unsubscribeConfirmation(for: feed.id, in: context), "Unsubscribe asked about a package downloading again")
        let title = try XCTUnwrap(world.center.store.record(of: feed.id)?.feed.title)

        XCTAssertNil(presenter.requestUnsubscribe(feed.id, in: context), "Unsubscribe asked first")

        XCTAssertEqual(world.center.store.record(of: feed.id)?.feed.isSubscribed, false)
        XCTAssertFalse(world.center.downloads.isDownloading("guid:ep-1", of: feed.id), "the rule's queued download stayed")
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state, .notDownloaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.tmbDirectory.path), "Unsubscribe deleted a kept package it never asked about")
        XCTAssertEqual(world.library.feedItemRows(of: feed.id).kept["guid:ep-1"]?.readingPosition?.characterOffset, 42)
        XCTAssertEqual(world.removedItems.value, [], "something went through the listener's removal")
        XCTAssertEqual(heard.lines, ["Unsubscribed from \(title): TextMouth no longer checks it for new episodes."])
        world.center.cancelDownload("guid:ep-2", of: feed.id)
        await waitFor("episode 2's download stops") { world.center.downloads.current == nil }
    }

    /// Confirming Unsubscribe's question deletes the kept packages it named
    /// and no other (REV14 feeds 1): one the newest-N rule kept while the
    /// question was up, removing its download, stays with its place, and
    /// VoiceOver hears only the one named go.
    @MainActor
    func testConfirmingUnsubscribeDeletesOnlyWhatItsQuestionNamed() async throws {
        let world = try FeedTestWorld(self, label: "LibraryFeedUnsubscribeNamed")
        let feed = try await subscribedToEpisodes(2, in: world)
        let named = try await packageTheRuleKept("guid:ep-1", of: feed, in: world)
        world.center.downloads.download("guid:ep-2", of: feed.id, origin: .window)
        let download = try await downloadedBook(world, feed: feed, item: "guid:ep-2")
        world.library.persistReadingPosition(bookID: download.id, position: ReadingPosition(chapterIndex: 0, characterOffset: 7))
        let presenter = LibraryFeedsPresenter()
        let heard = Heard()
        presenter.announce = { message, _ in heard.lines.append(message) }
        let context = FeedCommandContext(center: world.center, library: world.library, window: nil)
        let question = try XCTUnwrap(presenter.requestUnsubscribe(feed.id, in: context))
        XCTAssertTrue(question.message.hasSuffix("It also deletes the place kept for 1 removed download."), question.message)

        // While the question is up, the rule removes episode 2's download,
        // keeping its package with its place.
        let laterKept = try await keepByTheRule("guid:ep-2", of: feed, in: world)
        let title = try XCTUnwrap(world.center.store.record(of: feed.id)?.feed.title)
        presenter.confirm(question, in: context)

        XCTAssertFalse(FileManager.default.fileExists(atPath: named.tmbDirectory.path), "the package the question named stayed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: laterKept.tmbDirectory.path), "Unsubscribe deleted a package its question never named")
        XCTAssertEqual(world.library.feedItemRows(of: feed.id).kept.keys.sorted(), ["guid:ep-2"])
        XCTAssertEqual(world.removedItems.value.map(\.name), [named.tmbDirectoryName])
        let unsubscribed = "Unsubscribed from \(title): TextMouth no longer checks it for new episodes. "
            + "The place kept for 1 removed download was deleted."
        await waitFor("the unsubscription is said") { heard.lines.last == unsubscribed }
    }

    /// Resubscribe checks the feed at once, finding what was published
    /// while it was unsubscribed, and every later check goes on as before; a
    /// second Resubscribe changes nothing.
    @MainActor
    func testResubscribeChecksTheFeedAtOnce() async throws {
        let world = try FeedTestWorld(self, label: "LibraryFeedResubscribe")
        let (feed, _) = try await downloadedEpisodes(1, in: world)
        world.center.unsubscribe(feed.id)
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [
            FeedXML.Item(guid: "ep-0", title: "Episode Zero", published: world.day(1)),
            FeedXML.Item(guid: "ep-1", title: "Episode 1", published: world.day(-1)),
        ])))
        world.advance(by: 2 * 86_400)

        let report = await world.center.resubscribe(feed.id)

        XCTAssertEqual(report?.newItemIDs, ["guid:ep-0"])
        XCTAssertEqual(world.center.store.record(of: feed.id)?.feed.isSubscribed, true)
        XCTAssertNil(world.center.store.record(of: feed.id)?.feed.unsubscribedDate)
        let again = await world.center.resubscribe(feed.id)
        XCTAssertNil(again, "a second Resubscribe checked the feed")
        let summary = await world.center.refreshAll(origin: .listener)
        XCTAssertEqual(summary.reports.map(\.feedID), [feed.id])
    }

    // MARK: - Fixtures

    /// What VoiceOver was asked to say, in order.
    @MainActor
    private final class Heard {
        var lines: [String] = []
    }

    /// Starts `world`'s engine and subscribes it to a feed of `count`
    /// episodes, "Episode 1" ("guid:ep-1") the newest, each a second of
    /// silence served at /audio/<number>.m4a; returns the feed.
    @MainActor
    private func subscribedToEpisodes(_ count: Int, in world: FeedTestWorld) async throws -> Feed {
        await world.start()
        let audio = try FeedMediaFixtures.silentAAC()
        let items = (1...count).map { number in
            world.server.serve("/audio/\(number).m4a", FeedMediaFixtures.file(audio, mimeType: "audio/mp4"))
            return FeedXML.Item(
                guid: "ep-\(number)",
                title: "Episode \(number)",
                published: world.day(Double(-number)),
                enclosure: world.server.url("/audio/\(number).m4a").absoluteString,
                enclosureType: "audio/mp4"
            )
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: items)))
        return try await world.subscribe("/feed.xml")
    }

    /// Starts `world`'s engine, subscribes it to a feed of `count` episodes,
    /// and downloads each; returns the feed and the books, episode 1 first.
    @MainActor
    private func downloadedEpisodes(_ count: Int, in world: FeedTestWorld) async throws -> (Feed, [Book]) {
        let feed = try await subscribedToEpisodes(count, in: world)
        var books: [Book] = []
        for number in 1...count {
            world.center.download("guid:ep-\(number)", of: feed.id)
            books.append(try await downloadedBook(world, feed: feed, item: "guid:ep-\(number)"))
        }
        return (feed, books)
    }

    /// Downloads the episode `itemID` of `feed` as the newest-N rule asks
    /// for one, gives it a place, as listening to it does, and has the rule
    /// remove its download again (`keepByTheRule(_:of:in:)`), which keeps
    /// its package with that place; returns the row kept on the feed's
    /// shelf.
    @MainActor
    private func packageTheRuleKept(_ itemID: FeedItem.ID, of feed: Feed, in world: FeedTestWorld) async throws -> Book {
        world.center.downloads.download(itemID, of: feed.id, origin: .window)
        let book = try await downloadedBook(world, feed: feed, item: itemID)
        world.library.persistReadingPosition(bookID: book.id, position: ReadingPosition(chapterIndex: 0, characterOffset: 42))
        return try await keepByTheRule(itemID, of: feed, in: world)
    }

    /// Has the newest-N rule remove the download of the episode `itemID` of
    /// `feed`, as it removes one outside the newest, which keeps its package
    /// while the package holds the listener's place (FR11, branch A2), the
    /// item staying the rule's; returns the row kept on the feed's shelf.
    @MainActor
    private func keepByTheRule(_ itemID: FeedItem.ID, of feed: Feed, in world: FeedTestWorld) async throws -> Book {
        let book = try XCTUnwrap(world.library.feedItemRows(of: feed.id).downloaded[itemID], "\(itemID) is not downloaded")
        let outcome = await world.center.removeDue(
            [FeedDueRemoval(feedID: feed.id, itemID: itemID, book: book, reason: "outside the newest 1")],
            from: world.library,
            by: "the newest-N rule",
            at: world.clock.value,
            putOffEvent: "FEED_RULE_PUT_OFF"
        )
        XCTAssertEqual(outcome.removed.map(\.keepsPackage), [true], "the rule's removal kept no package")
        return try XCTUnwrap(world.library.feedItemRows(of: feed.id).kept[itemID], "no row of \(itemID) was kept")
    }
}
