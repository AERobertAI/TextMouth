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
struct FeedBookLink: Codable, Hashable, Sendable, KeepsUnknownKeys {
    /// The subscription the book was downloaded from.
    let feedID: UUID
    /// The identity of the item it was downloaded from (`FeedItem.id`).
    let itemID: String
    /// The keys of the stored link that this TextMouth does not know (V04),
    /// written back as they were; none in a link made here. They take no
    /// part in `==` or hashing (see below).
    var unknownKeys = UnknownKeys()
}

// MARK: - Identity

extension FeedBookLink {
    /// Two links are the same link when they name the same item of the same
    /// feed. A link is an identity: TextMouth finds a feed item's book by
    /// comparing the link a row holds with one it makes from the feed and
    /// the item, which never holds a later TextMouth's keys. So the keys
    /// this version does not know take no part here, unlike in every other
    /// record that keeps them (`UnknownKeys`): a stored link that held some
    /// would otherwise match no link made here, and its book would look
    /// like no item's.
    static func == (lhs: FeedBookLink, rhs: FeedBookLink) -> Bool {
        lhs.feedID == rhs.feedID && lhs.itemID == rhs.itemID
    }

    /// Hashes what `==` compares.
    func hash(into hasher: inout Hasher) {
        hasher.combine(feedID)
        hasher.combine(itemID)
    }
}

// MARK: - Coding

// In an extension, so the struct keeps its memberwise initializer.
extension FeedBookLink {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case feedID, itemID
    }

    /// The names of a link's keys that this version knows.
    private static let knownKeyNames = CodingKeys.names

    /// What a stored link holds, for the scan that says whether a file
    /// can hold unknown keys (`StoredKeyScan`).
    static let keySchema = StoredKeySchema(names: knownKeyNames)

    /// Reads a link as the synthesized decoder read it, both fields
    /// required, and keeps every other key as it is (V04).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        feedID = try container.decode(UUID.self, forKey: .feedID)
        itemID = try container.decode(String.self, forKey: .itemID)
        unknownKeys = UnknownKeys(from: decoder, besides: Self.knownKeyNames)
    }

    /// Writes the link as the synthesized encoder wrote it, after the keys
    /// this version does not know (V04).
    func encode(to encoder: Encoder) throws {
        try unknownKeys.write(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(feedID, forKey: .feedID)
        try container.encode(itemID, forKey: .itemID)
    }
}
