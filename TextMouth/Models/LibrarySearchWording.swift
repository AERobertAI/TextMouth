import Foundation

/// What Search Library shows and says (LIBRARY-SEARCH-RESEARCH-2026-11-13.md),
/// in one place, so the words on screen and the words VoiceOver speaks agree
/// and tests can pin them.
enum LibrarySearchWording {

    // MARK: - The Window

    /// The window's title, which VoiceOver names it by, and the command's
    /// name in the Edit menu's Find submenu, without its ellipsis.
    static let windowTitle = "Search Library"

    /// The search field's label.
    static let fieldLabel = "Search the library"

    /// The search field's placeholder, shown while it is empty.
    static let fieldPrompt = "Text to find in every book"

    /// The search field's hint.
    static let fieldHint = "Type to search the text of every book in the library"

    /// The Regular Expression checkbox's title and label.
    static let regexLabel = "Regular Expression"

    /// The Regular Expression checkbox's hint.
    static let regexHint = "When checked, the search text is an ICU regular expression"

    /// The label of the list of results.
    static let resultsLabel = "Results"

    /// The name of the rotor that lists each book with matches.
    static let booksRotor = "Books"

    /// The name of the rotor that lists each match listed.
    static let matchesRotor = "Matches"

    /// The Close button's title.
    static let closeButton = "Close"

    /// The Close button's hint.
    static let closeHint = "Close Search Library; its results stay for the next time it opens"

    // MARK: - The Status

    /// Said before anything is typed.
    static let idle = "Type text to find in every book of the library."

    /// Said while a search runs, before any book is done: "Searching 750
    /// books…", or "Searching…" while typing pauses, before the books are
    /// counted.
    static func searching(books: Int) -> String {
        books == 0 ? "Searching…" : "Searching \(countedBooks(books))…"
    }

    /// Said while a search runs, once some books are done: "Searched 120 of
    /// 750 books…".
    static func searched(_ done: Int, of total: Int) -> String {
        "Searched \(done.formatted()) of \(countedBooks(total))…"
    }

    /// Said while a search runs that has had to prepare a book on its way,
    /// parsing its text because this Mac's search texts did not hold it (the
    /// first search after an installation or after macOS emptied the Caches
    /// folder, before the background preparation reached the book), so the
    /// listener knows why it takes longer: "Preparing 120 of 737 books…".
    static func preparing(_ done: Int, of total: Int) -> String {
        "Preparing \(done.formatted()) of \(countedBooks(total))…"
    }

    /// The opening of a stopped search's status, before what it had found:
    /// "Stopped after 120 of 750 books:".
    static func stopped(searched: Int, of total: Int) -> String {
        "Stopped after \(searched.formatted()) of \(countedBooks(total)):"
    }

    /// The Stop button's title, shown while a search runs.
    static let stopButton = "Stop"

    /// The Stop button's hint.
    static let stopHint = "Stops the search, keeping the matches found so far"

    /// The label of the progress bar shown while a search runs.
    static let progressLabel = "Search progress"

    /// Said when the library holds no book with a text to search.
    static let noBooks = "No book in the library has text to search."

    /// The opening of an invalid regular expression's status, as Search in
    /// Book words it: "Invalid regular expression: <reason>".
    static func invalidPattern(_ reason: String) -> String {
        "Invalid regular expression: \(reason)"
    }

    /// How many matches were found in how many books: "No matches", "1
    /// match in 1 book", "212 matches in 31 books", or, when a book's count
    /// stopped at its limit, "More than 41,000 matches in 750 books".
    static func found(matches: Int, books: Int, isLowerBound: Bool) -> String {
        guard matches > 0 else { return "No matches" }
        let counted = matches == 1 ? "1 match" : "\(matches.formatted()) matches"
        let lead = isLowerBound ? "More than \(counted)" : counted
        return "\(lead) in \(countedBooks(books))"
    }

    /// The note added when the list shows fewer matches than were found:
    /// "showing up to 20 in each book", with ", and 1,000 in all" when the
    /// list stopped there.
    static func showing(perBook: Int, inAll: Int?) -> String {
        let each = "showing up to \(perBook.formatted()) in each book"
        guard let inAll else { return each }
        return "\(each), and \(inAll.formatted()) in all"
    }

    /// The note added for books whose text is only in the cloud, which a
    /// search never downloads: "1 book in the cloud wasn't searched", "3
    /// books in the cloud weren't searched".
    static func inCloud(_ count: Int) -> String {
        count == 1 ? "1 book in the cloud wasn't searched" : "\(count.formatted()) books in the cloud weren't searched"
    }

