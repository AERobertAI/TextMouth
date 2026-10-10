import Foundation

// MARK: - A Subscription (FR03)

/// One subscription to a podcast or article feed (FR03): the feed's address
/// and what the feed says about itself, the library folder its downloads go
/// to, and this feed's own exceptions to the feed settings.
///
/// A feed lives in its record (`FeedRecord`), in the data directory's Feeds
/// folder, so it travels with a library in the cloud. How this Mac last
/// fetched it (validators, digest, last check, last error) is kept apart, in
/// this Mac's own folder (`FeedFetchState`), since writing those into the
/// record would upload every feed after every refresh.
struct Feed: Codable, Equatable, Identifiable, Sendable {
    /// The subscription's ID, which names its record file. The file's name
    /// is what counts: a record read from a file whose name gives another ID
    /// takes that one (`FeedStore.readRecords(in:only:)`).
    var id: UUID
    /// The feed's title, as the feed gives it; the address's host until the
    /// feed has been read.
    var title: String
    /// Where the feed is fetched from: the address subscribed to, or the one
    /// a permanent redirect or the feed's own `itunes:new-feed-url` moved it
    /// to.
    var feedURL: URL
    /// The feed's web site, when it names one.
    var siteLink: URL?
    /// What the feed says about itself, when it says anything.
    var summary: FeedText?
    /// Who publishes the feed (`itunes:author`, or the Atom feed's author),
    /// when it says.
    var author: String?
    /// The library folder the feed's downloads go to, by its ID, which
    /// survives renaming and moving the folder.
    var folderID: UUID
    /// When the subscription began.
    let subscribedDate: Date
    /// When this record's items last changed.
    var updatedDate: Date?
    /// The latest publication date of any item the feed has listed while
    /// subscribed: the subscription date until a later item arrives. An item
    /// published after it is new (`FeedReconciler`), so subscribing marks
    /// none of the feed's existing items new, and keeping more entries later
    /// never brings old ones back as new.
    var newestItemDate: Date
    /// Whether the feed's address, or the address of any enclosure it has
    /// listed, uses plain http, which anyone on the network can read or
    /// change. Recorded for the warning shown after a feed is added.
    var usesInsecureTransport: Bool
    /// Whether the feed is a serial show, listed oldest episode first
    /// (`itunes:type` serial), rather than an episodic one.
    var isSerial: Bool
    /// How many entries the feed listed when it was last read: its size, of
    /// which the record keeps the newest (`FeedReconciler`), as "10 of 381
    /// episodes kept" says. Every merge of a body read records it; a check
    /// that read nothing new (a 304, or the same bytes as last time) leaves
    /// it as it was. Nil until a merge records it, as in a record written
    /// before TextMouth recorded it, which still loads, since the decoder
    /// reads an optional's key only when present (`decodeIfPresent`); the
    /// next refresh of such a record reads its feed whole
    /// (`FeedRefresher.fetchAndRead`), so the size is known from then on.
    var entryTotal: FeedEntryTotal?
    /// What this feed lists and downloads by itself, in place of the "List
    /// and download" setting (`FeedSettings.itemPolicy`, FR11); nil follows
    /// the setting ("Use the global setting"). Read through
    /// `decodeIfPresent`, so a record written before the choice existed
    /// loads, and written only when set, so such a record's file changes
    /// only once a feed has a choice of its own.
    var itemPolicyOverride: FeedItemPolicy?
    /// How many entries this feed keeps, in place of the setting
    /// (`FeedSettings.keepEntries`); nil follows the setting. Retired by
    /// `itemPolicyOverride`, as the setting is by the "List and download"
    /// choice.
    var keepEntriesOverride: Int?
    /// How many days after an episode plays to the end its download is
    /// deleted, in place of the setting
    /// (`FeedSettings.deleteDownloadsDaysAfterPlayed`); nil follows it.
    var deleteDownloadsDaysAfterPlayedOverride: Int?

