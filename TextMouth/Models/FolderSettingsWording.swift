import Foundation

/// Every word the Folder Settings sheet says and speaks (FR19): its title,
/// the labels of the folder's facts, the heading over its listening
/// options, its Done button, and the line shown when the folder is gone.
/// The listening options' own controls speak `ListeningOptionsWording`,
/// and the facts' values are the words Speak Info speaks
/// (`LibraryInfoWording`), so nothing is spelled twice. One place, so a
/// test pins each string, since the listener hears them through VoiceOver
/// and reads them in braille.
enum FolderSettingsWording {

    /// The sheet's navigation title (the window's title while it is open).
    static var title: String {
        // Translators: Text of the Folder Settings sheet, which shows one library folder's facts and its listening options. The sheet's navigation title (the window's title while it is open).
        InterfaceText.line("common.folderSettings", "Folder Settings")
    }

    /// The label of the folder's place: the folder that holds it.
    static var locationLabel: String {
        // Translators: Text of the Folder Settings sheet, which shows one library folder's facts and its listening options. The label of the folder's place: the folder that holds it.
        InterfaceText.line("common.location", "Location")
    }

    /// The label of the books in the folder and every folder below it.
    static var booksLabel: String {
        // Translators: Text of the Folder Settings sheet, which shows one library folder's facts and its listening options. The label of the books in the folder and every folder below it.
        InterfaceText.line("common.books", "Books")
    }

    /// The label of the folder's own subfolders, shown only when it has any.
    static var subfoldersLabel: String {
        // Translators: Text of the Folder Settings sheet, which shows one library folder's facts and its listening options. The label of the folder's own subfolders, shown only when it has any.
        InterfaceText.line("folderSettings.subfoldersLabel", "Subfolders")
    }

    /// The label of the feeds inside the folder, shown only when it has any.
    static var feedsLabel: String {
        // Translators: Text of the Folder Settings sheet, which shows one library folder's facts and its listening options. The label of the feeds inside the folder, shown only when it has any.
        InterfaceText.line("common.feeds", "Feeds")
    }

    /// The label of the time left in all the folder's books, shown only
    /// when it is known.
    static var timeRemainingLabel: String {
        // Translators: Text of the Folder Settings sheet, which shows one library folder's facts and its listening options. The label of the time left in all the folder's books, shown only when it is known.
        InterfaceText.line("folderSettings.timeRemainingLabel", "Time remaining")
    }

    /// The heading over the listening options.
    static var listeningHeading: String {
        // Translators: Text of the Folder Settings sheet, which shows one library folder's facts and its listening options. The heading over the listening options.
        InterfaceText.line("folderSettings.listeningHeading", "Listening")
    }

    /// The title of the button that closes the sheet.
    static var done: String {
        // Translators: Text of the Folder Settings sheet, which shows one library folder's facts and its listening options. The title of the button that closes the sheet.
        InterfaceText.line("common.done", "Done")
    }

    /// What the sheet says in place of the folder, when the folder was
    /// deleted in another window while the sheet was open.
    static var folderGone: String {
        // Translators: Text of the Folder Settings sheet, which shows one library folder's facts and its listening options. What the sheet says in place of the folder, when the folder was deleted in another window while the sheet was open.
        InterfaceText.line("folderSettings.folderGone", "This folder is no longer in the library.")
    }

    /// One labelled fact of a folder: what it is and its value.
    struct Fact: Equatable {
        /// What the fact is: "Books".
        let label: String
        /// The fact: "12 books, 3 unopened".
        let value: String
    }

    /// The facts of a folder, in the order the sheet lists them: where it
    /// is (`parentPath`, empty for the library's top level, which reads
    /// "Library Root"), its books, then its subfolders, its feeds, and the
    /// time left, each of those only when it has any. The values come from
    /// the functions Speak Info uses.
    static func facts(of folder: FolderInfoFacts, parentPath: String) -> [Fact] {
        var facts = [
            Fact(label: locationLabel, value: parentPath.isEmpty ? LibraryFolderOption.rootLabel : parentPath),
            Fact(label: booksLabel, value: LibraryInfoWording.booksPhrase(of: folder)),
        ]
        // The facts a folder may lack: a nil value is left out.
        let optional: [(label: String, value: String?)] = [
            (subfoldersLabel, LibraryInfoWording.subfoldersPhrase(of: folder)),
            (feedsLabel, LibraryInfoWording.feedsPhrase(of: folder)),
            (timeRemainingLabel, LibraryInfoWording.timeRemainingPhrase(of: folder)),
        ]
        for case (let label, let value?) in optional {
            facts.append(Fact(label: label, value: value))
        }
        return facts
    }
}
