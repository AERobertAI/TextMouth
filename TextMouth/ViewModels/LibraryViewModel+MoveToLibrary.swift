import Foundation

// MARK: - Move to Library… (FR11, Branch D)

/// Why Move to Library… left an episode or article in its feed (FR11, branch
/// D), in the words the sheet shows and VoiceOver speaks after "Could not
/// move to the library: ".
enum MoveToLibraryError: LocalizedError, Equatable {
    /// Nothing chosen is an episode or article downloaded in its feed.
    case nothingToMove
    /// The folder chosen is no longer in the library.
    case folderMissing
    /// The library cannot move books now: its index is recovered, or the
    /// data directory is away or moving.
    case libraryUnavailable
    /// The feed's record, which must say "In Library" before anything moves,
    /// could not be saved, so nothing moved.
    case recordNotSaved

    var errorDescription: String? {
        switch self {
        case .nothingToMove:
            return "Only an episode or article downloaded in its feed can move into the library."
        case .folderMissing:
            return "The folder chosen is no longer in the library. Choose another folder."
        case .libraryUnavailable:
            return "The library can't move books now. Try again once it is available."
        case .recordNotSaved:
            return "TextMouth couldn't save the feed's list of its items, so nothing moved."
        }
    }
}

/// Move to Library… (FR11, branch D; the listener's answer 5: "'Move to
/// Library…' moves an episode or article into the folder the user chooses as
/// an ordinary book, with its place, bookmarks, settings, and transcript;
/// its feed then lists it as 'In Library' and never downloads it again").
///
/// The book is the same package under the same book ID, so it keeps its
/// place, playback times, bookmarks, its own settings, its transcript, its
/// place on the reading list, and its history in Stats; its record keeps
/// its feed link (`Book.bookInfo(replacing:contentIndex:revisionFloor:)`),
/// so its item, which says "In Library", still knows it, and Books Finished
/// counts it as an episode.
extension LibraryViewModel {

    /// The context of every failure's words: "Could not move to the
    /// library: …".
    static let moveToLibraryFailureContext = "Could not move to the library"

    /// The books of `books` Move to Library… can move, each once, in their
    /// order, as the library holds them now: feed items whose files are here,
    /// among the library's books (`Book.isFeedItem`), whose package the
    /// library manages, and whose item their feed's record says is
    /// downloaded as that very book. A book of the library's own is none,
    /// and so is an item another Move to Library… has marked "In Library"
    /// while its package is still to move: two moves never mark one item, so
    /// each puts back only its own mark (`unmarkInLibrary(_:)`, REV13 feeds
    /// 9), as the check and the marking happen in one step on the main
    /// actor.
    func booksMovableToLibrary(_ books: [Book]) -> [Book] {
        var seen = Set<UUID>()
        return books.compactMap { requested in
            guard seen.insert(requested.id).inserted,
                  let row = feedBook(withID: requested.id),
                  let link = row.feedLink,
                  FileImportService.namesManagedPackage(row),
                  feeds.store.record(of: link.feedID)?.item(link.itemID)?.state == .downloaded(bookID: row.id) else { return nil }
            return row
        }
    }

