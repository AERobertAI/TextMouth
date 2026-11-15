import Foundation

// MARK: - The Words of Compare Libraries (Phase 0 of the local-first design)

/// Every sentence of Compare Libraries and of Use This Library's account of
/// which copy is newer, built in one place so the sheet, VoiceOver, a braille
/// display, and the tests all read the same words. Each difference is one
/// full sentence that makes sense heard alone, as VoiceOver reads a list row
/// by row.
enum LibraryComparisonWording {
    /// The sheet's title, and the command's.
    static let title = "Compare Libraries"

    /// The title the sheet speaks when it opens, naming what it compares.
    static let sheetLabel = "Compare Libraries, results"

    /// What the Storage settings button says to VoiceOver it does.
    static let buttonHint = "Chooses a folder holding another copy of this library and lists what differs. "
        + "Nothing in either copy is changed."

    /// What this copy and the other are called in a sentence.
    struct Names: Sendable {
        /// The library in use.
        var this: String
        /// The folder compared with it.
        var other: String

        /// The sheet's own names: "this copy" and "the other copy".
        static let sheet = Names(this: "this copy", other: "the other copy")
        /// The names Use This Library's confirmation uses, as it speaks of
        /// a library to switch to.
        static let useThisLibrary = Names(this: "the library in use", other: "the copy in this folder")

        /// The name of `side`.
        func callSide(_ side: LibraryCopySide) -> String {
            side == .thisCopy ? this : other
        }
    }

    /// "on" or "off", for an option's value.
    static func onOrOff(_ value: Bool) -> String {
        value ? "on" : "off"
    }

    /// What a reading list book that neither copy's library holds is called.
    static let unknownBookTitle = "a book that is not in the library"

    // MARK: Counts

    /// The count the list begins with, which VoiceOver reads first.
    /// - Parameter folder: The other copy's folder, by its path.
    static func countSentence(differences: Int, unread: Int, folder: String) -> String {
        let counted = differences == 0
            ? "No differences between this library and the copy in \(folder)."
            : "\(CountWording.phrase(differences, singular: "difference", plural: "differences")) between this library "
                + "and the copy in \(folder)."
        guard unread > 0 else { return counted }
        return counted + " " + unreadCountSentence(unread)
    }

    /// What the files not read mean for the list.
    static func unreadCountSentence(_ count: Int) -> String {
        let files = CountWording.phrase(count, singular: "file", plural: "files")
        return "\(files) couldn't be read, so the comparison may be missing differences. "
            + "They are listed after the differences."
    }

    /// The sentence that opens the results when the library index of a copy
    /// could not be read, so nothing could be compared.
    static func nothingComparedSentence(folder: String) -> String {
        "Nothing could be compared with the copy in \(folder), because a file the comparison needs couldn't be read. "
            + "The files that couldn't be read are listed."
    }

    /// What the sheet says while it works, naming the folder.
    static func comparingSentence(folder: String) -> String {
        "Comparing this library with the copy in \(folder). A library in the cloud can take a while: "
            + "files that are only in the cloud are brought to this Mac to be read. Nothing is changed."
    }

    /// What the sheet says when the folder holds another library.
    static func differentLibrarySentence(folder: String) -> String {
        "The folder \(folder) holds a different library, so nothing was compared."
    }

    /// What the sheet says once the listener stopped it.
    static let stoppedSentence = "Comparing stopped. Nothing was changed."

    /// The folder panel's title, message, and prompt, for choosing the copy.
    static let panelTitle = "Choose the Copy to Compare"
    static let panelMessage = "Choose the folder that holds another copy of this library. Nothing in it is changed."
    static let panelPrompt = "Compare"

    /// The words for a button that copies every sentence of the results.
    static let copyLabel = "Copy Results"
    static let copyHint = "Copies the count and every difference as text, one to a line."
    /// What is announced once the results are on the clipboard.
    static let copiedSentence = "Results copied to the clipboard."
    /// The Storage settings button that opens the sheet, and what VoiceOver calls it.
    static let buttonTitle = "Compare Libraries..."
    /// The button that closes the sheet.
    static let doneLabel = "Done"
    /// The button that stops the comparison.
    static let stopLabel = "Stop"
    static let stopHint = "Stops comparing. Nothing in either copy has been changed."

    /// How many unread files the list names one by one.
    static let unreadListed = 20

    /// The sentence that ends a list of unread files cut short.
    static func moreUnreadSentence(_ count: Int) -> String {
        "And \(CountWording.phrase(count, singular: "more file", plural: "more files")) couldn't be read."
    }

    // MARK: Rows

