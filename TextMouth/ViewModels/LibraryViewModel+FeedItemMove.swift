import Combine
import Foundation

// MARK: - Moving Downloads Made Before FR11 Into Their Feeds

/// Why one download made before FR11 could not move into its feed's folder;
/// it stays a book of the library's own where it is, and the next launch
/// tries again.
enum FeedItemMoveError: LocalizedError, Equatable {
    /// Its row names no package the library manages: no package name, or a
    /// folder path that leaves the library
    /// (`FileImportService.namesManagedPackage(_:)`), so the "package" it
    /// names could be a whole folder of other books.
    case packageNotManaged
    /// Its package is neither in its library folder nor in its feed's.
    case packageMissing
    /// A package of its name is in its library folder and in its feed's
    /// folder both, so which holds the book cannot be told.
    case packageInBothPlaces

    var errorDescription: String? {
        switch self {
        case .packageNotManaged:
            return "its row names no package the library manages"
        case .packageMissing:
            return "its package is in neither its library folder nor its feed's"
        case .packageInBothPlaces:
            return "a package of its name is in both its library folder and its feed's"
        }
    }
}

extension LibraryViewModel {

    /// Moves the downloads made before FR11 into their feeds' folders once
    /// the feeds' records have loaded, which happens off the main thread
    /// just after the library has: the records say which of the library's
    /// books are downloads. Until then each download shows where it always
    /// did. Then returns to the library the downloads of every feed whose
    /// folder is here while its record is gone
    /// (`returnDownloadsOfFeedsWithoutRecords(knownFeeds:absence:removingWith:)`),
    /// and marks downloaded again the items an older TextMouth marked
    /// otherwise (`markFeedItemsDownloadedAgain()`). Called once, as the
    /// feeds start.
    func moveFeedDownloadsOnceRecordsLoad() {
        feeds.store.$hasLoaded
            .filter { $0 }
            .first()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.moveDownloadsIntoTheirFeeds()
                    await self?.returnDownloadsOfFeedsWithoutRecords()
                    self?.markFeedItemsDownloadedAgain()
                }
            }
            .store(in: &cancellables)
    }

    /// Marks downloaded again, as its book, each feed item whose row joined
    /// the library's books, its file here, while its feed's record says it
    /// is not downloaded (FR11). An older TextMouth, which reads no feed
    /// index, never finds such a download among its books and marks its
    /// item not downloaded; once this build is run again, the package with
    /// its file and its index row make it downloaded again. An item deleted
    /// from its feed, or downloading or downloaded as another book, is left
    /// as it is.
    ///
    /// Only a file found here heals its item (FR02's rule: nothing is
    /// decided from a check the cloud answers). A row joins the books while
    /// its file may be only in the cloud, as when another Mac removed the
    /// download and its package is not on this Mac yet; marking such an
    /// item downloaded would undo the other Mac's removal, which would undo
    /// this, back and forth. Such a row, and one whose file is gone, goes
    /// back to its feed's shelf as kept, as the record has it, until a
    /// launch finds its file here.
    /// - Parameter access: How the files are looked for: with dataless files
    ///   left in the cloud, unless a test pretends some are.
    /// - Returns: How many items were marked downloaded again.
    @discardableResult
    func markFeedItemsDownloadedAgain(access: MaintenanceFileAccess = .live) -> Int {
        var marked = 0
        var shelved: [Book] = []
        for row in library.books {
            guard let link = row.feedLink,
                  let item = feeds.store.record(of: link.feedID)?.item(link.itemID),
                  item.deletedDate == nil, item.state.bookID == nil, !item.state.isDownloading else { continue }
            guard access.presence(of: row.bookFileURL) == .present else {
                shelved.append(row)
                continue
            }
            feeds.store.updateItem(link.itemID, of: link.feedID) { item in
                item.state = .downloaded(bookID: row.id)
                item.downloadDeletedDate = nil
            }
            marked += 1
        }
        if marked > 0 {
            DiagnosticLog.event(
                .feeds,
                "FEED_ITEMS_DOWNLOADED_AGAIN: marked \(CountWording.phrase(marked, singular: "item", plural: "items")) "
                    + "downloaded again whose packages and index rows an older TextMouth did not read"
            )
        }
        if !shelved.isEmpty {
            // The rows are the same, so the feeds' indexes and library.json
            // stay as they are: only where the model holds them changes.
            var updated = library
            let shelvedIDs = Set(shelved.map(\.id))
            updated.books.removeAll { shelvedIDs.contains($0.id) }
            shelved.forEach { updated.feedShelf.put($0) }
            library = updated
            DiagnosticLog.event(
                .feeds,
                "FEED_ITEMS_KEPT: \(CountWording.phrase(shelved.count, singular: "item", plural: "items")) whose feed's "
                    + "record says not downloaded, and whose file is not on this Mac, went back to its feed's kept rows"
            )
        }
        return marked
    }

    /// The downloads made before FR11 still among the library's own books,
    /// each with the link it takes (FR11): every row of the library's own
    /// whose book a feed's record, in `records`, names as an item's download
    /// (`FeedItemState.downloaded`), the feed subscribed or not, since an
    /// unsubscribed feed keeps its record and its downloads (FR11, branch
    /// D). A book whose feed's record is gone, as one an older build's
    /// Unsubscribe deleted, is named by no record, and stays a book of the
    /// library's own.
    ///
    /// A row whose package name or folder path names no package the library
    /// manages (`FileImportService.namesManagedPackage(_:)`) is left out and
    /// stays a book where it is: with no package name its "package" would be
    /// its whole folder, and with ".." in its folder path it could be every
    /// folder of the library, which one rename would carry into the feed's
    /// folder with every other book in it.
    func downloadsToMoveIntoTheirFeeds(records: [UUID: FeedRecord]) -> [(book: Book, link: FeedBookLink)] {
        downloadRows(namedBy: records).filter { FileImportService.namesManagedPackage($0.book) }
    }

    /// Every row of the library's own that a feed's record in `records`
    /// names as an item's download, with the link it would take, whether or
    /// not its row names a package that can move.
    private func downloadRows(namedBy records: [UUID: FeedRecord]) -> [(book: Book, link: FeedBookLink)] {
        var links: [UUID: FeedBookLink] = [:]
        for record in records.values {
            for item in record.items {
                if let bookID = item.state.bookID {
                    links[bookID] = FeedBookLink(feedID: record.feed.id, itemID: item.id)
                }
            }
        }
        return library.books.compactMap { book in
            guard !book.isFeedItem, let link = links[book.id] else { return nil }
            return (book, link)
        }
    }

    /// Writes one FEED_DOWNLOAD_MOVE_REFUSED line for each download in
    /// `records` that stays a book because its row names no package the
    /// library manages (`downloadsToMoveIntoTheirFeeds(records:)`), naming
    /// what its row holds, so a download that never moves can be found.
    private func logDownloadsThatCannotMove(records: [UUID: FeedRecord]) {
        for (book, _) in downloadRows(namedBy: records) where !FileImportService.namesManagedPackage(book) {
            DiagnosticLog.event(
                .storage,
                "FEED_DOWNLOAD_MOVE_REFUSED: \"\(book.title)\": its row names no package the library manages "
                    + "(package name \"\(book.tmbDirectoryName)\", folder \"\(book.folderPath)\"); "
                    + "it stays a book where it is"
            )
        }
    }

    /// Moves each download made before FR11 that is still a book of the
    /// library's own into its feed's folder (FR11; the design's section 2,
    /// "The move"), keeping its book ID, place, playback times, bookmarks,
    /// settings, last-opened date, and so its history in Stats and its place
    /// in the reading list. In order:
    ///
    /// 1. its feed's folder, `Feeds/<feed ID>/`, is made when missing;
    /// 2. its package moves there from its library folder, in one rename;
    /// 3. its row takes its feed link and no library folder, its file path
    ///    is worked out again, and its record is written where it is now;
    /// 4. each feed's index is written with its rows, and waited for;
    /// 5. and only then library.json is written without them
    ///    (`LibraryPersistenceService.saveAndWait(_:)`, whose one write puts
    ///    the feeds' indexes first).
    ///
    /// A launch after a crash between any two steps mends it: a package
    /// moved before its index was written is found by its feed's index's
    /// reading (`FeedIndexFiles.read`), its row then giving way to the feed
    /// item's at the join, and a download still among the library's books is
    /// moved again, its package found where an earlier launch left it. A
    /// download that cannot move stays where it is, its package put back
    /// when its record could not be written, and the next launch tries again.
    ///
    /// It holds the storage work, as a folder edit moving books does, so no
    /// import, extraction, or analysis writes into a package as it moves;
    /// it waits silently for those under way, and writes the saves already
    /// queued first. Readers with a moving book open hear of the move, and
    /// follow it, as they follow any package's move. It does nothing while
    /// the library index is recovered, the data directory is away or moving,
    /// or another operation holds the storage work; the next launch tries
    /// again.
    /// - Parameter records: The feeds' records: the feed engine's, unless a
    ///   test gives its own.
    /// - Returns: How many downloads moved.
    @discardableResult
    func moveDownloadsIntoTheirFeeds(records: [UUID: FeedRecord]? = nil) async -> Int {
        let records = records ?? feeds.store.records
        logDownloadsThatCannotMove(records: records)
        guard canMoveDownloads, !downloadsToMoveIntoTheirFeeds(records: records).isEmpty else { return 0 }
        guard let hold = try? StorageBoundary.shared.holdWork(for: .movingBooksBetweenFolders) else {
            DiagnosticLog.event(
                .storage,
                "FEED_DOWNLOADS_MOVE: put off, since another operation holds the storage work; the next launch moves them"
            )
            return 0
        }
        defer { hold.release() }
        await hold.waitForWorkUnderWay { _ in }
        LibraryPersistenceService.flushPendingSave()

        // The library as it is now, after the wait; nothing below awaits, so
        // no other change can come between reading it and publishing it.
        let moving = downloadsToMoveIntoTheirFeeds(records: records)
        guard canMoveDownloads, !moving.isEmpty else { return 0 }
        let movingIDs = Set(moving.map(\.book.id))
        bookUpdates.packagesWillMove(movingIDs)
        defer { bookUpdates.packagesDidMove(movingIDs) }

        var moved: [Book] = []
        for (book, link) in moving {
            do {
                moved.append(try Self.moveIntoItsFeed(book, link: link, root: TextMouthPaths.root))
            } catch {
                DiagnosticLog.event(
                    .storage,
                    "FEED_DOWNLOAD_MOVE_FAILED: \"\(book.title)\": \(error.localizedDescription); "
                        + "it stays where it is, and the next launch tries again"
                )
            }
        }
        guard !moved.isEmpty else { return 0 }

        var updated = library
        for row in moved {
            guard let index = updated.books.firstIndex(where: { $0.id == row.id }) else { continue }
            updated.books[index].fileLocation = row.fileLocation
            if let feedID = row.feedLink?.feedID {
                updated.feedShelf.keepIndex(of: feedID)
            }
        }
        library = updated
        LibraryPersistenceService.saveAndWait(library)
        DiagnosticLog.event(
            .storage,
            "FEED_DOWNLOADS_MOVED: moved \(CountWording.phrase(moved.count, singular: "download", plural: "downloads")) "
                + "made before feeds kept their own indexes into their feeds' folders"
        )
        return moved.count
    }

    /// Whether feed items' packages may move between the Library folder and
    /// their feeds' folders now, either way: not while the library index is
    /// recovered, the data directory is unavailable, or the data directory
    /// moves.
    var canMoveDownloads: Bool {
        indexRecovery == nil && dataDirectoryUnavailability == nil && dataDirectoryMove == nil
    }

    /// Moves `book`, a download made before FR11, into the folder of the feed
    /// `link` names in the data directory at `root`, and returns its row as
    /// it is there: steps 1 to 3 of `moveDownloadsIntoTheirFeeds(records:)`.
    /// A package an earlier launch moved before it stopped is found in the
    /// feed's folder and not moved again.
    /// - Throws: `FeedItemMoveError` when the row names no package the
    ///   library manages, before anything on disk is touched, or when the
    ///   package is in neither place or both; or the error that kept a
    ///   folder from being made, the package from moving, or its record from
    ///   being written; the package is then put back where it was when this
    ///   call had moved it.
    nonisolated static func moveIntoItsFeed(_ book: Book, link: FeedBookLink, root: URL) throws -> Book {
        // The list of downloads to move leaves such a row out already; this
        // check keeps the rename below from ever taking a whole folder,
        // whoever calls it.
        guard FileImportService.namesManagedPackage(book) else {
            throw FeedItemMoveError.packageNotManaged
        }
        var moved = book
        moved.folderPath = ""
        moved.feedLink = link
        return try relocatePackage(of: book, as: moved, root: root)
    }

    /// Moves the package of `book` from where `book` places it in the data
    /// directory at `root` to where `relocated`, the same book with another
    /// place, puts it, in one rename, and writes its record there; returns
    /// `relocated` with its file at its place in the moved package. The two
    /// moves between a library folder and a feed's folder both take this
    /// step: a download made before FR11 moving into its feed's folder
    /// (`moveIntoItsFeed(_:link:root:)`), and the download of a feed whose
    /// record is gone returning to the library
    /// (`returnIntoTheLibrary(_:folderPath:root:)`).
    ///
    /// A package already where `relocated` puts it, and not where `book`
    /// does, was moved by an earlier launch that stopped before it was done,
    /// and is not moved again; its record is written all the same. The
    /// caller has checked that both rows name a package the library manages
    /// (`FileImportService.namesManagedPackage(_:)`).
    /// - Throws: `FeedItemMoveError` when the package is in neither place or
    ///   both, or the error that kept a folder from being made, the package
    ///   from moving, or its record from being written; the package is then
    ///   put back where it was when this call had moved it.
    nonisolated static func relocatePackage(of book: Book, as relocated: Book, root: URL) throws -> Book {
        let source = book.packageDirectory(inDataDirectory: root)
        var relocated = relocated
        let destination = relocated.packageDirectory(inDataDirectory: root)
        relocated.filePath = FeedIndexFiles.path(book.filePath, inPackageNamed: book.tmbDirectoryName, at: destination)

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var renamed = false
        switch (fileManager.fileExists(atPath: source.path), fileManager.fileExists(atPath: destination.path)) {
        case (true, false):
            try fileManager.moveItem(at: source, to: destination)
            renamed = true
        case (false, true):
            // An earlier launch moved it before it stopped.
            break
        case (true, true):
            throw FeedItemMoveError.packageInBothPlaces
        case (false, false):
            throw FeedItemMoveError.packageMissing
        }
        do {
            try relocated.saveBookInfoThrowing(inPackageAt: destination)
        } catch {
            if renamed {
                try? fileManager.moveItem(at: destination, to: source)
            }
            throw error
        }
        return relocated
    }
}
