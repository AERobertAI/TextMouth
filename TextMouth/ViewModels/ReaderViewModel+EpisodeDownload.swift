import Combine
import Foundation

/// Why a reader awaits a feed's episode that is being downloaded, which
/// decides what it speaks of the episode.
enum NextEpisodeCause: Equatable, Sendable {
    /// This book ended, and the episode is the next one (FR19): the end of a
    /// book's own sentences are spoken, and the wait ends once the book no
    /// longer rests finished.
    case endOfBook
    /// Next in Folder or Previous in Folder went to the episode (0.2.5),
    /// leaving this book where it is.
    /// - direction: Which way the command went, named in what is spoken.
    /// - wasPlaying: Whether this book was playing when the command was
    ///   pressed, so the episode plays once it arrives, and "playback
    ///   stopped" is said when it never does.
    /// - sleepTimerKeptItFromStarting: Whether this reader's sleep timer
    ///   was in effect at the press, so the episode only opens, and the
    ///   announcement says why.
    case folderMove(direction: ReadingList.Direction, wasPlaying: Bool, sleepTimerKeptItFromStarting: Bool)

    /// Whether this is the end of a book's.
    var isEndOfBook: Bool {
        if case .endOfBook = self { return true }
        return false
    }
}

/// The wait for a feed's next episode to download (FR19, task B3): when an
/// episode ends and the one that follows it is listed but its file is not
/// here, the reader asks for the download and hands listening over once the
/// episode arrives, or says why playback stopped when the download fails.
extension ReaderViewModel {

    /// Downloads `item` of the feed `feedID`, the episode that follows this
    /// finished one, and goes on with it when it arrives.
    ///
    /// The reader listens to the feed engine's events first, then asks for
    /// the download, so no event can pass unheard. A download of the item
    /// already waiting or running is not started twice
    /// (`FeedCenter.download(_:of:startingNext:)`), and the ask puts it
    /// ahead of the downloads queued before it. A new wait replaces an
    /// earlier one. The wait ends silently when the listener moves on, as
    /// another reader's taking the media controls does
    /// (`listenerHasMovedOn(_:)`).
    ///
    /// - Parameters:
    ///   - item: The episode (or article) to download.
    ///   - feedID: The feed it belongs to.
    ///   - start: Opens the book with the given ID, after the announcement
    ///     that it is starting, or opening (as for any next book).
    ///   - cause: Why the episode is awaited: this book ended, as at the end
    ///     of a book, or Next in Folder or Previous in Folder went to it
    ///     (`NextEpisodeCause`), which says what to speak of it.
    func waitForNextEpisode(
        _ item: FeedItem,
        of feedID: UUID,
        cause: NextEpisodeCause = .endOfBook,
        startingWith start: @escaping (UUID) -> Void
    ) {
        let feeds = libraryViewModel.feeds
        // Whoever owned the media controls as this episode ended. The wait
        // ends if another reader takes them (see `listenerHasMovedOn`).
        let wait = NextEpisodeWait(
            item: item, feedID: feedID, start: start, controlsOwner: nowPlayingService.activeOwnerID,
            cause: cause
        )
        nextEpisodeWait = feeds.events.sink { [weak self] event in
            self?.nextEpisodeEventArrived(event, during: wait)
        }
        // The listener waits for this episode, so it goes ahead of the
        // downloads queued before it (it opens nothing: the wait hands over).
        feeds.download(item.id, of: feedID, startingNext: true)

        // Right after the request, the item is downloading, waiting, or
        // (already) downloaded. Anything else means the engine refused it,
        // as it does while quitting or for a feed being deleted, and no
        // event will come.
        switch feeds.store.record(of: feedID)?.item(item.id)?.state {
        case .downloading, .waiting:
            return
        case .downloaded(let bookID):
            // Its file was here after all: no event will announce it.
            goOnWithNextEpisode(as: bookID, during: wait)
        default:
            nextEpisodeWait = nil
            DiagnosticLog.trace(.playback, "end of book: the engine did not start the download of the next episode")
            announceDownloadFailed(reason: EndOfBookWording.downloadNotStartedReason, during: wait)
        }
    }

    /// What a wait for the next episode needs to know, kept together so
    /// each step takes the one value.
    private struct NextEpisodeWait {
        /// The episode (or article) being downloaded.
        let item: FeedItem
        /// The feed it belongs to.
        let feedID: UUID
        /// Opens the book with the given ID to be played.
        let start: (UUID) -> Void
        /// The reader that owned TextMouth's media controls as the wait
        /// began: nil, this reader, or another one.
        let controlsOwner: UUID?
        /// Why the episode is awaited, which decides what is spoken of it.
        let cause: NextEpisodeCause
    }

    /// Says that the awaited episode could not be downloaded, in the words
    /// of the wait's cause: the end of a book's own, or Next in Folder's or
    /// Previous in Folder's, which name the direction and say that playback
    /// stopped only when something was playing.
    private func announceDownloadFailed(reason: String, during wait: NextEpisodeWait) {
        switch wait.cause {
        case .endOfBook:
            announceToVoiceOver(EndOfBookWording.nextEpisodeNotDownloaded(reason: reason, isArticle: wait.item.isArticle))
        case .folderMove(let direction, let wasPlaying, _):
            announceToVoiceOver(FolderNavigationWording.episodeNotDownloaded(
                reason: reason, isArticle: wait.item.isArticle, going: direction, playbackStopped: wasPlaying
            ))
        }
    }

