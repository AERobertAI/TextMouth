import Combine
import Foundation

// MARK: - Punctuation and Objects Shared by the Removal Words

/// The small pieces that every removal sentence builds from, each a
/// localized string of its own so a language puts its punctuation and its
/// capitals where it needs them (FR34): a title made into a question, a
/// title that asks for a choice with an ellipsis, a clause made into a
/// sentence, and the title-case objects that fill a button's title.
enum RemovalText {
    /// `title` as a question: "Move Book to Trash?".
    static func question(_ title: String) -> String {
        // Translators: Makes a title into a question, such as the title of a removal confirmation: "Move Book to Trash?". %@ is the title without its question mark.
        InterfaceText.line("removal.question", "\(title)?")
    }

    /// `title` followed by an ellipsis, which says a question follows.
    static func withEllipsis(_ title: String) -> String {
        // Translators: Adds an ellipsis to the title of a command, which says a question follows the command: "Delete Download…". %@ is the title without the ellipsis.
        InterfaceText.line("removal.withEllipsis", "\(title)…")
    }

    /// `clause` as a sentence of its own: its first letter in capitals and a
    /// full stop, "Their files go to the Trash, where you can recover them
    /// until the Trash is emptied."
    static func sentence(_ clause: String) -> String {
        let capitalized = clause.capitalizingFirstLetter
        // Translators: Makes a clause into a whole sentence by adding its full stop. %@ is the clause, already starting with a capital letter.
        return InterfaceText.line("common.valuePeriod", "\(capitalized).")
    }

    /// The title-case object of a button that removes `count` books:
    /// "3 Books".
    static func booksObject(_ count: Int) -> String {
        // Translators: The object of a removal button's title, in title case, as in "Move 3 Books to Trash". %lld is how many books, a count.
        InterfaceText.line("removal.booksObject", "\(number: count) Books")
    }

    /// The title-case object of a button that removes the books selected in
    /// a list: "3 Selected".
    static func selectedObject(_ count: Int) -> String {
        // Translators: The object of a removal button's title, in title case, as in "Move 3 Selected to Trash". %lld is how many books are selected, a count.
        InterfaceText.line("removal.selectedObject", "\(number: count) Selected")
    }

    /// The title-case object for one book in a confirmation's title: "Book".
    static var bookObject: String {
        // Translators: The object of a removal confirmation's title for one book, in title case, as in "Move Book to Trash?".
        InterfaceText.line("removal.bookObject", "Book")
    }

    /// The title-case object of the button that deletes a folder with its
    /// contents: "Everything".
    static var everythingObject: String {
        // Translators: The object of the button that deletes a folder with its contents, in title case, as in "Move Everything to Trash".
        InterfaceText.line("removal.everythingObject", "Everything")
    }

    /// The title-case object of the second confirmation that deletes a
    /// folder: "Everything in “Fiction”".
    static func everythingInObject(_ quotedName: String) -> String {
        // Translators: The object of the title of the second confirmation that deletes a folder with its contents, in title case, as in "Move Everything in “Fiction” to Trash?". %@ is the folder's name in quotation marks.
        InterfaceText.line("removal.everythingInObject", "Everything in \(quotedName)")
    }

    /// A name in quotation marks: “Notes”.
    static func quoted(_ name: String) -> String {
        // Translators: Puts a book's, folder's, or feed's title in quotation marks inside a sentence. %@ is the title.
        InterfaceText.line("removal.quoted", "“\(name)”")
    }
}

/// What a failure heading calls the things that could not be removed.
enum RemovalNoun {
    /// Books, as a list of books removes them.
    case book
    /// Items of a folder: books and the folders themselves.
    case item
}

/// What removing books does with their files (TODO A08). Every removal
/// button, accessibility label, confirmation, and completion or failure
/// message takes its words from here, so what the user sees and hears
/// always matches what happens to the files.
enum RemovalMode: Equatable, CaseIterable {
    /// Remove from Library Only: the books leave the library, and their
    /// files stay in the TextMouth library folder.
    case keepFiles
    /// The files go to the Trash: "Move to Trash instead of deleting" is on.
    case moveToTrash
    /// The files are deleted permanently: that preference is off.
    case deletePermanently

    /// The mode in which a removal deletes files, as the Trash preference
    /// chooses.
    static func deleting(movesToTrash: Bool) -> RemovalMode {
        movesToTrash ? .moveToTrash : .deletePermanently
    }

    // MARK: - Building Blocks

    /// Title-case words for a button that removes `object` this way, or the
    /// bare action when there is no object: "Move to Trash", "Move 3 Books
    /// to Trash", "Delete Everything Permanently", "Remove from Library Only".
    func buttonTitle(_ object: String = "") -> String {
        if object.isEmpty {
            switch self {
            case .keepFiles:
                // Translators: Title of the button that removes books from the library and keeps their files, in title case.
                return InterfaceText.line("removalMode.buttonTitle.keepFiles.removeLibrary", "Remove from Library Only")
            case .moveToTrash:
                // Translators: Title of the button that removes books and moves their files to the Trash, in title case.
                return InterfaceText.line("removalMode.buttonTitle.moveToTrash.plain", "Move to Trash")
            case .deletePermanently:
                // Translators: Title of the button that removes books and deletes their files permanently, in title case.
                return InterfaceText.line("removalMode.buttonTitle.deletePermanently.plain", "Delete Permanently")
            }
        }
        switch self {
        case .keepFiles:
            // Translators: Title of a button that removes the named books from the library and keeps their files, in title case. %@ is the object, such as "3 Books" or "3 Selected".
            return InterfaceText.line("removalMode.buttonTitle.keepFiles.named", "Remove \(object) from Library Only")
        case .moveToTrash:
            // Translators: Title of a button that moves the named books' files to the Trash, in title case. %@ is the object, such as "3 Books", "3 Selected", or "Everything".
            return InterfaceText.line("removalMode.buttonTitle.moveToTrash.named", "Move \(object) to Trash")
        case .deletePermanently:
            // Translators: Title of a button that deletes the named books' files permanently, in title case. %@ is the object, such as "3 Books", "3 Selected", or "Everything".
            return InterfaceText.line("removalMode.buttonTitle.deletePermanently.named", "Delete \(object) Permanently")
        }
    }

    /// The same action as VoiceOver speaks it, naming `object` in full:
    /// "Move 3 selected books to the Trash", "Delete “Notes” permanently".
    func spokenLabel(_ object: String) -> String {
        switch self {
        case .keepFiles:
            // Translators: VoiceOver label of a removal button that keeps the files. %@ is what is removed, such as "“Notes”" or "3 selected books".
            return InterfaceText.line("removalMode.spokenLabel.keepFiles", "Remove \(object) from the library and keep the files")
        case .moveToTrash:
            // Translators: VoiceOver label of a removal button that moves files to the Trash. %@ is what is moved, such as "“Notes”", "3 selected books", or "the original file".
            return InterfaceText.line("removalMode.spokenLabel.moveToTrash", "Move \(object) to the Trash")
        case .deletePermanently:
            // Translators: VoiceOver label of a removal button that deletes files permanently. %@ is what is deleted, such as "“Notes”", "3 selected books", or "the original file".
            return InterfaceText.line("removalMode.spokenLabel.deletePermanently", "Delete \(object) permanently")
        }
    }

