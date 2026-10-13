import XCTest
@testable import TextMouth

/// A book keeps the skipped headings that wait apart from the ones that name
/// headings (T06's branch D), and takes the places a rebuild of its text
/// moved only where it still holds them as they were.
final class BookWaitingSkipTests: XCTestCase {

    // MARK: - Fixtures

    /// A skip that waits, with words at its start, as the relocator leaves
    /// one when a rebuild found no heading for it.
    private static let waiting = SkippedHeading(
        level: 3, label: "Appendix", chapterIndex: 4, characterOffset: 120,
        anchor: TextAnchor(before: "the end of the", after: "appendix begins here", fraction: 0.5, measuredIn: "measure", version: 1)
    )

    /// A skip that names a heading, other than `waiting` in every value.
    private static let named = SkippedHeading(level: 2, label: "Notes", chapterIndex: 1, characterOffset: 40)

    /// A plain-text book holding the given skips and nothing else.
    private static func book(skipped: [SkippedHeading]? = nil, waiting: [SkippedHeading]? = nil) -> Book {
        var book = Book(
            title: "Waiting Skips", format: .txt,
            filePath: "/tmp/\(UUID().uuidString)-waiting-skips.txt", md5Hash: UUID().uuidString,
            waitingSkippedHeadings: waiting
        )
        book.setSkippedHeadings(skipped)
        return book
    }

    /// An encoder and decoder that write and read dates as the library and
    /// the package records do.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// `book` as a library row: written as JSON and read back.
    private static func storedAsRow(_ book: Book) throws -> Book {
        try decoder().decode(Book.self, from: encoder().encode(book))
    }

    /// `book` as a package record: its `bookInfo.json` written and read back,
    /// and the book made from the record.
    private static func storedAsRecord(_ book: Book) throws -> Book {
        let record = try decoder().decode(BookInfo.self, from: encoder().encode(book.makeBookInfo()))
        return Book(record: record, filePath: book.filePath, folderPath: book.folderPath, tmbDirectoryName: book.tmbDirectoryName)
    }

