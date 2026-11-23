import Foundation

/// What Search Library shows and says (LIBRARY-SEARCH-RESEARCH-2026-11-13.md),
/// in one place, so the words on screen and the words VoiceOver speaks agree
/// and tests can pin them. Every count sits inside its own whole sentence,
/// with English plural forms in the catalog, so each language counts by its
/// own rules (FR34).
enum LibrarySearchWording {

    // MARK: - The Window

    /// The window's title, which VoiceOver names it by, and the command's
    /// name in the Edit menu's Find submenu, without its ellipsis.
    static var windowTitle: String {
        // Translators: Title of the Search Library window, which VoiceOver names it by, and the name of its command in the Edit menu's Find submenu.
        InterfaceText.line("librarySearch.windowTitle", "Search Library")
    }

    /// The search field's label.
    static var fieldLabel: String {
        // Translators: VoiceOver label of the search field in the Search Library window.
        InterfaceText.line("librarySearch.fieldLabel", "Search the library")
    }

    /// The search field's placeholder, shown while it is empty.
    static var fieldPrompt: String {
        // Translators: Placeholder of the empty search field in the Search Library window.
        InterfaceText.line("librarySearch.fieldPrompt", "Text to find in every book")
    }

    /// The search field's hint.
    static var fieldHint: String {
        // Translators: VoiceOver hint of the search field in the Search Library window.
        InterfaceText.line("librarySearch.fieldHint", "Type to search the text of every book in the library")
    }

    /// The Regular Expression checkbox's title and label.
    static var regexLabel: String {
        // Translators: Title and VoiceOver label of the checkbox in the Search Library window that makes the search text a regular expression.
        InterfaceText.line("librarySearch.regexLabel", "Regular Expression")
    }

    /// The Regular Expression checkbox's hint.
    static var regexHint: String {
        // Translators: VoiceOver hint of the Regular Expression checkbox in the Search Library window. ICU is the name of the regular expression syntax, and stays as written.
        InterfaceText.line("librarySearch.regexHint", "When checked, the search text is an ICU regular expression")
    }

    /// The label of the list of results.
    static var resultsLabel: String {
        // Translators: VoiceOver label of the list of results in the Search Library window.
        InterfaceText.line("librarySearch.resultsLabel", "Results")
    }

    /// The name of the rotor that lists each book with matches.
    static var booksRotor: String {
        // Translators: Name of the VoiceOver rotor in the Search Library window that moves between the books that hold matches.
        InterfaceText.line("common.books", "Books")
    }

    /// The name of the rotor that lists each match listed.
    static var matchesRotor: String {
        // Translators: Name of the VoiceOver rotor in the Search Library window that moves between the matches listed.
        InterfaceText.line("librarySearch.matchesRotor", "Matches")
    }

    /// The Close button's title.
    static var closeButton: String {
        // Translators: Title of the button that closes the Search Library window.
        InterfaceText.line("common.close", "Close")
    }

    /// The Close button's hint.
    static var closeHint: String {
        // Translators: VoiceOver hint of the Close button of the Search Library window. Search Library is the window's name.
        InterfaceText.line("librarySearch.closeHint", "Closes Search Library; results stay for next time")
    }

    // MARK: - The Status

    /// Said before anything is typed.
    static var idle: String {
        // Translators: Status line of the Search Library window before anything is typed.
        InterfaceText.line("librarySearch.idle", "Type text to find in every book of the library.")
    }

    /// Said while a search runs, before any book is done: "Searching 750
    /// books…", or "Searching…" while typing pauses, before the books are
    /// counted.
    static func searching(books: Int) -> String {
        guard books != 0 else {
            // Translators: Status line of the Search Library window while a search runs and the books are not yet counted.
            return InterfaceText.line("common.searching", "Searching…")
        }
        // Translators: Status line of the Search Library window while a search runs, before any book is done. %lld is the number of books being searched.
        return InterfaceText.line("librarySearch.searching", "Searching \(number: books) books…")
    }

    /// Said while a search runs, once some books are done: "Searched 120 of
    /// 750 books…". The number done is formatted; the total is a count of
    /// books with its noun, which a translation agrees with.
    static func searched(_ done: Int, of total: Int) -> String {
        // Translators: Status line of the Search Library window while a search runs, once some books are done. %1$@ is the number of books searched so far, and %2$@ is the count of all the books with its noun, such as "750 books".
        InterfaceText.line("librarySearch.searched", "Searched \(done.interfaceFormatted()) of \(CountWording.books(total))…")
    }

