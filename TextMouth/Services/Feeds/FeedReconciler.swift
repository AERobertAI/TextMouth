import Foundation

// MARK: - Merging a Refresh (FR03)

/// Merges what a feed lists now into the record TextMouth keeps of it
/// (FR03).
///
/// Items are matched by identity (`FeedItemIdentity`): an item whose
/// identity the record knows is the same item; failing that, one with the
/// guid or the enclosure address of an item the record knows is that item,
/// so a feed that renumbers its guids does not list every episode twice. A
/// match takes the feed's new title, texts, dates, and enclosure and keeps
/// everything the listener did: its download, its played and deleted dates.
/// An item no match finds is added.
///
/// Then the kept-entries rule decides what the record keeps (the listener's
/// decision of October 4, whose number is now the feed's listing under the
/// "List and download" choice, FR11: every entry, or the newest of the short
/// list): every item downloaded, or downloading, or moved into the library
/// (FR11, branch D), always;
/// every item played, whose played date would otherwise be lost (board
/// #1412), and every item whose package was kept with the listener's place
/// after its file went (FR11, branch A2), always too; and the newest
/// `keepEntries` of the others, by publication date (by
/// first sight for an item the feed dates nowhere, and by its place in the
/// feed between items of the same date, an item the feed lists before one
/// it no longer lists), or all of them when `keepEntries` is -1. An item
/// the listener deleted stays, out of every list, so no refresh brings it
/// back: while the feed lists it, and, once the feed stops listing it, for
/// 90 days after its deletion (`deletedItemRetention`), so a read that
/// leaves it out (a publisher's server sending an empty or cut-short
/// channel once, a feed's window moving) never lets a later read add it
/// again as a new episode; then it goes. Items the feed no longer lists
/// count among the newest like any other, so a feed that lists only its
/// last few episodes still keeps the ones before them.
///
/// An item is new, and announced, when it was not in the record and was
/// published after the newest date the feed had given before
/// (`Feed.newestItemDate`, which starts at the subscription): subscribing
/// marks none of the feed's back catalog new, and keeping more entries later
/// brings old ones back without announcing them. An item the feed dates
/// nowhere, as none of LibriVox's are, is placed by the feed's own order
/// instead: one the feed lists behind an item the record knew (above it in
/// a serial show, below it in any other) is back catalog, which a
/// kept-entries window that moved or grew brings back unannounced and dated
/// as first seen with the oldest item the record knew, so it never sorts
/// ahead of the items kept before it; any other is new once the record has
/// been refreshed before.
///
/// Every merge also records the feed's size (`Feed.entryTotal`): how many
/// entries it lists, each once, before the kept-entries rule, which the
/// library says beside the number kept ("10 of 381 episodes kept").
///
/// Reading an item's texts (`FeedTextConverter`) is the costly part, so it
/// happens only for the items kept whose text is new or changed, and the
/// texts read are kept by their HTML in a `FeedTextCache`: a refresh merges
/// once off the main actor into a copy of the record, filling the cache,
/// then again on the main actor into the record as it is then, which may
/// have changed meanwhile, reading every text from the cache.
enum FeedReconciler {
    /// What a merge did.
    struct MergeResult: Equatable, Sendable {
        /// The items that arrived as new, newest first.
        var newItemIDs: [FeedItem.ID] = []
        /// Every item added to the record, new or not, newest first.
        var addedItemIDs: [FeedItem.ID] = []
        /// The items the record no longer keeps.
        var removedItemIDs: [FeedItem.ID] = []
        /// Whether the record's durable form changed.
        var changed = false
    }

    /// How far in the future a publication date may be and still count
    /// toward the newest date a feed has given: a feed that dates an item
    /// years ahead would otherwise keep every later item from being new.
    static let futureDateTolerance: TimeInterval = 2 * 86_400

    /// How long the record keeps an item the listener deleted once the feed
    /// no longer lists it, counted from its deletion
    /// (`FeedItem.deletedDate`): 90 days, except that a read listing none
    /// of the record's items forgets no deletion. Long enough to outlast a
    /// publisher's server that sends an empty or cut-short channel for a
    /// while, and a feed whose window of entries moves back to list older
    /// ones again, either of which would otherwise let the next full read
    /// add the deleted episode anew: unplayed, new, and downloaded again by
    /// the newest-N rule. Short enough that a long-running show's record
    /// does not keep every deletion for ever.
    static let deletedItemRetention: TimeInterval = 90 * 86_400