    /// Says that the listener cancelled the awaited episode's download, as
    /// `announceDownloadFailed(reason:during:)` says that it failed.
    private func announceDownloadCancelled(during wait: NextEpisodeWait) {
        switch wait.cause {
        case .endOfBook:
            announceToVoiceOver(EndOfBookWording.nextEpisodeDownloadCancelled)
        case .folderMove(let direction, let wasPlaying, _):
            announceToVoiceOver(FolderNavigationWording.downloadCancelled(
                isArticle: wait.item.isArticle, going: direction, playbackStopped: wasPlaying
            ))
        }
    }

    /// Whether the listener has moved on from the finished book, so that the
    /// next episode must not take listening over, nor anything be said about
    /// its download: this reader has closed, has been played again (or
    /// plays), or another reader has taken the media controls since the wait
    /// began (it plays, or its window became the focused one). The controls
    /// returning to this reader, or staying with the reader that held them,
    /// is no move.
    private func listenerHasMovedOn(_ wait: NextEpisodeWait) -> Bool {
        guard !hasClosed, !isPlaybackUnderWay, hasFinishedBook || !wait.cause.isEndOfBook else { return true }
        guard let owner = nowPlayingService.activeOwnerID else { return false }
        return owner != wait.controlsOwner && owner != readerID
    }

    /// Acts on one event of the feed engine while this reader waits for
    /// `wait`'s episode: its arrival hands listening over, its failure or
    /// its cancelling is said. Events about other items or feeds, and
    /// other kinds of events, are none of this wait's business.
    private func nextEpisodeEventArrived(_ event: FeedEvent, during wait: NextEpisodeWait) {
        switch event {
        case .downloadFinished(let eventFeedID, let itemID, let bookID)
            where eventFeedID == wait.feedID && itemID == wait.item.id:
            goOnWithNextEpisode(as: bookID, during: wait)

        case .downloadFailed(let eventFeedID, let itemID, let reason)
            where eventFeedID == wait.feedID && itemID == wait.item.id:
            nextEpisodeWait = nil
            guard !listenerHasMovedOn(wait) else {
                DiagnosticLog.trace(.playback, "end of book: the next episode failed, but the listener had moved on")
                return
            }
            announceDownloadFailed(reason: reason, during: wait)

        case .downloadCancelled(let eventFeedID, let itemID)
            where eventFeedID == wait.feedID && itemID == wait.item.id:
            // The listener cancelled it (Cancel Download, the downloads
            // section's Cancel, or Delete Feed): nothing will arrive.
            nextEpisodeWait = nil
            guard !listenerHasMovedOn(wait) else {
                DiagnosticLog.trace(.playback, "end of book: the next episode's download was cancelled, but the listener had moved on")
                return
            }
            announceDownloadCancelled(during: wait)

        default:
            break
        }
    }

    /// Ends the wait, and, when the listener has not moved on, hands
    /// listening over to the wait's episode, now the book `bookID`, exactly
    /// as it hands over to any next book ("Starting: <title>"). A listener
    /// who has moved on (played the book again, closed the window, or
    /// started another book) is left alone, and a sleep timer of this
    /// reader's, started meanwhile, keeps the episode from starting, as it
    /// would at the end.
    private func goOnWithNextEpisode(as bookID: UUID, during wait: NextEpisodeWait) {
        nextEpisodeWait = nil
        guard !listenerHasMovedOn(wait) else {
            DiagnosticLog.trace(.playback, "end of book: the next episode arrived, but the listener had moved on")
            return
        }
        // Next in Folder or Previous in Folder went to the episode. It plays
        // when the book was playing and no sleep timer keeps it from
        // starting, as at the press or since (a timer of this reader's, set
        // meanwhile, would be played past); any other episode only opens:
        // "Opening: <title>", and then its window (`openInFolder(_:)`, which
        // only those commands wait for), as a book that is here opens.
        if case .folderMove(_, let wasPlaying, let timerKeptItFromStarting) = wait.cause {
            let timerKeepsItNow = timerKeptItFromStarting || (wasPlaying && sleepTimerEndsListeningHere)
            guard wasPlaying, !timerKeepsItNow else {
                announceToVoiceOver(ReadingListReaderWording.opening(
                    wait.item.title, sleepTimerKeptItFromStarting: timerKeepsItNow
                ))
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.continueToNextBookDelay) {
                    self.openInFolder(bookID)
                }
                return
            }
            handOverToNextBook(to: bookID, titled: wait.item.title) {
                wait.start(bookID)
            }
            return
        }
        // The listener started a sleep timer after the wait began: the next
        // episode would play on past it, and the timer can pause only this
        // reader. Say what the end says when the timer is already in effect.
        guard !sleepTimerEndsListeningHere else {
            saySleepTimerKeepsNextBookFromStarting(in: "its feed", saying: announceToVoiceOver(_:))
            return
        }
        handOverToNextBook(to: bookID, titled: wait.item.title) {
            wait.start(bookID)
        }
    }
}
