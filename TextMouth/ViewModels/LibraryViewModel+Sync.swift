import Combine
import Foundation

// LibraryViewModel+Sync.swift: the library's side of syncing it between
// devices (FR43, sections 6 and 9 of the build plan). `LibraryViewModel` is
// the `SyncLibraryHost`: the sync engine hands it a merge, and it changes the
// rows, adds placeholders for the books another device has, removes the books
// a person removed elsewhere, and moves packages through
// `performLibraryTransition`. It shares the iPhone, which makes the same model.

// MARK: - What a Merge Tells the Readers

/// The reading state a sync merge gave a book, which its open readers weigh
/// (`ReaderViewModel.takeSyncedReadingState(_:)`).
struct SyncedReadingState {
    /// The book.
    let bookID: UUID
    /// Its place, bookmarks, and settings as the merge made them.
    let state: Book.ReadingState
    /// The other device's name, for what is said: "iPhone".
    let device: String
}

// MARK: - The Merge of Rows

/// What a merge does to the library's rows, worked out field by field from the
/// library as it was when the merge was made (`start`), the merge's own
/// (`application.library`), and the library now (`current`), which can differ:
/// a reader saves its place, a person edits a book, a rename lands, while the
/// placeholders of new books are written off the main thread.
///
/// A field the merge changed is set in the row only when the row's is still
/// what it was at `start`, or is already the merge's; a field the person
/// changed meanwhile keeps their value. A row with any such field is `stale`:
/// its keys are not reported applied, and the next sync offers them again.
/// Fields are independent, so a row left alone in one field still follows a
/// folder's rename or a place saved elsewhere.
struct SyncRowMerge: Equatable {
    /// The library with the merge's fields, folders, list, and new books in.
    var library: Library
    /// The books whose rows the merge changed.
    var changedBookIDs: Set<UUID> = []
    /// The books with a field changed meanwhile, which the merge left alone.
    var staleBookIDs: Set<UUID> = []
    /// The new books that joined the library.
    var addedBookIDs: Set<UUID> = []
    /// The new books the library refused, for a hash a book of this device has.
    var refusedBookIDs: Set<UUID> = []
    /// Whether the merge's folders are in the library.
    var foldersApplied = false
    /// Whether the folders or the reading list changed meanwhile, leaving them alone.
    var foldersAreStale = false
    var readingListIsStale = false

