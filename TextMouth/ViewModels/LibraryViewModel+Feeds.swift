import Combine
import Foundation

/// The library's side of the podcast and article reader (FR03): the feed
/// engine starts with the library, finds a feed's folder by its ID, and adds
/// the books its downloads publish.
extension LibraryViewModel: FeedLibraryHost {
    /// The feed engine this library works with: the app's, unless a test
    /// gave its own (`feedEngine`).
    var feeds: FeedCenter {
        feedEngine ?? FeedCenter.shared
    }

    // MARK: - A Feed's Items in Its Folder (FR11)

    /// The feed whose folder is the library folder at `path`, if any.
    func feedID(listedIn path: String) -> UUID? {
        guard !path.isEmpty, let folder = library.folders.first(where: { $0.fullPath == path }) else { return nil }
        return feeds.store.feed(inFolder: folder.id)?.id
    }

    /// The feed items the library folder at `path` lists beside its own
    /// books (FR11): the rows of its feed's items whose files are here,
    /// found by feed ID, since a feed item's row names no folder; none for a
    /// folder that holds no feed. So a folder's rename or move, and Feed
    /// Info's change of folder, take a feed's items along without changing
    /// any row.
    func feedItems(listedIn path: String) -> [Book] {
        guard let feedID = feedID(listedIn: path) else { return [] }
        return library.books.filter { $0.feedLink?.feedID == feedID }
    }

    /// Starts the feed engine with this library, once the library has
    /// loaded: it reads the feeds' records off the main thread and, outside
    /// a process hosting tests, refreshes every feed when the settings say
    /// to. Once the records have loaded, the downloads made before FR11 move
    /// into their feeds' folders (`moveDownloadsIntoTheirFeeds(records:)`).
    /// Returns at once, so nothing the engine does holds the library back.
    func startFeeds() {
        feeds.start(library: self)
        moveFeedDownloadsOnceRecordsLoad()
    }

    // MARK: - FeedLibraryHost

    /// The path of the library folder `folderID`, wherever it has been
    /// renamed or moved to; nil when the folder is gone.
    func feedFolderPath(forFolderID folderID: UUID) -> String? {
        library.folders.first { $0.id == folderID }?.fullPath
    }

