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
        "Downloading the \(side(direction)) \(EndOfBookWording.kind(of: item)): \(item.title)"
    }

    /// What the command says when the episode's download failed: "The
    /// previous episode could not be downloaded. <reason>", the reason being
    /// the download's own sentence, kept whole. "The next article" for an
    /// article. When the book was playing, it was paused for the move, and
    /// the sentence says so, as the end of a book's does: "The next episode
    /// could not be downloaded, so playback stopped. <reason>".
    static func episodeNotDownloaded(
        reason: String,
        isArticle: Bool,
        going direction: ReadingList.Direction,
        playbackStopped: Bool
    ) -> String {
        let what = "The \(side(direction)) \(EndOfBookWording.kind(isArticle: isArticle))"
        return "\(what) could not be downloaded\(playbackStopped ? ", so playback stopped" : ""). \(reason)"
    }

    /// What the command says when the listener cancelled the episode's
    /// download: "Download of the previous episode cancelled." and, when the
    /// book was playing, "Download of the next episode cancelled, so
    /// playback stopped."
    static func downloadCancelled(
        isArticle: Bool,
        going direction: ReadingList.Direction,
        playbackStopped: Bool
    ) -> String {
        "Download of the \(side(direction)) \(EndOfBookWording.kind(isArticle: isArticle)) cancelled\(playbackStopped ? ", so playback stopped" : "")."
    }

    /// "next" going down, "previous" going up.
    private static func side(_ direction: ReadingList.Direction) -> String {
        direction == .down ? "next" : "previous"
    }

}
