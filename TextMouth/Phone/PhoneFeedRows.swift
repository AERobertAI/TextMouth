import Foundation

/// Where VoiceOver's focus goes once a feed command has taken its row away
/// (FR53): the row it was run from, the row that takes that row's identity
/// when it has one (Delete Download turns a downloaded item's book row into the
/// item's own), and the rows as they were, for the row after it or before it.
struct PhoneFeedFocusRequest: Equatable, Sendable {
    /// The row the command was run from.
    let row: PhoneRowID
    /// The row that takes its place with another identity, or nil.
    let successor: PhoneRowID?
    /// The list's rows when the command was run.
    let oldRows: [PhoneRowID]
}

/// The rows of feeds on the iPhone's Library (FR53, phase F1): a feed's row in
/// the Feeds section, and the row of a feed's item that is not downloaded.
///
/// Every word is the Mac's, called from where the Mac keeps it
/// (`FeedWording`, `FeedItemRowContent`, `FeedAction`, `FeedItemAction`): this
/// only chooses which of the Mac's commands the phone offers, and puts the
/// Mac's content into the phone's row value, which the Library's rows are.
/// A plain type that compiles on both apps, so the Mac's test host tests it.
@MainActor
enum PhoneFeedRows {
    // MARK: - Which Commands the Phone Offers

    /// Whether the phone offers the feed item command `command` in this
    /// phase: not Show in Finder, which is the Mac's, and not Move to
    /// Library…, whose sheet the phone has yet to have.
    nonisolated static func offers(_ command: FeedItemCommand) -> Bool {
        switch command {
        case .showInFinder, .moveToLibrary: false
        case .open, .download, .cancelDownload, .deleteDownload, .markPlayed, .markUnplayed, .showDescription, .deleteItem: true
        }
    }

    /// The feed item commands of `actions` that the phone offers, in the Mac's
    /// order.
    nonisolated static func offered(_ actions: [FeedItemAction]) -> [FeedItemAction] {
        actions.filter { offers($0.command) }
    }

    // MARK: - A Feed's Row

    /// The row of the feed `content` describes: the Mac's label, "The Tactile
    /// Atlas, Feed, 3 episodes, 1 downloaded, checked today at 3:05 PM"; its
    /// title and, under it, its items counted and its last check; and the
    /// Mac's feed commands.
    static func feedRow(_ content: FeedRowContent) -> PhoneRowValue {
        PhoneRowValue(
            id: .feed(content.id),
            label: content.label,
            title: content.rowTitle,
            detail: SentenceWording.commaJoined([content.countsText, content.check.visible]),
            commands: FeedAction.actions(for: content.id, counts: content.counts).map { PhoneLibraryOffer.Command($0) },
            hint: FeedWording.feedRowHint
        )
    }

    // MARK: - An Item's Row

    /// The row of the item `content` describes, not downloaded or downloaded
    /// into another folder: the Mac's label, "Ep. 368, Not Downloaded, July
    /// 17, 2026, 1 hour, 4 minutes"; its title and, under it, the same notes
    /// as the Mac's row shows them; and the item's commands the phone offers.
    static func itemRow(_ content: FeedItemRowContent) -> PhoneRowValue {
        PhoneRowValue(
            id: .feedItem(feedID: content.feedID, itemID: content.id),
            label: content.label,
            title: content.rowTitle,
            detail: SentenceWording.commaJoined(detailParts(of: content)),
            commands: offered(FeedItemAction.actions(for: content)).map { PhoneLibraryOffer.Command($0) },
            hint: FeedWording.itemRowHint(content.state, keptPlace: content.kept?.hasPlace ?? false)
        )
    }

    /// The notes an item row shows under its title, in the order its label
    /// speaks them: Played, the state, why a download failed or waits, the
    /// place and bookmarks kept, New, the date, and the duration.
    private static func detailParts(of content: FeedItemRowContent) -> [String] {
        var parts: [String] = []
        if content.isPlayed { parts.append(FeedWording.playedNote(isArticle: content.isArticle)) }
        parts.append(content.state.visibleNote)
        if let reason = content.state.reason { parts.append(reason) }
        parts += content.kept?.shownParts ?? []
        if content.isNew { parts.append(FeedWording.newNote) }
        if let date = content.dateText { parts.append(date) }
        if let duration = content.duration { parts.append(TimeFormatting.format(duration)) }
        return parts
    }

    // MARK: - A Feed's Folder

    /// The commands of the feed item `entry` offers a downloaded item's book
    /// row, beside the book's own: the Mac's, as the phone offers them.
    static func bookRowActions(of entry: FeedFolderEntry) -> [FeedItemAction] {
        guard case .book(_, let actions) = entry else { return [] }
        return offered(actions)
    }

    // MARK: - What a Library Screen Holds of Feeds

    /// A feed's folder as its screen lists it: the feed, what its folder
    /// lists, and what its summary says of the feed.
    struct FolderContents {
        /// The feed whose folder is shown.
        let feedID: UUID
        /// The feed's items newest first, each as its book or its own row,
        /// then the folder's other books.
        let listing: FeedFolderListing
        /// The feed's items counted, and its last check.
        let summary: FeedWording.FolderSummary
    }

