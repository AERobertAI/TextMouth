import Combine
import Foundation

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
    /// (`FeedCenter.download(_:of:)`). A new wait replaces an earlier one.
    ///
    /// - Parameters:
    ///   - item: The episode (or article) to download.
    ///   - feedID: The feed it belongs to.
    ///   - start: Opens the book with the given ID to be played, after the
    ///     announcement that it is starting (as for any next book).
    func waitForNextEpisode(
        _ item: FeedItem,
        of feedID: UUID,
        startingWith start: @escaping (UUID) -> Void
    ) {
        let feeds = libraryViewModel.feeds
        nextEpisodeWait = feeds.events.sink { [weak self] event in
            self?.nextEpisodeEventArrived(event, for: item, of: feedID, startingWith: start)
        }
        feeds.download(item.id, of: feedID)

        // Right after the request, the item is downloading, waiting, or
        // (already) downloaded. Anything else means the engine refused it,
        // as it does while quitting or for a feed being deleted, and no
        // event will come.
        switch feeds.store.record(of: feedID)?.item(item.id)?.state {
        case .downloading, .waiting:
            return
        case .downloaded(let bookID):
            // Its file was here after all: no event will announce it.
            goOnWithNextEpisode(item, as: bookID, startingWith: start)
        default:
            nextEpisodeWait = nil
            DiagnosticLog.trace(.playback, "end of book: the engine did not start the download of the next episode")
            announceToVoiceOver(EndOfBookWording.nextEpisodeNotDownloaded(
                reason: EndOfBookWording.downloadNotStartedReason, isArticle: item.isArticle
            ))
        }
    }

    /// Whether this reader still rests at its finished book's end, so that
    /// the next episode may take listening over: it has not closed, has not
    /// been played again, and nothing plays.
    private var restsFinishedAwaitingTheNextEpisode: Bool {
        hasFinishedBook && !hasClosed && !isPlaybackUnderWay
    }

    /// Acts on one event of the feed engine while this reader waits for the
    /// episode `item` of the feed `feedID`: its arrival hands listening
    /// over, its failure is said. Events about other items or feeds, and
    /// other kinds of events, are none of this wait's business.
    private func nextEpisodeEventArrived(
        _ event: FeedEvent,
        for item: FeedItem,
        of feedID: UUID,
        startingWith start: @escaping (UUID) -> Void
    ) {
        switch event {
        case .downloadFinished(let eventFeedID, let itemID, let bookID)
            where eventFeedID == feedID && itemID == item.id:
            goOnWithNextEpisode(item, as: bookID, startingWith: start)

        case .downloadFailed(let eventFeedID, let itemID, let reason)
            where eventFeedID == feedID && itemID == item.id:
            nextEpisodeWait = nil
            guard restsFinishedAwaitingTheNextEpisode else { return }
            announceToVoiceOver(EndOfBookWording.nextEpisodeNotDownloaded(reason: reason, isArticle: item.isArticle))

        default:
            break
        }
    }

    /// Ends the wait, and, when this reader still rests finished, hands
    /// listening over to the episode `item`, now the book `bookID`, exactly
    /// as it hands over to any next book ("Starting: <title>"). A listener
    /// who has moved on (played the book again, or closed the window) is
    /// left alone, and a sleep timer of this reader's, started meanwhile,
    /// keeps the episode from starting, as it would at the end.
    private func goOnWithNextEpisode(
        _ item: FeedItem,
        as bookID: UUID,
        startingWith start: @escaping (UUID) -> Void
    ) {
        nextEpisodeWait = nil
        guard restsFinishedAwaitingTheNextEpisode else {
            DiagnosticLog.trace(.playback, "end of book: the next episode arrived, but the listener had moved on")
            return
        }
        // The listener started a sleep timer after the wait began: the next
        // episode would play on past it, and the timer can pause only this
        // reader. Say what the end says when the timer is already in effect.
        guard !sleepTimerEndsListeningHere else {
            saySleepTimerKeepsNextBookFromStarting(in: "its feed", saying: announceToVoiceOver(_:))
            return
        }
        handOverToNextBook(to: bookID, titled: item.title) {
            start(bookID)
        }
    }
}
