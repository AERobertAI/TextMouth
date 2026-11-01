import Foundation

/// What Next in Folder and Previous in Folder say (0.2.5), beyond the
/// sentences they share with the end of a book and the reading list:
/// "Starting: <title>" (`EndOfBookWording.starting(_:)`) for an item that
/// plays, and "Opening: <title>" (`ReadingListReaderWording.opening`) for one
/// that does not.
enum FolderNavigationWording {

    /// What the command says when no item lies the way it goes, or only
    /// finished ones do and the folder passes over them: the succession's own
    /// note, as the end of a book says it after "Finished: <title>.", with a
    /// full stop, for example "No more books in folder." or "Every book
    /// before it in the folder is finished."
    static func nothingThatWay(_ note: String) -> String {
        note + "."
    }

    /// What the command says when the item that way is a feed's episode (or
    /// article) whose file is not here, and it is downloaded first: "Downloading
    /// the next episode: <title>", or "the previous episode" going up.
    static func downloading(_ item: FeedItem, going direction: ReadingList.Direction) -> String {
        let side = direction == .down ? "next" : "previous"
        return "Downloading the \(side) \(EndOfBookWording.kind(of: item)): \(item.title)"
    }
}