    /// Works the merge out, purely: no file is touched.
    /// - Parameters:
    ///   - application: The merge, made from `start`.
    ///   - start: The library the merge was made from.
    ///   - current: The library now.
    ///   - added: The new books, with their placeholders made.
    static func make(
        applying application: SyncApplication, start: Library, current: Library, added: [Book]
    ) -> SyncRowMerge {
        var result = SyncRowMerge(library: current)
        let folderPaths = Set(current.folders.map(\.fullPath))
        let startRows = Dictionary(start.books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var currentIndexes: [UUID: Int] = [:]
        for (index, book) in current.books.enumerated() where currentIndexes[book.id] == nil {
            currentIndexes[book.id] = index
        }
        for merged in application.library.books {
            guard let startRow = startRows[merged.id], let index = currentIndexes[merged.id], merged != startRow else { continue }
            var row = current.books[index]
            let outcome = mergeFields(from: startRow, merged: merged, into: &row, folderPaths: folderPaths)
            if outcome.changed {
                result.library.books[index] = row
                result.changedBookIDs.insert(merged.id)
            }
            if outcome.stale { result.staleBookIDs.insert(merged.id) }
        }
        // The folders and the list: the merge's when the library's are as they
        // were, or already the merge's; a person's change meanwhile stands.
        if application.library.folders != start.folders {
            if current.folders == start.folders {
                result.library.folders = application.library.folders
                result.foldersApplied = true
            } else if current.folders == application.library.folders {
                result.foldersApplied = true
            } else {
                result.foldersAreStale = true
            }
        }
        if application.library.readingList != start.readingList {
            if current.readingList == start.readingList {
                result.library.readingList = application.library.readingList
            } else if current.readingList != application.library.readingList {
                result.readingListIsStale = true
            }
        }
        for book in added {
            let before = result.library.books.count
            result.library.addBook(book)
            if result.library.books.count > before {
                result.addedBookIDs.insert(book.id)
            } else {
                result.refusedBookIDs.insert(book.id)
            }
        }
        return result
    }

    /// Sets into `row` each field `merged` changed from `start`, when `row`'s
    /// is still `start`'s (or already the merge's). Returns whether any field
    /// was set, and whether any was left alone because it changed meanwhile.
    private static func mergeFields(from start: Book, merged: Book, into row: inout Book, folderPaths: Set<String>) -> (changed: Bool, stale: Bool) {
        var changed = false, stale = false
        for field in SyncBookValues.rowFields {
            guard let before = SyncBookValues.value(of: field, in: start),
                  let after = SyncBookValues.value(of: field, in: merged), after != before else { continue }
            let now = SyncBookValues.value(of: field, in: row)
            if now == after { continue }
            if now == before, SyncBookValues.set(field, to: after, in: &row) {
                changed = true
                if let detail = SyncBookValues.metadataField(of: field), merged.handEdits?.contains(detail) == true {
                    row.markEditedByHand([detail])
                }
            } else {
                stale = true
            }
        }
        // The folder, so a rename that moved the merged row still moves this one.
        if merged.folderPath != start.folderPath, row.folderPath != merged.folderPath {
            if row.folderPath == start.folderPath, merged.folderPath.isEmpty || folderPaths.contains(merged.folderPath) {
                row.folderPath = merged.folderPath
                changed = true
            } else {
                stale = true
            }
        }
        // The bookmarks, one by one: the merge's additions, removals, and
        // changes, each only where this row's bookmark is as it was.
        if merged.bookmarks != start.bookmarks {
            var bookmarks = row.bookmarks
            let startByID = Dictionary(start.bookmarks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let mergedByID = Dictionary(merged.bookmarks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (id, mark) in mergedByID where startByID[id] != mark {
                if let place = bookmarks.firstIndex(where: { $0.id == id }) {
                    if bookmarks[place] == startByID[id] { bookmarks[place] = mark } else if bookmarks[place] != mark { stale = true }
                } else if startByID[id] == nil {
                    bookmarks.append(mark)
                }
            }
            for (id, mark) in startByID where mergedByID[id] == nil {
                if let place = bookmarks.firstIndex(where: { $0.id == id }) {
                    if bookmarks[place] == mark { bookmarks.remove(at: place) } else { stale = true }
                }
            }
            if bookmarks != row.bookmarks {
                bookmarks.sort { ($0.dateCreated, $0.id.uuidString) < ($1.dateCreated, $1.id.uuidString) }
                for number in bookmarks.indices { bookmarks[number].number = number + 1 }
                row.bookmarks = bookmarks
                changed = true
            }
        }
        return (changed, stale)
    }

    /// The keys of `application` still worth reporting applied: those of
    /// rows left alone, of folders or the list changed meanwhile, and of
    /// books the library refused are taken out; `failed` are the books whose
    /// placeholders or removals did not happen.
    func appliedKeys(of application: SyncApplication, failed: Set<UUID>) -> Set<SyncKey> {
        let skipped = staleBookIDs.union(refusedBookIDs).union(failed)
        return application.appliedKeys.filter { key in
            if let book = key.bookID, skipped.contains(book) { return false }
            switch key {
            case .folder: return !foldersAreStale
            case .readingList, .readingListOption: return !readingListIsStale
            default: return true
            }
        }
    }
}

// MARK: - The Host

extension LibraryViewModel: SyncLibraryHost {
    /// Whether a sync may change the library now: not while an operation
    /// holds the storage work, the library is unavailable, its index is
    /// being recovered, or its data directory is moving.
    var maySyncNow: Bool {
        StorageBoundary.shared.heldFor == nil
            && dataDirectoryUnavailability == nil
            && indexRecovery == nil
            && dataDirectoryMove == nil
    }

    /// The subscriptions the sync records and merges (FR56): the feed engine's,
    /// once its records have loaded, and nil before.
    var syncFeeds: [Feed]? {
        feeds.syncFeeds
    }

    /// Tells the sync when a feed's synced values change (FR56), as the
    /// library's `didSet` does for its own: a subscription added or deleted, or
    /// a setting a person changed. A refresh changes none of those values, so it
    /// records nothing and schedules no sync. Followed from when the feed engine
    /// starts with this library.
    func followFeedsForSync() {
        feeds.store.$records
            .map { records in SyncFeedValues.values(of: Array(records.values.map(\.feed))) }
            .removeDuplicates()
            .dropFirst()
            .sink { _ in SyncCenter.shared.libraryDidChange() }
            .store(in: &cancellables)
    }

    /// Applies a merge made from the library as it is now.
    func applySync(_ application: SyncApplication) async -> Set<SyncKey> {
        await applySync(application, from: library)
    }

    /// The identifiers of the voices installed on this Mac, once they are
    /// listed, so a merge applies no voice this Mac lacks; nil before that,
    /// which offers every voice.
    var availableVoiceIDs: Set<String>? {
        VoiceCatalog.shared.isLoaded ? Set(VoiceCatalog.shared.voices.map(\.identifier)) : nil
    }

    /// Whether the book `id` is busy now, so a removal waits: open in a
    /// reader (the synchronous truth, not the published set that follows a
    /// turn later), its audio being edited, being edited with Edit Text, in
    /// use by a feed rule, being exported or transcribed, being fetched, or
    /// having its download taken off this device (`booksBeingFreed`).
    func isBookBusyForSync(_ id: UUID) -> Bool {
        if isBookOpenNow(id) || audioEditActivity.isInUse(id) || feedBooksInUse.contains(id) { return true }
        if booksBeingFreed.contains(id) { return true }
        if case .downloading? = BookCloudStates.shared.state(of: id) { return true }
        return false
    }

    /// Applies a merge to the library, on the main actor (plan, section 6),
    /// against `source`, the library the merge was made from:
    /// 1. makes a placeholder package for each new book, off the main thread;
    /// 2. changes the folders and moves packages first, through
    ///    `performLibraryTransition`, which keeps what the library changes
    ///    meanwhile but rebuilds the rest from the library as it then is;
    /// 3. then sets each field the merge changed, field by field, onto the
    ///    library the move published, only where the person has not changed
    ///    it since `source` (`SyncRowMerge`), and adds the new books;
    /// 4. writes the merged records, which keep the merged place;
    /// 5. removes the books a person removed elsewhere, by the delete path
    ///    with this device's Trash setting, unasked (R7: only these), but not
    ///    a book that is busy or has changed since `source`.
    /// - Returns: Only the keys that landed.
    func applySync(_ application: SyncApplication, from source: Library) async -> Set<SyncKey> {
        guard maySyncNow else { return [] }
        let start = source

        // 1. The placeholders of new books, off the main thread. A book a
        // device lacks and cannot be made a package for stays out, its keys
        // unapplied.
        let storeID = SyncCenter.shared.storeID ?? Self.placeholderStoreID
        var failed: Set<UUID> = []
        var added: [Book] = []
        let known = Set(library.books.map(\.id))
        for newBook in application.booksToAdd where !known.contains(newBook.book.id) {
            do {
                added.append(try await OffMainWork.runThrowing {
                    try SyncPlaceholder.makePackage(for: newBook, storeID: storeID)
                })
            } catch {
                failed.insert(newBook.book.id)
                DiagnosticLog.event(.storage, "SYNC_MERGE: a placeholder for book \(newBook.book.id.uuidString.prefix(8)) could not be made (\(type(of: error)))") // l10n: no (debug log, English)
            }
        }
        guard maySyncNow else { return [] }

        // 2. The folders and the moves, as the library is now.
        guard await applyFolderChanges(of: application, start: start) else { return [] }
        guard maySyncNow else { return [] }

        // 3. The fields, onto the library as the move left it.
        let merge = SyncRowMerge.make(applying: application, start: start, current: library, added: added)
        if merge.library != library { library = merge.library }
        save()

        // 4. The records of the rows the merge changed or added carry the
        // merged place, whatever place the record already held.
        for id in merge.changedBookIDs.union(merge.addedBookIDs) {
            if let book = bookByID(id) {
                LibraryPersistenceService.saveBookInfo(for: book, asMerged: true)
            }
        }

        // The readers of the books whose place changed hear of it, after the
        // records are queued, so a reader at rest moves to it.
        let startRows = Dictionary(start.books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in merge.changedBookIDs where isBookOpenNow(id) {
            guard let row = bookByID(id), let before = startRows[id],
                  row.readingState != before.readingState else { continue }
            syncedReadingStates.send(SyncedReadingState(bookID: id, state: row.readingState, device: syncDeviceName(.book(id, .position)) ?? Self.otherDeviceName()))
        }

        // 5. Removals: a busy book, or one changed since the merge was made,
        // waits for a later sync.
        for id in application.booksToRemove {
            guard let book = bookByID(id) else { continue }
            guard !isBookBusyForSync(id), startRows[id].map({ $0 == book }) ?? true else { failed.insert(id); continue }
            // The way a person's removal goes, for each kind of book: a feed
            // item's is its Delete Download, and the feed's own state agrees.
            if !removeBooksAndDeleteReturningOutcome([book]).succeeded {
                failed.insert(id)
                DiagnosticLog.event(.storage, "SYNC_MERGE: book \(id.uuidString.prefix(8)) could not be removed") // l10n: no (debug log, English)
            }
        }
        if !application.booksToRemove.isEmpty { save() }

        // 6. The feeds (FR56), once the folders they list in are in place. A
        // feed whose change did not land keeps its keys for a later sync.
        let applied = merge.appliedKeys(of: application, failed: failed)
        guard !application.feeds.isEmpty else { return applied }
        let (landing, waiting) = Self.feedsWithTheirFolders(application, in: library)
        let failedFeeds = await feeds.applySync(landing).union(waiting)
        return applied.filter { key in key.feedID.map { !failedFeeds.contains($0) } ?? true }
    }

    /// What `application` does to the feeds, less the feeds it adds to, or moves into, a folder
    /// the merge makes that `library` lacks: the folders changed meanwhile, so the merge's were
    /// left out (`SyncRowMerge.foldersAreStale`), and such a feed waits for them, its keys
    /// unapplied, rather than listing in no folder. Returns the rest, and the IDs that wait.
    static func feedsWithTheirFolders(
        _ application: SyncApplication, in library: Library
    ) -> (landing: SyncFeedApplication, waiting: Set<UUID>) {
        let missing = Set(application.library.folders.map(\.id)).subtracting(library.folders.map(\.id))
        var landing = application.feeds
        guard !missing.isEmpty else { return (landing, []) }
        var waiting = Set<UUID>()
        // A change waits only when it moves the feed into such a folder.
        let movesIntoMissing = { (feed: Feed) in
            missing.contains(feed.folderID) && application.feeds.startFeeds[feed.id]?.folderID != feed.folderID
        }
        landing.feedsToAdd.removeAll { feed in missing.contains(feed.folderID) && waiting.insert(feed.id).inserted }
        landing.feedsToChange.removeAll { feed in movesIntoMissing(feed) && waiting.insert(feed.id).inserted }
        return (landing, waiting)
    }

    /// Changes the folders and moves the packages the merge says, through
    /// the library transition: the merge's folders when the library's are
    /// still `start`'s, and each book whose row is still where `start` had it
    /// moved to where the merge puts it. Returns false, changing nothing,
    /// when the transition refuses, so the whole merge waits.
    private func applyFolderChanges(of application: SyncApplication, start: Library) async -> Bool {
        var proposed = library
        if library.folders == start.folders { proposed.folders = application.library.folders }
        let mergedFolderPaths = Dictionary(
            application.library.folders.map { ($0.fullPath, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let startRows = Dictionary(start.books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var moved: Set<UUID> = []
        for merged in application.library.books {
            guard let before = startRows[merged.id], merged.folderPath != before.folderPath,
                  let index = proposed.books.firstIndex(where: { $0.id == merged.id }),
                  proposed.books[index].folderPath == before.folderPath else { continue }
            // The folders it moves into, and the ones above them, are in the
            // list, though the person changed folders meanwhile: a row never
            // lands in a folder the library does not hold.
            let held = Set(proposed.folders.map(\.fullPath))
            var needed: [String] = []
            var path = merged.folderPath
            while !path.isEmpty, !held.contains(path) {
                needed.append(path)
                path = (path as NSString).deletingLastPathComponent
            }
            guard needed.allSatisfy({ mergedFolderPaths[$0] != nil }) else { continue }
            proposed.folders.append(contentsOf: needed.reversed().compactMap { mergedFolderPaths[$0] })
            proposed.books[index].folderPath = merged.folderPath
            moved.insert(merged.id)
        }
        guard proposed != library else { return true }
        do {
            try await performLibraryTransition(proposed, affectedBookIDs: moved)
            return true
        } catch {
            // Nothing moved: the rows stay as they were, to be merged again.
            DiagnosticLog.event(.storage, "SYNC_MERGE: the merge's moves were refused (\(type(of: error)))") // l10n: no (debug log, English)
            return false
        }
    }

    /// Tells the cloud notes whether sync is on, now and whenever the sync's
    /// status changes, so a library with a sync folder shows In Cloud for the
    /// books it has not fetched (FR43).
    func observeSyncStatus() {
        syncStatusSubscription = SyncCenter.shared.$status
            .map(\.isOn)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { isOn in BookCloudStates.shared.setSyncIsOn(isOn) }
        // The books kept on all devices follow the sync's registers at once,
        // so a checkbox just changed shows it before the next run ends.
        syncKeptSubscription = SyncCenter.shared.$keptBookIDs
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { KeptBooks.shared.setSyncedBooks($0) }
    }

    /// The name of the device whose changes arrived last, from the sync's
    /// status, or the other platform's name where none has been heard from.
    private static func otherDeviceName() -> String {
        let heard = SyncCenter.shared.status.lastHeard
        return heard.max { $0.value < $1.value }?.key ?? "iPhone" // l10n: no (a product name)
    }

    /// The store a placeholder's pointer names when the sync has none (only
    /// in tests): the nil UUID. The fetch reads the manifest the pointer names.
    private static let placeholderStoreID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Called after each sync run with the books kept on all devices (section
    /// 16): this Mac keeps them downloaded as books kept on this Mac are,
    /// and, where the network allows (`mayDownload`: a path that is neither
    /// expensive nor constrained), downloads those evicted.
    ///
    /// `mayDownload` is the network check of the kept books' downloads in a
    /// synced library: `downloadEvictedKeptBooks` downloads there only when
    /// called from here (`afterSync`), and the cloud refresher's own call
    /// leaves such a library alone.
    ///
    /// Each placeholder's state is recorded as In Cloud first, so the rows
    /// say so and the kept books' downloads find them: the cloud refresher
    /// runs only while a Mac Library window is open, so a sync does this
    /// itself (section 16).
    func syncDidApply(keptBookIDs: Set<UUID>, mayDownload: Bool) {
        KeptBooks.shared.setSyncedBooks(keptBookIDs)
        let books = library.books
        Task { @MainActor in
            // Looking for pointers is file work, so it is off the main thread.
            let placeholders = await OffMainWork.run {
                books.filter {
                    SyncPlaceholder.isPlaceholder(package: $0.tmbDirectory, contentFile: $0.bookFileURL)
                }.map(\.id)
            }
            Self.recordInCloud(placeholders)
            if mayDownload {
                cloudCommands.downloadEvictedKeptBooks(in: self, afterSync: true)
                // Under "All books" every book this device lacks downloads, never removing one (FR45).
                cloudCommands.downloadMissingBooks(in: self)
            }
            // Under "Books you open or keep" a book unopened for the days goes, on any connection.
            await removeUnopenedDownloads(mayDownload: mayDownload)
        }
    }

    /// Removes the downloads of books unopened for this device's days (FR45), after a sync, and tells the sync's
    /// status how many it had to leave. The first look at a device whose removal applies by default (the iPhone's
    /// 7 days) only notes the date, so the days count from it and nothing goes at once.
    func removeUnopenedDownloads(mayDownload: Bool, settings: SyncSpaceSettings = .shared) async {
        guard SyncActivity.isOn else { return }
        settings.beginRemovalsIfNeeded()
        let report = await cloudCommands.removeUnopenedDownloads(
            of: library.books, in: self, settings: settings.settings, mayDownload: mayDownload
        ) { [weak self] in self?.isProtectedFromUnopenedRemoval($0) ?? true }
        SyncCenter.shared.noteSpace(removalsWaiting: report.waiting)
    }

    /// Whether a book is never taken off this device for being unopened: kept (by the person, the reading list,
    /// or on all devices), on the reading list, open now, being played, exported, transcribed, edited, or
    /// downloaded, or a feed's item, whose feed holds its download.
    func isProtectedFromUnopenedRemoval(_ book: Book) -> Bool {
        isBookBusyForSync(book.id)
            || cloudCommands.kept.isKept(book.id)
            || library.readingList.contains(book.id)
            || cloudCommands.booksDownloading.contains(book.id)
            || book.feedLink != nil
    }

    /// Called after a placeholder's files were fetched: the content keeps the
    /// name it had where it was backed up, so the row's file path is set to
    /// it in the book's package when that differs, and the row is saved.
    /// Nothing changes for a book that is gone, a manifest naming no content
    /// file, or a path already right.
    func syncDidFetch(bookID: UUID, contentPath: String?) {
        guard let contentPath, let book = bookByID(bookID) else { return }
        let path = book.tmbDirectory.appendingPathComponent(contentPath).path
        guard book.filePath != path else { return }
        updateBook(id: bookID) { $0.filePath = path }
    }

    /// Records the books `ids`, placeholders, as In Cloud in the shared
    /// states, but never over a download under way, which owns its book's state.
    static func recordInCloud(_ ids: [UUID], in states: BookCloudStates = .shared) {
        for id in ids {
            if case .downloading? = states.state(of: id) { continue }
            states.record(.inCloud, for: id)
        }
    }
}
