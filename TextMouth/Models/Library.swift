import Foundation

/// Per-folder sort configuration. Stored in library.json keyed by folder
/// path, or by a category's reserved key (see `LibraryLocation`). A window
/// shows it through `LibrarySortState`, which applies the rule for manual
/// order (TODO A06).
struct FolderSortSetting: Codable, Equatable {
    /// The field the books are sorted by. Choosing one clears
    /// `unknownSortField`: a field the user picks replaces any a newer
    /// TextMouth saved.
    var sortField: LibrarySortField {
        didSet { unknownSortField = nil }
    }
    /// The direction of `sortField`. Manual order has no direction, so a
    /// setting whose field is manual ignores this value.
    var sortAscending: Bool
    /// The direction (true for ascending) the location last showed each of
    /// its other fields in, so choosing one again shows it the same way.
    /// Settings saved before TODO A06 have none, and an empty one is not
    /// written, so they read and write exactly as before.
    var rememberedDirections: [LibrarySortField: Bool]
    /// The name of the sort field a newer TextMouth saved that this one does
    /// not know (V03), kept exactly as read so the next save writes it back.
    /// The setting reads as `FolderSortSetting.defaultSort`'s field until a
    /// field is chosen (`sortField`'s `didSet` clears this). Only a decoded
    /// setting holds one; every initializer leaves it nil.
    private var unknownSortField: String?

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

    /// The one order of the Reading List (FR09): the list's own, which the
    /// user arranges, shown as manual order, which has no direction. The
    /// list never sorts by it; it shows its books as the list holds them.
    static let readingListOrder = FolderSortSetting(sortField: .manual, sortAscending: true)

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
    /// skipped instead of failing the whole library index. The setting's own
    /// field, if this version does not know it, is read as the default field
    /// and kept to be written back (`unknownSortField`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A field this TextMouth does not know is not an error (V03): the
        // setting reads as the default field and keeps the name to write back.
        // (Assigning inside an initializer does not run `sortField`'s didSet.)
        let savedField = try container.decode(String.self, forKey: .sortField)
        if let known = LibrarySortField(rawValue: savedField) {
            sortField = known
            unknownSortField = nil
        } else {
            sortField = Self.defaultSort.sortField
            unknownSortField = savedField
        }
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
        try container.encode(unknownSortField ?? sortField.rawValue, forKey: .sortField)
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

/// A row of library.json this TextMouth could not read (V03): a book a later
/// TextMouth wrote, in a format or with fields this one does not know, or a
/// row damaged by hand. It is kept exactly as read, written back at every
/// save, and never shown, counted as a book, opened, or searched. Its
/// package is its own, which the walks of the packages respect.
struct UnreadableLibraryRow: Equatable, Sendable {
    /// The row as the file held it.
    let json: JSONValue

    /// The row's `id`, when it holds one that is a UUID.
    var id: UUID? {
        json["id"]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    /// The name of the row's package folder, when the row names one.
    var tmbDirectoryName: String? {
        json["tmbDirectoryName"]?.stringValue
    }

    /// The library folder the row was filed in, when the row names one.
    var folderPath: String? {
        json["folderPath"]?.stringValue
    }

    /// Reads every remaining element of a `books` array from `container`: an
    /// element that decodes as a `Book` is a book, in order, and any other is
    /// kept as it was in `unreadable`, also in order. A failed decode does not
    /// move an unkeyed container on, so the same element is then read again
    /// as a `JSONValue`.
    ///
    /// Throws when an element cannot be read even as a `JSONValue` (one
    /// nested deeper than `JSONValue.maximumDepth`), as a library that cannot
    /// be read throws. A feed's index may read its rows this way later.
    static func decodeRows(
        from container: inout UnkeyedDecodingContainer
    ) throws -> (books: [Book], unreadable: [UnreadableLibraryRow]) {
        var books: [Book] = []
        var unreadable: [UnreadableLibraryRow] = []
        while !container.isAtEnd {
            if let book = try? container.decode(Book.self) {
                books.append(book)
            } else {
                unreadable.append(UnreadableLibraryRow(json: try container.decode(JSONValue.self)))
            }
        }
        return (books, unreadable)
    }
}

/// The packages that the kept rows of a library (`Library.unreadableRows`)
/// own (V03), and the one place that decides whether a package on disk is
/// one of them. Every walk of the packages (orphan adoption, with the startup
/// repair, Rebuild Directory, and Rebuild Library Index behind it) asks
/// `owns(folderPath:tmbDirectoryName:)` and leaves an owned package alone:
/// it is never adopted as a second book, made a row of, repaired, moved, or
/// deleted.
///
/// A kept row names its package by its `folderPath` and `tmbDirectoryName`
/// when both read, and by `tmbDirectoryName` alone, in any folder, when only
/// that reads (the folder may be the very field the row is unreadable for).
/// A row naming no package owns none. Names and folders are compared the way
/// the library compares folders on a volume that ignores case
/// (`FolderPathEquivalence.caseInsensitive`), and in precomposed form, as a
/// directory listing may spell them differently from the row. That can only
/// own more, never less, which is the safe way to be wrong.
struct KeptRowPackages: Equatable, Sendable {
    /// How names and folders are compared.
    private static let equivalence = FolderPathEquivalence.caseInsensitive