    /// Merges `feed`, read at `now`, into `record`, keeping `keepEntries` of
    /// its newest entries besides its downloads, its played items, and the
    /// items `keptRecords` names, whose packages were kept after their files
    /// went (-1 keeps all), and reading each text that is needed through
    /// `texts`.
    @discardableResult
    static func merge(
        _ feed: ParsedFeed,
        into record: inout FeedRecord,
        keepEntries: Int,
        now: Date,
        texts: inout FeedTextCache,
        keepingRecordsOf keptRecords: Set<FeedItem.ID> = []
    ) -> MergeResult {
        let before = record.durable
        var result = MergeResult()
        let isFirstRefresh = record.feed.updatedDate == nil
        let newestBefore = record.feed.newestItemDate
        var matcher = ItemMatcher(record.items)

        // Each item the feed lists, matched to the record's or added.
        var candidates: [FeedItem] = []
        var pendingTexts: [FeedItem.ID: (summary: FeedTextSource?, content: FeedTextSource?)] = [:]
        var positions: [FeedItem.ID: Int] = [:]
        var listedIDs = Set<FeedItem.ID>()
        var addedIDs = Set<FeedItem.ID>()
        for parsed in feed.items {
            if var item = matcher.claim(parsed) {
                guard !listedIDs.contains(item.id) else { continue }
                if item.deletedDate == nil {
                    update(&item, from: parsed)
                    pendingTexts[item.id] = (parsed.summary, parsed.content)
                } else {
                    // A deleted item keeps only what finds it again.
                    item.guid = parsed.guid
                    item.enclosure = parsed.enclosure ?? item.enclosure
                }
                listedIDs.insert(item.id)
                positions[item.id] = parsed.position
                candidates.append(item)
            } else {
                let identity = parsed.identity
                guard !listedIDs.contains(identity) else { continue }
                var item = FeedItem(id: identity, title: parsed.title, firstSeen: now)
                update(&item, from: parsed)
                pendingTexts[identity] = (parsed.summary, parsed.content)
                listedIDs.insert(identity)
                addedIDs.insert(identity)
                positions[identity] = parsed.position
                candidates.append(item)
            }
        }
        // Undated items the feed lists behind the items the record knew are
        // back catalog: dated as first seen with the oldest item the record
        // knew, so the feed's order places them, and never new.
        let backCatalogIDs = Self.backCatalog(candidates, addedIDs: addedIDs, positions: positions, isSerial: feed.isSerial)
        if let oldestKnown = candidates.filter({ !addedIDs.contains($0.id) }).map(\.firstSeen).min() {
            for index in candidates.indices where backCatalogIDs.contains(candidates[index].id) {
                candidates[index].firstSeen = oldestKnown
            }
        }
        // The record's items the feed no longer lists: each one the listener
        // has not deleted, for the kept-entries rule, and each deleted one
        // for 90 days after its deletion, so a read that leaves it out once
        // never lets the next one add it back as new. A read that lists none
        // of the record's items at all (an empty or replaced channel, as a
        // server fault sends) keeps every deleted one, however old its
        // deletion: the 90 days count deletions from a feed that went on
        // listing the others, and one empty read must not forget them.
        let listsNoneOfTheRecord = !record.items.isEmpty && candidates.allSatisfy { addedIDs.contains($0.id) }
        candidates += matcher.unclaimed.filter {
            keepsUnlisted($0, at: now, keepingEveryDeletion: listsNoneOfTheRecord)
        }

        // The kept-entries rule.
        var kept = Self.kept(
            candidates,
            keepEntries: keepEntries,
            positions: positions,
            isSerial: feed.isSerial,
            keepingRecordsOf: keptRecords
        )
        for index in kept.indices {
            guard let pending = pendingTexts[kept[index].id] else { continue }
            kept[index].summary = texts.read(pending.summary, keeping: kept[index].summary)
            kept[index].content = texts.read(pending.content, keeping: kept[index].content)
        }
        let keptIDs = Set(kept.map(\.id))

        result.addedItemIDs = kept.filter { addedIDs.contains($0.id) }.map(\.id)
        result.newItemIDs = kept.filter { item in
            guard addedIDs.contains(item.id), !backCatalogIDs.contains(item.id) else { return false }
            if let published = item.published {
                return published > newestBefore
            }
            return !isFirstRefresh
        }.map(\.id)
        result.removedItemIDs = record.items.map(\.id).filter { !keptIDs.contains($0) }

        // The feed's own fields.
        let latest = feed.items
            .compactMap(\.published)
            .filter { $0 <= now.addingTimeInterval(futureDateTolerance) }
            .max()
        record.feed.newestItemDate = max(newestBefore, latest ?? newestBefore)
        if !feed.title.isEmpty {
            record.feed.title = feed.title
        }
        record.feed.siteLink = feed.siteLink ?? record.feed.siteLink
        record.feed.summary = texts.read(feed.summary, keeping: record.feed.summary)
        record.feed.author = feed.author ?? record.feed.author
        record.feed.isSerial = feed.isSerial
        // The feed's size: every entry it lists, each once, the ones the
        // listener deleted among them, and whether it lists more than
        // TextMouth reads of a feed.
        record.feed.entryTotal = FeedEntryTotal(count: listedIDs.count, listsMore: feed.reachedItemLimit)
        record.feed.usesInsecureTransport = FeedTransport.isInsecure(record.feed.feedURL)
            || feed.items.contains { $0.enclosure.map { FeedTransport.isInsecure($0.url) } ?? false }

        if kept != record.items || isFirstRefresh {
            record.items = kept
            record.feed.updatedDate = now
        }
        result.changed = record.durable != before
        return result
    }

