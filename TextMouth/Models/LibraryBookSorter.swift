import Foundation

/// Provides the strict ordering used by library lists.
///
/// A Swift sort comparator must return false when two values are equivalent.
/// Negating an ascending Boolean does not produce a valid descending comparator
/// because equality then returns true in both directions. This helper compares
/// values explicitly and adds stable title/UUID tie-breakers.
///
/// Every order here reads titles as `articles`, the Library tab's Leading
/// articles setting, says (`LeadingArticles`): as written, as on main before
/// the setting, unless sorting passes over leading articles, when each title
/// is compared from where it files ("Hobbit" for "The Hobbit"), the Title
/// sort and every tie broken by title alike. A caller that names no setting
/// gets titles as written.
enum LibraryBookSorter {
    /// How many rows Recently Opened lists: the ten opened last, which its
    /// shipped Library view keeps too (`LibraryViewDefinition.shipped`).
    static let recentlyOpenedCount = 10

    /// Recent-library policy: omit unopened books, newest first, and cap the
    /// quick-access list to a small stable count. Of each feed's items, only
    /// the one opened last is listed, within the same count (FR11), so a
    /// week of one podcast takes one place, and resuming it stays one step.
    /// A limit below 1 lists nothing. The shipped Recently Opened view
    /// chooses its rows through the same `latestOpened(_:limit:onePerFeed:)`
    /// (`LibraryViewFilterEvaluator`), so the two cannot drift apart.
    static func recent(_ books: [Book], limit: Int = recentlyOpenedCount, articles: LeadingArticles = .partOfTitle) -> [Book] {
        latestOpened(books.filter { !$0.isUnopened }, limit: limit, onePerFeed: true, articles: articles)
    }

    /// The rows of `books` opened last first (`openedLastFirst`: by last
    /// opened, newest first, then the rows never opened, newest added
    /// first), with, when `onePerFeed`, only the first of each feed's items,
    /// and at most `limit` (nil: all; a limit below 1 lists nothing).
    /// Titles break ties as `articles` reads them.
    static func latestOpened(_ books: [Book], limit: Int?, onePerFeed: Bool, articles: LeadingArticles = .partOfTitle) -> [Book] {
        if let limit, limit < 1 {
            return []
        }
        // Each row's keys are read once, not at every comparison (TODO
        // PERF10), and positions are sorted rather than whole rows.
        let keys = books.map { SortKeys($0, articles: articles) }
        let byLastOpened = keys.indices.sorted { openedLastFirst(keys[$0], keys[$1]) }.map { books[$0] }
        var listedFeeds = Set<UUID>()
        var listed: [Book] = []
        for book in byLastOpened {
            // A feed's later items in this order were opened before the one
            // listed already.
            if onePerFeed, let feedID = book.feedLink?.feedID, !listedFeeds.insert(feedID).inserted {
                continue
            }
            listed.append(book)
            // Never true with no limit.
            if listed.count == limit {
                break
            }
        }
        return listed
    }

    /// Whether the row whose keys are `first` comes before the one whose
    /// keys are `second` in `latestOpened`'s order: opened later first, and
    /// every row opened before every row never opened. Rows never opened
    /// fall as a list sorted by Date Added, newest first, puts them, its
    /// title and identity breaking ties, so "the latest" of a feed's
    /// unplayed episodes is the newest, never one picked by the library's
    /// order (review of October 31, 2026, finding 7). Rows opened at one
    /// instant keep the order they came in, as they always have, so Recently
    /// Opened lists what it always did.
    private static func openedLastFirst(_ first: SortKeys, _ second: SortKeys) -> Bool {
        switch (first.wasOpened, second.wasOpened) {
        case (true, true):
            return first.lastOpened > second.lastOpened
        case (true, false):
            return true
        case (false, true):
            return false
        case (false, false):
            return areInIncreasingOrder(first, second, by: .dateAdded, ascending: false)
        }
    }

    /// Return the logical size of a file or all regular files contained in a
    /// directory package. Directory metadata alone does not include its contents.
    static func recursiveFileSize(at url: URL, fileManager: FileManager = .default) -> Int {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }

