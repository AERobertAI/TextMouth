import Combine
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

    /// What happens to the files of `owner`, a possessive such as "its" or
    /// "a deleted book's", as a clause to build sentences from: "its files
    /// go to the Trash, where you can recover them until the Trash is
    /// emptied".
    func filesClause(of owner: String) -> String {
        let files = "\(owner) files"
        switch self {
        case .keepFiles:
            return "\(files) stay in the TextMouth library folder"
        case .moveToTrash:
            return "\(files) go to the Trash, where you can recover them until the Trash is emptied"
        case .deletePermanently:
            return "\(files) are deleted permanently and cannot be recovered"
        }
    }

    /// The files clause for one book ("its files") or several ("their
    /// files").
    func filesClause(plural: Bool) -> String {
        filesClause(of: plural ? "their" : "its")
    }

    /// The files clause as a sentence of its own: "Their files go to the
    /// Trash, where you can recover them until the Trash is emptied."
    func filesSentence(plural: Bool) -> String {
        filesClause(plural: plural).capitalizingFirstLetter + "."
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
        return deletion.count == 1 ? "Remove Book?" : "Remove \(deletion.count) Books?"
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
        return "Choose how to remove \(deletion.subject) from the library. "
            + "With \(deleteButtonTitle), \(deletion.mode.filesClause(plural: plural)). "
            + "With \(keepButtonTitle), \(keeping.mode.filesClause(plural: plural))."
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
        self.mode = mode
        count = items.count
        title = items.count == 1 ? items.first?.title : nil
    }

    /// Whether the words speak of several downloads (or none).
    private var isPlural: Bool { count != 1 }

    /// The downloads as a sentence names them: "the download of “Ep. 368”",
    /// or "3 downloads".
    private var subject: String {
        if let title { return "the download of “\(title)”" }
        return "\(count) downloads"
    }

    /// "Delete Download?" or "Delete 3 Downloads?"
    var confirmationTitle: String {
        (isPlural ? "Delete \(count) Downloads" : "Delete Download") + "?"
    }

    /// The deleting button, "Delete Download" or "Delete Downloads"; the
    /// title says how many.
    var buttonTitle: String {
        isPlural ? "Delete Downloads" : "Delete Download"
    }

    /// What the confirmation explains: "The download of “Ep. 368” will be
    /// deleted. Its files go to the Trash, where you can recover them until
    /// the Trash is emptied. Its place, bookmarks, and transcript, if it has
    /// any, are kept, and it can be downloaded again."
    var confirmationMessage: String {
        let kept = isPlural
            ? "Their places, bookmarks, and transcripts, if they have any, are kept, and they can be downloaded again."
            : "Its place, bookmarks, and transcript, if it has any, are kept, and it can be downloaded again."
        return "\(subject.capitalizingFirstLetter) will be deleted. " + mode.filesSentence(plural: isPlural) + " " + kept
    }

    /// The report once the downloads are deleted, of which `keptCount` kept
    /// their packages with the listener's place, bookmarks, or transcript:
    /// "Moved the download of “Ep. 368” to the Trash. Its place, bookmarks,
    /// and transcript are kept.", or "Deleted 3 downloads permanently. The
    /// places, bookmarks, and transcripts of 2 of them are kept."
    func completionMessage(keptCount: Int) -> String {
        let deleted = mode.completionSentence(subject, plural: isPlural)
        guard keptCount > 0 else { return deleted }
        if !isPlural {
            return deleted + " Its place, bookmarks, and transcript are kept."
        }
        if keptCount >= count {
            return deleted + " Their places, bookmarks, and transcripts are kept."
        }
        return deleted + " The places, bookmarks, and transcripts of \(keptCount) of them are kept."
    }
}

// MARK: - The Library's Remove Command

/// The words for the library's Remove command in the book context menu and
/// the edit bar. With "Confirm before removing a book" on, it asks how to
/// remove the books, so it promises nothing about their files; with it off,
/// it deletes them at once, so it says how.
struct LibraryRemoveCommandWording: Equatable {
    let preferences: RemovalPreferences
    /// The words for deleting the books at once in the mode the Trash
    /// preference chooses.
    let removal: RemovalWording

