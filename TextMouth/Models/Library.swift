import Foundation

/// Per-folder sort configuration. Stored in library.json keyed by folder
/// path, or by a category's reserved key (see `LibraryLocation`). A window
/// shows it through `LibrarySortState`, which applies the rule for manual
/// order (TODO A06).
struct FolderSortSetting: Codable, Equatable {
    var sortField: LibrarySortField
    /// The direction of `sortField`. Manual order has no direction, so a
    /// setting whose field is manual ignores this value.
    var sortAscending: Bool
    /// The direction (true for ascending) the location last showed each of
    /// its other fields in, so choosing one again shows it the same way.
    /// Settings saved before TODO A06 have none, and an empty one is not
    /// written, so they read and write exactly as before.
    var rememberedDirections: [LibrarySortField: Bool]

    /// A setting that shows `sortField` in the given direction, remembering
    /// `rememberedDirections` for the other fields.
    init(
        sortField: LibrarySortField,
        sortAscending: Bool,
        rememberedDirections: [LibrarySortField: Bool] = [:]
    ) {
        self.sortField = sortField
        self.sortAscending = sortAscending
        self.rememberedDirections = rememberedDirections
    }

    /// Default sort: title ascending
    static let defaultSort = FolderSortSetting(sortField: .title, sortAscending: true)

    /// Default sort for the Recent category: last opened descending (newest first)
    static let recentDefault = FolderSortSetting(sortField: .lastOpened, sortAscending: false)

    /// Default sort for the Unopened category: date added descending (newest
    /// first), since no unopened book has a last-opened date to sort by.
    static let unopenedDefault = FolderSortSetting(sortField: .dateAdded, sortAscending: false)

    /// The setting in the one form a location shows it: manual order is
    /// ascending, because it has no direction, and no direction is
    /// remembered for the field shown or for manual order.
    var normalized: FolderSortSetting {
        FolderSortSetting(
            sortField: sortField,
            sortAscending: sortField.hasDirection ? sortAscending : true,
            rememberedDirections: rememberedDirections.filter { field, _ in
                field != sortField && field.hasDirection
            }
        )
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case sortField, sortAscending, rememberedDirections
    }

