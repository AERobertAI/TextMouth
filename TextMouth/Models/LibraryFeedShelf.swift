import Foundation

// MARK: - The Feed Shelf (FR11)

/// What the library model holds of its feeds' items apart from its books
/// (FR11, branch A1): the rows of feed items whose files are not on this
/// Mac, and the feeds whose own indexes the library keeps.
///
/// A feed item's row has two homes while TextMouth runs. While its file is
/// here it is among the library model's books, so the reader, positions,
/// bookmarks, settings, the reading list, and Stats work through the paths
/// every book takes. Otherwise it waits here, where no list, count, or
/// maintenance pass meets it: at launch every feed's rows come here first,
/// and those whose files are here join the books once the startup repair
/// is done (`LibraryViewModel`'s join). Branch A2 keeps a removed
/// download's row here, with its place and bookmarks.
///
/// Neither part is ever written to library.json (`Library.encode(to:)`);
/// each save writes every feed's index from its rows, wherever they are
/// (`Library.feedIndexRows`).
struct FeedShelf: Equatable {
    /// The rows waiting here, each a feed item's (`Book.feedLink`).
    private(set) var rows: [Book] = []
    /// The feeds whose own index the library keeps: every feed whose index
    /// was read, and every feed whose rows the library has held. A save
    /// writes each of these feeds' indexes, so a feed whose last row left
    /// is written empty; a feed no library named is never written.
    private(set) var indexedFeedIDs: Set<UUID> = []
    /// The feeds whose index files are left as they are, never written over
    /// while TextMouth runs (`Library.feedIndexRows` leaves them out, for
    /// every writer):
    ///
    /// - a feed whose index a read found only in the cloud (FR02), so it was
    ///   not read, its rows here standing in, read from its packages'
    ///   records (`FeedIndexFiles.Contents.isLeftAlone`). Writing those rows
    ///   would replace what the cloud holds with what this Mac could read;
    ///   the next launch, which waits for the index, reads it;
    /// - and a feed no longer subscribed whose downloads returned to the
    ///   library (`LibraryViewModel.returnDownloads(ofFeed:toFolderID:removingWith:)`):
    ///   its index keeps listing them until library.json holds them and the
    ///   feed's folder goes with the index, so a crash in between finds every
    ///   row in one file or the other.
    private(set) var indexesLeftAlone: Set<UUID> = []

    /// A shelf holding `rows`, keeping the indexes of `indexedFeedIDs` and
    /// of every feed `rows` belong to, and leaving alone the index files of
    /// `indexesLeftAlone`.
    init(rows: [Book] = [], indexedFeedIDs: Set<UUID> = [], indexesLeftAlone: Set<UUID> = []) {
        self.rows = rows
        self.indexedFeedIDs = indexedFeedIDs.union(rows.compactMap { $0.feedLink?.feedID })
        self.indexesLeftAlone = indexesLeftAlone
    }

    /// Whether no row waits here.
    var isEmpty: Bool {
        rows.isEmpty
    }

    /// Puts `row` here, in place of any row with its ID, and keeps its
    /// feed's index. A row without a feed link is no feed item's and is
    /// not taken.
    mutating func put(_ row: Book) {
        guard let feedID = row.feedLink?.feedID else { return }
        rows.removeAll { $0.id == row.id }
        rows.append(row)
        indexedFeedIDs.insert(feedID)
    }

    /// Keeps the index of the feed `feedID`, as when a row of it joins the
    /// library model's books without passing through here.
    mutating func keepIndex(of feedID: UUID) {
        indexedFeedIDs.insert(feedID)
    }

    /// Leaves the index file of the feed `feedID` as it is for as long as
    /// TextMouth runs (`indexesLeftAlone`), as when a library read again
    /// after the data directory came back found it only in the cloud, or
    /// when an unsubscribed feed's downloads return to the library.
    mutating func leaveIndexAlone(of feedID: UUID) {
        indexesLeftAlone.insert(feedID)
    }

    /// Forgets the index of the feed `feedID` altogether, once its folder is
    /// gone with it, as after an unsubscribed feed's downloads returned to
    /// the library: no save writes it again, or leaves it alone. The caller
    /// holds no row of the feed any more.
    mutating func forgetIndex(of feedID: UUID) {
        indexedFeedIDs.remove(feedID)
        indexesLeftAlone.remove(feedID)
    }

    /// Takes out and returns the rows `shouldTake` chooses, in their order,
    /// asking it once for each row, since it may look at the disk. Their
    /// feeds' indexes are still kept.
    mutating func takeRows(where shouldTake: (Book) -> Bool) -> [Book] {
        var taken: [Book] = []
        var kept: [Book] = []
        for row in rows {
            if shouldTake(row) {
                taken.append(row)
            } else {
                kept.append(row)
            }
        }
        rows = kept
        return taken
    }

    /// Changes every row with `change`, as when the data directory moved
    /// under paths captured before it did.
    mutating func changeRows(_ change: (inout Book) -> Void) {
        for index in rows.indices {
            change(&rows[index])
        }
    }
}

// MARK: - A Feed's Rows by Item (FR11)

/// One feed's rows, found by the identity of the item each came from
/// (FR11, branch A2): those whose files are here, among the library model's
/// books, and those kept on the feed shelf after their files went, with the
/// listener's place, bookmarks, settings, and transcript.
///
/// A feed's counts, an item's state, and a download that restores a kept
/// record find an item's row here in one step, by the item's identity, as
/// the feed's own index lists it, rather than by scanning every row of the
/// library for the book the item names.
struct FeedItemRows: Equatable {
    /// The rows of items whose files are here, by item identity.
    var downloaded: [FeedItem.ID: Book] = [:]
    /// The rows kept after their files went, by item identity.
    var kept: [FeedItem.ID: Book] = [:]

    /// Every feed's rows in `library`, by feed ID: each feed item among its
    /// books as downloaded, and each row on its feed shelf as kept, found by
    /// the item its feed link names. Should two rows name one item, as no
    /// write makes them, the first stays, as a list of the library shows
    /// the first row of an ID.
    static func byFeed(in library: Library) -> [UUID: FeedItemRows] {
        var rows: [UUID: FeedItemRows] = [:]
        for book in library.books {
            guard let link = book.feedLink else { continue }
            if rows[link.feedID, default: FeedItemRows()].downloaded[link.itemID] == nil {
                rows[link.feedID, default: FeedItemRows()].downloaded[link.itemID] = book
            }
        }
        for row in library.feedShelf.rows {
            guard let link = row.feedLink else { continue }
            if rows[link.feedID, default: FeedItemRows()].kept[link.itemID] == nil {
                rows[link.feedID, default: FeedItemRows()].kept[link.itemID] = row
            }
        }
        return rows
    }
}