    /// The sentence for one difference, with `names` for the copies.
    static func sentence(for difference: LibraryDifference, names: Names = .sheet) -> String {
        switch difference {
        case .bookOnlyIn(let side, let book):
            return "Book only in \(names.callSide(side)): \(bookPhrase(book))."
        case .bookFiledDifferently(let book, let thisFolder, let otherFolder):
            return "\(book.title) is filed \(folderPhrase(thisFolder)) in \(names.this) and \(folderPhrase(otherFolder)) "
                + "in \(names.other)."
        case .positionNewer(let book, let side, let newer, let older):
            let olderWords = older.map { "\(names.callSide(side.opposite).capitalizedFirst) has \(placePhrase($0))." }
                ?? "\(names.callSide(side.opposite).capitalizedFirst) has no place saved."
            return "Position in \(book.title): newer in \(names.callSide(side)), \(placePhrase(newer)). \(olderWords)"
        case .positionDiffersAtOnce(let book, let this, let other):
            return "Position in \(book.title): differs, and both were saved at the same time. "
                + "\(names.this.capitalizedFirst) has \(placePhrase(this)); \(names.other) has \(placePhrase(other))."
        case .bookmarkOnlyIn(let side, let book, let bookmark):
            return "Bookmark \(bookmark.number) in \(book.title): only in \(names.callSide(side)), "
                + "\(bookmarkPhrase(bookmark))."
        case .bookmarkDiffers(let book, let this, let other):
            return "Bookmark \(this.number) in \(book.title): differs. \(names.this.capitalizedFirst) has "
                + "\(bookmarkPhrase(this)); \(names.other) has \(bookmarkPhrase(other))."
        case .readingListBookOnlyIn(let side, let book, let place):
            return "Reading list: \(book.title) is only on \(names.callSide(side))'s list, at place \(place)."
        case .readingListOrderDiffers(let thisTitles, let otherTitles):
            return "Reading list: the order differs. \(names.this.capitalizedFirst) has \(CountWording.list(thisTitles)); "
                + "\(names.other) has \(CountWording.list(otherTitles))."
        case .readingListOptionDiffers(let label, let this, let other):
            return "Reading list: “\(label)” is \(this) in \(names.this) and \(other) in \(names.other)."
        case .folderOnlyIn(let side, let path):
            return "Folder “\(path)” is only in \(names.callSide(side))."
        case .folderPathDiffers(let thisPath, let otherPath):
            return "Folder “\(thisPath)” in \(names.this) is “\(otherPath)” in \(names.other)."
        }
    }

    /// The sentence for one file that was not read, as the list ends with.
    /// A file not read is unread, never missing: nothing is known of it.
    static func sentence(for file: LibraryUnreadFile, names: Names = .sheet) -> String {
        let where_ = names.callSide(file.side)
        let what: String
        let consequence: String
        switch file.subject {
        case .identityMarker:
            what = "the identity marker of the library in \(where_)"
            consequence = "so TextMouth can't tell whether the two copies are one library, and compared nothing."
        case .libraryIndex:
            what = "the library index in \(where_)"
            consequence = "so nothing in \(where_) was compared."
        case .record(_, let title):
            what = "the record of \(title) in \(where_)"
            consequence = "so its place and bookmarks there were taken from the library index alone."
        }
        switch file.reason {
        case .notArrived(let seconds):
            return "Unread: \(what) hasn't arrived from the cloud after \(CountWording.seconds(seconds)), \(consequence)"
        case .cannotBeRead(let reason):
            return "Unread: \(what) couldn't be read (\(reason)), \(consequence)"
        case .timeRanOut(let seconds):
            return "Unread: \(what) wasn't read, because TextMouth stopped waiting after \(CountWording.seconds(seconds)) "
                + "in all, \(consequence)"
        case .stillBeingFetched:
            return "Unread: \(what) wasn't asked for again, because the drive hasn't answered an earlier read, \(consequence)"
        }
    }

    /// Why a file was not read, in a clause that follows "couldn't tell which
    /// copy is newer": "the library index in the copy in this folder couldn't
    /// be read (its contents are damaged)".
    static func shortReason(for file: LibraryUnreadFile, names: Names = .useThisLibrary) -> String {
        let where_ = names.callSide(file.side)
        let what: String
        switch file.subject {
        case .identityMarker: what = "the identity marker of \(where_)"
        case .libraryIndex: what = "the library index of \(where_)"
        case .record(_, let title): what = "the record of \(title) in \(where_)"
        }
        switch file.reason {
        case .notArrived(let seconds):
            return "\(what) hadn't arrived from the cloud after \(CountWording.seconds(seconds))"
        case .cannotBeRead(let reason):
            return "\(what) couldn't be read: \(reason)"
        case .timeRanOut(let seconds):
            return "\(what) wasn't read within \(CountWording.seconds(seconds))"
        case .stillBeingFetched:
            return "\(what) wasn't asked for again, because the drive hasn't answered an earlier read"
        }
    }