    /// Each feed's folder path, by feed ID, for the folder conditions of a
    /// Library view that lists episodes or articles, which are in their
    /// feeds' folders: every feed whose folder is in the library, the first
    /// kept should two share an ID.
    func feedFolderPathsByFeedID() -> [UUID: String] {
        let pairs = feeds.feeds.compactMap { feed in
            feedFolderPath(forFolderID: feed.folderID).map { (feed.id, $0) }
        }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    /// The book `bookID`, when the library lists it: found through the
    /// library's books by ID, worked out once for each change of the
    /// library, rather than by a scan of every book (FR11, branch A2).
    func feedBook(withID bookID: UUID) -> Book? {
        feedItemRowLookup.book(withID: bookID, in: library, revision: listCache.contentRevision)
    }

    /// The feed `feedID`'s rows, found by the identity of the item each came
    /// from: those whose files are here and those kept after their files
    /// went (FR11, branch A2).
    func feedItemRows(of feedID: UUID) -> FeedItemRows {
        feedItemRowLookup.rows(of: feedID, in: library, revision: listCache.contentRevision)
    }

    /// Lists a book a feed download published, and saves the library. An
    /// episode skips the duplicate question, and the library's rule against
    /// two books of one file, since two shows can carry one file.
    ///
    /// The book is a feed item's (FR11): its row carries the feed link the
    /// import gave it and no library folder, its package is in its feed's
    /// folder, and the save writes it to its feed's index, which the library
    /// keeps from now on, never to library.json. A download that restored a
    /// row kept after an earlier download's file went takes that row's place
    /// on the shelf (branch A2), so no book is ever both.
    func addFeedBook(_ book: Book) {
        guard bookByID(book.id) == nil else { return }
        var row = book
        var updated = library
        if let feedID = row.feedLink?.feedID {
            row.folderPath = ""
            updated.feedShelf.keepIndex(of: feedID)
            _ = updated.feedShelf.takeRows { $0.id == row.id }
        }
        updated.books.append(row)
        library = updated
        save()
    }

    /// Shows the transcript fetched with an episode and just saved into its
    /// package (FMT25), as a finished transcription shows its own
    /// (`TranscriptionJobCenter`): the row says the book is transcribed, and
    /// its open readers show `text`.
    func feedTranscriptAttached(bookID: UUID, text: TranscriptText) {
        TranscribedBooks.shared.record(bookID, isTranscribed: true)
        bookUpdates.transcriptReplaced(bookID: bookID, with: text)
    }

    /// Removes the files of the feed items `books` the library lists, in the
    /// order that never loses the listener's place (FR11, branch A2;
    /// FEED-ITEMS-ADDENDUM-2026-10-07.md, section 6):
    ///
    /// 1. With `keepingPackages`, each book whose package holds something
    ///    of the listener's (`FeedItemPackage.holdsListenerState`) has its
    ///    record written at once, from its row as the library holds it now,
    ///    and waited for (`LibraryPersistenceService.writePendingBookInfoNow`).
    /// 2. Each row leaves the books, to its feed's shelf when its package
    ///    stays, and the library's indexes, its feed's among them, are
    ///    written at once and waited for (`LibraryPersistenceService.saveAndWait`).
    /// 3. Only then does `remove` remove each file and what it made, or each
    ///    whole package.
    ///
    /// A row whose file `remove` could not remove goes back among the books
    /// as it was, still on the reading list. The others leave the reading
    /// list; a package gone whole has its pending record writes forgotten,
    /// as every removal that deletes a package does; and the reading text
    /// this Mac kept for each goes. `removeDeletedBook(_:)` itself is not
    /// used: a kept package's record must still take its pending writes.
    ///
    /// Without `keepingPackages`, as Delete Episode asks, a row kept on its
    /// feed's shelf after its file went is removed too, its package whole,
    /// and goes back to the shelf when the package cannot be removed. A book
    /// the library no longer lists, or one of its own, is passed over.
    ///
    /// All three steps run here, on the main actor, as the listener's own
    /// deletions ask; the engine's rules run step 3 off the main thread
    /// between `readyFeedFilesForRemoval(of:keepingPackages:)` and
    /// `settleFeedFileRemovals(_:failures:)`, which make up this one.
    /// - Returns: The removals whose files went, and why each other's stayed.
    /// - Throws: `FeedItemPackageError.indexNotWritten` when the indexes
    ///   could not be written: the library is as it was, and no file was
    ///   touched.
    func removeFeedFiles(
        of books: [Book],
        keepingPackages: Bool,
        remove: (FeedFileRemoval) throws -> Void
    ) throws -> FeedFileRemovalOutcome {
        let removals = try readyFeedFilesForRemoval(of: books, keepingPackages: keepingPackages)
        var failures: [UUID: any Error] = [:]
        for removal in removals {
            do {
                try remove(removal)
            } catch {
                failures[removal.row.id] = error
            }
        }
        return settleFeedFileRemovals(removals, failures: failures)
    }

    /// Steps 1 and 2 of `removeFeedFiles(of:keepingPackages:remove:)`: the
    /// records that keep the listener's state written and waited for, the
    /// rows out of the books (to their feeds' shelves when their packages
    /// stay), and the indexes on disk, all on the main actor, so the library
    /// changes and is saved as one. Nothing is removed yet.
    ///
    /// `listenersFilesHeld` has, for the books whose packages were read off
    /// the main thread already (`FeedItemPackage.listenersFilesHeld(in:)`),
    /// whether each holds files of the listener's; a book not in it is read
    /// here, as the listener's own one-book deletions do.
    /// - Returns: The removals to make, in the order asked.
    /// - Throws: `FeedItemPackageError.indexNotWritten` when the indexes
    ///   could not be written: the library is as it was.
    func readyFeedFilesForRemoval(
        of books: [Book],
        keepingPackages: Bool,
        listenersFilesHeld: [UUID: Bool] = [:]
    ) throws -> [FeedFileRemoval] {
        var updated = library
        var removals: [FeedFileRemoval] = []
        for requested in books {
            let listed = feedBook(withID: requested.id)
            // A row kept on the shelf has no file left; only a removal of
            // its whole package takes it.
            let shelved = listed == nil && !keepingPackages ? library.feedShelf.rows.first { $0.id == requested.id } : nil
            guard let row = listed ?? shelved, let feedID = row.feedLink?.feedID,
                  !removals.contains(where: { $0.row.id == row.id }) else { continue }
            if shelved != nil {
                _ = updated.feedShelf.takeRows { $0.id == row.id }
                updated.feedShelf.keepIndex(of: feedID)
                removals.append(FeedFileRemoval(row: row, keepsPackage: false, wasOnShelf: true))
                continue
            }
            let keeps = keepingPackages && FeedItemPackage.holdsListenerState(
                row,
                package: row.tmbDirectory,
                holdsListenersFiles: listenersFilesHeld[row.id]
            )
            if keeps {
                // 1. The record takes the row's state before anything else changes.
                LibraryPersistenceService.saveBookInfo(for: row)
                LibraryPersistenceService.writePendingBookInfoNow(bookID: row.id)
                updated.feedShelf.put(row)
            } else {
                updated.feedShelf.keepIndex(of: feedID)
            }
            updated.books.removeAll { $0.id == row.id }
            removals.append(FeedFileRemoval(row: row, keepsPackage: keeps))
        }
        guard !removals.isEmpty else { return [] }

        // 2. The rows leave the books, and the indexes are on disk before any
        // file goes; a failed write keeps every file and every row as it was.
        let before = library
        library = updated
        guard LibraryPersistenceService.saveAndWait(library) else {
            library = before
            save()
            throw FeedItemPackageError.indexNotWritten
        }
        return removals
    }

    /// The end of `removeFeedFiles(of:keepingPackages:remove:)`, once step 3
    /// has removed what it could of `removals`, on the main actor: each
    /// removal whose file went leaves the reading list, a package gone whole
    /// has its pending record writes forgotten, and the reading text this
    /// Mac kept goes; each row whose file stayed, named in `failures` with
    /// why, goes back where it was, among the books or on its feed's shelf.
    /// - Returns: The removals whose files went, and why each other's stayed.
    func settleFeedFileRemovals(_ removals: [FeedFileRemoval], failures: [UUID: any Error]) -> FeedFileRemovalOutcome {
        var outcome = FeedFileRemovalOutcome()
        var afterwards = library
        var changed = false
        for removal in removals {
            let id = removal.row.id
            if let error = failures[id] {
                outcome.failures.append((row: removal.row, error: error))
                _ = afterwards.feedShelf.takeRows { $0.id == id }
                if removal.wasOnShelf {
                    afterwards.feedShelf.put(removal.row)
                } else if !afterwards.books.contains(where: { $0.id == id }) {
                    afterwards.books.append(removal.row)
                }
                changed = true
                continue
            }
            outcome.removed.append(removal)
            changed = !afterwards.readingList.remove([id]).isEmpty || changed
            if !removal.keepsPackage {
                LibraryPersistenceService.forgetDeletedBook(removal.row)
            }
            ReadingTextCache.shared.remove(bookID: id)
        }
        if changed {
            library = afterwards
            save()
        }
        return outcome
    }

    /// The books in use now, which the feed engine's rules leave for their
    /// next pass (REV11 F1): the books `feedBookUses` lists, which the
    /// listener's own deletions refuse (`feedBookUse(of:)`), and the books
    /// being edited with Edit Text (`textEditSessions`), which they do not:
    /// an editing session ends only when TextMouth quits, so a deletion
    /// refused for it would stay refused until then. A rule that waits
    /// leaves the text the listener is editing in its download until the
    /// next pass; a download that goes anyway keeps its transcript in its
    /// package, and a save made after it went is kept when the episode is
    /// downloaded again (`FeedEpisodeImporter`).
    var feedBooksInUse: Set<UUID> {
        feedBookUses.reduce(into: textEditSessions.bookIDs) { inUse, use in inUse.formUnion(use.bookIDs) }
    }

    /// How the book `bookID` is in use now, the first that holds of open in
    /// a reader, being transcribed, and being exported, or nil when none
    /// does. A book being edited with Edit Text is not in use here: it
    /// waits only for the rules (`feedBooksInUse`).
    func feedBookUse(of bookID: UUID) -> FeedBookUse? {
        feedBookUses.first { $0.bookIDs.contains(bookID) }?.use
    }

    /// Each way a book can be in use that the listener's own deletions
    /// refuse, with the books in use that way now: the list
    /// `feedBookUse(of:)` reads, and `feedBooksInUse` adds to.
    private var feedBookUses: [(use: FeedBookUse, bookIDs: Set<UUID>)] {
        [
            (.openInReader, openBookIDs),
            (.transcribing, TranscribedBooks.shared.transcribingBookID.map { [$0] } ?? []),
            (.exporting, BookExportModel.booksBeingExported),
        ]
    }

    /// Whether the book `bookID` is on the reading list, whose downloads the
    /// feeds' newest-N rule never removes (FR11).
    func feedBookIsOnReadingList(_ bookID: UUID) -> Bool {
        library.readingList.contains(bookID)
    }

    /// Publishes the books open in readers whenever they change.
    var feedBooksOpenInReadersChanges: AnyPublisher<Set<UUID>, Never> {
        $openBookIDs.eraseToAnyPublisher()
    }

    /// Whether the library lists every book it holds: not while its index
    /// is recovered (`indexRecovery`), when the library is provisional.
    var feedLibraryIsComplete: Bool {
        indexRecovery == nil
    }

    /// Opens the book `bookID` in its reader, as an import that opens its
    /// book does.
    func openFeedBook(_ bookID: UUID) {
        readerOpener(bookID)
    }

    /// Makes a folder for a new subscription to the feed titled `title`
    /// inside the folder at `parentPath` ("" for the library's top level),
    /// as New Folder makes one: the feed's title, made a folder name
    /// (`FeedFolderNaming.baseName(for:)`), followed by " 2", " 3", and so on
    /// while a folder of that name is there already.
    /// - Throws: `FeedFolderError` when the parent folder is gone, or no
    ///   folder could be made there.
    func makeFeedFolder(named title: String, inParentPath parentPath: String) throws(FeedFolderError) -> UUID {
        // A parent path naming no folder would leave the new folder outside
        // the library's tree.
        guard parentPath.isEmpty || library.existingFolder(equivalentTo: parentPath) != nil else {
            throw FeedFolderError(message: FeedFolderNaming.parentMissingMessage)
        }
        let base = FeedFolderNaming.baseName(for: title)
        for name in FeedFolderNaming.candidates(for: base) {
            do {
                return try createFolderReturningFolder(name: name, parentPath: parentPath).id
            } catch {
                switch error {
                case .refused(.nameInUse):
                    // Taken: try the next name.
                    continue
                default:
                    throw FeedFolderError(message: error.outcome.failureMessage ?? FeedFolderNaming.notMadeMessage)
                }
            }
        }
        throw FeedFolderError(message: FeedFolderNaming.notMadeMessage)
    }
}

// MARK: - Rows by Item and Books by ID (FR11)

/// The library's feed rows by feed and item, and its books by ID, worked out
/// in one pass the first time either is asked for after a change of the
/// library, and kept until the next (FR11, branch A2).
///
/// A feed's counts look up each of its items, and a list of a feed's folder
/// asks for each item's state, so each lookup must cost one step: a scan of
/// the library's books for each item cost a millisecond for a 381-item feed
/// (FEED-ITEMS-ADDENDUM-2026-10-07.md, section 1). The library model passes
/// its list cache's content revision, which every change of its library
/// moves on, so nothing found here is ever older than the library.
///
/// Main-actor isolated, like the library model that owns it; it publishes
/// nothing, so a list drawing may fill it.
@MainActor
final class FeedItemRowLookup {
    /// The content revision of the library the lookups were worked out
    /// from; nil before the first.
    private var revision: Int?
    /// Each feed's rows by item.
    private var rowsByFeed: [UUID: FeedItemRows] = [:]
    /// Each book's index in the library's books, by ID; the first of an ID
    /// wins, as `bookByID` finds it (`LibraryListCache.index(of:)`).
    private var bookIndexByID: [UUID: Int] = [:]

