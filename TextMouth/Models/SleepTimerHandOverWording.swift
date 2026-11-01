import Foundation

/// What the listener hears when a sleep timer that goes on with the next book
/// (0.2.5) is lost without being asked to: in one place, so the service, the
/// reader, and the tests word it alike. A timer that runs out, or that the
/// listener cancels, has its own words (`ReaderViewModel` and the sheet).
enum SleepTimerHandOverWording {
    /// Said when a timer held for a book is stopped because the book truly
    /// could not be opened: it failed to load, its download stopped or failed,
    /// the Library refused the open, or the book was deleted. The timer would
    /// count toward pausing nothing. Closing the book's window while it loads
    /// stops the timer without a word, as closing the window a timer belongs
    /// to does.
    static let noBook = "Sleep timer cancelled, because the next book could not be opened."

    /// How long the sentence waits after a book fails to open, in seconds, so
    /// the reason is read first: the error view's own focus reads it 1.2
    /// seconds after it appears, and the sentence follows it after current
    /// speech, never before it or over it.
    static let afterTheReason: TimeInterval = 3

    /// Said, after "Starting: <title>", when Next or Previous pressed while
    /// the timer fades out ended it, as a Pause during a fade does: the
    /// listener did not ask to cancel it.
    static let fadeEndedByTheMove = "Sleep timer cancelled, because you moved to another book while it faded out."
}
