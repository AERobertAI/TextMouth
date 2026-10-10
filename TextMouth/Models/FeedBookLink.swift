import Foundation

// MARK: - The Link From a Book to Its Feed Item (FR03)

/// Which feed item a book was downloaded from (FR03).
///
/// The link runs both ways. The item names its book (`FeedItemState
/// .downloaded`), in the feed's record; the book names its feed and item
/// here, in its package record (bookInfo.json's metadata) and, while the
/// book belongs to its feed, in its row (`Book.feedLink`, FR11), which the
/// feed's own index keeps instead of library.json. A save of the book's
/// state writes the row's link, or keeps the one its record already holds
/// when the row has none (`Book.bookInfo(replacing:contentIndex:
/// revisionFloor:)`).
struct FeedBookLink: Codable, Hashable, Sendable {
    /// The subscription the book was downloaded from.
    let feedID: UUID
    /// The identity of the item it was downloaded from (`FeedItem.id`).
    let itemID: String
}
