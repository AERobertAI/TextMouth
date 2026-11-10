import Foundation

// MARK: - Played, and Deleted After (FR03)

/// What one sweep of played downloads did (FR03).
struct FeedSweepReport: Equatable, Sendable {
    /// The downloads deleted, by book ID.
    var deletedBookIDs: [UUID] = []
    /// Those of `deletedBookIDs` whose packages stayed without their files,
    /// holding the listener's place, bookmarks, settings, or transcript
    /// (FR11, branch A2).
    var keptPackageBookIDs: [UUID] = []
    /// The downloads due but in use (`FeedLibraryHost.feedBooksInUse`):
    /// open in a reader, being transcribed, or being exported, each left
    /// for a later sweep (REV11 F1).
    var inUseBookIDs: [UUID] = []
    /// The downloads due in a cloud library whose packages are not wholly on
    /// this Mac, left to a Mac that has them.
    var leftInCloudBookIDs: [UUID] = []
    /// The items whose books the library no longer lists, now not
    /// downloaded.
    var forgottenItemIDs: [FeedItem.ID] = []
}

/// A download one of the engine's own rules found due to go (FR11): its
/// feed and item, its row, and why, as the debug log says it ("played",
/// "outside the newest 5").
struct FeedDueRemoval: Sendable {
    let feedID: UUID
    let itemID: FeedItem.ID
    let book: Book
    let reason: String
}

/// Why a file one of the engine's rules removed off the main thread stayed
/// (FR11): the words its error gave, carried back to the main actor.
struct FeedFileRemovalFailure: LocalizedError, Sendable {
    let errorDescription: String?
}

/// What removing the downloads a rule found due did
/// (`FeedCenter.removeDue(_:from:by:at:putOffEvent:)`).
struct FeedDueRemovalOutcome {
    /// The removals whose files went, in the order asked.
    var removed: [FeedFileRemoval] = []
    /// The books whose packages this Mac does not hold whole, in a cloud
    /// library, left to a Mac that has them.
    var leftInCloud: [UUID] = []
    /// The books put in use while the cloud state was read, as when a reader
    /// opened one, left for the next pass (REV11 F1).
    var inUse: [UUID] = []
    /// Whether the records and indexes could not be written first, so every
    /// file stayed.
    var wasPutOff = false
}

extension FeedCenter {
    // MARK: Played

    /// Records that the book `bookID` played or was read to its end, when it
    /// is a feed item's download, or the book an item became in the library
    /// by Move to Library… (FR11, branch D): the item is played from now.
    /// The reader reaches here through the completion that counts Books
    /// Finished (`ReadingStatsService.markBookFinished(bookID:title:)`, which
    /// posts `.bookDidFinish`), so finished episodes and articles count as
    /// finished books, as the listener decided for now.
    func bookDidFinish(_ bookID: UUID) {
        guard let (feed, item) = store.item(linkedTo: bookID) else { return }
        store.updateItem(item.id, of: feed.id) { $0.playedDate = environment.now() }
        DiagnosticLog.event(.feeds, "FEED_ITEM_PLAYED: \(item.title) (\(feed.title))")
        requestSweep()
    }

    /// What kind of book the book `bookID` is, as Books Finished counts it
    /// (`ReadingStatsService.finishedBookKind`): a podcast episode when this
    /// engine downloaded it as an episode, in its feed or moved into the
    /// library since (`cameFromAFeed(_:)`), and otherwise an audiobook or a
    /// text book by its format, an article being a text book; nil when the
    /// library no longer lists it, or the engine has not started.
    func finishedBookKind(of bookID: UUID) -> FinishedBookKind? {
        guard let book = library?.feedBook(withID: bookID) else { return nil }
        return FinishedBookKind.of(format: book.format, isFeedDownload: cameFromAFeed(book))
    }

