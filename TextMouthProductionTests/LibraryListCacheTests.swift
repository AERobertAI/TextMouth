import XCTest
@testable import TextMouth

/// The library list cache (TODO PERF10): each list a Library window shows
/// is derived once and kept until a change of membership or of a field it is
/// sorted or searched by; other changes reach its books without deriving it
/// again, and the order is always the one `LibraryBookSorter` gives.
@MainActor
final class LibraryListCacheTests: XCTestCase {

    /// The folder the per-field tests show.
    private static let shelf = "Shelf"

    // MARK: - Each Sort Field Follows Its Key

    /// A new title moves the book; a reading position does not derive again.
    func testTitleSortFollowsATitleChangeAndKeepsTheListForAPosition() throws {
        try assertSortFollowsItsKey(.title) { $0.title = "Aardvark Almanac" }
    }

    /// A new author moves the book; a reading position does not derive again.
    func testAuthorSortFollowsAnAuthorChangeAndKeepsTheListForAPosition() throws {
        try assertSortFollowsItsKey(.author) { $0.author = "Aabel Aagaard" }
    }

    /// An earlier date added moves the book; a reading position does not
    /// derive again.
    func testDateAddedSortFollowsADateChangeAndKeepsTheListForAPosition() throws {
        try assertSortFollowsItsKey(.dateAdded) { $0.dateAdded = Date(timeIntervalSince1970: 0) }
    }

    /// An earlier last-opened date moves the book; a reading position does
    /// not derive again.
    func testLastOpenedSortFollowsAnOpeningAndKeepsTheListForAPosition() throws {
        try assertSortFollowsItsKey(.lastOpened) { $0.lastOpened = Date(timeIntervalSince1970: 0) }
    }

    /// A new place in the manual order moves the book; a reading position
    /// does not derive again.
    func testManualOrderFollowsARearrangementAndKeepsTheListForAPosition() throws {
        try assertSortFollowsItsKey(.manual) { $0.manualSortOrder = -1 }
    }

    /// A smaller file, with the new content hash a rewrite records, moves the
    /// book; a reading position does not derive again or measure any file.
    func testFileSizeSortFollowsARewrittenFileAndKeepsTheListForAPosition() throws {
        try assertSortFollowsItsKey(.fileSize) { book in
            try Data(count: 1).write(to: URL(fileURLWithPath: book.filePath))
            book.md5Hash = "rewritten"
        }
    }

