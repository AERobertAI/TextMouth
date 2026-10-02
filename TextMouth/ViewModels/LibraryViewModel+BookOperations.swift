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

    /// Remove books from the library and delete their .tmb packages
    func removeBooksAndDelete(_ books: [Book]) {
        performRemoveBooks(books, deleteTMB: true)
    }

    /// Internal helper to remove books with optional .tmb deletion
    func performRemoveBooks(
        _ books: [Book],
        deleteTMB: Bool,
        deletePackage: ((Book) throws -> Void)? = nil
    ) {
        let deletePackage = deletePackage ?? { book in
            try FileImportService.deleteBookPackage(book)
        }
        var failures: [String] = []
        for book in books {
            if deleteTMB {
                do {
                    try deletePackage(book)
                } catch {
                    failures.append("\(book.title): \(error.localizedDescription)")
                    continue
                }
            }
            library.removeBook(id: book.id)
        }
        save()
        if !failures.isEmpty {
            errorMessage = "Some books could not be moved to Trash and remain in the library:\n" + failures.joined(separator: "\n")
            showError = true
        }
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
    func commitLibraryTransition(
        _ proposedLibrary: Library,
        affectedBookIDs: Set<UUID>,
        equivalence: FolderPathEquivalence = .library
    ) throws {
        struct Move {
            let original: Book
            var updated: Book
            let source: URL
            let destination: URL
            /// False when the package already sits in its destination directory.
            let needsDiskMove: Bool
        }

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

        var completedMoves: [Move] = []
        var rewrittenRecordIDs: Set<UUID> = []
        do {
            for move in moves where move.needsDiskMove {
                try FileManager.default.moveItem(at: move.source, to: move.destination)
                completedMoves.append(move)
            }
            for move in moves {
                try move.updated.saveBookInfoThrowing()
                rewrittenRecordIDs.insert(move.original.id)
            }
            // Empty folders have no book move to create their destinations.
            // Materialize changed folder paths before publishing the model.
            for folder in changedFolders {
                try TextMouthPaths.ensureLibrarySubfolder(folder.fullPath)
            }
        } catch {
            for move in completedMoves.reversed() {
                try? FileManager.default.moveItem(at: move.destination, to: move.source)
                try? move.original.saveBookInfoThrowing()
            }
            // Packages that stayed in place may already carry the new record.
            for move in moves where !move.needsDiskMove && rewrittenRecordIDs.contains(move.original.id) {
                try? move.original.saveBookInfoThrowing()
            }
            throw error
        }

        library = proposed
        save()
        FileImportService.removeEmptyLibrarySubdirectories(library: library)
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