    /// What happens to what this removal deletes, as the words after their
    /// subject, agreeing with one thing or several (`plural`): "go to the
    /// Trash, where you can recover them until the Trash is emptied", "is
    /// deleted permanently and cannot be recovered", "stay in the TextMouth
    /// library folder". English only: it is a piece of `ImportDecision`'s
    /// English sentences until that area converts (FR34); Delete Feed… says
    /// it of a feed's downloads in whole sentences of its own.
    func outcomePhrase(plural: Bool) -> String {
        switch self {
        case .keepFiles:
            return "\(plural ? "stay" : "stays") in the TextMouth library folder" // l10n: no (inside ImportDecision's English sentences until that area converts)
        case .moveToTrash:
            return "\(plural ? "go" : "goes") to the Trash, where you can recover \(plural ? "them" : "it") until the Trash is emptied" // l10n: no (inside ImportDecision's English sentences until that area converts)
        case .deletePermanently:
            return "\(plural ? "are" : "is") deleted permanently and cannot be recovered" // l10n: no (inside ImportDecision's English sentences until that area converts)
        }
    }

    /// The files clause for one book ("its files") or several ("their
    /// files"), a whole clause for each mode.
    func filesClause(plural: Bool) -> String {
        switch (self, plural) {
        case (.keepFiles, false):
            // Translators: A clause about one book's files when it is removed from the library only, inside a sentence of a removal confirmation.
            return InterfaceText.line("removalMode.filesClause.stayLibraryFolder", "its files stay in the TextMouth library folder")
        case (.keepFiles, true):
            // Translators: A clause about several books' files when they are removed from the library only, inside a sentence of a removal confirmation.
            return InterfaceText.line("removalMode.filesClause.theirStayLibraryFolder", "their files stay in the TextMouth library folder")
        case (.moveToTrash, false):
            // Translators: A clause about one book's files when it is moved to the Trash, inside a sentence of a removal confirmation.
            return InterfaceText.line("removalMode.filesClause.trashWhereRecoverEmptied", "its files go to the Trash, where you can recover them until the Trash is emptied")
        case (.moveToTrash, true):
            // Translators: A clause about several books' files when they are moved to the Trash, inside a sentence of a removal confirmation.
            return InterfaceText.line("removalMode.filesClause.trashRecoverEmptied", "their files go to the Trash, where you can recover them until the Trash is emptied")
        case (.deletePermanently, false):
            // Translators: A clause about one book's files when it is deleted permanently, inside a sentence of a removal confirmation.
            return InterfaceText.line("removalMode.filesClause.permanentlyRecovered", "its files are deleted permanently and cannot be recovered")
        case (.deletePermanently, true):
            // Translators: A clause about several books' files when they are deleted permanently, inside a sentence of a removal confirmation.
            return InterfaceText.line("removalMode.filesClause.permanently", "their files are deleted permanently and cannot be recovered")
        }
    }

    /// The files clause as a sentence of its own: "Their files go to the
    /// Trash, where you can recover them until the Trash is emptied."
    func filesSentence(plural: Bool) -> String {
        RemovalText.sentence(filesClause(plural: plural))
    }

    /// The report that `subject` was removed this way: "Moved 3 books to the
    /// Trash.", "Deleted “Notes” permanently.", "Removed “Notes” from the
    /// library. Its files stay in the TextMouth library folder."
    func completionSentence(_ subject: String, plural: Bool) -> String {
        switch self {
        case .keepFiles:
            return SentenceWording.joined([
                // Translators: Report that books were removed from the library only. %@ is what was removed, such as "“Notes”" or "3 books". A sentence about their files follows.
                InterfaceText.line("removalMode.completionSentence.keepFiles", "Removed \(subject) from the library."),
                filesSentence(plural: plural),
            ])
        case .moveToTrash:
            // Translators: Report that books' files were moved to the Trash. %@ is what was moved, such as "“Notes”" or "3 books".
            return InterfaceText.line("removalMode.completionSentence.moveToTrash", "Moved \(subject) to the Trash.")
        case .deletePermanently:
            // Translators: Report that books' files were deleted permanently. %@ is what was deleted, such as "“Notes”" or "3 books".
            return InterfaceText.line("removalMode.completionSentence.deletePermanently", "Deleted \(subject) permanently.")
        }
    }

    /// Introduces the items this removal could not remove, each of which
    /// stays in the library. `noun` names the items, books or items of a
    /// folder: "These books could not be moved to the Trash and remain in
    /// the library:".
    func failureHeading(count: Int, noun: RemovalNoun) -> String {
        let plural = count != 1
        switch (self, noun, plural) {
        case (.keepFiles, .book, true):
            // Translators: Heading over the books that could not be removed from the library, several of them. One line for each book follows.
            return InterfaceText.line("common.theseBooksCouldNotBeRemoved", "These books could not be removed from the library and remain in it:")
        case (.keepFiles, .book, false):
            // Translators: Heading over the one book that could not be removed from the library. A line about it follows.
            return InterfaceText.line("common.thisBookCouldNotBeRemoved", "This book could not be removed from the library and remains in it:")
        case (.keepFiles, .item, true):
            // Translators: Heading over the items of a folder that could not be removed from the library, several of them. One line for each follows.
            return InterfaceText.line("removalMode.failureHeading.itemsRemoved", "These items could not be removed from the library and remain in it:")
        case (.keepFiles, .item, false):
            // Translators: Heading over the one item of a folder that could not be removed from the library. A line about it follows.
            return InterfaceText.line("removalMode.failureHeading.itemRemoved", "This item could not be removed from the library and remains in it:")
        case (.moveToTrash, .book, true):
            // Translators: Heading over the books that could not be moved to the Trash, several of them. One line for each book follows.
            return InterfaceText.line("removalMode.failureHeading.booksMoved", "These books could not be moved to the Trash and remain in the library:")
        case (.moveToTrash, .book, false):
            // Translators: Heading over the one book that could not be moved to the Trash. A line about it follows.
            return InterfaceText.line("removalMode.failureHeading.bookMoved", "This book could not be moved to the Trash and remains in the library:")
        case (.moveToTrash, .item, true):
            // Translators: Heading over the items of a folder that could not be moved to the Trash, several of them. One line for each follows.
            return InterfaceText.line("removalMode.failureHeading.itemsMoved", "These items could not be moved to the Trash and remain in the library:")
        case (.moveToTrash, .item, false):
            // Translators: Heading over the one item of a folder that could not be moved to the Trash. A line about it follows.
            return InterfaceText.line("removalMode.failureHeading.itemMoved", "This item could not be moved to the Trash and remains in the library:")
        case (.deletePermanently, .book, true):
            // Translators: Heading over the books that could not be deleted permanently, several of them. One line for each book follows.
            return InterfaceText.line("removalMode.failureHeading.booksDeleted", "These books could not be deleted and remain in the library:")
        case (.deletePermanently, .book, false):
            // Translators: Heading over the one book that could not be deleted permanently. A line about it follows.
            return InterfaceText.line("removalMode.failureHeading.bookDeleted", "This book could not be deleted and remains in the library:")
        case (.deletePermanently, .item, true):
            // Translators: Heading over the items of a folder that could not be deleted permanently, several of them. One line for each follows.
            return InterfaceText.line("removalMode.failureHeading.itemsDeleted", "These items could not be deleted and remain in the library:")
        case (.deletePermanently, .item, false):
            // Translators: Heading over the one item of a folder that could not be deleted permanently. A line about it follows.
            return InterfaceText.line("removalMode.failureHeading.itemDeleted", "This item could not be deleted and remains in the library:")
        }
    }

