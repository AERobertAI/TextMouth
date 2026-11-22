import Foundation

/// What Next in Folder and Previous in Folder say (0.2.5), beyond the
/// sentences they share with the end of a book and the reading list:
/// "Starting: <title>" (`EndOfBookWording.starting(_:)`) for an item that
/// plays, and "Opening: <title>" (`ReadingListReaderWording.opening`) for one
/// that does not. Every sentence is whole in each case (FR34), so a
/// translation never glues a noun into it.
enum FolderNavigationWording {

    /// The name the library's top level goes by, where a folder's name is
    /// spoken: "Library, 743 books" after a move to the top.
    nonisolated static var libraryName: String {
        // Translators: The name spoken for the library's top level, the place that holds the folders and the books outside any folder, as in "Library, 743 books" after going to it.
        InterfaceText.line("common.library", "Library")
    }

    /// What the command says when no item lies the way it goes, or only
    /// finished ones do and the folder passes over them: the succession's own
    /// note, as the end of a book says it after "Finished: <title>.", with a
    /// full stop, for example "No more books in folder." or "Every book
    /// before it in the folder is finished."
    static func nothingThatWay(_ note: String) -> String {
        // Translators: VoiceOver announcement of Next in Folder or Previous in Folder when no item lies that way. %@ is a sentence without its full stop, such as "No more books in folder"; this adds the full stop.
        InterfaceText.line("common.valuePeriod", "\(note).")
    }

    /// What the command says when the item that way is a feed's episode (or
    /// article) whose file is not here, and it is downloaded first: "Downloading
    /// the next episode: <title>", or "the previous episode" going up.
    static func downloading(_ item: FeedItem, going direction: ReadingList.Direction) -> String {
        let title = item.title
        switch (direction, item.isArticle) {
        case (.down, false):
            // Translators: VoiceOver announcement of Next in Folder when the next item is a podcast episode that must be downloaded first. %@ is the episode's title.
            return InterfaceText.line("common.downloadingTheNextEpisodeValue", "Downloading the next episode: \(title)")
        case (.down, true):
            // Translators: VoiceOver announcement of Next in Folder when the next item is a feed's article that must be downloaded first. %@ is the article's title.
            return InterfaceText.line("common.downloadingTheNextArticleValue", "Downloading the next article: \(title)")
        case (.up, false):
            // Translators: VoiceOver announcement of Previous in Folder when the previous item is a podcast episode that must be downloaded first. %@ is the episode's title.
            return InterfaceText.line("folderNavigation.downloading.episode", "Downloading the previous episode: \(title)")
        case (.up, true):
            // Translators: VoiceOver announcement of Previous in Folder when the previous item is a feed's article that must be downloaded first. %@ is the article's title.
            return InterfaceText.line("folderNavigation.downloading.article", "Downloading the previous article: \(title)")
        }
    }

    /// What the command says when the episode's download failed: "The
    /// previous episode could not be downloaded. <reason>", the reason being
    /// the download's own sentence, kept whole. "The next article" for an
    /// article. When the book was playing, it was paused for the move, and
    /// the sentence says so, as the end of a book's does: "The next episode
    /// could not be downloaded, so playback stopped. <reason>".
    static func episodeNotDownloaded(
        reason: String,
        isArticle: Bool,
        going direction: ReadingList.Direction,
        playbackStopped: Bool
    ) -> String {
        SentenceWording.joined([
            notDownloadedSentence(isArticle: isArticle, going: direction, playbackStopped: playbackStopped),
            reason,
        ])
    }

