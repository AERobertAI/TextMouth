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
    func performRemoveBooks(_ books: [Book], deleteTMB: Bool) {
        for book in books {
            if deleteTMB {
                FileImportService.deleteBookPackage(book)
            }
            library.removeBook(id: book.id)
        }
        save()
    }

    // MARK: - Moving Books

    func moveBook(_ book: Book, toFolder path: String) {
        moveBooks([book], toFolder: path)
    }

    /// Move one or more books to the specified folder path
    func moveBooks(_ books: [Book], toFolder path: String) {
        for book in books {
            guard let idx = library.books.firstIndex(where: { $0.id == book.id }) else { continue }
            // Move .tmb on disk BEFORE updating folderPath, so book.tmbDirectory
            // still points to the old location for the move source
            moveTMBToFolder(book: &library.books[idx], newFolderPath: path)
            library.books[idx].folderPath = path
        }
        lastMovedFolderPath = path
        save()
    }

    /// Move a .tmb package directory to a new library subfolder.
    /// When oldFolderPath is provided, it overrides book.folderPath for computing
    /// the source location (needed when folderPath was already updated by the model).
    func moveTMBToFolder(book: inout Book, newFolderPath: String, oldFolderPath: String? = nil) {
        guard !book.tmbDirectoryName.isEmpty else { return }

        let sourceFolderPath = oldFolderPath ?? book.folderPath
        let oldTmbDir = TextMouthPaths.tmbPath(folderPath: sourceFolderPath, tmbName: book.tmbDirectoryName)
        try? TextMouthPaths.ensureLibrarySubfolder(newFolderPath)
        let newTmbDir = TextMouthPaths.tmbPath(folderPath: newFolderPath, tmbName: book.tmbDirectoryName)

        guard oldTmbDir != newTmbDir else { return }

        do {
            if FileManager.default.fileExists(atPath: oldTmbDir.path) {
                try FileManager.default.moveItem(at: oldTmbDir, to: newTmbDir)
                let fileName = URL(fileURLWithPath: book.filePath).lastPathComponent
                book.filePath = newTmbDir.appendingPathComponent(fileName).path
            }
        } catch {
            print("Failed to move .tmb package: \(error)")
        }
    }

    // MARK: - Metadata and State Updates

    func updateReadingPosition(bookID: UUID, position: ReadingPosition) {
        library.updateReadingPosition(bookID: bookID, position: position)
        save()
        if let book = library.books.first(where: { $0.id == bookID }) {
            LibraryPersistenceService.saveBookInfo(for: book)
        }
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