    /// Package names owned in one folder, by the folder's comparison key.
    private let namesByFolder: [String: Set<String>]
    /// Package names owned in any folder, by comparison key: those of rows
    /// that name no folder this TextMouth can read.
    private let namesInAnyFolder: Set<String>

    /// The packages `rows` own.
    init(_ rows: [UnreadableLibraryRow]) {
        var byFolder: [String: Set<String>] = [:]
        var inAnyFolder = Set<String>()
        for row in rows {
            // A row without a package name (a legacy row) owns no package.
            guard let name = row.tmbDirectoryName, !name.isEmpty else { continue }
            let nameKey = Self.equivalence.comparisonKey(for: name)
            if let folder = row.folderPath {
                byFolder[Self.equivalence.comparisonKey(for: folder), default: []].insert(nameKey)
            } else {
                inAnyFolder.insert(nameKey)
            }
        }
        namesByFolder = byFolder
        namesInAnyFolder = inAnyFolder
    }

    /// Whether no row owns a package.
    var isEmpty: Bool {
        namesByFolder.isEmpty && namesInAnyFolder.isEmpty
    }

    /// Whether a kept row owns a package named `tmbDirectoryName`, wherever
    /// it is: for a walk of a folder that is not a library folder, such as a
    /// feed's, where a package is placed by the folder, not by a row's
    /// `folderPath`.
    func owns(tmbDirectoryName: String) -> Bool {
        let nameKey = Self.equivalence.comparisonKey(for: tmbDirectoryName)
        return namesInAnyFolder.contains(nameKey) || namesByFolder.values.contains { $0.contains(nameKey) }
    }

    /// Whether the package named `tmbDirectoryName` in the library folder
    /// `folderPath` ("" for the top of the library) belongs to a kept row.
    func owns(folderPath: String, tmbDirectoryName: String) -> Bool {
        let nameKey = Self.equivalence.comparisonKey(for: tmbDirectoryName)
        if namesInAnyFolder.contains(nameKey) { return true }
        return namesByFolder[Self.equivalence.comparisonKey(for: folderPath)]?.contains(nameKey) ?? false
    }
}

/// The library model: its books, folders, sort settings, reading list, feed
/// shelf, and the rows of library.json this TextMouth could not read, kept
/// as they are.
///
/// Its `==` is the one Swift synthesizes, which compares every stored field
/// (`books`, `folders`, `folderSortSettings`, `readingList`, `feedShelf`,
/// and `unreadableRows`), each with its own synthesized `==`; a field added
/// later is compared too, or the build fails until it can be. Work that runs
/// off the main actor and then publishes a library it made from a snapshot
/// (`LibraryViewModel.library(after:current:)` and
/// `library(afterMoving:from:current:)`) asks this whether anything changed
/// meanwhile, so no change to any part is undone.
struct Library: Codable, Equatable {
    /// The rows of the library model's books: every book of the library's
    /// own, and, while TextMouth runs, the rows of feed items whose files
    /// are here (FR11), which the library's lists and counts leave out
    /// (`libraryBooks`) and library.json never holds (`encode(to:)`).
    var books: [Book]
    var folders: [BookFolder]
    /// Per-folder sort settings keyed by folder path (empty string = root).
    /// Folders not in this dictionary use FolderSortSetting.defaultSort.
    var folderSortSettings: [String: FolderSortSetting]
    /// The reading list (FR09): books from anywhere in the library in the
    /// order the user arranged, with its options. Saved with the index.
    var readingList: ReadingList
    /// The feed items' rows held apart from `books`, and the feeds whose own
    /// indexes the library keeps (FR11). Never written to library.json: each
    /// feed's index holds its rows (`feedIndexRows`).
    var feedShelf: FeedShelf
    /// The rows of library.json this TextMouth could not read, in the order
    /// the file held them (V03). They are written back after the books at
    /// every save, and are never shown or counted. A library that replaces
    /// the one loaded carries these over.
    var unreadableRows: [UnreadableLibraryRow]