        if !isDirectory.boolValue {
            return (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total = 0
        for case let childURL as URL in enumerator {
            guard let values = try? childURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += values.fileSize ?? 0
        }
        return total
    }

    /// What one book is sorted by, read from it once per sort rather than at
    /// every comparison (TODO PERF10): comparing two books then unwraps no
    /// optional and makes no string, where the comparator used to make both
    /// books' ID strings afresh at every tie.
    struct SortKeys {
        /// The title as written.
        let title: String
        /// The title as sorts read it (`LeadingArticles.sortKey(of:language:)`):
        /// from where it files, its leading article left out, while sorting
        /// passes over articles; the title as written otherwise.
        let titleKey: String
        let author: String
        let dateAdded: Date
        /// When the book was last opened; the distant past if never.
        let lastOpened: Date
        /// Whether the book was ever opened, which `lastOpened` alone cannot
        /// tell from a book opened at the distant past.
        let wasOpened: Bool
        /// Its place in its folder's manual order; after every placed book
        /// (`Int.max`) if it has none.
        let manualOrder: Int
        /// Its ID as a string: the last tie-breaker.
        let idString: String
        /// Its size on disk, for File Size; 0 when it was not measured.
        let fileSize: Int

        /// The keys of `book`, whose size on disk is `fileSize`, its title
        /// read as `articles` says, in the articles of English and of the
        /// book's metadata language.
        init(_ book: Book, fileSize: Int = 0, articles: LeadingArticles = .partOfTitle) {
            title = book.title
            titleKey = articles.sortKey(of: book.title, language: book.epubLanguage)
            author = book.author
            dateAdded = book.dateAdded
            lastOpened = book.lastOpened ?? .distantPast
            wasOpened = book.lastOpened != nil
            manualOrder = book.manualSortOrder ?? Int.max
            idString = book.id.uuidString
            self.fileSize = fileSize
        }
    }

    /// `books` in the order `field` and `ascending` give them, titles read
    /// as `articles` says. Each book's keys are read once, and positions
    /// rather than whole books are moved while sorting.
    /// - Parameter fileSizes: Each book's size on disk, by ID, for File
    ///   Size; a book missing from it counts as 0 bytes.
    static func sorted(
        _ books: [Book],
        by field: LibrarySortField,
        ascending: Bool,
        fileSizes: [UUID: Int] = [:],
        articles: LeadingArticles = .partOfTitle
    ) -> [Book] {
        let keys = books.map { SortKeys($0, fileSize: fileSizes[$0.id] ?? 0, articles: articles) }
        return keys.indices
            .sorted { areInIncreasingOrder(keys[$0], keys[$1], by: field, ascending: ascending) }
            .map { books[$0] }
    }

    /// Whether `first` sorts before `second`, by their keys as
    /// `areInIncreasingOrder(_:_:by:ascending:)` for keys compares them.
    static func areInIncreasingOrder(
        _ first: Book,
        _ second: Book,
        by field: LibrarySortField,
        ascending: Bool,
        fileSizes: [UUID: Int] = [:],
        articles: LeadingArticles = .partOfTitle
    ) -> Bool {
        areInIncreasingOrder(
            SortKeys(first, fileSize: fileSizes[first.id] ?? 0, articles: articles),
            SortKeys(second, fileSize: fileSizes[second.id] ?? 0, articles: articles),
            by: field,
            ascending: ascending
        )
    }

    /// The strict order every library list uses: `field` in the chosen
    /// direction, then the title (ascending, ignoring case, in the user's
    /// locale, as `titleOrder` compares titles), then the ID string, so no
    /// two books ever compare equal.
    static func areInIncreasingOrder(
        _ first: SortKeys,
        _ second: SortKeys,
        by field: LibrarySortField,
        ascending: Bool
    ) -> Bool {
        let primary = comparison(first, second, by: field)
        if primary != .orderedSame {
            return ascending ? primary == .orderedAscending : primary == .orderedDescending
        }

        let titleComparison = titleOrder(first, second)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }

        return first.idString < second.idString
    }

    /// How two books' titles compare, for the Title sort and for every tie
    /// broken by title: by the text sorts read (`SortKeys.titleKey`),
    /// ignoring case, in the user's locale; and, when those are the same
    /// and a title differs from its key, which happens only while sorting
    /// passes over articles, by the titles as written, so "Hobbit" comes
    /// before "The Hobbit" and the two never tie. Titles read as written
    /// compare exactly as they always have.
    static func titleOrder(_ first: SortKeys, _ second: SortKeys) -> ComparisonResult {
        let byKey = first.titleKey.localizedCaseInsensitiveCompare(second.titleKey)
        guard byKey == .orderedSame, first.titleKey != first.title || second.titleKey != second.title else {
            return byKey
        }
        return first.title.localizedCaseInsensitiveCompare(second.title)
    }

    /// How two books compare by `field` alone.
    private static func comparison(
        _ first: SortKeys,
        _ second: SortKeys,
        by field: LibrarySortField
    ) -> ComparisonResult {
        switch field {
        case .title:
            return titleOrder(first, second)
        case .author:
            return first.author.localizedCaseInsensitiveCompare(second.author)
        case .dateAdded:
            return compare(first.dateAdded, second.dateAdded)
        case .lastOpened:
            return compare(first.lastOpened, second.lastOpened)
        case .fileSize:
            return compare(first.fileSize, second.fileSize)
        case .manual:
            return compare(first.manualOrder, second.manualOrder)
        }
    }

    /// How two comparable values compare, as a `ComparisonResult`.
    private static func compare<T: Comparable>(_ first: T, _ second: T) -> ComparisonResult {
        if first < second { return .orderedAscending }
        if first > second { return .orderedDescending }
        return .orderedSame
    }
}
