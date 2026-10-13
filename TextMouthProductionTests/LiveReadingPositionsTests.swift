import Combine
import XCTest
@testable import TextMouth

/// Live reading positions (TODO PERF11): a reader's position between
/// checkpoints reaches the library's rows and summary bar without
/// publishing the library model; only the playing book's row and the bar
/// redraw; a checkpoint takes over at once and is still saved to the
/// library and the book's record; and closing the book's reader drops it.
@MainActor
final class LiveReadingPositionsTests: XCTestCase {

    // MARK: - What a Live Update Reaches

    /// A live update changes the playing book's row (its spoken percent and
    /// time left) and the summary bar, publishing only that book's entry
    /// and the store: never the library model, and never another book's
    /// entry, so no other row redraws.
    func testALiveUpdateRedrawsOnlyItsRowAndTheBar() throws {
        let (model, books) = makeModel()
        let playing = books[0]
        let playingEntry = model.livePositions.entry(for: playing.id)
        let otherEntry = model.livePositions.entry(for: books[1].id)
        var libraryPublishes = 0
        var playingPublishes = 0
        var otherPublishes = 0
        var storePublishes = 0
        let watchers = [
            model.objectWillChange.sink { libraryPublishes += 1 },
            playingEntry.objectWillChange.sink { playingPublishes += 1 },
            otherEntry.objectWillChange.sink { otherPublishes += 1 },
            model.livePositions.objectWillChange.sink { storePublishes += 1 }
        ]
        defer { watchers.forEach { $0.cancel() } }
        let rowBefore = BookRow(book: playing, wpm: 200, livePosition: playingEntry).rowAccessibilityLabel
        let barBefore = summary(of: books, in: model)

        model.updateLiveReadingPosition(bookID: playing.id, position: Self.halfway)

        XCTAssertEqual(libraryPublishes, 0, "the library model published")
        XCTAssertEqual(playingPublishes, 1)
        XCTAssertEqual(storePublishes, 1)
        XCTAssertEqual(otherPublishes, 0, "another book's row would redraw")
        let rowAfter = BookRow(book: playing, wpm: 200, livePosition: playingEntry).rowAccessibilityLabel
        XCTAssertEqual(rowBefore, "Harbor Ledger, by Odile Halvorsen, 10 minutes remaining, Plain Text")
        XCTAssertEqual(rowAfter, "Harbor Ledger, by Odile Halvorsen, 50 percent, 5 minutes remaining, Plain Text")
        XCTAssertNotEqual(summary(of: books, in: model), barBefore)
        XCTAssertNil(model.bookByID(playing.id)?.readingPosition, "the library's row changed")
    }

    /// A report whose cursor has not moved from what the row shows
    /// publishes nothing, however much later it was made.
    func testAReportThatDoesNotMoveTheCursorPublishesNothing() {
        let (model, books) = makeModel()
        let entry = model.livePositions.entry(for: books[0].id)
        model.updateLiveReadingPosition(bookID: books[0].id, position: Self.halfway)
        var publishes = 0
        let watcher = entry.objectWillChange.sink { publishes += 1 }
        defer { watcher.cancel() }

        var later = Self.halfway
        later.lastUpdated = Self.halfway.lastUpdated.addingTimeInterval(5)
        model.updateLiveReadingPosition(bookID: books[0].id, position: later)

        XCTAssertEqual(publishes, 0)
    }

    /// A report for a book the library does not hold records nothing.
    func testAReportForABookNotInTheLibraryRecordsNothing() {
        let (model, _) = makeModel()
        let stranger = UUID()

        model.updateLiveReadingPosition(bookID: stranger, position: Self.halfway)

        XCTAssertNil(model.livePositions.entry(for: stranger).position)
    }

    // MARK: - No Refresh Tick

