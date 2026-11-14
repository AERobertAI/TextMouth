import Foundation

// MARK: - What the Library Shows of Feeds (FR03)

/// A feed's items counted as the library shows them (FR03).
struct FeedItemCounts: Equatable, Sendable {
    /// The items the library lists: every one not deleted.
    var listed = 0
    /// How many entries the feed itself lists (`Feed.entryTotal`), of
    /// which the library lists `listed`; nil until a check has read the
    /// feed since TextMouth began recording its size.
    var total: FeedEntryTotal?
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
    /// Whether the listener is subscribed to the feed (FR11, branch D): the
    /// counts of an unsubscribed one are said with the note "unsubscribed"
    /// after "Feed", wherever its row, its folder's row, its rotor entry,
    /// entering its folder, and Speak Info name it.
    var isSubscribed = true
    /// How many packages the feed kept for downloads removed earlier, with
    /// the listener's places and bookmarks, Unsubscribe would delete now
    /// (`FeedCenter.keptRowsUnsubscribeDeletes(of:)`): Unsubscribe asks
    /// first only when there are some (FR14), its title ending "…" then.
    var keptForRemovedDownloads = 0
}

extension FeedCenter {
    /// Whether `item` of `feed` is new: published (or, undated, first seen)
    /// after the subscription began, so subscribing marks none of a feed's
    /// back catalog new, never played, and never opened, whether its file is
    /// here or its row was kept after its file went (FR11), and not moved
    /// into the library, where it is the listener's own book (FR11, branch
    /// D). Its row is found by the item's identity, in one step.
    func isNew(_ item: FeedItem, of feed: Feed) -> Bool {
        guard item.playedDate == nil, item.sortDate > feed.subscribedDate, item.state.libraryBookID == nil else { return false }
        if let book = downloadedRow(of: item, in: feed.id) ?? library?.feedItemRows(of: feed.id).kept[item.id] {
            return book.isUnopened
        }
        return true
    }

