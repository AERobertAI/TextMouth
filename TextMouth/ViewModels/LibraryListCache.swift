import Foundation

/// The lists Library windows show, each derived once and kept until
/// something it depends on changes (TODO PERF10).
///
/// A Library window reads its list several times each time it draws (the
/// summary bar, the header's count, the rotor, the rows, and the focus
/// checks), and it draws again after every change of the library. Every
/// read used to filter and sort the whole library again: seven or eight
/// derivations per change, a moved reading position included. Now each list
/// is derived once, here, and every later read gets the same books until a
/// change it depends on:
///
/// - **Membership**: which books there are and where, that is their IDs,
///   their order in the library, and their folders; and which books the
///   reading list holds, in its order (FR09).
/// - **Sort keys**: a field a sort, the Recent category, or a search reads:
///   the title, the author, the metadata language (whose articles a title
///   may be sorted without, `LeadingArticles`), the dates added and last
///   opened, the manual order, and the book's file (its path and content
///   hash, which the size a File Size sort measures follows).
///
/// A list is also keyed by the Leading articles setting it was sorted
/// under, so changing the setting derives each list again.
///
/// Such a change bumps the list revision, which drops every list. Any other
/// change, such as a reading position, a word count, or a voice setting,
/// keeps every list's order and only refreshes its books' values, so rows
/// show the change without the library being filtered or sorted again.
///
/// Folder counts (`bookCount(inFolderTree:in:)`) are counted for every
/// folder in one pass per list revision, and the sizes File Size sorts by
/// are measured once per book and kept until its file changes.
///
/// Main-actor isolated, like the library model that owns it. It publishes
/// nothing: a window reading its list while SwiftUI draws may derive and
/// store it, and must not send a change notification then.
@MainActor
final class LibraryListCache {

    /// What one list is: where it is, the order it shows, and the search
    /// narrowing it.
    struct Key: Hashable {
        /// The view shown.
        let view: LibraryViewID
        /// The view's filter, so a list whose filter changed is derived
        /// again; nil for Folders and the Reading List.
        let filter: LibraryViewFilter?
        /// What the filter reads beyond the library's books (today's date,
        /// the finished books, folders' paths), so a list derived before any
        /// of it changed is derived again; nil without a filter.
        let context: LibraryViewFilterContext?
        /// The folder shown in Folders; "" in every other view, whose books
        /// do not depend on it.
        let folderPath: String
        /// The field the books are sorted by.
        let field: LibrarySortField
        /// Whether the books run ascending.
        let isAscending: Bool
        /// The search, lowercased as the list matches it; "" for none.
        let search: String
        /// The feed whose folder is shown in Folders, whose items the list
        /// holds beside the folder's books (FR11); nil for any other place.
        /// A feed given another folder, or the feeds' records loading after
        /// the library, changes it, so the list is derived again although no
        /// book changed.
        let feedID: UUID?
        /// How titles are read (the Leading articles setting), which a sort,
        /// a tie broken by title, and a search all follow, so a list derived
        /// before the setting changed is derived again.
        let articles: LeadingArticles

        /// The list at `location`, in `sort`'s order, narrowed by `search`
        /// (already lowercased; "" for none), holding the items of the feed
        /// `feedID` when the folder shown is that feed's, its filter reading
        /// `context` (`LibraryViewModel.filterContext(for:)`), its titles
        /// read as `articles` says.
        init(
            location: LibraryLocation,
            sort: LibrarySortState,
            search: String,
            feedID: UUID? = nil,
            context: LibraryViewFilterContext? = nil,
            articles: LeadingArticles = .partOfTitle
        ) {
            let showsFolders = location.view.kind == .folders
            view = location.view.id
            filter = location.view.filter
            self.context = context
            folderPath = showsFolders ? location.folderPath : ""
            field = sort.field
            isAscending = sort.isAscending
            self.search = search
            self.feedID = showsFolders ? feedID : nil
            self.articles = articles
        }
    }

    /// One derived list: its books' IDs in order, and the books' values as
    /// of a content revision.
    private struct Entry {
        /// The books' IDs, in the list's order.
        let ids: [UUID]
        /// The books, as the library held them at `contentRevision`.
        var books: [Book]
        /// The content revision `books` reflects.
        var contentRevision: Int
    }

