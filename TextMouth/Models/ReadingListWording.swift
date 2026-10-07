import Foundation

/// What TextMouth shows and says of the reading list (FR09), in one place,
/// so the words on screen and the words VoiceOver speaks agree and tests
/// can pin them.
enum ReadingListWording {

    // MARK: - The Rows

    /// What a book's row says of a book in the reading list, as the row's
    /// accessibility value, after its label, in every view but the Reading
    /// List itself, where every row's book is in the list.
    static let inReadingListValue = "In reading list"

    // MARK: - The Order

    /// The name of the one order the Reading List shows its books in: the
    /// order the user arranges, which its Sort menu names, checked, and the
    /// only item it offers.
    static let orderName = "Reading List Order"

    /// The Sort button's spoken label at the Reading List, as the Sort
    /// button elsewhere names the sort it shows ("Sort books by Title,
    /// ascending").
    static let sortMenuLabel = "Sort books by \(orderName)"

    /// What VoiceOver says when the user chooses the Reading List's order,
    /// as choosing a sort elsewhere says the sort now shown.
    static let orderAnnouncement = "Sorted by \(orderName)"

    /// The hint of the Reading List's one sort item: how its order changes.
    static let orderHint = "The reading list keeps the order you arrange with Move Book Up, Move Book Down, or dragging"
}
