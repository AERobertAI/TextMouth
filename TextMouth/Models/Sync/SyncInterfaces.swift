import Foundation

// SyncInterfaces.swift: the contract of syncing the library between devices
// (FR43): the first three parts of section 9 of
// research/CLOUD-SYNC-BUILD-PLAN-2026-11-25.md. This file is owned by
// sync-core: only its owner changes it, and the other branches build against
// it. At `sync/base` every body is inert (it returns an empty or default
// value, and never traps); sync-core fills them in.

// MARK: - Stamps, keys, and entries

/// When a change was made and by which device: milliseconds, a counter, and
/// the device ID, compared in that order (a hybrid logical clock), so any two
/// stamps are ordered the same way on every device.
struct SyncStamp: Comparable, Hashable, Codable, Sendable {
    /// Wall-clock milliseconds since 1970.
    var wall: Int64
    /// Tells apart changes of one millisecond.
    var counter: UInt32
    /// The device's ID, the last tie-breaker.
    var device: String

    /// Orders by wall time, then counter, then device ID.
    static func < (lhs: SyncStamp, rhs: SyncStamp) -> Bool {
        (lhs.wall, lhs.counter, lhs.device) < (rhs.wall, rhs.counter, rhs.device)
    }
}

/// A device's hybrid logical clock: stamps its changes, and moves past each
/// stamp it merges.
struct SyncClock: Codable, Sendable {
    /// The latest stamp made or observed.
    private(set) var last: SyncStamp

    /// A clock that has made no stamp yet, for `device`.
    init(device: String) {
        last = SyncStamp(wall: 0, counter: 0, device: device)
    }

    /// The stamp for a change made at `now`: the later of the last stamp and
    /// the clock, so a clock set back never dates a change before an earlier
    /// one. Each call gives a stamp above every earlier one.
    mutating func next(at now: Date) -> SyncStamp {
        let milliseconds = Self.milliseconds(of: now)
        if milliseconds > last.wall {
            // The clock moved on: a fresh millisecond starts its counter again.
            last = SyncStamp(wall: milliseconds, counter: 0, device: last.device)
        } else if last.counter == UInt32.max {
            // The counter is spent (never in practice): the next millisecond takes over.
            last = SyncStamp(wall: last.wall + 1, counter: 0, device: last.device)
        } else {
            // The same millisecond, or a clock set back: the counter orders the change.
            last = SyncStamp(wall: last.wall, counter: last.counter + 1, device: last.device)
        }
        return last
    }

    /// How far ahead of the clock a remote stamp may be and still be taken, a day in milliseconds.
    /// One device whose clock is years ahead must not freeze every other device's time.
    static let maximumAhead: Int64 = 24 * 60 * 60 * 1000

    /// Moves the clock past `remote`, a stamp merged from another device, so
    /// that this device's next change is dated after it. A stamp the clock
    /// is already past changes nothing.
    /// - Returns: false, with the clock unchanged, for a stamp more than `maximumAhead`
    ///   ahead of `now`, which the caller logs; true otherwise.
    @discardableResult
    mutating func observe(_ remote: SyncStamp, at now: Date) -> Bool {
        let milliseconds = Self.milliseconds(of: now)
        guard remote.wall <= milliseconds + Self.maximumAhead else { return false }
        // Only the wall time and counter count here: the device ID is this clock's own.
        guard (remote.wall, remote.counter) >= (last.wall, last.counter) else { return true }
        let wall = max(remote.wall, milliseconds)
        if wall != remote.wall {
            last = SyncStamp(wall: wall, counter: 0, device: last.device)
        } else if remote.counter == UInt32.max {
            // The remote counter is spent: the next millisecond takes over, as `next(at:)` does.
            last = SyncStamp(wall: wall + 1, counter: 0, device: last.device)
        } else {
            last = SyncStamp(wall: wall, counter: remote.counter + 1, device: last.device)
        }
        return true
    }

    /// `date` in whole milliseconds since 1970.
    static func milliseconds(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}

/// The fields of a book that sync, one register each.
enum SyncBookField: String, Codable, Sendable, CaseIterable {
    case presence, content, title, author, publisher, publicationDate, album, genre, year
    case folder, voice, rate, pitch, skipForward, skipBackward, endOfBook, position, skippedHeadings, lastOpened
    /// Keep on All Devices (section 16): `true` or `false`, stamped by `SyncCenter.setKeep`. Never projected
    /// from the library (`SyncProjection.of` leaves it out) and applied to no row (`SyncMerge.apply`).
    case keep
}

/// The fields of a folder that sync.
enum SyncFolderField: String, Codable, Sendable { case presence, name, parent }

/// The fields of a feed (a subscription) that sync (FR56): only what a person
/// decides, never what a refresh reads from the feed, so a refresh writes no
/// entry. A device lacking the feed makes its record from `address`,
/// `subscribed`, and `folder`; research/FR56-FEED-SYNC-2026-11-27.md is the design.
enum SyncFeedField: String, Codable, Sendable, CaseIterable {
    /// `true`, or null for Delete Feed….
    case presence
    /// The address the feed is fetched from (`Feed.feedURL`).
    case address
    /// When the subscription began (`Feed.subscribedDate`), which never changes.
    case subscribed
    /// The library folder the feed lists its episodes in, by ID (`Feed.folderID`).
    case folder
    /// When the listener unsubscribed (`Feed.unsubscribedDate`), or null while subscribed.
    case unsubscribed
    /// The feed's own "List and download" choice (`Feed.itemPolicyOverride`), or null for the global one.
    case itemPolicy
    /// The feed's own days after playing that a download goes, or null for the setting.
    case deleteAfterPlayed
    /// The feed's own listening options (FR19), or null for the standard ones.
    case listening
}

/// The reading list's options that sync.
enum SyncListOption: String, Codable, Sendable { case continuation, skipsFinished, removesFinished }

/// What a value belongs to: one register of the shared state.
enum SyncKey: Hashable, Codable, Sendable {
    case book(UUID, SyncBookField), bookmark(book: UUID, id: UUID)
    case folder(UUID, SyncFolderField), readingList(book: UUID), readingListOption(SyncListOption)
    /// A feed's field (FR56). A TextMouth before it knows no `feed/` key and leaves its entries out.
    case feed(UUID, SyncFeedField)