    /// How many rows are kept unshown in all: those of library.json and
    /// those of the feeds' indexes (`FeedShelf.unreadableRows`).
    var unreadableRowCount: Int {
        unreadableRows.count + feedShelf.unreadableRowCount
    }

    /// The packages the kept rows of library.json own, which every walk of
    /// the library's packages leaves alone (`KeptRowPackages`).
    var keptRowPackages: KeptRowPackages {
        KeptRowPackages(unreadableRows)
    }

    /// The folder of each kept row of library.json (V03) filed in the folder
    /// at `path` or below it, one entry per row, as the row spells it:
    /// the books a newer TextMouth added there, which Delete Folder counts
    /// and keeps (stable020 review, finding 1). Folders are compared as
    /// `KeptRowPackages` compares them, without regard to case. A row whose
    /// folder does not read is in none.
    func keptRowFolders(inFolderTree path: String) -> [String] {
        unreadableRows.compactMap(\.folderPath).filter {
            FolderPathEquivalence.caseInsensitive.isPath($0, inSubtreeOf: path)
        }
    }

    /// A library of `books` and the rest. The shelf keeps the index of every
    /// feed whose rows are among `books` too, so a feed whose last row later
    /// leaves the library has its index written without it (FR11).
    init(
        books: [Book] = [],
        folders: [BookFolder] = [],
        folderSortSettings: [String: FolderSortSetting] = [:],
        readingList: ReadingList = ReadingList(),
        feedShelf: FeedShelf = FeedShelf(),
        unreadableRows: [UnreadableLibraryRow] = []
    ) {
        self.books = books
        self.folders = folders
        self.folderSortSettings = folderSortSettings
        self.readingList = readingList
        self.feedShelf = feedShelf
        self.unreadableRows = unreadableRows
        for feedID in Set(books.compactMap { $0.feedLink?.feedID }) {
            self.feedShelf.keepIndex(of: feedID)
        }
    }

    // MARK: - Coding

    /// The keys of library.json. The feed shelf has none: it is never
    /// written there.
    private enum CodingKeys: String, CodingKey {
        case books, folders, folderSortSettings, readingList
    }

    /// Backward-compatible decoding: folderSortSettings may be absent in
    /// older library.json files, and the reading list in any written before
    /// it existed (FR09). A reading list that cannot be read at all is left
    /// empty rather than making the whole index unreadable; its own reading
    /// already skips an entry it cannot read and keeps the rest.
    ///
    /// library.json holds only books of the library's own, so every row read
    /// from it is one, without a feed link, whatever a damaged or hand-edited
    /// file says (FR11): only a feed's own index makes a row a feed item's.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // One row at a time, so a row this version cannot read (a format a
        // later TextMouth added) is kept, not fatal (V03).
        var rows = try container.nestedUnkeyedContainer(forKey: .books)
        let decoded = try UnreadableLibraryRow.decodeRows(from: &rows)
        books = decoded.books.map { $0.placedInLibraryFolder() }
        unreadableRows = decoded.unreadable
        folders = try container.decode([BookFolder].self, forKey: .folders)
        folderSortSettings = try container.decodeIfPresent([String: FolderSortSetting].self, forKey: .folderSortSettings) ?? [:]
        readingList = (try? container.decodeIfPresent(ReadingList.self, forKey: .readingList)) ?? ReadingList()
        feedShelf = FeedShelf()
    }

