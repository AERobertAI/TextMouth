import Combine
import Foundation

// MARK: - The Feed Downloads' Progress (FR10)

/// What the library model does for the feed downloads' progress, FR10's
/// feed half: its Speak Download Progress and its Cancel. The progress
/// itself is the feed engine's (`FeedDownloadManager.progress`), which only
/// the Library windows' feed downloads section observes, so this model is
/// never republished for it.
extension LibraryViewModel {
    /// The progress of the feed downloads of this library's feed engine,
    /// which the Library window's feed downloads section shows.
    var feedDownloadProgress: FeedDownloadProgress {
        feeds.downloads.progress
    }

    /// Starts answering Speak Download Progress, from the Library menu or
    /// the key the user gave it, from any window. The library starts it
    /// once, with its other observers.
    func observeDownloadProgressRequests() {
        NotificationCenter.default.publisher(for: .speakDownloadProgress)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.speakDownloadProgress() }
            .store(in: &cancellables)
    }

    /// Has VoiceOver speak how the feed downloads under way have got, every
    /// line the feed downloads section shows, or that none is under way,
    /// with the downloads waiting for a network or for room, wherever the
    /// user is, without finding the section.
    func speakDownloadProgress() {
        VoiceOverAnnouncer.announce(feeds.downloads.spokenProgress())
    }

    /// Stops the feed downloads under way and waiting to start, as the feed
    /// downloads section's Cancel does: VoiceOver hears what stopped, and
    /// the newest-N rule never starts them again by itself
    /// (`FeedDownloadManager.cancelEveryDownload()`).
    func cancelFeedDownloads() {
        feeds.downloads.cancelEveryDownload()
    }
}
