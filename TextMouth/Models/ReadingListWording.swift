import Foundation

/// What TextMouth shows and says of the reading list (FR09), in one place,
/// so the words on screen and the words VoiceOver speaks agree and tests
/// can pin them.
enum ReadingListWording {

    // MARK: - The Rows

    /// What a book's row says of a book in the reading list: spoken in the
    /// row's label, right after its title and author, in every view but the
    /// Reading List itself, where every row's book is in the list.
    static let inReadingListNote = "In reading list"

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

    // MARK: - The Options Bar

    /// The label of the options bar's picker of what a book opened from the
    /// reading list does when it ends, whose options are
    /// `ReadingList.Continuation.title`.
    static let continuationLabel = "When a book ends"

    /// The picker's hint: which books it applies to, and what each option
    /// does.
    static let continuationHint = "For a book opened from the reading list: "
        + "play the book below it or the book above it when it ends, or stop"

    /// The label of the options bar's checkbox for passing over finished
    /// books.
    static let skipFinishedLabel = "Skip finished books"

    /// The checkbox's hint: when it applies, and what it does.
    static let skipFinishedHint = "When a book opened from the reading list ends, pass over the books already finished"

    /// The label of the options bar's checkbox for taking books off the list
    /// as they are finished.
    static let removeFinishedLabel = "Remove books when finished"

    /// The checkbox's hint: when it applies, and what it does. It says that
    /// only books finished from then on leave the list, so no one expects
    /// the books already finished to go at once.
    static let removeFinishedHint = "When a book is finished, take it off the reading list. "
        + "A finished book stays on the list while its reader window is open on it, and leaves when the window moves on or closes. "
        + "Books finished before you turn this on stay on it. Books stay in the library."

    /// The label of the options bar's checkbox for keeping the list's books
    /// downloaded on this Mac, shown only while the library is in the cloud.
    static let keepBooksLabel = "Keep these books on this Mac"

    /// The checkbox's hint: what it does, and that the choice is this Mac's
    /// own. Nothing is removed from this Mac by clearing it.
    static let keepBooksHint = "Keeps the books on the reading list downloaded on this Mac, as Keep on This Mac does. "
        + "This choice is this Mac's alone. Clearing it removes no download."

    /// What lets a book go that this Mac keeps for the reading list: take it
    /// off the list, or clear the options bar's keep choice, which keeps all
    /// the list's books. "Take it off the reading list, or clear Keep these
    /// books on this Mac in the Reading List's options" begins a sentence;
    /// "take it off ..." follows one.
    /// - Parameters:
    ///   - plural: Whether it is about several books ("them").
    ///   - capitalized: Whether the sentence begins with this advice.
    static func letGoOfBooksAdvice(plural: Bool, capitalized: Bool) -> String {
        let take = capitalized ? "Take" : "take"
        return "\(take) \(plural ? "them" : "it") off the reading list, or clear \(keepBooksLabel) in the Reading List's options"
    }

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

    // MARK: - The Edit-Mode Bar

    /// The title of the edit-mode bar's button for a command of `kind`: its
    /// plain name, "Add to Reading List" or "Remove from Reading List", as
    /// the Library menu names it; the bar's own "3 of 12 selected" says how
    /// many books are chosen.
    static func editBarTitle(_ kind: ReadingListCommand.Kind) -> String {
        switch kind {
        case .add: return addTitle(count: 1, forSelection: false)
        case .remove: return removeTitle(count: 1, forSelection: false)
        }
    }

    /// What VoiceOver calls the edit-mode bar's button for a command of
    /// `kind` acting on `count` books, as the bar's Move button counts its
    /// books: "Add 3 books to the reading list", "Remove 1 book from the
    /// reading list"; with no book to act on, while the button is dimmed,
    /// its plain name.
    static func editBarLabel(_ kind: ReadingListCommand.Kind, count: Int) -> String {
        guard count > 0 else { return editBarTitle(kind) }
        switch kind {
        case .add: return "Add \(CountWording.books(count)) to the reading list"
        case .remove: return "Remove \(CountWording.books(count)) from the reading list"
        }
    }

    /// The hint of the edit-mode bar's button for a command of `kind`: what
    /// it does with the selected books.
    static func editBarHint(_ kind: ReadingListCommand.Kind) -> String {
        switch kind {
        case .add: return "Adds the selected books to the end of the reading list."
        case .remove: return "Takes the selected books off the reading list. They stay in the library."
        }
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

    /// What VoiceOver hears after an import made at the Reading List added
    /// `titles`, the titles of the books it made, in order, to the end of
    /// the list: that they joined it, as Add to Reading List says it, and,
    /// since the list is no folder, the folder the books themselves went to,
    /// `folderPath`, named as the folder pickers name it: "Added to reading
    /// list: Moby-Dick. The book is in Essays/Sea." or "Added 3 books to the
    /// reading list. The books are in Library Root."
    static func importedAnnouncement(added titles: [String], folderPath: String) -> String {
        let folder = folderPath.isEmpty ? LibraryFolderOption.rootLabel : folderPath
        let place = titles.count == 1 ? "The book is in \(folder)." : "The books are in \(folder)."
        return sentences(addedAnnouncement(added: titles, alreadyIn: 0), place)
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
