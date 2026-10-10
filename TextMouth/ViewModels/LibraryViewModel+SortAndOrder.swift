import SwiftUI

enum ManualBookOrder {
    /// One book moved one place up or down an order the user arranges: a
    /// folder's manual order, or the reading list (FR09).
    struct MoveResult {
        /// The title of the book moved.
        let movedTitle: String
        /// The title of the book it moved past.
        let adjacentTitle: String
        /// -1 for up, +1 for down.
        let direction: Int
        /// Where the moved book is now in the order, from 0 at the top.
        let newIndex: Int
        /// How many books the order holds, as the list shows it.
        let count: Int

        /// What VoiceOver says of a move made from the Library menu, the
        /// keyboard, or a row's context menu, the same in a folder and in
        /// the reading list: "Moved Bestiary above Almanac", or "Moved
        /// Almanac below Bestiary".
        var announcement: String {
            "Moved \(movedTitle) \(direction < 0 ? "above" : "below") \(adjacentTitle)"
        }

        /// What VoiceOver says of a move made with a row's Move Up or Move
        /// Down VoiceOver action: the book and its new place in the order,
        /// counted from 1 at the top, "Dune, 3 of 12", short enough to hear
        /// after each of many moves in a row.
        var placeAnnouncement: String {
            "\(movedTitle), \(newIndex + 1) of \(count)"
        }
    }

    /// What VoiceOver says when a row's Move Up or Move Down VoiceOver
    /// action finds the book `title` can no longer move that way (-1 up,
    /// +1 down), as when the list changed after the row offered the action:
    /// "Dune can't move up." The action is offered only where the book can
    /// move, so this is said only after such a change.
    static func cannotMoveAnnouncement(_ title: String, direction: Int) -> String {
        "\(title) can't move \(direction < 0 ? "up" : "down")."
    }

    /// The books in `folderPath`, in the folder's manual order exactly as
    /// the list shows it: by manual position, then title, then book ID
    /// (`LibraryBookSorter`). Moving a book up or down, dragging, and
    /// Continue to Next Book all follow this one order.
    static func orderedBooks(in library: Library, folderPath: String) -> [Book] {
        LibraryBookSorter.sorted(
            library.booksInFolder(folderPath),
            by: .manual,
            ascending: true
        )
    }

    @discardableResult
    static func move(
        library: inout Library,
        bookID: UUID,
        direction: Int,
        folderPath: String
    ) -> MoveResult? {
        var books = orderedBooks(in: library, folderPath: folderPath)
        guard let currentIndex = books.firstIndex(where: { $0.id == bookID }) else { return nil }
        let newIndex = currentIndex + direction
        guard books.indices.contains(newIndex) else { return nil }

        let result = MoveResult(
            movedTitle: books[currentIndex].title,
            adjacentTitle: books[newIndex].title,
            direction: direction,
            newIndex: newIndex,
            count: books.count
        )
        books.swapAt(currentIndex, newIndex)
        renumber(books, in: &library)
        return result
    }

    /// Moves the books at `source` to `destination` in the folder's manual
    /// order, as a drag in the list does. The offsets are positions in
    /// `orderedBooks(in:folderPath:)`, which is the order the list shows
    /// while it shows the folder in manual order. Returns false, changing
    /// nothing, when an offset is outside the folder.
    @discardableResult
    static func reorder(
        library: inout Library,
        folderPath: String,
        from source: IndexSet,
        to destination: Int
    ) -> Bool {
        var books = orderedBooks(in: library, folderPath: folderPath)
        guard !source.isEmpty,
              source.allSatisfy({ books.indices.contains($0) }),
              (0...books.count).contains(destination) else { return false }
        books.move(fromOffsets: source, toOffset: destination)
        renumber(books, in: &library)
        return true
    }

    /// Numbers the books of one folder 0, 1, 2… in the order of `ordered`,
    /// which becomes the folder's manual order.
    private static func renumber(_ ordered: [Book], in library: inout Library) {
        let positions = Dictionary(
            ordered.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        for index in library.books.indices {
            if let position = positions[library.books[index].id] {
                library.books[index].manualSortOrder = position
            }
        }
    }

    static func canMove(
        in library: Library,
        bookID: UUID,
        direction: Int,
        folderPath: String
    ) -> Bool {
        let books = orderedBooks(in: library, folderPath: folderPath)
        guard let currentIndex = books.firstIndex(where: { $0.id == bookID }) else { return false }
        return books.indices.contains(currentIndex + direction)
    }
}

/// Extension for sorting, ordering, and reordering books within folders —
/// manual sort order, folder sort settings, and next-book navigation.
extension LibraryViewModel {

