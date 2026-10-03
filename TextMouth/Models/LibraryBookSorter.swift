import Foundation

/// Provides the strict ordering used by library lists.
///
/// A Swift sort comparator must return false when two values are equivalent.
/// Negating an ascending Boolean does not produce a valid descending comparator
/// because equality then returns true in both directions. This helper compares
/// values explicitly and adds stable title/UUID tie-breakers.
enum LibraryBookSorter {
    /// Recent-library policy: omit unopened books, newest first, and cap the
    /// quick-access list to a small stable count.
    static func recent(_ books: [Book], limit: Int = 10) -> [Book] {
        Array(
            books
                .filter { $0.lastOpened != nil }
                .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
                .prefix(max(0, limit))
        )
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
        let title: String
        let author: String
        let dateAdded: Date
        /// When the book was last opened; the distant past if never.
        let lastOpened: Date
        /// Its place in its folder's manual order; after every placed book
        /// (`Int.max`) if it has none.
        let manualOrder: Int
        /// Its ID as a string: the last tie-breaker.
        let idString: String
        /// Its size on disk, for File Size; 0 when it was not measured.
        let fileSize: Int

        /// The keys of `book`, whose size on disk is `fileSize`.
        init(_ book: Book, fileSize: Int = 0) {
            title = book.title
            author = book.author
            dateAdded = book.dateAdded
            lastOpened = book.lastOpened ?? .distantPast
            manualOrder = book.manualSortOrder ?? Int.max
            idString = book.id.uuidString
            self.fileSize = fileSize
        }
    }

    /// `books` in the order `field` and `ascending` give them. Each book's
    /// keys are read once, and positions rather than whole books are moved
    /// while sorting.
    /// - Parameter fileSizes: Each book's size on disk, by ID, for File
    ///   Size; a book missing from it counts as 0 bytes.
    static func sorted(
        _ books: [Book],
        by field: LibrarySortField,
        ascending: Bool,
        fileSizes: [UUID: Int] = [:]
    ) -> [Book] {
        let keys = books.map { SortKeys($0, fileSize: fileSizes[$0.id] ?? 0) }
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
        fileSizes: [UUID: Int] = [:]
    ) -> Bool {
        areInIncreasingOrder(
            SortKeys(first, fileSize: fileSizes[first.id] ?? 0),
            SortKeys(second, fileSize: fileSizes[second.id] ?? 0),
            by: field,
            ascending: ascending
        )
    }

    /// The strict order every library list uses: `field` in the chosen
    /// direction, then the title (ascending, ignoring case, in the user's
    /// locale), then the ID string, so no two books ever compare equal.
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

        let titleComparison = first.title.localizedCaseInsensitiveCompare(second.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }

        return first.idString < second.idString
    }

    /// How two books compare by `field` alone.
    private static func comparison(
        _ first: SortKeys,
        _ second: SortKeys,
        by field: LibrarySortField
    ) -> ComparisonResult {
        switch field {
        case .title:
            return first.title.localizedCaseInsensitiveCompare(second.title)
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