    /// Whether `book` came from a feed: a feed item's row, a book an item of
    /// a record names, or an audiobook of the library's own that Move to
    /// Library… made of an episode (FR11, branch D), whose package record
    /// keeps the feed link its row lost, as it does once no record names
    /// its item, after a lost record (REV11). That record is read once a
    /// book, without downloading anything, and remembered, as where a book
    /// came from never changes; a book of another format is a text book
    /// whatever it came from, so none is read for it.
    private func cameFromAFeed(_ book: Book) -> Bool {
        if book.isFeedItem || store.item(linkedTo: book.id) != nil { return true }
        guard book.format.isAudio else { return false }
        if let known = feedOriginOfRecords[book.id] { return known }
        // A record that can't be read now, as one only in the cloud, is
        // read again next time rather than remembered.
        guard let record = try? DatalessFiles.withoutDownloading({ try StoredBookRecord.read(from: book.tmbDirectory) }) else {
            return false
        }
        let fromAFeed = record.info.metadata.feedLink != nil
        feedOriginOfRecords[book.id] = fromAFeed
        return fromAFeed
    }

    /// Marks the item `itemID` of the feed `feedID` played (an article: read)
    /// now, as Mark as Played does; the delete-after-played rule counts from
    /// now, and the newest-N rule's pass over the feed, asked for at once,
    /// takes back its download of the item not yet under way, which a
    /// played item no longer needs (REV11 F3).
    func markPlayed(_ itemID: FeedItem.ID, of feedID: UUID) {
        store.updateItem(itemID, of: feedID) { $0.playedDate = environment.now() }
        requestSweep()
        requestItemPolicyPass(for: [feedID])
    }

    /// Marks the item `itemID` of the feed `feedID` unplayed, as Mark as
    /// Unplayed does: its download is kept from then on.
    func markUnplayed(_ itemID: FeedItem.ID, of feedID: UUID) {
        store.updateItem(itemID, of: feedID) { $0.playedDate = nil }
    }

    /// Marks every item of the feed `feedID` the listener has not deleted
    /// and that is not played yet played now, as Mark All Played does, those
    /// the short list hides among them (FR11), in one change of its record,
    /// so the record is written once; the delete-after-played rule counts
    /// from now, and the newest-N rule's pass over the feed, asked for at
    /// once, takes back its downloads not yet under way, as during the
    /// first launch's batch, so no more played episodes download (REV11 F3).
    /// - Returns: How many items were marked.
    @discardableResult
    func markAllPlayed(of feedID: UUID) -> Int {
        let now = environment.now()
        var marked = 0
        store.update(feedID) { record in
            for index in record.items.indices
            where record.items[index].deletedDate == nil && record.items[index].playedDate == nil {
                record.items[index].playedDate = now
                marked += 1
            }
        }
        if marked > 0 {
            requestSweep()
            requestItemPolicyPass(for: [feedID])
        }
        return marked
    }

    // MARK: Deleting

    /// Deletes the download of the item `itemID` of the feed `feedID`, as
    /// Delete Download does: its file goes, to the Trash or for good as the
    /// removal setting says, with what was made from it, and the item stays,
    /// not downloaded. The item's package stays without the file while it
    /// holds something of the listener's, keeping the place, the playback
    /// times, the bookmarks, the item's own settings, and its transcript for
    /// a later download; otherwise it goes whole (FR11, branch A2). Refused
    /// while the download is in use: open in a reader, being transcribed,
    /// or being exported (`FeedBookUse`).
    /// - Throws: `FeedDownloadInUseError`, `FeedItemPackageError`, or why
    ///   the file could not be removed; the download then stays.
    func deleteDownload(_ itemID: FeedItem.ID, of feedID: UUID) throws {
        guard let item = store.record(of: feedID)?.item(itemID), item.state.bookID != nil else { return }
        if let library, let book = downloadedRow(of: item, in: feedID) {
            try removeDownload(book, in: library, keepingPackage: true, by: "Delete Download")
        }
        noteDownloadRemoved(itemID, of: feedID)
    }

    /// Deletes the download whose book is `book`, a feed item `library`
    /// lists, as the library's Remove does for one: as Delete Download does
    /// (FR11, branch A2), whether or not a feed's record still names it, and
    /// the item a record names becomes not downloaded.
    /// - Throws: what `deleteDownload(_:of:)` throws.
    func deleteDownload(ofBook book: Book, in library: FeedLibraryHost) throws {
        try removeDownload(book, in: library, keepingPackage: true, by: "the library's Remove")
        if let (feed, item) = store.item(downloadedAs: book.id) {
            noteDownloadRemoved(item.id, of: feed.id)
        }
    }