    /// The feed `feedID`'s rows in `library`, whose content revision is
    /// `revision`; none for a feed it holds no row of.
    func rows(of feedID: UUID, in library: Library, revision: Int) -> FeedItemRows {
        refresh(from: library, revision: revision)
        return rowsByFeed[feedID] ?? FeedItemRows()
    }

    /// The book `id` among `library`'s books, whose content revision is
    /// `revision`, or nil when it holds none.
    func book(withID id: UUID, in library: Library, revision: Int) -> Book? {
        refresh(from: library, revision: revision)
        guard let index = bookIndexByID[id], library.books.indices.contains(index),
              library.books[index].id == id else { return nil }
        return library.books[index]
    }

    /// Works the lookups out again from `library` when they were worked out
    /// from another revision of it.
    private func refresh(from library: Library, revision: Int) {
        guard self.revision != revision else { return }
        self.revision = revision
        rowsByFeed = FeedItemRows.byFeed(in: library)
        bookIndexByID = LibraryListCache.index(of: library.books)
    }
}

// MARK: - Naming a Feed's Folder (FR03)

/// How a new subscription's folder is named: after the feed, as a folder
/// name may be written, told apart from folders already there by a number.
enum FeedFolderNaming {
    /// The longest name given, in characters: a feed's title can run long,
    /// and a folder's name is also a directory's name on disk.
    static let maximumLength = 80
    /// How many numbered names are tried before giving up: " 2" to " 99".
    static let maximumNumber = 99