    /// Said while a search runs that has had to prepare a book on its way,
    /// parsing its text because this Mac's search texts did not hold it (the
    /// first search after an installation or after macOS emptied the Caches
    /// folder, before the background preparation reached the book), so the
    /// listener knows why it takes longer: "Preparing 120 of 737 books…".
    static func preparing(_ done: Int, of total: Int) -> String {
        // Translators: Status line of the Search Library window while a search must prepare books' text, which takes longer. %1$@ is the number of books prepared so far, and %2$@ is the count of all the books with its noun, such as "737 books".
        InterfaceText.line("librarySearch.preparing", "Preparing \(done.interfaceFormatted()) of \(CountWording.books(total))…")
    }

    /// The opening of a stopped search's status, before what it had found:
    /// "Stopped after 120 of 750 books:".
    static func stopped(searched: Int, of total: Int) -> String {
        // Translators: Opening of the Search Library status after the user stopped a search, followed by what it had found. %1$@ is the number of books searched, and %2$@ is the count of all the books with its noun, such as "750 books". Ends with a colon.
        InterfaceText.line("librarySearch.stopped", "Stopped after \(searched.interfaceFormatted()) of \(CountWording.books(total)):")
    }

    /// The Stop button's title, shown while a search runs.
    static var stopButton: String {
        // Translators: Title of the button that stops a running search in the Search Library window.
        InterfaceText.line("common.stop", "Stop")
    }

    /// The Stop button's hint.
    static var stopHint: String {
        // Translators: VoiceOver hint of the Stop button of the Search Library window.
        InterfaceText.line("librarySearch.stopHint", "Stops the search, keeping the matches found so far")
    }

    /// The label of the progress bar shown while a search runs.
    static var progressLabel: String {
        // Translators: VoiceOver label of the progress bar shown while a search runs in the Search Library window.
        InterfaceText.line("librarySearch.progressLabel", "Search progress")
    }

    /// Said when the library holds no book with a text to search.
    static var noBooks: String {
        // Translators: Status line of the Search Library window when no book in the library has text that can be searched.
        InterfaceText.line("librarySearch.noBooks", "No book in the library has text to search.")
    }

    /// The opening of an invalid regular expression's status, as Search in
    /// Book words it: "Invalid regular expression: <reason>".
    static func invalidPattern(_ reason: String) -> String {
        // Translators: Status line when the search text is not a valid regular expression. %@ is the reason the system gives, which may be in English.
        InterfaceText.line("librarySearch.invalidPattern", "Invalid regular expression: \(reason)")
    }

    /// How many matches were found in how many books: "No matches", "1
    /// match in 1 book", "212 matches in 31 books", or, when a book's count
    /// stopped at its limit, "More than 41,000 matches in 750 books".
    static func found(matches: Int, books: Int, isLowerBound: Bool) -> String {
        guard matches > 0 else {
            // Translators: Status line of the Search Library window when a search found nothing.
            return InterfaceText.line("common.noMatches", "No matches")
        }
        let counted = CountWording.books(books)
        if isLowerBound {
            // Translators: Status line of a finished search where a book's count of matches stopped at its limit. %1$lld is the number of matches found, and %2$@ is the count of books with its noun, such as "750 books".
            return InterfaceText.line("librarySearch.found.more", "More than \(number: matches) matches in \(counted)")
        }
        // Translators: Status line of a finished search. %1$lld is the number of matches found, and %2$@ is the count of books that hold them with its noun, such as "31 books".
        return InterfaceText.line("librarySearch.found.matches", "\(number: matches) matches in \(counted)")
    }

    /// The note added when the list shows fewer matches than were found:
    /// "showing up to 20 in each book", with ", and 1,000 in all" when the
    /// list stopped there.
    static func showing(perBook: Int, inAll: Int?) -> String {
        // Translators: Note on a finished search's status: the list shows at most this many matches of each book. %lld is the number of matches shown for each book. Starts in lower case because it follows a semicolon.
        let each = InterfaceText.line("librarySearch.showing.each", "showing up to \(number: perBook) in each book")
        guard let inAll else { return each }
        // Translators: Note on a finished search's status: the list also stops after this many matches in all. %1$@ is the note "showing up to 20 in each book", and %2$lld is the number of matches shown in all.
        return InterfaceText.line("librarySearch.showing.value", "\(each), and \(number: inAll) in all")
    }

