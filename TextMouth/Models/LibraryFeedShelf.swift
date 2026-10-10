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

    /// A shelf holding `rows`, keeping the indexes of `indexedFeedIDs` and
    /// of every feed `rows` belong to.
    init(rows: [Book] = [], indexedFeedIDs: Set<UUID> = []) {
        self.rows = rows
        self.indexedFeedIDs = indexedFeedIDs.union(rows.compactMap { $0.feedLink?.feedID })
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
