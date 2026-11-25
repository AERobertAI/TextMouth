import Foundation

extension SyncMerge {
    /// What the merged state `winners` does to `library`: the library as it
    /// becomes, the books another device added (their rows, for the host to
    /// give a placeholder package), the books to remove, and which keys were
    /// applied. Pure: the same registers and library always give the same
    /// answer, and applying the same registers again to the library it gave
    /// changes nothing.
    ///
    /// - Parameters:
    ///   - voices: the voices this device has; a book's voice is applied only
    ///     if it is one of them (nil: every voice counts as there). A voice
    ///     the device lacks leaves the book's own voice as it is.
    /// - Note: In `SyncApplication.library` the books to remove are gone and
    ///   the reading list names the books to add, whose rows the host adds
    ///   (so the list is whole once it has). A new book's row has no
    ///   package: its `filePath` and `tmbDirectoryName` are empty, for the
    ///   host to fill when it makes the placeholder.
    static func apply(_ winners: SyncRegisters, to library: Library, voices: Set<String>?) -> SyncApplication {
        var applier = SyncApplier(entries: winners.entries, source: library, voices: voices)
        return applier.run()
    }
}

/// The work of `SyncMerge.apply`, kept in a value so each step is a small function.
private struct SyncApplier {
    let entries: [SyncKey: SyncEntry]
    let source: Library
    let voices: Set<String>?

    /// The library as it is being made.
    var library: Library
    var plan: SyncFolderPlan
    var booksToAdd: [SyncNewBook] = []
    var booksToRemove: [UUID] = []
    var movesPackages = false
    var entriesToRecord: [SyncKey: JSONValue] = [:]
    var appliedKeys: Set<SyncKey> = []

    /// The winning entries of each book, by book.
    private let entriesOfBook: [UUID: [SyncKey: SyncEntry]]

    init(entries: [SyncKey: SyncEntry], source: Library, voices: Set<String>?) {
        self.entries = entries
        self.source = source
        self.voices = voices
        library = source
        plan = SyncFolderPlan(library: source, entries: entries)
        var grouped: [UUID: [SyncKey: SyncEntry]] = [:]
        for (key, entry) in entries { if let book = key.bookID { grouped[book, default: [:]][key] = entry } }
        entriesOfBook = grouped
    }

    /// Applies folders, books, and the reading list, in that order.
    mutating func run() -> SyncApplication {
        applyFolders()
        applyBooks()
        applyReadingList()
        return SyncApplication(
            library: library, booksToAdd: booksToAdd, booksToRemove: booksToRemove,
            movesPackages: movesPackages, entriesToRecord: entriesToRecord, appliedKeys: appliedKeys
        )
    }

    // MARK: - Folders

    /// Puts the planned folders in the library, with the sort settings of the folders that moved.
    private mutating func applyFolders() {
        entriesToRecord.merge(plan.entriesToRecord, uniquingKeysWith: { _, new in new })
        appliedKeys.formUnion(plan.appliedKeys)
        guard plan.changesFolders else { return }
        library.folders = plan.folders
        movesPackages = true
        // A folder's sort setting is named by its path, so it follows the folder.
        var settings: [String: FolderSortSetting] = [:]
        for (path, setting) in source.folderSortSettings {
            if plan.removedPaths.contains(path) { continue }
            settings[plan.renamedPaths[path] ?? path] = setting
        }
        library.folderSortSettings = settings
    }

    // MARK: - Books

    /// Whether a book's removal mark stands: it is later than every other entry of the book.
    private func isRemoved(_ id: UUID) -> Bool {
        guard let mark = entries[.book(id, .presence)], mark.value == .null else { return false }
        let later = (entriesOfBook[id] ?? [:]).values.contains { entry in
            if case .book(_, let field) = entry.key, field == .presence || field == .keep { return false }
            // A bookmark or list place that was only removed is no sign the book lives.
            if entry.value == .null, entry.key.nullIsRemoval { return false }
            return entry.stamp > mark.stamp
        }
        return !later
    }

