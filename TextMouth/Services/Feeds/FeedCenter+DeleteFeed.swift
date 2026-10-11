import Foundation

// MARK: - Deleting a Feed (FR14)

/// What became of a deleted feed's library folder (FR14).
enum FeedFolderFate: Equatable, Sendable {
    /// It was deleted, nothing else being in it: its path then.
    case deleted(path: String)
    /// It stays, holding a book of the library's own, a folder, or another
    /// feed's items: its path.
    case stays(path: String)
    /// Nothing else was in it, yet it could not be deleted: its path. Why is
    /// in the debug log; the folder stays, as an empty one of the library's.
    case notDeleted(path: String)
    /// It was gone already, as for a feed whose folder Feed Info never
    /// replaced.
    case none
}

/// What Delete Feed… did (FR14, `FeedCenter.deleteFeed(_:)`), for the
/// words the listener hears.
struct FeedDeleteOutcome: Equatable, Sendable {
    /// The feed's title.
    var title: String
    /// How many of the feed's downloads were deleted.
    var deletedDownloads: Int
    /// How many packages the feed kept for downloads removed earlier were
    /// deleted, with the places, bookmarks, and transcripts they held.
    var deletedKeptPlaces: Int
    /// What became of the feed's library folder.
    var folder: FeedFolderFate
}

/// Why Delete Feed… stopped short of deleting a feed (FR14). The feed
/// stays, with its record, its folder, and whatever was not deleted.
enum FeedDeleteError: Error, Equatable, Sendable {
    /// A download of the feed, titled as given, is in use as `use` says:
    /// open in a reader, which nothing may delete, or being transcribed or
    /// exported, whose transcript or export would be lost with it (feed
    /// follow-ups item 1); nothing was deleted.
    case downloadInUse(title: String, use: FeedBookUse)
    /// The library's indexes could not be written before any file went, so
    /// nothing was deleted.
    case indexNotWritten
    /// The downloads or kept packages named, each as "Title: why", could not
    /// be deleted, and stay with the feed; the others went.
    case filesStayed([String])
}

extension FeedCenter {
    /// Deletes the feed `feedID` entirely (FR14), as the listener asked on
    /// October 10, once asked first: "Yes, make sure its not duplicating
    /// another delete action or anything." Delete Feed… is the one command
    /// that deletes a feed; Unsubscribe keeps it (FR11, branch D).
    ///
    /// In an order whose every stopping point is safe, as the next launch
    /// finds it:
    ///
    /// 1. Its downloads stop for good: the one under way, those waiting to
    ///    start, and those put off, every part downloaded going with them,
    ///    and none of its items is asked for again
    ///    (`FeedDownloadManager.closeFeed(_:)`). Every import and every
    ///    removal by the engine's rules already on the import queue ends
    ///    first, so no file of the feed is written or removed while its
    ///    files go: an import of the feed's is discarded, and a removal
    ///    settles.
    /// 2. Its downloads and the packages it kept for downloads removed
    ///    earlier, with their places, bookmarks, and transcripts, go each as
    ///    Delete Episode deletes one, through the listener's own removal (the
    ///    Trash or for good, as the removal setting says): the rows leave the
    ///    library and its reading list, and the feed's index is written
    ///    without them, before any file goes
    ///    (`FeedLibraryHost.removeFeedFiles(of:keepingPackages:remove:)`). A
    ///    stop here leaves the feed with its record and the packages not yet
    ///    gone, which the next launch reads back as its downloads.
    /// 3. The feed's own folder in the data directory goes, with its index
    ///    and whatever interrupted work left hidden there, once no save can
    ///    write that index again (`FeedLibraryHost.forgetFeedIndex(of:)`).
    ///    A stop here leaves the feed with its record and no download.
    /// 4. Its record and this Mac's fetch details go last
    ///    (`FeedStore.remove(_:)`, `FeedFetchStates.remove(_:)`): a launch
    ///    that found the feed's folder with the record gone would return its
    ///    downloads to the library as books, so the record goes only once no
    ///    download is left to return. A folder that could not be removed in
    ///    step 3 holds none, and the launch that finds it deletes it,
    ///    returning nothing (`LibraryViewModel.returnDownloadsOfFeedsWithoutRecords`).
    /// 5. Its library folder goes when nothing else is in it
    ///    (`FeedLibraryHost.removeFolderOfDeletedFeed(_:)`); one holding a
    ///    book of the library's own, a folder, or another feed's items stays.
    ///
    /// An item the listener moved into the library (Move to Library…) is a
    /// book of the library's own, which stays.
    /// - Returns: What deleting did, for the words the listener hears; nil
    ///   for a feed TextMouth has no record of, or one being deleted already.
    /// - Throws: `FeedDeleteError`, the feed then staying with what was not
    ///   deleted.
    @discardableResult
    func deleteFeed(_ feedID: UUID) async throws(FeedDeleteError) -> FeedDeleteOutcome? {
        guard store.record(of: feedID) != nil, let library, !downloads.isClosed(feedID) else { return nil }
        if let inUse = downloadInUse(of: feedID, in: library) {
            throw inUse
        }

        // 1. The feed downloads nothing more, and nothing already in flight
        // is left to land.
        downloads.closeFeed(feedID)
        await downloads.runBesideImports {}
        // The feed, the library, or the readers may have changed meanwhile.
        guard let feed = store.record(of: feedID)?.feed, let library = self.library else {
            downloads.reopenFeed(feedID)
            return nil
        }
        if let inUse = downloadInUse(of: feedID, in: library) {
            downloads.reopenFeed(feedID)
            throw inUse
        }

        // 2. Its downloads and kept packages, the index written first.
        let root = TextMouthPaths.root
        let removal: FeedFileRemovalOutcome
        do {
            removal = try library.removeFeedFiles(of: library.everyRow(ofFeed: feedID), keepingPackages: false) { removal in
                do {
                    // A package gone already counts as removed, as for
                    // every whole package (REV14 feeds 8).
                    try FeedItemPackage.removeWhole(removal.row, in: root, remove: environment.removeItem)
                } catch FeedItemPackageError.notAFeedPackage {
                    // A row naming no package of the feed's folder leaves
                    // nothing to remove here: whatever is left of it goes
                    // with that folder in step 3.
                }
            }
        } catch {
            downloads.reopenFeed(feedID)
            DiagnosticLog.event(.feeds, "FEED_DELETE_PUT_OFF: \(feed.title): \(error.localizedDescription); nothing was deleted")
            throw .indexNotWritten
        }
        guard removal.failures.isEmpty else {
            downloads.reopenFeed(feedID)
            let stayed = removal.failures.map { "\($0.row.title): \($0.error.localizedDescription)" }
            DiagnosticLog.event(
                .feeds,
                "FEED_DELETE_STOPPED: \(feed.title): \(CountWording.phrase(stayed.count, singular: "package", plural: "packages")) "
                    + "could not be deleted, so the feed stays with \(stayed.count == 1 ? "it" : "them")"
            )
            throw .filesStayed(stayed)
        }

        // 3. Its own folder, once no save can make it anew.
        library.forgetFeedIndex(of: feedID)
        removeItemsFolder(of: feedID, root: root)

        // 4. Its record and fetch details, last.
        store.remove(feedID)
        fetchStates.remove(feedID)
        downloads.reopenFeed(feedID)
        rulePauses[feedID] = nil

        // 5. Its library folder, when nothing else is in it.
        let folder = await library.removeFolderOfDeletedFeed(feed.folderID)
        let outcome = FeedDeleteOutcome(
            title: feed.title,
            deletedDownloads: removal.removed.filter { !$0.wasOnShelf }.count,
            deletedKeptPlaces: removal.removed.filter(\.wasOnShelf).count,
            folder: folder
        )
        DiagnosticLog.event(.feeds, "FEED_DELETED: \(feed.title): \(Self.deletionNote(outcome))")
        return outcome
    }

