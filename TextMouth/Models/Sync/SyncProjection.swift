import Foundation

// SyncProjection.swift: the library as sync keys and values, and what changed
// between two such projections (FR43). Pure: no file, no clock, no randomness.

// MARK: - A book's fields as values

/// How each field of a book that syncs is read from a row and written to it.
/// The projection reads, and the applier reads (to see whether a value
/// differs) and writes, through these, so one place says what a field is.
enum SyncBookValues {
    /// The hand-edit field a detail of a book is, or nil for a field that is no detail.
    static func metadataField(of field: SyncBookField) -> Book.MetadataField? {
        switch field {
        case .title: return .title
        case .author: return .author
        case .publisher: return .publisher
        case .publicationDate: return .publicationDate
        case .album: return .audioAlbum
        case .genre: return .audioGenre
        case .year: return .audioYear
        default: return nil
        }
    }

    /// The fields read from the row alone, in a fixed order: every field but
    /// `presence`, `content`, `folder` (which need the library or the store),
    /// and `keep` (which a person sets and no row holds).
    static let rowFields: [SyncBookField] = SyncBookField.allCases.filter {
        ![.presence, .content, .folder, .keep].contains($0)
    }

    /// The value of `field` in `book`, or nil for a field the row alone does not give.
    static func value(of field: SyncBookField, in book: Book, using encoder: JSONEncoder? = nil) -> JSONValue? {
        switch field {
        case .title: return .string(book.title)
        case .author: return .string(book.author)
        case .publisher: return SyncValueCoding.string(book.epubPublisher)
        case .publicationDate: return SyncValueCoding.string(book.epubPublicationDate)
        case .album: return SyncValueCoding.string(book.audioAlbum)
        case .genre: return SyncValueCoding.string(book.audioGenre)
        case .year: return SyncValueCoding.string(book.audioYear)
        case .voice: return SyncValueCoding.string(book.localVoiceID)
        case .rate: return SyncValueCoding.number(book.localWPM)
        case .pitch: return SyncValueCoding.number(book.localPitch)
        case .skipForward: return SyncValueCoding.string(book.localSkipForwardUnit)
        case .skipBackward: return SyncValueCoding.string(book.localSkipBackwardUnit)
        case .endOfBook: return SyncValueCoding.string(book.localEndOfBookBehavior)
        case .position: return book.readingPosition.map { SyncValueCoding.json($0, using: encoder) } ?? .null
        case .skippedHeadings: return SyncValueCoding.json(SyncSkippedHeadingsValue(book), using: encoder)
        case .lastOpened: return SyncValueCoding.json(date: book.lastOpened, using: encoder)
        case .presence, .content, .folder, .keep: return nil
        }
    }

    /// Writes `value` to `field` of `book`. Returns false, changing nothing,
    /// for a value the field cannot hold (text where a number belongs, or no
    /// title) or a field the row alone does not hold.
    @discardableResult
    static func set(_ field: SyncBookField, to value: JSONValue, in book: inout Book) -> Bool {
        switch field {
        case .title:
            guard let text = value.stringValue else { return false }
            book.title = text
        case .author:
            guard let text = value.stringValue else { return false }
            book.author = text
        case .publisher: return setText(value) { book.epubPublisher = $0 }
        case .publicationDate: return setText(value) { book.epubPublicationDate = $0 }
        case .album: return setText(value) { book.audioAlbum = $0 }
        case .genre: return setText(value) { book.audioGenre = $0 }
        case .year: return setText(value) { book.audioYear = $0 }
        case .voice: return setText(value) { book.localVoiceID = $0 }
        case .skipForward: return setText(value) { book.localSkipForwardUnit = $0 }
        case .skipBackward: return setText(value) { book.localSkipBackwardUnit = $0 }
        case .endOfBook: return setText(value) { book.localEndOfBookBehavior = $0 }
        case .rate: return setNumber(value) { book.localWPM = $0 }
        case .pitch: return setNumber(value) { book.localPitch = $0 }
        case .position:
            if value == .null {
                book.readingPosition = nil
            } else {
                guard let place = SyncValueCoding.decode(ReadingPosition.self, from: value) else { return false }
                book.readingPosition = place.keepingUnknownKeys(ofSamePlaceIn: book.readingPosition)
            }
        case .skippedHeadings:
            guard let lists = SyncValueCoding.decode(SyncSkippedHeadingsValue.self, from: value) else { return false }
            lists.write(to: &book)
        case .lastOpened:
            if value == .null {
                book.lastOpened = nil
            } else {
                guard let date = SyncValueCoding.date(from: value) else { return false }
                book.lastOpened = date
            }
        case .presence, .content, .folder, .keep:
            return false
        }
        return true
    }

