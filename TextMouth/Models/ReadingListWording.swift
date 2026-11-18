import Foundation

/// What TextMouth shows and says of the reading list (FR09), in one place,
/// so the words on screen and the words VoiceOver speaks agree and tests
/// can pin them.
///
/// Localized (FR35): each text is computed, so it is read from the String
/// Catalog in the interface's language whenever it is asked for; a count is
/// one sentence with its own plural forms in the catalog, never a sentence
/// built around English's "book" and "books".
enum ReadingListWording {

    // MARK: - The Rows

    /// What a book's row says of a book in the reading list: spoken in the
    /// row's label, right after its title and author, in every view but the
    /// Reading List itself, where every row's book is in the list.
    static var inReadingListNote: String {
        String(localized: "In reading list",
               comment: "Part of a library row's VoiceOver label, after the book's title and author: the book is on the reading list.")
    }

    // MARK: - The Order

    /// The name of the one order the Reading List shows its books in: the
    /// order the user arranges, which its Sort menu names, checked, and the
    /// only item it offers.
    static var orderName: String {
        String(localized: "Reading List Order",
               comment: "Name of the order the Reading List shows its books in, the one the listener arranges: the only item of its Sort menu.")
    }

    /// The Sort button's spoken label at the Reading List, as the Sort
    /// button elsewhere names the sort it shows ("Sort books by Title,
    /// ascending").
    static var sortMenuLabel: String {
        String(localized: "Sort books by \(orderName)",
               comment: "VoiceOver label of the Library's Sort button while the Reading List shows. %@ is the name of the Reading List's order, Reading List Order.")
    }

    /// What VoiceOver says when the user chooses the Reading List's order,
    /// as choosing a sort elsewhere says the sort now shown.
    static var orderAnnouncement: String {
        String(localized: "Sorted by \(orderName)",
               comment: "VoiceOver announcement after the Reading List's order was chosen in its Sort menu. %@ is the order's name, Reading List Order.")
    }

    /// The hint of the Reading List's one sort item: how its order changes.
    static var orderHint: String {
        String(localized: "Keeps the order you set with Move Book Up, Move Book Down, or dragging.",
               comment: "VoiceOver hint of the Reading List Order item of the Reading List's Sort menu. Move Book Up and Move Book Down are commands of the Library menu.")
    }

    // MARK: - The Options Bar

    /// The label of the options bar's picker of what a book opened from the
    /// reading list does when it ends, whose options are
    /// `ReadingList.Continuation.title`.
    static var continuationLabel: String {
        String(localized: "When a book ends",
               comment: "Label of the Reading List's options bar pop-up button choosing what a book opened from the list does when it ends: play the book below, play the book above, or stop.")
    }

    /// The picker's hint: which books it applies to, and what each option
    /// does.
    static var continuationHint: String {
        String(localized: "Chooses what a book opened from the list does when it ends.",
               comment: "VoiceOver hint of the Reading List's When a book ends pop-up button.")
    }

    /// The label of the options bar's checkbox for passing over finished
    /// books.
    static var skipFinishedLabel: String {
        String(localized: "Skip finished books",
               comment: "Checkbox of the Reading List's options bar: when a book opened from the list ends, pass over the finished books.")
    }

    /// The checkbox's hint: when it applies, and what it does.
    static var skipFinishedHint: String {
        String(localized: "Passes over finished books when a book from the list ends.",
               comment: "VoiceOver hint of the Reading List's Skip finished books checkbox.")
    }

    /// The label of the options bar's checkbox for taking books off the list
    /// as they are finished.
    static var removeFinishedLabel: String {
        String(localized: "Remove books when finished",
               comment: "Checkbox of the Reading List's options bar: take each book off the list once it is finished.")
    }

    /// The checkbox's hint: when it applies, and what it does. It says that
    /// only books finished from then on leave the list, so no one expects
    /// the books already finished to go at once.
    static var removeFinishedHint: String {
        String(localized: "Takes each finished book off the list when its window moves on or closes. Books finished before stay.",
               comment: "VoiceOver hint of the Reading List's Remove books when finished checkbox.")
    }

    /// The label of the options bar's checkbox for keeping the list's books
    /// downloaded on this Mac, shown only while the library is in the cloud.
    static var keepBooksLabel: String {
        String(localized: "Keep these books on this Mac",
               comment: "Checkbox of the Reading List's options bar, shown while the library is in iCloud: keep the list's books downloaded on this Mac.")
    }

    /// The checkbox's hint: what it does, and that the choice is this Mac's
    /// own. Nothing is removed from this Mac by clearing it.
    static var keepBooksHint: String {
        String(localized: "Keeps the list's books downloaded on this Mac alone. Clearing it removes no download.",
               comment: "VoiceOver hint of the Reading List's Keep these books on this Mac checkbox: a choice of this Mac's alone.")
    }

