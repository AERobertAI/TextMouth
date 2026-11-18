import Foundation

/// What a reader says as its book ends (`ReaderViewModel.handleEndOfBook()`),
/// in one place, so every way a book can end words what they share alike:
/// "Starting: <title>" for the book that follows, "Restarting: <title>" for
/// a book that loops, and "Finished: <title>" followed by why nothing
/// follows, each reason a sentence of its own. The book's own end-of-book
/// behavior and the reading list's (FR09) both speak through it.
///
/// Every text is localized (FR35): each is a computed property or a function
/// that reads the String Catalog when it is asked, so nothing keeps one
/// language's words, and each carries a comment for its translators.
enum EndOfBookWording {

    // MARK: - What Follows

    /// What VoiceOver hears as the book that follows is about to start:
    /// "Starting: <title>".
    static func starting(_ title: String) -> String {
        String(localized: "Starting: \(title)",
               comment: "VoiceOver announcement as the next book starts playing after one ends. %@ is the next book's title.")
    }

    /// What VoiceOver hears as a book that loops starts again:
    /// "Restarting: <title>".
    static func restarting(_ title: String) -> String {
        String(localized: "Restarting: \(title)",
               comment: "VoiceOver announcement as a book set to loop starts again from its beginning. %@ is the book's title.")
    }

    /// What VoiceOver hears as Play starts a finished book over from its
    /// beginning, its end-of-book choice "Stop, and Play Starts Over" (TODO
    /// P07): "Starting again: <title>", before the book plays, so the
    /// listener knows the place moved.
    static func startingAgain(_ title: String) -> String {
        String(localized: "Starting again: \(title)",
               comment: "VoiceOver announcement as Play starts a finished book over from its beginning. %@ is the book's title.")
    }

    /// What VoiceOver hears when Play reaches a finished book whose next
    /// book has been asked for, and is opening, but does not play yet:
    /// "Still starting: <title>", as "Starting: <title>" said it, so that
    /// the press is heard.
    static func stillStarting(_ title: String) -> String {
        String(localized: "Still starting: \(title)",
               comment: "VoiceOver announcement when Play is pressed while the next book is still opening. %@ is the next book's title.")
    }

    // MARK: - Nothing Follows

    /// What VoiceOver hears when a book ends and nothing follows it:
    /// "Finished: <title>", then each of `notes`, then, when
    /// `sleepTimerExpired`, `sleepTimerExpiredNote`, each a sentence of its
    /// own: "Finished: Dune. No more books in folder. Sleep timer expired."
    /// With no note at all, it is "Finished: <title>" alone, with no full
    /// stop, as it has always been.
    ///
    /// The sentences are joined with a full stop and a space, as English and
    /// Spanish join sentences; a language that ends a sentence otherwise
    /// (Japanese, Chinese) needs the joining localized too, a later item.
    ///
    /// - Parameters:
    ///   - title: The finished book's title.
    ///   - notes: Why nothing follows, each a sentence without its full
    ///     stop, which this adds.
    ///   - sleepTimerExpired: Whether the reader's sleep timer stopped
    ///     playback where the book ended.
    static func finished(_ title: String, notes: [String] = [], sleepTimerExpired: Bool = false) -> String {
        let finished = String(localized: "Finished: \(title)",
                              comment: "VoiceOver announcement as a book ends with no book to follow it. %@ is the book's title. Sentences saying why may follow it.")
        let sentences = [finished] + notes + (sleepTimerExpired ? [sleepTimerExpiredNote] : [])
        let joined = sentences.joined(separator: ". ")
        return sentences.count > 1 ? joined + "." : joined
    }

    /// The reader's sleep timer stopped playback where the book ended.
    static var sleepTimerExpiredNote: String {
        String(localized: "Sleep timer expired",
               comment: "A sentence of the announcement as a book ends, after \"Finished: <title>.\": the sleep timer stopped playback there. Written without its full stop, which is added after it.")
    }

    /// The book that would follow was not started: the finished book's
    /// sleep timer could never pause it, so it would play on past the timer.
    static var nextBookNotStartedNote: String {
        String(localized: "Next book not started because of the sleep timer",
               comment: "A sentence of the announcement as a book ends, after \"Finished: <title>.\": the next book was not started, because the sleep timer would not stop it. Written without its full stop.")
    }

    /// A book that loops waits at its beginning: its reader's sleep timer
    /// stopped playback at its end.
    static var notRestartedNote: String {
        String(localized: "Not restarted because of the sleep timer",
               comment: "A sentence of the announcement as a book set to loop ends: it did not start again, because the sleep timer stopped it. Written without its full stop.")
    }

    /// No book follows the finished one in its folder.
    static var noMoreBooksInFolderNote: String {
        String(localized: "No more books in folder",
               comment: "A sentence of the announcement as a book ends, after \"Finished: <title>.\": its library folder has no book after it. Written without its full stop.")
    }

    /// Only finished books follow the finished one in its folder, and
    /// Continue to Next Book passes over them (REV14), as the reading list
    /// says of the finished books it passes over:
    /// "Finished: Dune. Every book after it in the folder is finished."
    static var onlyFinishedBooksInFolderNote: String {
        String(localized: "Every book after it in the folder is finished",
               comment: "A sentence of the announcement as a book ends, after \"Finished: <title>.\": every book after it in its library folder is finished, so none plays. Written without its full stop.")
    }