    /// The book Continue to Next Book plays after `book`: the first of the
    /// books after it (`laterBooksInFolder(after:)`) that does not rest at
    /// its end (`Book.restsAtEnd`, TODO P07); nil after the last book, and
    /// when only finished books follow it, which `laterBooksInFolder(after:)`
    /// tells apart.
    ///
    /// A finished book once came next like any other: its reader opened and
    /// played it, and Play on a book resting at its end does what its end
    /// did (`ReaderViewModel.playFromTheEnd()`), so every finished book in a
    /// row opened a reader window of its own on the way to the first
    /// unfinished one (REV14). Continue to Next Book passes over them, as the
    /// reading list's Skip Finished Books passes over its finished books.
    func nextBookInFolder(after book: Book) -> Book? {
        laterBooksInFolder(after: book).first { !$0.restsAtEnd }
    }

    /// The books after `book` that Continue to Next Book goes through,
    /// finished or not, in its order: the books after it in its folder's
    /// manual order, as the list shows that order
    /// (`ManualBookOrder.orderedBooks`), or, for a feed's item, which names
    /// no folder, the items downloaded that its feed's folder lists after it
    /// (`laterFeedItems(after:of:)`, FR11). Empty after the last.
    func laterBooksInFolder(after book: Book) -> [Book] {
        if let feedID = book.feedLink?.feedID {
            return laterFeedItems(after: book, of: feedID)
        }
        let folderBooks = ManualBookOrder.orderedBooks(in: library, folderPath: book.folderPath)
        guard let currentIndex = folderBooks.firstIndex(where: { $0.id == book.id }) else { return [] }
        return Array(folderBooks[(currentIndex + 1)...])
    }

