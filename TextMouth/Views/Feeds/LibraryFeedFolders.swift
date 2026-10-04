import Combine
import Foundation

// MARK: - Which Folders Hold Feeds (FR03)

/// Which library folders hold feeds (FR03), as a Library window needs to
/// know them: a feed's folder carries the note "Feed" in the Folders list
/// and the Folders rotor, opens on its feed's items, and is no place for
/// another feed's folder.
///
/// It follows one feed engine and publishes only when a feed is subscribed,
/// unsubscribed, or given another folder: never for a download's progress
/// or a refresh, which change the engine many times a minute. So the
/// Library window observes this rather than the engine, and only the views
/// that show a feed's items and counts redraw as they change.
@MainActor
final class LibraryFeedFolders: ObservableObject {
    /// The app's, following the app's feed engine.
    static let shared = LibraryFeedFolders(center: .shared)

    /// The feed engine followed.
    let center: FeedCenter
    /// The feed whose downloads go to each folder, by folder ID. Should two
    /// feeds share one folder, the first by title holds it, as
    /// `FeedCenter.feed(inFolder:)` finds it.
    @Published private(set) var feedIDsByFolderID: [UUID: UUID]
    /// Hears the engine's records change.
    private var subscription: AnyCancellable?

    /// The folders holding the feeds `center` keeps, followed from now on.
    init(center: FeedCenter) {
        self.center = center
        feedIDsByFolderID = Self.feedIDsByFolderID(of: center.store.records.values.map(\.feed))
        // The records' publisher sends each new value before it is stored,
        // so the map is made from the value sent, and only a changed map is
        // published.
        subscription = center.store.$records
            .map { records in Self.feedIDsByFolderID(of: records.values.map(\.feed)) }
            .removeDuplicates()
            .sink { [weak self] map in
                guard let self, self.feedIDsByFolderID != map else { return }
                self.feedIDsByFolderID = map
            }
    }

    /// The feed whose downloads go to the folder `folderID`, if any.
    func feedID(inFolder folderID: UUID) -> UUID? {
        feedIDsByFolderID[folderID]
    }

    /// Whether `folder` is a feed's folder.
    func holdsFeed(_ folder: BookFolder) -> Bool {
        feedIDsByFolderID[folder.id] != nil
    }

    /// The feed of each folder holding one, by folder ID: of feeds sharing
    /// a folder, the first by title, as the store orders its feeds, and of
    /// two with one title, the one whose ID sorts first, so the choice never
    /// depends on the order the records happen to be in.
    nonisolated static func feedIDsByFolderID(of feeds: [Feed]) -> [UUID: UUID] {
        let byTitle = feeds.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
        var map: [UUID: UUID] = [:]
        for feed in byTitle where map[feed.folderID] == nil {
            map[feed.folderID] = feed.id
        }
        return map
    }
}
