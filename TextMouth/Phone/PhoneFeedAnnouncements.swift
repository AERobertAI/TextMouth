import Foundation

/// What VoiceOver hears when a feed item's download ends on the iPhone (FR53,
/// phase F1), in the item row's own words, so a download the listener asked for
/// is spoken twice and no more: once as it starts ("Downloading …", the Mac's
/// command saying it) and once as it ends, as a row's state would read it,
/// "A map you can touch, Downloaded" or "A map you can touch, Download Failed,
/// the server says the file is gone".
///
/// The Mac says neither: a listener there sees the row change. A listener on
/// the iPhone, with VoiceOver and often away from the screen, hears it. Left
/// out are the downloads the newest-N rule made by itself (nothing asked for
/// them, so nothing is said), and those Open asked for, whose end is the
/// reader opening on the item, which says itself.
///
/// A plain type that compiles on both apps, so the Mac's test host tests it.
enum PhoneFeedAnnouncements {
    /// An item of a feed, as the engine names it.
    struct ItemKey: Hashable, Sendable {
        /// The feed.
        let feedID: UUID
        /// The item's identity.
        let itemID: FeedItem.ID
    }

    /// What `event` says to a listener, or nil when it says nothing: the end of
    /// a download the listener asked for, that did not open the item.
    ///
    /// - Parameters:
    ///   - event: What the engine announced.
    ///   - center: The engine, which keeps each item's title and who asked for its download.
    ///   - opening: The items the listener opened, whose downloads open them when they end.
    @MainActor
    static func words(for event: FeedEvent, in center: FeedCenter, opening: Set<ItemKey>) -> String? {
        switch event {
        case .downloadFinished(let feedID, let itemID, let bookID):
            guard let item = askedFor(itemID, of: feedID, in: center), !opening.contains(ItemKey(feedID: feedID, itemID: itemID)) else {
                return nil
            }
            return SentenceWording.commaJoined([item.title, FeedItemState.downloaded(bookID: bookID).visibleNote])
        case .downloadFailed(let feedID, let itemID, let reason):
            guard let item = askedFor(itemID, of: feedID, in: center) else { return nil }
            let failed = FeedItemState.failed(reason)
            return SentenceWording.commaJoined([item.title, failed.visibleNote, failed.reason].compactMap { $0 })
        case .subscribed, .refreshed, .refreshedAll, .downloadStarted, .downloadCancelled, .itemPolicyApplied:
            return nil
        }
    }

    /// The item `itemID` of the feed `feedID` when the listener asked for its download (Download or Open, or a download made
    /// before the newest-N rule existed, which counts as the listener's), else nil: the rule's own downloads are silent.
    @MainActor
    private static func askedFor(_ itemID: FeedItem.ID, of feedID: UUID, in center: FeedCenter) -> FeedItem? {
        guard let item = center.store.record(of: feedID)?.item(itemID), item.downloadOrigin != .window else { return nil }
        return item
    }
}
