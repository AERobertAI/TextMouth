import XCTest
@testable import TextMouth

/// Delete Feed… in the feed engine (FR14, `FeedCenter.deleteFeed(_:)`): the
/// feed goes entirely, its record, its fetch details, its downloads under way
/// with every part of them, its downloads and the packages it kept for
/// removed ones, its rows on the reading list, its own folder in the data
/// directory, and its library folder when nothing else is in it, while an
/// item moved into the library stays; every stopping point leaves the feed
/// or nothing, and nothing the listener deleted comes back at the next
/// launch. Against a stub server; no episode is played, and nothing goes to
/// the Trash: the test world deletes for good.
@MainActor
final class FeedDeleteFeedTests: XCTestCase {

    // MARK: - Everything of the Feed Goes

    /// The feed's record and fetch details go, its download and the package
    /// kept for a removed download go through the listener's own removal,
    /// the download leaves the reading list and the library, the feed's own
    /// folder goes with its index, and its library folder, holding nothing
    /// else, goes too; the outcome counts each, and the debug log says so.
    func testDeleteFeedRemovesTheFeedAndEverythingOfIt() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeleteAll")
        let fixture = try await feedWithAKeptPlaceAndADownload(in: world)
        let feedID = fixture.feed.id
        let folderPath = try XCTUnwrap(world.library.feedFolderPath(forFolderID: fixture.feed.folderID))
        let itemsFolder = FeedPaths.itemsFolder(of: feedID, in: TextMouthPaths.root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: itemsFolder.path))
        await world.center.fetchStates.flush()
        let fetchStateFile = FeedPaths.recordFile(of: feedID, in: world.fetchStateFolder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fetchStateFile.path), "the feed had no fetch details to delete")
        let logLine = "FEED_DELETED: \(fixture.feed.title): 1 download and 1 package kept for removed downloads deleted; "
            + "its library folder deleted"
        let linesBefore = debugLogLines(containing: logLine).count

        let outcome = try await world.center.deleteFeed(feedID)

        XCTAssertEqual(outcome, FeedDeleteOutcome(
            title: fixture.feed.title,
            deletedDownloads: 1,
            deletedKeptPlaces: 1,
            folder: .deleted(path: folderPath)
        ))
        XCTAssertNil(world.center.store.record(of: feedID))
        XCTAssertEqual(world.center.feeds, [])
        XCTAssertEqual(world.center.fetchStates.state(of: feedID), FeedFetchState())
        await world.center.store.flush()
        await world.center.fetchStates.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: FeedPaths.recordFile(of: feedID, in: world.recordsFolder).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fetchStateFile.path), "this Mac's fetch details stayed")

        XCTAssertEqual(world.library.everyRow(ofFeed: feedID), [], "a row of the feed stayed")
        XCTAssertNil(world.library.bookByID(fixture.download.id))
        XCTAssertFalse(world.library.readingList.contains(fixture.download.id), "the download stayed on the reading list")
        XCTAssertFalse(world.library.library.feedShelf.indexedFeedIDs.contains(feedID), "the feed's index is still written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: itemsFolder.path), "the feed's own folder stayed")
        XCTAssertEqual(
            Set(world.removedItems.value.map(\.name)),
            [fixture.download.tmbDirectoryName, fixture.kept.tmbDirectoryName, feedID.uuidString],
            "something went other than through the listener's own removal"
        )
        XCTAssertNil(world.library.library.folders.first { $0.id == fixture.feed.folderID }, "the empty library folder stayed")
        XCTAssertFalse(world.center.downloads.isClosed(feedID))
        XCTAssertEqual(debugLogLines(containing: logLine).count, linesBefore + 1, "the deletion was not logged")
    }

    /// The next launch finds nothing of the deleted feed: no row in
    /// library.json or in any feed's index, and no feed whose downloads it
    /// would return to the library.
    func testTheNextLaunchFindsNothingOfADeletedFeed() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeleteLaunch")
        let fixture = try await feedWithAKeptPlaceAndADownload(in: world)
        let feedID = fixture.feed.id

        try await world.center.deleteFeed(feedID)
        let next = await launchedLibrary(of: world)
        let returned = await next.returnDownloadsOfFeedsWithoutRecords(
            knownFeeds: next.library.feedShelf.indexedFeedIDs.subtracting([feedID]),
            absence: FeedRecordAbsence(isCloud: false, macID: "", launchID: UUID()),
            removingWith: Self.deleteForGood
        )

        XCTAssertEqual(returned, 0, "the next launch returned a deleted download")
        XCTAssertEqual(next.everyRow(ofFeed: feedID), [])
        XCTAssertNil(next.bookByID(fixture.download.id))
        XCTAssertNil(next.bookByID(fixture.kept.id))
        XCTAssertFalse(next.library.feedShelf.indexedFeedIDs.contains(feedID))
    }

    // MARK: - Every Stopping Point

    /// A feed's own folder that cannot be removed stays, the record going
    /// all the same, as a stop between the two would leave it: the next
    /// launch finds the folder without its record and deletes it, returning
    /// nothing, since none of the feed's downloads is left in it.
    func testAFolderLeftWithoutItsRecordReturnsNothingAtTheNextLaunch() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeleteFolderLeft")
        let fixture = try await feedWithAKeptPlaceAndADownload(in: world)
        let feedID = fixture.feed.id
        let itemsFolder = FeedPaths.itemsFolder(of: feedID, in: TextMouthPaths.root)
        world.refusesRemovalsNamed.value = [feedID.uuidString]

        let outcome = try await world.center.deleteFeed(feedID)

        XCTAssertEqual(outcome?.deletedDownloads, 1)
        XCTAssertNil(world.center.store.record(of: feedID), "the record stayed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: itemsFolder.path), "the folder the test kept went")
        XCTAssertEqual(debugLogLines(containing: "FEED_DELETE_FOLDER_LEFT: \(feedID.uuidString.prefix(8))").count, 1)
        let leftInIt = try FileManager.default.contentsOfDirectory(atPath: itemsFolder.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(leftInIt, [FeedPaths.indexFileName], "a package of the deleted feed is left")

        let next = await launchedLibrary(of: world)
        let returned = await next.returnDownloadsOfFeedsWithoutRecords(
            knownFeeds: next.library.feedShelf.indexedFeedIDs.subtracting([feedID]),
            absence: FeedRecordAbsence(isCloud: false, macID: "", launchID: UUID()),
            removingWith: Self.deleteForGood
        )

        XCTAssertEqual(returned, 0, "the launch returned a deleted download")
        XCTAssertFalse(FileManager.default.fileExists(atPath: itemsFolder.path), "the launch left the folder")
        XCTAssertNil(next.bookByID(fixture.download.id))
        XCTAssertEqual(next.everyRow(ofFeed: feedID), [])
    }

    /// A package that cannot be deleted stops the deletion there: the feed
    /// keeps its record, its folder, and that download, listed as before,
    /// and the error names it; what could go went.
    func testAPackageThatCannotBeDeletedKeepsTheFeed() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeletePackageStays")
        let fixture = try await feedWithAKeptPlaceAndADownload(in: world)
        let feedID = fixture.feed.id
        world.refusesRemovalsNamed.value = [fixture.download.tmbDirectoryName]
        let stoppedLine = "FEED_DELETE_STOPPED: \(fixture.feed.title)"
        let linesBefore = debugLogLines(containing: stoppedLine).count

        do {
            try await world.center.deleteFeed(feedID)
            XCTFail("a feed whose download could not be deleted was deleted")
        } catch {
            guard case .filesStayed(let stayed) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(stayed.count, 1)
            XCTAssertTrue(stayed.first?.hasPrefix("\(fixture.download.title): ") == true, "\(stayed)")
        }

        XCTAssertNotNil(world.center.store.record(of: feedID), "the record went with a download left")
        XCTAssertEqual(world.library.bookByID(fixture.download.id)?.feedLink, fixture.download.feedLink, "the download left its feed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.download.filePath))
        XCTAssertNil(world.library.feedItemRows(of: feedID).kept["guid:ep-1"], "the kept package that went is still listed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: FeedPaths.itemsFolder(of: feedID, in: TextMouthPaths.root).path))
        XCTAssertNotNil(world.library.library.folders.first { $0.id == fixture.feed.folderID })
        XCTAssertFalse(world.center.downloads.isClosed(feedID), "the feed's items can't be downloaded again")
        XCTAssertEqual(debugLogLines(containing: stoppedLine).count, linesBefore + 1, "the stop was not logged")
    }

    /// When the library's indexes cannot be written, nothing is deleted:
    /// every file and row stays, and the feed with them.
    func testAFailedIndexWriteDeletesNothing() async throws {
        let failures = cleanSharedFailureCenter()
        let world = try FeedTestWorld(self, label: "FeedDeleteIndexFails")
        let fixture = try await feedWithAKeptPlaceAndADownload(in: world)
        let feedID = fixture.feed.id
        LibraryPersistenceService.flushPendingSave()
        let obstruction = try WriteObstruction.place(at: FeedPaths.indexFile(of: feedID, in: TextMouthPaths.root))
        defer { obstruction.clear() }

        do {
            try await world.center.deleteFeed(feedID)
            XCTFail("a feed was deleted though its index could not be written")
        } catch {
            XCTAssertEqual(error, .indexNotWritten)
        }

        XCTAssertNotNil(world.center.store.record(of: feedID))
        XCTAssertNotNil(world.library.bookByID(fixture.download.id))
        XCTAssertEqual(world.library.feedItemRows(of: feedID).kept["guid:ep-1"]?.id, fixture.kept.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.download.filePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.kept.tmbDirectory.path))
        XCTAssertEqual(world.removedItems.value, [])
        XCTAssertFalse(world.center.downloads.isClosed(feedID))
        XCTAssertEqual(failures.outstandingFailures().map(\.subject), [.libraryIndex])
    }

    // MARK: - What Asks First

    /// Delete Feed… is refused while a download of the feed is open in a
    /// reader, naming it, and nothing is deleted.
    func testDeleteFeedIsRefusedWhileADownloadIsOpen() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeleteOpen")
        let (feed, books) = try await feedWithDownloads(episodes: 2, downloading: 1, in: world, into: .newFolder(inParentPath: world.folder.path))
        let book = try XCTUnwrap(books.first)
        world.library.openBookIDs.insert(book.id)
        defer { world.library.openBookIDs.remove(book.id) }

        do {
            try await world.center.deleteFeed(feed.id)
            XCTFail("a feed whose download is open was deleted")
        } catch {
            XCTAssertEqual(error, .downloadInUse(title: "Episode 1", use: .openInReader))
        }

        XCTAssertNotNil(world.center.store.record(of: feed.id))
        XCTAssertNotNil(world.library.bookByID(book.id))
        XCTAssertEqual(world.removedItems.value, [])
        XCTAssertFalse(world.center.downloads.isClosed(feed.id))
    }

    /// Delete Feed… is refused while a download of the feed is transcribed,
    /// whose transcript would be lost with it (feed follow-ups item 1), or
    /// exported, naming it and how it is in use, and nothing is deleted;
    /// once the work ends, the feed goes.
    func testDeleteFeedIsRefusedWhileADownloadIsTranscribedOrExported() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeleteInUse")
        let (feed, books) = try await feedWithDownloads(episodes: 2, downloading: 1, in: world, into: .newFolder(inParentPath: world.folder.path))
        let book = try XCTUnwrap(books.first)
        let transcriptions = TranscribedBooks.shared
        let transcribingBefore = transcriptions.transcribingBookID
        addTeardownBlock { @MainActor in transcriptions.setTranscribing(transcribingBefore) }
        addTeardownBlock { @MainActor in BookExportModel.noteExportEnded([book.id]) }

        for use in [FeedBookUse.transcribing, .exporting] {
            if use == .transcribing {
                transcriptions.setTranscribing(book.id)
            } else {
                BookExportModel.noteExportStarted([book.id])
            }
            do {
                try await world.center.deleteFeed(feed.id)
                XCTFail("a feed whose download is \(use) was deleted")
            } catch {
                XCTAssertEqual(error, .downloadInUse(title: "Episode 1", use: use))
            }
            XCTAssertNotNil(world.center.store.record(of: feed.id))
            XCTAssertNotNil(world.library.bookByID(book.id))
            XCTAssertEqual(world.removedItems.value, [], "something went while a download was \(use)")
            XCTAssertFalse(world.center.downloads.isClosed(feed.id))
            transcriptions.setTranscribing(nil)
            BookExportModel.noteExportEnded([book.id])
        }

        let outcome = try await world.center.deleteFeed(feed.id)
        XCTAssertEqual(outcome?.deletedDownloads, 1)
        XCTAssertNil(world.center.store.record(of: feed.id))
    }

    /// A feed TextMouth has no record of is deleted by nothing.
    func testDeletingAFeedWithoutARecordDoesNothing() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeleteNone")
        await world.start()

        let outcome = try await world.center.deleteFeed(UUID())

        XCTAssertNil(outcome)
    }

    // MARK: - Downloads Under Way

    /// The download under way stops, and so do those waiting to start: no
    /// package of theirs is made, and every part of the feed's downloads on
    /// this Mac goes, its resume data and the partial file it names, while
    /// another feed's stays.
    func testDownloadsUnderWayStopAndLeaveNoPart() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeleteUnderWay")
        let (feed, _) = try await feedWithDownloads(episodes: 3, downloading: 0, in: world, into: .newFolder(inParentPath: world.folder.path))
        var slow = FeedMediaFixtures.file(try FeedMediaFixtures.silentAAC(), mimeType: "audio/mp4")
        slow.chunkSize = 256
        slow.pause = 0.05
        world.server.serve("/audio/1.m4a", slow)
        let partial = try makePartialDownload(for: "guid:ep-3", of: feed.id, in: world)
        let otherFeeds = try makePartialDownload(for: "guid:ep-1", of: UUID(), in: world)
        world.center.download("guid:ep-1", of: feed.id)
        world.center.download("guid:ep-2", of: feed.id)
        await waitFor("the first download is under way") { !world.server.requests(to: "/audio/1.m4a").isEmpty }

        try await world.center.deleteFeed(feed.id)
        await waitFor("the download under way stops") { world.center.downloads.current == nil }

        XCTAssertEqual(world.center.downloads.queue, [])
        XCTAssertEqual(world.server.requests(to: "/audio/2.m4a"), [], "a download waiting to start was fetched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.resumeData.path), "the feed's resume data stayed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.file.path), "the partial file stayed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherFeeds.resumeData.path), "another feed's resume data went")
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherFeeds.file.path), "another feed's partial file went")
        XCTAssertFalse(FileManager.default.fileExists(atPath: FeedPaths.itemsFolder(of: feed.id, in: TextMouthPaths.root).path))
        XCTAssertEqual(world.library.everyRow(ofFeed: feed.id), [])
    }

    /// A download whose book is being added as its feed is deleted is
    /// discarded, never listed: nothing of a feed being deleted comes back.
    func testAnImportEndingWhileItsFeedIsDeletedIsDiscarded() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeleteImport")
        let (feed, _) = try await feedWithDownloads(episodes: 1, downloading: 0, in: world, into: .newFolder(inParentPath: world.folder.path))
        let downloads = world.center.downloads
        var deletion: Task<FeedDeleteOutcome?, Error>?
        downloads.beforeCommit = { _ in
            // The listener confirms Delete Feed… as the book is added.
            downloads.closeFeed(feed.id)
            deletion = Task { try await world.center.deleteFeed(feed.id) }
        }

        let discardedLine = "FEED_DOWNLOAD_DISCARDED: Episode 1"
        let linesBefore = debugLogLines(containing: discardedLine).count
        world.center.download("guid:ep-1", of: feed.id)
        await waitFor("the deletion begins") { deletion != nil }
        let outcome = try await XCTUnwrap(deletion).value
        await waitFor("the download ends") { world.center.downloads.current == nil }

        XCTAssertNil(outcome, "a feed being deleted was deleted a second time")
        // Discarded as Delete Feed… deletes, through the listener's own
        // removal, never for good behind its back (REV14 feeds 2).
        let discarded = world.removedItems.value.filter { $0.name.hasSuffix(".tmb") }
        XCTAssertEqual(discarded.count, 1, "\(world.removedItems.value)")
        XCTAssertTrue(discarded.first?.contents.contains("Episode 1.m4a") == true, "\(discarded)")
        downloads.reopenFeed(feed.id)
        let ended = try await world.center.deleteFeed(feed.id)
        XCTAssertEqual(ended?.deletedDownloads, 0, "the import that ended was listed")
        XCTAssertEqual(world.library.everyRow(ofFeed: feed.id), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: FeedPaths.itemsFolder(of: feed.id, in: TextMouthPaths.root).path))
        XCTAssertEqual(debugLogLines(containing: discardedLine).count, linesBefore + 1, "the import was not discarded")
    }

    /// Delete Feed… confirmed while a kept episode downloads again, its book
    /// being added, the restore having moved the place kept for it into the
    /// new package: that package goes as its question said, through the
    /// listener's own removal (to the Trash, or for good, as Removal
    /// Behavior says), never for good behind its back, and is counted among
    /// the places kept for removed downloads that went (REV14 feeds 2).
    func testDeleteFeedDuringARestoreRemovesItsPackageAsTheListenersDeletion() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeleteRestoring")
        let fixture = try await feedWithAKeptPlaceAndADownload(in: world)
        let feedID = fixture.feed.id
        let imports = await world.holdImports(self)
        world.center.download("guid:ep-1", of: feedID)
        await waitFor("the kept episode's book is being added") {
            world.center.downloads.progress.state.download?.isAddingToLibrary == true
        }

        let deletion = Task { try await world.center.deleteFeed(feedID) }
        await waitFor("Delete Feed… closes the feed") { world.center.downloads.isClosed(feedID) }
        imports.release()
        let outcome = try await deletion.value

        XCTAssertEqual(outcome?.deletedKeptPlaces, 1)
        XCTAssertEqual(outcome?.deletedDownloads, 1)
        let restored = world.removedItems.value.filter { $0.name == fixture.kept.tmbDirectoryName }
        XCTAssertEqual(restored.count, 1, "the restored package went other than through the listener's own removal")
        XCTAssertTrue(restored.first?.contents.contains(TextMouthPaths.bookInfoFileName) == true, "\(restored)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.kept.tmbDirectory.path))
        XCTAssertNil(world.center.store.record(of: feedID))
        XCTAssertEqual(world.library.everyRow(ofFeed: feedID), [])
    }

    /// The engine's own rules leave a feed being deleted alone: the
    /// after-playing sweep finds nothing due in it, and a removal it found
    /// due before the feed closed removes nothing once it has; reopened, the
    /// feed's played download is removed as before.
    func testTheEnginesOwnRulesLeaveAFeedBeingDeletedAlone() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeleteRulesWait")
        let (feed, books) = try await feedWithDownloads(episodes: 2, downloading: 1, in: world)
        let book = try XCTUnwrap(books.first)
        world.center.setDeleteDownloadsDaysAfterPlayed(0, of: feed.id)
        world.center.markPlayed("guid:ep-1", of: feed.id)
        let downloads = world.center.downloads

        downloads.closeFeed(feed.id)
        let whileClosed = await world.center.sweepPlayedDownloads()
        let collectedBefore = await world.center.removeDue(
            [FeedDueRemoval(feedID: feed.id, itemID: "guid:ep-1", book: book, reason: "played")],
            from: world.library,
            by: "a test",
            at: world.clock.value,
            putOffEvent: "FEED_SWEEP_PUT_OFF"
        )

        XCTAssertEqual(whileClosed.deletedBookIDs, [])
        XCTAssertEqual(collectedBefore.removed, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath), "a rule removed a download of a feed being deleted")

        downloads.reopenFeed(feed.id)
        let reopened = await world.center.sweepPlayedDownloads()
        XCTAssertEqual(reopened.deletedBookIDs, [book.id])
    }

    // MARK: - The Library Folder

    /// The feed's library folder stays when it holds a book of the
    /// library's own, or another feed's items.
    func testTheLibraryFolderStaysWhenSomethingElseIsInIt() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeleteFolderStays")
        let (feed, _) = try await feedWithDownloads(episodes: 1, downloading: 0, in: world)
        let ownBook = Book(
            title: "Middlemarch",
            author: "Eliot",
            format: .txt,
            filePath: "/nonexistent/Middlemarch.txt",
            md5Hash: UUID().uuidString,
            folderPath: world.bookFolder.fullPath
        )
        world.library.library.books.append(ownBook)

        let outcome = try await world.center.deleteFeed(feed.id)

        XCTAssertEqual(outcome?.folder, .stays(path: world.bookFolder.fullPath))
        XCTAssertNotNil(world.library.library.folders.first { $0.id == world.bookFolder.id })
        world.library.library.books.removeAll { $0.id == ownBook.id }

        // Two feeds in one folder: deleting the first leaves it for the second.
        let atlas = try await feedWithDownloads(episodes: 1, downloading: 0, in: world, into: .newFolder(inParentPath: world.folder.path)).feed
        world.server.serve("/second.xml", .feed(FeedXML.rss(title: "The Harbour Log", items: [
            FeedXML.Item(guid: "log-1", title: "Low water", published: world.day(-1)),
        ])))
        let harbour = try await world.center.subscribe(to: world.server.url("/second.xml").absoluteString, folderID: atlas.folderID)
        guard case .subscribed(let second) = harbour else { return XCTFail("\(harbour)") }

        let first = try await world.center.deleteFeed(atlas.id)

        XCTAssertEqual(first?.folder, .stays(path: try XCTUnwrap(world.library.feedFolderPath(forFolderID: atlas.folderID))))
        XCTAssertEqual(world.center.feed(inFolder: atlas.folderID)?.id, second.id)
    }

    // MARK: - What Stays

    /// An item moved into the library (Move to Library…, FR11, branch D) is
    /// a book of the library's own, which Delete Feed… leaves where it is,
    /// with its file and its place on the reading list, as the question
    /// promises ("To keep an episode, choose Move to Library… on its row
    /// first"), and the next launch still lists it. Only what the feed
    /// holds goes: here the package it kept for a removed download, and its
    /// own folder in the data directory.
    func testAnItemMovedIntoTheLibraryStays() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeleteInLibrary")
        let fixture = try await feedWithAKeptPlaceAndADownload(in: world)
        XCTAssertTrue(world.library.createFolderReturningOutcome(name: "Keepers", parentPath: world.folder.path).succeeded)
        let keepers = "\(world.folder.path)/Keepers"
        let download = try XCTUnwrap(world.library.bookByID(fixture.download.id))
        let moved = await world.library.moveToLibraryReturningOutcome([download], toFolder: keepers)
        XCTAssertEqual(moved, .success(nil))
        world.removedItems.value = []

        let outcome = try await world.center.deleteFeed(fixture.feed.id)

        XCTAssertEqual(outcome?.deletedDownloads, 0, "the book moved into the library was counted as the feed's download")
        XCTAssertEqual(outcome?.deletedKeptPlaces, 1)
        let book = try XCTUnwrap(world.library.bookByID(download.id), "the book moved into the library went")
        XCTAssertNil(book.feedLink)
        XCTAssertEqual(book.folderPath, keepers)
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath), "the moved book's file went")
        XCTAssertTrue(world.library.readingList.contains(book.id), "the moved book left the reading list")
        XCTAssertEqual(
            Set(world.removedItems.value.map(\.name)),
            [fixture.kept.tmbDirectoryName, fixture.feed.id.uuidString],
            "something other than the feed's own went"
        )
        let next = await launchedLibrary(of: world)
        XCTAssertEqual(next.bookByID(book.id)?.folderPath, keepers, "the next launch lost the moved book")
    }

    // MARK: - Partial Downloads

    /// Resume data names its partial file as macOS 10.15 and later write it,
    /// in a keyed archive, and as earlier versions did, by its path in a
    /// plain property list; only a name the system gives a partial file is
    /// taken, and only in the temporary folder given.
    func testThePartialFileIsFoundOnlyWhereResumeDataNamesOne() throws {
        let temporary = URL(fileURLWithPath: "/tmp/feed-delete-tests", isDirectory: true)
        let archived = try NSKeyedArchiver.archivedData(
            withRootObject: [
                "NSURLSessionResumeInfoTempFileName": "CFNetworkDownload_q88WWC.tmp",
                "NSURLSessionDownloadURL": "https://show.example/1.mp3",
                "NSURLSessionResumeBytesReceived": 327_680,
            ] as NSDictionary,
            requiringSecureCoding: true
        )
        XCTAssertEqual(
            FeedPartialDownloads.partialFile(namedIn: archived, temporaryFolder: temporary),
            temporary.appendingPathComponent("CFNetworkDownload_q88WWC.tmp")
        )
        let older = try PropertyListSerialization.data(
            fromPropertyList: ["NSURLSessionResumeInfoLocalPath": "/private/var/folders/x/T/CFNetworkDownload_Ab12.tmp"],
            format: .xml,
            options: 0
        )
        XCTAssertEqual(
            FeedPartialDownloads.partialFile(namedIn: older, temporaryFolder: temporary)?.lastPathComponent,
            "CFNetworkDownload_Ab12.tmp"
        )
        for name in ["../../etc/CFNetworkDownload_x.tmp/..", "CFNetworkDownload_.tmp", "CFNetworkDownload_a-b.tmp", "Episode.mp3", "CFNetworkDownload_ab.tmpx"] {
            let named = try PropertyListSerialization.data(fromPropertyList: ["NSURLSessionResumeInfoTempFileName": name], format: .xml, options: 0)
            XCTAssertNil(FeedPartialDownloads.partialFile(namedIn: named, temporaryFolder: temporary), name)
        }
        XCTAssertNil(FeedPartialDownloads.partialFile(namedIn: Data("partial".utf8), temporaryFolder: temporary))
    }

    // MARK: - Fixtures

    /// A feed of three episodes subscribed into a new folder of its own
    /// inside the world's folder: episode 1's download, opened at a place
    /// and deleted, kept as a package holding that place (FR11, branch A2),
    /// and episode 2 downloaded and on the reading list.
    private struct Fixture {
        let feed: Feed
        let kept: Book
        let download: Book
    }

    /// Makes the fixture in `world`.
    private func feedWithAKeptPlaceAndADownload(in world: FeedTestWorld) async throws -> Fixture {
        let (feed, books) = try await feedWithDownloads(
            episodes: 3,
            downloading: 2,
            in: world,
            into: .newFolder(inParentPath: world.folder.path)
        )
        let kept = try XCTUnwrap(books.first)
        let download = try XCTUnwrap(books.last)
        world.library.persistReadingPosition(bookID: kept.id, position: ReadingPosition(chapterIndex: 0, characterOffset: 42))
        try world.center.deleteDownload("guid:ep-1", of: feed.id)
        XCTAssertEqual(world.library.feedItemRows(of: feed.id).kept["guid:ep-1"]?.id, kept.id, "the opened download's package was not kept")
        _ = world.library.addToReadingList([download.id])
        XCTAssertTrue(world.library.readingList.contains(download.id))
        // Only what Delete Feed… removes is counted from here.
        world.removedItems.value = []
        return Fixture(feed: feed, kept: kept, download: download)
    }

    /// What a download stopped partway leaves, as a test makes it: resume
    /// data in the world's resume folder naming a partial file in this
    /// process's temporary folder, both removed when the test ends.
    private func makePartialDownload(for itemID: FeedItem.ID, of feedID: UUID, in world: FeedTestWorld) throws -> (resumeData: URL, file: URL) {
        let name = "CFNetworkDownload_\(UUID().uuidString.replacingOccurrences(of: "-", with: "")).tmp"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try Data(repeating: 7, count: 4_096).write(to: file)
        let resumeData = world.center.downloads.resumeDataFile(for: itemID, of: feedID)
        try FileManager.default.createDirectory(at: resumeData.deletingLastPathComponent(), withIntermediateDirectories: true)
        try NSKeyedArchiver.archivedData(
            withRootObject: ["NSURLSessionResumeInfoTempFileName": name] as NSDictionary,
            requiringSecureCoding: true
        ).write(to: resumeData)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: resumeData)
        }
        return (resumeData, file)
    }

    /// The library model the next launch makes, reading library.json and
    /// every feed's index from disk, with the startup repair and the feed
    /// items' join done, working with `world`'s feed engine, whose records
    /// are what that launch finds, every write of them landed first.
    private func launchedLibrary(of world: FeedTestWorld) async -> LibraryViewModel {
        await world.center.store.flush()
        LibraryPersistenceService.flushPendingSave()
        let model = LibraryViewModel(initializeServices: false)
        model.feedEngine = world.center
        model.loadLibraryIndex()
        return model
    }

    /// Removes the item at `url` for good, never to the Trash, as a test
    /// must.
    private static func deleteForGood(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}