    /// What Storage settings says while it compares the copy in a chosen
    /// folder with the library in use, to say which is newer.
    static let comparingForUseSentence = "Comparing the library in use with the copy in the folder you chose, to say which is newer."

    // MARK: Pieces

    /// A book as a row names it: its title and, when known, its author.
    private static func bookPhrase(_ book: LibraryBookName) -> String {
        book.author.map { "\(book.title) by \($0)" } ?? book.title
    }

    /// Where a folder path puts a book: at the top of the library, or in the
    /// folder.
    private static func folderPhrase(_ path: String) -> String {
        path.isEmpty ? "at the top of the library" : "in the folder “\(path)”"
    }

    /// A place as "chapter 3, 41%".
    static func placePhrase(_ place: LibraryPlaceName) -> String {
        place.percent.map { "chapter \(place.chapter), \($0)%" } ?? "chapter \(place.chapter)"
    }

    /// A bookmark's place and note: "chapter 3, with the note “Check this”".
    private static func bookmarkPhrase(_ bookmark: LibraryBookmarkName) -> String {
        bookmark.note.isEmpty
            ? "chapter \(bookmark.chapter), with no note"
            : "chapter \(bookmark.chapter), with the note “\(bookmark.note)”"
    }

    // MARK: Which Copy Is Newer

    /// What Use This Library says of the folder chosen, which holds another
    /// copy of the library in use: which copy has the newer places and
    /// what only each holds, from the same comparison Compare Libraries
    /// lists. It replaces the words "may not have its latest changes".
    ///
    /// - Parameter comparison: The result, or nil when it could not be made.
    /// - Parameter reason: Why it could not, in words, when `comparison` is nil.
    static func newerCopySentence(_ comparison: LibraryComparison?, reason: String?, names: Names = .useThisLibrary) -> String {
        let pointer = "Compare Libraries in Storage settings lists every difference."
        guard let comparison else {
            let why = reason.map { " (\($0))" } ?? ""
            return "This folder holds another copy of the library TextMouth is using. "
                + "TextMouth couldn't tell which copy is newer\(why). \(pointer)"
        }
        let lead = "This folder holds another copy of the library TextMouth is using."
        let here = changesOnly(in: .thisCopy, comparison)
        let there = changesOnly(in: .otherCopy, comparison)
        let unread = comparison.unread.isEmpty
            ? ""
            : " TextMouth couldn't read \(CountWording.phrase(comparison.unread.count, singular: "file", plural: "files")), "
                + "so this may be incomplete."
        switch (here, there) {
        case (nil, nil) where comparison.differences.isEmpty:
            return "\(lead) It has the same books, places, bookmarks, reading list, and folders.\(unread)"
        case (nil, nil):
            return "\(lead) Neither has newer places or books the other lacks, but they differ in other ways.\(unread) \(pointer)"
        case (let here?, nil):
            return "\(lead) \(names.this.capitalizedFirst) is the newer. It has \(here).\(unread) \(pointer)"
        case (nil, let there?):
            return "\(lead) \(names.other.capitalizedFirst) is the newer. It has \(there).\(unread) \(pointer)"
        case (let here?, let there?):
            return "\(lead) Neither is newer: each has changes the other lacks. "
                + "\(names.this.capitalizedFirst) has \(here). \(names.other.capitalizedFirst) has \(there).\(unread) \(pointer)"
        }
    }

    /// What only `side` has, as a phrase such as "newer places in 3 books,
    /// 2 books the other lacks, and 1 bookmark the other lacks"; nil when it
    /// has nothing the other lacks.
    private static func changesOnly(in side: LibraryCopySide, _ comparison: LibraryComparison) -> String? {
        var parts: [String] = []
        let places = comparison.newerPositions(in: side)
        if places > 0 {
            parts.append("newer places in \(CountWording.books(places))")
        }
        let books = comparison.booksOnlyIn(side)
        if books > 0 {
            parts.append("\(CountWording.books(books)) the other lacks")
        }
        let bookmarks = comparison.bookmarksOnlyIn(side)
        if bookmarks > 0 {
            parts.append("\(CountWording.bookmarks(bookmarks)) the other lacks")
        }
        return parts.isEmpty ? nil : CountWording.list(parts)
    }
}

private extension String {
    /// The string with its first letter capitalized, the rest as it is.
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
