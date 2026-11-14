import SwiftUI

/// Extension for individual book CRUD operations — marking opened, removing,
/// moving, updating metadata, reading position, voice settings, and word counts.
extension LibraryViewModel {

    // MARK: - Book Lifecycle

    func markBookOpened(_ bookID: UUID) {
        updateBook(id: bookID) { $0.lastOpened = Date() }
    }

    /// Request removal of a single book — shows confirmation if enabled
    func removeBook(_ book: Book) {
        removeBooks([book])
    }

    /// Request removal of one or more books — shows confirmation if enabled.
    /// Without one, a removal of feed items alone says at once what it did
    /// and kept, no dialog closing over the words.
    func removeBooks(_ books: [Book]) {
        guard !books.isEmpty else { return }
        if configService.config.confirmBeforeDelete {
            pendingRemoveBooks = books
            showRemoveBookDialog = true
        } else if let report = performRemoveBooks(books, deleteTMB: true) {
            // Default: remove from library and delete .tmb
            VoiceOverAnnouncer.announce(report)
        }
    }

    /// Remove books from the library index only, keeping each .tmb package
    /// and its content file on disk for a later re-import (TODO S06). Each
    /// package is retired before its row is removed
    /// (`LibraryPersistenceService.retirePackage(of:)`): its removal marker
    /// keeps orphan adoption from bringing the book back after a restart or
    /// a rebuild, and metadata writes still queued or in flight for it are
    /// dropped. A book whose package cannot be marked stays in the library,
    /// and a bookInfo.json that cannot be deleted does not undo the removal;
    /// either problem is reported through the library's error alert.
    func removeBooksFromLibraryOnly(_ books: [Book]) {
        var refused: [String] = []
        var recordsLeft: [String] = []
        var removedAny = false
        for requested in books {
            // The confirmation captured these books when it opened. Act on
            // the current row, so a book moved meanwhile is marked where its
            // package is now; a book no longer listed needs nothing.
            guard let book = bookByID(requested.id) else { continue }
            // A feed item stays in its feed while its file is here, and
            // retiring its package would delete its record, with its place
            // and bookmarks (FR11, branch A2): Delete Download removes it.
            guard !book.isFeedItem else {
                refused.append("\(book.title): \(FeedItemPackageError.staysInItsFeed.localizedDescription)")
                continue
            }
            do {
                let retirement = try LibraryPersistenceService.retirePackage(of: book)
                if let error = retirement.recordDeletionError {
                    recordsLeft.append("\(book.title): \(error.localizedDescription)")
                }
            } catch {
                refused.append("\(book.title): \(error.localizedDescription)")
                continue
            }
            library.removeBook(id: book.id)
            removedAny = true
        }
        if removedAny {
            save()
        }
        if let message = Self.libraryOnlyRemovalProblems(refused: refused, recordsLeft: recordsLeft) {
            errorMessage = message
            showError = true
        }
    }

    /// What Remove from Library Only could not do, as the error alert says
    /// it, or nil when it did everything. `refused` lists the books kept in
    /// the library because their package could not be marked; `recordsLeft`
    /// lists removed books whose bookInfo.json could not be deleted. Each
    /// entry reads "Title: reason".
    nonisolated static func libraryOnlyRemovalProblems(refused: [String], recordsLeft: [String]) -> String? {
        var paragraphs: [String] = []
        if !refused.isEmpty {
            let heading = refused.count == 1
                ? "This book could not be removed from the library and remains in it:"
                : "These books could not be removed from the library and remain in it:"
            paragraphs.append(([heading] + refused).joined(separator: "\n"))
        }
        if !recordsLeft.isEmpty {
            let heading = recordsLeft.count == 1
                ? "This book was removed from the library, but its bookInfo.json file could not be deleted. "
                    + "It will still stay out of the library:"
                : "These books were removed from the library, but their bookInfo.json files could not be deleted. "
                    + "They will still stay out of the library:"
            paragraphs.append(([heading] + recordsLeft).joined(separator: "\n"))
        }
        return paragraphs.isEmpty ? nil : paragraphs.joined(separator: "\n\n")
    }

    /// Remove books from the library and delete their .tmb packages, to the
    /// Trash or permanently as the preference chooses. Books whose packages
    /// cannot be deleted stay, and the error alert names them in the words
    /// of that mode.
    /// - Returns: For feed items alone, their Delete Download, what it did
    ///   and kept, which the Remove question's owner says once the question
    ///   has closed, so its closing never cuts the words off (REV11 F6); nil
    ///   otherwise.
    @discardableResult
    func removeBooksAndDelete(_ books: [Book]) -> String? {
        performRemoveBooks(books, deleteTMB: true)
    }

    /// Remove & Delete for a workflow that reports the result where it was
    /// started, such as the Duplicate Finder; presents nothing (TODO A08).
    /// Returns the mode's completion message, such as "Moved 2 books to the
    /// Trash.", or, when some books stayed, what was removed followed by
    /// which books stayed and why.
    func removeBooksAndDeleteReturningOutcome(
        _ books: [Book],
        deletePackage: ((Book) throws -> Void)? = nil
    ) -> OperationOutcome {
        removeBooksReturningOutcome(books, deletingPackages: true, deletePackage: deletePackage)
    }

    /// Internal helper to remove books with optional .tmb deletion. Books
    /// that stay are named through the library's error alert.
    /// - Returns: For a removal of feed items alone, their Delete Download
    ///   (FR11), what it did and what it kept, for the caller to say through
    ///   VoiceOver, as the feed's own Delete Download says what it did, since
    ///   the row that leaves becomes an item's row saying "Not Downloaded":
    ///   at once, or once the Remove question has closed (REV11 F6); nil for
    ///   any other removal, which the rows' leaving says.
    @discardableResult
    func performRemoveBooks(
        _ books: [Book],
        deleteTMB: Bool,
        deletePackage: ((Book) throws -> Void)? = nil
    ) -> String? {
        let outcome = removeBooksReturningOutcome(
            books,
            deletingPackages: deleteTMB,
            deletePackage: deletePackage
        )
        presentFailure(of: outcome)
        guard outcome.succeeded, deleteTMB, !books.isEmpty, books.allSatisfy(\.isFeedItem) else { return nil }
        return outcome.message
    }

