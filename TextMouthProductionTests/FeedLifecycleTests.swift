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

    /// A book Move to Library… made of an episode counts as an episode among
    /// Books Finished even once no feed's record names its item, as after a
    /// lost record, by the feed link its package record keeps while its row
    /// lost it (REV11); an audiobook of the library's own whose record holds
    /// no link stays an audiobook.
    func testAMovedEpisodeCountsAsAnEpisodeWithoutItsFeedsRecord() async throws {
        let world = try FeedTestWorld(self, label: "FeedFinishedMoved")
        let (feed, episode) = try await downloadedEpisode(in: world)
        let outcome = await world.library.moveToLibraryReturningOutcome([episode], toFolder: world.folder.path)
        XCTAssertTrue(outcome.succeeded, "\(outcome)")
        XCTAssertNil(world.library.bookByID(episode.id)?.feedLink, "the moved book's row kept its feed link")
        XCTAssertEqual(world.center.finishedBookKind(of: episode.id), .episode)

        world.center.store.remove(feed.id)

        XCTAssertNil(world.center.store.item(linkedTo: episode.id))
        XCTAssertEqual(world.center.finishedBookKind(of: episode.id), .episode, "the moved episode became an audiobook")
        let audiobook = Book(title: "Ferry Songs", format: .audio, filePath: "/Ferry Songs.m4a", md5Hash: "")
        world.library.library.books.append(audiobook)
        XCTAssertEqual(world.center.finishedBookKind(of: audiobook.id), .audiobook)
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
    ///
    /// The row leaves the books a step before the item's state settles,
    /// the files going off the main thread between the two, so the test
    /// reads the state only once the engine's own work has ended (board
    /// #1821). It holds that step open to show it: with the row gone, the
    /// state is still the download's, as a reading made at that moment, as
    /// this test once made it, found under load.
    func testADownloadOpenInAReaderWaitsUntilItCloses() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeleteOpen", worksOnItsOwn: true)
        FeedSettings.refreshAtLaunchPreference.write(false, to: world.preferences)
        FeedSettings.refreshIntervalHoursPreference.write(0, to: world.preferences)
        // Downloads by hand keep the newest-N rule (FR11) out of this test of
        // the after-playing sweep.
        FeedSettings.itemsPreference.write(.everyListedDownloadsByHand, to: world.preferences)
        let (feed, book) = try await downloadedEpisode(in: world)
        FeedSettings.deleteDownloadsDaysAfterPlayedPreference.write(0, to: world.preferences)
        world.library.openBookIDs = [book.id]
        world.center.markPlayed("guid:ep-1", of: feed.id)

        let report = await world.center.sweepPlayedDownloads()
        XCTAssertEqual(report.inUseBookIDs, [book.id])
        XCTAssertNotNil(world.library.bookByID(book.id))
        await waitFor("the engine's own work ends") { !world.center.isSweeping }

        let imports = await world.holdImports(self)
        world.library.openBookIDs = []
        await waitFor("the download's row goes once its reader closes") { world.library.bookByID(book.id) == nil }
        XCTAssertEqual(
            world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state,
            .downloaded(bookID: book.id),
            "the state settled with the row, so reading it there would not race"
        )
        imports.release()
        await waitFor("the engine's own work ends, its removal settled") { !world.center.isSweeping }
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state, .notDownloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
    }

    /// A due download in use waits for a later sweep, as one open in a
    /// reader does (REV11 F1): one being transcribed, whose transcript would
    /// be thrown away with its file, and one being exported. Once neither
    /// work is under way, the sweep deletes it.
    func testADownloadBeingTranscribedOrExportedWaitsForALaterSweep() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeleteInUse")
        let (feed, book) = try await downloadedEpisode(in: world)
        FeedSettings.deleteDownloadsDaysAfterPlayedPreference.write(0, to: world.preferences)
        world.center.markPlayed("guid:ep-1", of: feed.id)
        let transcriptions = TranscribedBooks.shared
        let transcribingBefore = transcriptions.transcribingBookID
        addTeardownBlock { @MainActor in transcriptions.setTranscribing(transcribingBefore) }

        transcriptions.setTranscribing(book.id)
        var report = await world.center.sweepPlayedDownloads()
        transcriptions.setTranscribing(nil)
        XCTAssertEqual(report.inUseBookIDs, [book.id])
        XCTAssertEqual(report.deletedBookIDs, [])
        XCTAssertNotNil(world.library.bookByID(book.id), "a download being transcribed was deleted")

        BookExportModel.noteExportStarted([book.id])
        report = await world.center.sweepPlayedDownloads()
        BookExportModel.noteExportEnded([book.id])
        XCTAssertEqual(report.inUseBookIDs, [book.id])
        XCTAssertNotNil(world.library.bookByID(book.id), "a download being exported was deleted")

        report = await world.center.sweepPlayedDownloads()
        XCTAssertEqual(report.inUseBookIDs, [])
        XCTAssertEqual(report.deletedBookIDs, [book.id])
    }

    /// An item opened while a rule removes its file downloads again, and the
    /// removal, ending a step later off the main thread, leaves the new
    /// download's state alone (REV11 F5): the item says Downloading for its
    /// whole transfer, never Not Downloaded, while the date its download
    /// went is noted all the same.
    func testAnItemOpenedDuringARulesRemovalStaysDownloading() async throws {
        let world = try FeedTestWorld(self, label: "FeedRemovalOpened")
        let (feed, book) = try await downloadedEpisode(in: world)
        // Opened once, so its package is kept with its place, and Open
        // restores it.
        world.library.markBookOpened(book.id)
        FeedSettings.deleteDownloadsDaysAfterPlayedPreference.write(0, to: world.preferences)
        world.center.markPlayed("guid:ep-1", of: feed.id)
        // The next download arrives over seconds, so it is under way when
        // the removal ends.
        let audio = try FeedMediaFixtures.silentAAC()
        var slow = FeedMediaFixtures.file(audio, mimeType: "audio/mp4")
        slow.chunkSize = max(1, audio.count / 20)
        slow.pause = 0.2
        world.server.serve("/audio/1.m4a", slow)
        let imports = await world.holdImports(self)

        let sweep = Task { await world.center.sweepPlayedDownloads() }
        await waitFor("the removal readies the row") { world.library.bookByID(book.id) == nil }
        world.center.open("guid:ep-1", of: feed.id)
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state, .downloading)
        imports.release()
        let report = await sweep.value

        XCTAssertEqual(report.deletedBookIDs, [book.id])
        let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))
        XCTAssertEqual(item.state, .downloading, "the removal reset an item downloading again")
        XCTAssertEqual(item.downloadDeletedDate, world.clock.value)
        world.center.cancelDownload("guid:ep-1", of: feed.id)
        await waitFor("the download stops") { world.center.downloads.current == nil }
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

    /// An item whose book left the library without the engine hearing of
    /// it, as an older build or a lost row can leave one, becomes not
    /// downloaded at the next sweep.
    func testAnItemWhoseBookWasDeletedIsNotDownloaded() async throws {
        let world = try FeedTestWorld(self, label: "FeedBookGone")
        let (feed, book) = try await downloadedEpisode(in: world)
        world.library.library.removeBook(id: book.id)
        XCTAssertEqual(world.center.state(of: try XCTUnwrap(world.center.listedItems(of: feed.id).first), in: feed.id), .notDownloaded)

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
            XCTAssertEqual(error as? FeedDownloadInUseError, FeedDownloadInUseError(title: "Episode One", use: .openInReader))
        }
        world.library.openBookIDs = []

        try world.center.deleteDownload("guid:ep-1", of: feed.id)

        XCTAssertNil(world.library.bookByID(book.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
        XCTAssertEqual(world.center.listedItems(of: feed.id).map(\.state), [.notDownloaded])
    }

    /// The listener's own deletions refuse a download in use, where the
    /// rules wait for it (feed follow-ups item 1): while it is transcribed,
    /// whose transcript would be lost with its file, and while it is
    /// exported, Delete Download, the library's Remove, and Delete Episode
    /// each throw why, naming the download, and nothing goes: the book, its
    /// file, and its item, still downloaded and listed. Once the work ends,
    /// Delete Download deletes it.
    func testTheListenersDeletionsRefuseADownloadInUse() async throws {
        let world = try FeedTestWorld(self, label: "FeedDeleteRefusedInUse")
        let (feed, book) = try await downloadedEpisode(in: world)
        let transcriptions = TranscribedBooks.shared
        let transcribingBefore = transcriptions.transcribingBookID
        addTeardownBlock { @MainActor in transcriptions.setTranscribing(transcribingBefore) }
        addTeardownBlock { @MainActor in BookExportModel.noteExportEnded([book.id]) }

        for use in [FeedBookUse.transcribing, .exporting] {
            switch use {
            case .transcribing: transcriptions.setTranscribing(book.id)
            case .exporting: BookExportModel.noteExportStarted([book.id])
            case .openInReader: world.library.openBookIDs.insert(book.id)
            }
            XCTAssertEqual(world.library.feedBookUse(of: book.id), use)
            XCTAssertTrue(world.library.feedBooksInUse.contains(book.id), "the rules would not wait for a book \(use)")
            let refusal = FeedDownloadInUseError(title: "Episode One", use: use)

            XCTAssertThrowsError(try world.center.deleteDownload("guid:ep-1", of: feed.id)) { error in
                XCTAssertEqual(error as? FeedDownloadInUseError, refusal, "Delete Download")
            }
            XCTAssertThrowsError(try world.center.deleteDownload(ofBook: book, in: world.library)) { error in
                XCTAssertEqual(error as? FeedDownloadInUseError, refusal, "the library's Remove")
            }
            XCTAssertThrowsError(try world.center.deleteItem("guid:ep-1", of: feed.id)) { error in
                XCTAssertEqual(error as? FeedDownloadInUseError, refusal, "Delete Episode")
            }

            XCTAssertNotNil(world.library.bookByID(book.id), "a download \(use) left the library")
            XCTAssertTrue(FileManager.default.fileExists(atPath: book.bookFileURL.path), "the file of a download \(use) went")
            let item = try XCTUnwrap(world.center.store.record(of: feed.id)?.item("guid:ep-1"))
            XCTAssertEqual(item.state, .downloaded(bookID: book.id))
            XCTAssertNil(item.deletedDate, "Delete Episode hid an item whose download is \(use)")
            XCTAssertEqual(world.removedItems.value, [], "something went while the download was \(use)")
            transcriptions.setTranscribing(nil)
            BookExportModel.noteExportEnded([book.id])
        }
        XCTAssertNil(world.library.feedBookUse(of: book.id))

        try world.center.deleteDownload("guid:ep-1", of: feed.id)
        XCTAssertNil(world.library.bookByID(book.id))
    }

    /// A crash between the hidden holder an article's file and text wait in
    /// and the Trash leaves the holder in its feed's folder, where nothing
    /// else ever removes it; the next launch sweeps it as the Delete
    /// Download it belonged to would have sent it, through the listener's
    /// own removal (to the Trash, or for good, as Removal Behavior says),
    /// and leaves the feed's packages and anything not a holder alone.
    func testTheNextLaunchSweepsAHolderACrashLeft() async throws {
        let world = try FeedTestWorld(self, label: "FeedHolderSweep")
        let (feed, book) = try await downloadedEpisode(in: world)
        let folder = FeedPaths.itemsFolder(of: feed.id, in: TextMouthPaths.root)
        let holder = folder.appendingPathComponent(FeedItemPackage.removalHolderPrefix + UUID().uuidString, isDirectory: true)
        let together = holder.appendingPathComponent("A Newer Article", isDirectory: true)
        try FileManager.default.createDirectory(at: together, withIntermediateDirectories: true)
        try Data("<p>Words.</p>".utf8).write(to: together.appendingPathComponent("A Newer Article.html"))
        try Data("Words.".utf8).write(to: together.appendingPathComponent(TextMouthPaths.contentMarkdownFileName))
        let other = folder.appendingPathComponent(".staging-left-alone", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertEqual(FeedItemPackage.removalHolders(in: TextMouthPaths.root).filter { $0.path.hasPrefix(folder.path) }, [holder])

        _ = await world.relaunch(self)

        XCTAssertFalse(FileManager.default.fileExists(atPath: holder.path), "the holder a crash left stayed")
        XCTAssertEqual(world.removedItems.value.map(\.name), [holder.lastPathComponent])
        XCTAssertEqual(world.removedItems.value.first?.contents, ["A Newer Article"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.tmbDirectory.path), "a package went with the holder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "a folder that is no holder went")
    }

    /// How a book is in use, which the listener's deletions refuse, is the
    /// first of open in a reader, being transcribed, and being exported, and
    /// the rules' set of books in use holds exactly the books in some use.
    func testABooksUseIsTheFirstThatHolds() throws {
        let library = LibraryViewModel(initializeServices: false)
        let transcriptions = TranscribedBooks.shared
        let transcribingBefore = transcriptions.transcribingBookID
        let (open, transcribed, exported, idle) = (UUID(), UUID(), UUID(), UUID())
        addTeardownBlock { @MainActor in
            transcriptions.setTranscribing(transcribingBefore)
            BookExportModel.noteExportEnded([open, exported])
        }
        library.openBookIDs = [open]
        transcriptions.setTranscribing(transcribed)
        BookExportModel.noteExportStarted([open, exported])

        XCTAssertEqual(library.feedBookUse(of: open), .openInReader, "open in a reader comes first")
        XCTAssertEqual(library.feedBookUse(of: transcribed), .transcribing)
        XCTAssertEqual(library.feedBookUse(of: exported), .exporting)
        XCTAssertNil(library.feedBookUse(of: idle))
        XCTAssertEqual(library.feedBooksInUse.intersection([open, transcribed, exported, idle]), [open, transcribed, exported])
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

    /// Unsubscribing is a switch (FR11, branch D): the feed keeps its record,
    /// which says it is unsubscribed, and this Mac's fetch details, and
    /// every download stays its item, in its feed's own folder.
    func testUnsubscribingKeepsTheFeedAndItsDownloads() async throws {
        let world = try FeedTestWorld(self, label: "FeedUnsubscribe")
        let (feed, book) = try await downloadedEpisode(in: world)
        await world.center.store.flush()

        world.center.unsubscribe(feed.id)
        await world.center.store.flush()
        await world.center.fetchStates.flush()

        XCTAssertEqual(world.center.store.record(of: feed.id)?.feed.isSubscribed, false)
        let written = try FeedRecordCoding.decoder().decode(
            FeedRecord.self,
            from: Data(contentsOf: FeedPaths.recordFile(of: feed.id, in: world.recordsFolder))
        )
        XCTAssertEqual(written.feed.unsubscribedDate, world.clock.value)
        XCTAssertTrue(FileManager.default.fileExists(atPath: FeedPaths.recordFile(of: feed.id, in: world.fetchStateFolder).path))
        XCTAssertEqual(world.library.bookByID(book.id)?.feedLink, book.feedLink)
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath))
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
