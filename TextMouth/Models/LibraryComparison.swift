import Foundation

// MARK: - Comparing Two Copies of a Library (Phase 0 of the local-first design)

/// Which of the two copies being compared something is in. "This copy" is
/// the library TextMouth is using, "the other copy" the folder chosen to
/// compare it with.
enum LibraryCopySide: Equatable, Sendable {
    /// The library in use.
    case thisCopy
    /// The folder compared with it.
    case otherCopy

    /// The other side.
    var opposite: LibraryCopySide {
        self == .thisCopy ? .otherCopy : .thisCopy
    }
}

/// What a book's package record (bookInfo.json) says that its row in
/// library.json may say differently: the place and the bookmarks, which the
/// reader saves into the record as often as into the index, so either may
/// hold the newer.
struct LibraryRecordFacts: Equatable, Sendable {
    /// The place the record holds, if any.
    var position: ReadingPosition?
    /// The record's bookmarks.
    var bookmarks: [Bookmark]
    /// The record's count of the book's characters, which a percent needs
    /// when the row holds none.
    var totalCharacterCount: Int?
}

/// A file of one copy that could not be read, which the comparison lists as
/// unread, never as missing: nothing is known of what it holds.
struct LibraryUnreadFile: Equatable, Sendable {
    /// What was to be read.
    enum Subject: Equatable, Sendable {
        /// library-identity.json, which says which library a copy is.
        case identityMarker
        /// library.json, the index, which the whole comparison needs.
        case libraryIndex
        /// A book's package record, by the book's ID and title.
        case record(bookID: UUID, title: String)
    }

    /// Why it was not read.
    enum Reason: Equatable, Sendable {
        /// It was only in the cloud and had not arrived after this many
        /// seconds, the limit of every wait.
        case notArrived(seconds: Int)
        /// It could not be read or decoded, for this reason in words.
        case cannotBeRead(String)
        /// The whole comparison had used its time, this many seconds, before
        /// this file was read.
        case timeRanOut(seconds: Int)
        /// An earlier read of it is still waiting on the drive, or the drive
        /// has not answered the reads it has, so it was not asked again.
        case stillBeingFetched
    }

    var subject: Subject
    var side: LibraryCopySide
    var reason: Reason
}

/// One copy of a library, as its files decode: the index, the records of
/// the books whose package records were read, and what was not read. The
/// comparison reads nothing else, so it is a pure function of two of these
/// (`LibraryComparison.compare(this:other:)`), which the merge of a later
/// phase reuses.
struct LibraryCopy: Sendable {
    /// library.json, decoded. Its feed items are not part of the comparison.
    var library: Library
    /// The records read, by book ID. A book whose record is absent here is
    /// compared by its row alone.
    var records: [UUID: LibraryRecordFacts] = [:]
    /// What was not read.
    var unread: [LibraryUnreadFile] = []
}

/// A book as the comparison's sentences name it.
struct LibraryBookName: Equatable, Sendable {
    var id: UUID
    var title: String
    /// The author, nil when unknown.
    var author: String?

    /// The name of `book`.
    init(_ book: Book) {
        id = book.id
        title = book.title
        author = book.author.isEmpty || book.author == Book.unknownAuthor ? nil : book.author
    }

    /// The name of a book the copy's library does not hold, only the
    /// reading list's ID.
    init(id: UUID, title: String) {
        self.id = id
        self.title = title
        author = nil
    }
}

/// A place in a book as the comparison's sentences say it: the chapter, from
/// 1, and the percent of the book, when the book's length is known.
struct LibraryPlaceName: Equatable, Sendable {
    var chapter: Int
    var percent: Int?
}

/// A bookmark as the comparison's sentences say it.
struct LibraryBookmarkName: Equatable, Sendable {
    var number: Int
    var chapter: Int
    var note: String
}

