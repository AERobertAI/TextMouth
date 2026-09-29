import SwiftUI

/// Extension for duplicate detection and resolution during import,
/// zip folder assignment, and original file deletion handling.
extension LibraryViewModel {

    // MARK: - Duplicate Detection

    /// Add a book, checking for duplicates by hash or source path.
    /// Returns true if added immediately, false if a duplicate dialog is shown.
    @discardableResult
    func addBookCheckingDuplicate(
        _ book: Book,
        toFolder folderPath: String,
        originalURL: URL? = nil
    ) -> Bool {
        // Check for existing book with same hash
        if let existing = library.books.first(where: { $0.md5Hash == book.md5Hash }) {
            // Same file content — show replace/duplicate dialog
            pendingDuplicateBook = book
            pendingDuplicateExisting = existing
            pendingDuplicateFolder = folderPath
            pendingDuplicateOriginalURL = originalURL
            showDuplicateDialog = true
            return false
        }

        // Check for existing book imported from the same source path
        if let sourcePath = book.sourceFilePath, !sourcePath.isEmpty,
           let existing = library.books.first(where: { $0.sourceFilePath == sourcePath }) {
            pendingDuplicateBook = book
            pendingDuplicateExisting = existing
            pendingDuplicateFolder = folderPath
            pendingDuplicateOriginalURL = originalURL
            showDuplicateDialog = true
            return false
        }

        library.addBook(book)
        return true
    }

    /// Replace the existing book with the new duplicate (updates .tmb, refreshes timestamp)
    func replaceDuplicate() {
        guard let newBook = pendingDuplicateBook,
              let existing = pendingDuplicateExisting else { return }
        let originalURL = pendingDuplicateOriginalURL

        // Delete old .tmb before changing the library model.
        do {
            try FileImportService.deleteBookPackage(existing)
        } catch {
            presentFilesystemError("Could not replace duplicate", error: error)
            return
        }
        library.removeBook(id: existing.id)

        // Add new book (already has its own .tmb from import)
        library.addBook(newBook)
        save()

        clearDuplicateState()
        if let originalURL {
            handleOriginalFileDeletion(url: originalURL)
        }
    }

    /// Keep both the existing and the new book as separate entries
    func keepDuplicate() {
        guard let newBook = pendingDuplicateBook else { return }
        let originalURL = pendingDuplicateOriginalURL

        // The new book was already imported to its .tmb by importFile,
        // but Library.addBook won't add it because the hash matches.
        // Force-add by appending directly.
        library.books.append(newBook)
        save()

        clearDuplicateState()
        if let originalURL {
            handleOriginalFileDeletion(url: originalURL)
        }
    }

    /// Cancel the duplicate import — remove the newly created .tmb
    func cancelDuplicate() {
        if let newBook = pendingDuplicateBook {
            do {
                try FileImportService.deleteBookPackage(newBook)
            } catch {
                presentFilesystemError("Could not discard duplicate import", error: error)
                return
            }
        }
        clearDuplicateState()
    }

    /// Reset all duplicate-related dialog state
    func clearDuplicateState() {
        pendingDuplicateBook = nil
        pendingDuplicateExisting = nil
        pendingDuplicateFolder = ""
        pendingDuplicateOriginalURL = nil
        showDuplicateDialog = false
    }

    /// Move zip-imported books into a newly created folder
    func moveZipBooksToFolder(folderName: String) {
        guard !folderName.isEmpty else { return }
        let parentPath = pendingZipFolderPath
        var proposed = library
        guard let folder = proposed.createFolder(name: folderName, parentPath: parentPath) else { return }
        // Keeping both copies is supported; their hash cannot identify which
        // copy belongs to this import's organization dialog.
        let affectedIDs = Set(pendingZipBooks.map(\.id))
        for index in proposed.books.indices where affectedIDs.contains(proposed.books[index].id) {
            proposed.books[index].folderPath = folder.fullPath
        }
        do {
            try TextMouthPaths.ensureLibrarySubfolder(folder.fullPath)
            try commitLibraryTransition(proposed, affectedBookIDs: affectedIDs)
            pendingZipBooks = []
        } catch {
            presentFilesystemError("Could not organize imported ZIP books", error: error)
        }
    }

    /// Handle deleting the original file based on user preference
    func handleOriginalFileDeletion(url: URL) {
        let behavior = configService.config.importDeleteBehavior
        switch behavior {
        case .keepOriginal:
            break
        case .deleteAfterImport:
            FileImportService.deleteOriginalFile(at: url)
        case .askEachTime:
            pendingOriginalURL = url
            showDeleteOriginalDialog = true
        }
    }
}