    /// What lets a book go that this Mac keeps for the reading list: take it
    /// off the list, or clear the options bar's keep choice, which keeps all
    /// the list's books. "Take it off the reading list, or clear Keep these
    /// books on this Mac in the Reading List's options" begins a sentence;
    /// "take it off ..." follows one. Each of the four is whole (FR35): the
    /// cloud's sentences put it inside their own until that area's
    /// sentences are made whole too.
    /// - Parameters:
    ///   - plural: Whether it is about several books ("them").
    ///   - capitalized: Whether the sentence begins with this advice.
    static func letGoOfBooksAdvice(plural: Bool, capitalized: Bool) -> String {
        switch (plural, capitalized) {
        case (false, true):
            return String(localized: "Take it off the reading list, or clear \(keepBooksLabel) in the Reading List's options",
                          comment: "Advice that begins a sentence of the iCloud library's messages, on letting go of a book this Mac keeps for the reading list; the sentence goes on after it. %@ is the name of the checkbox Keep these books on this Mac.")
        case (true, true):
            return String(localized: "Take them off the reading list, or clear \(keepBooksLabel) in the Reading List's options",
                          comment: "Advice that begins a sentence of the iCloud library's messages, on letting go of several books this Mac keeps for the reading list; the sentence goes on after it. %@ is the name of the checkbox Keep these books on this Mac.")
        case (false, false):
            return String(localized: "take it off the reading list, or clear \(keepBooksLabel) in the Reading List's options",
                          comment: "Advice inside a sentence of the iCloud library's messages, after \"To let it go,\" or \"Then\": on letting go of a book this Mac keeps for the reading list. Lowercase. %@ is the name of the checkbox Keep these books on this Mac.")
        case (true, false):
            return String(localized: "take them off the reading list, or clear \(keepBooksLabel) in the Reading List's options",
                          comment: "Advice inside a sentence of the iCloud library's messages, after \"To let them go,\": on letting go of several books this Mac keeps for the reading list. Lowercase. %@ is the name of the checkbox Keep these books on this Mac.")
        }
    }

    // MARK: - The Empty List

    /// What the Reading List shows, as a row VoiceOver reads, while the
    /// list holds no book: that it is empty, and how a book joins it.
    static var emptyList: String {
        String(localized: "The reading list is empty. To add a book, choose Add to Reading List from its context menu, its VoiceOver actions, or the Library menu.",
               comment: "Shown and read as the only row of the Reading List while it holds no book. Add to Reading List is the name of the command in the Library menu.")
    }

    // MARK: - The Commands

    /// The title of Add to Reading List for `count` books: its plain name,
    /// as the Library menu names it, for the one book a row's menu is for,
    /// or a title counting the books of a selection, as "Add 3 Books to
    /// Reading List".
    static func addTitle(count: Int, forSelection: Bool) -> String {
        guard forSelection else { return ShortcutAction.addToReadingList.title }
        return String(localized: "Add \(count) Books to Reading List",
                      comment: "Context menu item for the books selected in the Library: adds them to the reading list. Title case. %lld is the number of books selected.")
    }

