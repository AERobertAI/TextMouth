import Foundation

// MARK: - What the Library Shows of Feeds (FR03)

/// A feed's items counted as the library shows them (FR03).
struct FeedItemCounts: Equatable, Sendable {
    /// The items the library lists: every one not deleted.
    var listed = 0
    /// Those downloaded, whose books the library lists.
    var downloaded = 0
    /// Those waiting to download or downloading.
    var downloading = 0
    /// Those new: published since the subscription began, and neither
    /// played nor opened.
    var new = 0
    /// Those not played (an article: not read).
    var unplayed = 0
    /// What the items are called.
    var noun: FeedWording.ItemNoun = .episode
}

extension FeedCenter {
    /// Whether `item` of `feed` is new: published (or, undated, first seen)
    /// after the subscription began, so subscribing marks none of a feed's
    /// back catalog new, never played, and, when downloaded, never opened.
    func isNew(_ item: FeedItem, of feed: Feed) -> Bool {
        guard item.playedDate == nil, item.sortDate > feed.subscribedDate else { return false }
        if let bookID = state(of: item).bookID, let book = library?.feedBook(withID: bookID) {
            return book.lastOpened == nil
        }
        return true
    }

    /// The items of the feed `feedID` counted as the library shows them;
    /// none for a feed no longer subscribed.
    func counts(of feedID: UUID) -> FeedItemCounts {
        guard let record = store.record(of: feedID) else { return FeedItemCounts() }
        let items = record.listedItems
        var counts = FeedItemCounts(listed: items.count, noun: .of(items))
        for item in items {
            switch state(of: item) {
            case .downloaded:
                counts.downloaded += 1
            case .downloading:
                counts.downloading += 1
            case .notDownloaded, .failed:
                break
            }
            if isNew(item, of: record.feed) {
                counts.new += 1
            }
            if item.playedDate == nil {
                counts.unplayed += 1
            }
        }
        return counts
    }

    /// How the feed `feedID`'s last check reads now.
    func checkWording(of feedID: UUID, now: Date) -> FeedWording.Check {
        FeedWording.check(fetchState(of: feedID), isRefreshing: refreshingFeedIDs.contains(feedID), now: now)
    }

    /// What the summary bar of the feed `feedID`'s folder says of the feed.
    func folderSummary(of feedID: UUID, now: Date) -> FeedWording.FolderSummary {
        FeedWording.FolderSummary(counts: FeedWording.countsPhrase(counts(of: feedID)), check: checkWording(of: feedID, now: now))
    }

    /// The path of the feed `feed`'s folder, or nil when that folder is no
    /// longer in the library.
    func folderPath(of feed: Feed) -> String? {
        library?.feedFolderPath(forFolderID: feed.folderID)
    }
}

// MARK: - Entering a Feed's Folder

extension FolderNavigationHistory {
    /// What VoiceOver hears on entering the folder at `path`: its name and
    /// its books counted ("Fiction, 12 books"), or, for a feed's folder, its
    /// name, the note "Feed", and the feed's items counted ("Planet Money,
    /// Feed, 12 episodes, 3 downloaded, 2 new") (FR03).
    @MainActor
    static func announcement(for path: String, library: Library, feedFolders: LibraryFeedFolders) -> String {
        if !path.isEmpty,
           let folder = library.folders.first(where: { $0.fullPath == path }),
           let feedID = feedFolders.feedID(inFolder: folder.id) {
            return FeedWording.folderAnnouncement(name: folder.name, counts: feedFolders.center.counts(of: feedID))
        }
        return announcement(for: path, library: library)
    }
}

// MARK: - The Feeds Section

/// What one row of the Feeds section shows and says (FR03).
struct FeedRowContent: Equatable, Identifiable {
    /// The feed's ID.
    let id: UUID
    /// The feed's title.
    let title: String
    /// The path of the feed's folder, or nil when it is gone.
    let folderPath: String?
    /// The feed's items counted.
    let counts: FeedItemCounts
    /// The last check.
    let check: FeedWording.Check

    /// The items counted, as the row shows them.
    var countsText: String {
        FeedWording.countsPhrase(counts)
    }

    /// The row as VoiceOver speaks it, in one sentence.
    var label: String {
        FeedWording.feedRowLabel(title: title, counts: counts, check: check, folderMissing: folderPath == nil)
    }
}

/// Which feeds a Library window's Feeds section lists, and what each row
/// says (FR03).
///
/// The section shows where feeds are: at a folder holding feeds' folders,
/// at any depth, which makes the top of the library list every feed, and
/// in All Items, which lists every feed. A feed's own folder lists its
/// items rather than itself, and No Folder and Recent list no feeds. A feed
/// whose folder is gone shows at the top of the library and in All Items,
/// where it can still be found.
enum LibraryFeedsSectionRows {
    /// The feeds the Feeds section lists at `location`, by title.
    @MainActor
    static func feeds(at location: LibraryLocation, center: FeedCenter) -> [Feed] {
        switch location.category {
        case .allItems:
            return center.feeds
        case .folders:
            let base = location.folderPath
            return center.feeds.filter { feed in
                guard let path = center.folderPath(of: feed) else { return base.isEmpty }
                return base.isEmpty || path.hasPrefix(base + "/")
            }
        case .unopened, .recent:
            return []
        }
    }

