import Foundation

/// Provides the strict ordering used by library lists.
///
/// A Swift sort comparator must return false when two values are equivalent.
/// Negating an ascending Boolean does not produce a valid descending comparator
/// because equality then returns true in both directions. This helper compares
/// values explicitly and adds stable title/UUID tie-breakers.
enum LibraryBookSorter {
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

    static func sorted(
        _ books: [Book],
        by field: LibrarySortField,
        ascending: Bool,
        fileSizes: [UUID: Int] = [:]
    ) -> [Book] {
        books.sorted {
            areInIncreasingOrder(
                $0,
                $1,
                by: field,
                ascending: ascending,
                fileSizes: fileSizes
            )
        }
    }

    static func areInIncreasingOrder(
        _ first: Book,
        _ second: Book,
        by field: LibrarySortField,
        ascending: Bool,
        fileSizes: [UUID: Int] = [:]
    ) -> Bool {
        let primary = comparison(first, second, by: field, fileSizes: fileSizes)
        if primary != .orderedSame {
            return ascending ? primary == .orderedAscending : primary == .orderedDescending
        }

        let titleComparison = first.title.localizedCaseInsensitiveCompare(second.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }

        return first.id.uuidString < second.id.uuidString
    }

    private static func comparison(
        _ first: Book,
        _ second: Book,
        by field: LibrarySortField,
        fileSizes: [UUID: Int]
    ) -> ComparisonResult {
        switch field {
        case .title:
            return first.title.localizedCaseInsensitiveCompare(second.title)
        case .author:
            return first.author.localizedCaseInsensitiveCompare(second.author)
        case .dateAdded:
            return compare(first.dateAdded, second.dateAdded)
        case .lastOpened:
            return compare(first.lastOpened ?? .distantPast, second.lastOpened ?? .distantPast)
        case .fileSize:
            return compare(fileSizes[first.id] ?? 0, fileSizes[second.id] ?? 0)
        case .manual:
            return compare(first.manualSortOrder ?? Int.max, second.manualSortOrder ?? Int.max)
        }
    }

    private static func compare<T: Comparable>(_ first: T, _ second: T) -> ComparisonResult {
        if first < second { return .orderedAscending }
        if first > second { return .orderedDescending }
        return .orderedSame
    }
}
