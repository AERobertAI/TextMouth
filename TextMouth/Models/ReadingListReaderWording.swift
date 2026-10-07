import Foundation

/// What a reader reading its book from the reading list shows and says
/// (FR09), in one place, so the window, the header, and VoiceOver word it
/// alike and the tests pin every phrase. The Library window's own words for
/// the list are `ReadingListWording`'s.
enum ReadingListReaderWording {

    // MARK: - The Mark

    /// What the window title of a reader reading its book from the reading
    /// list begins with, in place of "Book": "Reading List: <title> by
    /// <author>", or "Reading List: <title>" with no known author
    /// (`BookReaderWindowView.windowTitle(for:readFromReadingList:)`), so
    /// the window says, wherever VoiceOver or an eye meets it, that the book
    /// is read from the list.
    static let windowTitlePrefix = "Reading List"

    /// Where the book stands in the reading list, counted as the Reading
    /// List shows it, as the reader's header shows it and the full Where Am
    /// I? says it: "Reading list, book 3 of 12".
    static func place(_ place: ReadingListPlace) -> String {
        "Reading list, book \(place.position) of \(place.count)"
    }
}
