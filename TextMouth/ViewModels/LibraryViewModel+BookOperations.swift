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

    /// Request removal of one or more books — shows confirmation if enabled
    func removeBooks(_ books: [Book]) {
        guard !books.isEmpty else { return }
        if configService.config.confirmBeforeDelete {
            pendingRemoveBooks = books
            showRemoveBookDialog = true
        } else {
            // Default: remove from library and delete .tmb
            performRemoveBooks(books, deleteTMB: true)
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
    func removeBooksAndDelete(_ books: [Book]) {
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
    func performRemoveBooks(
        _ books: [Book],
        deleteTMB: Bool,
        deletePackage: ((Book) throws -> Void)? = nil
    ) {
        presentFailure(of: removeBooksReturningOutcome(
            books,
            deletingPackages: deleteTMB,
            deletePackage: deletePackage
        ))
    }

    /// Removes `books` from the library. With `deletingPackages`, each
    /// package is deleted first, through the Trash-aware path unless a test
    /// injects `deletePackage`, and a book whose package cannot be deleted
    /// stays. Returns the outcome in the words of the deleting mode in force.
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
        for book in books {
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
        let completion = removed.isEmpty ? nil : RemovalWording(mode, books: removed).completionMessage
        guard !failures.isEmpty else { return .success(completion) }
        let report = [completion, mode.failureMessage(failures)].compactMap { $0 }
        return .failure(report.joined(separator: "\n\n"))
    }

    /// Takes `book`, whose package was just deleted, out of the library
    /// model and out of the persistence queue: no write queued for it may
    /// chase the deleted package, and a failed write of its record no
    /// longer counts as unsaved (TODO S09). Every removal that deletes a
    /// package ends here.
    func removeDeletedBook(_ book: Book) {
        library.removeBook(id: book.id)
        LibraryPersistenceService.forgetDeletedBook(book)
    }

    // MARK: - Moving Books

    func moveBook(_ book: Book, toFolder path: String) {
        moveBooks([book], toFolder: path)
    }

    /// Move one or more books to the specified folder path. A failure is
    /// explained through the library's error alert.
    func moveBooks(_ books: [Book], toFolder path: String) {
        presentFailure(of: moveBooksReturningOutcome(books, toFolder: path))
    }

    /// Moves books to the folder at `path` and returns what happened,
    /// presenting nothing, so the move sheet can stay open with the reason
    /// after a failure (TODO A07). A failed move puts back any package that
    /// already moved and leaves the library as it was.
    func moveBooksReturningOutcome(_ books: [Book], toFolder path: String) -> OperationOutcome {
        var proposed = library
        let ids = Set(books.map(\.id))
        for index in proposed.books.indices where ids.contains(proposed.books[index].id) {
            proposed.books[index].folderPath = path
        }
        do {
            try commitLibraryTransition(proposed, affectedBookIDs: ids)
            lastMovedFolderPath = path
            return .success(nil)
        } catch {
            return .failure("Could not move books", error)
        }
    }

    /// Move every changed package, persist its new metadata, and then commit the
    /// proposed library model. Completed disk moves are reversed on any failure.
    /// A book whose old and new folders name the same directory under
    /// `equivalence` (a case- or normalization-only respelling) stays where it
    /// is; only its recorded path and package record change.
    ///
    /// A move that writes a book's record has saved the book's current state,
    /// so it settles any earlier failed write of the book. Undoing a failed
    /// transition is never silent: what cannot be put back is reported to the
    /// failure center (`rollBack`). `disk` makes the moves and writes; tests
    /// replace it to make one of them fail.
    ///
    /// Readers with a moving book open hear of the move before any package
    /// moves, and that it ended once the library holds the books' new rows,
    /// or once a failed transition has been put back (TODO P10).
    func commitLibraryTransition(
        _ proposedLibrary: Library,
        affectedBookIDs: Set<UUID>,
        equivalence: FolderPathEquivalence = .library,
        disk: LibraryTransitionDisk = .system
    ) throws {
        typealias Move = LibraryTransitionMove

        var proposed = proposedLibrary
        let existingPaths = Set(library.folders.map(\.fullPath))
        let changedFolders = proposed.folders.filter { !existingPaths.contains($0.fullPath) }
        guard changedFolders.allSatisfy({ BookFolder.isValidLibraryPath($0.fullPath) }),
              proposed.books.filter({ affectedBookIDs.contains($0.id) })
                .allSatisfy({ BookFolder.isValidLibraryPath($0.folderPath) }) else {
            throw FileImportError.importFailed("A destination folder path is invalid.")
        }
        var moves: [Move] = []
        for bookID in affectedBookIDs {
            guard let original = library.books.first(where: { $0.id == bookID }),
                  let proposedIndex = proposed.books.firstIndex(where: { $0.id == bookID }) else { continue }
            var updated = proposed.books[proposedIndex]
            guard !original.tmbDirectoryName.isEmpty else { continue }

            let source = original.tmbDirectory
            let destination = TextMouthPaths.tmbPath(
                folderPath: updated.folderPath,
                tmbName: original.tmbDirectoryName
            )
            // Equivalent folder paths name one directory on this volume, so a
            // "move" there would find its own source occupying the destination.
            let needsDiskMove = !equivalence.areEquivalent(original.folderPath, updated.folderPath)
            if needsDiskMove {
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
                }
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
                }
                try TextMouthPaths.ensureLibrarySubfolder(updated.folderPath)
            }
            let fileName = URL(fileURLWithPath: original.filePath).lastPathComponent
            updated.filePath = destination.appendingPathComponent(fileName).path
            proposed.books[proposedIndex] = updated
            moves.append(Move(
                original: original,
                updated: updated,
                source: source,
                destination: destination,
                needsDiskMove: needsDiskMove
            ))
        }

        // A reader playing a moving book's audio stops reading its files
        // before they move, and plays on from the same place once the move
        // is over: from the new place, or from the old one when the move is
        // put back.
        let movingBookIDs = moves.filter(\.needsDiskMove).map(\.original.id)
        bookUpdates.packagesWillMove(movingBookIDs)
        defer { bookUpdates.packagesDidMove(movingBookIDs) }

        var completedMoves: [Move] = []
        var rewrittenRecordIDs: Set<UUID> = []
        do {
            for move in moves where move.needsDiskMove {
                try disk.moveItem(move.source, move.destination)
                completedMoves.append(move)
            }
            for move in moves {
                try disk.writeRecord(move.updated)
                rewrittenRecordIDs.insert(move.original.id)
            }
            // Empty folders have no book move to create their destinations.
            // Materialize changed folder paths before publishing the model.
            for folder in changedFolders {
                try TextMouthPaths.ensureLibrarySubfolder(folder.fullPath)
            }
        } catch {
            rollBack(moves, completed: completedMoves, rewrittenRecordIDs: rewrittenRecordIDs, disk: disk)
            throw error
        }

        library = proposed
        save()
        // Each moved book's record now holds its current state, where its
        // package is: an earlier failed write of the book is settled.
        for move in moves {
            failureCenter.recordSuccess(.book(move.original.id))
        }
        FileImportService.removeEmptyLibrarySubdirectories(library: library)
    }

    /// Undoes the disk side of a library transition that failed, while the
    /// library still holds every book where it was (TODO S09). Each package
    /// that moved goes back, the last one moved first; then each book whose
    /// record was rewritten gets the record of its current state back, where
    /// its package now is. A package that moved but whose record was not
    /// rewritten carried its record with it, unchanged, so it needs none.
    ///
    /// Nothing here is silent. A package that cannot be moved back is
    /// reported with both paths, so the user knows where its files are, and
    /// keeps its rewritten record, which describes where it is; a record
    /// that cannot be restored is reported as the book's unsaved record.
    /// Each report carries a retry.
    private func rollBack(
        _ moves: [LibraryTransitionMove],
        completed: [LibraryTransitionMove],
        rewrittenRecordIDs: Set<UUID>,
        disk: LibraryTransitionDisk
    ) {
        var stranded: Set<UUID> = []
        for move in completed.reversed() where !moveBack(move, disk: disk) {
            stranded.insert(move.original.id)
        }
        for move in moves
        where rewrittenRecordIDs.contains(move.original.id) && !stranded.contains(move.original.id) {
            restoreRecord(ofBookID: move.original.id, disk: disk)
        }
    }

    /// Moves `move`'s package back to where the library expects it, and
    /// returns whether it is back. One that cannot be moved back is reported
    /// to the failure center with where it is and where it belongs; its
    /// retry moves it back and then restores its record.
    private func moveBack(_ move: LibraryTransitionMove, disk: LibraryTransitionDisk) -> Bool {
        do {
            try disk.moveItem(move.destination, move.source)
            return true
        } catch {
            failureCenter.recordFailure(
                .strandedPackage(
                    bookID: move.original.id,
                    title: move.original.title,
                    location: move.destination.path,
                    home: move.source.path
                ),
                path: move.destination.path,
                error: error
            ) { [weak self] _ in
                guard let self, self.moveBack(move, disk: disk) else { return }
                self.restoreRecord(ofBookID: move.original.id, disk: disk)
            }
            return false
        }
    }

    /// Writes the record of the book `id` as the library now holds it, into
    /// the package where the library expects it. Success settles the book's
    /// failure; a failure is reported as the book's unsaved record, with a
    /// retry of this restore. A book no longer in the library has no record
    /// left to restore, so its failure is withdrawn.
    private func restoreRecord(ofBookID id: UUID, disk: LibraryTransitionDisk) {
        guard let book = bookByID(id) else {
            failureCenter.withdraw(.book(id))
            return
        }
        do {
            try disk.writeRecord(book)
            failureCenter.recordSuccess(.book(id))
        } catch {
            failureCenter.recordFailure(
                .bookRecord(bookID: id, title: book.title),
                path: TextMouthPaths.bookInfoPath(in: book.tmbDirectory).path,
                error: error
            ) { [weak self] _ in
                self?.restoreRecord(ofBookID: id, disk: disk)
            }
        }
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

    /// Updates the shared in-memory snapshot used by library rows without
    /// writing to disk. Reader windows call this at a throttled cadence so the
    /// library and reader calculate remaining time from the same cursor.
    func updateLiveReadingPosition(bookID: UUID, position: ReadingPosition) {
        guard let index = library.books.firstIndex(where: { $0.id == bookID }) else { return }
        let existing = library.books[index].readingPosition
        guard existing?.chapterIndex != position.chapterIndex
                || existing?.characterOffset != position.characterOffset
                || existing?.globalCharacterOffset != position.globalCharacterOffset else {
            return
        }
        library.books[index].readingPosition = position
    }

    /// Persists a reading checkpoint to both the library index and the book's
    /// package metadata. This is intentionally separate from live publication.
    func persistReadingPosition(bookID: UUID, position: ReadingPosition) {
        library.updateReadingPosition(bookID: bookID, position: position)
        save()
        if let book = library.books.first(where: { $0.id == bookID }) {
            LibraryPersistenceService.saveBookInfo(for: book)
        }
    }

    /// Compatibility name for navigation and bookmark call sites that expect
    /// an immediate durable checkpoint.
    func updateReadingPosition(bookID: UUID, position: ReadingPosition) {
        persistReadingPosition(bookID: bookID, position: position)
    }

    func updateBookMetadata(_ updatedBook: Book) {
        updateBook(id: updatedBook.id) { book in
            book.applyEditableMetadata(from: updatedBook)
        }
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
    /// all. Nothing is presented or announced here: the caller reports the
    /// result where the user is working.
    ///
    /// - Parameters:
    ///   - metadata: The edited metadata. Its title, author, publisher, and
    ///     publication date are saved; its other fields are read-only.
    ///   - book: The book being edited, as the editor knows it.
    ///   - writingToFile: Whether to write the library's copy of the EPUB
    ///     file too.
    ///   - writer: Writes the file; tests pass one that fails.
    func saveEPUBMetadata(
        _ metadata: EPUBMetadata,
        for book: Book,
        writingToFile: Bool,
        writer: EPUBMetadataWriter = .system
    ) -> EPUBMetadataSave {
        guard var updated = bookByID(book.id) else {
            return .failed(message: EPUBMetadataSaveWording.notInLibrary(title: book.title))
        }
        updated.title = metadata.title
        updated.author = metadata.author
        updated.epubPublisher = metadata.publisher
        updated.epubPublicationDate = metadata.publicationDate

        let message: String
        if writingToFile && updated.format == .epub {
            let wording = EPUBMetadataSaveWording(filePath: updated.filePath)
            do {
                // The new hash describes the written file, so it is recorded
                // only once the write has succeeded.
                updated.md5Hash = try writer.write(metadata, URL(fileURLWithPath: updated.filePath))
            } catch {
                // The error's domain, code, and description, which names files
                // by name; its full description would repeat absolute paths.
                let failure = error as NSError
                DiagnosticLog.event(
                    .storage,
                    "EPUB_METADATA_WRITE_FAILED: book=\(book.id.uuidString.prefix(8)) "
                        + "file=\(DiagnosticLog.loggablePath(updated.filePath)): "
                        + "\(failure.domain) \(failure.code): \(failure.localizedDescription)"
                )
                return .failed(message: wording.writeFailed(reason: error.localizedDescription))
            }
            message = wording.savedToFile
        } else {
            message = EPUBMetadataSaveWording.savedToLibraryOnly
        }
        updateBookMetadata(updated)
        return .saved(updated, message: message)
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

    func updateSkippedHeadings(bookID: UUID, skippedIDs: [String]) {
        updateBook(id: bookID) { $0.skippedHeadingIDs = skippedIDs.isEmpty ? nil : skippedIDs }
    }

    func updateLocalVoiceAndSpeed(bookID: UUID, voiceID: String?, wpm: Double?, pitch: Double? = nil) {
        updateBook(id: bookID) { book in
            book.localVoiceID = voiceID
            book.localWPM = wpm
            book.localPitch = pitch
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

    func bookByID(_ id: UUID) -> Book? {
        library.books.first { $0.id == id }
    }

    // MARK: - Open Book Tracking

    func registerOpenBook(_ id: UUID) {
        openBookIDs.insert(id)
        // Track last opened book for quick-resume
        let config = ConfigService.shared
        config.config.lastOpenedBookID = id.uuidString
        config.saveToDisk()
    }

    func unregisterOpenBook(_ id: UUID) {
        openBookIDs.remove(id)
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
struct LibraryTransitionMove {
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

/// The disk operations a library transition makes, and its rollback undoes.
/// Tests replace them to make one fail at a chosen moment (TODO S09).
struct LibraryTransitionDisk: Sendable {
    /// Moves a package directory from the first URL to the second.
    var moveItem: @MainActor @Sendable (_ source: URL, _ destination: URL) throws -> Void
    /// Writes a book's record into its package.
    var writeRecord: @MainActor @Sendable (_ book: Book) throws -> Void

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