    /// Removes the file of `book`, a feed item `library` lists, as the
    /// listener's own deletion does (`FeedEnvironment.removeItem`): with
    /// `keepingPackage`, keeping its package while it holds something of the
    /// listener's, and otherwise deleting the package whole, even one kept
    /// on the shelf after its file went. Its record and its feed's index are
    /// written first, then the file goes
    /// (`FeedLibraryHost.removeFeedFiles(of:keepingPackages:remove:)`);
    /// `command` names what asked, for the debug log.
    /// - Throws: `FeedDownloadInUseError` for a download in use, open in a
    ///   reader, being transcribed, or being exported, whose transcript or
    ///   export would be lost with its file (feed follow-ups item 1);
    ///   `FeedItemPackageError.notAFeedPackage` for a download not in its
    ///   feed's folder, as one made before FR11 until it moves there; or
    ///   whatever kept the file; nothing was removed then.
    private func removeDownload(_ book: Book, in library: FeedLibraryHost, keepingPackage: Bool, by command: String) throws {
        if let use = library.feedBookUse(of: book.id) {
            DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_DELETE_REFUSED: \(book.title): it \(use.clause), by \(command)")
            throw FeedDownloadInUseError(title: book.title, use: use)
        }
        guard book.isFeedItem else { throw FeedItemPackageError.notAFeedPackage }
        let root = TextMouthPaths.root
        let outcome = try library.removeFeedFiles(of: [book], keepingPackages: keepingPackage) { removal in
            guard removal.keepsPackage else {
                // A package gone already counts as removed (REV14 feeds 8).
                try FeedItemPackage.removeWhole(removal.row, in: root, remove: environment.removeItem)
                return
            }
            let package = try FeedItemPackage.packageForRemoval(of: removal.row, in: root)
            // A text book's content.md may hold an edit made with Edit Text,
            // so it stays in a kept package whenever one of the engine's
            // rules removes the file (`FeedItemPackage.staysWithoutTheFile(_:)`);
            // the listener's own Delete Download takes it with the file, as
            // one item that follows the Trash setting as the file does, and a
            // refusal leaves both (REV11).
            try FeedItemPackage.removeFileAndText(of: removal.row, in: package, remove: environment.removeItem)
            FeedItemPackage.removeWhatTheFileMade(of: removal.row, from: package)
        }
        if let failure = outcome.failures.first {
            throw failure.error
        }
        for removal in outcome.removed {
            DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_DELETED: \(removal.row.title): \(Self.removalNote(removal)), by \(command)")
        }
    }

    /// Notes in the record that the listener removed the download of the
    /// item `itemID` of the feed `feedID`, from now: it is no longer
    /// downloaded, and it is the listener's, so the newest-N rule never
    /// downloads it again by itself (FR11).
    private func noteDownloadRemoved(_ itemID: FeedItem.ID, of feedID: UUID) {
        noteDownloadGone(itemID, of: feedID, at: environment.now(), byListener: true)
    }

    /// Notes in the record that the download of the item `itemID` of the
    /// feed `feedID` went at `date`: the item is not downloaded, with the
    /// date its download went. With `byListener`, the item is the
    /// listener's from then on (`noteDownloadRemoved(_:of:)`); a rule's
    /// removal, and a book the library no longer lists, leave who asked for
    /// the download as it was.
    ///
    /// A rule's removal, whose files go off the main thread, names the book
    /// it removed (`removing`), and ends a step after it began: an item
    /// asked for again meanwhile, as Open asks for one, says so for its
    /// whole transfer, so its state changes only while it still names that
    /// book; the date its download went is noted either way (REV11 F5).
    private func noteDownloadGone(
        _ itemID: FeedItem.ID,
        of feedID: UUID,
        at date: Date,
        byListener: Bool,
        removing bookID: UUID? = nil
    ) {
        store.updateItem(itemID, of: feedID) { item in
            if bookID == nil || item.state.bookID == bookID {
                item.state = .notDownloaded
            }
            item.downloadDeletedDate = date
            if byListener {
                item.downloadOrigin = .listener
            }
        }
    }

    /// What became of a removed download's package, as its log line says.
    private static func removalNote(_ removal: FeedFileRemoval) -> String {
        removal.keepsPackage ? "its file deleted, its place and bookmarks kept" : "its package deleted whole"
    }