    /// Shows a folder of six books sorted ascending by `field`, then checks
    /// the cache against that field's key:
    /// - the first read derives the list, in the order `LibraryBookSorter`
    ///   gives the books;
    /// - a moved reading position keeps the list (no derivation, no file
    ///   measured) and reaches the list's book;
    /// - `changeKey`, applied to the book sorted last, makes it sort first,
    ///   and the next read derives the list once and shows it first.
    private func assertSortFollowsItsKey(
        _ field: LibrarySortField,
        file: StaticString = #filePath,
        line: UInt = #line,
        changeKey: (inout Book) throws -> Void
    ) throws {
        let model = LibraryViewModel(initializeServices: false)
        model.library = try makeShelfLibrary(sortedBy: field)
        let shelf = LibraryLocation(category: .folders, folderPath: Self.shelf)
        let cache = model.listCache

        let first = model.displayedBooks(at: shelf)
        XCTAssertEqual(first.map(\.id), try referenceOrder(of: model, at: shelf), "first read", file: file, line: line)
        let derivations = cache.derivationCount
        let measurements = cache.fileMeasurementCount

        // A reading position alone, as a reader's live position changes it:
        // the same list, with the new position. (A checkpoint also stamps
        // the book as last opened; see the Recent test below.)
        // The shelf lists six books, so a short list is a failure, not a trap.
        let middle = try XCTUnwrap(first[safe: 2], "the shelf shows fewer than three books", file: file, line: line).id
        let position = ReadingPosition(chapterIndex: 3, characterOffset: 1_234, globalCharacterOffset: 9_999)
        let middleIndex = try XCTUnwrap(model.library.books.firstIndex { $0.id == middle }, file: file, line: line)
        model.library.books[middleIndex].readingPosition = position
        let afterPosition = model.displayedBooks(at: shelf)
        XCTAssertEqual(cache.derivationCount, derivations, "a reading position derived the list", file: file, line: line)
        XCTAssertEqual(cache.fileMeasurementCount, measurements, "a reading position measured a file", file: file, line: line)
        XCTAssertEqual(afterPosition.map(\.id), first.map(\.id), file: file, line: line)
        XCTAssertEqual(afterPosition.first { $0.id == middle }?.readingPosition, position, file: file, line: line)

        // The key of the book sorted last: derived once more, now first.
        let last = try XCTUnwrap(first.last, file: file, line: line)
        let index = try XCTUnwrap(model.library.books.firstIndex { $0.id == last.id }, file: file, line: line)
        try changeKey(&model.library.books[index])
        let afterKey = model.displayedBooks(at: shelf)
        XCTAssertEqual(cache.derivationCount, derivations + 1, "the key change was not derived once", file: file, line: line)
        XCTAssertEqual(afterKey.first?.id, last.id, "the changed key did not move the book", file: file, line: line)
        XCTAssertEqual(afterKey.map(\.id), try referenceOrder(of: model, at: shelf), file: file, line: line)

        // Read again: kept.
        _ = model.displayedBooks(at: shelf)
        XCTAssertEqual(cache.derivationCount, derivations + 1, "an unchanged library derived the list", file: file, line: line)
    }

    /// A checkpoint (`Library.updateReadingPosition`) stamps the book as
    /// last opened as well, a field Recent and Last Opened sort by, so those
    /// lists are derived again and put the book first.
    func testACheckpointMovesItsBookToTheTopOfRecent() throws {
        let model = LibraryViewModel(initializeServices: false)
        model.library = try makeShelfLibrary(sortedBy: .title)
        let recent = LibraryLocation(category: .recent, folderPath: "")
        let before = model.displayedBooks(at: recent)
        let oldest = try XCTUnwrap(before.last)
        let derivations = model.listCache.derivationCount

        model.library.updateReadingPosition(bookID: oldest.id, position: ReadingPosition(characterOffset: 50))
        let after = model.displayedBooks(at: recent)

        XCTAssertEqual(model.listCache.derivationCount, derivations + 1)
        XCTAssertEqual(after.first?.id, oldest.id)
        XCTAssertEqual(after.first?.readingPosition?.characterOffset, 50)
    }

    // MARK: - Searching

    /// A search narrows the kept list as the list always did (title or
    /// author contains the words, ignoring case) without sorting again, and
    /// is itself kept; a new search is one more derivation.
    func testASearchNarrowsTheKeptListWithoutSortingAgain() throws {
        let model = LibraryViewModel(initializeServices: false)
        model.library = try makeShelfLibrary(sortedBy: .title)
        let shelf = LibraryLocation(category: .folders, folderPath: Self.shelf)
        let all = model.displayedBooks(at: shelf)
        let derivations = model.listCache.derivationCount

        let found = model.displayedBooks(at: shelf, matching: "OrCh")
        XCTAssertEqual(model.listCache.derivationCount, derivations + 1)
        XCTAssertEqual(found.map(\.id), all.filter {
            $0.title.lowercased().contains("orch") || $0.author.lowercased().contains("orch")
        }.map(\.id))
        XCTAssertFalse(found.isEmpty)

        _ = model.displayedBooks(at: shelf, matching: "OrCh")
        _ = model.displayedBooks(at: shelf, matching: "orch")
        XCTAssertEqual(model.listCache.derivationCount, derivations + 1, "the same search, in either case, is kept")

        let byAuthor = model.displayedBooks(at: shelf, matching: "halvorsen")
        XCTAssertEqual(byAuthor.map(\.author), all.map(\.author).filter { $0.lowercased().contains("halvorsen") })
        XCTAssertEqual(model.listCache.derivationCount, derivations + 2)
        XCTAssertEqual(model.displayedBooks(at: shelf, matching: "").map(\.id), all.map(\.id))
    }

