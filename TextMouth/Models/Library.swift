import Foundation

/// Per-folder sort configuration. Stored in library.json keyed by folder path.
struct FolderSortSetting: Codable, Equatable {
    var sortField: LibrarySortField
    var sortAscending: Bool

    /// Default sort: title ascending
    static let defaultSort = FolderSortSetting(sortField: .title, sortAscending: true)

    /// Default sort for the Recent category: last opened descending (newest first)
    static let recentDefault = FolderSortSetting(sortField: .lastOpened, sortAscending: false)
}

struct Library: Codable {
    var books: [Book]
    var folders: [BookFolder]
    /// Per-folder sort settings keyed by folder path (empty string = root).
    /// Folders not in this dictionary use FolderSortSetting.defaultSort.
    var folderSortSettings: [String: FolderSortSetting]

    init(books: [Book] = [], folders: [BookFolder] = [], folderSortSettings: [String: FolderSortSetting] = [:]) {
        self.books = books
        self.folders = folders
        self.folderSortSettings = folderSortSettings
    }

    /// Backward-compatible decoding: folderSortSettings may be absent in older library.json files
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        books = try container.decode([Book].self, forKey: .books)
        folders = try container.decode([BookFolder].self, forKey: .folders)
        folderSortSettings = try container.decodeIfPresent([String: FolderSortSetting].self, forKey: .folderSortSettings) ?? [:]
    }

    // MARK: - Sort Settings

    /// Get the sort setting for a key (folder path or category key),
    /// falling back to the provided default or the global default.
    func sortSetting(for key: String, default fallback: FolderSortSetting = .defaultSort) -> FolderSortSetting {
        folderSortSettings[key] ?? fallback
    }

    /// Update the sort setting for a folder path.
    mutating func setSortSetting(_ setting: FolderSortSetting, for folderPath: String) {
        folderSortSettings[folderPath] = setting
    }

    /// Apply a sort setting to a folder and all its subfolders recursively.
    mutating func applySortToSubfolders(_ setting: FolderSortSetting, from folderPath: String) {
        folderSortSettings[folderPath] = setting
        for folder in folders {
            let path = folder.fullPath
            if path == folderPath || path.hasPrefix(folderPath.isEmpty ? "" : folderPath + "/") {
                // For root (empty folderPath), apply to all folders
                if folderPath.isEmpty || path != folderPath {
                    folderSortSettings[path] = setting
                }
            }
        }
    }

    // MARK: - Book Operations

    mutating func addBook(_ book: Book) {
        // Check for duplicate by MD5 hash
        guard !books.contains(where: { $0.md5Hash == book.md5Hash }) else { return }
        books.append(book)
    }

    mutating func removeBook(id: UUID) {
        books.removeAll { $0.id == id }
    }

    mutating func moveBook(id: UUID, toFolder folderPath: String) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        books[index].folderPath = folderPath
    }

    mutating func updateReadingPosition(bookID: UUID, position: ReadingPosition) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].readingPosition = position
        books[index].lastOpened = Date()
    }

    // MARK: - Bookmark Operations

    mutating func addBookmark(bookID: UUID, chapterIndex: Int, characterOffset: Int, label: String = "") {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        let nextNumber = (books[index].bookmarks.map { $0.number }.max() ?? 0) + 1
        let bookmark = Bookmark(
            number: nextNumber,
            chapterIndex: chapterIndex,
            characterOffset: characterOffset,
            label: label
        )
        books[index].bookmarks.append(bookmark)
    }

    mutating func removeBookmark(bookID: UUID, bookmarkID: UUID) {
        guard let bookIndex = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[bookIndex].bookmarks.removeAll { $0.id == bookmarkID }
        // Renumber bookmarks
        for i in books[bookIndex].bookmarks.indices {
            books[bookIndex].bookmarks[i].number = i + 1
        }
    }

    // MARK: - Folder Operations

    /// Creates a folder, or throws the conflict that prevents it. A parent
    /// path given in another spelling adopts the stored spelling of the
    /// existing folder it names, and a name equivalent to a folder already at
    /// that location is refused under the library volume's rule.
    @discardableResult
    mutating func createFolderThrowing(
        name: String,
        parentPath: String = "",
        equivalence: FolderPathEquivalence = .library
    ) throws(FolderOperationConflict) -> BookFolder {
        guard let name = BookFolder.normalizedName(name) else { throw .invalidName }
        guard BookFolder.isValidLibraryPath(parentPath) else { throw .invalidPath(parentPath) }
        let folder = BookFolder(
            name: name,
            parentPath: storedSpelling(of: parentPath, equivalence: equivalence)
        )
        guard folder.depth <= BookFolder.maxDepth else { throw .tooDeep(folder.fullPath) }
        if let existing = existingFolder(equivalentTo: folder.fullPath, equivalence: equivalence) {
            throw .nameInUse(proposedPath: folder.fullPath, existingPath: existing.fullPath)
        }
        folders.append(folder)
        return folder
    }

    /// Creates a folder, returning nil when `createFolderThrowing` refuses it.
    mutating func createFolder(
        name: String,
        parentPath: String = "",
        equivalence: FolderPathEquivalence = .library
    ) -> BookFolder? {
        try? createFolderThrowing(name: name, parentPath: parentPath, equivalence: equivalence)
    }

    /// Remove a folder, moving its contents to a destination path.
    /// Pass empty string to move contents to library root.
    mutating func removeFolder(id: UUID, movingContentsTo destination: String = "") {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        let folderPath = folder.fullPath

        // The removed folder's own sort setting goes away; the settings of
        // its subfolders move with them.
        folderSortSettings.removeValue(forKey: folderPath)

        // Books and subfolders keep their structure under the destination.
        relocate(FolderSubtree(rootPath: folderPath, equivalence: .caseSensitive), to: destination)

        // Remove only the folder itself (children have been reparented)
        folders.removeAll { $0.id == id }
    }

    /// Remove a folder and ALL its contents (books and subfolders) from the library model.
    /// Does not touch disk — caller is responsible for deleting .tmb packages.
    mutating func removeFolderAndContents(id: UUID) -> [Book] {
        guard let folder = folders.first(where: { $0.id == id }) else { return [] }
        let folderPath = folder.fullPath

        // Collect books that will be removed
        let removedBooks = books.filter {
            $0.folderPath == folderPath || $0.folderPath.hasPrefix(folderPath + "/")
        }

        // Remove those books
        books.removeAll {
            $0.folderPath == folderPath || $0.folderPath.hasPrefix(folderPath + "/")
        }

        // Remove the folder and all subfolders
        folders.removeAll {
            $0.fullPath == folderPath || $0.fullPath.hasPrefix(folderPath + "/")
        }

        // Clean up sort settings for deleted folder tree
        for key in folderSortSettings.keys {
            if key == folderPath || key.hasPrefix(folderPath + "/") {
                folderSortSettings.removeValue(forKey: key)
            }
        }

        return removedBooks
    }

    /// Moves a folder under a new parent, carrying its subfolders, books, and
    /// sort settings along, or throws the conflict that prevents it: a
    /// destination inside the folder itself, a folder at the destination with
    /// an equivalent name, or a subtree that would exceed the depth limit.
    mutating func moveFolderThrowing(
        id: UUID,
        toParentPath newParent: String,
        equivalence: FolderPathEquivalence = .library
    ) throws(FolderOperationConflict) {
        guard BookFolder.isValidLibraryPath(newParent) else { throw .invalidPath(newParent) }
        let (index, folder) = try editableFolder(id: id)
        let parent = storedSpelling(of: newParent, equivalence: equivalence)
        guard !equivalence.areEquivalent(parent, folder.parentPath) else { throw .unchanged }

        let subtree = FolderSubtree(rootPath: folder.fullPath, equivalence: equivalence)
        guard !subtree.contains(parent) else {
            throw .destinationInsideFolder(folderPath: folder.fullPath, destinationPath: parent)
        }
        let newPath = BookFolder(name: folder.name, parentPath: parent).fullPath
        try validateRelocation(of: subtree, to: newPath, vacating: nil)

        // Carry descendants, books, and sort settings along, then reparent
        // the folder itself (its own parent lies outside the moved subtree).
        relocate(subtree, to: newPath)
        folders[index].parentPath = parent
    }

    /// Moves a folder, returning false when `moveFolderThrowing` refuses it.
    @discardableResult
    mutating func moveFolder(
        id: UUID,
        toParentPath newParent: String,
        equivalence: FolderPathEquivalence = .library
    ) -> Bool {
        (try? moveFolderThrowing(id: id, toParentPath: newParent, equivalence: equivalence)) != nil
    }

    /// Renames a folder, carrying its subfolders, books, and sort settings
    /// along, or throws the conflict that prevents it. A case-only or
    /// normalization-only change of the same folder is allowed: the new name
    /// only has to differ from every other folder at that location.
    mutating func renameFolderThrowing(
        id: UUID,
        to newName: String,
        equivalence: FolderPathEquivalence = .library
    ) throws(FolderOperationConflict) {
        guard let sanitized = BookFolder.normalizedName(newName) else { throw .invalidName }
        let (index, folder) = try editableFolder(id: id)
        // Compare exact spellings: turning a decomposed legacy name into its
        // composed form is a real rename, even though Swift's == calls the
        // two names equal.
        guard !BookFolder.spellingsMatch(sanitized, folder.name) else { throw .unchanged }

        let subtree = FolderSubtree(rootPath: folder.fullPath, equivalence: equivalence)
        let newPath = BookFolder(name: sanitized, parentPath: folder.parentPath).fullPath
        try validateRelocation(of: subtree, to: newPath, vacating: nil)

        // Carry descendants, books, and sort settings along, then rename the
        // folder itself.
        relocate(subtree, to: newPath)
        folders[index].name = sanitized
    }

    /// Renames a folder, returning false when `renameFolderThrowing` refuses it.
    @discardableResult
    mutating func renameFolder(
        id: UUID,
        to newName: String,
        equivalence: FolderPathEquivalence = .library
    ) -> Bool {
        (try? renameFolderThrowing(id: id, to: newName, equivalence: equivalence)) != nil
    }

    // MARK: - Folder Path Resolution

    /// The first folder whose path names the same directory as `path` under
    /// `equivalence`.
    func existingFolder(
        equivalentTo path: String,
        equivalence: FolderPathEquivalence = .library
    ) -> BookFolder? {
        let key = equivalence.comparisonKey(for: path)
        return folders.first { equivalence.comparisonKey(for: $0.fullPath) == key }
    }

    /// `path` respelled with the stored spelling of each existing folder it
    /// passes through, so "work/reports" resolves to the "Work/Reports" rows
    /// it names on a case-insensitive volume. Components that match no folder
    /// keep their spelling.
    func storedSpelling(
        of path: String,
        equivalence: FolderPathEquivalence = .library
    ) -> String {
        guard !path.isEmpty else { return path }
        // The first spelling wins, matching the row duplicate repair keeps.
        var spellings: [String: String] = [:]
        for folder in folders {
            let key = equivalence.comparisonKey(for: folder.fullPath)
            if spellings[key] == nil { spellings[key] = folder.fullPath }
        }
        var resolved: [String] = []
        for component in FolderSubtree.components(of: path) {
            let candidate = FolderSubtree.path(from: resolved + [component])
            let stored = spellings[equivalence.comparisonKey(for: candidate)] ?? candidate
            resolved = FolderSubtree.components(of: stored)
        }
        return FolderSubtree.path(from: resolved)
    }

    /// The index and row of the folder with `id`, provided it can be edited.
    /// A folder with an empty stored path would claim every library path as
    /// its subtree, so it is refused instead of relocated.
    private func editableFolder(
        id: UUID
    ) throws(FolderOperationConflict) -> (index: Int, folder: BookFolder) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { throw .folderNotFound }
        guard !folders[index].fullPath.isEmpty else { throw .invalidPath("") }
        return (index, folders[index])
    }

    /// Checks, before anything changes, that relocating every folder in
    /// `subtree` so its root becomes `newRootPath` keeps each folder path
    /// unique under the subtree's rule and within `BookFolder.maxDepth`.
    /// `vacatedID` names a folder the same edit removes, which frees its path.
    /// Parents are checked before children, so a conflict is reported at the
    /// highest level where it occurs.
    private func validateRelocation(
        of subtree: FolderSubtree,
        to newRootPath: String,
        vacating vacatedID: UUID?
    ) throws(FolderOperationConflict) {
        let equivalence = subtree.equivalence
        let travelling = folders.enumerated()
            .filter { $0.element.id != vacatedID && subtree.contains($0.element.fullPath) }
            .sorted { ($0.element.depth, $0.offset) < ($1.element.depth, $1.offset) }
            .map(\.element)
        var departingIDs = Set(travelling.map(\.id))
        if let vacatedID { departingIDs.insert(vacatedID) }

        // Paths of the folders that stay where they are.
        var occupied: [String: String] = [:]
        for folder in folders where !departingIDs.contains(folder.id) {
            let key = equivalence.comparisonKey(for: folder.fullPath)
            if occupied[key] == nil { occupied[key] = folder.fullPath }
        }

        // Claim each destination in turn so two travelling folders can never
        // land on one name either.
        var claimed: [String: String] = [:]
        for folder in travelling {
            guard let newPath = subtree.relocating(folder.fullPath, to: newRootPath) else { continue }
            let newComponents = FolderSubtree.components(of: newPath)
            guard newComponents.count <= BookFolder.maxDepth else { throw .tooDeep(newPath) }
            let key = equivalence.comparisonKey(for: newPath)
            if let existingPath = occupied[key] {
                throw .nameInUse(proposedPath: newPath, existingPath: existingPath)
            }
            if let earlierPath = claimed[key] {
                throw .namesCollide(
                    firstPath: earlierPath,
                    secondPath: folder.fullPath,
                    parentPath: FolderSubtree.path(from: Array(newComponents.dropLast()))
                )
            }
            claimed[key] = folder.fullPath
        }
    }

    /// Rewrites every stored path inside `subtree` so the subtree's root
    /// becomes `newRootPath`: subfolder parents, book folders, and per-folder
    /// sort settings, including the root's own setting. The root folder's row
    /// is left to the caller, which renames, reparents, or removes it.
    private mutating func relocate(_ subtree: FolderSubtree, to newRootPath: String) {
        // A folder with an empty stored path would claim the whole library
        // as its subtree; relocating it would rewrite every path.
        guard !subtree.rootPath.isEmpty else { return }

        for index in folders.indices {
            if let parentPath = subtree.relocating(folders[index].parentPath, to: newRootPath) {
                folders[index].parentPath = parentPath
            }
        }
        for index in books.indices {
            if let folderPath = subtree.relocating(books[index].folderPath, to: newRootPath) {
                books[index].folderPath = folderPath
            }
        }

        // Rebuild the settings in one pass. Category keys such as
        // "__recent__" never match a folder subtree, so they stay put; a
        // relocated setting replaces any stale entry under its new key.
        var relocatedSettings: [String: FolderSortSetting] = [:]
        var otherSettings: [String: FolderSortSetting] = [:]
        for (key, setting) in folderSortSettings {
            if let newKey = subtree.relocating(key, to: newRootPath) {
                relocatedSettings[newKey] = setting
            } else {
                otherSettings[key] = setting
            }
        }
        folderSortSettings = otherSettings.merging(relocatedSettings) { _, relocated in relocated }
    }

    /// Check whether a folder contains any books or subfolders
    func folderHasContents(_ folder: BookFolder) -> Bool {
        let path = folder.fullPath
        let hasBooks = books.contains {
            $0.folderPath == path || $0.folderPath.hasPrefix(path + "/")
        }
        let hasSubfolders = folders.contains { $0.parentPath == path }
        return hasBooks || hasSubfolders
    }

    /// Count all books recursively inside a folder (including subfolders)
    func totalBooksInFolderTree(_ path: String) -> Int {
        books.filter {
            $0.folderPath == path || $0.folderPath.hasPrefix(path + "/")
        }.count
    }

    mutating func updateWordCounts(bookID: UUID, wordCount: Int, charCount: Int) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].totalWordCount = wordCount
        books[index].totalCharacterCount = charCount
    }

    // MARK: - Query

    func booksInFolder(_ path: String) -> [Book] {
        books.filter { $0.folderPath == path }
    }

    /// All books with no folder assignment
    func booksWithNoFolder() -> [Book] {
        books.filter { $0.folderPath.isEmpty }
    }

    func subfolders(of parentPath: String) -> [BookFolder] {
        folders.filter { $0.parentPath == parentPath }.sorted { $0.name < $1.name }
    }

    func bookByHash(_ hash: String) -> Book? {
        books.first { $0.md5Hash == hash }
    }
}
