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

    // MARK: - Next and Previous in Reading List

    /// What Next in Reading List and Previous in Reading List say from a
    /// reader not reading its book from the list: the Navigate menu offers
    /// them only for one that is, but a key the user gave them still
    /// reaches any reader.
    static let notReadFromReadingList = "This book was not opened from the reading list."

    /// What VoiceOver hears as Next in Reading List or Previous in Reading
    /// List opens `title` without starting it, as when this book was not
    /// playing: "Opening: <title>"; and, when this reader's sleep timer kept
    /// it from starting, why: "Opening: <title>. Not started because of the
    /// sleep timer." A book that starts is announced as a book that
    /// continues is (`EndOfBookWording.starting(_:)`).
    static func opening(_ title: String, sleepTimerKeptItFromStarting: Bool) -> String {
        let opening = "Opening: \(title)"
        return sleepTimerKeptItFromStarting ? opening + ". Not started because of the sleep timer." : opening
    }

    /// What Next in Reading List (going down) or Previous in Reading List
    /// (going up) says with no book that way: "No next book in the reading
    /// list.", or, past only finished books while the list passes over
    /// them, why: "No next book in the reading list: every book below this
    /// one is finished."
    static func noNeighbor(_ end: ReadingListEnd, going direction: ReadingList.Direction) -> String {
        let noBook = "No \(direction == .down ? "next" : "previous") book in the reading list"
        switch end {
        case .noBookBeyond:
            return noBook + "."
        case .onlyFinishedBooksBeyond:
            return noBook + ": every book \(side(direction)) this one is finished."
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
