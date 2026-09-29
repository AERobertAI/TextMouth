import SwiftUI

/// Extension for folder CRUD operations — creating, removing (with content
/// relocation or deletion), moving, renaming, and querying folder contents.
extension LibraryViewModel {

    // MARK: - Folder Operations

    /// Create a folder. A refused name (reserved, or equivalent to a folder
    /// already at that location on this volume) is explained with a message
    /// that names the conflict.
    func createFolder(name: String, parentPath: String) {
        // Publish the folder only after its directory exists, matching book
        // moves and renames when storage is unavailable or a file collides.
        var proposed = library
        let folder: BookFolder
        do {
            folder = try proposed.createFolderThrowing(name: name, parentPath: parentPath)
        } catch {
            presentFolderConflict(error, context: "Could not create folder")
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
    /// The whole subtree is validated first: a refused removal explains the
    /// conflict and leaves both the library and the disk untouched. The
    /// folder's disk directory is removed after all contents have been moved out.
    func removeFolderMovingContents(_ folder: BookFolder, toPath destination: String) {
        var proposed = library
        do {
            try proposed.removeFolderThrowing(id: folder.id, movingContentsTo: destination)
        } catch {
            presentFolderConflict(error, context: "Could not delete \"\(folder.name)\" and move its contents")
            return
        }

        do {
            for proposedFolder in proposed.folders {
                try TextMouthPaths.ensureLibrarySubfolder(proposedFolder.fullPath)
            }
            try commitLibraryTransition(proposed, affectedBookIDs: bookIDsChangingFolder(in: proposed))
        } catch {
            presentFilesystemError("Could not relocate folder contents", error: error)
        }
    }

    /// Remove a folder and permanently delete all its contents (books, subfolders, .tmb files).
    func removeFolderAndEverything(_ folder: BookFolder) {
        let path = folder.fullPath
        // Validate again at the destructive boundary: legacy/edited indexes
        // can contain names rejected by today's creation UI, and an open
        // confirmation may refer to a folder moved in another window.
        guard !path.isEmpty, BookFolder.isValidLibraryPath(path),
              library.folders.contains(where: { $0.id == folder.id && $0.fullPath == path }) else {
            errorMessage = "Could not remove folder: its library path is invalid or has changed."
            showError = true
            return
        }
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

    /// Move a folder to a new parent, preserving its internal structure on
    /// disk. A refused move is explained with a message naming the conflict.
    func moveFolder(_ folder: BookFolder, toParent newParentPath: String) {
        var proposed = library
        do {
            try proposed.moveFolderThrowing(id: folder.id, toParentPath: newParentPath)
        } catch {
            presentFolderConflict(error, context: "Could not move \"\(folder.name)\"")
            return
        }
        do {
            try commitLibraryTransition(proposed, affectedBookIDs: bookIDsChangingFolder(in: proposed))
        } catch {
            presentFilesystemError("Could not move folder", error: error)
        }
    }

    /// Rename a folder, updating disk directory and all book file paths. A
    /// refused name is explained with a message naming the conflict.
    func renameFolder(_ folder: BookFolder, to newName: String) {
        let equivalence = FolderPathEquivalence.library
        var proposed = library
        do {
            try proposed.renameFolderThrowing(id: folder.id, to: newName, equivalence: equivalence)
        } catch {
            presentFolderConflict(error, context: "Could not rename \"\(folder.name)\"")
            return
        }
        // The rename just found this folder in the library, so both exist.
        guard let oldPath = library.folders.first(where: { $0.id == folder.id })?.fullPath,
              let newPath = proposed.folders.first(where: { $0.id == folder.id })?.fullPath else { return }

        // A case-only or normalization-only rename still names the same
        // directory on this volume. Rename that directory in place first; the
        // transition then only rewrites the book paths and package records.
        let respellsDirectory = equivalence.areEquivalent(oldPath, newPath)
        var respelled = false
        do {
            if respellsDirectory {
                respelled = try TextMouthPaths.respellLibrarySubfolder(from: oldPath, to: newPath)
            }
            try commitLibraryTransition(
                proposed,
                affectedBookIDs: bookIDsChangingFolder(in: proposed),
                equivalence: equivalence
            )
        } catch {
            if respelled {
                // Best effort: give the directory back its original spelling.
                _ = try? TextMouthPaths.respellLibrarySubfolder(from: newPath, to: oldPath)
            }
            presentFilesystemError("Could not rename folder", error: error)
        }
    }

    /// Check whether a folder has any books or subfolders
    func folderHasContents(_ folder: BookFolder) -> Bool {
        library.folderHasContents(folder)
    }

    /// IDs of books whose folder differs between the published library and
    /// `proposed`, so a transition moves exactly the packages the model
    /// edit moved. Spellings are compared exactly: a case-only or
    /// normalization-only change still counts and rewrites the package record.
    func bookIDsChangingFolder(in proposed: Library) -> Set<UUID> {
        let currentFolderPaths = Dictionary(
            library.books.map { ($0.id, $0.folderPath) },
            uniquingKeysWith: { first, _ in first }
        )
        return Set(proposed.books.compactMap { book in
            guard let currentPath = currentFolderPaths[book.id],
                  !BookFolder.spellingsMatch(currentPath, book.folderPath) else { return nil }
            return book.id
        })
    }

    /// Explains a refused folder edit with a message that names the folders
    /// involved. An unchanged request stays a silent no-op, matching the
    /// sheets, which simply disable their buttons for it.
    func presentFolderConflict(_ conflict: FolderOperationConflict, context: String) {
        guard conflict != .unchanged else { return }
        presentFilesystemError(context, error: conflict)
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