    /// Moves `books`, episodes and articles downloaded in their feeds, into
    /// the library folder at `path` ("" for the library's top level) as
    /// books of the library's own, as Move to Library… does, and returns
    /// what happened, presenting nothing, so the sheet can stay open with
    /// the reason after a failure. Each item's feed then lists it "In
    /// Library" (`FeedItemState.inLibrary`), the listener's from then on, and
    /// never downloads it again. A move whose packages moved only in part
    /// is a failure that says what moved and what stayed in its feed, and
    /// why (`FeedWording.partlyMovedToLibrary`, REV13 feeds 5), so the sheet,
    /// left open for the rest, never hides the move that happened.
    ///
    /// The order never loses a book or a place, and a crash at any point is
    /// settled at the next launch:
    ///
    /// 1. Each item's state in its feed's record becomes "in library", and
    ///    the record is written and waited for before anything moves: the
    ///    move's commit point. A record that cannot be written puts the
    ///    states back, and nothing moves. It is written before the storage
    ///    work is held, since a record's write is storage work itself.
    /// 2. With the storage work held, as every move of packages holds it,
    ///    the work under way finished and the saves already queued written
    ///    (the book's record among them, at its feed's folder), each package
    ///    moves from its feed's folder into the library folder in one
    ///    rename, and its record is written there, the row's feed link
    ///    cleared (`moveIntoTheLibrary(_:folderPath:root:)`). A package that
    ///    cannot move is put back, and its item's state with it.
    /// 3. The rows become books of the library's own, in that folder, and
    ///    the library's indexes are written and waited for, each save's one
    ///    order: the feed's index without them, then library.json with them.
    ///    A failed write is reported and retried as every index write is.
    ///
    /// A crash after step 1, before a package moved, leaves its book in its
    /// feed, where the launch marks its item downloaded again
    /// (`markFeedItemsDownloadedAgain(access:)`). A crash once a package has
    /// moved, before library.json lists its book, leaves the package under
    /// the Library folder, which the startup repair adopts from its record
    /// under its own book ID, the row in the feed's index giving way to it
    /// (`joinFeedItems(journaled:access:skips:)`); its item says "in library"
    /// already, so the launch's move of downloads into their feeds passes it
    /// over. Readers with a moving book open follow its package, as they
    /// follow any package's move.
    func moveToLibraryReturningOutcome(_ books: [Book], toFolder path: String) async -> OperationOutcome {
        let context = Self.moveToLibraryFailureContext
        guard canMoveDownloads else { return .failure(context, MoveToLibraryError.libraryUnavailable) }
        guard path.isEmpty || library.folders.contains(where: { $0.fullPath == path }) else {
            return .failure(context, MoveToLibraryError.folderMissing)
        }
        let moving = booksMovableToLibrary(books)
        guard !moving.isEmpty else { return .failure(context, MoveToLibraryError.nothingToMove) }

        // 1. The commit point: each item says "in library" on disk first.
        let marks = moving.compactMap(markInLibrary)
        await feeds.store.flush()
        guard Set(marks.map(\.link.feedID)).isDisjoint(with: feeds.store.unsavedFeedIDs) else {
            marks.forEach(unmarkInLibrary)
            DiagnosticLog.event(.feeds, "FEED_MOVE_TO_LIBRARY_PUT_OFF: the feed's record could not be saved, so nothing moved")
            return .failure(context, MoveToLibraryError.recordNotSaved)
        }

        // 2 and 3, with the storage work held.
        let hold: StorageWorkHold
        do {
            hold = try StorageBoundary.shared.holdWork(for: .movingBooksBetweenFolders)
        } catch {
            marks.forEach(unmarkInLibrary)
            return .failure(context, error)
        }
        defer { hold.release() }
        await hold.waitForWorkUnderWay { work in
            VoiceOverAnnouncer.announce(work.waitingMessage)
        }
        LibraryPersistenceService.flushPendingSave()

        // The library as it is now, after the waits; nothing below awaits,
        // so no other change can come between reading it and publishing it.
        guard canMoveDownloads else {
            marks.forEach(unmarkInLibrary)
            return .failure(context, MoveToLibraryError.libraryUnavailable)
        }
        let rows = marks.compactMap { mark in feedBook(withID: mark.bookID).flatMap { $0.isFeedItem ? $0 : nil } }
        let movingIDs = Set(rows.map(\.id))
        bookUpdates.packagesWillMove(movingIDs)
        defer { bookUpdates.packagesDidMove(movingIDs) }

        let root = TextMouthPaths.root
        var moved: [Book] = []
        // Each row whose package stayed, with why, for the words of a move
        // that moved only some (REV13 feeds 5).
        var stayed: [(title: String, reason: String)] = []
        var failure: (any Error)?
        for row in rows {
            do {
                moved.append(try Self.moveIntoTheLibrary(row, folderPath: path, root: root))
            } catch {
                failure = failure ?? error
                stayed.append((title: row.title, reason: error.localizedDescription))
                DiagnosticLog.event(
                    .storage,
                    "FEED_MOVE_TO_LIBRARY_FAILED: \"\(row.title)\": \(error.localizedDescription); it stays in its feed"
                )
            }
        }
        // An item whose package did not move stays its feed's download.
        let movedIDs = Set(moved.map(\.id))
        marks.filter { !movedIDs.contains($0.bookID) }.forEach(unmarkInLibrary)
        guard !moved.isEmpty else {
            return .failure(context, failure ?? MoveToLibraryError.nothingToMove)
        }

        // 3. The rows become the library's own, and the indexes are written.
        var updated = library
        for row in moved {
            guard let index = updated.books.firstIndex(where: { $0.id == row.id }) else { continue }
            if let feedID = updated.books[index].feedLink?.feedID {
                // Written without the row, even when it was the feed's last.
                updated.feedShelf.keepIndex(of: feedID)
            }
            updated.books[index].fileLocation = row.fileLocation
        }
        library = updated
        LibraryPersistenceService.saveAndWait(library)
        lastMovedFolderPath = path
        for row in moved {
            DiagnosticLog.event(
                .storage,
                "FEED_ITEM_MOVED_TO_LIBRARY: \"\(row.title)\" became a book of the library's own "
                    + (path.isEmpty ? "at the library's top level" : "in the folder chosen")
            )
        }
        guard !stayed.isEmpty else { return .success(nil) }
        // Some moved and some stayed: the sheet, left open, says both, so
        // the move that happened is never hidden behind what failed.
        return .failure(FeedWording.partlyMovedToLibrary(
            moved: moved.map(\.title),
            noun: FeedWording.noun(of: moved),
            folderPath: path,
            stayed: stayed
        ))
    }