    /// Removes `books` from the library. With `deletingPackages`, each
    /// package is deleted first, through the Trash-aware path unless a test
    /// injects `deletePackage`, and a book whose package cannot be deleted
    /// stays. Returns the outcome in the words of the deleting mode in force.
    ///
    /// Each book is removed as the library holds it now, found by its ID: a
    /// confirmation or a sheet may have captured it before a data-directory
    /// move published, or before another change, and its package is where
    /// the library says now (TODO S04). A book no longer listed needs
    /// nothing. Removals run on the main actor, as a move's copy and
    /// publication do, so the two never interleave.
    private func removeBooksReturningOutcome(
        _ books: [Book],
        deletingPackages: Bool,
        deletePackage: ((Book) throws -> Void)?
    ) -> OperationOutcome {
        let deletePackage = deletePackage ?? { book in
            try FileImportService.deleteBookPackage(book)
        }
        var removed: [Book] = []
        var failures: [String] = []
        for book in books.compactMap({ bookByID($0.id) }) {
            // A feed item's Remove is its Delete Download (FR11, branch A2):
            // its file goes, and its package stays while it holds the
            // listener's place, bookmarks, settings, or transcript.
            if book.isFeedItem {
                do {
                    try feeds.deleteDownload(ofBook: book, in: self)
                    removed.append(book)
                } catch {
                    failures.append("\(book.title): \(error.localizedDescription)")
                }
                continue
            }
            if deletingPackages {
                do {
                    try deletePackage(book)
                } catch {
                    failures.append("\(book.title): \(error.localizedDescription)")
                    continue
                }
                removeDeletedBook(book)
            } else {
                library.removeBook(id: book.id)
            }
            removed.append(book)
        }
        save()
        guard deletingPackages else { return .success(nil) }

        let mode = removalPreferences.deletionMode
        // What each removed download whose package stayed still holds, read
        // from its row on its feed's shelf and its package, so the report
        // names only that.
        let removedIDs = Set(removed.map(\.id))
        let kept = Dictionary(
            library.feedShelf.rows.filter { removedIDs.contains($0.id) }.map { row in
                (row.id, FeedWording.KeptParts.of(row, package: row.tmbDirectory))
            },
            uniquingKeysWith: { first, _ in first }
        )
        let completion = Self.removalCompletion(removed, mode: mode, kept: kept)
        guard !failures.isEmpty else { return .success(completion) }
        let report = [completion, mode.failureMessage(failures)].compactMap { $0 }
        return .failure(report.joined(separator: "\n\n"))
    }