    /// Passes the text `value` holds, or nil for `.null`, to `store`; false for any other value.
    private static func setText(_ value: JSONValue, _ store: (String?) -> Void) -> Bool {
        switch value {
        case .null: store(nil)
        case .string(let text): store(text)
        default: return false
        }
        return true
    }

    /// Passes the number `value` holds, or nil for `.null`, to `store`; false for any other value.
    private static func setNumber(_ value: JSONValue, _ store: (Double?) -> Void) -> Bool {
        if value == .null {
            store(nil)
            return true
        }
        guard let number = SyncValueCoding.double(from: value) else { return false }
        store(number)
        return true
    }

    /// The value of a book's content, as the entry holds it.
    static func value(of content: SyncContent) -> JSONValue {
        SyncValueCoding.json(content)
    }
}

// MARK: - Keys

extension SyncKey {
    /// The book a key is about: the book's own fields, its bookmarks, and its place on the reading list.
    var bookID: UUID? {
        switch self {
        case .book(let id, _): return id
        case .bookmark(let book, _): return book
        case .readingList(let book): return book
        case .folder, .readingListOption, .feed: return nil
        }
    }

    /// The folder a key is about, or nil.
    var folderID: UUID? {
        if case .folder(let id, _) = self { return id }
        return nil
    }

    /// The feed a key is about (FR56), or nil.
    var feedID: UUID? {
        if case .feed(let id, _) = self { return id }
        return nil
    }

    /// Whether `value`, under this key, is a removal mark: of a book or a
    /// bookmark or a place on the reading list or a feed (`.null`), or of a folder
    /// (`.null`, or the ID of the folder it was folded into). Any other
    /// `.null` is a value that is none (a detail cleared, say).
    func marksRemoval(_ value: JSONValue) -> Bool {
        switch self {
        case .book(_, .presence), .bookmark, .readingList, .feed(_, .presence): return value == .null
        case .folder(_, .presence): return value == .null || value.stringValue != nil
        default: return false
        }
    }
}

// MARK: - Projecting a library

/// The folder tree of a library, by ID and by path, since a book names its
/// folder by path and the sync names it by ID.
struct SyncFolderIndex: Sendable {
    /// The folders' IDs by their full paths.
    private(set) var idByPath: [String: UUID] = [:]

    /// The index of `folders`.
    init(_ folders: [BookFolder]) {
        for folder in folders { idByPath[folder.fullPath] = folder.id }
    }

    /// The ID of the folder at `path`; nil for the top level and for a path no folder has.
    func id(atPath path: String) -> UUID? { idByPath[path] }
}

/// The library's syncing values, key by key: the projection of a library
/// (`of(_:contents:)`), and the baseline, the projection as last recorded or
/// applied, which the changes are measured from.
///
/// A baseline is kept only through `absorb(_:)` (what this device recorded)
/// and `absorbApplied(_:from:)` (what an apply took from the winners):
/// removals are forgotten, hand edits noted, and each book's place on the
/// reading list kept as its order key. The values cannot be set from outside,
/// so a caller cannot keep one wrongly. A baseline is saved and read as
/// itself (`Codable`).
struct SyncProjection: Equatable, Sendable {
    /// Each key's value. A book's place on the reading list is its order, a
    /// whole number, in the projection of a library, and its order key, a
    /// string, in a baseline; `SyncMerge.changes` knows both.
    private(set) var values: [SyncKey: JSONValue]
    /// The keys a person edited by hand (`HandEdits`).
    private(set) var byHand: Set<SyncKey>
    /// True for a projection made without the feeds (FR56), because the host
    /// had none to give (its feeds not loaded yet, or a host without feeds):
    /// it holds no `feed/` key, and `SyncMerge.changes` then reports no feed
    /// key at all, rather than every feed as removed. Never true in a baseline.
    private(set) var leavesFeedsAlone = false