    /// A size measured for File Size sorts, and the file it was measured
    /// from: a book whose path or content hash changed is measured again.
    private struct MeasuredSize {
        let filePath: String
        let md5Hash: String
        let bytes: Int
    }

    /// At most this many lists are kept. Every keystroke of a search makes
    /// a list of its own, so past this the cache starts over rather than
    /// grow without bound.
    static let entryLimit = 32

    /// How many lists were derived: each a filter and sort of the library's
    /// books, or a search of a list already derived. Tests and benchmarks
    /// read it to see which reads derived and which reused.
    private(set) var derivationCount = 0
    /// How many files File Size sorts measured. Tests read it.
    private(set) var fileMeasurementCount = 0
    /// Bumped by every change of membership or of a sort key, which drops
    /// every list.
    private(set) var listRevision = 0
    /// Bumped by every change of the library, which refreshes the books'
    /// values in a list the next time it is read.
    private(set) var contentRevision = 0

    /// The lists derived since the list revision last changed.
    private var entries: [Key: Entry] = [:]
    /// Each book's index in the library's books, by ID, for the current list
    /// revision: a change that keeps the list revision keeps every book at
    /// its index. Nil until a list needs it.
    private var indexByID: [UUID: Int]?
    /// Every folder tree's book count for the current list revision; nil
    /// until a count is asked for.
    private var folderTreeCounts: [String: Int]?
    /// The sizes File Size sorts measured, by book ID.
    private var measuredSizes: [UUID: MeasuredSize] = [:]
    /// Each title inverted as a row shows it while sorting passes over
    /// leading articles ("Hobbit, The"), by the title and the metadata
    /// language it was read in, so a list drawn again works none out anew.
    private var invertedTitles: [InvertedTitleKey: String] = [:]
    /// How many titles were inverted. Tests read it.
    private(set) var titleInversionCount = 0
    /// At most this many inverted titles are kept; past it the record starts
    /// over, so renamed books cannot make it grow without bound.
    static let invertedTitleLimit = 8_192

    /// What an inverted title depends on: the title and the metadata
    /// language whose articles count beside English's.
    private struct InvertedTitleKey: Hashable {
        let title: String
        let language: String?
    }

    /// The books of the list last typed into as letter navigation reaches
    /// them: their IDs in order, the list revision they were made under,
    /// and their rows with every title folded (`TypedRow`).
    private struct TypedRowsMemo {
        let listRevision: Int
        let ids: [UUID]
        let rows: [TypedRow<UUID>]
    }

    /// The memo of the last list typed into; nil before any, or after the
    /// library dropped it.
    private var typedRowsMemo: TypedRowsMemo?
    /// How many books' rows were made (their titles read for articles and
    /// folded). Tests read it to see that a key reuses rows made before.
    private(set) var typedRowBuildCount = 0

    // MARK: - Titles as Letter Navigation Reaches Them

    /// The rows of `books`, the books a list shows in its order, as letter
    /// navigation compares typed letters with them (`TitleTyping`), each
    /// title folded once and kept for as long as the list is: a key pressed
    /// in a Library of thousands of titles then reads these rows and folds
    /// nothing of theirs.
    ///
    /// The rows are kept for the last list asked for, while the list
    /// revision and the books' IDs and order are as they were. A book's
    /// title and metadata language change the list revision
    /// (`hasSameListFields`), so a renamed book is made anew, and a change
    /// that leaves the list alone (a reading position, a word count) keeps
    /// the rows. The rows follow no setting, so changing the Leading
    /// articles setting does not make them again.
    func typedRows(of books: [Book]) -> [TypedRow<UUID>] {
        if let memo = typedRowsMemo,
           memo.listRevision == listRevision,
           memo.ids.count == books.count,
           zip(memo.ids, books).allSatisfy({ $0 == $1.id }) {
            return memo.rows
        }
        let rows = books.map { TypedRow(id: $0.id, title: $0.title, language: $0.epubLanguage) }
        typedRowBuildCount += rows.count
        typedRowsMemo = TypedRowsMemo(listRevision: listRevision, ids: books.map(\.id), rows: rows)
        return rows
    }

    // MARK: - Titles as Rows Show Them