    /// The report of a removal that deleted `removed` in `mode`, or nil when
    /// it removed nothing: the books of the library's own as having gone,
    /// and the feed items, whose Remove is Delete Download (FR11), as having
    /// lost only their downloads, saying of those in `kept`, the rows kept
    /// on their feeds' shelves, what each package still holds and nothing
    /// more: "Moved “Notes” to the Trash. Moved the download of “Ep. 368” to
    /// the Trash. Its place and bookmarks are kept."
    nonisolated static func removalCompletion(_ removed: [Book], mode: RemovalMode, kept: [UUID: FeedWording.KeptParts]) -> String? {
        let books = removed.filter { !$0.isFeedItem }
        let downloads = removed.filter(\.isFeedItem)
        let sentences = [
            books.isEmpty ? nil : RemovalWording(mode, books: books).completionMessage,
            downloads.isEmpty ? nil : FeedDownloadRemovalWording(mode, items: downloads)
                .completionMessage(kept: downloads.compactMap { kept[$0.id] }),
        ].compactMap { $0 }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// Takes `book`, whose package was just deleted, out of the library
    /// model and out of the persistence queue: no write queued for it may
    /// chase the deleted package, and a failed write of its record no
    /// longer counts as unsaved (TODO S09). The reading text this Mac kept
    /// for it goes too (`ReadingTextCache`). Every removal that deletes a
    /// package ends here.
    func removeDeletedBook(_ book: Book) {
        library.removeBook(id: book.id)
        LibraryPersistenceService.forgetDeletedBook(book)
        ReadingTextCache.shared.remove(bookID: book.id)
    }

    // MARK: - Moving Books

    /// Moves `book` to the folder at `path`, as `moveBooks(_:toFolder:)` does.
    @discardableResult
    func moveBook(_ book: Book, toFolder path: String) -> Task<Void, Never> {
        moveBooks([book], toFolder: path)
    }

    /// Move one or more books to the specified folder path. A failure is
    /// explained through the library's error alert, and the feed items left
    /// where they are are named through VoiceOver at once, no sheet closing
    /// over the words. Returns the task doing the work, whose packages move
    /// off the main actor (PERF14); callers need not wait for it.
    @discardableResult
    func moveBooks(_ books: [Book], toFolder path: String) -> Task<Void, Never> {
        Task {
            let outcome = await moveBooksReturningOutcome(books, toFolder: path)
            presentFailure(of: outcome)
            if outcome.succeeded, let note = outcome.message {
                VoiceOverAnnouncer.announce(note)
            }
        }
    }

    /// Moves books to the folder at `path` and returns what happened,
    /// presenting nothing, so the move sheet can stay open with the reason
    /// after a failure (TODO A07). A failed move puts back any package that
    /// already moved and leaves the library as it was. The packages move off
    /// the main actor (`performLibraryTransition`, PERF14).
    ///
    /// A feed item among `books` stays where it is, in its feed's folder
    /// (FR11), and the success's message names the items left
    /// (`LibraryTransitionWording.feedItemsLeft(titles:)`), for the caller
    /// to say: the Move sheet's owner once the sheet has closed, so its
    /// closing never cuts the words off (REV11 F6), and so a mixed
    /// selection's move never closes as if every item had moved.
    func moveBooksReturningOutcome(_ books: [Book], toFolder path: String) async -> OperationOutcome {
        let left = books.filter(\.isFeedItem)
        var proposed = library
        let ids = Set(books.filter { !$0.isFeedItem }.map(\.id))
        for index in proposed.books.indices where ids.contains(proposed.books[index].id) {
            proposed.books[index].folderPath = path
        }
        do {
            if !ids.isEmpty {
                try await performLibraryTransition(proposed, affectedBookIDs: ids)
                lastMovedFolderPath = path
            }
            return .success(LibraryTransitionWording.feedItemsLeft(titles: left.map(\.title)))
        } catch {
            return .failure("Could not move books", error)
        }
    }

    // MARK: - Library Transitions

    /// Move every changed package, persist its new metadata, and then commit the
    /// proposed library model. Completed disk moves are reversed on any failure.
    /// A book whose old and new folders name the same directory under
    /// `equivalence` (a case- or normalization-only respelling) stays where it
    /// is; only its recorded path and package record change.
    ///
    /// A move that writes a book's record has saved the book's current state,
    /// so it settles any earlier failed write of the book. Undoing a failed
    /// transition is never silent: what cannot be put back is reported to the
    /// failure center (`LibraryTransitionDiskWork`). `disk` makes the moves
    /// and writes; tests replace it to make one of them fail.
    ///
    /// Readers with a moving book open hear of the move before any package
    /// moves, and that it ended once the library holds the books' new rows,
    /// or once a failed transition has been put back (TODO P10).
    ///
    /// Everything here runs on the main actor, so it suits a transition
    /// small enough to finish at once, such as putting a ZIP archive's books
    /// into a folder of their own. The folder edits started from the
    /// library's sheets, which can move hundreds of packages, use
    /// `performLibraryTransition`, which moves them off the main actor.
    func commitLibraryTransition(
        _ proposedLibrary: Library,
        affectedBookIDs: Set<UUID>,
        equivalence: FolderPathEquivalence = .library,
        disk: LibraryTransitionDisk = .system
    ) throws {
        let plan = try planLibraryTransition(proposedLibrary, affectedBookIDs: affectedBookIDs, equivalence: equivalence)
        bookUpdates.packagesWillMove(plan.movingBookIDs)
        defer { bookUpdates.packagesDidMove(plan.movingBookIDs) }
        try LibraryTransitionDiskWork.perform(plan, disk: disk, restoringThrough: self)
        publish(plan)
    }

    /// The transition `commitLibraryTransition` makes, with its disk work off
    /// the main actor (PERF14): moving each package and rewriting its record,
    /// which for a folder of hundreds of books takes the better part of a
    /// second that VoiceOver would otherwise spend waiting for the app. The
    /// library publishes the new rows once that work is done, with a
    /// VoiceOver announcement of how many books moved.
    ///
    /// It runs as held storage work, as Rebuild Directory does: imports,
    /// text extractions, and analyses started meanwhile wait until it is
    /// done, so none writes into a package as it moves; those already under
    /// way finish first, VoiceOver hearing what it waits for; and the saves
    /// already queued are written before anything moves. Throws
    /// `StorageBusyError` while another operation holds the storage work,
    /// saying which (#673): a data-directory move, Rebuild Directory, or
    /// another folder edit. A transition that moves no package and rewrites
    /// no record, as for an empty folder, only makes folders, at once, and
    /// holds nothing.
    ///
    /// The library can change while the packages move, as when a reader saves
    /// its position or another window edits a book. Such changes are kept
    /// (`library(after:current:)`), and a moved book whose row changed has its
    /// record saved again at its new place, as one whose row changed while a
    /// failed transition was put back has at its old one.
    ///
    /// `beforeMovingPackages` runs on the main actor before anything moves:
    /// once the storage work is held and the work already under way has
    /// finished, or at once for a transition that moves no package. A
    /// folder's case-only rename renames its directory there, telling the
    /// readers of the books inside first, so that no reader waits on other
    /// storage work to read its book (TODO P10). Should it throw, nothing
    /// moves, and the error is thrown.
    func performLibraryTransition(
        _ proposedLibrary: Library,
        affectedBookIDs: Set<UUID>,
        equivalence: FolderPathEquivalence = .library,
        disk: LibraryTransitionDisk = .system,
        beforeMovingPackages: () throws -> Void = {}
    ) async throws {
        let plan = try planLibraryTransition(proposedLibrary, affectedBookIDs: affectedBookIDs, equivalence: equivalence)
        guard !plan.moves.isEmpty else {
            // No package moves and no record is rewritten, as for an empty
            // folder: only folders are made, at once, which no storage work
            // can be in the way of.
            try beforeMovingPackages()
            try LibraryTransitionDiskWork.perform(plan, disk: disk, restoringThrough: self)
            publish(plan)
            return
        }
        let hold = try StorageBoundary.shared.holdWork(for: .movingBooksBetweenFolders)
        defer { hold.release() }
        await hold.waitForWorkUnderWay { work in
            VoiceOverAnnouncer.announce(work.waitingMessage)
        }
        LibraryPersistenceService.flushPendingSave()
        try beforeMovingPackages()

        bookUpdates.packagesWillMove(plan.movingBookIDs)
        defer { bookUpdates.packagesDidMove(plan.movingBookIDs) }
        do {
            try await OffMainWork.runThrowing { [weak self] in
                try LibraryTransitionDiskWork.perform(plan, disk: disk, restoringThrough: self)
            }
        } catch {
            saveRowsChanged(during: plan)
            throw error
        }
        if let announcement = LibraryTransitionWording.completion(movingPackagesOf: plan.movingBookIDs.count) {
            VoiceOverAnnouncer.announce(announcement)
        }
        publish(plan)
    }

    /// Plans the transition to `proposedLibrary`: checks the paths it
    /// introduces, and works out where each affected book's package goes and
    /// whether it moves on disk, without changing anything. Throws for a
    /// destination folder path the library refuses.
    private func planLibraryTransition(
        _ proposedLibrary: Library,
        affectedBookIDs: Set<UUID>,
        equivalence: FolderPathEquivalence
    ) throws -> LibraryTransitionPlan {
        var proposed = proposedLibrary
        let existingPaths = Set(library.folders.map(\.fullPath))
        let changedFolders = proposed.folders.filter { !existingPaths.contains($0.fullPath) }
        guard changedFolders.allSatisfy({ BookFolder.isValidLibraryPath($0.fullPath) }),
              proposed.books.filter({ affectedBookIDs.contains($0.id) })
                .allSatisfy({ BookFolder.isValidLibraryPath($0.folderPath) }) else {
            throw FileImportError.importFailed("A destination folder path is invalid.")
        }
        // Each book is found by ID once, not by a search per affected book,
        // which for a folder of hundreds of books took a tenth of a second.
        let originals = Self.firstIndexByID(of: library.books)
        let proposedIndexes = Self.firstIndexByID(of: proposed.books)
        var moves: [LibraryTransitionMove] = []
        for bookID in affectedBookIDs {
            guard let originalIndex = originals[bookID],
                  let proposedIndex = proposedIndexes[bookID] else { continue }
            let original = library.books[originalIndex]
            var updated = proposed.books[proposedIndex]
            // A feed item's package is in its feed's own folder, which no
            // folder edit moves, and its row names no library folder (FR11):
            // it keeps its place as it is.
            guard !original.isFeedItem else {
                proposed.books[proposedIndex].fileLocation = original.fileLocation
                continue
            }
            guard !original.tmbDirectoryName.isEmpty else { continue }

            let source = original.tmbDirectory
            let destination = TextMouthPaths.tmbPath(
                folderPath: updated.folderPath,
                tmbName: original.tmbDirectoryName
            )
            // Equivalent folder paths name one directory on this volume, so a
            // "move" there would find its own source occupying the destination.
            let needsDiskMove = !equivalence.areEquivalent(original.folderPath, updated.folderPath)
            let fileName = URL(fileURLWithPath: original.filePath).lastPathComponent
            updated.filePath = destination.appendingPathComponent(fileName).path
            proposed.books[proposedIndex] = updated
            moves.append(LibraryTransitionMove(
                original: original,
                updated: updated,
                source: source,
                destination: destination,
                needsDiskMove: needsDiskMove
            ))
        }
        return LibraryTransitionPlan(
            original: library,
            proposed: proposed,
            moves: moves,
            changedFolders: changedFolders
        )
    }

    /// Makes the library hold `plan`'s rows, once its packages have moved and
    /// their records are rewritten, keeping any change made meanwhile
    /// (`library(after:current:)`), and saves it. Each moved book's record
    /// now holds its state where its package is, which settles an earlier
    /// failed write of the book.
    private func publish(_ plan: LibraryTransitionPlan) {
        let changedRows = rowsChanged(during: plan)
        library = Self.library(after: plan, current: library)
        save()
        for move in plan.moves {
            failureCenter.recordSuccess(.book(move.original.id))
        }
        for id in changedRows {
            if let book = bookByID(id) {
                LibraryPersistenceService.saveBookInfo(for: book)
            }
        }
        FileImportService.removeEmptyLibrarySubdirectories(library: library)
    }

    /// Saves again, where their packages are, the records of `plan`'s books
    /// whose rows changed while a transition that failed was put back: the
    /// rollback restored each record as the transition found it.
    private func saveRowsChanged(during plan: LibraryTransitionPlan) {
        for id in rowsChanged(during: plan) {
            if let book = bookByID(id) {
                LibraryPersistenceService.saveBookInfo(for: book)
            }
        }
    }

    /// The IDs of `plan`'s books whose rows in the library differ from the
    /// rows the plan was made from, as a reader's checkpoint or another
    /// window's edit makes them differ while the packages move.
    private func rowsChanged(during plan: LibraryTransitionPlan) -> [UUID] {
        let rows = Self.firstIndexByID(of: library.books)
        return plan.moves.compactMap { move in
            guard let index = rows[move.original.id], library.books[index] != move.original else { return nil }
            return move.original.id
        }
    }

    /// The index of each book in `books` by its ID: the first, should an
    /// ID appear twice, as a search from the start would find it.
    private nonisolated static func firstIndexByID(of books: [Book]) -> [UUID: Int] {
        Dictionary(books.indices.map { (books[$0].id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The library to hold once `plan`'s packages have moved: `plan.proposed`,
    /// unless the library changed meanwhile, which a transition run off the
    /// main actor allows. Then it is the library as it is now, with the
    /// transition's own changes made to it: each moved book's place (its
    /// folder, package, and file paths), and the folders and folder sort
    /// settings the transition added, changed, or removed. A book removed
    /// meanwhile stays removed, and one added meanwhile stays; so does any
    /// other change, such as a book added to the reading list in another
    /// window or a feed's rows on the feed shelf.
    nonisolated static func library(after plan: LibraryTransitionPlan, current: Library) -> Library {
        let original = plan.original
        // The proposed library holds every part of the library as the plan
        // found it, so it stands in only for a library unchanged in every
        // stored field (`Library`'s synthesized `==`). Any change meanwhile,
        // to the reading list, the feed shelf, or the kept rows as much as to
        // the books, folders, or sort settings, goes through the merge below,
        // which starts from `current` and so keeps it.
        guard current != original else { return plan.proposed }

        var merged = current
        let places = Dictionary(
            plan.moves.map { ($0.original.id, $0.updated.fileLocation) },
            uniquingKeysWith: { first, _ in first }
        )
        for index in merged.books.indices {
            if let place = places[merged.books[index].id] {
                merged.books[index].fileLocation = place
            }
        }
        merged.folders = mergedChanges(
            from: original.folders,
            to: plan.proposed.folders,
            into: current.folders,
            key: \.id
        )
        merged.folderSortSettings = mergedChanges(
            from: original.folderSortSettings,
            to: plan.proposed.folderSortSettings,
            into: current.folderSortSettings
        )
        return merged
    }

    /// `current` with the changes that turned `before` into `after`: items
    /// removed, changed, and added, matched by `key`; items no change touched
    /// stay as `current` has them.
    private nonisolated static func mergedChanges<Item: Equatable, Key: Hashable>(
        from before: [Item],
        to after: [Item],
        into current: [Item],
        key: (Item) -> Key
    ) -> [Item] {
        let beforeByKey = Dictionary(before.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        let afterByKey = Dictionary(after.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        var merged = current.filter { item in
            beforeByKey[key(item)] == nil || afterByKey[key(item)] != nil
        }
        for index in merged.indices {
            let itemKey = key(merged[index])
            if let changed = afterByKey[itemKey], let was = beforeByKey[itemKey], changed != was {
                merged[index] = changed
            }
        }
        let present = Set(merged.map(key))
        merged += after.filter { beforeByKey[key($0)] == nil && !present.contains(key($0)) }
        return merged
    }

    /// `current` with the changes that turned `before` into `after`: entries
    /// removed, changed, and added; entries no change touched stay as
    /// `current` has them.
    private nonisolated static func mergedChanges<Value: Equatable>(
        from before: [String: Value],
        to after: [String: Value],
        into current: [String: Value]
    ) -> [String: Value] {
        var merged = current
        for (key, value) in before where after[key] == nil {
            if merged[key] == value {
                merged[key] = nil
            }
        }
        for (key, value) in after where before[key] != value {
            merged[key] = value
        }
        return merged
    }

    /// Writes the record of the book `id` as the library now holds it, into
    /// the package where the library expects it: the retry of a record that
    /// a failed transition could not restore. Success settles the book's
    /// failure; a failure is reported again, with this retry. A book no
    /// longer in the library has no record left to restore, so its failure
    /// is withdrawn.
    func retryRecordRestore(ofBookID id: UUID, disk: LibraryTransitionDisk) {
        guard let book = bookByID(id) else {
            failureCenter.withdraw(.book(id))
            return
        }
        LibraryTransitionDiskWork.restoreRecord(of: book, disk: disk, restoringThrough: self)
    }

    /// Where the library's failed writes and cleanups are reported and shown.
    var failureCenter: PersistenceFailureCenter {
        .shared
    }

    /// Explains a failed operation through the library's error alert as
    /// "<context>: <reason>".
    func presentFilesystemError(_ context: String, error: Error) {
        presentFailure(of: .failure(context, error))
    }

    /// Shows a failed outcome's message through the library's error alert;
    /// a success shows nothing. Workflows that report outcomes where they
    /// started, such as the library's sheets and Storage settings, do not
    /// call this, so their failures never surface a second time elsewhere.
    func presentFailure(of outcome: OperationOutcome) {
        guard let message = outcome.failureMessage else { return }
        errorMessage = message
        showError = true
    }

    /// `outcome` as a workflow may report it once the library's queued
    /// writes have been made (TODO S09): they are written now, and a success
    /// that leaves changes unsaved becomes a failure that names them, since
    /// "Done" would claim the work was saved. Storage settings report their
    /// operations through this.
    func outcomeConfirmingSaves(_ outcome: OperationOutcome) -> OperationOutcome {
        LibraryPersistenceService.flushPendingSave()
        return outcome.confirmingSaves(failureCenter.unsavedFailures())
    }

    // MARK: - Metadata and State Updates

    /// Reports where a reader is now, for the library's rows and summary
    /// bar, without changing the library or writing to disk. Reader windows
    /// call this at a throttled cadence (about once a second) so the library
    /// and the reader calculate remaining time from the same cursor.
    ///
    /// The position goes to `livePositions` (TODO PERF11), which redraws only
    /// the book's row and the summary bar; the library takes the reader's
    /// position at its next checkpoint (`persistReadingPosition`). A book no
    /// longer in the library, or a cursor that has not moved, changes
    /// nothing.
    func updateLiveReadingPosition(bookID: UUID, position: ReadingPosition) {
        guard let book = bookByID(bookID) else { return }
        livePositions.update(position, of: book)
    }

    /// Persists a reading checkpoint to both the library index and the book's
    /// package metadata. This is intentionally separate from live publication.
    ///
    /// The book's record takes the checkpoint within half a second, and
    /// holds it durably; library.json, half a megabyte, takes it within five
    /// minutes, or sooner when anything else is saved, when the book's reader
    /// closes, or when TextMouth quits (PERF15,
    /// `LibraryPersistenceService.saveReadingCheckpoint`). A launch after a
    /// crash takes the newer position from the record
    /// (`adoptNewerRecordedPositions`). A book without a package has no
    /// record, so library.json takes its checkpoint as soon as any change.
    ///
    /// - Parameter markingOpened: Whether the checkpoint dates the book's
    ///   last opening now, in its row and so in its record, as a reader's
    ///   checkpoint does (the default). A place moved for a book nobody
    ///   opened, as the one-time move of finished books to their ends moves
    ///   one, passes false and keeps the date
    ///   (`Library.updateReadingPosition(bookID:position:markingOpened:)`).
    func persistReadingPosition(bookID: UUID, position: ReadingPosition, markingOpened: Bool = true) {
        library.updateReadingPosition(bookID: bookID, position: position, markingOpened: markingOpened)
        guard let book = bookByID(bookID) else { return }
        guard !book.tmbDirectoryName.isEmpty else {
            save()
            return
        }
        LibraryPersistenceService.saveReadingCheckpoint(library, of: bookID)
        LibraryPersistenceService.saveBookInfo(for: book)
    }

    /// Saves `edit`, one save of a metadata editor, to the row of the book
    /// `bookID`, as every editor's save does, and returns the row as saved,
    /// or nil when the book has left the library.
    ///
    /// The edit applies to the row as it is now, never as the editor
    /// opened with it (`Book.applyMetadataEdit(_:)`): each field the user
    /// changed, saved with a value other than the one the editor opened
    /// with, takes the value saved and is recorded as edited by hand, and
    /// every other field keeps the row's value. So a field another window
    /// or the launch metadata refresh changed while the editor was open
    /// keeps that change and is not marked; a field the editor showed from
    /// the book's file, where the row keeps none, is not kept in the row
    /// when saved unchanged; and the row's record of hand edits, which may
    /// have grown since the editor opened, keeps every field it names. A
    /// save that changes nothing writes nothing, so the row, its record,
    /// and the library index stay as they are.
    ///
    /// - Parameters:
    ///   - edit: What the editor opened with and what the user saved.
    ///   - bookID: The book edited.
    ///   - contentHash: The new content hash of the book's file, when the
    ///     save wrote the edit into the file (an EPUB's, TODO A09); nil
    ///     keeps the row's.
    @discardableResult
    func updateBookMetadata(_ edit: Book.MetadataEdit, of bookID: UUID, contentHash: String? = nil) -> Book? {
        guard let row = bookByID(bookID) else { return nil }
        // Nothing to change: a write would only rewrite the book's record
        // and the index, and redraw every Library window, for nothing.
        guard !edit.changes.isEmpty || contentHash != nil else { return row }
        var saved: Book?
        updateBook(id: bookID) { book in
            book.applyMetadataEdit(edit)
            if let contentHash {
                book.md5Hash = contentHash
            }
            saved = book
        }
        // An audiobook of tracks keeps its title and author in its manifest
        // too (FR17), through the one write of them.
        if let saved, saved.title != row.title || saved.author != row.author {
            setTitleAndAuthor(
                ofManifestBook: bookID,
                title: saved.title != row.title ? saved.title : nil,
                author: saved.author != row.author ? saved.author : nil
            )
        }
        return saved
    }

    /// Saves edited EPUB metadata from the reader's or the library's
    /// metadata editor, and returns what it did for the editor to report
    /// (TODO A09).
    ///
    /// With `writingToFile`, the library's copy of the book's EPUB file is
    /// written first, and only a write that succeeded is published: the
    /// library row, the book's record in its package (bookInfo.json), and
    /// the content hash then change together. A write that fails changes
    /// nothing, so every view of the book keeps agreeing, and the failure
    /// names the file and why. Without `writingToFile`, only the library's
    /// record of the book changes; the EPUB file is left as it is.
    ///
    /// The edit applies to the book as the library holds it now, found by
    /// its ID, so an editor opened before the book moved writes the file
    /// where it is now, and a book that has left the library is not saved at
    /// all. Only the fields the user changed are saved and recorded as
    /// edited by hand (`updateBookMetadata(_:of:contentHash:)`), and the
    /// file is given the row as the save leaves it, so a field another
    /// window changed while the editor was open goes into the file as the
    /// row has it now. Nothing is presented or announced here: the caller
    /// reports the result where the user is working.
    ///
    /// - Parameters:
    ///   - metadata: The edited metadata. Its title, author, publisher, and
    ///     publication date are saved; its other fields are read-only.
    ///   - opened: The metadata the editor opened with, which tells the
    ///     fields the user changed from the rest.
    ///   - book: The book being edited, as the editor knows it.
    ///   - writingToFile: Whether to write the library's copy of the EPUB
    ///     file too.
    ///   - writer: Writes the file; tests pass one that fails.
    func saveEPUBMetadata(
        _ metadata: EPUBMetadata,
        openedAs opened: EPUBMetadata,
        for book: Book,
        writingToFile: Bool,
        writer: EPUBMetadataWriter = .system
    ) -> EPUBMetadataSave {
        let notInLibrary = MetadataEditorWording.notInLibrary(title: book.title)
        guard let row = bookByID(book.id) else {
            return .failed(message: notInLibrary)
        }
        let edit = Book.MetadataEdit(opened: opened, saved: metadata)

        let message: String
        var contentHash: String?
        if writingToFile && row.format == .epub {
            let wording = EPUBMetadataSaveWording(filePath: row.filePath)
            // The file takes the row as the edit leaves it, with the
            // editor's metadata under it for the fields the row keeps none
            // of, so the file and the row agree once the save is done.
            var edited = row
            edited.applyMetadataEdit(edit)
            do {
                // The new hash describes the written file, so it is recorded
                // only once the write has succeeded.
                contentHash = try writer.write(
                    edited.mergingEditableEPUBMetadata(metadata),
                    URL(fileURLWithPath: row.filePath)
                )
            } catch {
                // A file that is not there is told apart from one that could
                // not be written: the way on is different, and its error
                // carries the file's whole path, which neither the log nor
                // a listener's ear should have.
                var isMissing = false
                if case EPUBParserError.fileNotFound = error { isMissing = true }
                // The error's domain, code, and description, which names files
                // by name; the missing file's error would repeat the path.
                let failure = error as NSError
                let detail = isMissing
                    ? "the file was not found"
                    : "\(failure.domain) \(failure.code): \(failure.localizedDescription)"
                DiagnosticLog.event(
                    .storage,
                    "EPUB_METADATA_WRITE_FAILED: book=\(book.id.uuidString.prefix(8)) "
                        + "file=\(DiagnosticLog.loggablePath(row.filePath)): \(detail)"
                )
                return .failed(message: isMissing
                    ? wording.fileMissing
                    : wording.writeFailed(reason: error.localizedDescription))
            }
            message = wording.savedToFile
        } else {
            message = EPUBMetadataSaveWording.savedToLibraryOnly
        }
        // The row as saved carries the record of hand edits, which the
        // reader's copy takes from it.
        guard let saved = updateBookMetadata(edit, of: book.id, contentHash: contentHash) else {
            return .failed(message: notInLibrary)
        }
        return .saved(saved, message: message)
    }

    func updatePlaybackTimestamps(bookID: UUID, started: Date?, stopped: Date?) {
        updateBook(id: bookID) { book in
            book.lastPlaybackStarted = started
            book.lastPlaybackStopped = stopped
        }
    }

    func updateEndOfBookBehavior(bookID: UUID, behavior: String?) {
        updateBook(id: bookID) { $0.localEndOfBookBehavior = behavior }
    }

    /// Saves `headings` as the headings the book `bookID` skips during
    /// playback, each with the text at its start (T06's branch B), in its
    /// row and its record; their IDs are written from them for the reader's
    /// filter and for older builds (`Book.setSkippedHeadings(_:)`). None
    /// skips nothing.
    ///
    /// A heading saved without its text keeps the text the row holds for
    /// the same heading, so a reader whose copy of the book predates a
    /// capture never drops one.
    func updateSkippedHeadings(bookID: UUID, headings: [SkippedHeading]) {
        updateBook(id: bookID) { book in
            var heldAnchors: [String: TextAnchor] = [:]
            for held in book.skippedHeadings ?? [] where heldAnchors[held.id] == nil {
                heldAnchors[held.id] = held.anchor
            }
            book.setSkippedHeadings(headings.map { heading in
                guard heading.anchor == nil, let anchor = heldAnchors[heading.id] else { return heading }
                var kept = heading
                kept.anchor = anchor
                return kept
            })
        }
    }

    /// Gives the book `bookID` its own voice, speed, and pitch, nil for each
    /// it takes from the settings. The speed is kept within its format's
    /// range, as the book's record reads it back (REV11): words per minute
    /// for a text book, a playback rate for an audiobook, so an article
    /// given a rate of 1.5 keeps 50 words per minute in its row as in its
    /// record; a pitch is kept within the pitch's range likewise.
    func updateLocalVoiceAndSpeed(bookID: UUID, voiceID: String?, wpm: Double?, pitch: Double? = nil) {
        updateBook(id: bookID) { book in
            book.localVoiceID = voiceID
            book.localWPM = wpm.flatMap { SettingsPolicy.validatedLocalSpeed($0, isAudio: book.format.isAudio) }
            book.localPitch = pitch.flatMap(SettingsPolicy.validatedLocalPitch)
        }
    }

    /// Persist both per-book navigation-unit overrides as one atomic update so
    /// shared-menu changes cannot briefly leave the two directions out of sync.
    func updateLocalSkipUnits(bookID: UUID, forward: String?, backward: String?) {
        updateBook(id: bookID) { book in
            book.localSkipForwardUnit = forward
            book.localSkipBackwardUnit = backward
        }
    }

    func updateWordCounts(bookID: UUID, wordCount: Int, charCount: Int) {
        library.updateWordCounts(bookID: bookID, wordCount: wordCount, charCount: charCount)
        save()
        if let book = library.books.first(where: { $0.id == bookID }) {
            LibraryPersistenceService.saveBookInfo(for: book)
        }
    }

    func updateAudioDuration(bookID: UUID, duration: TimeInterval) {
        updateBook(id: bookID) { $0.audioDuration = duration }
    }

    /// Publish only the compact analysis summary to the main-actor library.
    /// The full chapter/heading index is encoded on the package persistence queue.
    /// The row takes the analysis fields alone, through the same helper that
    /// merges an analysis into a package record, and keeps its newer reading
    /// state; the save below records the index with exactly those fields.
    func updateContentIndex(
        bookID: UUID,
        index: BookContentIndex,
        cacheFormatVersion: String? = nil
    ) {
        guard let bookIndex = library.books.firstIndex(where: { $0.id == bookID }) else { return }
        library.books[bookIndex].applyContentAnalysis(index, cacheFormatVersion: cacheFormatVersion)
        let updatedBook = library.books[bookIndex]
        save()
        LibraryPersistenceService.saveBookInfo(for: updatedBook, contentIndex: index)
    }

    // MARK: - Queries

    /// The book `id` of the library, found by the list cache's index of the
    /// books by ID rather than a scan of every book.
    func bookByID(_ id: UUID) -> Book? {
        listCache.book(withID: id, in: library)
    }

    // MARK: - Open Book Tracking

    /// Notes that a reader opened the book `id`: the book is open until its
    /// last reader closes (`openReaderCounts`).
    func registerOpenBook(_ id: UUID) {
        openReaderCounts[id, default: 0] += 1
        openBookIDs.insert(id)
        // Track last opened book for quick-resume. config.json takes it once
        // changes pause (PERF17), not as the reader window opens.
        let config = ConfigService.shared
        config.config.lastOpenedBookID = id.uuidString
        config.scheduleSave()
    }

    /// Notes that a reader of the book `id` closed: the book leaves
    /// `openBookIDs` with its last reader, not before. Its last reading
    /// checkpoint, saved as it closed, reaches library.json now rather than at
    /// the checkpoint's deadline (PERF15).
    func unregisterOpenBook(_ id: UUID) {
        let remaining = (openReaderCounts[id] ?? 0) - 1
        if remaining > 0 {
            openReaderCounts[id] = remaining
        } else {
            openReaderCounts[id] = nil
            openBookIDs.remove(id)
        }
        LibraryPersistenceService.writePendingIndexSoon()
    }

    /// The most recently opened book (for quick-resume on launch)
    var lastOpenedBook: Book? {
        let idString = ConfigService.shared.config.lastOpenedBookID
        guard !idString.isEmpty, let uuid = UUID(uuidString: idString) else { return nil }
        return library.books.first { $0.id == uuid }
    }
}

// MARK: - Library Transitions

/// One book's part in a library transition: the book before and after, and
/// the package directory it moves between.
struct LibraryTransitionMove: Sendable {
    /// The book as the library holds it before the transition.
    let original: Book
    /// The book as the transition leaves it.
    var updated: Book
    /// Where its package is before the transition.
    let source: URL
    /// Where its package goes.
    let destination: URL
    /// False when the package already sits in its destination directory.
    let needsDiskMove: Bool
}

/// A library transition worked out on the main actor before anything on
/// disk changes: the library it starts from and the one it makes, each
/// affected book's move, and the folders it introduces, which need
/// directories of their own.
struct LibraryTransitionPlan: Sendable {
    /// The library the transition was planned from.
    let original: Library
    /// The library the transition makes.
    let proposed: Library
    /// Each affected book's part, for the books that have packages.
    let moves: [LibraryTransitionMove]
    /// The folders the proposed library holds that the original did not.
    let changedFolders: [BookFolder]

    /// The books whose packages move on disk, which open readers are told
    /// about before and after.
    var movingBookIDs: [UUID] {
        moves.filter(\.needsDiskMove).map(\.original.id)
    }
}

/// The disk operations a library transition makes, and its rollback undoes.
/// Tests replace them to make one fail at a chosen moment (TODO S09). They
/// run on whatever thread runs the transition's disk work: the main thread
/// for `commitLibraryTransition`, a background queue for
/// `performLibraryTransition` (PERF14).
struct LibraryTransitionDisk: Sendable {
    /// Moves a package directory from the first URL to the second.
    var moveItem: @Sendable (_ source: URL, _ destination: URL) throws -> Void
    /// Writes a book's record into its package.
    var writeRecord: @Sendable (_ book: Book) throws -> Void

    /// The operations the app makes.
    static let system = LibraryTransitionDisk(
        moveItem: { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        },
        writeRecord: { book in
            try book.saveBookInfoThrowing()
        }
    )
}

/// The disk side of a library transition: checking that each package can
/// move, moving it, rewriting its record, making the new folders, and, when
/// any step fails, putting back what was done. It touches nothing but the
/// disk and the failure center, so it runs on any thread (PERF14).
enum LibraryTransitionDiskWork {
    /// Makes `plan`'s changes on disk through `disk`, or throws the first
    /// failure once it has put back what it did (`rollBack`). Every package
    /// is checked before any moves: its source must be there and its
    /// destination free, and the destination's folder is made. `model` is
    /// the library model the failures' retries look the books up in.
    static func perform(
        _ plan: LibraryTransitionPlan,
        disk: LibraryTransitionDisk,
        restoringThrough model: LibraryViewModel?
    ) throws {
        let fileManager = FileManager.default
        for move in plan.moves where move.needsDiskMove {
            guard fileManager.fileExists(atPath: move.source.path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: move.source.path])
            }
            guard !fileManager.fileExists(atPath: move.destination.path) else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: move.destination.path])
            }
            try TextMouthPaths.ensureLibrarySubfolder(move.updated.folderPath)
        }

        var completedMoves: [LibraryTransitionMove] = []
        var rewrittenRecordIDs: Set<UUID> = []
        do {
            for move in plan.moves where move.needsDiskMove {
                try disk.moveItem(move.source, move.destination)
                completedMoves.append(move)
            }
            for move in plan.moves {
                try disk.writeRecord(move.updated)
                rewrittenRecordIDs.insert(move.original.id)
            }
            // Empty folders have no book move to create their destinations.
            // Materialize changed folder paths before publishing the model.
            for folder in plan.changedFolders {
                try TextMouthPaths.ensureLibrarySubfolder(folder.fullPath)
            }
        } catch {
            rollBack(plan.moves, completed: completedMoves, rewrittenRecordIDs: rewrittenRecordIDs, disk: disk, model: model)
            throw error
        }
    }

    /// Undoes the disk side of a library transition that failed, while the
    /// library still holds every book where it was (TODO S09). Each package
    /// that moved goes back, the last one moved first; then each book whose
    /// record was rewritten gets back the record of its state as the
    /// transition found it, where its package now is. A package that moved
    /// but whose record was not rewritten carried its record with it,
    /// unchanged, so it needs none.
    ///
    /// Nothing here is silent. A package that cannot be moved back is
    /// reported with both paths, so the user knows where its files are, and
    /// keeps its rewritten record, which describes where it is; a record
    /// that cannot be restored is reported as the book's unsaved record.
    /// Each report carries a retry.
    private static func rollBack(
        _ moves: [LibraryTransitionMove],
        completed: [LibraryTransitionMove],
        rewrittenRecordIDs: Set<UUID>,
        disk: LibraryTransitionDisk,
        model: LibraryViewModel?
    ) {
        var stranded: Set<UUID> = []
        for move in completed.reversed() where !moveBack(move, disk: disk, model: model) {
            stranded.insert(move.original.id)
        }
        for move in moves
        where rewrittenRecordIDs.contains(move.original.id) && !stranded.contains(move.original.id) {
            restoreRecord(of: move.original, disk: disk, restoringThrough: model)
        }
    }

    /// Moves `move`'s package back to where the library expects it, and
    /// returns whether it is back. One that cannot be moved back is reported
    /// to the failure center with where it is and where it belongs; its
    /// retry, on the main actor, moves it back and then restores its record
    /// as the library holds the book then.
    @discardableResult
    static func moveBack(_ move: LibraryTransitionMove, disk: LibraryTransitionDisk, model: LibraryViewModel?) -> Bool {
        do {
            try disk.moveItem(move.destination, move.source)
            return true
        } catch {
            PersistenceFailureCenter.shared.recordFailure(
                .strandedPackage(
                    bookID: move.original.id,
                    title: move.original.title,
                    location: move.destination.path,
                    home: move.source.path
                ),
                path: move.destination.path,
                error: error
            ) { [weak model] _ in
                guard moveBack(move, disk: disk, model: model) else { return }
                model?.retryRecordRestore(ofBookID: move.original.id, disk: disk)
            }
            return false
        }
    }

    /// Writes `book`'s record into its package. Success settles the book's
    /// failure; a failure is reported as the book's unsaved record, whose
    /// retry, on the main actor, writes the record of the book as the
    /// library holds it then (`LibraryViewModel.retryRecordRestore`).
    static func restoreRecord(of book: Book, disk: LibraryTransitionDisk, restoringThrough model: LibraryViewModel?) {
        do {
            try disk.writeRecord(book)
            PersistenceFailureCenter.shared.recordSuccess(.book(book.id))
        } catch {
            PersistenceFailureCenter.shared.recordFailure(
                .bookRecord(bookID: book.id, title: book.title),
                path: TextMouthPaths.bookInfoPath(in: book.tmbDirectory).path,
                error: error
            ) { [weak model] _ in
                model?.retryRecordRestore(ofBookID: book.id, disk: disk)
            }
        }
    }
}

/// What VoiceOver hears when a library transition run off the main actor
/// finishes (PERF14).
enum LibraryTransitionWording {
    /// How many packages a transition must move before its end is
    /// announced: a smaller one finishes before the user could wonder, and
    /// the sheet that started it closing says enough.
    static let announcedPackageCount = 25

    /// The announcement of a finished transition that moved `count`
    /// packages, such as "Done. Moved 527 books."; nil below
    /// `announcedPackageCount`.
    static func completion(movingPackagesOf count: Int) -> String? {
        guard count >= announcedPackageCount else { return nil }
        return "Done. Moved \(CountWording.books(count))."
    }

    /// The Move to Folder… command for `targets`, the books a row's commands
    /// act on: "Move to Folder..." for one book to move, "Move 3 Books to
    /// Folder..." for several, counting only books of the library's own,
    /// since a feed item stays in its feed's folder (FR11); nil, so the
    /// command is not offered, when every target is a feed item.
    static func moveToFolderTitle(for targets: [Book]) -> String? {
        let movable = targets.reduce(0) { $1.isFeedItem ? $0 : $0 + 1 }
        guard movable > 0 else { return nil }
        return movable > 1 ? "Move \(movable) Books to Folder..." : "Move to Folder..."
    }

    /// What VoiceOver hears when Move to Folder… leaves feed items titled
    /// `titles` where they are, as it leaves every episode and article in its
    /// feed's folder (FR11), naming the first three and the command that
    /// does move one (FR11, branch D): "Left “Ep. 368” where it is: episodes
    /// and articles stay in their feeds; Move to Library… makes one a book of
    /// your library."; nil for none.
    static func feedItemsLeft(titles: [String]) -> String? {
        guard !titles.isEmpty else { return nil }
        let shown = titles.prefix(3).map { "“\($0)”" }
        let rest = titles.count - shown.count
        let names = rest > 0
            ? shown.joined(separator: ", ") + ", and \(rest) more"
            : CountWording.list(Array(shown))
        let place = titles.count == 1 ? "where it is" : "where they are"
        return "Left \(names) \(place): episodes and articles stay in their feeds; "
            + "\(ShortcutAction.moveToLibrary.title) makes one a book of your library."
    }
}
