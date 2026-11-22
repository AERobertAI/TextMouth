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
        // Translators: Part of a library row's VoiceOver label, after the book's title and author: the book is on the reading list.
        InterfaceText.line("readingList.inReadingListNote", "In reading list")
    }

    // MARK: - The Order

    /// The name of the one order the Reading List shows its books in: the
    /// order the user arranges, which its Sort menu names, checked, and the
    /// only item it offers.
    static var orderName: String {
        // Translators: Name of the order the Reading List shows its books in, the one the listener arranges: the only item of its Sort menu.
        InterfaceText.line("readingList.orderName", "Reading List Order")
    }

    /// The Sort button's spoken label at the Reading List, as the Sort
    /// button elsewhere names the sort it shows ("Sort books by Title,
    /// ascending").
    static var sortMenuLabel: String {
        // Translators: VoiceOver label of the Library's Sort button while the Reading List shows. %@ is the name of the Reading List's order, Reading List Order.
        InterfaceText.line("common.sortBooksByValue", "Sort books by \(orderName)")
    }

    /// What VoiceOver says when the user chooses the Reading List's order,
    /// as choosing a sort elsewhere says the sort now shown.
    static var orderAnnouncement: String {
        // Translators: VoiceOver announcement after the Reading List's order was chosen in its Sort menu. %@ is the order's name, Reading List Order.
        InterfaceText.line("common.sortedByValue", "Sorted by \(orderName)")
    }

    /// The hint of the Reading List's one sort item: how its order changes.
    static var orderHint: String {
        // Translators: VoiceOver hint of the Reading List Order item of the Reading List's Sort menu. Move Book Up and Move Book Down are commands of the Library menu.
        InterfaceText.line("readingList.orderHint", "Keeps the order you set with Move Book Up, Move Book Down, or dragging.")
    }

    // MARK: - The Options Bar

    /// The label of the options bar's picker of what a book opened from the
    /// reading list does when it ends, whose options are
    /// `ReadingList.Continuation.title`.
    static var continuationLabel: String {
        // Translators: Label of the Reading List's options bar pop-up button choosing what a book opened from the list does when it ends: play the book below, play the book above, or stop.
        InterfaceText.line("common.whenABookEnds", "When a book ends")
    }

    /// The picker's hint: which books it applies to, and what each option
    /// does.
    static var continuationHint: String {
        // Translators: VoiceOver hint of the Reading List's When a book ends pop-up button.
        InterfaceText.line("readingList.continuationHint", "Chooses what a book opened from the list does when it ends.")
    }

    /// The label of the options bar's checkbox for passing over finished
    /// books.
    static var skipFinishedLabel: String {
        // Translators: Checkbox of the Reading List's options bar: when a book opened from the list ends, pass over the finished books.
        InterfaceText.line("common.skipFinishedBooks", "Skip finished books")
    }

    /// The checkbox's hint: when it applies, and what it does.
    static var skipFinishedHint: String {
        // Translators: VoiceOver hint of the Reading List's Skip finished books checkbox.
        InterfaceText.line("readingList.skipFinishedHint", "Passes over finished books when a book from the list ends.")
    }

    /// The label of the options bar's checkbox for taking books off the list
    /// as they are finished.
    static var removeFinishedLabel: String {
        // Translators: Checkbox of the Reading List's options bar: take each book off the list once it is finished.
        InterfaceText.line("readingList.removeFinishedLabel", "Remove books when finished")
    }

    /// The checkbox's hint: when it applies, and what it does. It says that
    /// only books finished from then on leave the list, so no one expects
    /// the books already finished to go at once.
    static var removeFinishedHint: String {
        // Translators: VoiceOver hint of the Reading List's Remove books when finished checkbox.
        InterfaceText.line("readingList.removeFinishedHint", "Takes each finished book off the list when its window moves on or closes. Books finished before you turn it on stay.")
    }

    /// The label of the options bar's checkbox for keeping the list's books
    /// downloaded on this Mac, shown only while the library is in the cloud.
    static var keepBooksLabel: String {
        // Translators: Checkbox of the Reading List's options bar, shown while the library is in iCloud: keep the list's books downloaded on this Mac.
        InterfaceText.line("readingList.keepBooksLabel", "Keep these books on this Mac")
    }

    /// The checkbox's hint: what it does, and that the choice is this Mac's
    /// own. Nothing is removed from this Mac by clearing it.
    static var keepBooksHint: String {
        // Translators: VoiceOver hint of the Reading List's Keep these books on this Mac checkbox: a choice of this Mac's alone.
        InterfaceText.line("readingList.keepBooksHint", "Keeps the list's books downloaded on this Mac; each Mac chooses for itself. Clearing it removes no download.")
    }

    // MARK: - The Empty List

    /// What the Reading List shows, as a row VoiceOver reads, while the
    /// list holds no book: that it is empty, and how a book joins it.
    static var emptyList: String {
        // Translators: Shown and read as the only row of the Reading List while it holds no book. Add to Reading List is the name of the command in the Library menu.
        InterfaceText.line("readingList.emptyList", "The reading list is empty. To add a book, choose Add to Reading List from its context menu, its VoiceOver actions, or the Library menu.")
    }

    // MARK: - The Commands

    /// The title of Add to Reading List for `count` books: its plain name,
    /// as the Library menu names it, for the one book a row's menu is for,
    /// or a title counting the books of a selection, as "Add 3 Books to
    /// Reading List".
    static func addTitle(count: Int, forSelection: Bool) -> String {
        guard forSelection else { return ShortcutAction.addToReadingList.title }
        // Translators: Context menu item for the books selected in the Library: adds them to the reading list. Title case. %lld is the number of books selected.
        return InterfaceText.line("readingList.addTitle", "Add \(number: count) Books to Reading List")
    }

    /// The title of Remove from Reading List for `count` books: its plain
    /// name for one book, or "Remove 3 Books from Reading List" for a
    /// selection.
    static func removeTitle(count: Int, forSelection: Bool) -> String {
        guard forSelection else { return ShortcutAction.removeFromReadingList.title }
        // Translators: Context menu item for the books selected in the Library: takes them off the reading list. Title case. %lld is the number of books selected.
        return InterfaceText.line("readingList.removeTitle", "Remove \(number: count) Books from Reading List")
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
            // Translators: VoiceOver label of the Library's edit-mode bar button that adds the selected books to the reading list. %lld is the number of books selected.
            return InterfaceText.line("readingList.editBarLabel.add", "Add \(number: count) books to the reading list")
        case .remove:
            // Translators: VoiceOver label of the Library's edit-mode bar button that takes the selected books off the reading list. %lld is the number of books selected.
            return InterfaceText.line("readingList.editBarLabel.remove", "Remove \(number: count) books from the reading list")
        }
    }

    /// The hint of the edit-mode bar's button for a command of `kind`: what
    /// it does with the selected books.
    static func editBarHint(_ kind: ReadingListCommand.Kind) -> String {
        switch kind {
        case .add:
            // Translators: VoiceOver hint of the Library's edit-mode bar button Add to Reading List.
            return InterfaceText.line("readingList.editBarHint.add", "Adds the selected books to the end of the reading list.")
        case .remove:
            // Translators: VoiceOver hint of the Library's edit-mode bar button Remove from Reading List.
            return InterfaceText.line("readingList.editBarHint.remove", "Takes the selected books off the reading list. They stay in the library.")
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
            // Translators: VoiceOver announcement after one book was added to the reading list. %@ is the book's title.
            ? InterfaceText.line("readingList.addedAnnouncement.single", "Added to reading list: \(titles.first ?? "")")
            // Translators: VoiceOver announcement after several books were added to the reading list. %lld is the number of books added.
            : InterfaceText.line("readingList.addedAnnouncement.books", "Added \(number: titles.count) books to the reading list.")
        guard alreadyIn > 0 else { return done }
        // Translators: Second sentence of the announcement after books were added to the reading list: some chosen were on it already. %lld is how many.
        return sentences(done, InterfaceText.line("readingList.addedAnnouncement.already", "\(number: alreadyIn) books were already in it."))
    }

    /// What VoiceOver hears after Remove from Reading List took off
    /// `removed`, the titles of the books taken off, in the list's order:
    /// "Removed from reading list: Moby-Dick" for one, "Removed 3 books from
    /// the reading list." for several; then, when `notIn` of the books
    /// chosen were not in the list, how many, as in "2 books were not in
    /// it."
    static func removedAnnouncement(removed titles: [String], notIn: Int) -> String {
        let done = titles.count == 1
            // Translators: VoiceOver announcement after one book was taken off the reading list. %@ is the book's title.
            ? InterfaceText.line("readingList.removedAnnouncement.single", "Removed from reading list: \(titles.first ?? "")")
            // Translators: VoiceOver announcement after several books were taken off the reading list. %lld is the number of books taken off.
            : InterfaceText.line("readingList.removedAnnouncement.books", "Removed \(number: titles.count) books from the reading list.")
        guard notIn > 0 else { return done }
        // Translators: Second sentence of the announcement after books were taken off the reading list: some chosen were not on it. %lld is how many.
        return sentences(done, InterfaceText.line("readingList.removedAnnouncement.were", "\(number: notIn) books were not in it."))
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
            // Translators: Second sentence of the announcement after an import at the Reading List added one book to it: the library folder the book went to. %@ is the folder's path, such as Essays/Sea, or Library Root.
            ? InterfaceText.line("readingList.importedAnnouncement.book", "The book is in \(folder).")
            // Translators: Second sentence of the announcement after an import at the Reading List added several books to it: the library folder they went to. %@ is the folder's path, such as Essays/Sea, or Library Root.
            : InterfaceText.line("readingList.importedAnnouncement.books", "The books are in \(folder).")
        return sentences(addedAnnouncement(added: titles, alreadyIn: 0), place)
    }

    /// Why Add to Reading List from the Library menu added nothing, for the
    /// books selected, titled `titles`: none is selected, or every one is
    /// in the list already.
    static func addRefusal(selected titles: [String]) -> String {
        guard !titles.isEmpty else { return LibraryCloudWording.noBooksSelected }
        if titles.count == 1, let title = titles.first {
            // Translators: VoiceOver announcement when Add to Reading List added nothing: the one book selected is on the list already. %@ is the book's title.
            return InterfaceText.line("readingList.addRefusal.already", "\(title) is already in the reading list.")
        }
        // Translators: VoiceOver announcement when Add to Reading List added nothing: every book selected is on the list already. %lld is the number of books selected (two or more).
        return InterfaceText.line("readingList.addRefusal.selected", "The \(number: titles.count) selected books are already in the reading list.")
    }

    /// Why Remove from Reading List from the Library menu took nothing off,
    /// for the books selected, titled `titles`: none is selected, or none
    /// of them is in the list.
    static func removeRefusal(selected titles: [String]) -> String {
        guard !titles.isEmpty else { return LibraryCloudWording.noBooksSelected }
        if titles.count == 1, let title = titles.first {
            // Translators: VoiceOver announcement when Remove from Reading List took nothing off: the one book selected is not on the list. %@ is the book's title.
            return InterfaceText.line("readingList.removeRefusal.isnt", "\(title) isn't in the reading list.")
        }
        // Translators: VoiceOver announcement when Remove from Reading List took nothing off: no book selected is on the list. %lld is the number of books selected (two or more).
        return InterfaceText.line("readingList.removeRefusal.selected", "None of the \(number: titles.count) selected books is in the reading list.")
    }

    /// `first` followed by `second` as two sentences: `first` ends with a
    /// period when it has none. Joined with a full stop and a space, as
    /// English and Spanish join sentences; a language that ends a sentence
    /// otherwise needs this localized too, a later item.
    private static func sentences(_ first: String, _ second: String) -> String {
        "\(first.hasSuffix(".") ? first : first + ".") \(second)"
    }
}