    /// The title `book`'s row shows in place of its own under `articles`
    /// (`LeadingArticles.rowTitle(of:)`): nil while titles are shown as
    /// written, and otherwise the title inverted, worked out once for each
    /// title and language and kept, as a Library window draws its rows and
    /// its Books rotor again once a second while a book plays.
    func rowTitle(of book: Book, articles: LeadingArticles) -> String? {
        guard articles.sortsWithoutArticles else { return nil }
        let key = InvertedTitleKey(title: book.title, language: book.epubLanguage)
        if let known = invertedTitles[key] {
            return known
        }
        let inverted = articles.shownTitle(book.title, language: book.epubLanguage)
        titleInversionCount += 1
        if invertedTitles.count >= Self.invertedTitleLimit {
            invertedTitles.removeAll(keepingCapacity: true)
        }
        invertedTitles[key] = inverted
        return inverted
    }

    // MARK: - Following the Library

    /// Notes that the library changed from `old` to `new`. The library model
    /// calls this after every change of its library, before anything reads
    /// the new library through the cache.
    func libraryDidChange(from old: Library, to new: Library) {
        contentRevision &+= 1
        guard Self.listsMayDiffer(old.books, new.books) || Self.readingListMayDiffer(old.readingList, new.readingList) else {
            return
        }
        listRevision &+= 1
        typedRowsMemo = nil
        entries.removeAll(keepingCapacity: true)
        indexByID = nil
        folderTreeCounts = nil
        forgetSizes(ofBooksNotIn: new.books)
    }

    /// Whether going from `old` to `new` can change a list: a book added,
    /// removed, or moved within the library's books, or a change to a field
    /// that membership, an order, or a search reads. Comparing the books in
    /// place costs one pass, far less than sorting them again.
    nonisolated static func listsMayDiffer(_ old: [Book], _ new: [Book]) -> Bool {
        guard old.count == new.count else { return true }
        for (before, after) in zip(old, new) where !before.hasSameListFields(as: after) {
            return true
        }
        return false
    }

    /// Whether going from `old` to `new` can change the Reading List's
    /// list (FR09): a book added to or taken off the reading list, or moved
    /// in it. Its options change no list.
    nonisolated static func readingListMayDiffer(_ old: ReadingList, _ new: ReadingList) -> Bool {
        old.bookIDs != new.bookIDs
    }

    // MARK: - Reading Lists

    /// The list `key` names: the one derived earlier, or, the first time it
    /// is read in this list revision, the one `derive` makes from `library`.
    /// Either way its books have their values as `library` holds them now.
    /// - Parameters:
    ///   - key: The list.
    ///   - library: The library as it is now, which the model passes.
    ///   - derive: Makes the list from `library`, filtering and sorting it;
    ///     called only when the list is not kept.
    func books(for key: Key, in library: Library, derive: () -> [Book]) -> [Book] {
        if var entry = entries[key] {
            if entry.contentRevision != contentRevision {
                // Something no list depends on changed: same order, fresh values.
                entry.books = currentBooks(entry.ids, in: library)
                entry.contentRevision = contentRevision
                entries[key] = entry
            }
            return entry.books
        }
        let books = derive()
        derivationCount += 1
        if entries.count >= Self.entryLimit {
            entries.removeAll(keepingCapacity: true)
        }
        entries[key] = Entry(ids: books.map(\.id), books: books, contentRevision: contentRevision)
        return books
    }

    /// The books `ids` name, in that order, with their values as `library`
    /// holds them now. Only a list kept through a change that left the list
    /// revision alone is refreshed this way, and such a change keeps every
    /// book at its index, so each ID is found where the index says.
    private func currentBooks(_ ids: [UUID], in library: Library) -> [Book] {
        let index = bookIndex(of: library)
        let books = library.books
        return ids.compactMap { id in
            guard let position = index[id], books.indices.contains(position), books[position].id == id else {
                return nil
            }
            return books[position]
        }
    }

    /// Each book's index in `library`'s books, by ID, made once for each list
    /// revision and kept (`indexByID`).
    private func bookIndex(of library: Library) -> [UUID: Int] {
        let index = indexByID ?? Self.index(of: library.books)
        indexByID = index
        return index
    }

