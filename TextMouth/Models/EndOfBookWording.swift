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
}