    /// A row's time left follows its reader's position as it moves, with no
    /// clock (TODO PERF29): each report publishes the book's entry, which
    /// redraws the row, and the row says the new time left at once. The
    /// library model, which a 10-second tick used to publish so that rows
    /// would refresh, publishes nothing at all.
    func testARowsTimeLeftFollowsALivePositionWithNoTick() throws {
        let (model, books) = makeModel()
        let entry = model.livePositions.entry(for: books[0].id)
        var rowRedraws = 0
        var libraryPublishes = 0
        let watchers = [
            entry.objectWillChange.sink { rowRedraws += 1 },
            model.objectWillChange.sink { libraryPublishes += 1 }
        ]
        defer { watchers.forEach { $0.cancel() } }

        var spoken: [String] = []
        for minute in 1...3 {
            // 2,000 words at 200 a minute: each minute read is 1,000 characters.
            let offset = minute * 1_000
            let position = ReadingPosition(chapterIndex: 0, characterOffset: offset, globalCharacterOffset: offset)
            model.updateLiveReadingPosition(bookID: books[0].id, position: position)
            // Read the library's first book afresh on each pass, failing (not trapping) if it is gone.
            let libraryBook = try XCTUnwrap(model.library.books[safe: 0], "the library has no first book")
            spoken.append(BookRow(book: libraryBook, wpm: 200, livePosition: entry).rowAccessibilityLabel)
        }

        XCTAssertEqual(spoken, [
            "Harbor Ledger, by Odile Halvorsen, 10 percent, 9 minutes remaining, Plain Text",
            "Harbor Ledger, by Odile Halvorsen, 20 percent, 8 minutes remaining, Plain Text",
            "Harbor Ledger, by Odile Halvorsen, 30 percent, 7 minutes remaining, Plain Text"
        ])
        XCTAssertEqual(rowRedraws, 3, "each report redraws the row")
        XCTAssertEqual(libraryPublishes, 0, "the library model published")
    }

    // MARK: - Checkpoints and Closing

    /// A checkpoint takes over from the live position at once (it is the
    /// newer), and is still written to the library's row and to the book's
    /// record, as before.
    func testACheckpointTakesOverAndIsStillSaved() throws {
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        let book = try makePackagedBook()
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        model.updateLiveReadingPosition(bookID: book.id, position: Self.halfway)
        var checkpoint = ReadingPosition(chapterIndex: 0, characterOffset: 6_000, globalCharacterOffset: 6_000)
        checkpoint.lastUpdated = Self.halfway.lastUpdated.addingTimeInterval(1)

        model.persistReadingPosition(bookID: book.id, position: checkpoint)
        LibraryPersistenceService.flushPendingSave()

        let row = try XCTUnwrap(model.bookByID(book.id))
        XCTAssertEqual(row.readingPosition, checkpoint)
        XCTAssertEqual(model.livePositions.applied(to: row).readingPosition, checkpoint, "the older live position hid it")
        // The record's date is written to the second, so compare the cursor.
        let recorded = try BookInfo.load(from: book.tmbDirectory).state.readingPosition
        XCTAssertEqual(recorded?.characterOffset, checkpoint.characterOffset)
        XCTAssertEqual(recorded?.globalCharacterOffset, checkpoint.globalCharacterOffset)
    }

    /// A live position never hides a newer position the library holds,
    /// however that position got there; with equal times the library's wins.
    func testALivePositionNeverHidesANewerOrEqualLibraryPosition() throws {
        let (model, books) = makeModel()
        model.updateLiveReadingPosition(bookID: books[0].id, position: Self.halfway)
        var newer = ReadingPosition(chapterIndex: 0, characterOffset: 9_000, globalCharacterOffset: 9_000)

        // One guard covers every position write and read below: nothing here removes a book.
        _ = try XCTUnwrap(model.library.books[safe: 0], "the library has no first book")
        newer.lastUpdated = Self.halfway.lastUpdated
        model.library.books[0].readingPosition = newer
        XCTAssertEqual(model.livePositions.applied(to: model.library.books[0]).readingPosition, newer)

        newer.lastUpdated = Self.halfway.lastUpdated.addingTimeInterval(-1)
        model.library.books[0].readingPosition = newer
        XCTAssertEqual(model.livePositions.applied(to: model.library.books[0]).readingPosition, Self.halfway)
    }

