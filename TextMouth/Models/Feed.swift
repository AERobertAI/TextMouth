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
    /// which the library lists those the "List and download" choice lists
    /// (`FeedReconciler`, FR11), as "10 of 381 episodes listed" says. Every
    /// merge of a body read records it; a check
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
    /// How many entries this feed kept, in place of the retired setting
    /// (`FeedSettings.keepEntriesPreference`); nil followed the setting.
    /// Retired by `itemPolicyOverride`, as the setting is by the "List and
    /// download" choice: nothing sets it any more, and the move to the
    /// choice gives a feed whose record still holds one the choice it asks
    /// for and clears it (`FeedCenter.moveKeptEntriesOverrides()`).
    var keepEntriesOverride: Int?
    /// How many days after an episode plays to the end its download is
    /// deleted, in place of the setting
    /// (`FeedSettings.deleteDownloadsDaysAfterPlayed`); nil follows it.
    var deleteDownloadsDaysAfterPlayedOverride: Int?
    /// When the listener unsubscribed from the feed (FR11, branch D); nil
    /// while it is subscribed (`isSubscribed`). Unsubscribing is a switch,
    /// as the listener asked on October 9 ("just keep it a feed with rules
    /// kept except you can't check it or manually check it for new
    /// items"): the feed keeps its record, its folder, its settings, and
    /// its downloads, and only checking stops; Resubscribe clears it. Read
    /// through `decodeIfPresent`, as every optional field of the record is,
    /// so a record written before it existed reads as subscribed, and
    /// written only when set, so a subscribed feed's record file is
    /// exactly as it was.
    var unsubscribedDate: Date?
    /// How listening goes on from one of the feed's episodes to another
    /// (FR19): what happens when one ends, whether finished ones are passed
    /// over, and whether the next is downloaded before it is needed. Nil is
    /// the standard options, which are never stored (`FeedCenter
    /// .setListeningOptions(_:of:)` stores nil for them). Read through
    /// `decodeIfPresent`, so a record written before it existed reads as
    /// standard, and written only when set, so a feed left as it was has a
    /// record file exactly as it was.
    var listeningOptions: ListeningOptions?

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
        unsubscribedDate = nil
        listeningOptions = nil
    }

    /// Whether TextMouth checks the feed for new items (FR11, branch D): at
    /// launch, on the interval, in Refresh All Feeds, and by Check Feed.
    /// An unsubscribed feed is checked by none of them, while its rules
    /// still act on its downloads and Download still downloads a listed
    /// item (`unsubscribedDate`).
    var isSubscribed: Bool {
        unsubscribedDate == nil
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
/// download in progress, or one waiting (FR11), is never written as such:
/// its item is written as not downloaded, so neither a later launch nor
/// another Mac sharing the library finds a download that is no longer
/// running (`FeedItemState`).
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

    /// The item linked to the book `bookID`, if any: its download, in its
    /// feed's folder, or the book it became in the library by Move to
    /// Library… (FR11, branch D, `FeedItemState.linkedBookID`).
    func item(linkedTo bookID: UUID) -> FeedItem? {
        items.first { $0.state.linkedBookID == bookID }
    }

    /// Every item the listener has not deleted, newest first: what the
    /// library lists while the feed lists every item, and what the "List
    /// and download" choice's newest are counted among
    /// (`listedItems(under:hasFile:)`).
    var listedItems: [FeedItem] {
        items.filter { $0.deletedDate == nil }
    }

    /// The newest `count` items the listener has not deleted, newest first,
    /// played ones among them (FR11): the items the "List and download"
    /// choice's number counts, in the order the feed's folder lists them,
    /// which is the order the record keeps them in. A played item keeps its
    /// place, so playing one never brings an older one in (the listener's
    /// answer to question 4).
    func newestItems(_ count: Int) -> ArraySlice<FeedItem> {
        listedItems.prefix(max(0, count))
    }

    /// The items the library lists under `listing` (FR11): every item not
    /// deleted, or, under "Only the newest 5 listed", the short list: the
    /// newest of them (`newestItems(_:)`), less those played whose files are
    /// not here, so a played episode drops off the list, and every item
    /// whose file is here (`hasFile`), that downloads, or waits to, or that
    /// was moved into the library (FR11, branch D), wherever it falls, as
    /// its row says "In Library" until Delete Episode hides it. The items
    /// left out stay in the record, hidden, and come back when the list
    /// widens.
    func listedItems(under listing: FeedItemPolicy.Listing, hasFile: (FeedItem) -> Bool) -> [FeedItem] {
        guard case .newest(let count) = listing else { return listedItems }
        let newest = Set(newestItems(count).map(\.id))
        return listedItems.filter { item in
            hasFile(item) || item.state.isTransient || item.state.libraryBookID != nil
                || (newest.contains(item.id) && item.playedDate == nil)
        }
    }

    /// The record as its file holds it: each download in progress, or
    /// waiting (FR11), written as not downloaded. Two records with the same
    /// durable form write the same file, so a change of progress alone, or a
    /// download put off, writes nothing.
    var durable: FeedRecord {
        var durable = self
        for index in durable.items.indices where durable.items[index].state.isTransient {
            durable.items[index].state = .notDownloaded
        }
        return durable
    }
}
