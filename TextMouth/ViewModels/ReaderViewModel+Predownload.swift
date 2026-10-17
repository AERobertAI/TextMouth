import Foundation

/// The download of a feed's next episode before this one ends (FR19, task C):
/// when the episode playing has little left and listening would go on to
/// another episode whose file is not here, the reader asks for that file
/// now, so the episode is ready when this one ends and the listener does not
/// wait for it (or hear "Downloading the next episode", task B3's fallback).
extension ReaderViewModel {

    /// Downloads the episode that follows this one if it is due: the time
    /// left is within `predownloadLeadTime`, listening would go on to another
    /// episode, and that episode's file is not here and not being fetched.
    ///
    /// Called about once a second while the position moves
    /// (`publishLivePosition(now:)`), so every guard is ordered cheapest
    /// first and the one search of the library runs at most once per reader
    /// (`hasAskedForPredownload`). The download is the listener's
    /// (`FeedCenter.download(_:of:)`), so the newest-N rule never removes it.
    func predownloadNextEpisodeIfDue() {
        // Cheap flags first: a closed reader, one already asked, content
        // not loaded, or nothing playing has nothing to download for.
        guard !hasClosed, !hasAskedForPredownload, content != nil, isPlaybackUnderWay else { return }
        // Only a feed's episode has a next episode to fetch. A book read
        // from the reading list goes on to a book of the library, always here.
        guard book.feedLink != nil, !isOpenedFromReadingList else { return }
        // The rule must go on to another book, and the feed must allow the
        // early download (Feed Info's "Download the next episode").
        let rule = endOfBookRule
        guard rule.behavior == .continueNext, rule.predownloadsNext else { return }
        // Not yet within the lead time of the end (this also leaves out a
        // book with nothing left, which ends by itself).
        let remaining = timeRemaining
        guard remaining > 0, remaining <= predownloadLeadTime else { return }

        // Due. Whatever the search finds (a book already here, or nothing
        // after this episode), it need not be run again by this reader.
        hasAskedForPredownload = true
        let succession = libraryViewModel.succession(
            after: book,
            going: rule.direction,
            skippingFinished: rule.skipsFinished
        )
        // Only an episode whose file is not here needs fetching, and not one
        // already downloading: that request stands. One the newest-N rule put
        // off (it waits for a network with data limits, or for room) is
        // fetched all the same: this listener's ask takes its place.
        guard case .episodeToDownload(let feedID, let item) = succession, !item.state.isDownloading else { return }

        DiagnosticLog.event(.feeds, "FEED_PREDOWNLOAD: \(item.title) before \(book.title) ends")
        libraryViewModel.feeds.download(item.id, of: feedID)
    }
}