    /// The note added for books whose text could not be read: "1 book
    /// couldn't be read", "2 books couldn't be read".
    static func unreadable(_ count: Int) -> String {
        "\(countedBooks(count)) couldn't be read"
    }

    /// A finished search's status, which VoiceOver announces once: what it
    /// found, then, after semicolons, what the list leaves out and which
    /// books were not searched.
    static func finished(found: String, notes: [String]) -> String {
        ([found] + notes).joined(separator: "; ")
    }

    // MARK: - The Results

    /// A book's heading over its matches: its title and author, then how
    /// many matches it holds: "Title, by Author: 12 matches", "...: more
    /// than 1,000 matches".
    static func bookHeading(title: String, author: String, matches: Int, isLowerBound: Bool) -> String {
        let byline = author.isEmpty || author == Book.unknownAuthor ? title : "\(title), by \(author)"
        let counted = matches == 1 ? "1 match" : "\(matches.formatted()) matches"
        return "\(byline): \(isLowerBound ? "more than \(counted)" : counted)"
    }

    /// A match's row, spoken: the match in its context, where it is, and
    /// the book's title, "…the fox ran…, Chapter 3, in The Long Road". The
    /// context comes first, so moving from row to row hears what differs
    /// first; the title ends it, so a row is never heard without its book.
    static func matchLabel(context: String, location: String?, bookTitle: String) -> String {
        ([context, location].compactMap { $0 } + ["in \(bookTitle)"]).joined(separator: ", ")
    }

    /// A match row's hint.
    static let matchHint = "Opens the book at this match"

    /// The row that lists the rest of a book's matches, kept to the first
    /// ones until asked for, where Show All lists up to `limit`: "Show all
    /// 212 matches in The Long Road" when that is every one, and otherwise
    /// how many it lists of how many the book holds, "Show the first 500 of
    /// 700 matches in The Long Road", "Show the first 500 of more than 1,000
    /// matches in The Long Road".
    static func showAll(matches: Int, isLowerBound: Bool, listing limit: Int, bookTitle: String) -> String {
        guard isLowerBound || matches > limit else {
            return "Show all \(matches.formatted()) matches in \(bookTitle)"
        }
        return "Show the first \(limit.formatted()) of \(total(matches, isLowerBound: isLowerBound)) matches in \(bookTitle)"
    }

    /// The Show All row's hint.
    static let showAllHint = "Lists up to 500 of this book's matches here"

    /// The row under a book whose matches are more than even Show All lists,
    /// once it lists its most: "Listing 500 of 700 matches: refine the
    /// search to see the rest", "Listing 500 of more than 1,000 matches: …".
    static func listedPart(_ shown: Int, of matches: Int, isLowerBound: Bool) -> String {
        "Listing \(shown.formatted()) of \(total(matches, isLowerBound: isLowerBound)) matches: refine the search to see the rest"
    }

    /// Said once Show All has listed a book's matches: "Listing 212 matches
    /// in The Long Road", or, when the book holds more than it lists,
    /// "Listing the first 500 of 700 matches in The Long Road".
    static func listedAll(_ count: Int, of matches: Int, isLowerBound: Bool, bookTitle: String) -> String {
        guard isLowerBound || matches > count else {
            return "Listing \(count == 1 ? "1 match" : "\(count.formatted()) matches") in \(bookTitle)"
        }
        return "Listing the first \(count.formatted()) of \(total(matches, isLowerBound: isLowerBound)) matches in \(bookTitle)"
    }

    /// A book's count of matches as a total: "700", or "more than 1,000"
    /// when the count stopped at its limit.
    private static func total(_ matches: Int, isLowerBound: Bool) -> String {
        isLowerBound ? "more than \(matches.formatted())" : matches.formatted()
    }

    // MARK: - Opening a Match

    /// Said by the reader once it has moved to a match, naming where it is
    /// when the match is under a heading or in a chapter with a title:
    /// "Moved to the match, Chapter 3." or "Moved to the match."
    static func movedToMatch(location: String?) -> String {
        guard let location else { return "Moved to the match." }
        return "Moved to the match, \(location)."
    }

    /// Said by the reader when the book's text changed since the search and
    /// the match was found again nearby.
    static let movedToMatchFoundAgain = "The text changed since the search; moved to the nearest match."

    /// Said by the reader when the book no longer holds the match.
    static let matchGone = "That match is no longer in the book's text. Search again to find it."

    /// Said when a match's book has left the library since the search.
    static func bookGone(title: String) -> String {
        "\(title) is no longer in the library."
    }

    // MARK: - Counting

    /// `count` books, the count grouped by thousands: "1 book", "750 books".
    private static func countedBooks(_ count: Int) -> String {
        count == 1 ? "1 book" : "\(count.formatted()) books"
    }
}