    /// The items kept of `candidates` under the kept-entries rule, newest
    /// first: every item downloaded or downloading, and every item moved
    /// into the library (FR11, branch D), whose "In Library" state is what
    /// keeps the feed from downloading it again; every item played, so its
    /// played date is never lost (board #1412), and every item `keptRecords`
    /// names, whose package was kept with the listener's place after its
    /// file went (FR11, branch A2), each listed as a downloaded item is;
    /// every item the listener deleted (`merge` passes those the feed still
    /// lists, and those it no longer lists that `keepsUnlisted(_:at:)`
    /// keeps); and the newest `keepEntries` of the rest, or all when
    /// `keepEntries` is -1.
    static func kept(
        _ candidates: [FeedItem],
        keepEntries: Int,
        positions: [FeedItem.ID: Int],
        isSerial: Bool,
        keepingRecordsOf keptRecords: Set<FeedItem.ID> = []
    ) -> [FeedItem] {
        let ordered = candidates.sortedStably { isNewer($0, than: $1, positions: positions, isSerial: isSerial) }
        var kept: [FeedItem] = []
        var listedKept = 0
        for item in ordered {
            if item.deletedDate != nil {
                kept.append(item)
                continue
            }
            let isWithinNewest = keepEntries < 0 || listedKept < keepEntries
            let holdsTheListenersRecord = item.playedDate != nil || keptRecords.contains(item.id)
            if isWithinNewest || item.state.linkedBookID != nil || item.state.isDownloading || holdsTheListenersRecord {
                kept.append(item)
            }
            listedKept += 1
        }
        return kept
    }

    /// Whether a merge at `now` keeps `item`, which the feed no longer
    /// lists, among the candidates for the kept-entries rule: always when
    /// the listener has not deleted it; when deleted, only until
    /// `deletedItemRetention` has passed since its deletion, so a read that
    /// leaves it out never brings it back later as new, and always while
    /// the read lists none of the record's items (`keepingEveryDeletion`),
    /// which says nothing of what the feed dropped. A deletion dated after
    /// `now`, as another Mac's clock running ahead may date it, is kept.
    ///
    /// The retention counts from the deletion, not from when the feed last
    /// listed the item, which would need a date stored in the feed index
    /// (a follow-up): an item still listed for 120 days after its deletion,
    /// then left out by a read that does list other items, goes at once.
    static func keepsUnlisted(_ item: FeedItem, at now: Date, keepingEveryDeletion: Bool = false) -> Bool {
        guard let deleted = item.deletedDate, !keepingEveryDeletion else { return true }
        return now.timeIntervalSince(deleted) < deletedItemRetention
    }

    /// Whether `item` sorts before `other`, newest first: by date; between
    /// items of the same date, an item the feed lists before one it no
    /// longer lists, which it dropped from its old end, and two it lists by
    /// their place in the feed (top first for an episodic show, bottom first
    /// for a serial one, which lists its first episode first); then by
    /// episode number, a numbered episode first; finally by identity. Each
    /// step compares one part of a key every item has, so the order is
    /// consistent, and never depends on the order items arrived in.
    static func isNewer(_ item: FeedItem, than other: FeedItem, positions: [FeedItem.ID: Int], isSerial: Bool) -> Bool {
        if item.sortDate != other.sortDate {
            return item.sortDate > other.sortDate
        }
        let place = positions[item.id]
        let otherPlace = positions[other.id]
        if (place == nil) != (otherPlace == nil) {
            return place != nil
        }
        if let place, let otherPlace, place != otherPlace {
            return isSerial ? place > otherPlace : place < otherPlace
        }
        let number = item.episodeNumber ?? Int.min
        let otherNumber = other.episodeNumber ?? Int.min
        if number != otherNumber {
            return number > otherNumber
        }
        return item.id < other.id
    }

