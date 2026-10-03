import SwiftUI

/// Extension for folder CRUD operations — creating, removing (with content
/// relocation or deletion), moving, renaming, and querying folder contents.
///
/// Each folder edit a sheet can start comes in two forms (TODO A07). The
/// `...ReturningOutcome` form reports what happened to its caller and
/// presents nothing, so a sheet can stay open with the reason after a
/// failure. The plain form keeps its original behavior for every other
/// caller: it runs the same edit and explains a failure through the
/// library's error alert.
extension LibraryViewModel {

    // MARK: - Folder Operations

    /// Create a folder. A refused name (reserved, or equivalent to a folder
    /// already at that location on this volume) is explained with a message
    /// that names the conflict.
    func createFolder(name: String, parentPath: String) {
        presentFailure(of: createFolderReturningOutcome(name: name, parentPath: parentPath))
    }

    /// Creates a folder and returns what happened, presenting nothing. A
    /// refused name fails with a message naming the conflict, and a
    /// directory that cannot be created fails with the file system's reason;
    /// either way the library is unchanged.
    func createFolderReturningOutcome(name: String, parentPath: String) -> OperationOutcome {
        // Publish the folder only after its directory exists, matching book
        // moves and renames when storage is unavailable or a file collides.
        var proposed = library
        let folder: BookFolder
        do {
            folder = try proposed.createFolderThrowing(name: name, parentPath: parentPath)
        } catch {
            return Self.outcome(refusing: error, context: "Could not create folder")
        }
        do {
            try TextMouthPaths.ensureLibrarySubfolder(folder.fullPath)
            library = proposed
            save()
            return .success(nil)
        } catch {
            return .failure("Could not create folder", error)
        }
    }

    /// Remove a folder, moving its contents to the given destination path.
    /// Subfolders are reparented under the destination; books are reassigned.
    /// The whole subtree is validated first: a refused removal explains the
    /// conflict and leaves both the library and the disk untouched. The
    /// folder's disk directory is removed after all contents have been moved out.
    /// Returns the task doing the work, whose packages move off the main
    /// actor (PERF14); callers need not wait for it.
    @discardableResult
    func removeFolderMovingContents(_ folder: BookFolder, toPath destination: String) -> Task<Void, Never> {
        Task {
            presentFailure(of: await removeFolderMovingContentsReturningOutcome(folder, toPath: destination))
        }
    }

    /// Removes a folder, moving its contents to `destination`, and returns
    /// what happened, presenting nothing. A refused removal changes nothing;
    /// a removal whose packages cannot all move is rolled back. The packages
    /// move off the main actor (`performLibraryTransition`, PERF14).
    func removeFolderMovingContentsReturningOutcome(
        _ folder: BookFolder,
        toPath destination: String
    ) async -> OperationOutcome {
        var proposed = library
        do {
            try proposed.removeFolderThrowing(id: folder.id, movingContentsTo: destination)
        } catch {
            return Self.outcome(
                refusing: error,
                context: "Could not delete \"\(folder.name)\" and move its contents"
            )
        }

        do {
            for proposedFolder in proposed.folders {
                try TextMouthPaths.ensureLibrarySubfolder(proposedFolder.fullPath)
            }
            try await performLibraryTransition(proposed, affectedBookIDs: bookIDsChangingFolder(in: proposed))
            return .success(nil)
        } catch {
            return .failure("Could not relocate folder contents", error)
        }
    }

    /// The removal preferences in force: whether removing a book asks first,
    /// and whether deleted files go to the Trash or are deleted permanently.
    var removalPreferences: RemovalPreferences {
        RemovalPreferences(configService.config)
    }