    /// A projection holding nothing: the baseline of a library never recorded.
    init() {
        values = [:]
        byHand = []
    }

    /// A projection of `values`, for `of(_:contents:feeds:)` and for tests.
    fileprivate init(values: [SyncKey: JSONValue], byHand: Set<SyncKey>, leavesFeedsAlone: Bool = false) {
        self.values = values
        self.byHand = byHand
        self.leavesFeedsAlone = leavesFeedsAlone
    }

    // MARK: Keeping a baseline

    /// Takes `entries`, which this device just stamped and recorded, into the
    /// baseline: each key's value, whether a person made it, and, for a
    /// removal mark, the removal. A removed book or folder takes all its
    /// keys with it.
    mutating func absorb(_ entries: [SyncEntry]) {
        for entry in entries { absorb(entry) }
    }

    /// Takes the winning entries of `keys` from `winners`, which an apply
    /// has just put in the library (`SyncApplication.appliedKeys`, or what
    /// the host's `applySync` returned). A key with no winner is left alone.
    mutating func absorbApplied(_ keys: Set<SyncKey>, from winners: SyncRegisters) {
        for key in keys.sorted(by: { $0.text < $1.text }) {
            if let entry = winners.entries[key] { absorb(entry) }
        }
    }

    /// Takes one entry, as `absorb(_:)` does.
    private mutating func absorb(_ entry: SyncEntry) {
        if entry.byHand { byHand.insert(entry.key) } else { byHand.remove(entry.key) }
        if entry.key.marksRemoval(entry.value) {
            forget(entry.key)
        } else {
            values[entry.key] = entry.value
        }
    }

    /// Forgets the key a removal mark is for, and, for a book or a folder, all its keys.
    fileprivate mutating func forget(_ key: SyncKey) {
        switch key {
        case .book(let id, .presence):
            for gone in values.keys.filter({ $0.bookID == id }) { values[gone] = nil; byHand.remove(gone) }
        case .folder(let id, .presence):
            for gone in values.keys.filter({ $0.folderID == id }) { values[gone] = nil; byHand.remove(gone) }
        case .feed(let id, .presence):
            for gone in values.keys.filter({ $0.feedID == id }) { values[gone] = nil; byHand.remove(gone) }
        default:
            values[key] = nil
            byHand.remove(key)
        }
    }

    // MARK: Saving a baseline

    /// How a baseline is written: its values and hand-edited keys as sorted lists, so the same
    /// baseline is always the same bytes, and a key a later TextMouth added is left out.
    private struct Stored: Codable {
        struct Pair: Codable {
            var key: SyncKey
            var value: JSONValue
        }
        var values: [Pair]
        var byHand: [SyncKey]
    }
}