    /// The items of the feed `feedID` counted as the library shows them,
    /// with the feed's size, whether the listener is subscribed (FR11,
    /// branch D), and, while subscribed, the kept places Unsubscribe would
    /// delete (FR14); none for a feed whose record is gone. Each
    /// item's row is found by its identity in the feed's rows (FR11), so a
    /// count takes one step per item, however many books the library holds.
    /// The items are those the library lists, the short list's under "Only
    /// the newest 5 listed" (`listedItems(of:)`).
    func counts(of feedID: UUID) -> FeedItemCounts {
        guard let record = store.record(of: feedID) else { return FeedItemCounts() }
        let items = listedItems(of: feedID)
        var counts = FeedItemCounts(
            listed: items.count,
            total: record.feed.entryTotal,
            noun: .of(items),
            isSubscribed: record.feed.isSubscribed,
            keptForRemovedDownloads: record.feed.isSubscribed ? keptRowsUnsubscribeDeletes(of: feedID).count : 0
        )
        for item in items {
            switch state(of: item, in: feedID) {
            case .downloaded:
                counts.downloaded += 1
            case .downloading:
                counts.downloading += 1
            // An item moved into the library is no download of its feed's
            // (FR11, branch D).
            case .notDownloaded, .waiting, .failed, .inLibrary:
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

    /// How the feed `feedID`'s last check reads now: for a feed the listener
    /// unsubscribed from (FR11, branch D), that it is not checked, and since
    /// when.
    func checkWording(of feedID: UUID, now: Date) -> FeedWording.Check {
        FeedWording.check(
            fetchState(of: feedID),
            isRefreshing: refreshingFeedIDs.contains(feedID),
            isSubscribed: store.record(of: feedID)?.feed.isSubscribed ?? true,
            now: now
        )
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
    /// its books counted, with the feeds the Feeds section lists there
    /// beside them ("Library, 743 books, 2 feeds", FR11), or, for a feed's
    /// folder, its name, the note "Feed", and the feed's items counted
    /// ("Planet Money, Feed, 10 of 381 episodes listed, 3 downloaded, 2 new")
    /// (FR03).
    @MainActor
    static func announcement(for path: String, library: Library, feedFolders: LibraryFeedFolders) -> String {
        if !path.isEmpty,
           let folder = library.folders.first(where: { $0.fullPath == path }),
           let feedID = feedFolders.feedID(inFolder: folder.id) {
            return FeedWording.folderAnnouncement(name: folder.name, counts: feedFolders.center.counts(of: feedID))
        }
        let feeds = LibraryFeedsSectionRows.feeds(at: LibraryLocation(category: .folders, folderPath: path), center: feedFolders.center)
        return announcement(for: path, library: library, feedCount: feeds.count)
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
    /// The title the row shows and speaks in place of the feed's own while
    /// the Leading articles setting shows titles with their articles after
    /// them ("Digital Antiquarian, The"); nil shows the title as written.
    /// Commands and announcements name the feed by `title`.
    var shownTitle: String? = nil

    /// The title the row shows and speaks.
    var rowTitle: String {
        shownTitle ?? title
    }

    /// The items counted, as the row shows them.
    var countsText: String {
        FeedWording.countsPhrase(counts)
    }

    /// The row as VoiceOver speaks it, in one sentence, beginning with the
    /// title as the row shows it.
    var label: String {
        FeedWording.feedRowLabel(title: rowTitle, counts: counts, check: check, folderMissing: folderPath == nil)
    }
}

/// Which feeds a Library window's Feeds section lists, and what each row
/// says (FR03).
///
/// The section shows where feeds are: in Folders, at a folder holding
/// feeds' folders, at any depth, which makes the top of the library list
/// every feed; in a filter view, the feeds its filter finds (October 30,
/// 2026, `LibraryViewFilterEvaluator.feeds`); at the Reading List, none.
/// The views TextMouth ships list what the categories did: All Items and
/// Feeds every feed; Unopened a feed only while it has a new item (FR11,
/// the user's answer to question 8), one published since the subscription
/// began, neither played nor opened (`FeedCenter.isNew`), so a podcast's
/// back catalogue, every item of which is listed and unplayed, never keeps
/// its feed there; and Recently Opened none. Each row counts its items as
/// it does everywhere. A feed's own folder lists its items rather than
/// itself. A feed whose folder is gone shows at the top of the library, in
/// All Items and Feeds, and, with a new item, in Unopened, where it can
/// still be found.
enum LibraryFeedsSectionRows {
    /// The feeds the Feeds section lists at `location`, by title.
    @MainActor
    static func feeds(at location: LibraryLocation, center: FeedCenter) -> [Feed] {
        switch location.view.kind {
        case .folders:
            let base = location.folderPath
            return center.feeds.filter { feed in
                guard let path = center.folderPath(of: feed) else { return base.isEmpty }
                return base.isEmpty || path.hasPrefix(base + "/")
            }
        case .readingList:
            return []
        case .filter:
            guard let filter = location.view.filter, filter.lists.contains(.feeds) else { return [] }
            return LibraryViewFilterEvaluator.feeds(
                of: filter,
                in: center.feeds,
                context: feedContext(for: filter, center: center),
                newItemCount: { center.counts(of: $0).new },
                folderPath: { center.folderPath(of: $0) }
            )
        }
    }

    /// Whether the filter view `view` lists any feed, the search ending at
    /// the first that matches: what a window's View pop-up asks of a view
    /// shown when applicable (review of October 31, 2026, finding 4).
    @MainActor
    static func listsAnyFeed(of view: LibraryViewDefinition, center: FeedCenter) -> Bool {
        guard let filter = view.filter, filter.lists.contains(.feeds) else { return false }
        return LibraryViewFilterEvaluator.listsAnyFeed(
            of: filter,
            in: center.feeds,
            context: feedContext(for: filter, center: center),
            newItemCount: { center.counts(of: $0).new },
            folderPath: { center.folderPath(of: $0) }
        )
    }

    /// What a filter reads of the feeds: their folder, their title and
    /// author, their new items, and whether they are subscribed, so the
    /// context holds the paths of the folders the conditions name, and
    /// nothing else.
    @MainActor
    private static func feedContext(for filter: LibraryViewFilter, center: FeedCenter) -> LibraryViewFilterContext {
        LibraryViewFilterContext(
            for: filter,
            now: Date(),
            calendar: .current,
            finishedIDs: { [] },
            readingListIDs: { [] },
            folderPath: { center.library?.feedFolderPath(forFolderID: $0) },
            feedFolderPaths: { [:] }
        )
    }

    /// The rows of the Feeds section at `location`, in order: by title, as
    /// the feeds are kept; or, while the Leading articles setting has sorting
    /// pass over articles (`articles`), by each title without its leading
    /// article, ties keeping the feeds' order, each row showing its title
    /// with its article after it ("Digital Antiquarian, The"), as a book's
    /// row does. A feed names no language, so English's articles count.
    @MainActor
    static func rows(
        at location: LibraryLocation,
        center: FeedCenter,
        now: Date = Date(),
        articles: LeadingArticles = .partOfTitle
    ) -> [FeedRowContent] {
        let rows = feeds(at: location, center: center).map { feed in
            FeedRowContent(
                id: feed.id,
                title: feed.title,
                folderPath: center.folderPath(of: feed),
                counts: center.counts(of: feed.id),
                check: center.checkWording(of: feed.id, now: now),
                shownTitle: articles.sortsWithoutArticles ? articles.shownTitle(feed.title, language: nil) : nil
            )
        }
        guard articles.sortsWithoutArticles else { return rows }
        // Each key read once; the feeds' own order breaks ties.
        let keys = rows.map { articles.sortKey(of: $0.title, language: nil) }
        return rows.indices
            .sortedStably { first, second in
                let order = keys[first].localizedStandardCompare(keys[second])
                return order == .orderedSame ? first < second : order == .orderedAscending
            }
            .map { rows[$0] }
    }
}

// MARK: - A Feed's Folder

/// What one row of a feed's item not downloaded shows and says (FR03): its
/// title, its state (with why it waits, FR11), the place and bookmarks kept
/// for it after its file went (FR11), its date, and its duration. A
/// downloaded item is its book's row instead, unless its book lives in
/// another folder.
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
    /// What the row says of the place and bookmarks the item's package kept
    /// after its file went (FR11, branch A2), or nil when nothing was kept.
    let kept: FeedKeptProgress?
    /// Its date, as its row shows and speaks it, when the feed gives one.
    let dateText: String?
    /// How long it plays, when the feed says.
    let duration: TimeInterval?
    /// The title the row shows and speaks in place of the item's own while
    /// the Leading articles setting shows titles with their articles after
    /// them, as the book rows beside it do; nil shows the title as written.
    /// Commands and announcements name the item by `title`.
    let shownTitle: String?

    /// The title the row shows and speaks.
    var rowTitle: String {
        shownTitle ?? title
    }

    /// The row as VoiceOver speaks it.
    var label: String {
        FeedWording.itemRowLabel(self)
    }

    /// The row's content for `item` of `feed` in `center`, an article's
    /// time left estimated at `wordsPerMinute`, as a book row's is, its
    /// title shown as `articles`, the Leading articles setting, shows a
    /// book's (a feed names no language, so English's articles count).
    @MainActor
    init(_ item: FeedItem, of feed: Feed, in center: FeedCenter, wordsPerMinute: Double, articles: LeadingArticles = .partOfTitle) {
        let state = center.state(of: item, in: feed.id)
        let isPlayed = item.playedDate != nil
        feedID = feed.id
        id = item.id
        title = item.title
        shownTitle = articles.sortsWithoutArticles ? articles.shownTitle(item.title, language: nil) : nil
        self.state = state
        isNew = center.isNew(item, of: feed)
        self.isPlayed = isPlayed
        isArticle = item.isArticle
        // The kept row is found by the item's identity, in one step.
        kept = center.library?.feedItemRows(of: feed.id).kept[item.id].map { row in
            FeedKeptProgress(row, isPlayed: isPlayed, besideDownloadPercentage: state.isDownloading, wordsPerMinute: wordsPerMinute)
        }
        dateText = item.published.map { FeedWording.itemDate($0) }
        duration = item.duration
    }
}

/// What a feed item's row says of the listener's place kept in the item's
/// package after its file went (FR11, branches A2 and C), in the book row's
/// own words (`BookRow.progressText(for:)`, `BookRow.remainingText(_:)`),
/// so an episode or article says the same before and after its file goes:
/// how far it got and the time left, unless it was played, and its
/// bookmarks.
struct FeedKeptProgress: Equatable, Sendable {
    /// The progress as the row shows it, "42%"; nil for a played item, or
    /// one whose package kept no place.
    let shownProgress: String?
    /// The progress as the row speaks it: "42 percent", or "42 percent
    /// read" beside "Downloading", which would otherwise seem to say how far
    /// the download has got, as a book row says it beside a cloud
    /// download's percentage.
    let spokenProgress: String?
    /// The time left after the place, as a book's row gives it
    /// (`BookRow.timeRemaining(for:wpm:)`); nil with no progress to say,
    /// since the row's own duration then says how long the item is, and at
    /// the end, where "Finished" says it all (TODO P07).
    let remaining: TimeInterval?
    /// How many bookmarks the package kept.
    let bookmarkCount: Int

    /// What the row says of `row`, the item's kept row on its feed's shelf,
    /// for an item that `isPlayed`, whose row says "Downloading" too when
    /// `besideDownloadPercentage` (its download's percent is the feed
    /// downloads section's, FR10), an article's time left estimated at
    /// `wordsPerMinute`.
    init(_ row: Book, isPlayed: Bool, besideDownloadPercentage: Bool, wordsPerMinute: Double) {
        let shown = isPlayed ? nil : BookRow.progressText(for: row)?.visible
        shownProgress = shown
        spokenProgress = shown == nil ? nil : BookRow.spokenProgress(for: row, besideDownloadPercentage: besideDownloadPercentage)
        remaining = shown == nil ? nil : BookRow.timeRemaining(for: row, wpm: wordsPerMinute)
        bookmarkCount = row.bookmarks.count
    }

    /// Whether the item opens at a place of its own once downloaded again,
    /// which its row's hint then says.
    var hasPlace: Bool {
        spokenProgress != nil
    }

    /// The words the row speaks of it, in order, each left out when there
    /// is nothing to say: "42 percent", "16 minutes remaining", "2
    /// bookmarks".
    var spokenParts: [String] {
        parts(progress: spokenProgress) { BookRow.remainingText($0).spoken }
    }

    /// The words the row shows of it, which say what `spokenParts` says:
    /// "42%", "16:00 left", "2 bookmarks".
    var shownParts: [String] {
        parts(progress: shownProgress) { BookRow.remainingText($0).visible }
    }

    /// The row's words of it in one form: `progress`, the time left as
    /// `remainingWords` words it, and the bookmarks, each left out when
    /// there is nothing to say.
    private func parts(progress: String?, remainingWords: (TimeInterval) -> String) -> [String] {
        var parts: [String] = []
        if let progress { parts.append(progress) }
        if let remaining { parts.append(remainingWords(remaining)) }
        if bookmarkCount > 0 { parts.append(CountWording.bookmarks(bookmarkCount)) }
        return parts
    }
}

/// One row of a feed's folder (FR03): an item's book, or an item not
/// downloaded.
enum FeedFolderEntry: Equatable, Identifiable {
    /// A downloaded item, or one Move to Library… moved into this folder,
    /// as its book's row, with the commands of the item it came from, which
    /// its row offers beside the book's own.
    case book(Book, actions: [FeedItemAction])
    /// An item not downloaded, or whose book is in another folder.
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
/// whose book the folder holds as that book, a downloaded one or one moved
/// into the library there, then the folder's other books, which came from
/// no item of the feed; no book is listed twice.
struct FeedFolderListing: Equatable {
    /// The feed's items, newest first.
    var entries: [FeedFolderEntry] = []
    /// The folder's books from no item of the feed, in the folder's order.
    var otherBooks: [Book] = []
    /// What the feed's items are called.
    var noun: FeedWording.ItemNoun = .episode
    /// The feed's size, which the items' heading says beside their count
    /// while the entries are every item the library lists
    /// (`FeedWording.sectionTitle(_:count:total:)`); nil while a search
    /// narrows them, and while the size is not known.
    var total: FeedEntryTotal?

    /// The listing of the feed `feedID`'s folder in `center`, given the
    /// folder's books as the list shows them, narrowed by `search`
    /// (`shownBooks`), and every book of the folder (`folderBooks`). An item
    /// shows when its title or author contains the search, ignoring case, as
    /// a book does; a downloaded item shows as its book when the folder holds
    /// it, so the search narrows it as it narrows the book. An item row
    /// estimates an article's time left at `wordsPerMinute`, the library's
    /// reading speed, as a book row does, and shows its title as
    /// `articles`, the Leading articles setting, shows a book's; while that
    /// shows titles inverted, the search finds an item by its title as its
    /// row shows it too.
    @MainActor
    static func make(
        feedID: UUID,
        center: FeedCenter,
        shownBooks: [Book],
        folderBooks: [Book],
        search: String,
        wordsPerMinute: Double,
        articles: LeadingArticles = .partOfTitle
    ) -> FeedFolderListing {
        guard let record = center.store.record(of: feedID) else {
            return FeedFolderListing(otherBooks: shownBooks)
        }
        // Every item the library lists: the short list's under "Only the
        // newest 5 listed" (FR11).
        let items = center.listedItems(of: feedID)
        // With no search, every item listed has its row, as its book's or
        // its own, so the rows are the entries listed, of the feed's size.
        var listing = FeedFolderListing(noun: .of(items), total: search.isEmpty ? record.feed.entryTotal : nil)
        let shownByID = Dictionary(shownBooks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let folderBookIDs = Set(folderBooks.map(\.id))
        let query = search.lowercased()
        var itemBookIDs = Set<UUID>()
        for item in items {
            let state = center.state(of: item, in: feedID)
            // The book the item is linked to wherever it is: its download in
            // the feed's folder, or the book Move to Library… made of it,
            // which the listener may have moved into this very folder, where
            // it is listed once, as its book's row (REV13 feeds 1).
            if let bookID = state.linkedBookID {
                itemBookIDs.insert(bookID)
                if let book = shownByID[bookID] {
                    let actions = FeedItemAction.actions(
                        feedID: feedID,
                        itemID: item.id,
                        itemTitle: item.title,
                        state: state,
                        isPlayed: item.playedDate != nil,
                        isArticle: item.isArticle,
                        onBookRow: true,
                        // A download in its feed's folder moves into the
                        // library (FR11, branch D); one made before FR11,
                        // a book of the library's own, needs no move.
                        canMoveToLibrary: book.isFeedItem
                    )
                    listing.entries.append(.book(book, actions: actions))
                    continue
                }
                // In this folder but narrowed out by the search.
                if folderBookIDs.contains(bookID) {
                    continue
                }
            }
            guard query.isEmpty || Self.matches(item, query: query, articles: articles) else { continue }
            listing.entries.append(.item(FeedItemRowContent(
                item, of: record.feed, in: center, wordsPerMinute: wordsPerMinute, articles: articles
            )))
        }
        listing.otherBooks = shownBooks.filter { !itemBookIDs.contains($0.id) }
        return listing
    }

    /// Whether `item`'s title or author contains `query`, already lower
    /// case, or, while `articles` shows titles inverted, its title as its
    /// row shows it does ("one about x, the").
    private static func matches(_ item: FeedItem, query: String, articles: LeadingArticles) -> Bool {
        if item.title.lowercased().contains(query) || (item.author?.lowercased().contains(query) ?? false) {
            return true
        }
        return articles.sortsWithoutArticles && articles.shownTitle(item.title, language: nil).lowercased().contains(query)
    }
}