    /// What one Library screen holds of feeds, gathered with the screen's
    /// books and folders (FR53): the Feeds section's rows, the folders that
    /// are feeds' or hold them, and, in a feed's own folder, its items.
    struct Gathered {
        /// The Feeds section's rows at the screen's location, in order.
        var feeds: [FeedRowContent] = []
        /// The folders the Folders section lists: every subfolder but those
        /// whose feeds the Feeds section lists, which stand for them.
        var folders: [BookFolder] = []
        /// The feed's items counted, by the ID of each folder listed that is
        /// a feed's: the folder's row says "Feed" and these.
        var heldFeedCounts: [UUID: FeedItemCounts] = [:]
        /// How many feeds each folder listed holds below it, by folder ID,
        /// which its row names beside its books.
        var feedsBelow: [UUID: Int] = [:]
        /// The screen's own feed, when it is a feed's folder.
        var folder: FolderContents?

        /// The words that decide whether the feeds on the screen changed: the
        /// feed rows' labels, each folder's feed counts, and the feed
        /// folder's heading and entries. Never a reading position, so a
        /// checkpoint changes nothing here.
        var signature: [String] {
            var words = feeds.map(\.label)
            words += heldFeedCounts.map { "held:\($0.key.uuidString):\(FeedWording.countsPhrase($0.value))" }.sorted()
            words += feedsBelow.map { "below:\($0.key.uuidString):\($0.value)" }.sorted()
            if let folder {
                words.append(FeedWording.sectionTitle(folder.listing.noun, count: folder.listing.entries.count, total: folder.listing.total))
                words.append(folder.summary.counts)
                words.append(folder.summary.check.visible)
                words += folder.listing.entries.map(Self.signature(of:))
                words += folder.listing.otherBooks.map { "other:\($0.id.uuidString):\($0.title)" }
            }
            return words
        }

        /// What decides whether one entry of a feed's folder changed: its
        /// identity and words, and the names of its commands, which follow
        /// its state and whether it is played.
        private static func signature(of entry: FeedFolderEntry) -> String {
            switch entry {
            case .book(let book, let actions):
                return "book:\(book.id.uuidString):\(book.title):\(book.author):" + actions.map(\.title).joined(separator: "|")
            case .item(let content):
                return "item:" + content.id + ":" + content.label
            }
        }
    }

    /// What the feeds on the Library screen at `location` hold, for a screen
    /// whose own subfolders are `subfolders` and whose books are `books`
    /// (FR53). `bookCount` counts the books in a folder's tree, as a plain
    /// folder's row says them.
    static func gather(
        at location: LibraryLocation,
        subfolders: [BookFolder],
        books: [Book],
        in library: LibraryViewModel,
        feedFolders: LibraryFeedFolders,
        wordsPerMinute: Double,
        bookCount: (BookFolder) -> Int
    ) -> Gathered {
        let center = feedFolders.center
        var gathered = Gathered()
        gathered.feeds = LibraryFeedsSectionRows.rows(at: location, center: center)
        // Only the Folders view shows folders: a feed's folder whose feed the
        // Feeds section lists is left out, its row standing for it.
        gathered.folders = location.view.kind == .folders
            ? feedFolders.folderRows(subfolders, at: location, bookCount: bookCount).shown
            : []
        for folder in gathered.folders {
            if let feedID = feedFolders.feedID(inFolder: folder.id) {
                gathered.heldFeedCounts[folder.id] = center.counts(of: feedID)
            } else if !center.feeds.isEmpty {
                gathered.feedsBelow[folder.id] = feedFolders.feedCount(below: folder)
            }
        }
        // A feed's own folder lists its items, not its books alone.
        if location.view.kind == .folders, let feedID = library.feedID(listedIn: location.folderPath) {
            let listing = FeedFolderListing.make(
                feedID: feedID,
                center: center,
                shownBooks: books,
                folderBooks: books,
                search: "",
                wordsPerMinute: wordsPerMinute
            )
            gathered.folder = FolderContents(feedID: feedID, listing: listing, summary: center.folderSummary(of: feedID, now: Date()))
        }
        return gathered
    }

    // MARK: - Finding What a Command Acts On

    /// The Mac's feed command `command` for the feed `feedID`, as its row
    /// offers it now; nil once the feed is gone or no longer offers it (an
    /// unsubscribed feed's row offers Resubscribe, not Unsubscribe).
    static func feedAction(_ command: FeedCommand, feedID: UUID, in center: FeedCenter) -> FeedAction? {
        FeedAction.actions(for: feedID, in: center).first { $0.command == command }
    }

    /// The Mac's item command `command` for the item `itemID` of the feed
    /// `feedID`, built from the engine's record as the item's row builds its
    /// own, so a command from a book's row and one from an item's row are the
    /// same; nil once the item is gone.
    ///
    /// The engine's own commands are named by the item and its state, so this
    /// reads both now, not as they were when the row was drawn: a menu drawn
    /// before a download ended still runs the command on the item as it is.
    static func itemAction(_ command: FeedItemCommand, feedID: UUID, itemID: FeedItem.ID, in center: FeedCenter) -> FeedItemAction? {
        guard let item = center.store.record(of: feedID)?.item(itemID) else { return nil }
        return FeedItemAction(
            command: command,
            feedID: feedID,
            itemID: itemID,
            itemTitle: item.title,
            isArticle: item.isArticle,
            title: FeedWording.title(of: command, isArticle: item.isArticle)
        )
    }

    // MARK: - The Summary

    /// What the summary under a feed's folder says: its items counted, then
    /// its last check, as the Mac's summary bar says them, with the time left
    /// in the downloads in between when there are any.
    static func summary(of feed: FeedWording.FolderSummary, books: [Book], wordsPerMinute: Double, livePositions: LiveReadingPositions) -> String {
        var bar = TimeRemainingBar(books: books, wpm: wordsPerMinute, livePositions: livePositions)
        bar.feedSummary = feed
        return bar.summaryAccessibilityLabel
    }
}
