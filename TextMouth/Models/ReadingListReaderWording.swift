import Foundation

/// What a reader reading its book from the reading list shows and says
/// (FR09), in one place, so the window, the header, and VoiceOver word it
/// alike and the tests pin every phrase. The Library window's own words for
/// the list are `ReadingListWording`'s.
///
/// Localized (FR35): each text is computed, read from the String Catalog in
/// the interface's language whenever it is asked for, and each sentence that
/// differs by direction is written whole for each direction.
enum ReadingListReaderWording {

    // MARK: - The Mark

    /// What the window title of a reader reading its book from the reading
    /// list begins with, in place of "Book": "Reading List: <title> by
    /// <author>", or "Reading List: <title>" with no known author
    /// (`BookReaderWindowView.windowTitle(for:readFromReadingList:)`), so
    /// the window says, wherever VoiceOver or an eye meets it, that the book
    /// is read from the list.
    static var windowTitlePrefix: String {
        // Translators: The start of the window title of a book read from the reading list, before a colon and the book's title, in place of "Book"; also the name of the Library's Reading List.
        InterfaceText.line("common.readingList", "Reading List")
    }

    /// Where the book stands in the reading list, counted as the Reading
    /// List shows it, as the reader's header shows it and the full Where Am
    /// I? says it: "Reading list, book 3 of 12".
    static func place(_ place: ReadingListPlace) -> String {
        // Translators: Where a book read from the reading list stands in it, in the reader's header and in Where Am I?. %1$lld is the book's place in the list; %2$lld how many books the list holds.
        InterfaceText.line("readingListReader.place", "Reading list, book \(number: place.position) of \(number: place.count)")
    }

    // MARK: - The End of a Book Read from the List

    /// Why nothing follows a book read from the reading list whose "When a
    /// book ends" is Stop, as the sentence after "Finished: <title>." says
    /// it (`EndOfBookWording.finished(_:notes:sleepTimerExpired:)`).
    static var stopNote: String {
        // Translators: A sentence of the announcement as a book read from the reading list ends, after "Finished: <title>.": the list's When a book ends is Stop. Written without its full stop.
        InterfaceText.line("readingListReader.stopNote", "The reading list is set to stop when a book ends")
    }

    /// Why nothing follows a book read from the reading list, going
    /// `direction` as the list continues, as the sentence after "Finished:
    /// <title>." says it: the end of the list going down, its start going
    /// up, or only finished books below, or above, the book.
    static func endNote(_ end: ReadingListEnd, going direction: ReadingList.Direction) -> String {
        switch (end, direction) {
        case (.noBookBeyond, .down):
            // Translators: A sentence of the announcement as a book read from the reading list ends, after "Finished: <title>.": no book follows it below. Written without its full stop.
            return InterfaceText.line("readingListReader.endNote.finish", "End of the reading list")
        case (.noBookBeyond, .up):
            // Translators: A sentence of the announcement as a book read from the reading list ends while the list plays upward: no book above it. Written without its full stop.
            return InterfaceText.line("readingListReader.endNote.start", "Start of the reading list")
        case (.onlyFinishedBooksBeyond, .down):
            // Translators: A sentence of the announcement as a book read from the reading list ends, after "Finished: <title>.": the books below it are all finished, and the list passes over finished books. Written without its full stop.
            return InterfaceText.line("readingListReader.endNote.below", "Every book below it in the reading list is finished")
        case (.onlyFinishedBooksBeyond, .up):
            // Translators: A sentence of the announcement as a book read from the reading list ends while the list plays upward: the books above it are all finished, and the list passes over finished books. Written without its full stop.
            return InterfaceText.line("readingListReader.endNote.above", "Every book above it in the reading list is finished")
        }
    }

    /// The English the debug log writes for `stopNote`, whatever the interface
    /// language is (the log stays English: see `BookSuccession`).
    static let stopLogName = "the reading list is set to stop when a book ends" // l10n: no (the debug log's words)

    /// The English the debug log writes for `endNote(_:going:)`.
    static func endLogName(_ end: ReadingListEnd, going direction: ReadingList.Direction) -> String {
        // l10n: no (the debug log's words)
        switch (end, direction) {
        case (.noBookBeyond, .down): return "end of the reading list"
        case (.noBookBeyond, .up): return "start of the reading list"
        case (.onlyFinishedBooksBeyond, .down): return "every book below it in the reading list is finished"
        case (.onlyFinishedBooksBeyond, .up): return "every book above it in the reading list is finished"
        }
    }

    // MARK: - Next and Previous in Reading List

    /// What Next in Reading List and Previous in Reading List say from a
    /// reader not reading its book from the list: the Navigate menu offers
    /// them only for one that is, but a key the user gave them still
    /// reaches any reader.
    static var notReadFromReadingList: String {
        // Translators: VoiceOver announcement when Next in Reading List or Previous in Reading List is used in a reader whose book was not opened from the reading list.
        InterfaceText.line("readingListReader.notReadFromReadingList", "This book was not opened from the reading list.")
    }

    /// What VoiceOver hears as Next in Reading List or Previous in Reading
    /// List opens `title` without starting it, as when this book was not
    /// playing: "Opening: <title>". A book that starts is announced as a book
    /// that continues is (`EndOfBookWording.starting(_:)`). A running sleep
    /// timer keeps nothing from starting: it goes on with the next book.
    static func opening(_ title: String) -> String {
        // Translators: VoiceOver announcement as Next in Reading List or Previous in Reading List opens a book without playing it. %@ is the book's title.
        InterfaceText.line("readingListReader.opening", "Opening: \(title)")
    }

    /// What Next in Reading List (going down) or Previous in Reading List
    /// (going up) says with no book that way: "No next book in the reading
    /// list.", or, past only finished books while the list passes over
    /// them, why: "No next book in the reading list: every book below this
    /// one is finished." Each of the four is one whole sentence.
    static func noNeighbor(_ end: ReadingListEnd, going direction: ReadingList.Direction) -> String {
        switch (end, direction) {
        case (.noBookBeyond, .down):
            // Translators: VoiceOver announcement when Next in Reading List finds no book below this one.
            return InterfaceText.line("readingListReader.noNeighbor.next", "No next book in the reading list.")
        case (.noBookBeyond, .up):
            // Translators: VoiceOver announcement when Previous in Reading List finds no book above this one.
            return InterfaceText.line("readingListReader.noNeighbor.previous", "No previous book in the reading list.")
        case (.onlyFinishedBooksBeyond, .down):
            // Translators: VoiceOver announcement when Next in Reading List finds only finished books below this one, which the list passes over.
            return InterfaceText.line("readingListReader.noNeighbor.below", "No next book in the reading list: every book below this one is finished.")
        case (.onlyFinishedBooksBeyond, .up):
            // Translators: VoiceOver announcement when Previous in Reading List finds only finished books above this one, which the list passes over.
            return InterfaceText.line("readingListReader.noNeighbor.above", "No previous book in the reading list: every book above this one is finished.")
        }
    }

    // MARK: - Ways Through the List

    /// Where `direction` leads in the list, as the debug log says it:
    /// "below", going down; "above", going up. Never localized: the
    /// sentences the listener hears are written whole for each direction
    /// (FR35), so only the log, which stays English, still uses the word.
    static func side(_ direction: ReadingList.Direction) -> String {
        direction == .down ? "below" : "above" // l10n: no (the debug log's word; the interface's sentences are whole)
    }
}