    /// The undated items of `candidates` this merge added (`addedIDs`) that
    /// the feed lists behind an item the record knew: above the bottom-most
    /// known item of a serial show, which adds episodes at the bottom, or
    /// below the top-most known item of any other. Such an item is older, by
    /// the feed's own order, than an item kept before: the back catalog a
    /// smaller kept-entries number left out.
    static func backCatalog(
        _ candidates: [FeedItem],
        addedIDs: Set<FeedItem.ID>,
        positions: [FeedItem.ID: Int],
        isSerial: Bool
    ) -> Set<FeedItem.ID> {
        let knownPlaces = candidates.filter { !addedIDs.contains($0.id) }.compactMap { positions[$0.id] }
        guard let newestKnownPlace = isSerial ? knownPlaces.max() : knownPlaces.min() else { return [] }
        let behind = candidates.filter { item in
            guard addedIDs.contains(item.id), item.published == nil, let place = positions[item.id] else { return false }
            return isSerial ? place < newestKnownPlace : place > newestKnownPlace
        }
        return Set(behind.map(\.id))
    }

    /// Gives `item` the feed's fields from `parsed`, leaving its texts and
    /// everything the listener did as they are.
    private static func update(_ item: inout FeedItem, from parsed: ParsedItem) {
        item.guid = parsed.guid
        item.title = parsed.title.isEmpty ? item.title : parsed.title
        item.published = parsed.published
        item.enclosure = parsed.enclosure
        item.duration = parsed.duration
        item.link = parsed.link
        item.author = parsed.author
        item.episodeNumber = parsed.episodeNumber
        item.transcripts = parsed.transcripts.isEmpty ? nil : parsed.transcripts
        item.chapters = parsed.chapters
    }
}

// MARK: - Matching Items

/// Finds the record's item that a parsed item is, each record item at most
/// once: by identity, then by guid, then by enclosure address.
private struct ItemMatcher {
    /// The record's items not matched yet, by identity.
    private var byID: [FeedItem.ID: FeedItem] = [:]
    /// The identity of the record's item with each guid.
    private var byGuid: [String: FeedItem.ID] = [:]
    /// The identity of the record's item with each enclosure address.
    private var byEnclosure: [String: FeedItem.ID] = [:]
    /// The record's items in their order, for `unclaimed`.
    private let order: [FeedItem.ID]

    /// A matcher over `items`.
    init(_ items: [FeedItem]) {
        order = items.map(\.id)
        for item in items {
            byID[item.id] = item
            if let guid = item.guid, byGuid[guid] == nil {
                byGuid[guid] = item.id
            }
            if let enclosure = item.enclosure?.url.absoluteString, byEnclosure[enclosure] == nil {
                byEnclosure[enclosure] = item.id
            }
        }
    }

    /// The record's item `parsed` is, taken out of the matcher, or nil when
    /// it is none of them.
    mutating func claim(_ parsed: ParsedItem) -> FeedItem? {
        let candidates = [
            parsed.identity,
            parsed.guid.flatMap { byGuid[$0] },
            parsed.enclosure.flatMap { byEnclosure[$0.url.absoluteString] },
        ]
        for case let id? in candidates {
            if let item = byID.removeValue(forKey: id) {
                return item
            }
        }
        return nil
    }

    /// The record's items no parsed item claimed, in the record's order.
    var unclaimed: [FeedItem] {
        order.compactMap { byID[$0] }
    }
}

// MARK: - Texts Read Once

/// The texts a refresh has read, by the HTML they were read from, so the
/// same text is read once however many merges need it (`FeedReconciler`).
struct FeedTextCache: Sendable {
    /// Each text read, or nil for HTML that reads as nothing.
    private var texts: [String: FeedText?] = [:]

    /// An empty cache.
    init() {}

    /// `source` read, or `kept` when it is the same HTML `kept` was read
    /// from; nil when there is no source.
    mutating func read(_ source: FeedTextSource?, keeping kept: FeedText?) -> FeedText? {
        guard let source, let html = FeedTextConverter.html(for: source) else { return nil }
        if let kept, kept.html == html {
            return kept
        }
        if let cached = texts[html] {
            return cached
        }
        let read = FeedTextConverter.read(html: html)
        texts[html] = read
        return read
    }
}
