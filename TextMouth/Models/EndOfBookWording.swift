import Foundation

/// What a reader says as its book ends (`ReaderViewModel.handleEndOfBook()`),
/// in one place, so every way a book can end words what they share alike:
/// "Starting: <title>" for the book that follows, "Restarting: <title>" for
/// a book that loops, and "Finished: <title>" followed by why nothing
/// follows, each reason a sentence of its own. The book's own end-of-book
/// behavior and the reading list's (FR09) both speak through it.
enum EndOfBookWording {

    // MARK: - What Follows

    /// What VoiceOver hears as the book that follows is about to start:
    /// "Starting: <title>".
    static func starting(_ title: String) -> String {
        "Starting: \(title)"
    }

    /// What VoiceOver hears as a book that loops starts again:
    /// "Restarting: <title>".
    static func restarting(_ title: String) -> String {
        "Restarting: \(title)"
    }

    /// What VoiceOver hears as Play starts a finished book over from its
    /// beginning, its end-of-book choice "Stop, and Play Starts Over" (TODO
    /// P07): "Starting again: <title>", before the book plays, so the
    /// listener knows the place moved.
    static func startingAgain(_ title: String) -> String {
        "Starting again: \(title)"
    }

    /// What VoiceOver hears when Play reaches a finished book whose next
    /// book has been asked for, and is opening, but does not play yet:
    /// "Still starting: <title>", as "Starting: <title>" said it, so that
    /// the press is heard.
    static func stillStarting(_ title: String) -> String {
        "Still starting: \(title)"
    }

    // MARK: - Nothing Follows

    /// What VoiceOver hears when a book ends and nothing follows it:
    /// "Finished: <title>", then each of `notes`, then, when
    /// `sleepTimerExpired`, `sleepTimerExpiredNote`, each a sentence of its
    /// own: "Finished: Dune. No more books in folder. Sleep timer expired."
    /// With no note at all, it is "Finished: <title>" alone, with no full
    /// stop, as it has always been.
    ///
    /// - Parameters:
    ///   - title: The finished book's title.
    ///   - notes: Why nothing follows, each a sentence without its full
    ///     stop, which this adds.
    ///   - sleepTimerExpired: Whether the reader's sleep timer stopped
    ///     playback where the book ended.
    static func finished(_ title: String, notes: [String] = [], sleepTimerExpired: Bool = false) -> String {
        let sentences = ["Finished: \(title)"] + notes + (sleepTimerExpired ? [sleepTimerExpiredNote] : [])
        let joined = sentences.joined(separator: ". ")
        return sentences.count > 1 ? joined + "." : joined
    }

    /// The reader's sleep timer stopped playback where the book ended.
    static let sleepTimerExpiredNote = "Sleep timer expired"

    /// The book that would follow was not started: the finished book's
    /// sleep timer could never pause it, so it would play on past the timer.
    static let nextBookNotStartedNote = "Next book not started because of the sleep timer"

    /// A book that loops waits at its beginning: its reader's sleep timer
    /// stopped playback at its end.
    static let notRestartedNote = "Not restarted because of the sleep timer"

    /// No book follows the finished one in its folder.
    static let noMoreBooksInFolderNote = "No more books in folder"

    /// Only finished books follow the finished one in its folder, and
    /// Continue to Next Book passes over them (REV14), as the reading list
    /// says of the finished books it passes over:
    /// "Finished: Dune. Every book after it in the folder is finished."
    static let onlyFinishedBooksInFolderNote = "Every book after it in the folder is finished"

    /// The same note for the direction listening goes in: going down it is
    /// `onlyFinishedBooksInFolderNote`; going up, where a feed or folder
    /// that plays the book above looks, "Every book before it in the folder
    /// is finished". A feed's items say the same words.
    static func onlyFinishedBooksInFolderNote(going direction: ReadingList.Direction) -> String {
        switch direction {
        case .down: return onlyFinishedBooksInFolderNote
        case .up: return "Every book before it in the folder is finished"
        }
    }

    // MARK: - An Episode That Must Be Downloaded

    /// What a feed's episode that ended says of the next one, whose file is
    /// not here (FR19): "Downloading the next episode: <title>", or "the
    /// next article" for an article. A sentence after "Finished: <title>."
    static func downloadingNextNote(_ item: FeedItem) -> String {
        "Downloading the next \(kind(of: item)): \(item.title)"
    }

    /// What VoiceOver hears when the next episode's download failed and
    /// playback stopped: "The next episode could not be downloaded, so
    /// playback stopped. <reason>", the reason being the download's own
    /// sentence, kept whole. "The next article" for an article.
    ///
    /// - Parameters:
    ///   - reason: Why the download failed, as the item's row says it.
    ///   - isArticle: Whether the next item is an article, not an episode.
    static func nextEpisodeNotDownloaded(reason: String, isArticle: Bool = false) -> String {
        "The next \(kind(isArticle: isArticle)) could not be downloaded, so playback stopped. \(reason)"
    }

    /// What VoiceOver hears when the listener cancelled the download of the
    /// next episode (or article) the end was waiting for: the user's own
    /// words (question 19, October 16). One sentence for both kinds.
    static let nextEpisodeDownloadCancelled = "Download cancelled, so playback stopped."

    /// Why a download the reader asked for did not start: the engine
    /// refused it, as it does while TextMouth quits or the feed is deleted.
    static let downloadNotStartedReason = "TextMouth is not downloading right now."

    /// "article" for an article, "episode" for any other item.
    static func kind(of item: FeedItem) -> String {
        kind(isArticle: item.isArticle)
    }

    /// "article" or "episode".
    private static func kind(isArticle: Bool) -> String {
        isArticle ? "article" : "episode"
    }

    // MARK: - A Book Resting at Its End

    /// What a surface that says how far a book has got says of a book
    /// resting at its end, finished (`Book.restsAtEnd`, TODO P07), in place
    /// of "100 percent" and its time left: the library row, shown and
    /// spoken, Speak Info, Where Am I?, and Copy Reading Position. The user
    /// decided on October 10, 2026 (question 12): "yes except the reader,
    /// those controls with the info should still be there", so the reader's
    /// own controls and status row keep their percent and time. A word,
    /// never a sign or a colour, read alike on screen, by VoiceOver, and on
    /// a braille display.
    static let finishedProgress = "Finished"

    // MARK: - The Choices

    /// What the Playback tab says, under its "When book ends" picker, of
    /// what Play does on a finished book with each choice that stops there
    /// (TODO P07), shown and read alike.
    static let playOnAFinishedBookCaption =
        "With \"Stop\", Play on a finished book says it is finished; "
        + "with \"Stop, and Play Starts Over\", Play starts it again from the beginning."
}