    /// Writes the library as library.json holds it: the books of the
    /// library's own, its folders, sort settings, and reading list, as the
    /// encoding it replaces wrote them, key for key. A feed item's row is
    /// never written here, wherever the library holds it (FR11): every
    /// writer of library.json (saves, checkpoints, the quit flush, retries,
    /// Rebuild Library Index, and the data-directory move) encodes a library
    /// this way, so none can.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // The books, then the rows kept as they were read (V03). Without any
        // kept row this writes exactly what encoding the array wrote.
        var rows = container.nestedUnkeyedContainer(forKey: .books)
        for book in libraryBooks {
            try rows.encode(book)
        }
        for row in unreadableRows {
            try rows.encode(row.json)
        }
        try container.encode(folders, forKey: .folders)
        try container.encode(folderSortSettings, forKey: .folderSortSettings)
        try container.encode(readingList, forKey: .readingList)
    }

    // MARK: - Books and Feed Items (FR11)

    /// The books of the library's own: every row but a feed item's. The
    /// library's lists, counts, and maintenance read these; library.json
    /// holds exactly these.
    var libraryBooks: [Book] {
        books.filter { !$0.isFeedItem }
    }

    /// How many books the library counts: its own, never a feed's items.
    var libraryBookCount: Int {
        books.reduce(0) { $1.isFeedItem ? $0 : $0 + 1 }
    }

    /// Moves every feed item's row from `books` to the shelf (FR11), as the
    /// startup repair does before it reconciles the library's own books with
    /// the Library folder, which a feed item's package is never in.
    mutating func shelveFeedItems() {
        guard books.contains(where: \.isFeedItem) else { return }
        for row in books where row.isFeedItem {
            feedShelf.put(row)
        }
        books.removeAll(where: \.isFeedItem)
    }

    /// Runs `body` on this library with its feed items' rows set aside, and
    /// puts them back after it, as they were (FR11): for a pass that
    /// reconciles the library's own books with the Library folder, as
    /// Rebuild Directory does, which a feed item's package is never in.
    mutating func withFeedItemsSetAside<Result>(_ body: (inout Library) throws -> Result) rethrows -> Result {
        let feedItems = books.filter(\.isFeedItem)
        guard !feedItems.isEmpty else { return try body(&self) }
        books.removeAll(where: \.isFeedItem)
        defer { books.append(contentsOf: feedItems) }
        return try body(&self)
    }

    /// Each feed's rows as its own index keeps them: the feed items among
    /// `books`, then those on the shelf, by feed, and an empty list for each
    /// feed whose index the library keeps but which it holds no row of now,
    /// so that index is written empty. Every writer of a feed's index writes
    /// from this, so a feed whose index file is left alone
    /// (`FeedShelf.indexesLeftAlone`), such as one only in the cloud, is
    /// left out: its rows here stand in for an index this Mac did not read.
    var feedIndexRows: [UUID: [Book]] {
        var rows = Dictionary(uniqueKeysWithValues: feedShelf.indexedFeedIDs.map { ($0, [Book]()) })
        for book in books + feedShelf.rows {
            if let feedID = book.feedLink?.feedID {
                rows[feedID, default: []].append(book)
            }
        }
        for feedID in feedShelf.indexesLeftAlone {
            rows.removeValue(forKey: feedID)
        }
        return rows
    }