    /// The key as one line of text, which is how a file holds it and how
    /// keys are sorted: `book/<id>/<field>`, `bookmark/<book id>/<id>`,
    /// `folder/<id>/<field>`, `readingList/<book id>`,
    /// `readingListOption/<option>`, and `feed/<id>/<field>`, with lower-case IDs.
    var text: String {
        switch self {
        case .book(let id, let field): return "book/\(Self.text(of: id))/\(field.rawValue)"
        case .bookmark(let book, let id): return "bookmark/\(Self.text(of: book))/\(Self.text(of: id))"
        case .folder(let id, let field): return "folder/\(Self.text(of: id))/\(field.rawValue)"
        case .readingList(let book): return "readingList/\(Self.text(of: book))"
        case .readingListOption(let option): return "readingListOption/\(option.rawValue)"
        case .feed(let id, let field): return "feed/\(Self.text(of: id))/\(field.rawValue)"
        }
    }

    /// The key `text` names, or nil for text that names none (a key a later
    /// TextMouth added, which an older one leaves out).
    init?(text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch (parts.first, parts.count) {
        case ("book", 3):
            guard let id = UUID(uuidString: parts[1]), let field = SyncBookField(rawValue: parts[2]) else { return nil }
            self = .book(id, field)
        case ("bookmark", 3):
            guard let book = UUID(uuidString: parts[1]), let id = UUID(uuidString: parts[2]) else { return nil }
            self = .bookmark(book: book, id: id)
        case ("folder", 3):
            guard let id = UUID(uuidString: parts[1]), let field = SyncFolderField(rawValue: parts[2]) else { return nil }
            self = .folder(id, field)
        case ("readingList", 2):
            guard let book = UUID(uuidString: parts[1]) else { return nil }
            self = .readingList(book: book)
        case ("readingListOption", 2):
            guard let option = SyncListOption(rawValue: parts[1]) else { return nil }
            self = .readingListOption(option)
        case ("feed", 3):
            guard let id = UUID(uuidString: parts[1]), let field = SyncFeedField(rawValue: parts[2]) else { return nil }
            self = .feed(id, field)
        default:
            return nil
        }
    }

    /// An ID as the lower-case text files hold.
    private static func text(of id: UUID) -> String { id.uuidString.lowercased() }

    /// Reads the key from its text; a text that names no key is a decoding error.
    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let key = SyncKey(text: text) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Not a sync key." // l10n: no (damage reason: what is wrong inside a file stays English)
            ))
        }
        self = key
    }

    /// Writes the key as its text.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

/// One value of one key with its stamp. `.null` is a removal mark.
struct SyncEntry: Codable, Equatable, Sendable {
    var key: SyncKey
    var value: JSONValue
    var stamp: SyncStamp
    /// True when a person made the change (`HandEdits`), which outranks any other.
    var byHand: Bool

    /// Whether this entry beats `other` for the same key: a hand edit first,
    /// then the later stamp. Two entries of one stamp and one kind (which a
    /// correct device never writes) are told apart by their values' text, so
    /// that every device picks the same one.
    func outranks(_ other: SyncEntry) -> Bool {
        if byHand != other.byHand { return byHand }
        if stamp != other.stamp { return stamp > other.stamp }
        return SyncValueCoding.canonicalText(of: value) > SyncValueCoding.canonicalText(of: other.value)
    }
}

/// Every key's winning entry, and the last outbox file merged into them.
struct SyncRegisters: Codable, Equatable, Sendable {
    /// The winning entry of each key.
    private(set) var entries: [SyncKey: SyncEntry]
    /// The last outbox file (`seq`) in these registers.
    var throughSeq: Int

    /// Registers holding `entries`, none by default.
    init(entries: [SyncKey: SyncEntry] = [:], throughSeq: Int = 0) {
        self.entries = entries
        self.throughSeq = throughSeq
    }