extension SyncProjection: Codable {
    /// Reads a baseline written by `encode(to:)`.
    init(from decoder: Decoder) throws {
        let stored = try Stored(from: decoder)
        values = Dictionary(stored.values.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
        byHand = Set(stored.byHand)
    }

    /// Writes the baseline in a fixed order.
    func encode(to encoder: Encoder) throws {
        let stored = Stored(
            values: values.sorted { $0.key.text < $1.key.text }.map { Stored.Pair(key: $0.key, value: $0.value) },
            byHand: byHand.sorted { $0.text < $1.text }
        )
        try stored.encode(to: encoder)
    }
}

extension SyncProjection {
    /// The projection of `library`: a key for each value the sync keeps.
    /// - Parameters:
    ///   - contents: the uploaded content of the books that have any; a book
    ///     without it has no `content` key yet.
    ///   - feeds: the subscriptions (FR56), or nil when the host has none to give yet (its feed
    ///     store not loaded): the projection then holds no feed key and leaves the feeds alone.
    /// - Note: A book's place on the reading list is its order, a whole number.
    ///   Feed items are left out, and so is `keep`, which no row holds.
    static func of(_ library: Library, contents: [UUID: SyncContent], feeds: [Feed]? = nil) -> SyncProjection {
        var values: [SyncKey: JSONValue] = [:]
        var byHand = Set<SyncKey>()
        let index = SyncFolderIndex(library.folders)
        // One encoder for the whole library: making one for each value is the cost of a projection.
        let encoder = SyncValueCoding.makeEncoder()

        // Folders: that they exist, their names, and their parents.
        for folder in library.folders {
            values[.folder(folder.id, .presence)] = .bool(true)
            values[.folder(folder.id, .name)] = .string(folder.name)
            values[.folder(folder.id, .parent)] = SyncValueCoding.id(index.id(atPath: folder.parentPath))
        }

        // Books, their fields, and their bookmarks. A feed item is no book of the library's own.
        var bookIDs = Set<UUID>()
        for book in library.books where !book.isFeedItem {
            bookIDs.insert(book.id)
            values[.book(book.id, .presence)] = .bool(true)
            if let content = contents[book.id] {
                values[.book(book.id, .content)] = SyncValueCoding.json(content, using: encoder)
            }
            values[.book(book.id, .folder)] = SyncValueCoding.id(index.id(atPath: book.folderPath))
            for field in SyncBookValues.rowFields {
                values[.book(book.id, field)] = SyncBookValues.value(of: field, in: book, using: encoder)
                // The details a person edited by hand outrank any other change to them.
                if let edited = SyncBookValues.metadataField(of: field), book.handEdits?.contains(edited) == true {
                    byHand.insert(.book(book.id, field))
                }
            }
            for bookmark in book.bookmarks {
                values[.bookmark(book: book.id, id: bookmark.id)] = SyncValueCoding.json(SyncBookmarkValue(bookmark), using: encoder)
            }
        }

        // The reading list: each book's order, and the list's options.
        for (order, id) in library.readingList.bookIDs.enumerated() where bookIDs.contains(id) {
            values[.readingList(book: id)] = .integer(Int64(order))
        }
        values[.readingListOption(.continuation)] = .string(library.readingList.continuation.rawValue)
        values[.readingListOption(.skipsFinished)] = .bool(library.readingList.skipsFinished)
        values[.readingListOption(.removesFinished)] = .bool(library.readingList.removesFinished)

        // The feeds: what a person decided of each, never what a refresh read (FR56).
        guard let feeds else { return SyncProjection(values: values, byHand: byHand, leavesFeedsAlone: true) }
        values.merge(SyncFeedValues.values(of: feeds, using: encoder), uniquingKeysWith: { _, feed in feed })
        return SyncProjection(values: values, byHand: byHand)
    }
}

// MARK: - Comparing values

extension SyncValueCoding {
    /// `value` as `changes` and the applier compare it: without what TextMouth
    /// rewrites without the person moving anything. A place is its chapter, offset,
    /// and date; a bookmark and a skipped heading are without their anchors (the words
    /// around them, which a reader gives a place it opens and a launch gives every
    /// place); and a place's heading index and global offset are left out.
    static func comparable(_ value: JSONValue, for key: SyncKey) -> JSONValue {
        switch key {
        case .book(_, .position):
            guard case .object(let members) = value else { return value }
            return .object(members.filter { ["chapterIndex", "characterOffset", "lastUpdated"].contains($0.key) })
        case .bookmark:
            guard case .object(var members) = value else { return value }
            members["anchor"] = nil
            return .object(members)
        case .book(_, .skippedHeadings):
            guard case .object(var members) = value else { return value }
            for list in ["skipped", "waiting"] {
                guard case .array(let items)? = members[list] else { continue }
                members[list] = .array(items.map { item in
                    guard case .object(var skip) = item else { return item }
                    skip["anchor"] = nil
                    return .object(skip)
                })
            }
            return .object(members)
        case .feed(_, let field):
            // A feed's setting through its own type, so a field a later TextMouth added is no change (V04).
            return SyncFeedValues.comparable(value, of: field)
        default:
            return value
        }
    }

