import Foundation

/// Coming back the next day (spec: "Coming back the next day"): at the app's
/// first activation, the book open when it last ended is opened again, paused at
/// its place, with its reader's screen pushed only if that screen was showing as
/// the app left, and VoiceOver then says the book's title with low priority,
/// after Play, where the reader's screen puts focus as it arrives
/// (`PhoneFocusPolicy`). The crash guard's sentence is said instead when the app
/// ended while opening a book. A file opened from another app at launch wins
/// over reopening.
///
/// The decision is the session's (`PhoneSession.takeReopeningAtLaunch`); this
/// acts on it, so the Mac's test host tests both. The root view's
/// `.phoneReopening` modifier calls it, once for the process.
extension PhoneLifeCycle {
    /// What reopening at launch did, for the screen to finish: whether the
    /// reader's screen was pushed, and what VoiceOver says, with low priority.
    struct LaunchReopened: Equatable, Sendable {
        /// Whether the reader's screen was pushed over the Library.
        let showsReader: Bool
        /// What VoiceOver says with low priority, `wordsDelay` seconds later:
        /// the book's title, or the crash guard's sentence; nil for nothing.
        let lowPriorityWords: String?

        /// Nothing reopened, and nothing to say.
        static let nothing = LaunchReopened(showsReader: false, lowPriorityWords: nil)
    }

    /// How long after reopening the words wait, in seconds: past the reader
    /// screen's first focus post (`PhoneFocusPolicy.screenChangedDelay`), so
    /// that VoiceOver is speaking Play when they are posted, and a low-priority
    /// announcement, which UIKit's header says is "queued and spoken when other
    /// speech utterances have completed", follows it rather than goes first.
    nonisolated static let wordsDelay: TimeInterval = 0.6

    /// Opens again the book open when the app last ended, as the session
    /// decides at launch, and says what to say.
    ///
    /// - A book whose reader's screen was showing opens paused at its place,
    ///   from the Reading List if it was read from there, and its screen is
    ///   pushed over the Library's top; its title is then said.
    /// - A book left with the Library showing is not opened: the Library opens,
    ///   with the book in its Continue row (`PhoneSession.bookInReach`), as the
    ///   spec's question 13 recommends.
    /// - A reader already open, as when a Play from the lock screen woke the app
    ///   before its screen came, is left as it is, as a file opened at launch
    ///   is: nothing is opened over it.
    /// - After an end while opening a book, that book is not opened, and the
    ///   crash guard's sentence is said.
    ///
    /// - Parameters:
    ///   - model: The app's model, whose session opens the book and whose path
    ///     shows the reader.
    ///   - readingListRequests: Where a book read from the Reading List asks to
    ///     be read from it again; the readers' own store unless a test gives one.
    func reopenAtLaunch(
        in model: PhoneAppModel,
        readingListRequests: ReadingListOpenRequests = .shared
    ) -> LaunchReopened {
        let session = model.session
        let aReaderIsOpen = session.reader != nil || session.listeningReader != nil
        switch session.takeReopeningAtLaunch(fileOpened: filesOpenedAtLaunch || aReaderIsOpen) {
        case .nothing:
            return .nothing
        case .closedWhileOpening(let sentence):
            DiagnosticLog.event(.app, "PHONE_REOPEN_REFUSED: the app ended while opening a book")
            return LaunchReopened(showsReader: false, lowPriorityWords: sentence)
        case .reopen(let reopening):
            guard reopening.showsReaderScreen else {
                DiagnosticLog.event(.app, "PHONE_REOPEN_LIBRARY: the Library was showing; the book waits in Continue")
                return .nothing
            }
            if reopening.readFromReadingList {
                readingListRequests.request(for: reopening.book.id)
            }
            guard session.open(reopening.book) != nil else { return .nothing }
            model.showReader()
            DiagnosticLog.event(.app, "PHONE_REOPEN_READER: \(reopening.book.title)")
            return LaunchReopened(showsReader: true, lowPriorityWords: reopening.book.title)
        }
    }
}

extension Notification.Name {
    /// Posted on the main thread as the iPhone app comes back toward the screen
    /// (spec: "Coming back the next day"), for Book content to show the place
    /// as it is now rather than wait for its next refresh. The life cycle posts
    /// it; Book content's view observes it while it exists.
    static let phoneBookContentShouldRefresh = Notification.Name("TextMouth.phoneBookContentShouldRefresh")
}
