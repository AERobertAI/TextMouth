import Foundation

// MARK: - An Unsubscribed Feed's Downloads Return to the Library

/// What returning one unsubscribed feed's downloads to the library did
/// (`LibraryViewModel.returnDownloads(ofFeed:toFolderID:removingWith:)`).
struct FeedDownloadReturn: Equatable {
    /// The downloads that are books of the library's own now, as the library
    /// lists them.
    var returned: [Book] = []
    /// The downloads that could not move, which stay in the feed's folder for
    /// the next launch to try again.
    var stayed: [Book] = []
    /// How many packages kept for removed downloads were deleted.
    var deletedKeptPackages = 0
    /// Whether the feed's folder is gone, its index with it.
    var removedFeedFolder = false
}

/// Until Unsubscribe keeps a feed's downloads by the listener's choice (FR11,
/// branch D), a feed whose record is gone gets its downloads back as books of
/// the library's own (REV10, item 3): the inverse of the first launch's move
/// of downloads into their feeds' folders (`LibraryViewModel+FeedItemMove.swift`).
/// Without the feed nothing lists a feed item, so a download left in the
/// feed's folder would be listed nowhere, though the app said it stays.
///
/// Unsubscribe returns its feed's downloads into the feed's library folder,
/// or the top level when that folder is gone; the launch returns those of
/// every feed whose folder is here while its record is gone, at the top
/// level, since nothing names that feed's library folder any more. Each keeps
/// its book ID, place, playback times, bookmarks, settings, transcript, and
/// place on the reading list. What the feed kept of downloads removed earlier
/// goes, since nothing can download them again without the feed: the user
/// accepted that for unsubscribing ("Clearing out old deleted episodes
/// itself seems fine").
extension LibraryViewModel {

    // MARK: At Launch

    /// Returns to the library, as books of its own at its top level, the
    /// downloads of every feed whose folder this library read at launch
    /// while its record is gone (`feedsWithoutRecords(subscribed:)`), one feed
    /// at a time, as `returnDownloads(ofFeed:toFolderID:removingWith:)` does.
    /// Called once the feeds' records have loaded.
    /// - Parameters:
    ///   - subscribed: The feeds whose records are known: unless a test gives
    ///     its own, the feed engine's, read or found only in the cloud.
    ///   - remove: How a package kept for a removed download, and the feed's
    ///     folder, are removed: as the feed engine removes them (the Trash or
    ///     for good, as the removal setting says), unless a test gives its own.
    /// - Returns: How many downloads became books of the library's own.
    @discardableResult
    func returnDownloadsOfFeedsWithoutRecords(
        subscribed: Set<UUID>? = nil,
        removingWith remove: (@MainActor (URL) throws -> Void)? = nil
    ) async -> Int {
        var returned = 0
        for feedID in feedsWithoutRecords(subscribed: subscribed) {
            returned += await returnDownloads(ofFeed: feedID, toFolderID: nil, removingWith: remove).returned.count
        }
        return returned
    }

    /// The feeds whose folders this library read at launch
    /// (`FeedShelf.indexedFeedIDs`) while none of `subscribed` (by default
    /// the feed engine's records, read or only in the cloud, once they have
    /// loaded) is theirs and no record of theirs is in the records' folder,
    /// in the order of their IDs.
    ///
    /// A record that can't be read, preserved and left out, still has its
    /// file, so its feed is not one. Nothing is decided while the records'
    /// folder cannot be listed without downloading it, while the feed
    /// engine's records have not loaded, or for a feed whose index is left
    /// alone (`FeedShelf.indexesLeftAlone`), whose rows here may be only some
    /// of its own.
    func feedsWithoutRecords(subscribed: Set<UUID>? = nil) -> [UUID] {
        let store = feeds.store
        let known = subscribed ?? (store.hasLoaded ? Set(store.records.keys).union(store.recordsInCloud) : nil)
        guard let known else { return [] }
        let candidates = library.feedShelf.indexedFeedIDs
            .subtracting(known)
            .subtracting(library.feedShelf.indexesLeftAlone)
        guard !candidates.isEmpty else { return [] }
        let recordsFolder = store.location.currentFolder()
        let names: Set<String>
        do {
            names = Set(try DatalessFiles.withoutDownloading {
                try FileManager.default.contentsOfDirectory(atPath: recordsFolder.path)
            })
        } catch {
            return []
        }
        let root = TextMouthPaths.root
        return candidates
            .filter { !names.contains(FeedPaths.recordFile(of: $0, in: recordsFolder).lastPathComponent) }
            .filter { FileManager.default.fileExists(atPath: FeedPaths.itemsFolder(of: $0, in: root).path) }
            .sorted { $0.uuidString < $1.uuidString }
    }

    // MARK: One Feed