    /// Past `entryLimit` lists the cache starts over, and every list it
    /// gives afterwards is still the right one.
    func testKeptListsAreBoundedAndStayCorrect() throws {
        let model = LibraryViewModel(initializeServices: false)
        model.library = try makeShelfLibrary(sortedBy: .title)
        let shelf = LibraryLocation(category: .folders, folderPath: Self.shelf)
        let all = model.displayedBooks(at: shelf)

        for number in 0...LibraryListCache.entryLimit {
            XCTAssertTrue(model.displayedBooks(at: shelf, matching: "search \(number)").isEmpty)
        }

        XCTAssertEqual(model.displayedBooks(at: shelf).map(\.id), all.map(\.id))
    }

    // MARK: - Every Category

    /// Every category, and every folder of the generated library, shows the
    /// books in the order the uncached sort gives them, before and after a
    /// book moves between folders.
    func testEveryLocationShowsWhatTheUncachedSortShows() throws {
        let model = LibraryViewModel(initializeServices: false)
        model.library = try LibraryBenchmarkFixture.library(bookCount: 160)
        let locations = [
            LibraryLocation(category: .allItems, folderPath: ""),
            LibraryLocation(category: .unopened, folderPath: "Essays"),
            LibraryLocation(category: .recent, folderPath: ""),
            LibraryLocation(category: .folders, folderPath: "")
        ] + LibraryBenchmarkFixture.folderPaths.map { LibraryLocation(category: .folders, folderPath: $0) }

        for pass in 0..<2 {
            for location in locations {
                let uncached = model.sortedBooks(
                    model.booksForCategory(location.category, folderPath: location.folderPath),
                    by: model.sortState(at: location)
                )
                XCTAssertEqual(
                    model.displayedBooks(at: location).map(\.id),
                    uncached.map(\.id),
                    "\(location.category) \(location.folderPath), pass \(pass)"
                )
            }
            LibraryBenchmarkFixture.moveOneBook(in: model)
        }
    }

    // MARK: - What Bumps the List Revision

    /// Changes no list reads keep every list (the list revision stays);
    /// changes of membership and of each sort or search key bump it.
    func testOnlyMembershipAndSortKeysBumpTheListRevision() throws {
        let model = LibraryViewModel(initializeServices: false)
        model.library = try makeShelfLibrary(sortedBy: .title)
        let cache = model.listCache

        let unreadChanges: [(String, (inout Book) -> Void)] = [
            ("reading position", { $0.readingPosition = ReadingPosition(chapterIndex: 1, characterOffset: 5) }),
            ("word count", { $0.totalWordCount = 42 }),
            ("character count", { $0.totalCharacterCount = 420 }),
            ("speed", { $0.localWPM = 310 }),
            ("voice", { $0.localVoiceID = "com.example.voice" }),
            ("bookmark", { $0.bookmarks.append(Bookmark(number: 1, chapterIndex: 0, characterOffset: 3, label: "Mark")) }),
            ("playback times", { $0.lastPlaybackStarted = Date() }),
            ("analysis versions", { $0.contentIndexVersion = "next"; $0.cacheFormatVersion = "next" }),
            ("audio duration", { $0.audioDuration = 61 })
        ]
        for (name, change) in unreadChanges {
            let revision = cache.listRevision
            change(&model.library.books[0])
            XCTAssertEqual(cache.listRevision, revision, "\(name) bumped the list revision")
        }

        let keyChanges: [(String, (inout Book) -> Void)] = [
            ("folder", { $0.folderPath = "Elsewhere" }),
            ("title", { $0.title += " Revised" }),
            ("author", { $0.author += " Junior" }),
            ("date added", { $0.dateAdded = Date(timeIntervalSince1970: 7) }),
            ("last opened", { $0.lastOpened = Date(timeIntervalSince1970: 8) }),
            ("manual order", { $0.manualSortOrder = 77 }),
            ("file path", { $0.filePath += ".moved" }),
            ("content hash", { $0.md5Hash = "different" })
        ]
        for (name, change) in keyChanges {
            let revision = cache.listRevision
            change(&model.library.books[1])
            XCTAssertEqual(cache.listRevision, revision + 1, "\(name) did not bump the list revision")
        }

        let revision = cache.listRevision
        model.library.books.removeLast()
        XCTAssertEqual(cache.listRevision, revision + 1, "removing a book did not bump the list revision")
        model.library.books.swapAt(0, 1)
        XCTAssertEqual(cache.listRevision, revision + 2, "reordering the books did not bump the list revision")
    }