    /// The first sentence of `episodeNotDownloaded`, whole, with its full
    /// stop: one string for each side, kind, and whether playback stopped.
    private static func notDownloadedSentence(
        isArticle: Bool,
        going direction: ReadingList.Direction,
        playbackStopped: Bool
    ) -> String {
        switch (direction, isArticle, playbackStopped) {
        case (.down, false, false):
            // Translators: First sentence of the VoiceOver announcement when Next in Folder could not download the next podcast episode. A sentence with the reason follows it.
            return InterfaceText.line("folderNavigation.nextEpisodeFailed", "The next episode could not be downloaded.")
        case (.down, false, true):
            // Translators: First sentence of the VoiceOver announcement when Next in Folder could not download the next podcast episode while a book was playing, so playback was paused. A sentence with the reason follows it.
            return InterfaceText.line("folderNavigation.nextEpisodeFailedStop", "The next episode could not be downloaded, so playback stopped.")
        case (.down, true, false):
            // Translators: First sentence of the VoiceOver announcement when Next in Folder could not download the next feed article. A sentence with the reason follows it.
            return InterfaceText.line("folderNavigation.nextArticleFailed", "The next article could not be downloaded.")
        case (.down, true, true):
            // Translators: First sentence of the VoiceOver announcement when Next in Folder could not download the next feed article while a book was playing, so playback was paused. A sentence with the reason follows it.
            return InterfaceText.line("folderNavigation.nextArticleFailedStop", "The next article could not be downloaded, so playback stopped.")
        case (.up, false, false):
            // Translators: First sentence of the VoiceOver announcement when Previous in Folder could not download the previous podcast episode. A sentence with the reason follows it.
            return InterfaceText.line("folderNavigation.previousEpisodeFailed", "The previous episode could not be downloaded.")
        case (.up, false, true):
            // Translators: First sentence of the VoiceOver announcement when Previous in Folder could not download the previous podcast episode while a book was playing, so playback was paused. A sentence with the reason follows it.
            return InterfaceText.line("folderNavigation.previousEpisodeFailedStop", "The previous episode could not be downloaded, so playback stopped.")
        case (.up, true, false):
            // Translators: First sentence of the VoiceOver announcement when Previous in Folder could not download the previous feed article. A sentence with the reason follows it.
            return InterfaceText.line("folderNavigation.previousArticleFailed", "The previous article could not be downloaded.")
        case (.up, true, true):
            // Translators: First sentence of the VoiceOver announcement when Previous in Folder could not download the previous feed article while a book was playing, so playback was paused. A sentence with the reason follows it.
            return InterfaceText.line("folderNavigation.previousArticleFailedStop", "The previous article could not be downloaded, so playback stopped.")
        }
    }

    /// What the command says when the listener cancelled the episode's
    /// download: "Download of the previous episode cancelled." and, when the
    /// book was playing, "Download of the next episode cancelled, so
    /// playback stopped."
    static func downloadCancelled(
        isArticle: Bool,
        going direction: ReadingList.Direction,
        playbackStopped: Bool
    ) -> String {
        switch (direction, isArticle, playbackStopped) {
        case (.down, false, false):
            // Translators: VoiceOver announcement when the listener cancelled the download of the next podcast episode that Next in Folder started.
            return InterfaceText.line("folderNavigation.nextEpisodeCancelled", "Download of the next episode cancelled.")
        case (.down, false, true):
            // Translators: VoiceOver announcement when the listener cancelled the download of the next podcast episode that Next in Folder started, while a book was playing, so playback was paused.
            return InterfaceText.line("folderNavigation.nextEpisodeCancelledStop", "Download of the next episode cancelled, so playback stopped.")
        case (.down, true, false):
            // Translators: VoiceOver announcement when the listener cancelled the download of the next feed article that Next in Folder started.
            return InterfaceText.line("folderNavigation.nextArticleCancelled", "Download of the next article cancelled.")
        case (.down, true, true):
            // Translators: VoiceOver announcement when the listener cancelled the download of the next feed article that Next in Folder started, while a book was playing, so playback was paused.
            return InterfaceText.line("folderNavigation.nextArticleCancelledStop", "Download of the next article cancelled, so playback stopped.")
        case (.up, false, false):
            // Translators: VoiceOver announcement when the listener cancelled the download of the previous podcast episode that Previous in Folder started.
            return InterfaceText.line("folderNavigation.previousEpisodeCancelled", "Download of the previous episode cancelled.")
        case (.up, false, true):
            // Translators: VoiceOver announcement when the listener cancelled the download of the previous podcast episode that Previous in Folder started, while a book was playing, so playback was paused.
            return InterfaceText.line("folderNavigation.previousEpisodeCancelledStop", "Download of the previous episode cancelled, so playback stopped.")
        case (.up, true, false):
            // Translators: VoiceOver announcement when the listener cancelled the download of the previous feed article that Previous in Folder started.
            return InterfaceText.line("folderNavigation.previousArticleCancelled", "Download of the previous article cancelled.")
        case (.up, true, true):
            // Translators: VoiceOver announcement when the listener cancelled the download of the previous feed article that Previous in Folder started, while a book was playing, so playback was paused.
            return InterfaceText.line("folderNavigation.previousArticleCancelledStop", "Download of the previous article cancelled, so playback stopped.")
        }
    }
}
