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