    /// The failure heading followed by one line per item, each reading
    /// "Title: reason".
    func failureMessage(_ failures: [String], noun: RemovalNoun = .book) -> String {
        ([failureHeading(count: failures.count, noun: noun)] + failures).joined(separator: "\n")
    }


}

// MARK: - Removing Books

/// The words for removing particular books in one mode.
struct RemovalWording: Equatable {
    let mode: RemovalMode
    /// How many books are removed.
    let count: Int
    /// The title of the only book removed, so the words can name it; nil
    /// when several are.
    let title: String?

    /// The words for removing `count` books; `title` names the book when
    /// there is exactly one.
    init(_ mode: RemovalMode, count: Int, title: String? = nil) {
        self.mode = mode
        self.count = count
        self.title = count == 1 ? title : nil
    }

    /// The words for removing `books`.
    init(_ mode: RemovalMode, books: [Book]) {
        self.init(mode, count: books.count, title: books.first?.title)
    }

    /// Whether the words speak of several books (or none).
    private var isPlural: Bool { count != 1 }

    /// The books as a sentence names them: the title in quotes for one book,
    /// otherwise "3 books".
    var subject: String {
        if let title { return RemovalText.quoted(title) }
        // Translators: What a removal sentence calls the books it removes when none is named: a count of books, as in "Moved 3 books to the Trash." %lld is how many.
        return InterfaceText.line("common.countBooks", "\(number: count) books")
    }

    /// A button that removes the books at once: "Move to Trash" for one
    /// book, "Move 3 Books to Trash" for several.
    var buttonTitle: String {
        mode.buttonTitle(isPlural ? RemovalText.booksObject(count) : "")
    }

    /// What VoiceOver says for `buttonTitle`: "Move “Notes” to the Trash".
    var accessibilityLabel: String {
        mode.spokenLabel(subject)
    }

    /// A button that removes the books selected in a list, such as the
    /// Duplicate Finder's: "Move 3 Selected to Trash".
    var selectionButtonTitle: String {
        mode.buttonTitle(RemovalText.selectedObject(count))
    }

    /// What VoiceOver says for `selectionButtonTitle`: "Move 3 selected
    /// books to the Trash".
    var selectionAccessibilityLabel: String {
        // Translators: What a removal button's VoiceOver label calls the books selected in a list, as in "Move 3 selected books to the Trash". %lld is how many are selected, a count.
        mode.spokenLabel(InterfaceText.line("removal.selectionAccessibilityLabel", "\(number: count) selected books"))
    }

    /// The question asked before removing: "Move Book to Trash?", "Delete 3
    /// Books Permanently?".
    var confirmationTitle: String {
        RemovalText.question(mode.buttonTitle(isPlural ? RemovalText.booksObject(count) : RemovalText.bookObject))
    }

    /// What the confirmation explains: "“Notes” will be removed from the
    /// library. Its files go to the Trash, where you can recover them until
    /// the Trash is emptied."
    var confirmationMessage: String {
        let named = subject
        return SentenceWording.joined([
            // Translators: First sentence of a removal confirmation. %@ is what is removed, such as "“Notes”" or "3 books". A sentence about the files follows.
            InterfaceText.line("removal.confirmationMessage", "\(named) will be removed from the library."),
            mode.filesSentence(plural: isPlural),
        ])
    }

    /// The report once the books are removed: "Moved 3 books to the Trash."
    var completionMessage: String {
        mode.completionSentence(subject, plural: isPlural)
    }
}

/// The confirmation that asks how to remove books, as the library shows it
/// when "Confirm before removing a book" is on: delete their files, in the
/// mode the Trash preference chooses, or Remove from Library Only, which
/// keeps them.
///
/// When every book it removes is a feed item, an episode or an article in
/// its feed's folder (FR11), the library's Remove is their Delete Download,
/// and the confirmation speaks of that alone (`feedDownloads`): no Remove
/// from Library Only, which a feed item refuses, and no book leaving the
/// library.
struct RemovalChoiceWording: Equatable {
    /// Deleting the books' files, to the Trash or permanently.
    let deletion: RemovalWording
    /// Remove from Library Only.
    let keeping: RemovalWording
    /// The words of Delete Download, which the confirmation speaks instead
    /// when every book is a feed item; nil otherwise.
    let feedDownloads: FeedDownloadRemovalWording?

    /// The choice for `books` under the Trash preference.
    init(books: [Book], movesToTrash: Bool) {
        let mode = RemovalMode.deleting(movesToTrash: movesToTrash)
        deletion = RemovalWording(mode, books: books)
        keeping = RemovalWording(.keepFiles, books: books)
        feedDownloads = !books.isEmpty && books.allSatisfy(\.isFeedItem) ? FeedDownloadRemovalWording(mode, items: books) : nil
    }

    /// Whether the confirmation offers Remove from Library Only: not when
    /// every book is a feed item, which it would refuse.
    var offersLibraryOnly: Bool {
        feedDownloads == nil
    }

    /// "Remove Book?" or "Remove 3 Books?"; for feed items alone, "Delete
    /// Download?" or "Delete 3 Downloads?".
    var title: String {
        if let feedDownloads {
            return feedDownloads.confirmationTitle
        }
        if deletion.count == 1 {
            // Translators: Title of the confirmation that asks how to remove one book.
            return InterfaceText.line("removalChoice.title.book", "Remove Book?")
        }
        let count = deletion.count
        // Translators: Title of the confirmation that asks how to remove several books. %lld is how many, a count.
        return InterfaceText.line("removalChoice.title.books", "Remove \(number: count) Books?")
    }

    /// The deleting button, "Move to Trash" or "Delete Permanently", or, for
    /// feed items alone, "Delete Download" or "Delete Downloads"; the title
    /// already says how many.
    var deleteButtonTitle: String {
        if let feedDownloads {
            return feedDownloads.buttonTitle
        }
        return deletion.mode.buttonTitle()
    }

    /// The keeping button: "Remove from Library Only".
    var keepButtonTitle: String {
        keeping.mode.buttonTitle()
    }

    /// Explains both choices: "Choose how to remove “Notes” from the
    /// library. With Move to Trash, its files go to the Trash, where you can
    /// recover them until the Trash is emptied. With Remove from Library
    /// Only, its files stay in the TextMouth library folder." For feed items
    /// alone, what Delete Download does and keeps
    /// (`FeedDownloadRemovalWording.confirmationMessage`).
    var message: String {
        if let feedDownloads {
            return feedDownloads.confirmationMessage
        }
        let plural = deletion.count != 1
        let subject = deletion.subject
        return SentenceWording.joined([
            // Translators: First sentence of the confirmation that asks how to remove books. %@ is what is removed, such as "“Notes”" or "3 books".
            InterfaceText.line("removalChoice.message", "Choose how to remove \(subject) from the library."),
            RemovalChoiceWording.optionSentence(deleteButtonTitle, deletion.mode.filesClause(plural: plural)),
            RemovalChoiceWording.optionSentence(keepButtonTitle, keeping.mode.filesClause(plural: plural)),
        ])
    }