    /// Removes the books that were removed, changes the others, and adds the books other devices made.
    private mutating func applyBooks() {
        let index = SyncFolderIndex(source.folders)
        var removed: [UUID] = []
        for position in library.books.indices {
            let book = library.books[position]
            if book.isFeedItem { continue }
            if isRemoved(book.id) {
                removed.append(book.id)
                appliedKeys.insert(.book(book.id, .presence))
                continue
            }
            let updated = apply(to: book, folderID: index.id(atPath: book.folderPath))
            if updated != book { library.books[position] = updated }
        }
        booksToRemove = removed.sorted { $0.uuidString < $1.uuidString }
        for id in booksToRemove {
            library.removeBook(id: id)
            movesPackages = true
        }
        addNewBooks()
    }

    /// Changes `book`, a row of this library, to what the winners say.
    private mutating func apply(to book: Book, folderID: UUID?) -> Book {
        var book = book
        let id = book.id
        // The details and settings, each only when its value differs.
        for field in SyncBookValues.rowFields {
            guard let entry = entries[.book(id, field)] else { continue }
            if field == .voice, let voice = entry.value.stringValue, let voices, !voices.contains(voice) { continue }
            if SyncBookValues.value(of: field, in: book) != entry.value {
                guard SyncBookValues.set(field, to: entry.value, in: &book) else { continue }
            }
            if entry.byHand, let edited = SyncBookValues.metadataField(of: field), book.handEdits?.contains(edited) != true {
                book.markEditedByHand([edited])
            }
            appliedKeys.insert(entry.key)
        }
        applyFolder(to: &book, folderID: folderID)
        applyBookmarks(to: &book)
        appliedKeys.insert(.book(id, .presence))
        return book
    }

    /// Moves `book` to the folder the winners and the folder plan say.
    private mutating func applyFolder(to book: inout Book, folderID: UUID?) {
        var target = folderID
        let entry = entries[.book(book.id, .folder)]
        if let entry {
            switch entry.value {
            case .null: target = nil
            case .string:
                // A folder nothing knows leaves the book where it is.
                guard let named = SyncValueCoding.uuid(from: entry.value), plan.knows(named) else { return }
                target = named
            default: return
            }
        } else if target == nil {
            return
        }
        // A book put in a folder that was folded is recorded in the folder it went to.
        if let named = target, let keeper = plan.redirect[named] {
            entriesToRecord[.book(book.id, .folder)] = SyncValueCoding.id(plan.landing(keeper))
        }
        let path = plan.path(landingOf: target)
        if book.folderPath != path {
            book.folderPath = path
            movesPackages = true
        }
        if let entry { appliedKeys.insert(entry.key) }
    }

    /// Adds, changes, and removes the bookmarks of `book` as the winners say.
    private mutating func applyBookmarks(to book: inout Book) {
        var changed = false
        for (key, entry) in entriesOfBook[book.id] ?? [:] {
            guard case .bookmark(_, let bookmarkID) = key else { continue }
            appliedKeys.insert(key)
            let position = book.bookmarks.firstIndex { $0.id == bookmarkID }
            if entry.value == .null {
                if let position { book.bookmarks.remove(at: position); changed = true }
                continue
            }
            guard let value = SyncValueCoding.decode(SyncBookmarkValue.self, from: entry.value) else {
                appliedKeys.remove(key)
                continue
            }
            if let position {
                // Only a bookmark that differs is replaced, keeping the keys it holds that this version does not know.
                if SyncValueCoding.json(SyncBookmarkValue(book.bookmarks[position])) != entry.value {
                    var bookmark = book.bookmarks[position]
                    bookmark.chapterIndex = value.chapterIndex
                    bookmark.characterOffset = value.characterOffset
                    bookmark.label = value.label
                    bookmark.dateCreated = value.dateCreated
                    bookmark.anchor = value.anchor
                    book.bookmarks[position] = bookmark
                    changed = true
                }
            } else {
                book.bookmarks.append(value.bookmark(id: bookmarkID, number: 0))
                changed = true
            }
        }
        guard changed else { return }
        // Numbered by date, then ID, so every device numbers them alike.
        book.bookmarks.sort { ($0.dateCreated, $0.id.uuidString) < ($1.dateCreated, $1.id.uuidString) }
        for number in book.bookmarks.indices { book.bookmarks[number].number = number + 1 }
    }