    /// Remove a folder and delete all its contents (books, subfolders, .tmb
    /// files), to the Trash or permanently as the preference chooses. Items
    /// that cannot be deleted stay in the library, and the error alert names
    /// them in the words of that mode.
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
                removeDeletedBook(book)
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
            let wording = FolderRemovalWording(
                mode: removalPreferences.deletionMode,
                folderName: folder.name,
                bookCount: booksToRemove.count
            )
            errorMessage = wording.failureMessage(failures)
            showError = true
        }
    }

    /// Move a folder to a new parent, preserving its internal structure on
    /// disk. A refused move is explained with a message naming the conflict.
    /// Returns the task doing the work, whose packages move off the main
    /// actor (PERF14); callers need not wait for it.
    @discardableResult
    func moveFolder(_ folder: BookFolder, toParent newParentPath: String) -> Task<Void, Never> {
        Task {
            presentFailure(of: await moveFolderReturningOutcome(folder, toParent: newParentPath))
        }
    }

    /// Moves a folder to a new parent and returns what happened, presenting
    /// nothing. A refused move changes nothing; a move whose packages cannot
    /// all move is rolled back. The packages move off the main actor
    /// (`performLibraryTransition`, PERF14).
    func moveFolderReturningOutcome(_ folder: BookFolder, toParent newParentPath: String) async -> OperationOutcome {
        var proposed = library
        do {
            try proposed.moveFolderThrowing(id: folder.id, toParentPath: newParentPath)
        } catch {
            return Self.outcome(refusing: error, context: "Could not move \"\(folder.name)\"")
        }
        do {
            try await performLibraryTransition(proposed, affectedBookIDs: bookIDsChangingFolder(in: proposed))
            return .success(nil)
        } catch {
            return .failure("Could not move folder", error)
        }
    }

    /// Rename a folder, updating disk directory and all book file paths. A
    /// refused name is explained with a message naming the conflict.
    /// Returns the task doing the work, whose packages move off the main
    /// actor (PERF14); callers need not wait for it.
    @discardableResult
    func renameFolder(_ folder: BookFolder, to newName: String) -> Task<Void, Never> {
        Task {
            presentFailure(of: await renameFolderReturningOutcome(folder, to: newName))
        }
    }

    /// Renames a folder and returns what happened, presenting nothing. A
    /// refused name changes nothing; a rename whose directory or packages
    /// cannot all move is rolled back, directory spelling included. The
    /// packages move off the main actor (`performLibraryTransition`, PERF14).
    func renameFolderReturningOutcome(_ folder: BookFolder, to newName: String) async -> OperationOutcome {
        let equivalence = FolderPathEquivalence.library
        var proposed = library
        do {
            try proposed.renameFolderThrowing(id: folder.id, to: newName, equivalence: equivalence)
        } catch {
            return Self.outcome(refusing: error, context: "Could not rename \"\(folder.name)\"")
        }
        // The rename just found this folder in the library, so both exist;
        // should either be missing, nothing changed, and the outcome says so.
        guard let oldPath = library.folders.first(where: { $0.id == folder.id })?.fullPath,
              let newPath = proposed.folders.first(where: { $0.id == folder.id })?.fullPath else {
            return Self.outcome(refusing: .folderNotFound, context: "Could not rename \"\(folder.name)\"")
        }

        // A case-only or normalization-only rename still names the same
        // directory on this volume. Rename that directory in place first; the
        // transition then only rewrites the book paths and package records.
        let respellsDirectory = equivalence.areEquivalent(oldPath, newPath)
        let affectedBookIDs = bookIDsChangingFolder(in: proposed)
        // Respelling renames the books' directory before the transition runs,
        // so readers playing them stop reading their files first, as the
        // transition's own moves make them do (TODO P10).
        let respelledBookIDs = respellsDirectory ? affectedBookIDs : []
        bookUpdates.packagesWillMove(respelledBookIDs)
        defer { bookUpdates.packagesDidMove(respelledBookIDs) }
        var respelled = false
        do {
            if respellsDirectory {
                respelled = try TextMouthPaths.respellLibrarySubfolder(from: oldPath, to: newPath)
            }
            try await performLibraryTransition(
                proposed,
                affectedBookIDs: affectedBookIDs,
                equivalence: equivalence
            )
            return .success(nil)
        } catch {
            if respelled {
                // Best effort: give the directory back its original spelling.
                _ = try? TextMouthPaths.respellLibrarySubfolder(from: newPath, to: oldPath)
            }
            return .failure("Could not rename folder", error)
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
        presentFailure(of: Self.outcome(refusing: conflict, context: context))
    }

    /// The outcome of a folder edit the library refused: a failure whose
    /// message names the folders involved, or a silent success for an edit
    /// that would leave the folder exactly as it is, which has nothing to
    /// report (the sheets disable their buttons for it).
    nonisolated static func outcome(
        refusing conflict: FolderOperationConflict,
        context: String
    ) -> OperationOutcome {
        conflict == .unchanged ? .success(nil) : .failure(context, conflict)
    }

    /// Legacy: remove folder, moving contents to parent. Returns the task
    /// doing the work; callers need not wait for it.
    @discardableResult
    func removeFolder(_ folder: BookFolder) -> Task<Void, Never> {
        removeFolderMovingContents(folder, toPath: folder.parentPath)
    }

    // MARK: - Folder and Book Queries

    func subfoldersOf(_ path: String) -> [BookFolder] {
        library.subfolders(of: path)
    }

    /// Sort books as `sort` orders them (TODO A06): the comparator the
    /// location's sort derives, which keeps manual order in the order the
    /// user arranged.
    func sortedBooks(_ books: [Book], by sort: LibrarySortState) -> [Book] {
        // Pre-compute file sizes to avoid O(N log N) disk I/O in the sort comparator
        var sizeCache: [UUID: Int] = [:]
        if sort.field == .fileSize {
            for book in books {
                sizeCache[book.id] = LibraryBookSorter.recursiveFileSize(
                    at: URL(fileURLWithPath: book.filePath)
                )
            }
        }

        return sort.sorted(books, fileSizes: sizeCache)
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