    /// The title of Remove from Reading List for `count` books: its plain
    /// name for one book, or "Remove 3 Books from Reading List" for a
    /// selection.
    static func removeTitle(count: Int, forSelection: Bool) -> String {
        guard forSelection else { return ShortcutAction.removeFromReadingList.title }
        return String(localized: "Remove \(count) Books from Reading List",
                      comment: "Context menu item for the books selected in the Library: takes them off the reading list. Title case. %lld is the number of books selected.")
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
        case .add:
            return String(localized: "Add \(count) books to the reading list",
                          comment: "VoiceOver label of the Library's edit-mode bar button that adds the selected books to the reading list. %lld is the number of books selected.")
        case .remove:
            return String(localized: "Remove \(count) books from the reading list",
                          comment: "VoiceOver label of the Library's edit-mode bar button that takes the selected books off the reading list. %lld is the number of books selected.")
        }
    }

    /// The hint of the edit-mode bar's button for a command of `kind`: what
    /// it does with the selected books.
    static func editBarHint(_ kind: ReadingListCommand.Kind) -> String {
        switch kind {
        case .add:
            return String(localized: "Adds the selected books to the end of the reading list.",
                          comment: "VoiceOver hint of the Library's edit-mode bar button Add to Reading List.")
        case .remove:
            return String(localized: "Takes the selected books off the reading list. They stay in the library.",
                          comment: "VoiceOver hint of the Library's edit-mode bar button Remove from Reading List.")
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
            ? String(localized: "Added to reading list: \(titles.first ?? "")",
                     comment: "VoiceOver announcement after one book was added to the reading list. %@ is the book's title.")
            : String(localized: "Added \(titles.count) books to the reading list.",
                     comment: "VoiceOver announcement after several books were added to the reading list. %lld is the number of books added.")
        guard alreadyIn > 0 else { return done }
        return sentences(done, String(localized: "\(alreadyIn) books were already in it.",
                                      comment: "Second sentence of the announcement after books were added to the reading list: some chosen were on it already. %lld is how many."))
    }

    /// What VoiceOver hears after Remove from Reading List took off
    /// `removed`, the titles of the books taken off, in the list's order:
    /// "Removed from reading list: Moby-Dick" for one, "Removed 3 books from
    /// the reading list." for several; then, when `notIn` of the books
    /// chosen were not in the list, how many, as in "2 books were not in
    /// it."
    static func removedAnnouncement(removed titles: [String], notIn: Int) -> String {
        let done = titles.count == 1
            ? String(localized: "Removed from reading list: \(titles.first ?? "")",
                     comment: "VoiceOver announcement after one book was taken off the reading list. %@ is the book's title.")
            : String(localized: "Removed \(titles.count) books from the reading list.",
                     comment: "VoiceOver announcement after several books were taken off the reading list. %lld is the number of books taken off.")
        guard notIn > 0 else { return done }
        return sentences(done, String(localized: "\(notIn) books were not in it.",
                                      comment: "Second sentence of the announcement after books were taken off the reading list: some chosen were not on it. %lld is how many."))
    }

    /// What VoiceOver hears after an import made at the Reading List added
    /// `titles`, the titles of the books it made, in order, to the end of
    /// the list: that they joined it, as Add to Reading List says it, and,
    /// since the list is no folder, the folder the books themselves went to,
    /// `folderPath`, named as the folder pickers name it: "Added to reading
    /// list: Moby-Dick. The book is in Essays/Sea." or "Added 3 books to the
    /// reading list. The books are in Library Root." The second sentence is
    /// chosen by whether one book came, since it names no number.
    static func importedAnnouncement(added titles: [String], folderPath: String) -> String {
        let folder = folderPath.isEmpty ? LibraryFolderOption.rootLabel : folderPath
        let place = titles.count == 1
            ? String(localized: "The book is in \(folder).",
                     comment: "Second sentence of the announcement after an import at the Reading List added one book to it: the library folder the book went to. %@ is the folder's path, such as Essays/Sea, or Library Root.")
            : String(localized: "The books are in \(folder).",
                     comment: "Second sentence of the announcement after an import at the Reading List added several books to it: the library folder they went to. %@ is the folder's path, such as Essays/Sea, or Library Root.")
        return sentences(addedAnnouncement(added: titles, alreadyIn: 0), place)
    }

    /// Why Add to Reading List from the Library menu added nothing, for the
    /// books selected, titled `titles`: none is selected, or every one is
    /// in the list already.
    static func addRefusal(selected titles: [String]) -> String {
        guard !titles.isEmpty else { return LibraryCloudWording.noBooksSelected }
        if titles.count == 1, let title = titles.first {
            return String(localized: "\(title) is already in the reading list.",
                          comment: "VoiceOver announcement when Add to Reading List added nothing: the one book selected is on the list already. %@ is the book's title.")
        }
        return String(localized: "The \(titles.count) selected books are already in the reading list.",
                      comment: "VoiceOver announcement when Add to Reading List added nothing: every book selected is on the list already. %lld is the number of books selected (two or more).")
    }

    /// Why Remove from Reading List from the Library menu took nothing off,
    /// for the books selected, titled `titles`: none is selected, or none
    /// of them is in the list.
    static func removeRefusal(selected titles: [String]) -> String {
        guard !titles.isEmpty else { return LibraryCloudWording.noBooksSelected }
        if titles.count == 1, let title = titles.first {
            return String(localized: "\(title) isn't in the reading list.",
                          comment: "VoiceOver announcement when Remove from Reading List took nothing off: the one book selected is not on the list. %@ is the book's title.")
        }
        return String(localized: "None of the \(titles.count) selected books is in the reading list.",
                      comment: "VoiceOver announcement when Remove from Reading List took nothing off: no book selected is on the list. %lld is the number of books selected (two or more).")
    }

    /// `first` followed by `second` as two sentences: `first` ends with a
    /// period when it has none. Joined with a full stop and a space, as
    /// English and Spanish join sentences; a language that ends a sentence
    /// otherwise needs this localized too, a later item.
    private static func sentences(_ first: String, _ second: String) -> String {
        "\(first.hasSuffix(".") ? first : first + ".") \(second)"
    }
}