    /// Reads a saved setting. Remembered directions are only a convenience,
    /// so a field this version does not know, or a value it cannot read, is
    /// skipped instead of failing the whole library index.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sortField = try container.decode(LibrarySortField.self, forKey: .sortField)
        sortAscending = try container.decode(Bool.self, forKey: .sortAscending)
        let saved = (try? container.decodeIfPresent([String: Bool].self, forKey: .rememberedDirections)) ?? [:]
        rememberedDirections = Dictionary(
            saved.compactMap { name, ascending in
                LibrarySortField(rawValue: name).map { ($0, ascending) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Writes the setting with remembered directions keyed by field name,
    /// and leaves them out when there are none.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sortField, forKey: .sortField)
        try container.encode(sortAscending, forKey: .sortAscending)
        if !rememberedDirections.isEmpty {
            let byName = Dictionary(
                uniqueKeysWithValues: rememberedDirections.map { ($0.key.rawValue, $0.value) }
            )
            try container.encode(byName, forKey: .rememberedDirections)
        }
    }
}

/// What `Library.mergeEquivalentFolders` changed, for logging and for
/// persisting the package records of books that moved.
struct EquivalentFolderRepair: Equatable {
    /// A duplicate folder row folded into the earlier equivalent folder.
    struct Merge: Equatable {
        let duplicatePath: String
        let survivingPath: String
    }

    /// Duplicate rows removed, parents before children.
    var merges: [Merge] = []
    /// Books whose folder path moved onto a surviving folder's spelling.
    var relocatedBookIDs: [UUID] = []
    /// Whether any folder, book, or sort setting changed.
    var changedLibrary = false
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
    /// Every folder gets the setting in the form a location shows it
    /// (`normalized`), so each sorts, and switches fields, exactly as the
    /// folder does. For manual order that copies only the choice of manual
    /// order, never the order of the books: each folder holds different
    /// books and keeps its own order (TODO A06).
    mutating func applySortToSubfolders(_ setting: FolderSortSetting, from folderPath: String) {
        let applied = setting.normalized
        folderSortSettings[folderPath] = applied
        for folder in folders {
            let path = folder.fullPath
            if path == folderPath || path.hasPrefix(folderPath.isEmpty ? "" : folderPath + "/") {
                // For root (empty folderPath), apply to all folders
                if folderPath.isEmpty || path != folderPath {
                    folderSortSettings[path] = applied
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

    /// Removes a folder and moves its books and subfolders, structure intact,
    /// into `destination` (empty for the library root), or throws the
    /// conflict that prevents it. Everything is validated before anything
    /// changes: the destination must be the root or an existing folder outside
    /// the removed subtree, no moved subfolder may land on a name already in
    /// use there or on another moved subfolder's name, and the moved subtree
    /// must stay within `BookFolder.maxDepth`. The removed folder's own name
    /// is free for its contents, because it disappears in the same edit.
    mutating func removeFolderThrowing(
        id: UUID,
        movingContentsTo destination: String = "",
        equivalence: FolderPathEquivalence = .library
    ) throws(FolderOperationConflict) {
        let (_, folder) = try editableFolder(id: id)
        guard BookFolder.isValidLibraryPath(destination) else { throw .invalidPath(destination) }

        // Resolve the destination to the stored spelling of the folder it names.
        let target: String
        if destination.isEmpty {
            target = ""
        } else if let existing = existingFolder(equivalentTo: destination, equivalence: equivalence) {
            target = existing.fullPath
        } else {
            throw .destinationNotFound(destination)
        }

        let subtree = FolderSubtree(rootPath: folder.fullPath, equivalence: equivalence)
        guard !subtree.contains(target) else {
            throw .destinationInsideFolder(folderPath: folder.fullPath, destinationPath: target)
        }
        try validateRelocation(of: subtree, to: target, vacating: folder.id)

        // The removed folder's own sort setting goes away; the settings of
        // its subfolders move with them.
        folderSortSettings = folderSortSettings.filter {
            !equivalence.areEquivalent($0.key, folder.fullPath)
        }

        // Books and subfolders keep their structure under the destination.
        relocate(subtree, to: target)

        // Remove only the folder itself (children have been reparented)
        folders.removeAll { $0.id == folder.id }
    }

    /// Removes a folder, moving its contents to `destination` (the library
    /// root by default). Returns false, changing nothing, when
    /// `removeFolderThrowing` refuses the edit.
    @discardableResult
    mutating func removeFolder(
        id: UUID,
        movingContentsTo destination: String = "",
        equivalence: FolderPathEquivalence = .library
    ) -> Bool {
        (try? removeFolderThrowing(id: id, movingContentsTo: destination, equivalence: equivalence)) != nil
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
        // The first spelling wins, matching the row duplicate repair keeps.
        var spellings: [String: String] = [:]
        for folder in folders {
            let key = equivalence.comparisonKey(for: folder.fullPath)
            if spellings[key] == nil { spellings[key] = folder.fullPath }
        }
        return Self.resolve(path, against: spellings, equivalence: equivalence)
    }

    /// Resolves `path` one component at a time against `spellings`, which
    /// maps comparison keys to stored folder paths, so each prefix takes the
    /// stored spelling of the folder it names. Unmatched components are kept.
    private static func resolve(
        _ path: String,
        against spellings: [String: String],
        equivalence: FolderPathEquivalence
    ) -> String {
        guard !path.isEmpty else { return path }
        var resolved: [String] = []
        for component in FolderSubtree.components(of: path) {
            let candidate = FolderSubtree.path(from: resolved + [component])
            let stored = spellings[equivalence.comparisonKey(for: candidate)] ?? candidate
            resolved = FolderSubtree.components(of: stored)
        }
        return FolderSubtree.path(from: resolved)
    }

    // MARK: - Equivalent Folder Repair

    /// Merges folder rows whose paths name the same directory under
    /// `equivalence`, which older versions could create (`Reports` and
    /// `reports` on a case-insensitive volume). The first row in library
    /// order survives; a later duplicate's books, subfolders, and sort
    /// settings move onto it and the duplicate row is removed. A surviving
    /// folder's own sort setting wins over a duplicate's. Only the model
    /// changes: such rows already share one directory, so nothing on disk
    /// moves or is deleted. Running the repair again changes nothing.
    mutating func mergeEquivalentFolders(
        equivalence: FolderPathEquivalence = .library
    ) -> EquivalentFolderRepair {
        var repair = EquivalentFolderRepair()
        let originalPositions = Dictionary(
            folders.enumerated().map { ($0.element.fullPath, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )

        // Visit parents before children (library order among equals), so a
        // subfolder resolves against its parent's surviving spelling and
        // same-named subfolders of merged duplicates merge as well.
        var survivors: [String: String] = [:]
        var duplicateIDs: Set<UUID> = []
        let visitOrder = folders.indices.sorted { (folders[$0].depth, $0) < (folders[$1].depth, $1) }
        for index in visitOrder {
            let folder = folders[index]
            let parentPath = Self.resolve(folder.parentPath, against: survivors, equivalence: equivalence)
            let path = BookFolder(name: folder.name, parentPath: parentPath).fullPath
            let key = equivalence.comparisonKey(for: path)
            if let survivingPath = survivors[key] {
                duplicateIDs.insert(folder.id)
                repair.merges.append(.init(duplicatePath: folder.fullPath, survivingPath: survivingPath))
            } else {
                survivors[key] = path
                if !BookFolder.spellingsMatch(parentPath, folder.parentPath) {
                    folders[index].parentPath = parentPath
                    repair.changedLibrary = true
                }
            }
        }
        if !duplicateIDs.isEmpty {
            folders.removeAll { duplicateIDs.contains($0.id) }
            repair.changedLibrary = true
        }

        // Books follow their folder onto the surviving spelling. The package
        // already sits in the shared directory; only recorded paths change.
        for index in books.indices {
            let currentPath = books[index].folderPath
            let survivingPath = Self.resolve(currentPath, against: survivors, equivalence: equivalence)
            guard !BookFolder.spellingsMatch(survivingPath, currentPath) else { continue }
            let hasPackage = !books[index].tmbDirectoryName.isEmpty
            let oldPackagePrefix = books[index].tmbDirectory.path + "/"
            books[index].folderPath = survivingPath
            if hasPackage, books[index].filePath.hasPrefix(oldPackagePrefix) {
                let innerPath = books[index].filePath.dropFirst(oldPackagePrefix.count)
                books[index].filePath = books[index].tmbDirectory.path + "/" + innerPath
            }
            repair.relocatedBookIDs.append(books[index].id)
            repair.changedLibrary = true
        }

        // Sort settings keyed by a merged spelling fill in only where the
        // surviving folder has none, earlier duplicate rows first. Root and
        // category keys are not folder paths and stay as they are.
        var settings: [String: FolderSortSetting] = [:]
        var respelled: [(originalKey: String, survivingKey: String, setting: FolderSortSetting)] = []
        for (key, setting) in folderSortSettings {
            let survivingKey = key.isEmpty || !BookFolder.isValidLibraryPath(key)
                ? key
                : Self.resolve(key, against: survivors, equivalence: equivalence)
            if BookFolder.spellingsMatch(survivingKey, key) {
                settings[key] = setting
            } else {
                respelled.append((key, survivingKey, setting))
            }
        }
        let byLibraryOrder = respelled.sorted {
            (originalPositions[$0.originalKey] ?? Int.max, $0.originalKey)
                < (originalPositions[$1.originalKey] ?? Int.max, $1.originalKey)
        }
        for entry in byLibraryOrder where settings[entry.survivingKey] == nil {
            settings[entry.survivingKey] = entry.setting
        }
        if !respelled.isEmpty {
            folderSortSettings = settings
            repair.changedLibrary = true
        }
        return repair
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