    /// "With <button>, <what happens>.": one choice of the question and its
    /// effect, shared by the confirmation and Storage settings.
    static func optionSentence(_ button: String, _ effect: String) -> String {
        // Translators: A sentence that explains one button of a removal question. %1$@ is the button's title, such as "Move to Trash", and %2$@ says what it does, such as "its files go to the Trash, where you can recover them until the Trash is emptied".
        InterfaceText.line("removalChoice.optionSentence", "With \(button), \(effect).")
    }
}

// MARK: - Removing Feed Items' Downloads

/// The words for the library's Remove when it acts on feed items, episodes
/// and articles in their feeds' folders (FR11): for them it is Delete
/// Download (branch A2), which deletes the downloaded files, in the mode the
/// Trash preference chooses, and keeps each item's package with what the
/// listener left in it, its place, bookmarks, and transcript, so it can be
/// downloaded again where they left off. A package holding nothing of the
/// listener's goes whole.
struct FeedDownloadRemovalWording: Equatable {
    /// How the downloaded files go: to the Trash or permanently.
    let mode: RemovalMode
    /// How many downloads are deleted.
    let count: Int
    /// The title of the only item, so the words can name it; nil for
    /// several.
    let title: String?

    /// The words for deleting the downloads of `items` in `mode`.
    init(_ mode: RemovalMode, items: [Book]) {
        self.init(mode, count: items.count, title: items.first?.title)
    }

    /// The words for deleting `count` downloads in `mode`; `title` names the
    /// item when there is exactly one.
    init(_ mode: RemovalMode, count: Int, title: String? = nil) {
        self.mode = mode
        self.count = count
        self.title = count == 1 ? title : nil
    }

    /// Whether the words speak of several downloads (or none).
    private var isPlural: Bool { count != 1 }

    /// The downloads as a sentence names them: "the download of “Ep. 368”",
    /// "1 download" when its title is not known, or "3 downloads".
    private var subject: String {
        if let title {
            // Translators: What a sentence calls one feed item's downloaded files, inside a sentence, in lower case. %@ is the episode's or article's title.
            return InterfaceText.line("feedDownloadRemoval.subject.ofName", "the download of “\(title)”")
        }
        // Translators: What a sentence calls several feed items' downloaded files, inside a sentence, as in "Deleted 3 downloads permanently." %lld is how many, a count.
        return InterfaceText.line("feedDownloadRemoval.subject.downloads", "\(number: count) downloads")
    }

    /// "Delete Download?" or "Delete 3 Downloads?"
    var confirmationTitle: String {
        RemovalText.question(deleteDownloadsTitle)
    }

    /// "Delete Download" or "Delete 3 Downloads", the title of the command
    /// that names how many.
    private var deleteDownloadsTitle: String {
        if isPlural {
            // Translators: Title in title case of the command that deletes several feed items' downloads. %lld is how many, a count.
            return InterfaceText.line("feedDownloadRemoval.deleteDownloadsTitle", "Delete \(number: count) Downloads")
        }
        // Translators: Title in title case of the command that deletes one feed item's download.
        return InterfaceText.line("common.deleteDownload", "Delete Download")
    }

    /// The deleting button, "Delete Download" or "Delete Downloads"; the
    /// title says how many.
    var buttonTitle: String {
        isPlural
            // Translators: Title in title case of the button that deletes several feed items' downloads. The confirmation's title says how many.
            ? InterfaceText.line("feedDownloadRemoval.buttonTitle", "Delete Downloads")
            // Translators: Title in title case of the command that deletes one feed item's download.
            : InterfaceText.line("common.deleteDownload", "Delete Download")
    }

    /// What the confirmation explains: "The download of “Ep. 368” will be
    /// deleted. Its files go to the Trash, where you can recover them until
    /// the Trash is emptied. Its place, bookmarks, and transcript, if it has
    /// any, are kept, and it can be downloaded again."
    var confirmationMessage: String {
        let willBeDeleted: String
        if let title {
            // Translators: First sentence of the confirmation that deletes one feed item's download. %@ is the episode's or article's title.
            willBeDeleted = InterfaceText.line("feedDownloadRemoval.confirmationMessage.deleted", "The download of “\(title)” will be deleted.")
        } else {
            // Translators: First sentence of the confirmation that deletes several feed items' downloads. %lld is how many, a count.
            willBeDeleted = InterfaceText.line("feedDownloadRemoval.confirmation.downloads", "\(number: count) downloads will be deleted.")
        }
        return SentenceWording.joined([willBeDeleted, mode.filesSentence(plural: isPlural), keptSentence])
    }

    /// What deleting the downloads keeps: "Its place, bookmarks, and
    /// transcript, if it has any, are kept, and it can be downloaded again."
    private var keptSentence: String {
        isPlural
            // Translators: Sentence about several deleted downloads: what the listener left in them is kept, and they can be downloaded again.
            ? InterfaceText.line("feedDownloadRemoval.keptSentence.transcripts", "Their places, bookmarks, and transcripts, if they have any, are kept, and they can be downloaded again.")
            // Translators: Sentence about one deleted download: what the listener left in it is kept, and it can be downloaded again.
            : InterfaceText.line("feedDownloadRemoval.keptSentence.transcript", "Its place, bookmarks, and transcript, if it has any, are kept, and it can be downloaded again.")
    }

    // MARK: As the Library's Remove Command (REV11 F2)

    /// The library's Remove in a context menu, when it is these downloads'
    /// Delete Download: "Delete Download…" or "Delete 3 Downloads…" when it
    /// asks first, the ellipsis saying a question follows, otherwise
    /// "Delete Download" or "Delete 3 Downloads". A menu item is read by its
    /// title alone, so the title names how many.
    func commandTitle(asksFirst: Bool) -> String {
        asksFirst ? RemovalText.withEllipsis(deleteDownloadsTitle) : deleteDownloadsTitle
    }

    /// The edit bar's short button, which names no count: "Delete
    /// Download…" or "Delete Downloads…" when it asks first, otherwise
    /// "Delete Download" or "Delete Downloads".
    func shortTitle(asksFirst: Bool) -> String {
        asksFirst ? RemovalText.withEllipsis(buttonTitle) : buttonTitle
    }

    /// What VoiceOver says for the command: "Delete the download of
    /// “Ep. 368”", or "Delete 3 downloads".
    var accessibilityLabel: String {
        let named = subject
        // Translators: VoiceOver label of the command that deletes feed items' downloads. %@ is what is deleted, such as "the download of “Ep. 368”" or "3 downloads".
        return InterfaceText.line("feedDownloadRemoval.accessibilityLabel", "Delete \(named)")
    }

