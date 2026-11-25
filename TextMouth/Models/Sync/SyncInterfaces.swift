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
    /// one. Inert at `sync/base`: returns the last stamp.
    mutating func next(at now: Date) -> SyncStamp { last }

    /// Moves the clock past `remote`, a stamp merged from another device.
    /// Inert at `sync/base`.
    mutating func observe(_ remote: SyncStamp, at now: Date) {}
}

/// The fields of a book that sync, one register each.
enum SyncBookField: String, Codable, Sendable, CaseIterable {
    case presence, content, title, author, publisher, publicationDate, album, genre, year
    case folder, voice, rate, pitch, skipForward, skipBackward, endOfBook, position, skippedHeadings, lastOpened
}

/// The fields of a folder that sync.
enum SyncFolderField: String, Codable, Sendable { case presence, name, parent }

/// The reading list's options that sync.
enum SyncListOption: String, Codable, Sendable { case continuation, skipsFinished, removesFinished }

/// What a value belongs to: one register of the shared state.
enum SyncKey: Hashable, Codable, Sendable {
    case book(UUID, SyncBookField), bookmark(book: UUID, id: UUID)
    case folder(UUID, SyncFolderField), readingList(book: UUID), readingListOption(SyncListOption)
}

/// One value of one key with its stamp. `.null` is a removal mark.
struct SyncEntry: Codable, Equatable, Sendable {
    var key: SyncKey
    var value: JSONValue
    var stamp: SyncStamp
    /// True when a person made the change (`HandEdits`), which outranks any other.
    var byHand: Bool

    /// Whether this entry beats `other` for the same key: a hand edit first,
    /// then the later stamp. Inert at `sync/base`: always false.
    func outranks(_ other: SyncEntry) -> Bool { false }
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
    /// whose winner changed. Inert at `sync/base`: changes nothing.
    @discardableResult
    mutating func merge(_ incoming: [SyncEntry]) -> Set<SyncKey> { [] }

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

/// The library's syncing values, key by key.
struct SyncProjection: Equatable, Sendable {
    var values: [SyncKey: JSONValue]
    var byHand: Set<SyncKey>

    /// The projection of `library`. Inert at `sync/base`: empty.
    static func of(_ library: Library, contents: [UUID: SyncContent]) -> SyncProjection {
        SyncProjection(values: [:], byHand: [])
    }
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
}

/// The pure merge: what changed locally, and what a merged state does to a library.
enum SyncMerge {
    /// The keys whose values differ between `baseline` and `now`. Inert at `sync/base`: empty.
    static func changes(from baseline: SyncProjection, to now: SyncProjection, atLaunch: Bool) -> [SyncKey: JSONValue] { [:] }

    /// Applies `winners` to `library`; `voices` is the set of voices this
    /// device has, or nil for all. Inert at `sync/base`: the library as it was.
    static func apply(_ winners: SyncRegisters, to library: Library, voices: Set<String>?) -> SyncApplication {
        SyncApplication(library: library, booksToAdd: [], booksToRemove: [], movesPackages: false, entriesToRecord: [:], appliedKeys: [])
    }
}

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
