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

    // MARK: - The End of a Book Read from the List

    /// Why nothing follows a book read from the reading list whose "When a
    /// book ends" is Stop, as the sentence after "Finished: <title>." says
    /// it (`EndOfBookWording.finished(_:notes:sleepTimerExpired:)`).
    static let stopNote = "The reading list is set to stop when a book ends"

    /// Why nothing follows a book read from the reading list, going
    /// `direction` as the list continues, as the sentence after "Finished:
    /// <title>." says it: the end of the list going down, its start going
    /// up, or only finished books below, or above, the book.
    static func endNote(_ end: ReadingListEnd, going direction: ReadingList.Direction) -> String {
        switch end {
        case .noBookBeyond:
            return direction == .down ? "End of the reading list" : "Start of the reading list"
        case .onlyFinishedBooksBeyond:
            return "Every book \(side(direction)) it in the reading list is finished"
        }
    }

    // MARK: - Ways Through the List

    /// Where `direction` leads in the list as it is shown and spoken, as the
    /// options bar's "Play the book below" and "Play the book above" name
    /// it: below, going down; above, going up.
    static func side(_ direction: ReadingList.Direction) -> String {
        direction == .down ? "below" : "above"
    }
}
