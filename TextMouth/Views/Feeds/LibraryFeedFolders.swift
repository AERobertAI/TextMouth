import Combine
import Foundation

// MARK: - Which Folders Hold Feeds (FR03)

/// Which library folders hold feeds (FR03), as a Library window needs to
/// know them: a feed's folder is left out of the Folders list where the
/// Feeds section lists its feed (`folderRows(_:at:bookCount:)`), carries
/// the note "Feed" and its feed's counts in the Folders list and the
/// Folders rotor elsewhere, opens on its feed's items, and is no place for
/// another feed's folder.
///
/// It follows one feed engine and publishes only when a feed is subscribed,
/// unsubscribed, resubscribed (FR11, branch D), given another folder, or
/// deleted (FR14): never for a download's progress or a refresh, which
/// change the engine many times a minute. So the Library window observes
/// this rather than the engine, and only the views that show a feed's items
/// and counts redraw as they change; the window redraws as a feed is
/// unsubscribed or resubscribed, so its feed folders' rows offer Unsubscribe
/// or Resubscribe by the feed's state.
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
    /// The feeds the listener unsubscribed from (FR11, branch D).
    @Published private(set) var unsubscribedFeedIDs: Set<UUID>
    /// Hears the engine's records change.
    private var subscription: AnyCancellable?

    /// The folders holding the feeds `center` keeps, followed from now on.
    init(center: FeedCenter) {
        self.center = center
        let feeds = center.store.records.values.map(\.feed)
        feedIDsByFolderID = Self.feedIDsByFolderID(of: feeds)
        unsubscribedFeedIDs = Self.unsubscribedFeedIDs(of: feeds)
        // The records' publisher sends each new value before it is stored,
        // so the map and the set are made from the value sent, and only a
        // changed one is published.
        subscription = center.store.$records
            .map { records in
                let feeds = records.values.map(\.feed)
                return Shape(folders: Self.feedIDsByFolderID(of: feeds), unsubscribed: Self.unsubscribedFeedIDs(of: feeds))
            }
            .removeDuplicates()
            .sink { [weak self] shape in
                guard let self else { return }
                if self.feedIDsByFolderID != shape.folders {
                    self.feedIDsByFolderID = shape.folders
                }
                if self.unsubscribedFeedIDs != shape.unsubscribed {
                    self.unsubscribedFeedIDs = shape.unsubscribed
                }
            }
    }

    /// What this follows of the engine's records: the folders holding
    /// feeds, and the feeds unsubscribed from.
    private struct Shape: Equatable {
        let folders: [UUID: UUID]
        let unsubscribed: Set<UUID>
    }

    /// The feeds of `feeds` the listener unsubscribed from (FR11, branch D).
    nonisolated static func unsubscribedFeedIDs(of feeds: [Feed]) -> Set<UUID> {
        Set(feeds.filter { !$0.isSubscribed }.map(\.id))
    }

    /// The feed whose downloads go to the folder `folderID`, if any.
    func feedID(inFolder folderID: UUID) -> UUID? {
        feedIDsByFolderID[folderID]
    }

    /// Whether `folder` is a feed's folder.
    func holdsFeed(_ folder: BookFolder) -> Bool {
        feedIDsByFolderID[folder.id] != nil
    }

    /// How many feeds have their folders below `folder`, as the Feeds section
    /// lists them when that folder is shown (FR11): what a plain folder's
    /// row names beside its books, "Podcasts, 3 books, 2 feeds".
    func feedCount(below folder: BookFolder) -> Int {
        LibraryFeedsSectionRows.feeds(at: LibraryLocation(category: .folders, folderPath: folder.fullPath), center: center).count
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

// MARK: - The Folders Section and Its Rotor (October 7, 2026)

/// One entry of a Library window's Folders rotor (FR03): what VoiceOver
/// says for it, and the row it moves to.
struct FolderRotorEntry: Equatable, Identifiable {
    /// What the rotor says: a folder's row's label, "Fiction, 12 books", or,
    /// for a feed's folder, the feed counted as its row counts it, "Planet
    /// Money, Feed, 10 of 381 episodes listed".
    let label: String
    /// The ID of the row it moves to: the folder's own, or, for a feed's
    /// folder the Feeds section's row stands for, the feed's, which is that
    /// row's ID.
    let id: UUID
}

/// The Folders section's rows and the Folders rotor's entries at one
/// location of a Library window (FR03).
struct LibraryFolderRows: Equatable {
    /// The folders whose rows the Folders section shows, in order.
    var shown: [BookFolder] = []
    /// The Folders rotor's entries, one for each folder directly inside the
    /// location, in the folders' order, each naming a row the list shows.
    var rotorEntries: [FolderRotorEntry] = []
}

extension LibraryFeedFolders {
    /// The Folders section's rows and the Folders rotor's entries at
    /// `location`, of `subfolders`, the folders directly inside it, in
    /// order; a plain folder's entry counts the books `bookCount` finds in
    /// its tree.
    ///
    /// Only the Folders category shows folders: anywhere else there are
    /// none, and so no rotor entries either, which would name rows the list
    /// lacks. A feed's folder whose feed the Feeds section lists here is
    /// left out, since the feed's row stands for it, opening the folder and
    /// offering the feed's commands and the folder's, so the feed is listed
    /// once, as the user asked on October 7: "the feeds should probably
    /// just not have duplicate entries in the folders". Its rotor entry
    /// stays, moved to the feed's row and naming the feed as that row does,
    /// so the Folders rotor reaches every feed it reached before. A feed's
    /// folder the Feeds section does not list keeps its row, which counts
    /// the feed's items; a plain folder keeps its row whatever it holds, a
    /// feed's folder deeper down included. A feed's entry names the feed as
    /// its row shows it under `articles`, the Leading articles setting
    /// ("Digital Antiquarian, The" while sorting passes over articles);
    /// folders' names stay as written.
    func folderRows(
        _ subfolders: [BookFolder],
        at location: LibraryLocation,
        articles: LeadingArticles = .partOfTitle,
        bookCount: (BookFolder) -> Int
    ) -> LibraryFolderRows {
        guard location.category == .folders else { return LibraryFolderRows() }
        let listedFeedIDs = Set(LibraryFeedsSectionRows.feeds(at: location, center: center).map(\.id))
        var rows = LibraryFolderRows()
        for folder in subfolders {
            let heldFeedID = feedID(inFolder: folder.id)
            let feedCounts = heldFeedID.map { center.counts(of: $0) }
            if let heldFeedID, let feedCounts, listedFeedIDs.contains(heldFeedID),
               let feed = center.store.record(of: heldFeedID)?.feed {
                // The Feeds section's row stands for the folder, and the
                // entry names the feed as that row shows it.
                rows.rotorEntries.append(FolderRotorEntry(
                    label: FeedWording.folderAnnouncement(name: articles.shownTitle(feed.title, language: nil), counts: feedCounts),
                    id: heldFeedID
                ))
                continue
            }
            rows.shown.append(folder)
            rows.rotorEntries.append(FolderRotorEntry(
                label: FolderRow.accessibilityLabel(
                    name: folder.name,
                    bookCount: bookCount(folder),
                    feedCounts: feedCounts,
                    feedsBelow: feedCounts == nil ? feedCount(below: folder) : 0
                ),
                id: folder.id
            ))
        }
        return rows
    }
}