    /// Whether `left` and `right` are one value of `key`, as `comparable(_:for:)` reads them.
    static func isSame(_ left: JSONValue, _ right: JSONValue, for key: SyncKey) -> Bool {
        left == right || comparable(left, for: key) == comparable(right, for: key)
    }
}

// MARK: - What was missing at launch

/// The books and folders that were missing when TextMouth started, which the
/// sync puts back and never reports as removed (rule R7: a removal crosses
/// only when a person made it in a running TextMouth).
///
/// One value for each run of the app, not saved. At the first record after
/// launch it learns which book and folder keys the baseline holds that the
/// library lacks; those stay held, however many records are made, until the
/// first apply after launch has had its chance to put them back (the books
/// whose content is in the store come back). Then `settle` forgets the ones
/// still missing, silently. A book a person removes in the running app is
/// not held: it was in the library when the app started.
struct SyncLaunchHold: Sendable {
    /// The keys held back: presence keys of books, folders, and feeds missing at launch.
    private(set) var held: Set<SyncKey> = []
    /// Whether the launch has been looked at.
    private var hasObserved = false
    /// Whether the feeds have been looked at (FR56). The host gives them only once its feed
    /// store has loaded, which may be after the first record, so they are looked at, held,
    /// and settled on their own: at the first record and the first settle that have them.
    private var hasObservedFeeds = false
    /// Whether the feeds' hold has ended.
    private var hasSettledFeeds = false

    init() {}

    /// Looks at the library as it stands at launch: the first call holds the books and
    /// folders the baseline has and `now` lacks, and the first call whose `now` has the
    /// feeds holds the feeds the same way. Later calls do nothing.
    mutating func observeLaunch(baseline: SyncProjection, now: SyncProjection) {
        let observesFeeds = !hasObservedFeeds && !now.leavesFeedsAlone
        guard !hasObserved || observesFeeds else { return }
        let observesLibrary = !hasObserved
        hasObserved = true
        if observesFeeds { hasObservedFeeds = true }
        held.formUnion(baseline.values.keys.filter { key in
            switch key {
            case .book(_, .presence), .folder(_, .presence): return observesLibrary && now.values[key] == nil
            case .feed(_, .presence): return observesFeeds && now.values[key] == nil
            default: return false
            }
        })
    }

    /// Ends the hold after the first apply after launch: a held key that is still missing from
    /// `now` is dropped from `baseline`, so it is neither put back nor reported as removed.
    /// The feeds' keys wait for a settle whose `now` has the feeds and follows their observing.
    mutating func settle(baseline: inout SyncProjection, now: SyncProjection) {
        let settlesFeeds = hasObservedFeeds && !now.leavesFeedsAlone
        for key in held {
            let isFeed = key.feedID != nil
            if isFeed && !settlesFeeds { continue }
            if now.values[key] == nil { baseline.forget(key) }
            held.remove(key)
        }
        if settlesFeeds { hasSettledFeeds = true }
    }

    /// Whether the feeds' hold has yet to end (FR56): the host asks for another settle after
    /// an apply that had the feeds.
    var awaitsFeeds: Bool { !hasSettledFeeds }
}

// MARK: - What changed

extension SyncMerge {
    /// The keys whose values differ between `baseline` (the library as last
    /// recorded or applied) and `now`, with the value each has now: the
    /// entries to stamp. A book or folder gone from `now` is a `.null`
    /// presence, and so is a bookmark or a place on the reading list; the
    /// other keys of a vanished book are not reported.
    ///
    /// - Parameter atLaunch: true to report no removal of a book or folder at all, for a caller that
    ///   has only this one call to make (rule R7). A running app uses `changes(from:to:hold:)`.
    /// - Note: The reading list is compared by order: `baseline` holds each
    ///   book's order key, `now` its place in the list, and only a book that
    ///   was moved or added is given a key (`SyncOrderKey.assign`). A place
    ///   or bookmark that differs only in its anchor is no change.
    static func changes(from baseline: SyncProjection, to now: SyncProjection, atLaunch: Bool) -> [SyncKey: JSONValue] {
        changes(from: baseline, to: now, reportsRemovalOfBooksAndFolders: !atLaunch, holding: [])
    }

    /// The changes as `changes(from:to:atLaunch:)` finds them, except that the keys `hold` holds
    /// are not reported as removed, whatever record this is.
    static func changes(from baseline: SyncProjection, to now: SyncProjection, hold: SyncLaunchHold) -> [SyncKey: JSONValue] {
        changes(from: baseline, to: now, reportsRemovalOfBooksAndFolders: true, holding: hold.held)
    }