    /// The note added for books whose text is only in the cloud, which a
    /// search never downloads: "1 book in the cloud wasn't searched", "3
    /// books in the cloud weren't searched".
    static func inCloud(_ count: Int) -> String {
        // Translators: Note on a finished search's status: some books are only in the cloud, and a search never downloads them. %lld is the number of those books. Starts with a number and follows a semicolon.
        InterfaceText.line("librarySearch.inCloud", "\(number: count) books in the cloud weren't searched")
    }

    /// The note added for books whose text could not be read: "1 book
    /// couldn't be read", "2 books couldn't be read".
    static func unreadable(_ count: Int) -> String {
        // Translators: Note on a finished search's status: the text of some books could not be read. %lld is the number of those books. Starts with a number and follows a semicolon.
        InterfaceText.line("librarySearch.unreadable", "\(number: count) books couldn't be read")
    }

    /// A finished search's status, which VoiceOver announces once: what it
    /// found, then, after semicolons, what the list leaves out and which
    /// books were not searched.
    static func finished(found: String, notes: [String]) -> String {
        SentenceWording.semicolonJoined([found] + notes)
    }

    // MARK: - The Results

    /// A book's heading over its matches: its title and author, then how
    /// many matches it holds: "Title, by Author: 12 matches", "...: more
    /// than 1,000 matches".
    static func bookHeading(title: String, author: String, matches: Int, isLowerBound: Bool) -> String {
        let byline = author.isEmpty || author == Book.unknownAuthor ? title : InterfaceText.line(
            // Translators: A book's title and author in a search result's heading. %1$@ is the book's title and %2$@ its author.
            "common.valueCommaByValue", "\(title), by \(author)")
        if isLowerBound {
            // Translators: A book's heading over its search matches when the count stopped at its limit. %1$@ is the book's title, with its author when known, and %2$lld is the number of matches.
            return InterfaceText.line("librarySearch.bookHeading.more", "\(byline): more than \(number: matches) matches")
        }
        // Translators: A book's heading over its search matches. %1$@ is the book's title, with its author when known, and %2$lld is the number of matches.
        return InterfaceText.line("librarySearch.bookHeading.matches", "\(byline): \(number: matches) matches")
    }

    /// A match's row, spoken: the match in its context, where it is, and
    /// the book's title, "…the fox ran…, Chapter 3, in The Long Road". The
    /// context comes first, so moving from row to row hears what differs
    /// first; the title ends it, so a row is never heard without its book.
    static func matchLabel(context: String, location: String?, bookTitle: String) -> String {
        guard let location else {
            // Translators: VoiceOver label of a search match whose place in the book is unknown. %1$@ is the match in its surrounding text, and %2$@ is the book's title.
            return InterfaceText.line("common.valueInValue", "\(context), in \(bookTitle)")
        }
        // Translators: VoiceOver label of a search match: the match in its text, where it is in the book, then the book. %1$@ is the match in its surrounding text, %2$@ is its place, such as a chapter's title, and %3$@ is the book's title.
        return InterfaceText.line("librarySearch.matchLabel", "\(context), \(location), in \(bookTitle)")
    }

    /// A match row's hint.
    static var matchHint: String {
        // Translators: VoiceOver hint of a search match's row in the Search Library window.
        InterfaceText.line("librarySearch.matchHint", "Opens the book at this match")
    }

    /// The row that lists the rest of a book's matches, kept to the first
    /// ones until asked for, where Show All lists up to `limit`: "Show all
    /// 212 matches in The Long Road" when that is every one, and otherwise
    /// how many it lists of how many the book holds, "Show the first 500 of
    /// 700 matches in The Long Road", "Show the first 500 of more than 1,000
    /// matches in The Long Road".
    static func showAll(matches: Int, isLowerBound: Bool, listing limit: Int, bookTitle: String) -> String {
        guard isLowerBound || matches > limit else {
            // Translators: Title of the row that lists all of a book's matches in the Search Library results. %1$lld is the number of matches and %2$@ is the book's title.
            return InterfaceText.line("librarySearch.showAll.matches", "Show all \(number: matches) matches in \(bookTitle)")
        }
        // Translators: Title of the row that lists the first matches of a book that holds more than the list can show. %1$lld is the number listed, %2$@ is the book's total, such as "700" or "more than 1,000", and %3$@ is the book's title.
        return InterfaceText.line("librarySearch.showAll.first", "Show the first \(number: limit) of \(total(matches, isLowerBound: isLowerBound)) matches in \(bookTitle)")
    }