    /// Once no reader has the book open, its live position is dropped and
    /// its row shows the library's position again, publishing its entry
    /// and the store once.
    func testClosingTheBooksReaderDropsItsLivePosition() {
        let (model, books) = makeModel()
        let entry = model.livePositions.entry(for: books[0].id)
        model.openBookIDs.insert(books[0].id)
        model.openBookIDs.insert(books[1].id)
        model.updateLiveReadingPosition(bookID: books[0].id, position: Self.halfway)
        model.updateLiveReadingPosition(bookID: books[1].id, position: Self.halfway)
        var publishes = 0
        let watcher = entry.objectWillChange.sink { publishes += 1 }
        defer { watcher.cancel() }

        model.unregisterOpenBook(books[0].id)

        XCTAssertNil(entry.position)
        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(model.livePositions.applied(to: books[0]).readingPosition, books[0].readingPosition)
        XCTAssertEqual(
            model.livePositions.entry(for: books[1].id).position,
            Self.halfway,
            "a book still open lost its live position"
        )
    }

    // MARK: - Entries

    /// A book's entry is made once and kept: asking again gives the same
    /// object, and asking publishes nothing.
    func testABooksEntryIsMadeOnceAndAskingPublishesNothing() {
        let store = LiveReadingPositions()
        var publishes = 0
        let watcher = store.objectWillChange.sink { publishes += 1 }
        defer { watcher.cancel() }
        let id = UUID()

        XCTAssertTrue(store.entry(for: id) === store.entry(for: id))
        XCTAssertFalse(store.entry(for: id) === store.entry(for: UUID()))
        XCTAssertEqual(publishes, 0)
    }

    /// The inert store and entry, which views made without a library model
    /// use, never hold a position.
    func testTheInertStoreAndEntryHoldNothing() {
        let book = Self.book(title: "Inert", author: "Nobody")

        LiveReadingPositions.inert.update(Self.halfway, of: book)

        XCTAssertNil(LiveReadingPositions.inert.entry(for: book.id).position)
        XCTAssertNil(LiveReadingPosition.inert.position)
        XCTAssertEqual(BookRow(book: book).rowAccessibilityLabel, "Inert, by Nobody, New, 10 minutes remaining, Plain Text")
    }

    // MARK: - Fixtures

    /// Halfway through a fixture book: 5,000 of its 10,000 characters.
    private static let halfway = ReadingPosition(chapterIndex: 0, characterOffset: 5_000, globalCharacterOffset: 5_000)

    /// A model holding two opened books of 10,000 characters and 2,000
    /// words (ten minutes at 200 words a minute), neither with a position.
    private func makeModel() -> (LibraryViewModel, [Book]) {
        var first = Self.book(title: "Harbor Ledger", author: "Odile Halvorsen")
        var second = Self.book(title: "Granary", author: "Tobiah Varga")
        first.lastOpened = Date(timeIntervalSince1970: 100)
        second.lastOpened = Date(timeIntervalSince1970: 200)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [first, second])
        return (model, [first, second])
    }

    /// A plain text book of 10,000 characters and 2,000 words.
    private static func book(title: String, author: String) -> Book {
        Book(
            title: title,
            author: author,
            format: .txt,
            filePath: "/tmp/\(title).txt",
            md5Hash: title,
            totalWordCount: 2_000,
            totalCharacterCount: 10_000
        )
    }

    /// What the summary bar says for `books` with `model`'s live positions.
    private func summary(of books: [Book], in model: LibraryViewModel) -> String {
        TimeRemainingBar(books: books, wpm: 200, livePositions: model.livePositions).summaryAccessibilityLabel
    }

    /// A book of 10,000 characters in a package of its own in the
    /// sandbox's library, so its record can be written; removed when the
    /// test ends.
    private func makePackagedBook() throws -> Book {
        try TextMouthPaths.ensureDirectoryStructure()
        let name = "Live Position-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: name)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }
        let file = package.appendingPathComponent("source.txt")
        try String(repeating: "word ", count: 2_000).write(to: file, atomically: true, encoding: .utf8)
        return Book(
            title: "Packaged",
            format: .txt,
            filePath: file.path,
            md5Hash: UUID().uuidString,
            totalWordCount: 2_000,
            totalCharacterCount: 10_000,
            tmbDirectoryName: name
        )
    }
}