    /// Deletes the item `itemID` of the feed `feedID`, as Delete Episode does:
    /// its download stops; its package goes whole, to the Trash or for good
    /// as the removal setting says, whether its file is here or the package
    /// was kept with the listener's place after its file went (FR11, branch
    /// A2); and the item leaves every list, while its record keeps it so no
    /// refresh brings it back. Refused while the download is in use, as
    /// Delete Download is.
    /// - Throws: what `deleteDownload(_:of:)` throws; the item then stays.
    func deleteItem(_ itemID: FeedItem.ID, of feedID: UUID) throws {
        downloads.cancel(itemID, of: feedID)
        guard let item = store.record(of: feedID)?.item(itemID) else { return }
        if let library, let row = downloadedRow(of: item, in: feedID) ?? library.feedItemRows(of: feedID).kept[itemID] {
            try removeDownload(row, in: library, keepingPackage: false, by: "Delete Episode")
        }
        if item.state.bookID != nil {
            noteDownloadRemoved(itemID, of: feedID)
        }
        store.updateItem(itemID, of: feedID) { $0.deletedDate = environment.now() }
    }

    /// Deletes `kept`, rows of the feed `feedID` kept after their downloads
    /// went, with their packages, as Unsubscribe does (FR11, branch D), and
    /// the places, playback times, bookmarks, settings, and transcripts they
    /// hold, as the listener accepted ("Clearing out old deleted episodes
    /// itself seems fine"): each as Delete Episode deletes a kept package,
    /// through the listener's own removal (`FeedEnvironment.removeItem`, the
    /// Trash or for good as the removal setting says), once the feed's index
    /// is written without its row
    /// (`FeedLibraryHost.removeFeedFiles(of:keepingPackages:remove:)`).
    /// The caller decides the rows, before anything changes
    /// (`keptRowsUnsubscribeDeletes(of:among:)`), so nothing the listener
    /// was not told of goes (REV14 feeds 1). A failed index write keeps
    /// every package, and a package that cannot be removed keeps its row on
    /// the feed's shelf; each is logged, and nothing is lost.
    /// - Returns: How many packages went.
    func deleteKeptPackages(_ kept: [Book], of feedID: UUID) -> Int {
        guard let library, !kept.isEmpty else { return 0 }
        let root = TextMouthPaths.root
        let outcome: FeedFileRemovalOutcome
        do {
            outcome = try library.removeFeedFiles(of: kept, keepingPackages: false) { removal in
                // A package gone already counts as removed, its row leaving
                // the shelf, as Delete Feed… counts one (REV14 feeds 8).
                try FeedItemPackage.removeWhole(removal.row, in: root, remove: environment.removeItem)
            }
        } catch {
            DiagnosticLog.event(
                .feeds,
                "FEED_KEPT_PACKAGES_PUT_OFF: \(feedID.uuidString.prefix(8)): \(error.localizedDescription); "
                    + "the packages kept for removed downloads stay"
            )
            return 0
        }
        for failure in outcome.failures {
            DiagnosticLog.event(
                .feeds,
                "FEED_KEPT_PACKAGE_DELETE_FAILED: \(failure.row.title): \(failure.error.localizedDescription); its place stays kept"
            )
        }
        return outcome.removed.count
    }

