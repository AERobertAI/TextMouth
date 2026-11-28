import Foundation

/// Keys that put the reading list's books in order, so that two devices'
/// changes to it merge (FR43, section 5 of the plan).
///
/// A key is a string over `alphabet`, whose digits are in the order of their
/// code points, so Swift's text order is the keys' order, and no key ends in
/// the first digit (which keeps room between any two keys). A key can be
/// made between any two others, so a book added on one device and a book
/// moved on another both keep a place, and only a moved book gets a new key.
enum SyncOrderKey {
    /// The digits, lowest first.
    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// A key between `lower` and `upper`, each nil for none. Needs `lower`
    /// below `upper`; for two keys that are not, the result is a key above
    /// `lower` (so the caller never traps on a file that holds nonsense).
    static func between(_ lower: String?, _ upper: String?) -> String {
        let low = Array(lower ?? "")
        if let upper, !upper.isEmpty {
            let high = Array(upper)
            // Keys that are out of order, or empty of room: take a key above the lower one.
            guard low.lexicographicallyPrecedes(high) else { return after(low) }
            return String(midpoint(low, high))
        }
        return after(low)
    }

    /// `count` keys in order between `lower` and `upper`, spread so that the
    /// first and last are not much longer than the middle one: the middle
    /// key is made first, then the halves on either side of it.
    static func keys(count: Int, between lower: String?, _ upper: String?) -> [String] {
        guard count > 0 else { return [] }
        let middle = count / 2
        let key = between(lower, upper)
        return keys(count: middle, between: lower, key) + [key] + keys(count: count - middle - 1, between: key, upper)
    }

    /// The keys the books of `order` need, given the keys some of them have
    /// (`existing`), changing as few as it can: the books whose keys already
    /// stand in order (the longest such run) keep theirs, and every other
    /// book gets a key between its neighbours' keys. Books of `existing`
    /// that are not in `order` are ignored.
    /// - Returns: the new keys, only for the books that need one.
    static func assign(order: [UUID], existing: [UUID: String]) -> [UUID: String] {
        // The books that have a key, in list order, as (position in the list, key).
        let keyed: [(position: Int, key: String, id: String)] = order.enumerated().compactMap { position, id in
            existing[id].map { (position, $0, id.uuidString) }
        }
        // Strictly increasing by key alone: two books that share a key (two devices each added one to the end)
        // cannot both stay, since a book moved between them has no key between theirs. One stays, the other is re-keyed.
        let staying = Set(longestIncreasingRun(of: keyed.map { $0.key }).map { keyed[$0].position })

        var result: [UUID: String] = [:]
        var index = 0
        var lowerKey: String?
        while index < order.count {
            if staying.contains(index) {
                lowerKey = existing[order[index]]
                index += 1
                continue
            }
            // A run of books that need keys, up to the next book that keeps its own.
            var end = index
            while end < order.count, !staying.contains(end) { end += 1 }
            let upperKey = end < order.count ? existing[order[end]] : nil
            let made = keys(count: end - index, between: lowerKey, upperKey)
            for (offset, key) in made.enumerated() { result[order[index + offset]] = key }
            lowerKey = made.last
            index = end
        }
        return result
    }

    /// Two entries' places in the list, as the merge sorts them: by key, then by ID.
    struct SortKey: Comparable, Hashable, Sendable {
        var key: String
        var id: String
        static func < (lhs: SortKey, rhs: SortKey) -> Bool { (lhs.key, lhs.id) < (rhs.key, rhs.id) }
    }

    // MARK: - Making a key

    /// A key just above `low`: its first digit raised, or the digits that
    /// follow it, so it needs no upper bound.
    private static func after(_ low: [Character]) -> String {
        String(midpoint(low, nil))
    }

    /// The index of a digit; a character that is none counts as the first digit.
    private static func value(of digit: Character) -> Int { digits.firstIndex(of: digit) ?? 0 }

    /// A key above `a` and below `b` (nil for none), neither ending in the first digit.
    private static func midpoint(_ a: [Character], _ b: [Character]?) -> [Character] {
        if let b {
            // The digits both keys start with stay, and the rest is made between what is left.
            var common = 0
            while common < b.count, (common < a.count ? a[common] : digits[0]) == b[common] { common += 1 }
            if common > 0 {
                return Array(b[0..<common]) + midpoint(Array(a.dropFirst(min(common, a.count))), Array(b.dropFirst(common)).isEmpty ? nil : Array(b.dropFirst(common)))
            }
        }
        let lowDigit = a.first.map(value(of:)) ?? 0
        let highDigit = b?.first.map(value(of:)) ?? digits.count
        if highDigit - lowDigit > 1 {
            // Room for a digit between: the middle one.
            return [digits[(lowDigit + highDigit + 1) / 2]]
        }
        if let b, b.count > 1 {
            // The upper key's first digit alone is below it, and above the lower key.
            return [b[0]]
        }
        // No room at this digit: keep the lower key's and make the rest above what follows it.
        return [digits[lowDigit]] + midpoint(Array(a.dropFirst()), nil)
    }

    // MARK: - The longest increasing run

    /// The indices of a longest strictly increasing run of `items` (patience
    /// sorting), the same one for the same items, so the same books stay on every device.
    private static func longestIncreasingRun<Item: Comparable>(of items: [Item]) -> [Int] {
        // tails[length - 1] is the index of the smallest item that ends a run of that length.
        var tails: [Int] = []
        var previous = [Int?](repeating: nil, count: items.count)
        for (index, item) in items.enumerated() {
            // The first run length whose tail is not below this item.
            var low = 0, high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if items[tails[middle]] < item { low = middle + 1 } else { high = middle }
            }
            previous[index] = low > 0 ? tails[low - 1] : nil
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var run: [Int] = []
        var cursor = tails.last
        while let current = cursor {
            run.append(current)
            cursor = previous[current]
        }
        return run.reversed()
    }
}