    /// The refusal for the first download of the feed `feedID` in use in
    /// `library` (`FeedBookUse`): open in a reader, which nothing may
    /// delete, or being transcribed or exported, whose work would be lost
    /// with it, as Delete Download and Delete Episode refuse such a book;
    /// nil when none is in use. The debug log says which, and why.
    private func downloadInUse(of feedID: UUID, in library: FeedLibraryHost) -> FeedDeleteError? {
        let inUse = library.feedBooksInUse
        guard !inUse.isEmpty else { return nil }
        for row in library.everyRow(ofFeed: feedID) where inUse.contains(row.id) {
            guard let use = library.feedBookUse(of: row.id) else { continue }
            DiagnosticLog.event(.feeds, "FEED_DELETE_REFUSED: \(row.title): it \(use.clause); nothing was deleted")
            return .downloadInUse(title: row.title, use: use)
        }
        return nil
    }

    /// Removes the feed `feedID`'s own folder in the data directory at
    /// `root`, its index and whatever interrupted work left hidden there,
    /// through the listener's own removal, as its packages went. A folder
    /// that cannot be removed stays, logged, for the next launch, which
    /// finds it without the feed's record and deletes it; it holds no
    /// package by then, so nothing returns to the library.
    private func removeItemsFolder(of feedID: UUID, root: URL) {
        let folder = FeedPaths.itemsFolder(of: feedID, in: root)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try environment.removeItem(folder)
        } catch {
            DiagnosticLog.event(
                .feeds,
                "FEED_DELETE_FOLDER_LEFT: \(feedID.uuidString.prefix(8)): \(error.localizedDescription); "
                    + "the next launch deletes it, as a folder without its feed's record"
            )
        }
    }

    /// What deleting a feed did, as its debug log line says it.
    private static func deletionNote(_ outcome: FeedDeleteOutcome) -> String {
        let downloads = CountWording.phrase(outcome.deletedDownloads, singular: "download", plural: "downloads")
        let kept = CountWording.phrase(outcome.deletedKeptPlaces, singular: "package", plural: "packages")
        let folder: String
        switch outcome.folder {
        case .deleted: folder = "its library folder deleted"
        case .stays: folder = "its library folder stays, holding more"
        case .notDeleted: folder = "its library folder could not be deleted"
        case .none: folder = "it had no library folder"
        }
        return "\(downloads) and \(kept) kept for removed downloads deleted; \(folder)"
    }
}