    /// The rows of the Feeds section at `location`, in order.
    @MainActor
    static func rows(at location: LibraryLocation, center: FeedCenter, now: Date = Date()) -> [FeedRowContent] {
        feeds(at: location, center: center).map { feed in
            FeedRowContent(
                id: feed.id,
                title: feed.title,
                folderPath: center.folderPath(of: feed),
                counts: center.counts(of: feed.id),
                check: center.checkWording(of: feed.id, now: now)
            )
        }
    }
}

// MARK: - A Feed's Folder

/// What one row of a feed's item not downloaded shows and says (FR03): its
/// title, its state, its date, and its duration. A downloaded item is its
/// book's row instead, unless its book lives in another folder.
struct FeedItemRowContent: Equatable, Identifiable {
    /// The feed the item belongs to.
    let feedID: UUID
    /// The item's identity.
    let id: FeedItem.ID
    /// The item's title.
    let title: String
    /// Where its download stands.
    let state: FeedItemState
    /// Whether it is new.
    let isNew: Bool
    /// Whether it played to its end, or was marked played.
    let isPlayed: Bool
    /// Whether it is an article rather than an episode.
    let isArticle: Bool
    /// Its date, as its row shows and speaks it, when the feed gives one.
    let dateText: String?
    /// How long it plays, when the feed says.
    let duration: TimeInterval?

    /// The row as VoiceOver speaks it.
    var label: String {
        FeedWording.itemRowLabel(self)
    }

    /// The row's content for `item` of `feed` in `center`.
    @MainActor
    init(_ item: FeedItem, of feed: Feed, in center: FeedCenter) {
        feedID = feed.id
        id = item.id
        title = item.title
        state = center.state(of: item)
        isNew = center.isNew(item, of: feed)
        isPlayed = item.playedDate != nil
        isArticle = item.isArticle
        dateText = item.published.map { FeedWording.itemDate($0) }
        duration = item.duration
    }
}

/// One row of a feed's folder (FR03): an item's book, or an item not
/// downloaded.
enum FeedFolderEntry: Equatable, Identifiable {
    /// A downloaded item, as its book's row, with the commands of the item
    /// it came from, which its row offers beside the book's own.
    case book(Book, actions: [FeedItemAction])
    /// An item not downloaded, or downloaded into another folder.
    case item(FeedItemRowContent)

    /// The row's identity, unique in the folder: a book's ID, or an item's.
    var id: String {
        switch self {
        case .book(let book, _): return "book:" + book.id.uuidString
        case .item(let item): return "item:" + item.id
        }
    }
}

/// What a feed's folder lists (FR03): the feed's items newest first, each
/// downloaded one as its book, then the folder's other books, which came
/// from no item of the feed.
struct FeedFolderListing: Equatable {
    /// The feed's items, newest first.
    var entries: [FeedFolderEntry] = []
    /// The folder's books from no item of the feed, in the folder's order.
    var otherBooks: [Book] = []
    /// What the feed's items are called.
    var noun: FeedWording.ItemNoun = .episode

    /// The listing of the feed `feedID`'s folder in `center`, given the
    /// folder's books as the list shows them, narrowed by `search`
    /// (`shownBooks`), and every book of the folder (`folderBooks`). An item
    /// shows when its title or author contains the search, ignoring case, as
    /// a book does; a downloaded item shows as its book when the folder holds
    /// it, so the search narrows it as it narrows the book.
    @MainActor
    static func make(
        feedID: UUID,
        center: FeedCenter,
        shownBooks: [Book],
        folderBooks: [Book],
        search: String
    ) -> FeedFolderListing {
        guard let record = center.store.record(of: feedID) else {
            return FeedFolderListing(otherBooks: shownBooks)
        }
        let items = record.listedItems
        var listing = FeedFolderListing(noun: .of(items))
        let shownByID = Dictionary(shownBooks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let folderBookIDs = Set(folderBooks.map(\.id))
        let query = search.lowercased()
        var itemBookIDs = Set<UUID>()
        for item in items {
            let state = center.state(of: item)
            if let bookID = state.bookID {
                itemBookIDs.insert(bookID)
                if let book = shownByID[bookID] {
                    let actions = FeedItemAction.actions(
                        feedID: feedID,
                        itemID: item.id,
                        itemTitle: item.title,
                        state: state,
                        isPlayed: item.playedDate != nil,
                        isArticle: item.isArticle,
                        onBookRow: true
                    )
                    listing.entries.append(.book(book, actions: actions))
                    continue
                }
                // In this folder but narrowed out by the search.
                if folderBookIDs.contains(bookID) {
                    continue
                }
            }
            guard query.isEmpty || Self.matches(item, query: query) else { continue }
            listing.entries.append(.item(FeedItemRowContent(item, of: record.feed, in: center)))
        }
        listing.otherBooks = shownBooks.filter { !itemBookIDs.contains($0.id) }
        return listing
    }

    /// Whether `item`'s title or author contains `query`, already lower case.
    private static func matches(_ item: FeedItem, query: String) -> Bool {
        item.title.lowercased().contains(query) || (item.author?.lowercased().contains(query) ?? false)
    }
}
