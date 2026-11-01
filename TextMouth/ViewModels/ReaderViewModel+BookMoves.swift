import Foundation

// MARK: - Moving to Another Book on a Command

/// Which way a command moves to another book, so the one step they share
/// asks for the book the way that route does.
enum BookMoveRoute: Equatable, Sendable {
    /// Next in Reading List and Previous in Reading List (FR09): the book is
    /// read from the list, and the window follows the global setting.
    case readingList
    /// Next in Folder and Previous in Folder (0.2.5): the book is opened as
    /// any book of its folder, and the window follows the feed's or folder's
    /// own choice, else the global one.
    case folder
}

/// What a command found when it began to move from this book: whether the
/// book was playing, and whether this reader's sleep timer keeps the next
/// book from starting.
struct BookMoveStart: Equatable, Sendable {
    /// Whether this book was playing: speech or audio under way, or paused
    /// only while a Where Am I announcement speaks, or until the end sound
    /// of one that ended has played (`ReaderViewModel.whereAmIWillPlayBook`).
    let wasPlaying: Bool
    /// Whether this reader's sleep timer is in effect while the book was
    /// playing, so the next book could never be paused by it and is not
    /// started.
    let sleepTimerKeptItFromStarting: Bool

    /// Whether the book moved to plays: this one was playing, and no sleep
    /// timer keeps it from starting.
    var plays: Bool { wasPlaying && !sleepTimerKeptItFromStarting }
}

extension ReaderViewModel {

    /// Begins a move from this book to another, which the reading list's and
    /// the folder's Next and Previous share: reads whether this book was
    /// playing and whether its sleep timer keeps the next one from starting,
    /// and pauses it.
    ///
    /// A playing book pauses where it is, without the pause sound, since the
    /// book that starts makes its own; a Where Am I announcement speaking
    /// ends with that pause, without resuming its book, even for a book that
    /// was not playing, whose announcement would otherwise speak over the one
    /// moved to.
    func beginMoveToAnotherBook() -> BookMoveStart {
        let wasPlaying = isPlaybackUnderWay || whereAmIWillPlayBook
        let start = BookMoveStart(
            wasPlaying: wasPlaying,
            sleepTimerKeptItFromStarting: wasPlaying && sleepTimerEndsListeningHere
        )
        if wasPlaying || isWhereAmIUnderWay {
            pause(playingPauseSound: false)
        }
        return start
    }

    /// Says that the book `bookID`, titled `title`, is starting or opening,
    /// and asks for it once VoiceOver has begun saying so: "Starting:
    /// <title>" for a book that plays (`EndOfBookWording.starting(_:)`),
    /// "Opening: <title>" for one that does not, with why when the sleep
    /// timer kept it from starting
    /// (`ReadingListReaderWording.opening(_:sleepTimerKeptItFromStarting:)`).
    /// It is asked for after `continueToNextBookDelay`, as Continue to Next
    /// Book asks for its book, so the announcement is not cut off by the
    /// next book's window or by the switch of this one.
    func announceMove(
        to bookID: UUID,
        titled title: String,
        start: BookMoveStart,
        through route: BookMoveRoute
    ) {
        announceToVoiceOver(
            start.plays
                ? EndOfBookWording.starting(title)
                : ReadingListReaderWording.opening(title, sleepTimerKeptItFromStarting: start.sleepTimerKeptItFromStarting)
        )
        let plays = start.plays
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.continueToNextBookDelay) {
            self.askForBook(bookID, plays: plays, through: route)
        }
    }

    /// Asks for the book `bookID`, which a command moved to, as `route` asks:
    /// to be played, as a book that ends continues to the next one
    /// (`continueThroughReadingList(to:)`, `continueToNextBook(_:under:)`), or
    /// only opened (`openFromReadingList(_:)`, `openInFolder(_:)`). Also what
    /// an episode that was downloaded first is asked for with.
    func askForBook(_ bookID: UUID, plays: Bool, through route: BookMoveRoute) {
        switch (route, plays) {
        case (.readingList, true): continueThroughReadingList(to: bookID)
        case (.readingList, false): openFromReadingList(bookID)
        case (.folder, true): continueToNextBook(bookID, under: folderMoveWindowChoice)
        case (.folder, false): openInFolder(bookID)
        }
    }
}
