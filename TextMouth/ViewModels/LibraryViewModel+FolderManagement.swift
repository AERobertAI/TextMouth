import SwiftUI

/// Extension for folder CRUD operations — creating, removing (with content
/// relocation or deletion), moving, renaming, and querying folder contents.
extension LibraryViewModel {

    // MARK: - Folder Operations

    func createFolder(name: String, parentPath: String) {
        // Publish the folder only after its directory exists, matching book
        // moves and renames when storage is unavailable or a file collides.
        var proposed = library
        guard let folder = proposed.createFolder(name: name, parentPath: parentPath) else {
            errorMessage = "Choose a unique folder name without reserved path or package names."
            showError = true
            return
        }
        do {
            try TextMouthPaths.ensureLibrarySubfolder(folder.fullPath)
            library = proposed
            save()
        } catch {
            presentFilesystemError("Could not create folder", error: error)
        }
    }

    /// Remove a folder, moving its contents to the given destination path.
    /// Subfolders are reparented under the destination; books are reassigned.
    /// The folder's disk directory is removed after all contents have been moved out.
    func removeFolderMovingContents(_ folder: BookFolder, toPath destination: String) {
        let oldPath = folder.fullPath
        let affectedBookIDs = Set(library.books.filter {
            $0.folderPath == oldPath || $0.folderPath.hasPrefix(oldPath + "/")
        }.map(\.id))
        var proposed = library
        proposed.removeFolder(id: folder.id, movingContentsTo: destination)

        do {
            for proposedFolder in proposed.folders {
                try TextMouthPaths.ensureLibrarySubfolder(proposedFolder.fullPath)
            }
            try commitLibraryTransition(proposed, affectedBookIDs: affectedBookIDs)
        } catch {
            presentFilesystemError("Could not relocate folder contents", error: error)
        }
    }

    /// Remove a folder and permanently delete all its contents (books, subfolders, .tmb files).
    func removeFolderAndEverything(_ folder: BookFolder) {
        let path = folder.fullPath
        let booksToRemove = library.books.filter {
            $0.folderPath == path || $0.folderPath.hasPrefix(path + "/")
        }
        var failures: [String] = []
        for book in booksToRemove {
            do {
                try FileImportService.deleteBookPackage(book)
                library.removeBook(id: book.id)
            } catch {
                failures.append("\(book.title): \(error.localizedDescription)")
            }
        }

        let folderDiskURL = TextMouthPaths.libraryDir
            .appendingPathComponent(path, isDirectory: true)
        if failures.isEmpty {
            do {
                try FileImportService.removeItemRespectingTrashSetting(at: folderDiskURL)
                _ = library.removeFolderAndContents(id: folder.id)
            } catch {
                failures.append("\(folder.name): \(error.localizedDescription)")
            }
        }
        save()
        if !failures.isEmpty {
            errorMessage = "Some items could not be moved to Trash and remain in the library:\n" + failures.joined(separator: "\n")
            showError = true
        }
    }

    /// Move a folder to a new parent, preserving its internal structure on disk.
    func moveFolder(_ folder: BookFolder, toParent newParentPath: String) {
        let oldPath = folder.fullPath
        let affectedBookIDs = Set(library.books.filter {
            $0.folderPath == oldPath || $0.folderPath.hasPrefix(oldPath + "/")
        }.map(\.id))
        var proposed = library
        guard proposed.moveFolder(id: folder.id, toParentPath: newParentPath) else { return }
        do {
            try commitLibraryTransition(proposed, affectedBookIDs: affectedBookIDs)
        } catch {
            presentFilesystemError("Could not move folder", error: error)
        }
    }

    /// Rename a folder, updating disk directory and all book file paths.
    func renameFolder(_ folder: BookFolder, to newName: String) {
        let oldPath = folder.fullPath
        let affectedBookIDs = Set(library.books.filter {
            $0.folderPath == oldPath || $0.folderPath.hasPrefix(oldPath + "/")
        }.map(\.id))
        var proposed = library
        guard proposed.renameFolder(id: folder.id, to: newName) else { return }
        do {
            try commitLibraryTransition(proposed, affectedBookIDs: affectedBookIDs)
        } catch {
            presentFilesystemError("Could not rename folder", error: error)
        }
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
            return LibraryBookSorter.recent(library.books)
        }
    }
}
