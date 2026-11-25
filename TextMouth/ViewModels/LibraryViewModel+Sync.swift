import Foundation

// LibraryViewModel+Sync.swift: the library's side of syncing it between
// devices (FR43, sections 6 and 9 of the build plan). `LibraryViewModel` is
// the `SyncLibraryHost`: the sync engine hands it a merge, and it changes the
// rows, adds placeholders for the books another device has, removes the books
// a person removed elsewhere, and moves packages through
// `performLibraryTransition`. It shares the iPhone, which makes the same model.

// MARK: - Which Book a Key Belongs To

extension SyncKey {
    /// The book this key changes, or nil for a folder's or the reading list's option.
    var bookID: UUID? {
        switch self {
        case .book(let id, _): return id
        case .bookmark(let book, _): return book
        case .readingList(let book): return book
        case .folder, .readingListOption: return nil
        }
    }
}

// MARK: - The Merge of Rows

/// What a merge does to the library's rows, worked out from the library as it
/// was when the merge was made (`start`) and as it is now (`current`), which
/// can differ: a reader saves its place, a person edits a book, while the
/// placeholders of new books are written off the main thread. A row, the
/// folders, or the reading list changed meanwhile is left as the person made
/// it and its keys are not reported applied, so the next sync merges it again.
struct SyncRowMerge: Equatable {
    /// The library with the merge's rows, folders, list, and new books in.
    var library: Library
    /// The books whose rows the merge replaced.
    var changedBookIDs: Set<UUID> = []
    /// The books whose rows changed meanwhile, so the merge left them alone.
    var staleBookIDs: Set<UUID> = []
    /// The new books that joined the library.
    var addedBookIDs: Set<UUID> = []
    /// The new books the library refused, for a hash a book of this device has.
    var refusedBookIDs: Set<UUID> = []
    /// Whether the merge's folders replaced the library's.
    var foldersApplied = false
    /// Whether the merge's reading list replaced the library's.
    var readingListApplied = false
    /// Whether the folders or the reading list changed meanwhile, leaving them alone.
    var foldersAreStale = false
    var readingListIsStale = false

    /// Works the merge out, purely: no file is touched.
    /// - Parameters:
    ///   - application: The merge, made from `start`.
    ///   - start: The library when the merge was made.
    ///   - current: The library now.
    ///   - added: The new books, with their placeholders made.
    static func make(
        applying application: SyncApplication, start: Library, current: Library, added: [Book]
    ) -> SyncRowMerge {
        var result = SyncRowMerge(library: current)
        let startRows = Dictionary(start.books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var currentIndexes: [UUID: Int] = [:]
        for (index, book) in current.books.enumerated() where currentIndexes[book.id] == nil {
            currentIndexes[book.id] = index
        }
        for merged in application.library.books {
            guard let startRow = startRows[merged.id], merged != startRow else { continue }
            guard let index = currentIndexes[merged.id] else { continue }
            if current.books[index] == startRow {
                result.library.books[index] = merged
                result.changedBookIDs.insert(merged.id)
            } else {
                result.staleBookIDs.insert(merged.id)
            }
        }
        if application.library.folders != start.folders {
            if current.folders == start.folders {
                result.library.folders = application.library.folders
                result.foldersApplied = true
            } else {
                result.foldersAreStale = true
            }
        }
        if application.library.readingList != start.readingList {
            if current.readingList == start.readingList {
                result.library.readingList = application.library.readingList
                result.readingListApplied = true
            } else {
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

    /// The books whose package moves: a row now in another library folder
    /// than the library's was.
    func booksMoved(from current: Library) -> Set<UUID> {
        let before = Dictionary(current.books.map { ($0.id, $0.folderPath) }, uniquingKeysWith: { first, _ in first })
        return Set(library.books.filter { book in before[book.id].map { $0 != book.folderPath } ?? false }.map(\.id))
    }

    /// The keys of `application` still worth reporting applied: those of
    /// rows and lists left alone meanwhile, and of books the library refused,
    /// are taken out; `failed` are the books whose placeholders or removals
    /// did not work.
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

    /// Applies a merge to the library, on the main actor (plan, section 6):
    /// 1. makes a placeholder package for each new book, off the main thread;
    /// 2. replaces the rows, folders, and reading list the merge changed, but
    ///    only those not changed meanwhile (`SyncRowMerge`);
    /// 3. moves packages through `performLibraryTransition` when folders or
    ///    rows moved, or publishes the rows in place, and saves;
    /// 4. writes the merged records, which keep the merged place;
    /// 5. removes the books a person removed elsewhere, by the delete path
    ///    with this device's Trash setting, unasked (R7: only these).
    /// - Returns: The keys applied: those not left alone, refused, or failed.
    func applySync(_ application: SyncApplication) async -> Set<SyncKey> {
        guard maySyncNow else { return [] }
        let start = library

        // 1. The placeholders of new books, off the main thread. A book a
        // device lacks and cannot be made a package for stays out, its keys
        // unapplied.
        let storeID = Self.placeholderStoreID
        var failed: Set<UUID> = []
        var added: [Book] = []
        let known = Set(start.books.map(\.id))
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

        // 2. The rows, as the library is now.
        let merge = SyncRowMerge.make(applying: application, start: start, current: library, added: added)
        let moved = merge.booksMoved(from: library)

        // 3. Moves go through the transition, which keeps changes made
        // meanwhile; everything else is published in place.
        if application.movesPackages || !moved.isEmpty {
            do {
                try await performLibraryTransition(merge.library, affectedBookIDs: moved)
            } catch {
                // Nothing moved: the rows stay as they were, to be merged again.
                DiagnosticLog.event(.storage, "SYNC_MERGE: the merge's moves were refused (\(type(of: error)))") // l10n: no (debug log, English)
                return []
            }
        } else {
            library = merge.library
        }
        save()

        // 4. The records of the rows the merge changed or added carry the
        // merged place, whatever place the record already held.
        for id in merge.changedBookIDs.union(merge.addedBookIDs) {
            if let book = bookByID(id) {
                LibraryPersistenceService.saveBookInfo(for: book, asMerged: true)
            }
        }

        // 5. Removals: a book open in a reader waits for the next sync.
        for id in application.booksToRemove {
            guard let book = bookByID(id) else { continue }
            guard !openBookIDs.contains(id) else { failed.insert(id); continue }
            do {
                try FileImportService.deleteBookPackage(book)
                removeDeletedBook(book)
            } catch {
                failed.insert(id)
                DiagnosticLog.event(.storage, "SYNC_MERGE: book \(id.uuidString.prefix(8)) could not be removed (\(type(of: error)))") // l10n: no (debug log, English)
            }
        }
        if !application.booksToRemove.isEmpty { save() }

        return merge.appliedKeys(of: application, failed: failed)
    }

    /// The store the placeholders' pointers name. sync-store's `SyncCenter`
    /// does not publish the store's ID, so a placeholder names the nil UUID;
    /// the fetch reads the manifest the pointer names, not the store's ID.
    private static let placeholderStoreID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Called after each sync run with the books kept on all devices (section
    /// 16): this Mac keeps them downloaded as books kept on this Mac are,
    /// and, where the network allows (`mayDownload`: a path that is neither
    /// expensive nor constrained), downloads those evicted.
    func syncDidApply(keptBookIDs: Set<UUID>, mayDownload: Bool) {
        KeptBooks.shared.setSyncedBooks(keptBookIDs)
        guard mayDownload else { return }
        cloudCommands.downloadEvictedKeptBooks(in: self)
    }
}