    /// What VoiceOver adds after a pause: that it asks first, or where the
    /// files go, and then what is kept, never a choice the question does
    /// not offer: "Asks before deleting. Its place, bookmarks, and
    /// transcript, if it has any, are kept, and it can be downloaded again."
    func accessibilityHint(asksFirst: Bool) -> String {
        let first = asksFirst
            // Translators: First sentence of the VoiceOver hint of a delete command that asks before it deletes.
            ? InterfaceText.line("feedDownloadRemoval.accessibilityHint", "Asks before deleting.")
            : mode.filesSentence(plural: isPlural)
        return SentenceWording.joined([first, keptSentence])
    }

    /// The report once the downloads are deleted, `kept` holding, for each
    /// download whose package stayed, what that package holds of the
    /// listener's (`FeedWording.KeptParts`), so the report names only that,
    /// as Delete Download does (feed review item 18), never a part no package
    /// holds: "Moved the download of “Ep. 368” to the Trash. Its place and
    /// bookmarks are kept.", or "Deleted 3 downloads permanently. The places
    /// and transcripts of 2 of them are kept." A package kept for none of
    /// the parts named, as one kept because the item was opened, says
    /// nothing kept.
    func completionMessage(kept: [FeedWording.KeptParts]) -> String {
        let deleted = mode.completionSentence(subject, plural: isPlural)
        let holding = kept.filter { !$0.isEmpty }
        let parts = holding.reduce(into: FeedWording.KeptParts()) { $0.formUnion($1) }
        guard !holding.isEmpty else { return deleted }
        // One download: the feeds area's whole sentence names what is kept.
        if !isPlural, let kept = parts.keptSentence {
            return SentenceWording.joined([deleted, kept])
        }
        let nouns = CountWording.list(parts.nouns(several: true))
        if holding.count >= count {
            // Translators: Sentence that says what is kept of every one of several deleted downloads. %@ is a list of parts, such as "places and bookmarks".
            return SentenceWording.joined([deleted, InterfaceText.line("feedDownloadRemoval.completionMessage.their", "Their \(nouns) are kept.")])
        }
        let some = holding.count
        // Translators: Sentence that says what is kept of some of several deleted downloads. %1$@ is a list of parts, such as "places and bookmarks", and %2$lld is how many of the downloads keep them, a count.
        return SentenceWording.joined([deleted, InterfaceText.line("feedDownloadRemoval.completionMessage.them", "The \(nouns) of \(number: some) of them are kept.")])
    }
}

// MARK: - The Library's Remove Command

/// The words for the library's Remove command in the book context menu and
/// the edit bar. With "Confirm before removing a book" on, it asks how to
/// remove the books, so it promises nothing about their files; with it off,
/// it deletes them at once, so it says how.
///
/// When every book it removes is a feed item, an episode or an article in
/// its feed's folder (FR11), the library's Remove is their Delete Download,
/// and the command says so (`feedDownloads`, REV11 F2): "Delete Download…",
/// with no promise of the choice to keep the files, which the question then
/// does not offer.
struct LibraryRemoveCommandWording: Equatable {
    let preferences: RemovalPreferences
    /// The words for deleting the books at once in the mode the Trash
    /// preference chooses.
    let removal: RemovalWording
    /// The words of Delete Download, which the command speaks instead when
    /// every book it removes is a feed item; nil otherwise.
    let feedDownloads: FeedDownloadRemovalWording?

    /// The command for `count` books; `title` names the book when there is
    /// exactly one, and `feedItemsOnly` says every one is a feed item.
    init(preferences: RemovalPreferences, count: Int, title: String? = nil, feedItemsOnly: Bool = false) {
        self.preferences = preferences
        removal = RemovalWording(preferences.deletionMode, count: count, title: title)
        feedDownloads = feedItemsOnly && count > 0
            ? FeedDownloadRemovalWording(preferences.deletionMode, count: count, title: title)
            : nil
    }

    /// The command for `books`.
    init(preferences: RemovalPreferences, books: [Book]) {
        self.init(
            preferences: preferences,
            count: books.count,
            title: books.first?.title,
            feedItemsOnly: !books.isEmpty && books.allSatisfy(\.isFeedItem)
        )
    }

    /// Whether a book row's context menu offers the library's Remove for
    /// `targets`, the books its commands act on (REV11 F2): not for one
    /// feed item whose own commands, `feedActions`, offer Delete Download,
    /// which is what the library's Remove does for it, so the menu offers
    /// no command twice; for any other book, and for several, which Remove
    /// names together.
    static func isOfferedOnRow(for targets: [Book], feedActions: [FeedItemAction]) -> Bool {
        guard targets.count == 1, targets.first?.isFeedItem == true else { return true }
        return !feedActions.contains { $0.command == .deleteDownload }
    }

    /// The command's title when it asks how to remove before removing
    /// anything; the ellipsis says that a choice follows.
    private static var askFirstTitle: String {
        // Translators: Title of the Remove command when it asks how to remove before it removes anything. The three dots say a choice follows.
        InterfaceText.line("libraryRemoveCommand.askFirstTitle", "Remove from Library...")
    }

    /// The context-menu item: "Remove from Library..." or "Remove 3 Books
    /// from Library..." when it asks first, otherwise "Move to Trash",
    /// "Move 3 Books to Trash", or "Delete 3 Books Permanently". A menu item
    /// is read by its title, so the title alone must say all of this.
    var menuTitle: String {
        if let feedDownloads {
            return feedDownloads.commandTitle(asksFirst: preferences.confirmsFirst)
        }
        guard preferences.confirmsFirst else { return removal.buttonTitle }
        if removal.count == 1 { return Self.askFirstTitle }
        let count = removal.count
        // Translators: Title of the Remove command in a context menu when several books are chosen and it asks how to remove them first. %lld is how many books, a count. The three dots say a choice follows.
        return InterfaceText.line("libraryRemoveCommand.menuTitle", "Remove \(number: count) Books from Library...")
    }

    /// The menu bar's Remove command, which acts on whatever is selected in
    /// the key Library window, `selection`, and so names no count: "Remove
    /// from Library..." when it asks first, otherwise "Move to Trash" or
    /// "Delete Permanently"; with feed items alone selected, their Delete
    /// Download, as the edit bar names it: "Delete Download…" or "Delete
    /// Downloads…", without the ellipsis when it deletes at once (REV11 F2,
    /// the feed-policy-review follow-up). With confirmation off it never
    /// promises less than it does.
    static func menuBarTitle(preferences: RemovalPreferences, selection: LibraryRemovalSelection? = nil) -> String {
        if let selection, selection.feedItemsOnly {
            return LibraryRemoveCommandWording(preferences: preferences, count: selection.count, feedItemsOnly: true).shortTitle
        }
        return preferences.confirmsFirst ? askFirstTitle : preferences.deletionMode.buttonTitle()
    }

    /// The edit bar's short button: "Remove..." when it asks first,
    /// otherwise "Move to Trash" or "Delete Permanently"; for feed items
    /// alone, "Delete Downloads…" or "Delete Downloads".
    var shortTitle: String {
        if let feedDownloads {
            return feedDownloads.shortTitle(asksFirst: preferences.confirmsFirst)
        }
        return preferences.confirmsFirst
            // Translators: Short title of the edit bar's Remove button when it asks how to remove before it removes anything. The three dots say a choice follows.
            ? InterfaceText.line("libraryRemoveCommand.shortTitle", "Remove...")
            : removal.mode.buttonTitle()
    }