    /// The same note for the direction listening goes in: going down it is
    /// `onlyFinishedBooksInFolderNote`; going up, where a feed or folder
    /// that plays the book above looks, "Every book before it in the folder
    /// is finished". A feed's items say the same words.
    static func onlyFinishedBooksInFolderNote(going direction: ReadingList.Direction) -> String {
        switch direction {
        case .down:
            return onlyFinishedBooksInFolderNote
        case .up:
            return String(localized: "Every book before it in the folder is finished",
                          comment: "A sentence of the announcement as a book ends, in a folder or feed that plays the book above: every book before it is finished, so none plays. Written without its full stop.")
        }
    }

    /// The English the debug log writes for `noMoreBooksInFolderNote`, whatever
    /// the interface language is (the log stays English: see `BookSuccession`).
    static let noMoreBooksInFolderLogName = "no more books in folder" // l10n: no (the debug log's words)

    /// The English the debug log writes for `onlyFinishedBooksInFolderNote(going:)`.
    static func onlyFinishedBooksInFolderLogName(going direction: ReadingList.Direction) -> String {
        // l10n: no (the debug log's words)
        direction == .down ? "every book after it in the folder is finished" : "every book before it in the folder is finished"
    }

    // MARK: - An Episode That Must Be Downloaded

    /// What a feed's episode that ended says of the next one, whose file is
    /// not here (FR19): "Downloading the next episode: <title>", or "the
    /// next article" for an article. A sentence after "Finished: <title>."
    /// Each kind is a whole sentence of its own, so a language can word the
    /// noun as its sentence needs.
    static func downloadingNextNote(_ item: FeedItem) -> String {
        if item.isArticle {
            return String(localized: "Downloading the next article: \(item.title)",
                          comment: "A sentence of the announcement as a feed's article ends: the next article is being downloaded. %@ is that article's title.")
        }
        return String(localized: "Downloading the next episode: \(item.title)",
                      comment: "A sentence of the announcement as a feed's episode ends: the next episode is being downloaded. %@ is that episode's title.")
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
        if isArticle {
            return String(localized: "The next article could not be downloaded, so playback stopped. \(reason)",
                          comment: "VoiceOver announcement when the download of a feed's next article failed. %@ is the download's own sentence saying why.")
        }
        return String(localized: "The next episode could not be downloaded, so playback stopped. \(reason)",
                      comment: "VoiceOver announcement when the download of a feed's next episode failed. %@ is the download's own sentence saying why.")
    }

    /// What VoiceOver hears when the listener cancelled the download of the
    /// next episode (or article) the end was waiting for: the user's own
    /// words (question 19, October 16). One sentence for both kinds.
    static var nextEpisodeDownloadCancelled: String {
        String(localized: "Download cancelled, so playback stopped.",
               comment: "VoiceOver announcement when the listener cancelled the download of a feed's next episode or article, which playback was waiting for.")
    }

    /// Why a download the reader asked for did not start: the engine
    /// refused it, as it does while TextMouth quits or the feed is deleted.
    static var downloadNotStartedReason: String {
        String(localized: "TextMouth is not downloading right now.",
               comment: "Why the download of a feed's next episode did not start: the app is quitting or the feed is being deleted. Said after \"The next episode could not be downloaded, so playback stopped.\"")
    }

    /// "article" for an article, "episode" for any other item.
    static func kind(of item: FeedItem) -> String {
        kind(isArticle: item.isArticle)
    }

    /// "article" or "episode": a noun that `FolderNavigationWording` still
    /// puts inside its own English sentences. English until that area's
    /// sentences are made whole (FR34): a translated noun inside an English
    /// sentence read "Downloading the next episodio: ...".
    static func kind(isArticle: Bool) -> String {
        // l10n: no (inside FolderNavigationWording's English sentences until that area converts)
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
    static var finishedProgress: String {
        String(localized: "Finished",
               comment: "How far a finished book has got, shown and spoken in place of its percent: in the library's row, Speak Info, Where Am I?, and Copy Reading Position.")
    }

    // MARK: - The Choices

    /// What the Playback tab says, under its "When book ends" picker, of
    /// what Play does on a finished book with each choice that stops there
    /// (TODO P07), shown and read alike. The two choices are named as the
    /// picker shows them, so the caption and the picker agree in every
    /// language; the picker shows each choice's raw value until that setting
    /// gains a localized title, and then this takes the title too.
    static var playOnAFinishedBookCaption: String {
        String(localized: "With \"\(EndOfBookBehavior.stop.rawValue)\", Play on a finished book says it is finished; with \"\(EndOfBookBehavior.stopAndPlayStartsOver.rawValue)\", Play starts it again from the beginning.",
               comment: "Caption under the When book ends picker in Settings, Playback. %1$@ and %2$@ are the names of two of the picker's choices, as the picker shows them (Stop, and Stop, and Play Starts Over); Play is the reader's Play button.")
    }
}
