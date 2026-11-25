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
    static func value(of field: SyncBookField, in book: Book) -> JSONValue? {
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
        case .position: return book.readingPosition.map { SyncValueCoding.json($0) } ?? .null
        case .skippedHeadings: return SyncValueCoding.json(SyncSkippedHeadingsValue(book))
        case .lastOpened: return SyncValueCoding.json(date: book.lastOpened)
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
        case .folder, .readingListOption: return nil
        }
    }

    /// The folder a key is about, or nil.
    var folderID: UUID? {
        if case .folder(let id, _) = self { return id }
        return nil
    }

    /// Whether a `.null` entry under this key is a removal mark (of a book, a
    /// folder, a bookmark, or a place on the reading list) and not a value
    /// that is none (a detail cleared, say).
    var nullIsRemoval: Bool {
        switch self {
        case .book(_, let field): return field == .presence
        case .folder(_, let field): return field == .presence
        case .bookmark, .readingList: return true
        case .readingListOption: return false
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

extension SyncProjection {
    /// The projection of `library`: a key for each value the sync keeps.
    /// - Parameter contents: the uploaded content of the books that have any; a book
    ///   without it has no `content` key yet.
    /// - Note: A book's place on the reading list is its order, a whole number.
    ///   Feed items are left out, and so is `keep`, which no row holds.
    static func of(_ library: Library, contents: [UUID: SyncContent]) -> SyncProjection {
        var projection = SyncProjection()
        let index = SyncFolderIndex(library.folders)

        // Folders: that they exist, their names, and their parents.
        for folder in library.folders {
            projection.values[.folder(folder.id, .presence)] = .bool(true)
            projection.values[.folder(folder.id, .name)] = .string(folder.name)
            projection.values[.folder(folder.id, .parent)] = SyncValueCoding.id(index.id(atPath: folder.parentPath))
        }

        // Books, their fields, and their bookmarks. A feed item is no book of the library's own.
        var bookIDs = Set<UUID>()
        for book in library.books where !book.isFeedItem {
            bookIDs.insert(book.id)
            projection.values[.book(book.id, .presence)] = .bool(true)
            if let content = contents[book.id] {
                projection.values[.book(book.id, .content)] = SyncBookValues.value(of: content)
            }
            projection.values[.book(book.id, .folder)] = SyncValueCoding.id(index.id(atPath: book.folderPath))
            for field in SyncBookValues.rowFields {
                projection.values[.book(book.id, field)] = SyncBookValues.value(of: field, in: book)
            }
            // The details a person edited by hand outrank any other change to them.
            for field in SyncBookValues.rowFields {
                if let edited = SyncBookValues.metadataField(of: field), book.handEdits?.contains(edited) == true {
                    projection.byHand.insert(.book(book.id, field))
                }
            }
            for bookmark in book.bookmarks {
                projection.values[.bookmark(book: book.id, id: bookmark.id)] = SyncValueCoding.json(SyncBookmarkValue(bookmark))
            }
        }

        // The reading list: each book's order, and the list's options.
        for (order, id) in library.readingList.bookIDs.enumerated() where bookIDs.contains(id) {
            projection.values[.readingList(book: id)] = .integer(Int64(order))
        }
        projection.values[.readingListOption(.continuation)] = .string(library.readingList.continuation.rawValue)
        projection.values[.readingListOption(.skipsFinished)] = .bool(library.readingList.skipsFinished)
        projection.values[.readingListOption(.removesFinished)] = .bool(library.readingList.removesFinished)
        return projection
    }

    /// Takes `entries` into this projection, as a baseline takes what was
    /// just recorded or applied: each key's value, whether a person made it,
    /// and, for a removal mark, the removal. A removed book or folder takes
    /// all its keys with it.
    mutating func absorb(_ entries: [SyncEntry]) {
        for entry in entries {
            if entry.byHand { byHand.insert(entry.key) } else { byHand.remove(entry.key) }
            absorb(key: entry.key, value: entry.value)
        }
    }

    /// Takes the value of one key, as `absorb(_:)` does.
    mutating func absorb(key: SyncKey, value: JSONValue) {
        guard !(value == .null && key.nullIsRemoval) else {
            removeKeys(of: key)
            return
        }
        values[key] = value
    }

    /// Forgets the key a removal mark is for, and, for a book or a folder, all its keys.
    private mutating func removeKeys(of key: SyncKey) {
        switch key {
        case .book(let id, .presence):
            let doomed = values.keys.filter { $0.bookID == id }
            for gone in doomed { values[gone] = nil; byHand.remove(gone) }
        case .folder(let id, .presence):
            let doomed = values.keys.filter { $0.folderID == id }
            for gone in doomed { values[gone] = nil; byHand.remove(gone) }
        default:
            values[key] = nil
            byHand.remove(key)
        }
    }
}

// MARK: - What changed

extension SyncMerge {
    /// The keys whose values differ between `baseline` (the library as last
    /// recorded or applied) and `now`, with the value each has now: the
    /// entries to stamp. A book or folder gone from `now` is a `.null`
    /// presence, and so is a bookmark or a place on the reading list; the
    /// other keys of a vanished book are not reported.
    ///
    /// - Parameter atLaunch: true for the first look after launch. A book or
    ///   folder that is missing then is not reported as removed (rule R7: a
    ///   removal crosses only when a person made it in a running TextMouth),
    ///   so the sync puts it back.
    /// - Note: The reading list is compared by order: `baseline` holds each
    ///   book's order key, `now` its place in the list, and only a book that
    ///   was moved or added is given a key (`SyncOrderKey.assign`).
    static func changes(from baseline: SyncProjection, to now: SyncProjection, atLaunch: Bool) -> [SyncKey: JSONValue] {
        var changes: [SyncKey: JSONValue] = [:]

        // Values that are new or different, and details a person has newly edited by hand.
        for (key, value) in now.values {
            if case .readingList = key { continue }
            if baseline.values[key] != value || (now.byHand.contains(key) && !baseline.byHand.contains(key)) {
                changes[key] = value
            }
        }

        // What was in the baseline and is gone.
        for key in baseline.values.keys where now.values[key] == nil {
            switch key {
            case .book(_, .presence), .folder(_, .presence):
                // A book or folder missing at launch is put back, not removed.
                if !atLaunch { changes[key] = .null }
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
}