    // MARK: - Finding a Book by ID

    /// `bookByID` finds the book a scan of the library finds, for every
    /// book, through every kind of change: a new value, a removal, a
    /// reordering, an addition; an ID the library lacks gives nil; a book
    /// found twice gives the first (the audit's C17).
    func testBookByIDAgreesWithAScanThroughEveryChange() throws {
        let model = LibraryViewModel(initializeServices: false)
        model.library = try LibraryBenchmarkFixture.library(bookCount: 50)

        func assertAgreesWithAScan(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
            for book in model.library.books {
                let scanned = model.library.books.first { $0.id == book.id }
                XCTAssertEqual(model.bookByID(book.id), scanned, "\(step): \(book.title)", file: file, line: line)
            }
            XCTAssertNil(model.bookByID(UUID()), "\(step): an unknown ID", file: file, line: line)
        }

        assertAgreesWithAScan("at first")
        model.library.books[3].readingPosition = ReadingPosition(chapterIndex: 2, characterOffset: 9)
        assertAgreesWithAScan("after a position")
        model.library.books[4].title = "Renamed Again"
        assertAgreesWithAScan("after a rename")
        model.library.books.swapAt(0, 7)
        assertAgreesWithAScan("after a reordering")
        let removed = model.library.books.remove(at: 10)
        assertAgreesWithAScan("after a removal")
        XCTAssertNil(model.bookByID(removed.id), "the removed book is still found")
        model.library.books.append(removed)
        assertAgreesWithAScan("after an addition")

        // The same book twice: the first is the one found, as a scan finds it.
        var twin = removed
        twin.title = "The Second One"
        model.library.books.append(twin)
        XCTAssertEqual(model.bookByID(removed.id)?.title, removed.title)
    }

    // MARK: - Folder Counts

    /// Each folder tree's count is the library's own count, for every folder
    /// and for paths no folder has, and follows a book that moves.
    func testFolderCountsMatchTheLibrarysCount() throws {
        let model = LibraryViewModel(initializeServices: false)
        model.library = try LibraryBenchmarkFixture.library(bookCount: 200)
        let paths = LibraryBenchmarkFixture.folderPaths + ["", "Science", "Science Fiction/", "Nowhere", "History/Collected"]

        for pass in 0..<2 {
            for path in paths {
                XCTAssertEqual(
                    model.bookCount(inFolderTree: path),
                    model.library.totalBooksInFolderTree(path),
                    "\(path), pass \(pass)"
                )
            }
            LibraryBenchmarkFixture.moveOneBook(in: model)
        }
    }

