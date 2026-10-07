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

    // MARK: - The Empty List

    /// What the Reading List shows, as a row VoiceOver reads, while the
    /// list holds no book: that it is empty, and how a book joins it.
    static let emptyList = "The reading list is empty. To add a book, choose Add to Reading List "
        + "from its context menu, its VoiceOver actions, or the Library menu."

    // MARK: - The Commands

    /// The title of Add to Reading List for `count` books: its plain name,
    /// as the Library menu names it, for the one book a row's menu is for,
    /// or a title counting the books of a selection, as "Add 3 Books to
    /// Reading List".
    static func addTitle(count: Int, forSelection: Bool) -> String {
        guard forSelection else { return ShortcutAction.addToReadingList.title }
        return "Add \(countedBooks(count)) to Reading List"
    }

    /// The title of Remove from Reading List for `count` books: its plain
    /// name for one book, or "Remove 3 Books from Reading List" for a
    /// selection.
    static func removeTitle(count: Int, forSelection: Bool) -> String {
        guard forSelection else { return ShortcutAction.removeFromReadingList.title }
        return "Remove \(countedBooks(count)) from Reading List"
    }

    /// `count` books as a menu title counts them: "1 Book", "3 Books".
    private static func countedBooks(_ count: Int) -> String {
        CountWording.phrase(count, singular: "Book", plural: "Books")
    }

    // MARK: - What the Commands Say

    /// What VoiceOver hears after Add to Reading List added `added`, the
    /// titles of the books added, in order: "Added to reading list:
    /// Moby-Dick" for one, "Added 3 books to the reading list." for
    /// several; then, when `alreadyIn` of the books chosen were in the list
    /// already, how many, as in "1 book was already in it."
    static func addedAnnouncement(added titles: [String], alreadyIn: Int) -> String {
        let done = titles.count == 1
            ? "Added to reading list: \(titles.first ?? "")"
            : "Added \(CountWording.books(titles.count)) to the reading list."
        guard alreadyIn > 0 else { return done }
        return sentences(done, "\(CountWording.phrase(alreadyIn, singular: "book was", plural: "books were")) already in it.")
    }

    /// What VoiceOver hears after Remove from Reading List took off
    /// `removed`, the titles of the books taken off, in the list's order:
    /// "Removed from reading list: Moby-Dick" for one, "Removed 3 books from
    /// the reading list." for several; then, when `notIn` of the books
    /// chosen were not in the list, how many, as in "2 books were not in
    /// it."
    static func removedAnnouncement(removed titles: [String], notIn: Int) -> String {
        let done = titles.count == 1
            ? "Removed from reading list: \(titles.first ?? "")"
            : "Removed \(CountWording.books(titles.count)) from the reading list."
        guard notIn > 0 else { return done }
        return sentences(done, "\(CountWording.phrase(notIn, singular: "book was", plural: "books were")) not in it.")
    }

    /// Why Add to Reading List from the Library menu added nothing, for the
    /// books selected, titled `titles`: none is selected, or every one is
    /// in the list already.
    static func addRefusal(selected titles: [String]) -> String {
        guard !titles.isEmpty else { return LibraryCloudWording.noBooksSelected }
        if titles.count == 1, let title = titles.first {
            return "\(title) is already in the reading list."
        }
        return "The \(titles.count) selected books are already in the reading list."
    }

    /// Why Remove from Reading List from the Library menu took nothing off,
    /// for the books selected, titled `titles`: none is selected, or none
    /// of them is in the list.
    static func removeRefusal(selected titles: [String]) -> String {
        guard !titles.isEmpty else { return LibraryCloudWording.noBooksSelected }
        if titles.count == 1, let title = titles.first {
            return "\(title) isn't in the reading list."
        }
        return "None of the \(titles.count) selected books is in the reading list."
    }

    /// `first` followed by `second` as two sentences: `first` ends with a
    /// period when it has none.
    private static func sentences(_ first: String, _ second: String) -> String {
        "\(first.hasSuffix(".") ? first : first + ".") \(second)"
    }
}
