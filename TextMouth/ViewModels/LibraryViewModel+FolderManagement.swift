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
        do {
            try createFolderReturningFolder(name: name, parentPath: parentPath)
            return .success(nil)
        } catch {
            return error.outcome
        }
    }

    /// Why a folder could not be created: the library refused it, or its
    /// directory could not be made. Either way the library is unchanged.
    enum FolderCreationFailure: Error {
        /// The library refused the folder, for the conflict given.
        case refused(FolderOperationConflict)
        /// The folder's directory could not be made, for the error given.
        case directory(any Error)

        /// The failure as an outcome, worded as the library's error alert
        /// words every failed folder edit.
        var outcome: OperationOutcome {
            switch self {
            case .refused(let conflict):
                return LibraryViewModel.outcome(refusing: conflict, context: "Could not create folder")
            case .directory(let error):
                return .failure("Could not create folder", error)
            }
        }
    }

    /// Creates a folder and returns it, presenting nothing: what
    /// `createFolderReturningOutcome(name:parentPath:)` does, for a caller
    /// that goes on to use the new folder, such as a feed subscribing into a
    /// folder of its own (FR03).
    /// - Throws: `FolderCreationFailure`; the library is then unchanged.
    @discardableResult
    func createFolderReturningFolder(name: String, parentPath: String) throws(FolderCreationFailure) -> BookFolder {
        // Publish the folder only after its directory exists, matching book
        // moves and renames when storage is unavailable or a file collides.
        var proposed = library
        let folder: BookFolder
        do {
            folder = try proposed.createFolderThrowing(name: name, parentPath: parentPath)
        } catch {
            throw .refused(error)
        }
        do {
            try TextMouthPaths.ensureLibrarySubfolder(folder.fullPath)
        } catch {
            throw .directory(error)
        }
        library = proposed
        save()
        return folder
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
    /// them in the words of that mode. The books a newer TextMouth added
    /// there (kept rows, V03) stay: each package where it is, and every
    /// folder holding one, this one included, with its row (stable020
    /// review, finding 1).
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
        // The same rule `removeFolderAndContents` applies afterward, so a
        // package is deleted exactly when its record is dropped (a feed's
        // items, in no folder, are neither).
        let booksToRemove = library.booksInFolderTree(path)
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
                // The folder goes as one item unless it holds a kept row's
                // package or folder; then what is kept stays, and so do the
                // folders holding it, on disk and in the library.
                let stayed = try FileImportService.removeLibraryFolder(
                    at: folderDiskURL,
                    folderPath: path,
                    keepingPackagesOf: library.keptRowPackages,
                    keptFolders: library.keptRowFolders(inFolderTree: path)
                )
                _ = library.removeFolderAndContents(id: folder.id, keepingFolders: stayed)
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
        // directory on this volume. That directory is renamed in place before
        // anything else, and the transition then only rewrites the book paths
        // and package records.
        let respellsDirectory = equivalence.areEquivalent(oldPath, newPath)
        let affectedBookIDs = bookIDsChangingFolder(in: proposed)
        // The books' readers hear that their packages will move before the
        // directory is renamed, so readers playing them stop reading their
        // files first, as the transition's own moves make them do; but only
        // once the transition holds the storage work and the work already
        // under way has finished, since a reader that hears of a move reads
        // nothing of its book until the move is over, and would otherwise
        // wait on Loading for as long as an import or a text extraction ran.
        // They hear that the move is over once the library holds the new
        // paths, or once a rename that failed has given the directory back
        // its spelling (TODO P10).
        var respelledBookIDs: Set<UUID> = []
        defer { bookUpdates.packagesDidMove(respelledBookIDs) }
        var respelled = false
        do {
            try await performLibraryTransition(
                proposed,
                affectedBookIDs: affectedBookIDs,
                equivalence: equivalence,
                beforeMovingPackages: {
                    guard respellsDirectory else { return }
                    respelledBookIDs = affectedBookIDs
                    bookUpdates.packagesWillMove(respelledBookIDs)
                    respelled = try TextMouthPaths.respellLibrarySubfolder(from: oldPath, to: newPath)
                }
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

    /// Whether `folder` holds anything: books or subfolders, or is a feed's
    /// folder (FR03), which holds no book of the library's own, since a feed
    /// item names no folder (FR11), yet lists the feed's items. Delete
    /// Folder… asks first when it does (REV10, item 4), though a feed's own
    /// folder holding nothing more offers Delete Feed… in its place
    /// (`offersDeleteFolder(_:)`, FR14); and Delete Feed… deletes the folder
    /// of a feed it deleted only when nothing else is in it, another feed's
    /// items included (FR14).
    func folderHasContents(_ folder: BookFolder) -> Bool {
        library.folderHasContents(folder) || feeds.store.feed(inFolder: folder.id) != nil
    }

    /// Whether `folder`'s menu offers Delete Folder…: for every folder but a
    /// feed's own folder holding nothing more than the feed's items, whose
    /// feed's commands offer Delete Feed… there instead, so a feed has one
    /// command that deletes it, as the listener asked on October 10 ("make
    /// sure its not duplicating another delete action or anything", FR14).
    /// A feed's folder that also holds books of the library's own, or
    /// folders, as when Feed Info pointed the feed at a folder in use,
    /// offers it too (REV14 feeds 7): its question names the feed, which
    /// stays, without a folder, whichever way the folder goes
    /// (`feedTitles(of:)`).
    func offersDeleteFolder(_ folder: BookFolder) -> Bool {
        feeds.store.feed(inFolder: folder.id) == nil || library.folderHasContents(folder)
    }

    /// The titles of the feeds whose own folder `folder` is, by title
    /// (REV14 feeds 7): the feeds Delete Folder… leaves without a folder,
    /// whichever way it goes, which its questions name.
    func feedTitles(of folder: BookFolder) -> [String] {
        feeds.feeds.filter { $0.folderID == folder.id }.map(\.title)
    }

    /// The titles of the feeds whose folders are inside `folder`, at any
    /// depth, by title (FR14): the feeds the questions before Delete
    /// Folder… name, saying what happens to each.
    func feedTitles(inside folder: BookFolder) -> [String] {
        let inside = folder.fullPath + "/"
        return feeds.feeds.filter { feeds.folderPath(of: $0)?.hasPrefix(inside) == true }.map(\.title)
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

    /// The books a Library window shows at `location`: its view's or
    /// folder's books in the order of the sort it shows (`sortState(at:)`),
    /// titles read as the Leading articles setting says (`leadingArticles`),
    /// narrowed to those `search` finds (`book(_:isFoundBy:articles:)`). An
    /// empty search narrows nothing.
    ///
    /// Each list is derived once and kept until a book is added, removed,
    /// or moved, a field it is sorted, searched, or filtered by changes, the
    /// Leading articles setting changes, or what its view's filter reads
    /// beyond the books changes (TODO PERF10, `LibraryListCache`); any other
    /// change, such as a reading position, reaches the books it returns
    /// without sorting them again. So a window may read it as often as it
    /// draws.
    ///
    /// The Reading List is never sorted: it shows its books in the order
    /// the user arranged (FR09), and a search narrows that order.
    func displayedBooks(at location: LibraryLocation, matching search: String = "") -> [Book] {
        let sort = sortState(at: location)
        let articles = leadingArticles
        // A feed's folder lists its items beside its books (FR11), so which
        // feed the folder shown holds is part of what the list is.
        let feedID = location.view.kind == .folders ? feedID(listedIn: location.folderPath) : nil
        let context = filterContext(for: location)
        let unsearched = LibraryListCache.Key(
            location: location, sort: sort, search: "", feedID: feedID, context: context, articles: articles
        )
        let books = listCache.books(for: unsearched, in: library) {
            let listed = self.books(listedAt: location, context: context, articles: articles)
            return location.keepsItsOwnOrder ? listed : sortedBooks(listed, by: sort, articles: articles)
        }
        guard !search.isEmpty else { return books }
        let query = search.lowercased()
        let searched = LibraryListCache.Key(
            location: location, sort: sort, search: query, feedID: feedID, context: context, articles: articles
        )
        return listCache.books(for: searched, in: library) {
            books.filter { Self.book($0, isFoundBy: query, articles: articles) }
        }
    }

    /// Whether a search for `query`, lowercased already, finds `book`: its
    /// title holds the query, ignoring case, as it is written or, while the
    /// list shows titles with their articles after them, as its row shows
    /// it ("hobbit, the"); or its author does.
    nonisolated static func book(_ book: Book, isFoundBy query: String, articles: LeadingArticles) -> Bool {
        if book.title.lowercased().contains(query) || book.author.lowercased().contains(query) {
            return true
        }
        return articles.rowTitle(of: book)?.lowercased().contains(query) ?? false
    }

    /// How many books are in the folder `path` and every folder below it,
    /// as `Library.totalBooksInFolderTree` counts them, from counts kept for
    /// every folder until a book is added, removed, or moved (TODO PERF10).
    func bookCount(inFolderTree path: String) -> Int {
        listCache.bookCount(inFolderTree: path, in: library)
    }

    /// How many books a newer TextMouth added (kept rows, V03) the folder at
    /// `path` and its subfolders hold, which no list shows: what Delete
    /// Folder's questions say it keeps (stable020 review, finding 1).
    func keptBookCount(inFolderTree path: String) -> Int {
        library.keptRowFolders(inFolderTree: path).count
    }

    /// Sort books as `sort` orders them (TODO A06): the comparator the
    /// location's sort derives, which keeps manual order in the order the
    /// user arranged, titles read as `articles` says, or, when nil, as the
    /// Leading articles setting says (`leadingArticles`). A File Size sort
    /// reads each book's size measured once and kept until its file changes
    /// (TODO PERF10); no other sort reads the disk.
    func sortedBooks(_ books: [Book], by sort: LibrarySortState, articles: LeadingArticles? = nil) -> [Book] {
        let sizes = sort.field == .fileSize ? listCache.fileSizes(of: books) : [:]
        return sort.sorted(books, fileSizes: sizes, articles: articles ?? leadingArticles)
    }

    /// The books, episodes, and articles `location` lists, before sorting
    /// (October 30, 2026, LIBRARY-VIEWS-RESEARCH-2026-10-30.md): in Folders,
    /// the books of the folder shown, and, in a feed's folder, the feed's
    /// downloaded items beside them (FR11); at the Reading List, its books in
    /// its order, which is never sorted (FR09); in a filter view, what its
    /// filter finds among every row of the library
    /// (`LibraryViewFilterEvaluator.items`), reading `context` beside the
    /// books. The views TextMouth ships list exactly what the categories
    /// listed: All Items every book, Unopened every book never opened,
    /// Recently Opened the ten books, episodes, and articles opened last, one
    /// per feed, and Feeds no books; a feed's downloaded items are left out of
    /// All Items, Unopened, and the top of Folders, their feeds' rows
    /// standing for them. A limit chosen by the view's sort ranks the rows by
    /// `sort`, or by the sort saved for the location when nil, so the view
    /// editor counts a draft by its own sort (review of October 31, 2026,
    /// finding 8). A limit breaks ties by title as `articles` reads titles,
    /// or, when nil, as the Leading articles setting says.
    func books(
        listedAt location: LibraryLocation,
        context: LibraryViewFilterContext?,
        sortedBy sort: LibrarySortState? = nil,
        articles: LeadingArticles? = nil
    ) -> [Book] {
        switch location.view.kind {
        case .folders:
            return library.booksInFolder(location.folderPath) + feedItems(listedIn: location.folderPath)
        case .readingList:
            return readingListBooks
        case .filter:
            guard let filter = location.view.filter else { return [] }
            let articles = articles ?? leadingArticles
            return LibraryViewFilterEvaluator.items(
                of: filter,
                in: library.books,
                context: context ?? LibraryViewFilterContext(),
                sorted: { self.sortedBooks($0, by: sort ?? self.sortState(at: location), articles: articles) },
                articles: articles
            )
        }
    }

    /// The books the category `category`'s view, as TextMouth ships it,
    /// lists before sorting (`books(listedAt:context:)`), at `folderPath` in
    /// Folders; the other categories ignore `folderPath`.
    func booksForCategory(_ category: LibraryCategory, folderPath: String) -> [Book] {
        let location = LibraryLocation(category: category, folderPath: folderPath)
        return books(listedAt: location, context: filterContext(for: location))
    }

    /// What the filter of `location`'s view reads beyond the library's books,
    /// gathered now (`LibraryViewFilterContext`): today's date for its date
    /// conditions, the books Books Finished counts, the reading list, the
    /// paths of the folders its conditions name, and the feeds' folders; nil
    /// for Folders and the Reading List, which have no filter.
    func filterContext(for location: LibraryLocation) -> LibraryViewFilterContext? {
        guard let filter = location.view.filter else { return nil }
        return LibraryViewFilterContext(
            for: filter,
            now: Date(),
            calendar: .current,
            finishedIDs: { self.finishedBookIDs() },
            readingListIDs: { Set(self.library.readingList.bookIDs) },
            folderPath: { id in self.library.folders.first { $0.id == id }?.fullPath },
            feedFolderPaths: { self.feedFolderPathsByFeedID() }
        )
    }
}