    /// The JSON object of `book` as a row, for a test to change before it is
    /// read back.
    private static func rowObject(of book: Book) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: encoder().encode(book)) as? [String: Any])
    }

    /// The JSON object of `book`'s record, with its `state` object.
    private static func recordObject(of book: Book) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: encoder().encode(book.makeBookInfo())) as? [String: Any])
    }

    // MARK: - Commit 1: Waiting Skips Stored Apart

    /// A waiting skip survives a library row, with its anchor, and stays out
    /// of the skipped IDs the reader matches.
    func testARowKeepsAWaitingSkip() throws {
        let book = Self.book(skipped: [Self.named], waiting: [Self.waiting])
        let stored = try Self.storedAsRow(book)
        XCTAssertEqual(stored.waitingSkippedHeadings, [Self.waiting])
        XCTAssertEqual(stored.skippedHeadings, [Self.named])
        XCTAssertEqual(stored.skippedHeadingIDs, [Self.named.id])
    }

    /// A waiting skip survives a package record, with its anchor, and stays
    /// out of the skipped IDs.
    func testARecordKeepsAWaitingSkip() throws {
        let book = Self.book(skipped: [Self.named], waiting: [Self.waiting])
        let stored = try Self.storedAsRecord(book)
        XCTAssertEqual(stored.waitingSkippedHeadings, [Self.waiting])
        XCTAssertEqual(stored.skippedHeadings, [Self.named])
        XCTAssertEqual(stored.skippedHeadingIDs, [Self.named.id])
    }

    /// The record's JSON, which an older build reads, never holds a waiting
    /// skip's ID among its skipped IDs, whether the book has named skips or
    /// none.
    func testTheRecordsSkippedIDsNeverHoldAWaitingSkip() throws {
        for named in [[Self.named], nil] as [[SkippedHeading]?] {
            let object = try Self.recordObject(of: Self.book(skipped: named, waiting: [Self.waiting]))
            let state = try XCTUnwrap(object["state"] as? [String: Any])
            XCTAssertEqual(state["skippedHeadingIDs"] as? [String], named.map { $0.map(\.id) })
            XCTAssertNotNil(state["waitingSkippedHeadings"], "the waiting skip itself is written")
            let ids = state["skippedHeadingIDs"] as? [String] ?? []
            XCTAssertFalse(ids.contains(Self.waiting.id))
        }
    }

    /// A row or record written without the key, or with a value under it
    /// that cannot be read, has no waiting skips, and keeps every other
    /// field.
    func testARowAndARecordWithoutReadableWaitingSkipsDecodeWithNone() throws {
        let book = Self.book(skipped: [Self.named], waiting: [Self.waiting])
        for value in [nil, "garbage", 17] as [Any?] {
            // The row.
            var row = try Self.rowObject(of: book)
            // A nil value removes the key, which is the row written without it.
            row["waitingSkippedHeadings"] = value
            let decodedRow = try Self.decoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: row))
            XCTAssertNil(decodedRow.waitingSkippedHeadings, "row, \(String(describing: value))")
            XCTAssertEqual(decodedRow.skippedHeadings, [Self.named])
            XCTAssertEqual(decodedRow.title, book.title)

            // The record.
            var record = try Self.recordObject(of: book)
            var state = try XCTUnwrap(record["state"] as? [String: Any])
            state["waitingSkippedHeadings"] = value
            record["state"] = state
            let decodedRecord = try Self.decoder().decode(BookInfo.self, from: JSONSerialization.data(withJSONObject: record))
            XCTAssertNil(decodedRecord.state.waitingSkippedHeadings, "record, \(String(describing: value))")
            XCTAssertEqual(decodedRecord.state.skippedHeadings, [Self.named])
        }
    }

    /// An empty list is stored as none, never as an empty array: in the
    /// initializer, and when a row or record holding one is read.
    func testAnEmptyListIsNone() throws {
        XCTAssertNil(Self.book(waiting: []).waitingSkippedHeadings)

        var row = try Self.rowObject(of: Self.book(waiting: [Self.waiting]))
        row["waitingSkippedHeadings"] = [Any]()
        XCTAssertNil(try Self.decoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: row)).waitingSkippedHeadings)

        var record = try Self.recordObject(of: Self.book(waiting: [Self.waiting]))
        var state = try XCTUnwrap(record["state"] as? [String: Any])
        state["waitingSkippedHeadings"] = [Any]()
        record["state"] = state
        XCTAssertNil(try Self.decoder().decode(BookInfo.self, from: JSONSerialization.data(withJSONObject: record)).state.waitingSkippedHeadings)
    }

    // MARK: - Commit 2: Fixtures for Moved Places

    /// Places a rebuild moves, and the same places moved: every place in
    /// `movedPlaces` differs from its place in `original`, so a test can tell
    /// which ones a book took. The bookmarks keep their IDs, as the
    /// relocator leaves them.
    private struct Moving {
        let position = ReadingPosition(chapterIndex: 1, characterOffset: 10)
        let movedPosition = ReadingPosition(chapterIndex: 1, characterOffset: 15)
        let markA = Bookmark(number: 1, chapterIndex: 1, characterOffset: 20, label: "A")
        let markB = Bookmark(number: 2, chapterIndex: 2, characterOffset: 30, label: "B")
        let skip = SkippedHeading(level: 2, label: "Notes", chapterIndex: 1, characterOffset: 40)
        let movedSkip = SkippedHeading(level: 2, label: "Notes", chapterIndex: 1, characterOffset: 45)
        let wait = SkippedHeading(level: 3, label: "Appendix", chapterIndex: 3, characterOffset: 50)
        let movedWait = SkippedHeading(level: 3, label: "Appendix", chapterIndex: 3, characterOffset: 55)

        /// `mark` at another place, with the same ID, number, label, and date.
        func moved(_ mark: Bookmark) -> Bookmark {
            Bookmark(id: mark.id, number: mark.number, chapterIndex: mark.chapterIndex, characterOffset: mark.characterOffset + 5, label: mark.label, dateCreated: mark.dateCreated)
        }

        /// The places as they were.
        var original: PlaceRelocator.Places {
            PlaceRelocator.Places(position: position, bookmarks: [markA, markB], skippedHeadings: [skip], waitingSkippedHeadings: [wait])
        }

        /// The places as the relocator moved them.
        var movedPlaces: PlaceRelocator.Places {
            PlaceRelocator.Places(position: movedPosition, bookmarks: [moved(markA), moved(markB)], skippedHeadings: [movedSkip], waitingSkippedHeadings: [movedWait])
        }
    }

    /// A plain-text book holding `places`, with a last-opened time a test
    /// checks stays as it is.
    private static func book(holding places: PlaceRelocator.Places) -> Book {
        var book = Book(
            title: "Moved Places", format: .txt,
            filePath: "/tmp/\(UUID().uuidString)-moved-places.txt", md5Hash: UUID().uuidString,
            lastOpened: Date(timeIntervalSince1970: 1_700_000_000),
            readingPosition: places.position,
            bookmarks: places.bookmarks,
            waitingSkippedHeadings: places.waitingSkippedHeadings
        )
        book.setSkippedHeadings(places.skippedHeadings)
        return book
    }

    // MARK: - The Guarded Take

    /// With nothing changed meanwhile every place moves, the result says so,
    /// and nothing else of the book changes.
    func testEveryPlaceMovesWhenNothingChangedMeanwhile() {
        let moving = Moving()
        var book = Self.book(holding: moving.original)
        let untouched = book

        XCTAssertTrue(book.takeMovedPlaces(original: moving.original, moved: moving.movedPlaces))

        XCTAssertEqual(book.relocatablePlaces, moving.movedPlaces)
        XCTAssertEqual(book.skippedHeadingIDs, [moving.movedSkip.id], "the IDs follow the skips")
        // Put the places back and the whole book is as it was.
        book.takeMovedPlaces(original: moving.movedPlaces, moved: moving.original)
        XCTAssertEqual(book, untouched)
    }

    /// A place saved during this run keeps fractions of a second that its
    /// row and record, which store dates to the second, have lost: read
    /// back from its record it is still the place as it was, so it moves
    /// (the rebuild task found the difference).
    func testAPlaceReadBackFromItsRecordIsStillAsItWas() throws {
        let moving = Moving()
        var position = moving.position
        position.lastUpdated = Date(timeIntervalSince1970: 1_700_000_000.25)
        let mark = Bookmark(id: moving.markA.id, number: 1, chapterIndex: 1, characterOffset: 20, label: "A",
                            dateCreated: Date(timeIntervalSince1970: 1_700_000_000.75))
        var original = moving.original
        original.position = position
        original.bookmarks = [mark, moving.markB]
        var stored = try Self.storedAsRecord(Self.book(holding: original))
        XCTAssertNotEqual(stored.readingPosition, position, "the record keeps dates to the second")
        XCTAssertNotEqual(stored.bookmarks.first, mark, "the record keeps dates to the second")

        XCTAssertTrue(stored.takeMovedPlaces(original: original, moved: moving.movedPlaces))

        XCTAssertEqual(stored.readingPosition, moving.movedPosition)
        XCTAssertEqual(stored.bookmarks.map(\.characterOffset), moving.movedPlaces.bookmarks.map(\.characterOffset))
        // A place truly saved meanwhile is still kept.
        var later = stored
        later.readingPosition = ReadingPosition(chapterIndex: 1, characterOffset: 11)
        XCTAssertFalse(later.takeMovedPlaces(original: original, moved: moving.movedPlaces))
    }

    /// With every place as `moved` already, nothing changes and the result
    /// is false.
    func testNothingChangesWhenEveryPlaceIsAsMovedAlready() {
        let moving = Moving()
        var book = Self.book(holding: moving.movedPlaces)
        let untouched = book

        XCTAssertFalse(book.takeMovedPlaces(original: moving.original, moved: moving.movedPlaces))
        XCTAssertEqual(book, untouched)
    }

    /// A position saved meanwhile is kept, while the bookmarks move.
    func testAPositionSavedMeanwhileIsKeptWhileBookmarksMove() {
        let moving = Moving()
        let savedMeanwhile = ReadingPosition(chapterIndex: 3, characterOffset: 5)
        var places = moving.original
        places.position = savedMeanwhile
        var book = Self.book(holding: places)

        XCTAssertTrue(book.takeMovedPlaces(original: moving.original, moved: moving.movedPlaces))

        XCTAssertEqual(book.readingPosition, savedMeanwhile)
        XCTAssertEqual(book.bookmarks, [moving.moved(moving.markA), moving.moved(moving.markB)])
    }

    /// A bookmark whose label changed meanwhile keeps the change and its old
    /// place, while another bookmark moves.
    func testABookmarkRelabeledMeanwhileStaysWhileAnotherMoves() {
        let moving = Moving()
        var relabeled = moving.markA
        relabeled.label = "A, renamed"
        var places = moving.original
        places.bookmarks = [relabeled, moving.markB]
        var book = Self.book(holding: places)

        XCTAssertTrue(book.takeMovedPlaces(original: moving.original, moved: moving.movedPlaces))

        XCTAssertEqual(book.bookmarks, [relabeled, moving.moved(moving.markB)])
        XCTAssertEqual(book.readingPosition, moving.movedPosition)
    }

    /// A bookmark added meanwhile stays, and one removed meanwhile is not
    /// brought back; the book's order is kept.
    func testABookmarkAddedStaysAndOneRemovedIsNotBroughtBack() {
        let moving = Moving()
        let added = Bookmark(number: 3, chapterIndex: 0, characterOffset: 7, label: "Added")
        var places = moving.original
        // The book now holds B, then the new one; A was removed.
        places.bookmarks = [moving.markB, added]
        var book = Self.book(holding: places)

        XCTAssertTrue(book.takeMovedPlaces(original: moving.original, moved: moving.movedPlaces))

        XCTAssertEqual(book.bookmarks, [moving.moved(moving.markB), added])
    }

    /// A skip toggled meanwhile keeps both skip lists as they are, while the
    /// position moves; so does a waiting skip changed alone.
    func testASkipToggledMeanwhileKeepsBothSkipLists() {
        let moving = Moving()
        let toggled = SkippedHeading(level: 1, label: "Toggled", chapterIndex: 0, characterOffset: 3)

        var named = moving.original
        named.skippedHeadings = [moving.skip, toggled]
        var book = Self.book(holding: named)
        XCTAssertTrue(book.takeMovedPlaces(original: moving.original, moved: moving.movedPlaces))
        XCTAssertEqual(book.skippedHeadings, [moving.skip, toggled])
        XCTAssertEqual(book.skippedHeadingIDs, [moving.skip.id, toggled.id])
        XCTAssertEqual(book.waitingSkippedHeadings, [moving.wait])
        XCTAssertEqual(book.readingPosition, moving.movedPosition)

        var waiting = moving.original
        waiting.waitingSkippedHeadings = []
        var other = Self.book(holding: waiting)
        XCTAssertTrue(other.takeMovedPlaces(original: moving.original, moved: moving.movedPlaces))
        XCTAssertEqual(other.skippedHeadings, [moving.skip])
        XCTAssertNil(other.waitingSkippedHeadings)
        XCTAssertEqual(other.readingPosition, moving.movedPosition)
    }

    /// Skips that move to none leave the book with none, not empty lists.
    func testSkipsMovedToNoneLeaveNilLists() {
        let moving = Moving()
        var book = Self.book(holding: moving.original)
        var moved = moving.movedPlaces
        moved.skippedHeadings = []
        moved.waitingSkippedHeadings = []

        XCTAssertTrue(book.takeMovedPlaces(original: moving.original, moved: moved))

        XCTAssertNil(book.skippedHeadings)
        XCTAssertNil(book.skippedHeadingIDs)
        XCTAssertNil(book.waitingSkippedHeadings)
    }

    // MARK: - Places to Move

    /// A book with no places, or whose only place is its start, has none to
    /// move; an audiobook has none, whatever it holds.
    func testBooksWithoutPlacesHoldNoneToMove() {
        XCTAssertFalse(Self.book(holding: PlaceRelocator.Places()).holdsPlacesToMove)
        XCTAssertFalse(Self.book(holding: PlaceRelocator.Places(position: ReadingPosition(chapterIndex: 0, characterOffset: 0))).holdsPlacesToMove)

        var audiobook = Book(
            title: "Audio", format: .audio, filePath: "/tmp/audio.m4b", md5Hash: "hash",
            bookmarks: [Bookmark(number: 1, chapterIndex: 0, characterOffset: 90)]
        )
        audiobook.setSkippedHeadings([Self.named])
        XCTAssertFalse(audiobook.holdsPlacesToMove)
    }

    /// Any one place past the start counts: a bookmark, a skip, a waiting
    /// skip, a position in a later chapter or further into the first.
    func testEachKindOfPlaceCounts() {
        let kinds: [(String, PlaceRelocator.Places)] = [
            ("bookmark", PlaceRelocator.Places(bookmarks: [Bookmark(number: 1, chapterIndex: 0, characterOffset: 0)])),
            ("skip", PlaceRelocator.Places(skippedHeadings: [Self.named])),
            ("waiting skip", PlaceRelocator.Places(waitingSkippedHeadings: [Self.waiting])),
            ("later chapter", PlaceRelocator.Places(position: ReadingPosition(chapterIndex: 1, characterOffset: 0))),
            ("further in", PlaceRelocator.Places(position: ReadingPosition(chapterIndex: 0, characterOffset: 1))),
        ]
        for (name, places) in kinds {
            XCTAssertTrue(Self.book(holding: places).holdsPlacesToMove, name)
        }
    }

    // MARK: - From the Relocator to the Reader

    /// A skip that waits, as the relocator leaves it, then stored as a row
    /// and as a record, skips nothing in the reader, though the section that
    /// slid into its numbers has its ID, and the stored book still holds it,
    /// exactly as it was.
    @MainActor
    func testAWaitingSkipFromTheRelocatorSkipsNothingInTheReader() throws {
        let notes = NotesBook()
        let skip = try SavedPlace.skip(of: notes.firstHeading, in: notes.both)
        var book = Self.book(skipped: [skip])
        let original = book.relocatablePlaces
        let outcome = PlaceRelocator(oldTexts: notes.both, newTexts: notes.withoutFirst, oldHeadings: [notes.firstHeading, notes.secondHeading], newHeadings: [notes.slidHeading])
            .relocate(original, movedAt: SavedPlace.moveDate)

        XCTAssertTrue(book.takeMovedPlaces(original: original, moved: outcome.places))

        for (name, stored) in [("row", try Self.storedAsRow(book)), ("record", try Self.storedAsRecord(book))] {
            XCTAssertEqual(stored.waitingSkippedHeadings, [skip], name)
            let reader = makeReader(book: stored)
            addTeardownBlock { @MainActor in reader.close() }
            XCTAssertFalse(reader.isHeadingSkipped(notes.slidHeading), name)
            XCTAssertTrue(reader.skippedHeadingIDs.isEmpty, name)
        }
    }

    /// Open `book` in a reader backed by an isolated library and settings,
    /// as `HeadingVocabularyTests` does.
    @MainActor
    private func makeReader(book: Book) -> ReaderViewModel {
        let library = LibraryViewModel()
        library.library = Library(books: [book])
        return ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        )
    }
}