    /// `row`, a feed item's download, moved into the library folder
    /// `folderPath` of the data directory at `root` as a book of the
    /// library's own, and its row as it is there: its package moved out of
    /// its feed's folder in one rename, and its record written there with
    /// the feed link cleared from its row (the record keeps the link). Move
    /// to Library… takes this step (`moveToLibraryReturningOutcome(_:toFolder:)`),
    /// and so does the return of the downloads of a feed whose record is
    /// gone (`returnDownloads(ofFeed:toFolderID:removingWith:)`): the inverse
    /// of `moveIntoItsFeed(_:link:root:)`. A package an earlier launch moved
    /// before it stopped is found in the library folder and not moved again.
    /// - Throws: `FeedItemMoveError.packageNotManaged` for a row that is no
    ///   feed item's or names no package the library manages, before anything
    ///   on disk is touched, or the errors of `relocatePackage(of:as:root:)`,
    ///   which puts the package back when its record could not be written.
    nonisolated static func moveIntoTheLibrary(_ row: Book, folderPath: String, root: URL) throws -> Book {
        var book = row
        book.feedLink = nil
        book.folderPath = folderPath
        guard row.isFeedItem, FileImportService.namesManagedPackage(book) else {
            throw FeedItemMoveError.packageNotManaged
        }
        return try relocatePackage(of: row, as: book, root: root)
    }

    // MARK: The Items' States

    /// What Move to Library… changed of one item's state in its feed's
    /// record, to put back should its book stay in the feed.
    struct InLibraryMark {
        /// The item's feed and identity.
        let link: FeedBookLink
        /// The book moving.
        let bookID: UUID
        /// The item's state before.
        let state: FeedItemState
        /// Who had asked for its download before.
        let downloadOrigin: FeedDownloadOrigin?
    }

    /// Marks the item of `row`, a feed item's download, "in library" in its
    /// feed's record, the listener's from now on, so the newest-N rule never
    /// downloads it again; returns what to put back should the book stay in
    /// its feed, or nil when the record no longer names the item.
    private func markInLibrary(_ row: Book) -> InLibraryMark? {
        guard let link = row.feedLink, let item = feeds.store.record(of: link.feedID)?.item(link.itemID) else { return nil }
        feeds.store.updateItem(link.itemID, of: link.feedID) { item in
            item.state = .inLibrary(bookID: row.id)
            item.downloadOrigin = .listener
        }
        return InLibraryMark(link: link, bookID: row.id, state: item.state, downloadOrigin: item.downloadOrigin)
    }

    /// Puts back what `mark` changed, unless the item has changed again
    /// since, as when Delete Episode deleted it meanwhile. A mark found is
    /// this move's own: no other move marks an item already marked
    /// (`booksMovableToLibrary(_:)`).
    private func unmarkInLibrary(_ mark: InLibraryMark) {
        feeds.store.updateItem(mark.link.itemID, of: mark.link.feedID) { item in
            guard item.state == .inLibrary(bookID: mark.bookID) else { return }
            item.state = mark.state
            item.downloadOrigin = mark.downloadOrigin
        }
    }
}