    /// What VoiceOver says for the button: "Remove 3 books from the library"
    /// when it asks first, otherwise "Move 3 books to the Trash"; for feed
    /// items alone, "Delete 3 downloads".
    var accessibilityLabel: String {
        if let feedDownloads {
            return feedDownloads.accessibilityLabel
        }
        guard preferences.confirmsFirst else { return removal.accessibilityLabel }
        let subject = removal.subject
        // Translators: VoiceOver label of the Remove button when it asks how to remove before it removes anything. %@ is what is removed, such as "“Notes”" or "3 books".
        return InterfaceText.line("libraryRemoveCommand.accessibilityLabel", "Remove \(subject) from the library")
    }

    /// What VoiceOver adds after a pause: the choice that follows, or what
    /// happens to the files; for feed items alone, what Delete Download
    /// does and keeps, never the choice to keep the files, which their
    /// question does not offer.
    var accessibilityHint: String {
        if let feedDownloads {
            return feedDownloads.accessibilityHint(asksFirst: preferences.confirmsFirst)
        }
        guard preferences.confirmsFirst else {
            return removal.mode.filesSentence(plural: removal.count != 1)
        }
        let deleting = preferences.deletingTheFiles
        // Translators: VoiceOver hint of the Remove button when it asks first. %@ is what deleting the files does, such as "move the files to the Trash" or "delete the files permanently".
        return InterfaceText.line("libraryRemoveCommand.accessibilityHint", "Asks whether to \(deleting) or keep them in the TextMouth library folder.")
    }
}

/// The books the library's Remove acts on in a Library window, as the
/// Library menu's Remove names them (`LibraryRemoveCommandWording.menuBarTitle`):
/// how many are selected, and whether every one is a feed item, whose
/// Remove is its Delete Download (REV11 F2). Each Library window publishes
/// its own as a scene value (`FocusedValues.libraryRemovalSelection`).
struct LibraryRemovalSelection: Equatable {
    /// How many books are selected.
    let count: Int
    /// Whether at least one book is selected and every one is a feed item.
    let feedItemsOnly: Bool

    /// The selection of `books`.
    init(_ books: [Book]) {
        count = books.count
        feedItemsOnly = !books.isEmpty && books.allSatisfy(\.isFeedItem)
    }
}

// MARK: - Removing a Folder

/// The words for Delete Everything: deleting a folder, its subfolders, and
/// the books inside, in the mode the Trash preference chooses.
struct FolderRemovalWording: Equatable {
    let mode: RemovalMode
    /// The name of the folder being deleted.
    let folderName: String
    /// How many books the folder and its subfolders hold.
    let bookCount: Int
    /// The titles of the feeds whose folders are inside this one, at any
    /// depth, in the order said (FR14). A feed's own folder holding nothing
    /// more offers Delete Feed… in place of Delete Folder…
    /// (`LibraryViewModel.offersDeleteFolder(_:)`), so no feed is deleted
    /// with a folder: each stays, its folder moving with Move Contents Out,
    /// or gone with Delete Everything.
    var feedTitles: [String] = []
    /// The titles of the feeds whose own folder this one is, when it holds
    /// more than their items, in the order said (REV14 feeds 7). Whichever
    /// way the folder goes, each feed stays, with its downloads, but no
    /// folder lists them until Feed Info gives the feed another.
    var ownFeedTitles: [String] = []
    /// How many books a newer TextMouth added the folder and its subfolders
    /// hold (kept rows, V03), which no list shows. Neither choice deletes
    /// them, and Delete Everything keeps every folder holding one
    /// (stable020 review, finding 1).
    var keptBookCount = 0

    /// The folder's name in quotes, as sentences name it.
    private var quotedName: String { RemovalText.quoted(folderName) }

    /// The button: "Move Everything to Trash" or "Delete Everything
    /// Permanently".
    var buttonTitle: String {
        mode.buttonTitle(RemovalText.everythingObject)
    }

    /// The first dialog, which offers to move the contents out first or to
    /// remove everything, explains both: "“Fiction” contains 3 books and may
    /// have subfolders. With Move Contents Out, they stay in the library and
    /// only the folder is deleted. With Move Everything to Trash, the folder
    /// and everything in it leave the library, and their files go to the
    /// Trash, where you can recover them until the Trash is emptied."
    ///
    /// A folder holding feeds' folders says, last, what happens to each feed
    /// (FR14): its folder moves with Move Contents Out; with Delete
    /// Everything the feed stays, its downloads with it, which no folder
    /// edit touches (FR11), but no folder lists them until Feed Info gives
    /// it another; and Delete Feed… is what deletes a feed. "It holds the
    /// folder of the feed “Finish It!”. With Move Contents Out, the feed's
    /// folder moves with the rest. With Move Everything to Trash, the feed
    /// stays, with its downloads, but no folder lists them until Feed Info
    /// gives the feed another folder; Delete Feed… on the feed's row deletes
    /// a feed."
    ///
    /// A folder holding books a newer TextMouth added says last that they
    /// are kept: "“Fiction” also holds 2 books a newer TextMouth added,
    /// which are kept."
    var choiceMessage: String {
        let name = quotedName
        let button = buttonTitle
        let clause = mode.filesClause(plural: true)
        var sentences = [
            // Translators: First sentence of the dialog that asks how to delete a folder. %1$@ is the folder's name in quotation marks and %2$lld is how many books the folder and its subfolders hold, a count.
            InterfaceText.line("folderRemoval.choiceMessage.subfolders", "\(name) contains \(number: bookCount) books and may have subfolders."),
            // Translators: Sentence of the dialog that asks how to delete a folder. "Move Contents Out" is the name of one of its buttons.
            InterfaceText.line("folderRemoval.choiceMessage.contents", "With Move Contents Out, they stay in the library and only the folder is deleted."),
            // Translators: Sentence of the dialog that asks how to delete a folder. %1$@ is the title of its button that deletes everything, such as "Move Everything to Trash", and %2$@ says what happens to the files, such as "their files go to the Trash, where you can recover them until the Trash is emptied".
            InterfaceText.line("folderRemoval.choiceMessage.everything", "With \(button), the folder and everything in it leave the library, and \(clause)."),
        ]
        sentences += ownFeedsChoiceSentences + feedsChoiceSentences + keptBooksChoiceSentences
        return SentenceWording.joined(sentences)
    }

    /// The choice message's sentences about the books a newer TextMouth
    /// added; none when there are none. True of both choices: "“Fiction”
    /// also holds 1 book a newer TextMouth added, which is kept."
    private var keptBooksChoiceSentences: [String] {
        guard keptBookCount > 0 else { return [] }
        let name = quotedName
        let count = keptBookCount
        // Translators: Last sentence of the dialog that asks how to delete a folder, when the folder holds books that a newer TextMouth added. %1$@ is the folder's name in quotation marks and %2$lld is how many books, a count.
        return [InterfaceText.line("folderRemoval.keptBooksChoiceSentences", "\(name) also holds \(number: count) books a newer TextMouth added, which are kept.")]
    }