    /// Counting walks paths as `hasPrefix` compares them: a book in "A/B"
    /// counts toward "A/B" and "A", never toward "A/" or "A/B/", and odd
    /// paths (a leading slash, a doubled one) count as the library counts.
    func testFolderCountsWalkPathsAsTheLibraryDoes() {
        let books = ["A/B", "A", "A/B/C", "/Lead", "A//Double", "", "Ab"].map {
            Book(title: $0, format: .txt, filePath: "/tmp/\($0)", md5Hash: $0, folderPath: $0)
        }
        let library = Library(books: books)
        let counts = LibraryListCache.folderTreeCounts(of: books)

        for path in ["", "A", "A/", "A/B", "A/B/", "A/B/C", "/Lead", "Lead", "A//Double", "Ab", "B"] {
            XCTAssertEqual(counts[path] ?? 0, library.totalBooksInFolderTree(path), path)
        }
    }

    // MARK: - File Sizes

    /// File sizes are measured once per book, kept through reads and
    /// changes that leave the file alone, and measured again only for a
    /// book whose file changed.
    func testFileSizesAreMeasuredOncePerFile() throws {
        let model = LibraryViewModel(initializeServices: false)
        model.library = try makeShelfLibrary(sortedBy: .fileSize)
        let shelf = LibraryLocation(category: .folders, folderPath: Self.shelf)
        let cache = model.listCache
        let shelfCount = model.library.booksInFolder(Self.shelf).count

        _ = model.displayedBooks(at: shelf)
        XCTAssertEqual(cache.fileMeasurementCount, shelfCount)

        // Another derivation (a new title) measures nothing again.
        model.library.books[0].title = "Renamed"
        _ = model.displayedBooks(at: shelf)
        XCTAssertEqual(cache.fileMeasurementCount, shelfCount)

        // A rewritten file is measured again, alone.
        model.library.books[0].md5Hash = "rewritten"
        _ = model.displayedBooks(at: shelf)
        XCTAssertEqual(cache.fileMeasurementCount, shelfCount + 1)
    }

    // MARK: - The Comparator

    /// The keyed sort orders books exactly as the comparator did before its
    /// keys were read once per book: every field, both directions, over
    /// random books full of ties (equal keys, titles equal but for case,
    /// unopened and unplaced books).
    func testTheKeyedSortKeepsTheOriginalOrder() {
        var generator = SeededGenerator(state: 0x50_47_10)
        let titles = ["Atlas", "atlas", "Ledger", "Ferry", "ferry", "Zebra Quay", "Étude", "etude"]
        let authors = ["Varga", "varga", "Okonkwo", "Lindqvist", ""]
        for trial in 0..<20 {
            let books = (0..<60).map { _ in
                Book(
                    title: titles[Int(generator.next() % UInt64(titles.count))],
                    author: authors[Int(generator.next() % UInt64(authors.count))],
                    format: .txt,
                    filePath: "/tmp/keyed-sort",
                    md5Hash: "",
                    dateAdded: Date(timeIntervalSince1970: Double(generator.next() % 4)),
                    lastOpened: generator.next() % 3 == 0 ? nil : Date(timeIntervalSince1970: Double(generator.next() % 4)),
                    manualSortOrder: generator.next() % 3 == 0 ? nil : Int(generator.next() % 5)
                )
            }
            let sizes = Dictionary(uniqueKeysWithValues: books.map { ($0.id, Int(generator.next() % 4)) })
            for field in LibrarySortField.allCases {
                for ascending in [true, false] {
                    let legacy = books.sorted {
                        Self.legacyAreInIncreasingOrder($0, $1, by: field, ascending: ascending, fileSizes: sizes)
                    }
                    XCTAssertEqual(
                        LibraryBookSorter.sorted(books, by: field, ascending: ascending, fileSizes: sizes).map(\.id),
                        legacy.map(\.id),
                        "trial \(trial), \(field), ascending \(ascending)"
                    )
                }
            }
        }
    }