/// One way two copies of a library differ, in what the sentences need.
enum LibraryDifference: Equatable, Sendable {
    /// A book only one copy holds.
    case bookOnlyIn(LibraryCopySide, LibraryBookName)
    /// A book both hold, filed in different folders ("" is the top).
    case bookFiledDifferently(LibraryBookName, thisFolder: String, otherFolder: String)
    /// A book both hold, whose places differ: the newer one, and the older,
    /// which is nil when that copy holds none.
    case positionNewer(LibraryBookName, newerIn: LibraryCopySide, newer: LibraryPlaceName, older: LibraryPlaceName?)
    /// Places that differ and were saved at the same time.
    case positionDiffersAtOnce(LibraryBookName, this: LibraryPlaceName, other: LibraryPlaceName)
    /// A bookmark only one copy holds.
    case bookmarkOnlyIn(LibraryCopySide, LibraryBookName, LibraryBookmarkName)
    /// A bookmark both hold, with another place or note.
    case bookmarkDiffers(LibraryBookName, this: LibraryBookmarkName, other: LibraryBookmarkName)
    /// A book only one copy's reading list holds, at this place from 1.
    case readingListBookOnlyIn(LibraryCopySide, LibraryBookName, place: Int)
    /// The books both lists hold, in another order: each list's titles.
    case readingListOrderDiffers(thisTitles: [String], otherTitles: [String])
    /// A reading list option that differs: its label and each value.
    case readingListOptionDiffers(label: String, this: String, other: String)
    /// A folder only one copy holds, by its path.
    case folderOnlyIn(LibraryCopySide, path: String)
    /// A folder both hold under another path (renamed or moved).
    case folderPathDiffers(thisPath: String, otherPath: String)

    /// The kind of difference, for counts.
    enum Kind: Equatable, Sendable {
        case book, position, bookmark, readingList, folder
    }

    /// The kind this difference counts under.
    var kind: Kind {
        switch self {
        case .bookOnlyIn, .bookFiledDifferently: return .book
        case .positionNewer, .positionDiffersAtOnce: return .position
        case .bookmarkOnlyIn, .bookmarkDiffers: return .bookmark
        case .readingListBookOnlyIn, .readingListOrderDiffers, .readingListOptionDiffers: return .readingList
        case .folderOnlyIn, .folderPathDiffers: return .folder
        }
    }
}

/// What differs between two copies of one library, and what could not be
/// read to tell.
struct LibraryComparison: Equatable, Sendable {
    /// Every difference, in the order the sentences are read: books, places,
    /// bookmarks, the reading list, folders.
    var differences: [LibraryDifference]
    /// The files that were not read, either copy's.
    var unread: [LibraryUnreadFile]

    /// How many books only `side` holds.
    func booksOnlyIn(_ side: LibraryCopySide) -> Int {
        differences.filter { if case .bookOnlyIn(side, _) = $0 { return true } else { return false } }.count
    }

    /// How many books whose place is newer in `side`'s copy.
    func newerPositions(in side: LibraryCopySide) -> Int {
        differences.filter { if case .positionNewer(_, side, _, _) = $0 { return true } else { return false } }.count
    }

    /// How many bookmarks only `side` holds.
    func bookmarksOnlyIn(_ side: LibraryCopySide) -> Int {
        differences.filter { if case .bookmarkOnlyIn(side, _, _) = $0 { return true } else { return false } }.count
    }
}

// MARK: Comparing

extension LibraryComparison {
    /// Compares two copies of a library, changing neither. Each book is
    /// matched by its ID, each folder by its identifier, and each bookmark
    /// by its own; a book's place is the newer of its row's and its
    /// record's within a copy, and then the newer of the copies'.
    static func compare(this: LibraryCopy, other: LibraryCopy) -> LibraryComparison {
        let books = BookComparison(this: this, other: other)
        var differences = books.differences
        differences += ReadingListComparison(this: this, other: other).differences
        differences += folderDifferences(this: this.library, other: other.library)
        return LibraryComparison(differences: differences, unread: this.unread + other.unread)
    }

