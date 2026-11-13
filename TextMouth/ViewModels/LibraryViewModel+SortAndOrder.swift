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

    /// What VoiceOver says when a book `title` cannot move that way (-1 up,
    /// +1 down): "Dune can't move up." A row's Move Up or Move Down
    /// VoiceOver action is offered only where the book can move, so it says
    /// this only after the list changed; Move Book Up and Move Book Down
    /// from the menu and the keyboard say it when the book is at an edge
    /// (`LibraryViewModel.moveSelection`).
    static func cannotMoveAnnouncement(_ title: String, direction: Int) -> String {
        "\(title) can't move \(direction < 0 ? "up" : "down")."
    }

    /// What VoiceOver says when Move Book Up or Move Book Down is used
    /// where the list shows no order the user arranges, and the way to set
    /// it right, which differs by view. A folder in Folders that is not
    /// sorted by Manual Order is one Sort menu choice away from it. Every
    /// other view (All Items, Unopened, Recently Opened, Feeds, and the
    /// listener's own) mixes the books of many folders, offers no Manual
    /// Order, and cannot be put in one, so it sends the listener to a folder
    /// or the Reading List instead.
    static func noArrangedOrderAnnouncement(at location: LibraryLocation) -> String {
        if location.view.kind == .folders {
            return "Books can be moved only in a folder sorted by Manual Order, and this folder is not. "
                + "Choose Manual Order in the Sort menu, then try again."
        }
        return "Books can't be moved in this view. Go to a folder in Folders, or to the Reading List, then try again."
    }

    /// What VoiceOver says when Move Book Up or Move Book Down is used on a
    /// feed's item in a folder, where it has no place in the order the user
    /// arranges. In the Reading List it moves like any book.
    static func feedItemCannotMoveAnnouncement(_ title: String) -> String {
        "\(title) is an item of a feed, and a feed's items can't be moved."
    }

    /// What VoiceOver says when Move Book Up or Move Book Down is used with
    /// no book selected.
    static let noBookToMoveAnnouncement = "No book is selected. Select the book to move, then try again."

    /// What VoiceOver says when Move Book Up or Move Book Down is used with
    /// several books selected, since a move shifts one book one place.
    static let severalBooksToMoveAnnouncement =
        "Several books are selected, and a move shifts one book at a time. Select just one book, then try again."

    /// The books in `folderPath`, in the folder's manual order exactly as
    /// the list shows it: by manual position, then title, read as
    /// `articles` says, then book ID (`LibraryBookSorter`). Moving a book up
    /// or down, dragging, and Continue to Next Book all follow this one
    /// order.
    static func orderedBooks(in library: Library, folderPath: String, articles: LeadingArticles = .partOfTitle) -> [Book] {
        LibraryBookSorter.sorted(
            library.booksInFolder(folderPath),
            by: .manual,
            ascending: true,
            articles: articles
        )
    }

    /// Moves the book `bookID` one place up (-1) or down (+1) in the manual
    /// order of `folderPath`, as the list shows it with titles read as
    /// `articles` says, and numbers the folder's books in the new order.
    /// Returns what VoiceOver says of the move, or nil when the book can't
    /// move that way.
    @discardableResult
    static func move(
        library: inout Library,
        bookID: UUID,
        direction: Int,
        folderPath: String,
        articles: LeadingArticles = .partOfTitle
    ) -> MoveResult? {
        var books = orderedBooks(in: library, folderPath: folderPath, articles: articles)
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
    /// `orderedBooks(in:folderPath:articles:)`, which is the order the list
    /// shows while it shows the folder in manual order. Returns false,
    /// changing nothing, when an offset is outside the folder.
    @discardableResult
    static func reorder(
        library: inout Library,
        folderPath: String,
        from source: IndexSet,
        to destination: Int,
        articles: LeadingArticles = .partOfTitle
    ) -> Bool {
        var books = orderedBooks(in: library, folderPath: folderPath, articles: articles)
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

    /// Whether the book `bookID` can move one place up (-1) or down (+1) in
    /// the manual order of `folderPath`, as the list shows it with titles
    /// read as `articles` says.
    static func canMove(
        in library: Library,
        bookID: UUID,
        direction: Int,
        folderPath: String,
        articles: LeadingArticles = .partOfTitle
    ) -> Bool {
        let books = orderedBooks(in: library, folderPath: folderPath, articles: articles)
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
        nextBook(after: book, going: .down, skippingFinished: true)
    }

    /// The books after `book` that Continue to Next Book goes through,
    /// finished or not, in its order: the books after it in its folder's
    /// manual order, as the list shows that order
    /// (`ManualBookOrder.orderedBooks`), or, for a feed's item, which names
    /// no folder, the items downloaded that its feed's folder lists after it
    /// (FR11). Empty after the last.
    func laterBooksInFolder(after book: Book) -> [Book] {
        booksBeyond(book, going: .down)
    }

    /// The first of the books beyond `book` going `direction`
    /// (`booksBeyond(_:going:)`), nearest first: when `skippingFinished`, the
    /// first that does not rest at its end (`Book.restsAtEnd`), otherwise the
    /// adjacent one, finished or not. nil when no book qualifies that way.
    func nextBook(after book: Book, going direction: ReadingList.Direction, skippingFinished: Bool) -> Book? {
        booksBeyond(book, going: direction).first { !skippingFinished || !$0.restsAtEnd }
    }

    /// The books beyond `book` going `direction` through the sequence its
    /// folder lists, nearest first: down is the books after it, up the books
    /// before it, read backward. For a plain folder's book the sequence is
    /// its folder's manual order, as the list shows that order
    /// (`ManualBookOrder.orderedBooks`); for a feed's item, which names no
    /// folder, the feed's items as its folder lists them, newest first
    /// (`FeedRecord.listedItems`, FR11), leaving out those whose files are not
    /// here. Empty at that end of the sequence, and for a book the sequence
    /// does not hold.
    func booksBeyond(_ book: Book, going direction: ReadingList.Direction) -> [Book] {
        if let feedID = book.feedLink?.feedID {
            return feedItemBooksBeyond(book, of: feedID, going: direction)
        }
        let folderBooks = ManualBookOrder.orderedBooks(in: library, folderPath: book.folderPath, articles: leadingArticles)
        let beyond = ListNeighbors.beyond(book.id, going: direction, in: folderBooks.map(\.id)) ?? []
        // Each book is found by its ID in the order already in hand.
        let booksByID = Dictionary(folderBooks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return beyond.compactMap { booksByID[$0] }
    }

    /// The downloaded items of the feed `feedID` beyond `book`'s item going
    /// `direction` through the feed's folder listing (`booksBeyond(_:going:)`):
    /// the episodes or articles down or up the list, leaving out those not
    /// downloaded. Empty at that end, and for a feed whose record is gone or
    /// whose listing does not hold the item.
    private func feedItemBooksBeyond(_ book: Book, of feedID: UUID, going direction: ReadingList.Direction) -> [Book] {
        guard let items = feeds.store.record(of: feedID)?.listedItems else { return [] }
        let itemID = book.feedLink?.itemID
        guard let current = items.firstIndex(where: { $0.state.bookID == book.id || $0.id == itemID }) else { return [] }
        // Each item's row, found by one pass over the library.
        let rows = Dictionary(library.books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // The listing's positions stand for its items: the item was found
        // by its book or its item ID, so the search is by position.
        let beyond = ListNeighbors.beyond(current, going: direction, in: Array(items.indices)) ?? []
        return beyond.compactMap { position in
            guard let bookID = items[position].state.bookID, let row = rows[bookID], row.feedLink?.feedID == feedID else { return nil }
            return row
        }
    }

    // MARK: - Sorting a Location

    /// What a title's leading article does in this library's lists: the
    /// Library tab's Leading articles setting (`LeadingArticles`), read
    /// from the app's preferences store, where the settings model writes it,
    /// each time it is asked, so every list, Move Book Up and Move Book
    /// Down, a drag, and Continue to Next Book follow a change at once.
    var leadingArticles: LeadingArticles {
        LeadingArticles.preference.read(from: TextMouthRuntime.current.preferences)
    }

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

    /// Removes the sort saved under `key`, such as a deleted Library view's
    /// ("/views/" and its identity), or a built-in view's that Restore
    /// Default gives back its own, which then shows the sort it shows until
    /// one is chosen. Saves only when a sort was there.
    func removeSortSetting(for key: String) {
        guard library.folderSortSettings[key] != nil else { return }
        library.folderSortSettings[key] = nil
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
        if ManualBookOrder.reorder(library: &library, folderPath: folderPath, from: source, to: destination, articles: leadingArticles) {
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
            folderPath: folderPath,
            articles: leadingArticles
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
            folderPath: folderPath,
            articles: leadingArticles
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

    /// Moves the one book in `selection` one place up (-1) or down (+1) in
    /// the order the window shows at `location` under `sort`, as Move Book
    /// Up and Move Book Down do from the Library menu and the keyboard and
    /// as a row's context menu does, and returns what VoiceOver should say.
    /// A command that cannot act never stays silent, since nothing on the
    /// screen tells a listener it did nothing: the returned sentence says
    /// why, whether there is no order to arrange here, no book or several
    /// are selected, the book is a feed's item, or it is at the edge.
    ///
    /// - Parameters:
    ///   - selection: The IDs of the books selected, never of folders or
    ///     other rows.
    ///   - direction: -1 for up, +1 for down.
    ///   - location: Where the window is.
    ///   - sort: The sort the window shows there.
    func moveSelection(
        _ selection: Set<UUID>,
        direction: Int,
        at location: LibraryLocation,
        sortedBy sort: LibrarySortState
    ) -> String {
        guard let target = location.reorderTarget(sortedBy: sort) else {
            return ManualBookOrder.noArrangedOrderAnnouncement(at: location)
        }
        guard let bookID = selection.first else { return ManualBookOrder.noBookToMoveAnnouncement }
        guard selection.count == 1 else { return ManualBookOrder.severalBooksToMoveAnnouncement }
        let book = bookByID(bookID)
        // A feed's item has no place in a folder's manual order, but the
        // Reading List holds episodes and articles and orders them, as a
        // row's own Move Up and Move Down do: only a folder refuses it.
        if case .folder = target, let book, book.isFeedItem {
            return ManualBookOrder.feedItemCannotMoveAnnouncement(book.title)
        }
        if let result = moveBook(bookID, direction: direction, in: target) {
            return result.announcement
        }
        return ManualBookOrder.cannotMoveAnnouncement(book?.title ?? "The book", direction: direction)
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
