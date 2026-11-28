import Foundation

// SyncFeedValues.swift: how each field of a feed that syncs is read from a
// subscription and written to it (FR56). Pure: no file, no clock. The
// projection reads through these, and the applier reads (to see whether a
// value differs) and writes through them, so one place says what a field is.

/// The feed's own "List and download" choice (FR11) as an entry holds it:
/// the choice's name and its number. `FeedItemPolicy` itself is not
/// `Codable`, and a choice a later TextMouth adds must read as none here.
struct SyncFeedItemPolicyValue: Codable, Equatable, Sendable {
    /// The choice's raw name (`FeedItemPolicy.Choice`).
    var choice: String
    /// How many of the newest entries the choice counts.
    var newestCount: Int

    /// The value of `policy`.
    init(_ policy: FeedItemPolicy) {
        choice = policy.choice.rawValue
        newestCount = policy.newestCount
    }

    /// The policy the value names, or nil for a choice this TextMouth doesn't know.
    var policy: FeedItemPolicy? {
        FeedItemPolicy.Choice(rawValue: choice).map { FeedItemPolicy(choice: $0, newestCount: newestCount) }
    }
}

/// How each field of a feed that syncs is read and written (FR56).
enum SyncFeedValues {
    /// The fields a device lacking the feed makes its record from, besides `presence`.
    static let originFields: [SyncFeedField] = [.address, .subscribed, .folder]

    /// The fields read from the feed alone and written back to it: every field but
    /// `presence` and `folder`, which need the library's folders, and `subscribed`,
    /// which never changes once the record is made.
    static let feedFields: [SyncFeedField] = [.address, .unsubscribed, .itemPolicy, .deleteAfterPlayed, .listening]

    /// The value of `field` in `feed`. `presence` is `true`, as every feed held is.
    static func value(of field: SyncFeedField, in feed: Feed, using encoder: JSONEncoder? = nil) -> JSONValue {
        switch field {
        case .presence: return .bool(true)
        case .address: return .string(feed.feedURL.absoluteString)
        case .subscribed: return SyncValueCoding.json(date: feed.subscribedDate, using: encoder)
        case .folder: return SyncValueCoding.id(feed.folderID)
        case .unsubscribed: return SyncValueCoding.json(date: feed.unsubscribedDate, using: encoder)
        case .itemPolicy:
            return feed.itemPolicyOverride.map { SyncValueCoding.json(SyncFeedItemPolicyValue($0), using: encoder) } ?? .null
        case .deleteAfterPlayed:
            return feed.deleteDownloadsDaysAfterPlayedOverride.map { .integer(Int64($0)) } ?? .null
        case .listening:
            // Standard options are never stored (`FeedCenter.setListeningOptions`), and read as none here too.
            guard let options = feed.listeningOptions, !options.isStandard else { return .null }
            return SyncValueCoding.json(options, using: encoder)
        }
    }

    /// Every synced value of `feeds`, key by key: the feeds' part of a projection
    /// (`SyncProjection.of`), and what the host compares to know whether a change of
    /// the records is one the sync records at all.
    static func values(of feeds: [Feed], using encoder: JSONEncoder? = nil) -> [SyncKey: JSONValue] {
        var values: [SyncKey: JSONValue] = [:]
        for feed in feeds {
            for field in SyncFeedField.allCases {
                values[.feed(feed.id, field)] = value(of: field, in: feed, using: encoder)
            }
        }
        return values
    }

    /// Writes `value` to `field` of `feed`, one of `feedFields`. Returns false,
    /// changing nothing, for a value the field cannot hold (an address that is
    /// no web address, a choice this TextMouth doesn't know) or for a field
    /// the feed alone does not hold.
    @discardableResult
    static func set(_ field: SyncFeedField, to value: JSONValue, in feed: inout Feed) -> Bool {
        switch field {
        case .address:
            guard let text = value.stringValue, let url = URL(string: text), FeedTransport.isWebAddress(url) else { return false }
            feed.feedURL = url
        case .unsubscribed:
            guard let date = optionalDate(value) else { return false }
            feed.unsubscribedDate = date
        case .itemPolicy:
            if value == .null {
                feed.itemPolicyOverride = nil
            } else {
                guard let policy = SyncValueCoding.decode(SyncFeedItemPolicyValue.self, from: value)?.policy else { return false }
                feed.itemPolicyOverride = policy
            }
        case .deleteAfterPlayed:
            if value == .null {
                feed.deleteDownloadsDaysAfterPlayedOverride = nil
            } else {
                guard case .integer(let days) = value, let whole = Int(exactly: days) else { return false }
                feed.deleteDownloadsDaysAfterPlayedOverride = SettingsPolicy.feedDeleteDownloadsDaysAfterPlayed.validated(whole)
            }
        case .listening:
            if value == .null {
                feed.listeningOptions = nil
            } else {
                guard let options = SyncValueCoding.decode(ListeningOptions.self, from: value) else { return false }
                feed.listeningOptions = options.isStandard ? nil : options
            }
        case .presence, .subscribed, .folder:
            return false
        }
        return true
    }

    /// The date `value` holds, `.some(nil)` for `.null`, or nil for a value that is neither.
    private static func optionalDate(_ value: JSONValue) -> Date?? {
        if value == .null { return .some(nil) }
        return SyncValueCoding.date(from: value).map { .some($0) }
    }

    /// `value` of `field` as the projection and the applier compare it: a
    /// setting read through its own type and written again, so a value
    /// differing only in a field a later TextMouth added is the same value
    /// here (V04), and this device neither applies it nor records a copy
    /// without that field. A value its type can't read is compared as it is.
    static func comparable(_ value: JSONValue, of field: SyncFeedField) -> JSONValue {
        switch field {
        case .itemPolicy:
            guard value != .null, let read = SyncValueCoding.decode(SyncFeedItemPolicyValue.self, from: value) else { return value }
            return SyncValueCoding.json(read)
        case .listening:
            guard value != .null, let read = SyncValueCoding.decode(ListeningOptions.self, from: value) else { return value }
            return read.isStandard ? .null : SyncValueCoding.json(read)
        default:
            return value
        }
    }

    /// The record of a feed this device lacks, made from its winning values:
    /// its address, when it began, and its folder (`folderID`, as the folder
    /// plan lands it), with its settings written on. Nil when the address or
    /// the date is missing or unreadable, so the feed waits for them.
    static func makeFeed(id: UUID, values: [SyncFeedField: JSONValue], folderID: UUID) -> Feed? {
        guard let text = values[.address]?.stringValue, let url = URL(string: text), FeedTransport.isWebAddress(url),
              let subscribed = values[.subscribed].flatMap(SyncValueCoding.date(from:)) else { return nil }
        var feed = Feed(id: id, feedURL: url, folderID: folderID, subscribedDate: subscribed)
        // `newestItemDate` is the subscription's date here; the host moves it to when the feed
        // arrived (`FeedCenter.applySync`), so the episodes already out are not new on this device.
        for field in feedFields where field != .address {
            if let value = values[field] { set(field, to: value, in: &feed) }
        }
        return feed
    }
}