    /// A new subscription to the feed at `feedURL`, whose downloads go to
    /// the folder `folderID`, begun at `date`. Its title is the address's
    /// host until the feed is read.
    init(id: UUID = UUID(), feedURL: URL, folderID: UUID, subscribedDate date: Date) {
        self.id = id
        title = feedURL.host ?? feedURL.absoluteString
        self.feedURL = feedURL
        siteLink = nil
        summary = nil
        author = nil
        self.folderID = folderID
        subscribedDate = date
        updatedDate = nil
        newestItemDate = date
        usesInsecureTransport = FeedTransport.isInsecure(feedURL)
        isSerial = false
        entryTotal = nil
        itemPolicyOverride = nil
        keepEntriesOverride = nil
        deleteDownloadsDaysAfterPlayedOverride = nil
    }
}

// MARK: - A Feed's Size (October 7, 2026)

/// How many entries a feed lists (FR03): its size, as the last read of it
/// found, before the kept-entries rule chose the ones the record keeps.
struct FeedEntryTotal: Codable, Equatable, Sendable {
    /// How many entries TextMouth read of the feed, each counted once
    /// however often the feed repeats it, with the ones the listener deleted
    /// among them, since the feed still lists those.
    var count: Int
    /// Whether the feed lists more entries than TextMouth reads of one
    /// (`FeedParser.maximumItems`): it then lists more than `count`.
    var listsMore = false

    /// Whether the feed lists more entries than the `kept` the library
    /// keeps of it, so the number kept is not the feed's size.
    func exceeds(_ kept: Int) -> Bool {
        listsMore || count > kept
    }
}

// MARK: - Plain http

/// Which addresses travel in the clear (FR03). TextMouth may load plain http
/// feeds and enclosures (App Transport Security allows them), and a feed
/// that uses any is flagged so the listener can be warned.
enum FeedTransport {
    /// Whether `url` is fetched over plain http rather than https.
    static func isInsecure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http"
    }

    /// Whether `url` is an address TextMouth fetches at all: an http or
    /// https address with a host. Nothing else, such as a file address a
    /// feed names, is ever loaded.
    static func isWebAddress(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
    }
}

// MARK: - The Record

/// A feed and the items TextMouth keeps of it (FR03): the contents of
/// `Feeds/<feed ID>.json` in the data directory, beside library.json, which
/// keeps its own format.
///
/// The items are kept newest first, the order the library lists them in. A
/// download in progress is never written as such: its item is written as
/// not downloaded, so neither a later launch nor another Mac sharing the
/// library finds a download that is no longer running (`FeedItemState`).
struct FeedRecord: Codable, Equatable, Sendable {
    /// The layout this version of TextMouth writes. A later version may add
    /// fields, which this version ignores and leaves out of its next write.
    static let currentFormatVersion = 1

    /// The subscription.
    var feed: Feed
    /// The items kept, newest first.
    var items: [FeedItem]

    /// A record of `feed` holding `items`.
    init(feed: Feed, items: [FeedItem] = []) {
        self.feed = feed
        self.items = items
    }

    /// The keys of the record file.
    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case feed
        case items
    }

    /// Reads a record, whatever format version it names.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        feed = try container.decode(Feed.self, forKey: .feed)
        items = try container.decodeIfPresent([FeedItem].self, forKey: .items) ?? []
    }

    /// Writes the record with the format version this version of TextMouth
    /// writes.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentFormatVersion, forKey: .formatVersion)
        try container.encode(feed, forKey: .feed)
        try container.encode(items, forKey: .items)
    }

    /// The item whose identity is `itemID`, if the record keeps it.
    func item(_ itemID: FeedItem.ID) -> FeedItem? {
        items.first { $0.id == itemID }
    }

    /// Where the item whose identity is `itemID` is, if the record keeps it.
    func index(of itemID: FeedItem.ID) -> Int? {
        items.firstIndex { $0.id == itemID }
    }

    /// The item whose download became the book `bookID`, if any.
    func item(downloadedAs bookID: UUID) -> FeedItem? {
        items.first { $0.state.bookID == bookID }
    }

    /// The items the library lists: every item the listener has not deleted.
    var listedItems: [FeedItem] {
        items.filter { $0.deletedDate == nil }
    }

    /// The record as its file holds it: each download in progress written as
    /// not downloaded. Two records with the same durable form write the same
    /// file, so a change of progress alone writes nothing.
    var durable: FeedRecord {
        var durable = self
        for index in durable.items.indices where durable.items[index].state.isDownloading {
            durable.items[index].state = .notDownloaded
        }
        return durable
    }
}
