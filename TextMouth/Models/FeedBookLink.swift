import Foundation

// MARK: - The Link From a Book to Its Feed Item (FR03)

/// Which feed item a book was downloaded from (FR03).
///
/// The link runs both ways. The item names its book (`FeedItemState
/// .downloaded`), in the feed's record; the book names its feed and item
/// here, in its package record (bookInfo.json's metadata), never in
/// library.json, whose format stays as it is. A save of the book's state
/// keeps the link its record already holds (`Book.bookInfo(replacing:
/// contentIndex:revisionFloor:)`), since library rows never carry it.
struct FeedBookLink: Codable, Equatable, Sendable {
    /// The subscription the book was downloaded from.
    let feedID: UUID
    /// The identity of the item it was downloaded from (`FeedItem.id`).
    let itemID: String
}