    /// The command for `count` books; `title` names the book when there is
    /// exactly one.
    init(preferences: RemovalPreferences, count: Int, title: String? = nil) {
        self.preferences = preferences
        removal = RemovalWording(preferences.deletionMode, count: count, title: title)
    }

    /// The command for `books`.
    init(preferences: RemovalPreferences, books: [Book]) {
        self.init(preferences: preferences, count: books.count, title: books.first?.title)
    }

    /// The command's title when it asks how to remove before removing
    /// anything; the ellipsis says that a choice follows.
    private static let askFirstTitle = "Remove from Library..."

    /// The context-menu item: "Remove from Library..." or "Remove 3 Books
    /// from Library..." when it asks first, otherwise "Move to Trash",
    /// "Move 3 Books to Trash", or "Delete 3 Books Permanently". A menu item
    /// is read by its title, so the title alone must say all of this.
    var menuTitle: String {
        guard preferences.confirmsFirst else { return removal.buttonTitle }
        return removal.count == 1 ? Self.askFirstTitle : "Remove \(removal.count) Books from Library..."
    }

    /// The menu bar's Remove command, which acts on whatever is selected in
    /// the library window and so names no count: "Remove from Library..."
    /// when it asks first, otherwise "Move to Trash" or "Delete
    /// Permanently". With confirmation off it never promises less than it
    /// does.
    static func menuBarTitle(preferences: RemovalPreferences) -> String {
        preferences.confirmsFirst ? askFirstTitle : preferences.deletionMode.buttonTitle()
    }

    /// The edit bar's short button: "Remove..." when it asks first,
    /// otherwise "Move to Trash" or "Delete Permanently".
    var shortTitle: String {
        preferences.confirmsFirst ? "Remove..." : removal.mode.buttonTitle()
    }

    /// What VoiceOver says for the button: "Remove 3 books from the library"
    /// when it asks first, otherwise "Move 3 books to the Trash".
    var accessibilityLabel: String {
        preferences.confirmsFirst ? "Remove \(removal.subject) from the library" : removal.accessibilityLabel
    }

    /// What VoiceOver adds after a pause: the choice that follows, or what
    /// happens to the files.
    var accessibilityHint: String {
        guard preferences.confirmsFirst else {
            return removal.mode.filesSentence(plural: removal.count != 1)
        }
        return "Asks whether to \(preferences.deletingTheFiles) or keep them in the TextMouth library folder."
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
        let books = CountWording.books(bookCount)
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

    /// The deleting action as a phrase inside a sentence: "move the files
    /// to the Trash" or "delete the files permanently".
    var deletingTheFiles: String {
        deletionMode.spokenAction("the files").lowercasingFirstLetter
    }

    // MARK: Storage Settings

    /// What deleting a book does under the Trash preference, as Storage
    /// settings explain it, beside what Remove from Library Only does.
    var deletionSummary: String {
        let keeping = RemovalMode.keepFiles
        return "When a book is deleted, \(deletionMode.filesClause(plural: false)). "
            + "With \(keeping.buttonTitle()), \(keeping.filesClause(plural: false))."
    }

    /// The hint for "Confirm before removing a book": what removing does
    /// with the preference on and off, in the deleting mode in force.
    var confirmationExplanation: String {
        "When on, removing a book first asks whether to \(deletingTheFiles) "
            + "or keep them in the TextMouth library folder. "
            + "When off, removing a book will \(deletingTheFiles) at once."
    }

    /// The hint for "Move to Trash instead of deleting": what happens to a
    /// deleted book's files with the preference on and off.
    static var trashPreferenceExplanation: String {
        "When on, \(RemovalMode.moveToTrash.filesClause(of: "a deleted book's")). "
            + "When off, \(RemovalMode.deletePermanently.filesClause(of: "its"))."
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

private extension String {
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