    /// Turns the downloads of the feed `feedID`, which is no longer
    /// subscribed, back into books of the library's own, in the library
    /// folder `folderID` names, or at the top level when it names none that
    /// is still there, and deletes what the feed kept of removed downloads.
    /// In order:
    ///
    /// 1. each download's package moves from the feed's folder into that
    ///    library folder, in one rename, and its record is written there,
    ///    without the feed link in its row (its record keeps the link, so
    ///    the book is still known to have come from a feed);
    /// 2. the rows become books of the library's own, and library.json is
    ///    written with them and waited for, while the feed's index on disk
    ///    is left as it is (`FeedShelf.leaveIndexAlone(of:)`), still listing
    ///    them;
    /// 3. only then does each package kept for a removed download go, and,
    ///    once no download stayed, the feed's folder with its index.
    ///
    /// A launch after a crash between any two steps finishes it. A package
    /// moved before library.json was written is adopted from the Library
    /// folder by the startup repair, under its own book ID, so its reading
    /// list place holds, and its row in the feed's index gives way to it
    /// (`joinFeedItems(journaled:access:skips:)`); then the launch returns
    /// the feed's other downloads, and deletes what is left of the feed's
    /// folder, since its record is gone
    /// (`returnDownloadsOfFeedsWithoutRecords(subscribed:removingWith:)`). A
    /// download that cannot move stays where it is, its package put back
    /// when its record could not be written, and the feed's folder stays
    /// with it, for the next launch to try again.
    ///
    /// It holds the storage work, as the move into the feeds' folders does,
    /// waits silently for work under way, and writes the saves already
    /// queued first; readers with a returning book open follow its package.
    /// It does nothing while the library index is recovered, the data
    /// directory is away or moving, or another operation holds the storage
    /// work; the next launch tries again.
    /// - Parameter remove: How a package kept for a removed download, and the
    ///   feed's folder, are removed: as the feed engine removes them, unless
    ///   a test gives its own.
    @discardableResult
    func returnDownloads(
        ofFeed feedID: UUID,
        toFolderID folderID: UUID?,
        removingWith remove: (@MainActor (URL) throws -> Void)? = nil
    ) async -> FeedDownloadReturn {
        guard canMoveDownloads else { return FeedDownloadReturn() }
        guard let hold = try? StorageBoundary.shared.holdWork(for: .movingBooksBetweenFolders) else {
            DiagnosticLog.event(
                .storage,
                "FEED_DOWNLOADS_RETURN: \(feedID.uuidString.prefix(8)): put off, since another operation holds the storage "
                    + "work; the next launch returns them"
            )
            return FeedDownloadReturn()
        }
        defer { hold.release() }
        await hold.waitForWorkUnderWay { _ in }
        LibraryPersistenceService.flushPendingSave()

        // The library as it is now, after the wait; nothing below awaits, so
        // no other change can come between reading it and publishing it.
        guard canMoveDownloads else { return FeedDownloadReturn() }
        let remove = remove ?? feeds.environment.removeItem
        let root = TextMouthPaths.root
        let folderPath = folderID.flatMap { feedFolderPath(forFolderID: $0) } ?? ""
        let downloads = library.books.filter { $0.feedLink?.feedID == feedID }
        let returningIDs = Set(downloads.map(\.id))
        bookUpdates.packagesWillMove(returningIDs)
        defer { bookUpdates.packagesDidMove(returningIDs) }

        var outcome = FeedDownloadReturn()
        for row in downloads {
            do {
                outcome.returned.append(try Self.returnIntoTheLibrary(row, folderPath: folderPath, root: root))
            } catch {
                outcome.stayed.append(row)
                DiagnosticLog.event(
                    .storage,
                    "FEED_DOWNLOAD_RETURN_FAILED: \"\(row.title)\": \(error.localizedDescription); "
                        + "it stays in its feed's folder, and the next launch tries again"
                )
            }
        }

        var updated = library
        for row in outcome.returned {
            guard let index = updated.books.firstIndex(where: { $0.id == row.id }) else { continue }
            updated.books[index].fileLocation = row.fileLocation
        }
        let kept = updated.feedShelf.takeRows { $0.feedLink?.feedID == feedID }
        updated.feedShelf.leaveIndexAlone(of: feedID)
        library = updated
        guard LibraryPersistenceService.saveAndWait(library) else {
            // Reported and retried as every failed index write is; the
            // feed's folder keeps all it holds until library.json does.
            DiagnosticLog.event(
                .storage,
                "FEED_DOWNLOADS_RETURN: \(feedID.uuidString.prefix(8)): library.json could not be written, so the "
                    + "feed's folder keeps what it holds for the next launch"
            )
            return outcome
        }

        outcome.deletedKeptPackages = deleteKeptPackages(kept, of: feedID, root: root, remove: remove)
        if outcome.stayed.isEmpty, removeFeedFolder(of: feedID, root: root, remove: remove) {
            outcome.removedFeedFolder = true
            library.feedShelf.forgetIndex(of: feedID)
        }
        DiagnosticLog.event(
            .storage,
            "FEED_DOWNLOADS_RETURNED: \(feedID.uuidString.prefix(8)): "
                + "\(CountWording.phrase(outcome.returned.count, singular: "download", plural: "downloads")) of a feed "
                + "no longer subscribed became books \(folderPath.isEmpty ? "at the library's top level" : "in its folder"); "
                + "deleted \(CountWording.phrase(outcome.deletedKeptPackages, singular: "package", plural: "packages")) "
                + "kept for removed downloads"
                + (outcome.stayed.isEmpty ? "" : "; \(outcome.stayed.count) stayed in the feed's folder")
        )
        return outcome
    }