    /// The rows of the feed `feedID` kept after their downloads went that
    /// Unsubscribe deletes (`deleteKeptPackages(_:of:)`): every one but an
    /// item's downloading again, waiting in the queue or under way, whose
    /// download restores it, and, with `itemIDs`, only those of the items
    /// it names, as the question named them; in the order of their items,
    /// so the log and the index's writes never depend on a dictionary's.
    /// What Unsubscribe's question counts and names, and whether it asks at
    /// all, come from these alone (FR14; REV13 item 5), and Unsubscribe
    /// deletes no other (REV14 feeds 1).
    func keptRowsUnsubscribeDeletes(of feedID: UUID, among itemIDs: Set<FeedItem.ID>? = nil) -> [Book] {
        guard let library else { return [] }
        return library.feedItemRows(of: feedID).kept
            .filter { (itemIDs?.contains($0.key) ?? true) && !downloads.isDownloading($0.key, of: feedID) }
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    // MARK: The Engine's Own Work

    /// Asks for a sweep of played downloads: one starts at once, or after the
    /// engine's own work under way, a sweep or a pass of the newest-N rule,
    /// and a request made meanwhile makes it run again. Only an engine
    /// working on its own sweeps by itself.
    func requestSweep() {
        guard environment.worksOnItsOwn else { return }
        sweepRequested = true
        runOwnWork()
    }

    /// Asks for a pass of the newest-N rule (FR11) over the feeds `feedIDs`,
    /// every feed when nil, trying their failed downloads again when
    /// `retryingFailures`, as a pass that follows a refresh does: one starts
    /// at once, or after the engine's own work under way, every pass asked
    /// for meanwhile running as one. Only an engine working on its own runs
    /// passes by itself; a test runs `applyItemPolicy(to:retrying:)`.
    func requestItemPolicyPass(for feedIDs: Set<UUID>?, retryingFailures: Bool = false) {
        guard environment.worksOnItsOwn else { return }
        let request = FeedItemPolicyPassRequest(feedIDs: feedIDs, retryingFeedIDs: retryingFailures ? feedIDs ?? [] : [])
        pendingItemPolicyPass = pendingItemPolicyPass?.adding(request) ?? request
        runOwnWork()
    }

    /// Runs the engine's own work asked for, one piece at a time, until none
    /// is left: a sweep of played downloads, then a pass of the newest-N
    /// rule. One at a time, so the two never remove files from under each
    /// other while one waits for a cloud library's state.
    private func runOwnWork() {
        guard !isSweeping else { return }
        isSweeping = true
        Task {
            while sweepRequested || pendingItemPolicyPass != nil {
                if sweepRequested {
                    sweepRequested = false
                    await sweepPlayedDownloads()
                }
                if let pass = pendingItemPolicyPass {
                    pendingItemPolicyPass = nil
                    await applyItemPolicy(to: pass.feedIDs, retrying: pass.retryingFeedIDs)
                }
            }
            isSweeping = false
        }
    }

    // MARK: The Sweep

    /// Deletes the downloads the delete-after-played rule says are due: an
    /// item played at least its feed's number of days ago (0 at once, -1
    /// never; `FeedSettings.deleteDownloadsDaysAfterPlayed` unless the feed
    /// overrides it). Each file goes as Delete Download's does, keeping its
    /// package while it holds something of the listener's (FR11, branch
    /// A2), except that an article's content.md, which may hold an edit,
    /// stays in a kept package (`FeedItemPackage.staysWithoutTheFile(_:)`):
    /// the records and the feeds' indexes are written first, and a failed
    /// write keeps every file; the files themselves then go off the main
    /// thread (`removeDue`). Its item stays, not downloaded, with the date
    /// its download went.
    ///
    /// Files are deleted for good, rather than moved to the Trash, so played
    /// episodes never fill the Trash, with dataless files left in the cloud.
    /// A book in use waits for a later sweep (`FeedLibraryHost.feedBooksInUse`,
    /// REV11 F1): one open in a reader, until its reader closes, which asks
    /// for a sweep; one being transcribed, whose transcript would otherwise
    /// be thrown away with its file; and one being exported. In a cloud
    /// library, a download is deleted only when this Mac holds its package
    /// whole, as its cloud state says, read off the main thread without
    /// downloading anything (`BookCloudStorage.state(of:in:)`): one only in
    /// the cloud, or still syncing, is left to a Mac that has it, which also
    /// knows whether a reader there has it open. An item whose book the
    /// library no longer lists, as after the listener deleted the book,
    /// becomes not downloaded. Nothing is swept while the library's index is
    /// recovered: its list of books is provisional then, and a book missing
    /// from it may still be on disk.
    @discardableResult
    func sweepPlayedDownloads() async -> FeedSweepReport {
        var report = FeedSweepReport()
        guard let library, library.feedLibraryIsComplete else { return report }
        let now = environment.now()
        let settings = self.settings
        let inUse = library.feedBooksInUse
        var due: [FeedDueRemoval] = []
        // A feed being deleted is left to Delete Feed… (FR14).
        for record in store.records.values where !downloads.isClosed(record.feed.id) {
            // An item moved into the library whose book has left it is not
            // downloaded from now (FR11, branch D); one whose book is still
            // there is the library's, which no rule of the feed's touches.
            for item in record.items {
                guard let bookID = item.state.libraryBookID, library.feedBook(withID: bookID) == nil else { continue }
                noteDownloadGone(item.id, of: record.feed.id, at: now, byListener: false)
                report.forgottenItemIDs.append(item.id)
                DiagnosticLog.event(.feeds, "FEED_LIBRARY_BOOK_GONE: \(item.title): the book it was moved into the library as left it")
            }
            let days = record.feed.deleteDownloadsDaysAfterPlayed(under: settings)
            for item in record.items where item.state.bookID != nil {
                guard let book = downloadedRow(of: item, in: record.feed.id) else {
                    noteDownloadGone(item.id, of: record.feed.id, at: now, byListener: false)
                    report.forgottenItemIDs.append(item.id)
                    DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_FORGOTTEN: \(item.title): the library no longer lists its book")
                    continue
                }
                guard days >= 0, let played = item.playedDate,
                      now >= played.addingTimeInterval(TimeInterval(days) * 86_400) else { continue }
                guard !inUse.contains(book.id) else {
                    report.inUseBookIDs.append(book.id)
                    continue
                }
                // A download made before FR11 waits until it moves into its
                // feed's folder, where a package can be kept.
                guard book.isFeedItem else { continue }
                due.append(FeedDueRemoval(feedID: record.feed.id, itemID: item.id, book: book, reason: "played"))
            }
        }
        guard !due.isEmpty else { return report }

        let outcome = await removeDue(due, from: library, by: "the delete-after rule", at: now, putOffEvent: "FEED_SWEEP_PUT_OFF")
        report.leftInCloudBookIDs = outcome.leftInCloud
        report.inUseBookIDs += outcome.inUse
        guard !outcome.wasPutOff else { return report }
        report.deletedBookIDs = outcome.removed.map(\.row.id)
        report.keptPackageBookIDs = outcome.removed.filter(\.keepsPackage).map(\.row.id)
        if !report.leftInCloudBookIDs.isEmpty {
            DiagnosticLog.event(
                .feeds,
                "FEED_SWEEP_LEFT_IN_CLOUD: \(report.leftInCloudBookIDs.count) played download(s) not wholly on this Mac left for a Mac that has them"
            )
        }
        return report
    }

    // MARK: Removing What a Rule Found Due

    /// Removes for good the files of the downloads `due`, as the engine's own
    /// rules do: the after-playing sweep, and the newest-N rule (FR11). In a
    /// cloud library, only those whose packages this Mac holds whole, as
    /// their cloud state says, read first off the main thread without
    /// downloading anything; never one put in use meanwhile, as when a reader
    /// opened it or a transcription or an export began
    /// (`FeedLibraryHost.feedBooksInUse`, REV11 F1). Each keeps
    /// its package while it holds something of the listener's, in the order
    /// that never loses the listener's place: the records and the feeds'
    /// indexes written and waited for on the main actor first
    /// (`FeedLibraryHost.readyFeedFilesForRemoval(of:keepingPackages:)`),
    /// a failed write keeping every file, logged as `putOffEvent`; then the
    /// files, off the main thread; then the outcome, back on the main actor
    /// (`FeedLibraryHost.settleFeedFileRemovals(_:failures:)`). Each item
    /// whose file went is not downloaded from `now`, and keeps who asked for
    /// it; each removal is logged with its reason and `rule`.
    ///
    /// No rule's removal races a download restoring an item into its kept
    /// package, and not because of the thread it runs on: a due download's
    /// row is among the books, its file here, while a restoring item's row
    /// is on its feed's shelf, its file gone, so a restore can be asked for
    /// only once the readying step has shelved the row. Its import then
    /// waits on the import queue behind the removal of the files, which runs
    /// there (`FeedDownloadManager.runBesideImports(_:)`), as storage work
    /// (`StorageWork.removingFeedDownloads`): a data-directory move waits for
    /// a removal under way, and a removal waits while a move holds the work,
    /// then removes from the data directory as the move left it.
    /// - Returns: The removals whose files went, the books left in the
    ///   cloud, and whether the removal was put off.
    func removeDue(
        _ due: [FeedDueRemoval],
        from library: FeedLibraryHost,
        by rule: String,
        at now: Date,
        putOffEvent: String
    ) async -> FeedDueRemovalOutcome {
        var outcome = FeedDueRemovalOutcome()
        let storage = environment.bookStorage()
        let packages = due.map { BookPackage($0.book) }
        // What each package holds of the listener's is read here too: it
        // reads each transcript.json (about 70 ms for 16 MB), which the main
        // actor would pay once for each unopened episode removed. Only the
        // packages held whole are read, since a package only in the cloud is
        // left alone and reading it could download it.
        let packageURLs = Dictionary(due.map { ($0.book.id, $0.book.tmbDirectory) }, uniquingKeysWith: { first, _ in first })
        let (heldWhole, listenersFilesHeld) = await OffMainWork.run(on: .global(qos: .utility)) { () -> (Set<UUID>, [UUID: Bool]) in
            let whole = Self.packagesHeldWhole(packages, storage: storage)
            return (whole, FeedItemPackage.listenersFilesHeld(in: packageURLs.filter { whole.contains($0.key) }))
        }
        outcome.leftInCloud = due.map(\.book.id).filter { !heldWhole.contains($0) }
        // One may have been put in use meanwhile: opened in a reader, or
        // being transcribed or exported (REV11 F1).
        let inUse = library.feedBooksInUse
        let held = due.filter { heldWhole.contains($0.book.id) }
        outcome.inUse = held.map(\.book.id).filter(inUse.contains)
        // Nor is a download of a feed being deleted meanwhile removed here:
        // Delete Feed… removes it, once every removal readied before it
        // began has ended (FR14).
        let removable = held.filter { !inUse.contains($0.book.id) && !downloads.isClosed($0.feedID) }
        guard !removable.isEmpty else { return outcome }

        // 1 and 2: the records and the indexes, on the main actor.
        let readied: [FeedFileRemoval]
        do {
            readied = try library.readyFeedFilesForRemoval(
                of: removable.map(\.book),
                keepingPackages: true,
                listenersFilesHeld: listenersFilesHeld
            )
        } catch {
            DiagnosticLog.event(.feeds, "\(putOffEvent): \(error.localizedDescription)")
            outcome.wasPutOff = true
            return outcome
        }
        // 3: the files, off the main thread, beside the imports, as storage
        // work: a data-directory move waits for them, and they wait for it.
        let boundary = environment.boundary
        let failed = await downloads.runBesideImports { () -> [UUID: String] in
            boundary.perform(.removingFeedDownloads, whileHeld: {
                DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_DELETE_WAITING: storage work is held, so the deletions by \(rule) wait")
            }) { _ -> [UUID: String] in
                // Read inside the work: the library's root as it is now,
                // after any move this removal waited for.
                let root = TextMouthPaths.root
                var failed: [UUID: String] = [:]
                for removal in readied {
                    do {
                        try FeedItemPackage.removeForGood(removal, in: root)
                    } catch {
                        failed[removal.row.id] = error.localizedDescription
                    }
                }
                return failed
            }
        }
        let removal = library.settleFeedFileRemovals(readied, failures: failed.mapValues { FeedFileRemovalFailure(errorDescription: $0) })
        for removed in removal.removed {
            guard let entry = removable.first(where: { $0.book.id == removed.row.id }) else { continue }
            noteDownloadGone(entry.itemID, of: entry.feedID, at: now, byListener: false, removing: removed.row.id)
            outcome.removed.append(removed)
            DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_DELETED: \(removed.row.title): \(entry.reason), \(Self.removalNote(removed)) by \(rule)")
        }
        for failure in removal.failures {
            DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_DELETE_FAILED: \(failure.row.title): \(failure.error.localizedDescription)")
        }
        return outcome
    }

    /// The books of `packages` whose packages this Mac holds whole, read off
    /// the main thread without downloading anything: every one in a library
    /// on this Mac, and, in a cloud library, as `storage` says, those
    /// downloaded or local.
    nonisolated static func packagesHeldWhole(_ packages: [BookPackage], storage: any BookCloudStorage) -> Set<UUID> {
        let location = storage.libraryLocation()
        guard location.isCloud else { return Set(packages.map(\.bookID)) }
        var held = Set<UUID>()
        for package in packages {
            switch storage.state(of: package, in: location) {
            case .downloaded, .local:
                held.insert(package.bookID)
            default:
                continue
            }
        }
        return held
    }
}
