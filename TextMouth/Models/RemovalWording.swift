import Foundation

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
        let spaced = object.isEmpty ? "" : "\(object) "
        switch self {
        case .keepFiles: return "Remove \(spaced)from Library Only"
        case .moveToTrash: return "Move \(spaced)to Trash"
        case .deletePermanently: return "Delete \(spaced)Permanently"
        }
    }

    /// The same action as VoiceOver speaks it, naming `object` in full:
    /// "Move 3 selected books to the Trash", "Delete “Notes” permanently".
    func spokenAction(_ object: String) -> String {
        switch self {
        case .keepFiles: return "Remove \(object) from the library and keep the files"
        case .moveToTrash: return "Move \(object) to the Trash"
        case .deletePermanently: return "Delete \(object) permanently"
        }
    }

    /// What happens to the files, as a clause to build sentences from:
    /// "its files go to the Trash, where you can recover them until the
    /// Trash is emptied". `plural` chooses "their" over "its".
    func filesClause(plural: Bool) -> String {
        let files = plural ? "their files" : "its files"
        switch self {
        case .keepFiles:
            return "\(files) stay in the TextMouth library folder"
        case .moveToTrash:
            return "\(files) go to the Trash, where you can recover them until the Trash is emptied"
        case .deletePermanently:
            return "\(files) are deleted permanently and cannot be recovered"
        }
    }

    /// The files clause as a sentence of its own: "Their files go to the
    /// Trash, where you can recover them until the Trash is emptied."
    func filesSentence(plural: Bool) -> String {
        let clause = filesClause(plural: plural)
        return clause.prefix(1).uppercased() + clause.dropFirst() + "."
    }

    /// The report that `subject` was removed this way: "Moved 3 books to the
    /// Trash.", "Deleted “Notes” permanently.", "Removed “Notes” from the
    /// library. Its files stay in the TextMouth library folder."
    func completionSentence(_ subject: String, plural: Bool) -> String {
        switch self {
        case .keepFiles:
            return "Removed \(subject) from the library. " + filesSentence(plural: plural)
        case .moveToTrash:
            return "Moved \(subject) to the Trash."
        case .deletePermanently:
            return "Deleted \(subject) permanently."
        }
    }

    /// Introduces the items this removal could not remove, each of which
    /// stays in the library. `noun` names one item, such as "book":
    /// "These books could not be moved to the Trash and remain in the
    /// library:".
    func failureHeading(count: Int, noun: String) -> String {
        let plural = count != 1
        let subject = plural ? "These \(noun)s" : "This \(noun)"
        let remain = plural ? "remain" : "remains"
        switch self {
        case .keepFiles:
            return "\(subject) could not be removed from the library and \(remain) in it:"
        case .moveToTrash:
            return "\(subject) could not be moved to the Trash and \(remain) in the library:"
        case .deletePermanently:
            return "\(subject) could not be deleted and \(remain) in the library:"
        }
    }

    /// The failure heading followed by one line per item, each reading
    /// "Title: reason".
    func failureMessage(_ failures: [String], noun: String = "book") -> String {
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
        if let title { return "“\(title)”" }
        return isPlural ? "\(count) books" : "1 book"
    }

    /// A button that removes the books at once: "Move to Trash" for one
    /// book, "Move 3 Books to Trash" for several.
    var buttonTitle: String {
        mode.buttonTitle(isPlural ? "\(count) Books" : "")
    }

    /// What VoiceOver says for `buttonTitle`: "Move “Notes” to the Trash".
    var accessibilityLabel: String {
        mode.spokenAction(subject)
    }

    /// A button that removes the books selected in a list, such as the
    /// Duplicate Finder's: "Move 3 Selected to Trash".
    var selectionButtonTitle: String {
        mode.buttonTitle("\(count) Selected")
    }

    /// What VoiceOver says for `selectionButtonTitle`: "Move 3 selected
    /// books to the Trash".
    var selectionAccessibilityLabel: String {
        mode.spokenAction("\(count) selected \(isPlural ? "books" : "book")")
    }

    /// The question asked before removing: "Move Book to Trash?", "Delete 3
    /// Books Permanently?".
    var confirmationTitle: String {
        mode.buttonTitle(isPlural ? "\(count) Books" : "Book") + "?"
    }

    /// What the confirmation explains: "“Notes” will be removed from the
    /// library. Its files go to the Trash, where you can recover them until
    /// the Trash is emptied."
    var confirmationMessage: String {
        "\(subject) will be removed from the library. " + mode.filesSentence(plural: isPlural)
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
struct RemovalChoiceWording: Equatable {
    /// Deleting the books' files, to the Trash or permanently.
    let deletion: RemovalWording
    /// Remove from Library Only.
    let keeping: RemovalWording

    /// The choice for `books` under the Trash preference.
    init(books: [Book], movesToTrash: Bool) {
        deletion = RemovalWording(.deleting(movesToTrash: movesToTrash), books: books)
        keeping = RemovalWording(.keepFiles, books: books)
    }

    /// "Remove Book?" or "Remove 3 Books?"
    var title: String {
        deletion.count == 1 ? "Remove Book?" : "Remove \(deletion.count) Books?"
    }

    /// The deleting button, "Move to Trash" or "Delete Permanently"; the
    /// title already says how many books.
    var deleteButtonTitle: String {
        deletion.mode.buttonTitle()
    }

    /// The keeping button: "Remove from Library Only".
    var keepButtonTitle: String {
        keeping.mode.buttonTitle()
    }

    /// Explains both choices: "Choose how to remove “Notes” from the
    /// library. With Move to Trash, its files go to the Trash, where you can
    /// recover them until the Trash is emptied. With Remove from Library
    /// Only, its files stay in the TextMouth library folder."
    var message: String {
        let plural = deletion.count != 1
        return "Choose how to remove \(deletion.subject) from the library. "
            + "With \(deleteButtonTitle), \(deletion.mode.filesClause(plural: plural)). "
            + "With \(keepButtonTitle), \(keeping.mode.filesClause(plural: plural))."
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

    /// The folder's name in quotes, as sentences name it.
    private var quotedName: String { "“\(folderName)”" }

    /// The button: "Move Everything to Trash" or "Delete Everything
    /// Permanently".
    var buttonTitle: String {
        mode.buttonTitle("Everything")
    }

    /// The first dialog, which offers to move the contents out first or to
    /// remove everything, explains both: "“Fiction” contains 3 books and may
    /// have subfolders. With Move Contents Out, they stay in the library and
    /// only the folder is deleted. With Move Everything to Trash, the folder
    /// and everything in it leave the library, and their files go to the
    /// Trash, where you can recover them until the Trash is emptied."
    var choiceMessage: String {
        let books = bookCount == 1 ? "1 book" : "\(bookCount) books"
        return "\(quotedName) contains \(books) and may have subfolders. "
            + "With Move Contents Out, they stay in the library and only the folder is deleted. "
            + "With \(buttonTitle), the folder and everything in it leave the library, "
            + "and \(mode.filesClause(plural: true))."
    }

    /// The second confirmation's title: "Move Everything in “Fiction” to
    /// Trash?" or "Delete Everything in “Fiction” Permanently?"
    var confirmationTitle: String {
        mode.buttonTitle("Everything in \(quotedName)") + "?"
    }

    /// The second confirmation's message: "“Fiction”, any subfolders, and
    /// the 3 books inside will be removed from the library. Their files go
    /// to the Trash, where you can recover them until the Trash is emptied."
    var confirmationMessage: String {
        let contents: String
        switch bookCount {
        case 0: contents = "\(quotedName) and any subfolders"
        case 1: contents = "\(quotedName), any subfolders, and the book inside"
        default: contents = "\(quotedName), any subfolders, and the \(bookCount) books inside"
        }
        return "\(contents) will be removed from the library. " + mode.filesSentence(plural: true)
    }

    /// What could not be deleted, each item staying in the library: "These
    /// items could not be moved to the Trash and remain in the library:".
    func failureMessage(_ failures: [String]) -> String {
        mode.failureMessage(failures, noun: "item")
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
}