    /// The one implementation of both forms.
    private static func changes(
        from baseline: SyncProjection, to now: SyncProjection,
        reportsRemovalOfBooksAndFolders reportsRemoval: Bool, holding held: Set<SyncKey>
    ) -> [SyncKey: JSONValue] {
        var changes: [SyncKey: JSONValue] = [:]

        // Values that are new or different, and details a person has newly edited by hand.
        for (key, value) in now.values {
            if case .readingList = key { continue }
            let known = baseline.values[key]
            let differs = known.map { !SyncValueCoding.isSame($0, value, for: key) } ?? true
            if differs || (now.byHand.contains(key) && !baseline.byHand.contains(key)) {
                changes[key] = value
            }
        }

        // What was in the baseline and is gone.
        for (key, stored) in baseline.values where now.values[key] == nil {
            // A removal already in the baseline is not reported again.
            if stored == .null, key.marksRemoval(.null) { continue }
            switch key {
            case .feed(_, .presence):
                // A projection without the feeds says nothing of them (FR56); a feed missing at launch is put back.
                if reportsRemoval && !now.leavesFeedsAlone && !held.contains(key) { changes[key] = .null }
            case .book(_, .presence), .folder(_, .presence):
                // A book or folder missing at launch is put back, not removed.
                if reportsRemoval && !held.contains(key) { changes[key] = .null }
            case .bookmark(let book, _):
                // A vanished book takes its bookmarks with it.
                if now.values[.book(book, .presence)] != nil { changes[key] = .null }
            case .readingList(let book):
                if now.values[.book(book, .presence)] != nil { changes[key] = .null }
            default:
                break
            }
        }

        changes.merge(readingListChanges(from: baseline, to: now), uniquingKeysWith: { _, new in new })
        return changes
    }

    /// The reading list's changes: a key for each book added or moved, and a
    /// removal mark for each book that left the list.
    private static func readingListChanges(from baseline: SyncProjection, to now: SyncProjection) -> [SyncKey: JSONValue] {
        var changes: [SyncKey: JSONValue] = [:]
        var baselineKeys: [UUID: String] = [:]
        for (key, value) in baseline.values {
            if case .readingList(let book) = key, let order = value.stringValue { baselineKeys[book] = order }
        }
        // The list as it stands now, in order.
        let order: [UUID] = now.values.compactMap { key, value -> (UUID, Int64)? in
            if case .readingList(let book) = key, case .integer(let place) = value { return (book, place) }
            return nil
        }
        .sorted { ($0.1, $0.0.uuidString) < ($1.1, $1.0.uuidString) }
        .map(\.0)

        for (book, key) in SyncOrderKey.assign(order: order, existing: baselineKeys) {
            changes[.readingList(book: book)] = .string(key)
        }
        // A book that left the list, while it is still in the library.
        let listed = Set(order)
        for book in baselineKeys.keys where !listed.contains(book) && now.values[.book(book, .presence)] != nil {
            changes[.readingList(book: book)] = .null
        }
        return changes
    }

    // MARK: The stamp of a joining device

    /// The stamp for an entry of a device's first record in a store (a library that joins, or is
    /// restored or copied, already holding books): the value's own date where it has one, a
    /// place's `lastUpdated`, a bookmark's date, or when a book was last opened; otherwise the
    /// lowest stamp. So what the device brings never outranks what is already in the store,
    /// and still wins where nothing competes.
    /// A date after `now` counts as `now`: a place dated in the future (a clock that was ahead)
    /// must not get a stamp that `SyncClock.observe` then refuses as too far ahead.
    static func joiningStamp(for key: SyncKey, value: JSONValue, device: String, now: Date = Date()) -> SyncStamp {
        let dated: JSONValue?
        switch key {
        case .book(_, .position): dated = value["lastUpdated"]
        case .bookmark: dated = value["dateCreated"]
        case .book(_, .lastOpened): dated = value
        default: dated = nil
        }
        let milliseconds = dated.flatMap { SyncValueCoding.date(from: $0) }.map { SyncClock.milliseconds(of: $0) } ?? 0
        return SyncStamp(wall: min(max(0, milliseconds), SyncClock.milliseconds(of: now)), counter: 0, device: device)
    }
}
