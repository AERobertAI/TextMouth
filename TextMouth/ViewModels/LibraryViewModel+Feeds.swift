import Foundation

/// The library's side of the podcast and article reader (FR03): the feed
/// engine starts with the library, and finds a feed's folder by its ID.
extension LibraryViewModel: FeedLibraryHost {
    /// The feed engine this library works with: the app's.
    var feeds: FeedCenter {
        FeedCenter.shared
    }

    /// Starts the feed engine with this library, once the library has
    /// loaded: it reads the feeds' records off the main thread and, outside
    /// a process hosting tests, refreshes every feed when the settings say
    /// to. Returns at once, so nothing the engine does holds the library
    /// back.
    func startFeeds() {
        feeds.start(library: self)
    }

    // MARK: - FeedLibraryHost

    /// The path of the library folder `folderID`, wherever it has been
    /// renamed or moved to; nil when the folder is gone.
    func feedFolderPath(forFolderID folderID: UUID) -> String? {
        library.folders.first { $0.id == folderID }?.fullPath
    }
}