    /// The items of the feed `feedID` that its folder lists after `book`'s
    /// item, newest first as the folder lists them (`FeedRecord.listedItems`),
    /// whose files are here (FR11): the episodes or articles down the list,
    /// leaving out those not downloaded. Empty after the last, and for a feed
    /// whose record is gone.
    private func laterFeedItems(after book: Book, of feedID: UUID) -> [Book] {
        guard let items = feeds.store.record(of: feedID)?.listedItems else { return [] }
        let itemID = book.feedLink?.itemID
        guard let current = items.firstIndex(where: { $0.state.bookID == book.id || $0.id == itemID }) else { return [] }
        // Each later item's row, found by one pass over the library.
        let rows = Dictionary(library.books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return items[items.index(after: current)...].compactMap { item in
            guard let bookID = item.state.bookID, let next = rows[bookID], next.feedLink?.feedID == feedID else { return nil }
            return next
        }
    }

    // MARK: - Sorting a Location

    /// The sort `location` shows, restored from the setting saved for it.
    /// Showing a sort never saves it (TODO A06).
    func sortState(at location: LibraryLocation) -> LibrarySortState {
        library.sortState(at: location)
    }

    /// Makes a change the user chose in the Sort menu at `location`, and
    /// saves the result under that location's key: the one path that saves
    /// a sort (TODO A06). The key is the one the change was made in, so no
    /// change can land on a folder or category shown before it, however
    /// fast the window moved on. A change that leaves the sort as it was,
    /// such as reversing manual order, saves nothing, and neither does any
    /// change at the Reading List, which keeps its own order (FR09).
    /// Returns the sort now shown.
    @discardableResult
    func userChangedSort(_ change: LibrarySortChange, at location: LibraryLocation) -> LibrarySortState {
        let shown = sortState(at: location)
        guard !location.keepsItsOwnOrder else { return shown }
        let changed = shown.applying(change)
        if changed != shown {
            setFolderSortSetting(changed.setting, for: location.sortSettingsKey)
        }
        return changed
    }

    /// Update the sort setting for a specific folder path and persist.
    func setFolderSortSetting(_ setting: FolderSortSetting, for folderPath: String) {
        library.setSortSetting(setting, for: folderPath)
        save()
    }

    /// Apply a sort setting to a folder and all its subfolders, then persist.
    func applySortToSubfolders(_ setting: FolderSortSetting, from folderPath: String) {
        library.applySortToSubfolders(setting, from: folderPath)
        save()
    }

    /// Reorder books in a folder by moving from source indices to destination,
    /// as a drag in the list does: the indices are positions in the folder's
    /// manual order as the list shows it. Saves the new order at once.
    func reorderBooksInFolder(folderPath: String, from source: IndexSet, to destination: Int) {
        let before = manualPositions(in: folderPath)
        if ManualBookOrder.reorder(library: &library, folderPath: folderPath, from: source, to: destination) {
            saveManualOrder(in: folderPath, changedFrom: before)
        }
    }

    /// Result of a manual order move, containing info for VoiceOver announcements.
    typealias MoveResult = ManualBookOrder.MoveResult

    /// Move a book up or down by one position within its folder's manual sort order.
    /// direction: -1 for up, +1 for down.
    /// Returns a MoveResult for VoiceOver announcement, or nil if the move was not possible.
    @discardableResult
    func moveBookInManualOrder(bookID: UUID, direction: Int, folderPath: String) -> MoveResult? {
        let before = manualPositions(in: folderPath)
        let result = ManualBookOrder.move(
            library: &library,
            bookID: bookID,
            direction: direction,
            folderPath: folderPath
        )
        if result != nil {
            saveManualOrder(in: folderPath, changedFrom: before)
        }
        return result
    }

    /// Check if a book can be moved up or down in manual sort order.
    func canMoveBookInManualOrder(bookID: UUID, direction: Int, folderPath: String) -> Bool {
        ManualBookOrder.canMove(
            in: library,
            bookID: bookID,
            direction: direction,
            folderPath: folderPath
        )
    }

    // MARK: - Rearranging Where the List Shows an Arranged Order

    /// Moves a book one place up (-1) or down (+1) in `target`: a folder's
    /// manual order, or the reading list (FR09). Move Up and Move Down in a
    /// row's context menu, and Move Book Up and Move Book Down from the
    /// Library menu and the keyboard, all move this way wherever the list
    /// shows an order the user arranges, and announce the result alike
    /// (`MoveResult.announcement`). Returns nil, changing nothing, when the
    /// book cannot move that way.
    @discardableResult
    func moveBook(_ bookID: UUID, direction: Int, in target: LibraryReorderTarget) -> MoveResult? {
        switch target {
        case .folder(let folderPath):
            return moveBookInManualOrder(bookID: bookID, direction: direction, folderPath: folderPath)
        case .readingList:
            guard let way = ReadingList.Direction(step: direction) else { return nil }
            return moveInReadingList(bookID: bookID, direction: way)
        }
    }

    /// Moves the books at `source` to `destination` in `target`, as a drag
    /// in the list does: the offsets are positions in that whole order as
    /// the list shows it, with no search narrowing it.
    func reorderBooks(in target: LibraryReorderTarget, from source: IndexSet, to destination: Int) {
        switch target {
        case .folder(let folderPath):
            reorderBooksInFolder(folderPath: folderPath, from: source, to: destination)
        case .readingList:
            reorderReadingList(from: source, to: destination)
        }
    }

    // MARK: - Saving Manual Order

    /// Each book's manual position in `folderPath`, by ID, to tell after a
    /// rearrangement which books it moved.
    private func manualPositions(in folderPath: String) -> [UUID: Int?] {
        Dictionary(
            library.booksInFolder(folderPath).map { ($0.id, $0.manualSortOrder) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Saves a rearranged folder at once, the same way whether the user
    /// dragged or used Move Book Up and Move Book Down (TODO A06): the
    /// library index, and the record (bookInfo.json) of each book whose
    /// position changed, so the order also survives an index rebuilt from
    /// the books. Rearranging never touches a sort setting, so the folder
    /// stays in manual order.
    private func saveManualOrder(in folderPath: String, changedFrom before: [UUID: Int?]) {
        save()
        for book in library.booksInFolder(folderPath) where before[book.id] != .some(book.manualSortOrder) {
            LibraryPersistenceService.saveBookInfo(for: book)
        }
    }
}
