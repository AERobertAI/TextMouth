import SwiftUI

/// Extension for duplicate detection and resolution during import,
/// zip folder assignment, and original file deletion handling.
extension LibraryViewModel {

    // MARK: - Duplicate Detection

    /// Add a book, checking for duplicates by hash or source path.
    /// Returns true if added immediately, false if a duplicate dialog is shown.
    @discardableResult
    func addBookCheckingDuplicate(_ book: Book, toFolder folderPath: String) -> Bool {
        // Check for existing book with same hash
        if let existing = library.books.first(where: { $0.md5Hash == book.md5Hash }) {
            // Same file content — show replace/duplicate dialog
            pendingDuplicateBook = book
            pendingDuplicateExisting = existing
            pendingDuplicateFolder = folderPath
            showDuplicateDialog = true
            return false
        }

        // Check for existing book imported from the same source path
        if let sourcePath = book.sourceFilePath, !sourcePath.isEmpty,
           let existing = library.books.first(where: { $0.sourceFilePath == sourcePath }) {
            pendingDuplicateBook = book
            pendingDuplicateExisting = existing
            pendingDuplicateFolder = folderPath
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

        // Delete old .tmb
        FileImportService.deleteBookPackage(existing)
        library.removeBook(id: existing.id)

        // Add new book (already has its own .tmb from import)
        library.addBook(newBook)
        save()

        clearDuplicateState()
    }

    /// Keep both the existing and the new book as separate entries
    func keepDuplicate() {
        guard let newBook = pendingDuplicateBook else { return }

        // The new book was already imported to its .tmb by importFile,
        // but Library.addBook won't add it because the hash matches.
        // Force-add by appending directly.
        library.books.append(newBook)
        save()

        clearDuplicateState()
    }

    /// Cancel the duplicate import — remove the newly created .tmb
    func cancelDuplicate() {
        if let newBook = pendingDuplicateBook {
            FileImportService.deleteBookPackage(newBook)
        }
        clearDuplicateState()
    }

    /// Reset all duplicate-related dialog state
    func clearDuplicateState() {
        pendingDuplicateBook = nil
        pendingDuplicateExisting = nil
        pendingDuplicateFolder = ""
        showDuplicateDialog = false
    }

    /// Move zip-imported books into a newly created folder
    func moveZipBooksToFolder(folderName: String) {
        guard !folderName.isEmpty else { return }
        let parentPath = pendingZipFolderPath
        if let folder = library.createFolder(name: folderName, parentPath: parentPath) {
            for book in pendingZipBooks {
                if let idx = library.books.firstIndex(where: { $0.md5Hash == book.md5Hash }) {
                    // Move .tmb on disk BEFORE updating folderPath
                    moveTMBToFolder(book: &library.books[idx], newFolderPath: folder.fullPath)
                    library.books[idx].folderPath = folder.fullPath
                }
            }
        }
        pendingZipBooks = []
        save()
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