    // MARK: - New books

    /// Makes a row for each live book that another device added and this library lacks.
    private mutating func addNewBooks() {
        let known = Set(source.books.map(\.id))
        let ownHashes = Set(source.books.filter { !$0.isFeedItem }.map(\.md5Hash))
        var candidates: [SyncNewBook] = []
        for (id, group) in entriesOfBook where !known.contains(id) {
            guard let presence = group[.book(id, .presence)], presence.value != .null || !isRemoved(id),
                  let contentEntry = group[.book(id, .content)],
                  let content = SyncValueCoding.decode(SyncContent.self, from: contentEntry.value) else { continue }
            // A book this library has under another ID (imported on both devices) stays one book here.
            if !content.md5Hash.isEmpty, ownHashes.contains(content.md5Hash) { continue }
            var book = Book(
                id: id, title: "", format: content.format, filePath: "", md5Hash: content.md5Hash,
                dateAdded: content.dateAdded, totalWordCount: content.totalWordCount, audioDuration: content.audioDuration
            )
            book = apply(to: book, folderID: nil)
            appliedKeys.formUnion([.book(id, .content), .book(id, .presence)])
            candidates.append(SyncNewBook(book: book, content: content))
        }
        // Oldest first, so every device adds them in one order.
        booksToAdd = candidates.sorted { ($0.content.dateAdded, $0.book.id.uuidString) < ($1.content.dateAdded, $1.book.id.uuidString) }
        if !booksToAdd.isEmpty { movesPackages = true }
    }

    // MARK: - The reading list

    /// Orders the reading list by the winners' keys, and sets its options.
    private mutating func applyReadingList() {
        let present = Set(library.books.filter { !$0.isFeedItem }.map(\.id)).union(booksToAdd.map(\.book.id))
        var keyed: [SyncOrderKey.SortKey: UUID] = [:]
        var withEntry = Set<UUID>()
        for (key, entry) in entries {
            guard case .readingList(let book) = key, present.contains(book) else { continue }
            appliedKeys.insert(key)
            withEntry.insert(book)
            if let order = entry.value.stringValue {
                keyed[SyncOrderKey.SortKey(key: order, id: book.uuidString)] = book
            }
        }
        // Books the winners place, in key order; then this library's own, which they say nothing of.
        var order = keyed.keys.sorted().compactMap { keyed[$0] }
        order += source.readingList.bookIDs.filter { present.contains($0) && !withEntry.contains($0) }

        var list = ReadingList(
            bookIDs: order,
            continuation: option(.continuation).flatMap { $0.stringValue.flatMap(ReadingList.Continuation.init(rawValue:)) } ?? source.readingList.continuation,
            skipsFinished: option(.skipsFinished).flatMap(flag(in:)) ?? source.readingList.skipsFinished,
            removesFinished: option(.removesFinished).flatMap(flag(in:)) ?? source.readingList.removesFinished
        )
        list.unknownKeys = source.readingList.unknownKeys
        library.readingList = list
    }

    /// The winning value of a reading list option, noting that it was applied.
    private mutating func option(_ option: SyncListOption) -> JSONValue? {
        guard let entry = entries[.readingListOption(option)] else { return nil }
        appliedKeys.insert(entry.key)
        return entry.value
    }

    /// The flag a value holds, or nil for any other value.
    private func flag(in value: JSONValue) -> Bool? {
        if case .bool(let flag) = value { return flag }
        return nil
    }
}
