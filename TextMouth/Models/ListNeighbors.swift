import Foundation

/// The one search for "the element beside this one" in an ordered list, shared
/// by everything that hands listening on from a book to its neighbor: the
/// reading list, a plain folder's books in their order, and a feed's items.
/// Each used to carry its own copy of the same slicing (FR19).
enum ListNeighbors {

    /// The elements of `ids` beyond `id` going `direction`, nearest first:
    /// those after it going down, those before it read backward going up.
    /// nil when `ids` does not hold `id`. When `id` appears twice, the first
    /// position counts.
    static func beyond<ID: Equatable>(
        _ id: ID,
        going direction: ReadingList.Direction,
        in ids: [ID]
    ) -> [ID]? {
        guard let position = ids.firstIndex(of: id) else { return nil }
        switch direction {
        case .down:
            // `index(after:)` is safe at the last position: it gives endIndex,
            // and the slice from endIndex is empty.
            return Array(ids[ids.index(after: position)...])
        case .up:
            return Array(ids[..<position].reversed())
        }
    }

    /// The nearest element beyond `id` going `direction` that `isEligible`
    /// accepts; nil when `ids` does not hold `id`, or none qualifies.
    static func neighbor<ID: Equatable>(
        of id: ID,
        _ direction: ReadingList.Direction,
        in ids: [ID],
        where isEligible: (ID) -> Bool
    ) -> ID? {
        beyond(id, going: direction, in: ids)?.first(where: isEligible)
    }
}