    /// Merges `incoming`, each key keeping its highest entry; returns the keys
    /// whose winner changed. Any order of merging gives the same registers,
    /// and merging an entry again changes nothing.
    @discardableResult
    mutating func merge(_ incoming: [SyncEntry]) -> Set<SyncKey> {
        var changed = Set<SyncKey>()
        for entry in incoming {
            if let current = entries[entry.key], !entry.outranks(current) { continue }
            entries[entry.key] = entry
            changed.insert(entry.key)
        }
        return changed
    }

    // A dictionary keyed by an enum with payloads does not encode as a JSON
    // object, so the entries are stored as an array.
    private enum CodingKeys: String, CodingKey { case entries, throughSeq }

    /// Reads the entry list into the dictionary.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let list = try container.decode([SyncEntry].self, forKey: .entries)
        entries = Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        throughSeq = try container.decode(Int.self, forKey: .throughSeq)
    }

    /// Writes the entries as a list, in stamp order so the same registers write the same bytes.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let list = entries.values.sorted { ($0.stamp, "\($0.key)") < ($1.stamp, "\($1.key)") }
        try container.encode(list, forKey: .entries)
        try container.encode(throughSeq, forKey: .throughSeq)
    }
}

// MARK: - Projection and merge

/// What a device lacking a book makes its row from; only `manifest` is compared.
struct SyncContent: Codable, Equatable, Sendable {
    var manifest: String
    var format: BookFormat
    var dateAdded: Date
    var md5Hash: String
    var totalWordCount: Int?
    var audioDuration: TimeInterval?
}

/// A book another device added, with what its row is made from.
struct SyncNewBook: Sendable {
    var book: Book
    var content: SyncContent
}

/// What applying a merge does to the library.
struct SyncApplication: Sendable {
    var library: Library
    var booksToAdd: [SyncNewBook]
    var booksToRemove: [UUID]
    /// True when packages move, so the change goes through `performLibraryTransition`.
    var movesPackages: Bool
    /// Entries to record, as same-named folders are folded.
    var entriesToRecord: [SyncKey: JSONValue]
    var appliedKeys: Set<SyncKey>
    /// What the merge does to the feeds (FR56); nothing for a merge made without them.
    var feeds = SyncFeedApplication()
}

/// What applying a merge does to the feeds (FR56), for the feed store to
/// carry out (`FeedCenter.applySync(_:)`). Each feed is given whole, as the
/// winners make it from this device's own record, so the host writes only
/// the synced fields of it.
struct SyncFeedApplication: Equatable, Sendable {
    /// Feeds another device subscribed to, which this device lacks: a record
    /// each, made from their address, date, and folder, with their settings.
    var feedsToAdd: [Feed] = []
    /// Feeds of this device whose synced fields the winners change.
    var feedsToChange: [Feed] = []
    /// Feeds another device deleted (Delete Feed…), by ID, in ID order.
    var feedsToRemove: [UUID] = []
    /// The feeds to change and to remove as this device had them when the merge was made, by
    /// ID: a feed a person changed since keeps their change, and its keys are offered again.
    var startFeeds: [UUID: Feed] = [:]
    /// True when the merge was made without the feeds (the host's not loaded yet) while the
    /// winners hold feed keys: none of those was applied, so the host applies again later.
    var waitsForFeeds = false

    /// Whether the merge changes no feed.
    var isEmpty: Bool { feedsToAdd.isEmpty && feedsToChange.isEmpty && feedsToRemove.isEmpty }
}

/// The pure merge: what changed locally, and what a merged state does to a
/// library. `changes(from:to:atLaunch:)` is in SyncProjection.swift and
/// `apply(_:to:voices:)` in SyncApplier.swift.
enum SyncMerge {}

// MARK: - Stored formats

/// `store.json`: names the sync folder's store.
struct SyncStoreFile: Codable, Equatable, Sendable {
    var formatVersion: Int
    var storeID: UUID
    var created: Date
    var createdBy, createdByVersion: String
}

/// `Devices/<id>/device.json`: the one file a device replaces.
struct SyncDeviceFile: Codable, Equatable, Sendable {
    var formatVersion: Int
    var deviceID, name, platform, appVersion: String
    var lastSeq: Int
    var updated: Date
}

/// `<seq>.changes.json` and `<seq>.snapshot.json`.
struct SyncChangeFile: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case changes, snapshot }
    var formatVersion: Int
    var deviceID: String
    var incarnation: UUID
    var seq: Int
    var kind: Kind
    var count: Int
    var entries: [SyncEntry]
}

/// `Books/<id>/<sha256>.manifest.json`: a book's files and their blobs.
struct StoreManifest: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        /// `role` is content, record, or other.
        var path, sha256, blob, role: String
        var size: Int64
    }
    var formatVersion: Int
    var bookID: UUID
    var files: [File]
}

/// `.storeCopy.json` in a book's package: its manifest and which files are here.
struct StorePointer: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        var path, sha256: String
        var size, modified: Int64
        var onThisDevice: Bool
    }
    var formatVersion: Int
    var storeID, bookID: UUID
    var manifest: String
    var uploaded: String?
    var files: [File]
    static let fileName = ".storeCopy.json"
}