    /// The comparator before PERF10, unchanged: the order the keyed sort must
    /// keep.
    private static func legacyAreInIncreasingOrder(
        _ first: Book,
        _ second: Book,
        by field: LibrarySortField,
        ascending: Bool,
        fileSizes: [UUID: Int]
    ) -> Bool {
        let primary: ComparisonResult
        switch field {
        case .title:
            primary = first.title.localizedCaseInsensitiveCompare(second.title)
        case .author:
            primary = first.author.localizedCaseInsensitiveCompare(second.author)
        case .dateAdded:
            primary = legacyCompare(first.dateAdded, second.dateAdded)
        case .lastOpened:
            primary = legacyCompare(first.lastOpened ?? .distantPast, second.lastOpened ?? .distantPast)
        case .fileSize:
            primary = legacyCompare(fileSizes[first.id] ?? 0, fileSizes[second.id] ?? 0)
        case .manual:
            primary = legacyCompare(first.manualSortOrder ?? Int.max, second.manualSortOrder ?? Int.max)
        }
        if primary != .orderedSame {
            return ascending ? primary == .orderedAscending : primary == .orderedDescending
        }
        let titleComparison = first.title.localizedCaseInsensitiveCompare(second.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }
        return first.id.uuidString < second.id.uuidString
    }

    /// The old three-way comparison of two comparable values.
    private static func legacyCompare<T: Comparable>(_ first: T, _ second: T) -> ComparisonResult {
        if first < second { return .orderedAscending }
        if first > second { return .orderedDescending }
        return .orderedSame
    }

    // MARK: - Fixtures

    /// A library with six books in `shelf`, every key distinct and every
    /// book opened and placed in manual order, each book's file a temporary
    /// file of its own size (100 to 600 bytes), plus two books elsewhere.
    /// The shelf's sort is `field`, ascending.
    private func makeShelfLibrary(sortedBy field: LibrarySortField) throws -> Library {
        let folder = try LibraryBenchmarkFixture.makeFilesFolder(for: self)
        let titles = ["Ferry Ledger", "Granary", "Kiln Atlas", "Orchard", "Saltworks", "Weir"]
        let authors = ["Odile Halvorsen", "Tobiah Varga", "Ines Lindqvist", "Casimir Petrakis", "Signe Rautio", "Teodor Szabo"]
        var books: [Book] = []
        for (number, title) in titles.enumerated() {
            let file = folder.appendingPathComponent("book-\(number).txt")
            try Data(count: 100 * (number + 1)).write(to: file)
            books.append(Book(
                title: title,
                author: authors[number],
                format: .txt,
                filePath: file.path,
                md5Hash: "hash-\(number)",
                folderPath: Self.shelf,
                dateAdded: Date(timeIntervalSince1970: 1_000 * Double(number + 1)),
                lastOpened: Date(timeIntervalSince1970: 50_000 + 1_000 * Double(number)),
                manualSortOrder: number
            ))
        }
        for name in ["Elsewhere One", "Elsewhere Two"] {
            books.append(Book(title: name, format: .txt, filePath: "/tmp/\(name)", md5Hash: name, folderPath: "Other"))
        }
        // Shuffled, so the library's own order is never the sorted one.
        books.swapAt(0, 4)
        books.swapAt(1, 5)
        return Library(
            books: books,
            folders: [BookFolder(name: Self.shelf), BookFolder(name: "Other")],
            folderSortSettings: [Self.shelf: FolderSortSetting(sortField: field, sortAscending: true)]
        )
    }

    /// The shelf's books in the order the uncached sort gives them, with
    /// every file measured afresh.
    private func referenceOrder(of model: LibraryViewModel, at location: LibraryLocation) throws -> [UUID] {
        let books = model.library.booksInFolder(location.folderPath)
        let sizes = Dictionary(uniqueKeysWithValues: books.map {
            ($0.id, LibraryBookSorter.recursiveFileSize(at: URL(fileURLWithPath: $0.filePath)))
        })
        let sort = model.sortState(at: location)
        return LibraryBookSorter.sorted(books, by: sort.field, ascending: sort.isAscending, fileSizes: sizes).map(\.id)
    }
}