    /// The Show All row's hint.
    static var showAllHint: String {
        // Translators: VoiceOver hint of the row that lists a book's matches in the Search Library results. 500 is the most it lists.
        InterfaceText.line("librarySearch.showAllHint", "Lists up to 500 of this book's matches here")
    }

    /// The row under a book whose matches are more than even Show All lists,
    /// once it lists its most: "Listing 500 of 700 matches: refine the
    /// search to see the rest", "Listing 500 of more than 1,000 matches: …".
    static func listedPart(_ shown: Int, of matches: Int, isLowerBound: Bool) -> String {
        // Translators: Row under a book whose matches are more than the list shows even after Show All. %1$lld is the number listed, and %2$@ is the book's total, such as "700" or "more than 1,000".
        InterfaceText.line("librarySearch.listedPart", "Listing \(number: shown) of \(total(matches, isLowerBound: isLowerBound)) matches: refine the search to see the rest")
    }

    /// Said once Show All has listed a book's matches: "Listing 212 matches
    /// in The Long Road", or, when the book holds more than it lists,
    /// "Listing the first 500 of 700 matches in The Long Road".
    static func listedAll(_ count: Int, of matches: Int, isLowerBound: Bool, bookTitle: String) -> String {
        guard isLowerBound || matches > count else {
            // Translators: Announcement once Show All has listed every match of a book. %1$lld is the number of matches and %2$@ is the book's title.
            return InterfaceText.line("librarySearch.listedAll.listing", "Listing \(number: count) matches in \(bookTitle)")
        }
        // Translators: Announcement once Show All has listed the first matches of a book that holds more. %1$lld is the number listed, %2$@ is the book's total, such as "700" or "more than 1,000", and %3$@ is the book's title.
        return InterfaceText.line("librarySearch.listedAll.first", "Listing the first \(number: count) of \(total(matches, isLowerBound: isLowerBound)) matches in \(bookTitle)")
    }

    /// A book's count of matches as a total: "700", or "more than 1,000"
    /// when the count stopped at its limit.
    private static func total(_ matches: Int, isLowerBound: Bool) -> String {
        guard isLowerBound else { return matches.interfaceFormatted() }
        // Translators: A book's total number of matches when the count stopped at its limit, inside a longer sentence such as "Show the first 500 of more than 1,000 matches". %lld is the number the count stopped at.
        return InterfaceText.line("librarySearch.total", "more than \(number: matches)")
    }

    // MARK: - Opening a Match

    /// Said by the reader once it has moved to a match, naming where it is
    /// when the match is under a heading or in a chapter with a title:
    /// "Moved to the match, Chapter 3." or "Moved to the match."
    static func movedToMatch(location: String?) -> String {
        guard let location else {
            // Translators: Announcement after the reader moved to a search match whose place is unknown.
            return InterfaceText.line("librarySearch.movedToMatch.alone", "Moved to the match.")
        }
        // Translators: Announcement after the reader moved to a search match. %@ is its place, such as a chapter's title.
        return InterfaceText.line("librarySearch.movedToMatch.atPlace", "Moved to the match, \(location).")
    }

    /// Said by the reader when the book's text changed since the search and
    /// the match was found again nearby.
    static var movedToMatchFoundAgain: String {
        // Translators: Announcement when the book's text changed since the search and the reader moved to the nearest match.
        InterfaceText.line("librarySearch.movedToMatchFoundAgain", "The text changed since the search; moved to the nearest match.")
    }

    /// Said by the reader when the book no longer holds the match.
    static var matchGone: String {
        // Translators: Announcement when a search match is no longer in the book's text.
        InterfaceText.line("librarySearch.matchGone", "That match is no longer in the book's text. Search again to find it.")
    }

    /// Said when a match's book has left the library since the search.
    static func bookGone(title: String) -> String {
        // Translators: Announcement when the book of a search match has left the library since the search. %@ is the book's title.
        InterfaceText.line("librarySearch.bookGone", "\(title) is no longer in the library.")
    }
}