    // MARK: - Sort Settings

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
        // Check for duplicate by MD5 hash among the library's own books: a
        // feed item may carry the same file as a book (FR11), as two shows
        // can carry one file.
        guard !books.contains(where: { !$0.isFeedItem && $0.md5Hash == book.md5Hash }) else { return }
        books.append(book)
    }

    /// Takes the book `id` out of the library, and off the reading list
    /// (FR09): every removal of a book from the library, whether its package
    /// is deleted or kept, ends here or in `removeFolderAndContents(id:keepingFolders:)`. A
    /// feed item's row leaving keeps its feed's index, which the next save
    /// writes without it (FR11).
    mutating func removeBook(id: UUID) {
        for feedID in Set(books.filter { $0.id == id }.compactMap { $0.feedLink?.feedID }) {
            feedShelf.keepIndex(of: feedID)
        }
        books.removeAll { $0.id == id }
        readingList.remove([id])
    }

    mutating func moveBook(id: UUID, toFolder folderPath: String) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        books[index].folderPath = folderPath
    }

    /// Saves `position` as the reading position of the book `bookID`, and,
    /// while `markingOpened`, dates the book's last opening now, as a
    /// reader's save does: the book a reader saves a place in is open.
    ///
    /// A place moved for a book nobody opened passes false, so the book's
    /// last-opened date stays the user's own: the one-time move of finished
    /// books to their ends (TODO P07) would otherwise have dated every book
    /// it moves as opened at the user's first launch, for good, and Recently
    /// Opened, the Last Opened sort, and Speak Info's "Last opened" would
    /// all have said so (REV14).
    mutating func updateReadingPosition(bookID: UUID, position: ReadingPosition, markingOpened: Bool = true) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].readingPosition = position
        if markingOpened {
            books[index].lastOpened = Date()
        }
    }

    // MARK: - Bookmark Operations

    /// Adds a bookmark to the book `bookID` at `chapterIndex` and
    /// `characterOffset`, numbered after its others, with `label` and
    /// `anchor`, the words around its place (T06): nil for an audiobook's
    /// bookmark, whose place counts time, and for one made before the
    /// book's text loaded.
    mutating func addBookmark(
        bookID: UUID,
        chapterIndex: Int,
        characterOffset: Int,
        label: String = "",
        anchor: TextAnchor? = nil
    ) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        let nextNumber = (books[index].bookmarks.map { $0.number }.max() ?? 0) + 1
        let bookmark = Bookmark(
            number: nextNumber,
            chapterIndex: chapterIndex,
            characterOffset: characterOffset,
            label: label,
            anchor: anchor
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
    /// The books are those of `booksInFolderTree(_:)`: a feed's items are
    /// never taken, being in no folder (FR11).
    /// The folders `keptFolders` names stay, with their sort settings: those
    /// that still hold a book a newer TextMouth added (V03, stable020
    /// review, finding 1), compared without regard to case, as the walk that
    /// found them on disk compares them
    /// (`FileImportService.removeLibraryFolder(at:folderPath:keepingPackagesOf:keptFolders:removeItem:)`).
    /// Does not touch disk — caller is responsible for deleting .tmb packages.
    mutating func removeFolderAndContents(id: UUID, keepingFolders keptFolders: [String] = []) -> [Book] {
        guard let folder = folders.first(where: { $0.id == id }) else { return [] }
        let folderPath = folder.fullPath

        // Collect books that will be removed, and take exactly those by ID so
        // the books returned and the books removed can never disagree.
        let removedBooks = booksInFolderTree(folderPath)
        let removedIDs = Set(removedBooks.map(\.id))

        // Remove those books, from the library and from the reading list (FR09)
        books.removeAll { removedIDs.contains($0.id) }
        readingList.remove(removedIDs)

        // A path in the tree goes unless a folder kept for its kept rows is it.
        let equivalence = FolderPathEquivalence.caseInsensitive
        let keptKeys = Set(keptFolders.map { equivalence.comparisonKey(for: $0) })
        let goes: (String) -> Bool = { path in
            Self.isPath(path, inTreeAt: folderPath) && !keptKeys.contains(equivalence.comparisonKey(for: path))
        }

        // Remove the folder and all subfolders, but those kept
        folders.removeAll { goes($0.fullPath) }

        // Clean up sort settings for the folders removed
        for key in folderSortSettings.keys where goes(key) {
            folderSortSettings.removeValue(forKey: key)
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
    /// settings and listening options move onto it and the duplicate row is
    /// removed. A surviving folder's own sort setting and listening options
    /// win over a duplicate's. Only the model
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
        // Where each surviving row is, so a duplicate can give it its options.
        var survivorIndices: [String: Int] = [:]
        let visitOrder = folders.indices.sortedStably { (folders[$0].depth, $0) < (folders[$1].depth, $1) }
        for index in visitOrder {
            let folder = folders[index]
            let parentPath = Self.resolve(folder.parentPath, against: survivors, equivalence: equivalence)
            let path = BookFolder(name: folder.name, parentPath: parentPath).fullPath
            let key = equivalence.comparisonKey(for: path)
            if let survivingPath = survivors[key] {
                duplicateIDs.insert(folder.id)
                // The survivor keeps its own listening options; else it takes
                // the first duplicate's that has some (rows are visited in
                // library order), as its sort settings do below.
                if let survivor = survivorIndices[key],
                   folders[survivor].listeningOptions == nil {
                    folders[survivor].listeningOptions = folder.listeningOptions
                }
                repair.merges.append(.init(duplicatePath: folder.fullPath, survivingPath: survivingPath))
            } else {
                survivors[key] = path
                survivorIndices[key] = index
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
        let byLibraryOrder = respelled.sortedStably {
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
            .sortedStably { ($0.element.depth, $0.offset) < ($1.element.depth, $1.offset) }
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

    /// Check whether a folder contains any books or subfolders. A feed's
    /// items are in no folder (FR11), so they never count.
    func folderHasContents(_ folder: BookFolder) -> Bool {
        let path = folder.fullPath
        let hasSubfolders = folders.contains { $0.parentPath == path }
        return hasBooks(inFolderTree: path) || hasSubfolders
    }

    /// Count all books recursively inside a folder (including subfolders):
    /// the library's own, never a feed's items (FR11), which the library
    /// counts as their feeds instead. For the top level ("") it counts the
    /// books there, as it always has; `libraryBookCount` counts them all.
    func totalBooksInFolderTree(_ path: String) -> Int {
        booksInFolderTree(path).count
    }

    /// The library's own books in the folder at `path` and in every folder
    /// below it, in the library's order: never a feed's items, which name
    /// no folder (FR11). For the top level ("") it is the books there only,
    /// as `totalBooksInFolderTree(_:)` has always counted them. The one
    /// place that says what "in a folder's tree" means.
    func booksInFolderTree(_ path: String) -> [Book] {
        books.filter { isInFolderTree($0, at: path) }
    }

    /// Whether any of the library's own books is in the folder at `path` or
    /// below it, by the rule `booksInFolderTree(_:)` states. It stops at the
    /// first book it finds, where asking whether that list is empty would
    /// build the whole list.
    func hasBooks(inFolderTree path: String) -> Bool {
        books.contains { isInFolderTree($0, at: path) }
    }

    /// Whether `path` is `root` itself or a folder below it, at any depth.
    /// Whole path components only: "Essays Old" is not in the tree of
    /// "Essays". The one spelling of this rule, for folders, sort settings,
    /// and books alike.
    static func isPath(_ path: String, inTreeAt root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    /// The rule `booksInFolderTree(_:)` states for one book: a library book
    /// (never a feed's item, which names no folder, FR11) in the folder at
    /// `path` or below it.
    private func isInFolderTree(_ book: Book, at path: String) -> Bool {
        !book.isFeedItem && Self.isPath(book.folderPath, inTreeAt: path)
    }

    mutating func updateWordCounts(bookID: UUID, wordCount: Int, charCount: Int) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].totalWordCount = wordCount
        books[index].totalCharacterCount = charCount
    }

    // MARK: - Query

    /// The library's own books in the folder at `path` ("" for the top
    /// level): never a feed's items, which name no folder (FR11) and which
    /// their feed's folder lists instead
    /// (`LibraryViewModel.feedItems(listedIn:)`).
    func booksInFolder(_ path: String) -> [Book] {
        books.filter { !$0.isFeedItem && $0.folderPath == path }
    }

    /// All books never opened, from the root and every folder: what the
    /// Unopened category lists. A book is unopened while it has no
    /// `lastOpened`, which is what `BookState.isNew` reads too. A feed's
    /// items are left out (FR11): their feed's row stands for them, as the
    /// user asked on October 7.
    func unopenedBooks() -> [Book] {
        books.filter { !$0.isFeedItem && $0.isUnopened }
    }

    func subfolders(of parentPath: String) -> [BookFolder] {
        folders.filter { $0.parentPath == parentPath }.sortedStably { $0.name < $1.name }
    }

    func bookByHash(_ hash: String) -> Book? {
        books.first { $0.md5Hash == hash }
    }
}