    /// The confirmation message's sentences about the books a newer
    /// TextMouth added; none when there are none. It says what Delete
    /// Everything keeps beside what it removes: "But “Fiction” also holds 2
    /// books a newer TextMouth added: they are kept where they are, and so
    /// is every folder that holds one."
    private var keptBooksConfirmationSentences: [String] {
        guard keptBookCount > 0 else { return [] }
        let name = quotedName
        let count = keptBookCount
        // Translators: Last sentence of the second confirmation that deletes a folder, when the folder holds books that a newer TextMouth added. %1$@ is the folder's name in quotation marks and %2$lld is how many books, a count.
        return [InterfaceText.line("folderRemoval.keptBooksConfirmationSentences", "But \(name) also holds \(number: count) books a newer TextMouth added: they are kept where they are, and so is every folder that holds one.")]
    }

    /// The choice message's sentence about the feeds whose own folder this
    /// is (REV14 feeds 7); none when there are none. "It is the folder of
    /// the feed “Finish It!”: whichever you choose, the feed stays, with its
    /// downloads, but no folder lists them until Feed Info gives the feed
    /// another folder; Delete Feed… on the feed's row deletes a feed."
    private var ownFeedsChoiceSentences: [String] {
        guard let feeds = Self.quoted(ownFeedTitles) else { return [] }
        return [ownFeedTitles.count == 1
            // Translators: Sentence of the dialog that asks how to delete a folder, when it is the folder of one feed. %@ is the feed's title in quotation marks. "Feed Info" and "Delete Feed…" name a sheet and a command.
            ? InterfaceText.line("folderRemoval.ownFeedsChoiceSentences.downloads", "It is the folder of the feed \(feeds). Either way, the feed and its downloads stay, listed in no folder until Feed Info gives the feed another; Delete Feed… on its row deletes it.")
            // Translators: Sentence of the dialog that asks how to delete a folder, when it is the folder of several feeds. %@ is a list of the feeds' titles in quotation marks. "Feed Info" and "Delete Feed…" name a sheet and a command.
            : InterfaceText.line("folderRemoval.ownFeedsChoiceSentences.their", "It is the folder of the feeds \(feeds). Either way, the feeds and their downloads stay, listed in no folder until Feed Info gives each another; Delete Feed… on a feed's row deletes it.")]
    }

    /// The choice message's sentences about the feeds inside; none when
    /// there are none.
    private var feedsChoiceSentences: [String] {
        guard let feeds = quotedFeeds else { return [] }
        let button = buttonTitle
        if feedTitles.count == 1 {
            return [
                // Translators: Sentence of the dialog that asks how to delete a folder that holds one feed's folder. %@ is the feed's title in quotation marks.
                InterfaceText.line("folderRemoval.feedsChoiceSentences.holds", "It holds the folder of the feed \(feeds)."),
                // Translators: Sentence of the dialog that asks how to delete a folder that holds one feed's folder. "Move Contents Out" is the name of one of its buttons.
                InterfaceText.line("folderRemoval.feedsChoiceSentences.moves", "With Move Contents Out, the feed's folder moves with the rest."),
                // Translators: Sentence of the dialog that asks how to delete a folder that holds one feed's folder. %@ is the title of the button that deletes everything, such as "Move Everything to Trash". "Feed Info" and "Delete Feed…" name a sheet and a command.
                InterfaceText.line("folderRemoval.feedsChoiceSentences.downloads", "With \(button), the feed and its downloads stay, listed in no folder until Feed Info gives the feed another; Delete Feed… on its row deletes it."),
            ]
        }
        return [
            // Translators: Sentence of the dialog that asks how to delete a folder that holds several feeds' folders. %@ is a list of the feeds' titles in quotation marks.
            InterfaceText.line("folderRemoval.feedsChoiceSentences.folders", "It holds the folders of the feeds \(feeds)."),
            // Translators: Sentence of the dialog that asks how to delete a folder that holds several feeds' folders. "Move Contents Out" is the name of one of its buttons.
            InterfaceText.line("folderRemoval.feedsChoiceSentences.contents", "With Move Contents Out, their folders move with the rest."),
            // Translators: Sentence of the dialog that asks how to delete a folder that holds several feeds' folders. %@ is the title of the button that deletes everything, such as "Move Everything to Trash". "Feed Info" and "Delete Feed…" name a sheet and a command.
            InterfaceText.line("folderRemoval.feedsChoiceSentences.each", "With \(button), the feeds and their downloads stay, listed in no folder until Feed Info gives each another; Delete Feed… on a feed's row deletes it."),
        ]
    }

    /// The feeds inside, each in quotes, as a list: "“A”", "“A” and “B”";
    /// nil for none.
    private var quotedFeeds: String? {
        Self.quoted(feedTitles)
    }

    /// `titles`, each in quotes, as a list: "“A”", "“A” and “B”"; nil for
    /// none.
    private static func quoted(_ titles: [String]) -> String? {
        titles.isEmpty ? nil : CountWording.list(titles.map { RemovalText.quoted($0) })
    }

    /// The second confirmation's title: "Move Everything in “Fiction” to
    /// Trash?" or "Delete Everything in “Fiction” Permanently?"
    var confirmationTitle: String {
        RemovalText.question(mode.buttonTitle(RemovalText.everythingInObject(quotedName)))
    }

    /// The second confirmation's message: "“Fiction”, any subfolders, and
    /// the 3 books inside will be removed from the library. Their files go
    /// to the Trash, where you can recover them until the Trash is emptied."
    /// The feeds whose own folder it is, then those inside, named, stay
    /// (FR14, REV14 feeds 7): "The feed “Finish It!” stays, with its
    /// downloads, without a folder until Feed Info gives it another." Books
    /// a newer TextMouth added are named last, as kept with every folder
    /// holding one (`keptBookCount`).
    var confirmationMessage: String {
        let name = quotedName
        let count = bookCount
        let willBeRemoved: String
        switch bookCount {
        case 0:
            // Translators: First sentence of the second confirmation that deletes an empty folder. %@ is the folder's name in quotation marks.
            willBeRemoved = InterfaceText.line("folderRemoval.confirmationMessage.subfolders", "\(name) and any subfolders will be removed from the library.")
        case 1:
            // Translators: First sentence of the second confirmation that deletes a folder holding one book. %@ is the folder's name in quotation marks.
            willBeRemoved = InterfaceText.line("folderRemoval.confirmationMessage.inside", "\(name), any subfolders, and the book inside will be removed from the library.")
        default:
            // Translators: First sentence of the second confirmation that deletes a folder holding several books. %1$@ is the folder's name in quotation marks and %2$lld is how many books, a count.
            willBeRemoved = InterfaceText.line("folderRemoval.confirmationMessage.other", "\(name), any subfolders, and the \(number: count) books inside will be removed from the library.")
        }
        var sentences = [willBeRemoved, mode.filesSentence(plural: true)]
        let staying = ownFeedTitles + feedTitles
        if let feeds = Self.quoted(staying) {
            sentences.append(staying.count == 1
                // Translators: Sentence of the second confirmation that deletes a folder: one feed stays. %@ is the feed's title in quotation marks. "Feed Info" names a sheet.
                ? InterfaceText.line("folderRemoval.confirmationMessage.stays", "The feed \(feeds) stays, with its downloads, without a folder until Feed Info gives it another.")
                // Translators: Sentence of the second confirmation that deletes a folder: several feeds stay. %@ is a list of the feeds' titles in quotation marks. "Feed Info" names a sheet.
                : InterfaceText.line("folderRemoval.confirmationMessage.folders", "The feeds \(feeds) stay, with their downloads, without folders until Feed Info gives each another."))
        }
        return SentenceWording.joined(sentences + keptBooksConfirmationSentences)
    }