    /// The folders only one copy holds, and those both hold under another
    /// path, matched by identifier. A folder one copy lacks by identifier
    /// but whose path the other holds under another identifier is the same
    /// folder made twice, and is no difference.
    private static func folderDifferences(this: Library, other: Library) -> [LibraryDifference] {
        let otherByID = Dictionary(other.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let thisByID = Dictionary(this.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let equivalence = FolderPathEquivalence.caseInsensitive
        let thisPaths = Set(this.folders.map { equivalence.comparisonKey(for: $0.fullPath) })
        let otherPaths = Set(other.folders.map { equivalence.comparisonKey(for: $0.fullPath) })
        var found: [LibraryDifference] = []
        for folder in this.folders.sortedStably(by: { $0.fullPath.localizedStandardCompare($1.fullPath) == .orderedAscending }) {
            if let counterpart = otherByID[folder.id] {
                if equivalence.comparisonKey(for: counterpart.fullPath) != equivalence.comparisonKey(for: folder.fullPath) {
                    found.append(.folderPathDiffers(thisPath: folder.fullPath, otherPath: counterpart.fullPath))
                }
            } else if !otherPaths.contains(equivalence.comparisonKey(for: folder.fullPath)) {
                found.append(.folderOnlyIn(.thisCopy, path: folder.fullPath))
            }
        }
        for folder in other.folders.sortedStably(by: { $0.fullPath.localizedStandardCompare($1.fullPath) == .orderedAscending })
        where thisByID[folder.id] == nil && !thisPaths.contains(equivalence.comparisonKey(for: folder.fullPath)) {
            found.append(.folderOnlyIn(.otherCopy, path: folder.fullPath))
        }
        return found
    }
}

// MARK: Books, Places, and Bookmarks

/// The books of two copies compared: which each holds, their folders, their
/// places, and their bookmarks.
private struct BookComparison {
    let this: LibraryCopy
    let other: LibraryCopy

    /// A book as one copy holds it: the row, and the place and bookmarks
    /// the copy's row and record agree on.
    private struct Held {
        let book: Book
        let position: ReadingPosition?
        let bookmarks: [Bookmark]
        /// The book with that place, so a percent is worked out as the
        /// library's rows work it out.
        var placed: Book {
            var placed = book
            placed.readingPosition = position
            return placed
        }
    }

    /// The differences, books first, then places, then bookmarks, each
    /// group in the books' title order.
    var differences: [LibraryDifference] {
        let thisHeld = Self.held(in: this)
        let otherHeld = Self.held(in: other)
        let ordered = Self.inTitleOrder(Set(thisHeld.keys).union(otherHeld.keys), thisHeld, otherHeld)
        var books: [LibraryDifference] = []
        var places: [LibraryDifference] = []
        var bookmarks: [LibraryDifference] = []
        for id in ordered {
            switch (thisHeld[id], otherHeld[id]) {
            case (let here?, nil):
                books.append(.bookOnlyIn(.thisCopy, LibraryBookName(here.book)))
            case (nil, let there?):
                books.append(.bookOnlyIn(.otherCopy, LibraryBookName(there.book)))
            case (let here?, let there?):
                let name = LibraryBookName(here.book)
                if here.book.folderPath != there.book.folderPath {
                    books.append(.bookFiledDifferently(name, thisFolder: here.book.folderPath, otherFolder: there.book.folderPath))
                }
                places += Self.positionDifference(of: name, here, there)
                bookmarks += Self.bookmarkDifferences(of: name, here, there)
            case (nil, nil):
                break
            }
        }
        return books + places + bookmarks
    }

    /// The books of `copy`'s library, by ID, with each one's place and
    /// bookmarks as its row and its record, where one was read, agree on.
    private static func held(in copy: LibraryCopy) -> [UUID: Held] {
        var held: [UUID: Held] = [:]
        for book in copy.library.libraryBooks where held[book.id] == nil {
            var shown = book
            let record = copy.records[book.id]
            if shown.totalCharacterCount == nil { shown.totalCharacterCount = record?.totalCharacterCount }
            held[book.id] = Held(
                book: shown,
                position: newer(book.readingPosition, record?.position),
                bookmarks: union(of: book.bookmarks, and: record?.bookmarks ?? [])
            )
        }
        return held
    }

    /// The IDs in the order the books' titles read, the title of the book
    /// in `this` copy first, then ID text, so the order is the same on every
    /// run.
    private static func inTitleOrder(_ ids: Set<UUID>, _ this: [UUID: Held], _ other: [UUID: Held]) -> [UUID] {
        ids.sortedStably { first, second in
            let firstTitle = (this[first] ?? other[first])?.book.title ?? ""
            let secondTitle = (this[second] ?? other[second])?.book.title ?? ""
            switch firstTitle.localizedStandardCompare(secondTitle) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return first.uuidString < second.uuidString
            }
        }
    }

    /// The newer of two places, by the date each was saved; the first when
    /// the dates are the same second.
    private static func newer(_ first: ReadingPosition?, _ second: ReadingPosition?) -> ReadingPosition? {
        guard let first else { return second }
        guard let second else { return first }
        return second.lastUpdated.timeIntervalSince(first.lastUpdated) >= 1 ? second : first
    }

    /// Two lists of bookmarks as one, each bookmark once by its ID, the
    /// first list's winning, in number order.
    private static func union(of first: [Bookmark], and second: [Bookmark]) -> [Bookmark] {
        var byID: [UUID: Bookmark] = [:]
        for bookmark in first + second where byID[bookmark.id] == nil {
            byID[bookmark.id] = bookmark
        }
        return byID.values.sortedStably { ($0.number, $0.id.uuidString) < ($1.number, $1.id.uuidString) }
    }

    /// Whether two places are the same: the chapter and the offsets, not
    /// the dates or the anchors.
    private static func samePlace(_ first: ReadingPosition, _ second: ReadingPosition) -> Bool {
        first.chapterIndex == second.chapterIndex
            && first.characterOffset == second.characterOffset
            && (first.globalCharacterOffset ?? first.characterOffset) == (second.globalCharacterOffset ?? second.characterOffset)
    }

    /// How the places of one book in the two copies differ, if they do.
    private static func positionDifference(of name: LibraryBookName, _ here: Held, _ there: Held) -> [LibraryDifference] {
        switch (here.position, there.position) {
        case (nil, nil):
            return []
        case (let place?, nil):
            return [.positionNewer(name, newerIn: .thisCopy, newer: placeName(place, in: here), older: nil)]
        case (nil, let place?):
            return [.positionNewer(name, newerIn: .otherCopy, newer: placeName(place, in: there), older: nil)]
        case (let hereAt?, let thereAt?):
            if samePlace(hereAt, thereAt) { return [] }
            let gap = hereAt.lastUpdated.timeIntervalSince(thereAt.lastUpdated)
            let thisName = placeName(hereAt, in: here)
            let otherName = placeName(thereAt, in: there)
            if abs(gap) < 1 {
                return [.positionDiffersAtOnce(name, this: thisName, other: otherName)]
            }
            return gap > 0
                ? [.positionNewer(name, newerIn: .thisCopy, newer: thisName, older: otherName)]
                : [.positionNewer(name, newerIn: .otherCopy, newer: otherName, older: thisName)]
        }
    }

    /// `place` as the sentences say it, its percent worked out on the book
    /// as `held` holds it.
    private static func placeName(_ place: ReadingPosition, in held: Held) -> LibraryPlaceName {
        var placed = held.placed
        placed.readingPosition = place
        return LibraryPlaceName(chapter: place.chapterIndex + 1, percent: placed.percentComplete.map { Int($0.rounded()) })
    }

    /// The bookmarks only one copy holds, and those both hold that differ,
    /// by each bookmark's ID, in number order.
    private static func bookmarkDifferences(of name: LibraryBookName, _ here: Held, _ there: Held) -> [LibraryDifference] {
        let thereByID = Dictionary(there.bookmarks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let hereIDs = Set(here.bookmarks.map(\.id))
        var found: [LibraryDifference] = []
        for bookmark in here.bookmarks {
            guard let counterpart = thereByID[bookmark.id] else {
                found.append(.bookmarkOnlyIn(.thisCopy, name, bookmarkName(bookmark)))
                continue
            }
            if bookmark.label != counterpart.label || bookmark.chapterIndex != counterpart.chapterIndex
                || bookmark.characterOffset != counterpart.characterOffset {
                found.append(.bookmarkDiffers(name, this: bookmarkName(bookmark), other: bookmarkName(counterpart)))
            }
        }
        for bookmark in there.bookmarks where !hereIDs.contains(bookmark.id) {
            found.append(.bookmarkOnlyIn(.otherCopy, name, bookmarkName(bookmark)))
        }
        return found
    }

    /// `bookmark` as the sentences say it.
    private static func bookmarkName(_ bookmark: Bookmark) -> LibraryBookmarkName {
        LibraryBookmarkName(number: bookmark.number, chapter: bookmark.chapterIndex + 1, note: bookmark.label)
    }
}

// MARK: The Reading List

/// The reading lists of two copies compared: the books only one holds, the
/// order of those both hold, and the options.
private struct ReadingListComparison {
    let this: LibraryCopy
    let other: LibraryCopy

    /// The differences, books first, then the order, then the options.
    var differences: [LibraryDifference] {
        let thisList = this.library.readingList
        let otherList = other.library.readingList
        var found: [LibraryDifference] = []
        for (place, id) in thisList.bookIDs.enumerated() where !otherList.contains(id) {
            found.append(.readingListBookOnlyIn(.thisCopy, name(of: id), place: place + 1))
        }
        for (place, id) in otherList.bookIDs.enumerated() where !thisList.contains(id) {
            found.append(.readingListBookOnlyIn(.otherCopy, name(of: id), place: place + 1))
        }
        // The books both lists hold, in each list's order.
        let thisShared = thisList.bookIDs.filter(otherList.contains)
        let otherShared = otherList.bookIDs.filter(thisList.contains)
        if thisShared != otherShared {
            found.append(.readingListOrderDiffers(
                thisTitles: thisShared.map { name(of: $0).title },
                otherTitles: otherShared.map { name(of: $0).title }
            ))
        }
        if thisList.continuation != otherList.continuation {
            found.append(.readingListOptionDiffers(
                label: ReadingListWording.continuationLabel,
                this: thisList.continuation.title,
                other: otherList.continuation.title
            ))
        }
        if thisList.skipsFinished != otherList.skipsFinished {
            found.append(.readingListOptionDiffers(
                label: ReadingListWording.skipFinishedLabel,
                this: LibraryComparisonWording.onOrOff(thisList.skipsFinished),
                other: LibraryComparisonWording.onOrOff(otherList.skipsFinished)
            ))
        }
        if thisList.removesFinished != otherList.removesFinished {
            found.append(.readingListOptionDiffers(
                label: ReadingListWording.removeFinishedLabel,
                this: LibraryComparisonWording.onOrOff(thisList.removesFinished),
                other: LibraryComparisonWording.onOrOff(otherList.removesFinished)
            ))
        }
        return found
    }

    /// The name of the book `id`, from whichever copy holds it, or a stand-in
    /// when neither does.
    private func name(of id: UUID) -> LibraryBookName {
        if let book = this.library.libraryBooks.first(where: { $0.id == id }) ?? other.library.libraryBooks.first(where: { $0.id == id }) {
            return LibraryBookName(book)
        }
        return LibraryBookName(id: id, title: LibraryComparisonWording.unknownBookTitle)
    }
}
