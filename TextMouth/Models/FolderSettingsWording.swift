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
    static let title = "Folder Settings"

    /// The label of the folder's place: the folder that holds it.
    static let locationLabel = "Location"

    /// The label of the books in the folder and every folder below it.
    static let booksLabel = "Books"

    /// The label of the folder's own subfolders, shown only when it has any.
    static let subfoldersLabel = "Subfolders"

    /// The label of the feeds inside the folder, shown only when it has any.
    static let feedsLabel = "Feeds"

    /// The label of the time left in all the folder's books, shown only
    /// when it is known.
    static let timeRemainingLabel = "Time remaining"

    /// The heading over the listening options.
    static let listeningHeading = "Listening"

    /// The title of the button that closes the sheet.
    static let done = "Done"

    /// What the sheet says in place of the folder, when the folder was
    /// deleted in another window while the sheet was open.
    static let folderGone = "This folder is no longer in the library."

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
