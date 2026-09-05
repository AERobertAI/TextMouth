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

    /// Remove books from the library index only, leaving .tmb files on disk.
    /// Deletes bookInfo.json from each .tmb so orphan adoption won't re-add them.
    func removeBooksFromLibraryOnly(_ books: [Book]) {
        for book in books {
            // Remove bookInfo.json so adoptOrphanedTMBPackages won't re-adopt this book.
            // The .tmb and its book file remain on disk for the user to reimport if desired.
            if !book.tmbDirectoryName.isEmpty {
                let infoURL = TextMouthPaths.bookInfoPath(in: book.tmbDirectory)
                try? FileManager.default.removeItem(at: infoURL)
            }
            library.removeBook(id: book.id)
        }
        save()
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

    /// Move one or more books to the specified folder path
    func moveBooks(_ books: [Book], toFolder path: String) {
        var proposed = library
        let ids = Set(books.map(\.id))
        for index in proposed.books.indices where ids.contains(proposed.books[index].id) {
            proposed.books[index].folderPath = path
        }
        do {
            try commitLibraryTransition(proposed, affectedBookIDs: ids)
            lastMovedFolderPath = path
        } catch {
            presentFilesystemError("Could not move books", error: error)
        }
    }

    /// Move every changed package, persist its new metadata, and then commit the
    /// proposed library model. Completed disk moves are reversed on any failure.
    func commitLibraryTransition(_ proposedLibrary: Library, affectedBookIDs: Set<UUID>) throws {
        struct Move {
            let original: Book
            var updated: Book
            let source: URL
            let destination: URL
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
            if source != destination {
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
            moves.append(Move(original: original, updated: updated, source: source, destination: destination))
        }

        var completedMoves: [Move] = []
        do {
            for move in moves where move.source != move.destination {
                try FileManager.default.moveItem(at: move.source, to: move.destination)
                completedMoves.append(move)
            }
            for move in moves {
                try move.updated.saveBookInfoThrowing()
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
            throw error
        }

        library = proposed
        save()
        FileImportService.removeEmptyLibrarySubdirectories(library: library)
    }

    func presentFilesystemError(_ context: String, error: Error) {
        errorMessage = "\(context): \(error.localizedDescription)"
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
    func updateContentIndex(
        bookID: UUID,
        index: BookContentIndex,
        cacheFormatVersion: String? = nil
    ) {
        guard let bookIndex = library.books.firstIndex(where: { $0.id == bookID }) else { return }
        library.books[bookIndex].applyContentIndexSummary(index)
        if let cacheFormatVersion {
            library.books[bookIndex].cacheFormatVersion = cacheFormatVersion
        }
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