    /// What a new subscription's folder is called, before any number: the
    /// feed's title as a folder name may hold it (`BookFolder.normalizedName`,
    /// which turns "/" into "-"), cut to `maximumLength` characters at a
    /// word where it can be, or "Feed" for a title no folder name can hold.
    static func baseName(for title: String) -> String {
        guard let normalized = BookFolder.normalizedName(title) else { return "Feed" }
        guard normalized.count > maximumLength else { return normalized }
        let cut = String(normalized.prefix(maximumLength))
        // Cut at the last space, unless that leaves too little of the title.
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= maximumLength / 2 {
            return BookFolder.normalizedName(String(cut[..<space])) ?? cut
        }
        return BookFolder.normalizedName(cut) ?? "Feed"
    }

    /// The names tried in turn for a folder called `base`: `base` itself,
    /// then "`base` 2", "`base` 3", up to `maximumNumber`.
    static func candidates(for base: String) -> [String] {
        [base] + (2...maximumNumber).map { "\(base) \($0)" }
    }

    /// Why no folder was made when the folder chosen to hold it is gone.
    static let parentMissingMessage = "The folder chosen to hold the feed's folder is no longer in the library. Choose another one."
    /// Why no folder was made when no name could be used.
    static let notMadeMessage = "TextMouth couldn't make a folder for this feed."
}