    /// What could not be deleted, each item staying in the library: "These
    /// items could not be moved to the Trash and remain in the library:".
    func failureMessage(_ failures: [String]) -> String {
        mode.failureMessage(failures, noun: .item)
    }
}

// MARK: - Preferences

/// The two preferences that decide what removing a book does: whether to
/// ask first, and whether deleted files go to the Trash.
struct RemovalPreferences: Equatable {
    /// "Confirm before removing a book".
    var confirmsFirst: Bool
    /// "Move to Trash instead of deleting".
    var movesToTrash: Bool

    /// The mode in which removal deletes files.
    var deletionMode: RemovalMode {
        .deleting(movesToTrash: movesToTrash)
    }

    init(confirmsFirst: Bool, movesToTrash: Bool) {
        self.confirmsFirst = confirmsFirst
        self.movesToTrash = movesToTrash
    }

    /// The preferences `config` holds.
    init(_ config: ConfigService.AppConfig) {
        self.init(
            confirmsFirst: config.confirmBeforeDelete,
            movesToTrash: config.moveToTrashInsteadOfDeleting
        )
    }

    /// The deleting action as a phrase inside a sentence: "move the files
    /// to the Trash" or "delete the files permanently".
    var deletingTheFiles: String {
        movesToTrash
            // Translators: What deleting a book's files does when they go to the Trash, as a verb phrase in lower case inside a sentence: "asks whether to move the files to the Trash or keep them".
            ? InterfaceText.line("removalPreferences.deletingTheFiles.trash", "move the files to the Trash")
            // Translators: What deleting a book's files does when they are deleted permanently, as a verb phrase in lower case inside a sentence: "asks whether to delete the files permanently or keep them".
            : InterfaceText.line("removalPreferences.deletingTheFiles.permanently", "delete the files permanently")
    }

    // MARK: Storage Settings

    /// What deleting a book does under the Trash preference, as Storage
    /// settings explain it, beside what Remove from Library Only does.
    var deletionSummary: String {
        let keeping = RemovalMode.keepFiles
        let deleted = deletionMode.filesClause(plural: false)
        return SentenceWording.joined([
            // Translators: First sentence of the explanation in Storage settings of what removing a book does. %@ says what happens to the book's files, such as "its files go to the Trash, where you can recover them until the Trash is emptied".
            InterfaceText.line("removalPreferences.deletionSummary", "When a book is deleted, \(deleted)."),
            RemovalChoiceWording.optionSentence(keeping.buttonTitle(), keeping.filesClause(plural: false)),
        ])
    }

    /// The hint for "Confirm before removing a book": what removing does
    /// with the preference on and off, in the deleting mode in force.
    var confirmationExplanation: String {
        let deleting = deletingTheFiles
        return SentenceWording.joined([
            // Translators: First sentence of the hint of the setting that confirms before removing a book. %@ is what deleting does, such as "move the files to the Trash".
            InterfaceText.line("removalPreferences.confirmation.whether", "When on, removing a book first asks whether to \(deleting) or keep them in the TextMouth library folder."),
            // Translators: Second sentence of the hint of the setting that confirms before removing a book. %@ is what deleting does, such as "move the files to the Trash".
            InterfaceText.line("removalPreferences.confirmationExplanation.once", "When off, removing a book will \(deleting) at once."),
        ])
    }

    /// The hint for "Move to Trash instead of deleting": what happens to a
    /// deleted book's files with the preference on and off.
    static var trashPreferenceExplanation: String {
        SentenceWording.joined([
            // Translators: First sentence of the hint of the setting that moves deleted files to the Trash: what happens with the setting on.
            InterfaceText.line("removalPreferences.trashPreference.recover", "When on, a deleted book's files go to the Trash, where you can recover them until the Trash is emptied."),
            // Translators: Second sentence of the hint of the setting that moves deleted files to the Trash: what happens with the setting off.
            InterfaceText.line("removalPreferences.trashPreference.permanently", "When off, its files are deleted permanently and cannot be recovered."),
        ])
    }
}

/// The removal preferences as config.json holds them, published only when
/// one of the two changes. The library's views, its Remove Book dialog, the
/// menu bar, and the Storage settings' own toggles all take the preferences
/// from this one model, so none of them is left showing or promising the old
/// behavior after a preference changes, in Settings or by an edit of
/// config.json, and other settings changes redraw none of them.
@MainActor
final class RemovalPreferencesModel: ObservableObject {
    /// The model the app's windows and menus share.
    static let shared = RemovalPreferencesModel()

    /// The removal preferences now in force.
    @Published private(set) var preferences: RemovalPreferences

    /// The configuration the preferences are kept in.
    private let configService: ConfigService
    /// Keeps `preferences` in step with config.json.
    private var subscription: AnyCancellable?

    /// A model following `configService`'s removal preferences: the app's
    /// own configuration, unless a test passes one of its own.
    init(configService: ConfigService = .shared) {
        self.configService = configService
        preferences = RemovalPreferences(configService.config)
        subscription = configService.$config
            .map { RemovalPreferences($0) }
            .removeDuplicates()
            .sink { [weak self] current in
                // The first value is the current one; publish only changes.
                guard let self, self.preferences != current else { return }
                self.preferences = current
            }
    }

    // MARK: Changing the Preferences

    /// Turns "Confirm before removing a book" on or off and saves
    /// config.json. `preferences` hears of it from the configuration, as of
    /// any other change.
    func setConfirmsFirst(_ confirmsFirst: Bool) {
        save { $0.confirmBeforeDelete = confirmsFirst }
    }

    /// Turns "Move to Trash instead of deleting" on or off and saves
    /// config.json. `preferences` hears of it from the configuration, as of
    /// any other change.
    func setMovesToTrash(_ movesToTrash: Bool) {
        save { $0.moveToTrashInsteadOfDeleting = movesToTrash }
    }

    /// Makes `change` to the configuration and saves it, when that changes
    /// anything. Only the one field changes, so the save keeps every other
    /// value in force, those of an edit of config.json included.
    private func save(_ change: (inout ConfigService.AppConfig) -> Void) {
        var config = configService.config
        change(&config)
        guard config != configService.config else { return }
        configService.config = config
        configService.saveToDisk()
    }
}

// MARK: - Sentence Case

/// Sentence case for words built from parts, shared with the feed reader's
/// words, which start sentences with a phrase it built (FR14).
extension String {
    /// The text with its first letter in upper case, to start a sentence.
    var capitalizingFirstLetter: String {
        prefix(1).uppercased() + dropFirst()
    }

    /// The text with its first letter in lower case, to sit inside a
    /// sentence.
    var lowercasingFirstLetter: String {
        prefix(1).lowercased() + dropFirst()
    }
}