    /// The book `id` of `library`, found by the kept index instead of a scan
    /// of every book, as `LibraryViewModel.bookByID` reads it for each live
    /// position a reader publishes (the audit's C17). Nil for an ID the
    /// library does not hold. An index that does not point at the book it
    /// names, which no change of the library leaves behind, falls back to
    /// the scan, so a wrong index can slow the answer but never change it.
    func book(withID id: UUID, in library: Library) -> Book? {
        let books = library.books
        if let position = bookIndex(of: library)[id] {
            if books.indices.contains(position), books[position].id == id {
                return books[position]
            }
            return books.first { $0.id == id }
        }
        return nil
    }

    /// Each book's index in `books`, by ID; the first one wins should an ID
    /// appear twice, as `LibraryViewModel.bookByID` finds the first. The
    /// feed rows' lookup finds books by ID the same way (`FeedItemRowLookup`).
    static func index(of books: [Book]) -> [UUID: Int] {
        Dictionary(books.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Folder Counts

    /// How many books are in the folder `path` and every folder below it, as
    /// `Library.totalBooksInFolderTree` counts them, from counts made for
    /// every folder in one pass per list revision: the library's own books,
    /// never a feed's items (FR11).
    func bookCount(inFolderTree path: String, in library: Library) -> Int {
        let counts = folderTreeCounts ?? Self.folderTreeCounts(of: library.libraryBooks)
        folderTreeCounts = counts
        return counts[path] ?? 0
    }

    /// Every folder tree's book count, by folder path, in one pass over
    /// `books`. A book counts toward its own folder and toward each folder
    /// above it: each "/" in its folder path ends the path of one of them.
    /// That is exactly the folders whose path, or whose path followed by
    /// "/", the book's folder path is or starts with, which is how
    /// `Library.totalBooksInFolderTree` counts. Paths are walked by
    /// character, as `hasPrefix` compares them.
    nonisolated static func folderTreeCounts(of books: [Book]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for book in books {
            let path = book.folderPath
            counts[path, default: 0] += 1
            var index = path.startIndex
            while index < path.endIndex {
                if path[index] == "/" {
                    counts[String(path[..<index]), default: 0] += 1
                }
                index = path.index(after: index)
            }
        }
        return counts
    }

    // MARK: - File Sizes

    /// The size a File Size sort gives each of `books`, by ID: measured on
    /// disk the first time, then kept until the book's file changes (its
    /// path or its content hash), so a File Size list costs no file system
    /// calls when it is derived again.
    func fileSizes(of books: [Book]) -> [UUID: Int] {
        var sizes: [UUID: Int] = [:]
        sizes.reserveCapacity(books.count)
        for book in books {
            sizes[book.id] = fileSize(of: book)
        }
        return sizes
    }

    /// `book`'s size as File Size sorts read it: kept, or measured now.
    private func fileSize(of book: Book) -> Int {
        if let measured = measuredSizes[book.id],
           measured.filePath == book.filePath,
           measured.md5Hash == book.md5Hash {
            return measured.bytes
        }
        let bytes = LibraryBookSorter.recursiveFileSize(at: URL(fileURLWithPath: book.filePath))
        fileMeasurementCount += 1
        measuredSizes[book.id] = MeasuredSize(filePath: book.filePath, md5Hash: book.md5Hash, bytes: bytes)
        return bytes
    }

    /// Drops the sizes of books no longer in the library.
    private func forgetSizes(ofBooksNotIn books: [Book]) {
        guard !measuredSizes.isEmpty else { return }
        let ids = Set(books.map(\.id))
        measuredSizes = measuredSizes.filter { ids.contains($0.key) }
    }
}

private extension Book {
    /// Whether `other` has the same value in every field a library list
    /// reads: its ID, folder, and feed link (membership: a feed's items are
    /// listed by their feed, FR11), its format (which a view's format
    /// condition tests, and which tells an episode from an article), the
    /// fields sorts and Recently Opened order by, the title and author a
    /// search matches, the metadata language whose articles a title sorts
    /// and is searched without (`LeadingArticles`), and the file path and
    /// content hash a measured size follows.
    func hasSameListFields(as other: Book) -> Bool {
        id == other.id
            && folderPath == other.folderPath
            && feedLink == other.feedLink
            && format == other.format
            && title == other.title
            && author == other.author
            && epubLanguage == other.epubLanguage
            && dateAdded == other.dateAdded
            && lastOpened == other.lastOpened
            && manualSortOrder == other.manualSortOrder
            && filePath == other.filePath
            && md5Hash == other.md5Hash
    }
}