    /// `row`, a download of a feed no longer subscribed, moved back into the
    /// library folder `folderPath` of the data directory at `root` as a book
    /// of the library's own, and its row as it is there: step 1 of
    /// `returnDownloads(ofFeed:toFolderID:removingWith:)`, the inverse of
    /// `moveIntoItsFeed(_:link:root:)`. A package an earlier launch moved
    /// before it stopped is found in the library folder and not moved again.
    /// - Throws: `FeedItemMoveError.packageNotManaged` for a row that is no
    ///   feed item's or names no package the library manages, before anything
    ///   on disk is touched, or the errors of `relocatePackage(of:as:root:)`.
    nonisolated static func returnIntoTheLibrary(_ row: Book, folderPath: String, root: URL) throws -> Book {
        var book = row
        book.feedLink = nil
        book.folderPath = folderPath
        guard row.isFeedItem, FileImportService.namesManagedPackage(book) else {
            throw FeedItemMoveError.packageNotManaged
        }
        return try relocatePackage(of: row, as: book, root: root)
    }

    /// Deletes, through `remove`, the package of each of `rows`, the feed
    /// `feedID`'s rows kept after their downloads went, in its folder in the
    /// data directory at `root`, and forgets any record write still queued
    /// for it. A row whose package name names no package directly in a
    /// feed's folder (`FeedItemPackage.isPackageName(_:)`) is passed over:
    /// its "package" could be the feed's whole folder. Returns how many went.
    private func deleteKeptPackages(
        _ rows: [Book],
        of feedID: UUID,
        root: URL,
        remove: @MainActor (URL) throws -> Void
    ) -> Int {
        var deleted = 0
        for row in rows where FeedItemPackage.isPackageName(row.tmbDirectoryName) {
            let package = FeedPaths.packageDirectory(named: row.tmbDirectoryName, of: feedID, in: root)
            LibraryPersistenceService.forgetDeletedBook(row)
            guard FileManager.default.fileExists(atPath: package.path) else { continue }
            do {
                try remove(package)
                deleted += 1
            } catch {
                DiagnosticLog.event(
                    .storage,
                    "FEED_DOWNLOADS_RETURN: could not delete the package kept for \"\(row.title)\": "
                        + "\(error.localizedDescription); the next launch tries again"
                )
            }
        }
        return deleted
    }

    /// Removes, through `remove`, the folder of the feed `feedID` in the data
    /// directory at `root`, its index and what interrupted downloads left
    /// hidden there with it, once nothing else is in it. A folder still
    /// holding a package, as one whose record is only in the cloud and so
    /// was never read as a row, stays for a launch that reads it. Returns
    /// whether the folder is gone.
    private func removeFeedFolder(of feedID: UUID, root: URL, remove: @MainActor (URL) throws -> Void) -> Bool {
        let folder = FeedPaths.itemsFolder(of: feedID, in: root)
        let names: [String]
        do {
            names = try DatalessFiles.withoutDownloading {
                try FileManager.default.contentsOfDirectory(atPath: folder.path)
            }
        } catch {
            return !FileManager.default.fileExists(atPath: folder.path)
        }
        let left = names.filter { !$0.hasPrefix(".") && $0 != FeedPaths.indexFileName }
        guard left.isEmpty else {
            DiagnosticLog.event(
                .storage,
                "FEED_DOWNLOADS_RETURN: \(feedID.uuidString.prefix(8)): the feed's folder stays, holding "
                    + "\(CountWording.phrase(left.count, singular: "item", plural: "items")) no row named; "
                    + "the next launch reads it again"
            )
            return false
        }
        do {
            try remove(folder)
            return true
        } catch {
            DiagnosticLog.event(
                .storage,
                "FEED_DOWNLOADS_RETURN: \(feedID.uuidString.prefix(8)): could not remove the feed's folder: "
                    + "\(error.localizedDescription); the next launch tries again"
            )
            return false
        }
    }
}
