import SwiftUI

/// Extension for folder CRUD operations — creating, removing (with content
/// relocation or deletion), moving, renaming, and querying folder contents.
extension LibraryViewModel {

    // MARK: - Folder Operations

    func createFolder(name: String, parentPath: String) {
        // Strip filesystem-unsafe characters (/ is used as internal path separator)
        let sanitized = name.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return }
        if let folder = library.createFolder(name: sanitized, parentPath: parentPath) {
            try? TextMouthPaths.ensureLibrarySubfolder(folder.fullPath)
        }
        save()
    }

    /// Remove a folder, moving its contents to the given destination path.
    /// Subfolders are reparented under the destination; books are reassigned.
    /// The folder's disk directory is removed after all contents have been moved out.
    func removeFolderMovingContents(_ folder: BookFolder, toPath destination: String) {
        // Move .tmb packages on disk for books being reassigned.
        // Capture old folder paths BEFORE the model update changes them.
        let oldPath = folder.fullPath
        let booksToReassign = library.books.filter {
            $0.folderPath == oldPath || $0.folderPath.hasPrefix(oldPath + "/")
        }
        let oldFolderPaths = Dictionary(uniqueKeysWithValues: booksToReassign.map { ($0.id, $0.folderPath) })
        library.removeFolder(id: folder.id, movingContentsTo: destination)
        // Move disk locations using the captured old paths
        for (bookID, oldBookFolderPath) in oldFolderPaths {
            if let idx = library.books.firstIndex(where: { $0.id == bookID }) {
                let newFolderPath = library.books[idx].folderPath
                moveTMBToFolder(book: &library.books[idx], newFolderPath: newFolderPath, oldFolderPath: oldBookFolderPath)
            }
        }
        // Ensure destination subfolder directories exist on disk
        for f in library.folders {
            try? TextMouthPaths.ensureLibrarySubfolder(f.fullPath)
        }
        // Remove the now-empty folder directory from disk
        let folderDiskURL = TextMouthPaths.libraryDir
            .appendingPathComponent(oldPath, isDirectory: true)
        FileImportService.removeItemRespectingTrashSetting(at: folderDiskURL)
        save()
    }

    /// Remove a folder and permanently delete all its contents (books, subfolders, .tmb files).
    func removeFolderAndEverything(_ folder: BookFolder) {
        let removedBooks = library.removeFolderAndContents(id: folder.id)
        // Delete .tmb packages from disk (respects trash setting)
        for book in removedBooks {
            FileImportService.deleteBookPackage(book)
        }
        // Remove the folder's disk directory
        let folderDiskURL = TextMouthPaths.libraryDir
            .appendingPathComponent(folder.fullPath, isDirectory: true)
        FileImportService.removeItemRespectingTrashSetting(at: folderDiskURL)
        save()
    }

    /// Move a folder to a new parent, preserving its internal structure on disk.
    func moveFolder(_ folder: BookFolder, toParent newParentPath: String) {
        let oldPath = folder.fullPath
        guard library.moveFolder(id: folder.id, toParentPath: newParentPath) else { return }
        let newPath = newParentPath.isEmpty ? folder.name : "\(newParentPath)/\(folder.name)"

        // Move the disk directory
        let oldDiskURL = TextMouthPaths.libraryDir.appendingPathComponent(oldPath, isDirectory: true)
        try? TextMouthPaths.ensureLibrarySubfolder(newParentPath)
        let newDiskURL = TextMouthPaths.libraryDir.appendingPathComponent(newPath, isDirectory: true)
        var diskMoveSucceeded = false
        if FileManager.default.fileExists(atPath: oldDiskURL.path), oldDiskURL != newDiskURL {
            do {
                try FileManager.default.moveItem(at: oldDiskURL, to: newDiskURL)
                diskMoveSucceeded = true
            } catch {
                print("Failed to move folder on disk: \(error)")
            }
        }

        // Only update filePath if the disk move actually succeeded, otherwise
        // the file is still at the old location and updating filePath would break it
        if diskMoveSucceeded {
            for i in library.books.indices {
                let book = library.books[i]
                if book.folderPath == newPath || book.folderPath.hasPrefix(newPath + "/") {
                    if !book.tmbDirectoryName.isEmpty {
                        let tmbDir = TextMouthPaths.tmbPath(
                            folderPath: book.folderPath,
                            tmbName: book.tmbDirectoryName
                        )
                        let fileName = URL(fileURLWithPath: book.filePath).lastPathComponent
                        library.books[i].filePath = tmbDir.appendingPathComponent(fileName).path
                    }
                }
            }
        }
        save()
    }

    /// Rename a folder, updating disk directory and all book file paths.
    func renameFolder(_ folder: BookFolder, to newName: String) {
        let oldPath = folder.fullPath
        guard library.renameFolder(id: folder.id, to: newName) else { return }

        // Compute the new path after the model update
        let sanitized = newName.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let newPath = folder.parentPath.isEmpty ? sanitized : "\(folder.parentPath)/\(sanitized)"

        // Rename the disk directory
        let oldDiskURL = TextMouthPaths.libraryDir.appendingPathComponent(oldPath, isDirectory: true)
        let newDiskURL = TextMouthPaths.libraryDir.appendingPathComponent(newPath, isDirectory: true)
        var diskRenameSucceeded = false
        if FileManager.default.fileExists(atPath: oldDiskURL.path), oldDiskURL != newDiskURL {
            do {
                try FileManager.default.moveItem(at: oldDiskURL, to: newDiskURL)
                diskRenameSucceeded = true
            } catch {
                print("Failed to rename folder on disk: \(error)")
            }
        }

        // Only update filePath if the disk rename succeeded
        if diskRenameSucceeded {
            for i in library.books.indices {
                let book = library.books[i]
                if book.folderPath == newPath || book.folderPath.hasPrefix(newPath + "/") {
                    if !book.tmbDirectoryName.isEmpty {
                        let tmbDir = TextMouthPaths.tmbPath(
                            folderPath: book.folderPath,
                            tmbName: book.tmbDirectoryName
                        )
                        let fileName = URL(fileURLWithPath: book.filePath).lastPathComponent
                        library.books[i].filePath = tmbDir.appendingPathComponent(fileName).path
                    }
                }
            }
        }
        save()
    }

    /// Check whether a folder has any books or subfolders
    func folderHasContents(_ folder: BookFolder) -> Bool {
        library.folderHasContents(folder)
    }

    /// Legacy: remove folder, moving contents to parent
    func removeFolder(_ folder: BookFolder) {
        removeFolderMovingContents(folder, toPath: folder.parentPath)
    }

    // MARK: - Folder and Book Queries

    func subfoldersOf(_ path: String) -> [BookFolder] {
        library.subfolders(of: path)
    }

    /// Sort books by the given field and direction
    func sortedBooks(_ books: [Book], by field: LibrarySortField, ascending: Bool) -> [Book] {
        // Pre-compute file sizes to avoid O(N log N) disk I/O in the sort comparator
        var sizeCache: [UUID: Int] = [:]
        if field == .fileSize {
            for book in books {
                sizeCache[book.id] = LibraryBookSorter.recursiveFileSize(
                    at: URL(fileURLWithPath: book.filePath)
                )
            }
        }

        return LibraryBookSorter.sorted(
            books,
            by: field,
            ascending: ascending,
            fileSizes: sizeCache
        )
    }

    /// Return books matching the given library category within a folder path
    func booksForCategory(_ category: LibraryCategory, folderPath: String) -> [Book] {
        switch category {
        case .folders:
            return library.booksInFolder(folderPath)
        case .allItems:
            return library.books
        case .noFolder:
            return library.booksWithNoFolder()
        case .recent:
            return library.books
                .filter { $0.lastOpened != nil }
                .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
                .prefix(10)
                .map { $0 }
        }
    }
}
