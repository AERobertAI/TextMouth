import AppKit
import Combine
import XCTest
@testable import TextMouth

/// The startup batch's summaries and progress (TODO PERF12): finished books'
/// summaries reach the library together, at most every half second, at the
/// end of a pass, and at quit; and the batch's progress is an object of its
/// own, so it never publishes the library model.
@MainActor
final class ContentAnalysisSummaryBufferTests: XCTestCase {

    // MARK: - Reaching the Library Together

    /// Summaries wait instead of changing their rows one by one, then reach
    /// the library in one change, within the flush interval.
    func testSummariesWaitThenReachTheLibraryInOneChange() async throws {
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        let model = makeModel(bookCount: 4)
        var libraryChanges = 0
        let counter = model.$library.dropFirst().sink { _ in libraryChanges += 1 }
        defer { counter.cancel() }
        let reached = expectation(description: "The summaries reached the library")
        let watcher = model.$library.dropFirst().prefix(1).sink { _ in reached.fulfill() }
        defer { watcher.cancel() }

        for book in model.library.books.prefix(3) {
            model.analysisSummaries.add(Self.summary(of: book, words: 1_234))
        }
        XCTAssertEqual(libraryChanges, 0, "a summary changed its row at once")
        XCTAssertEqual(model.analysisSummaries.pendingCount, 3)

        await fulfillment(of: [reached], timeout: 2 + ContentAnalysisSummaryBuffer.flushInterval)

        XCTAssertEqual(libraryChanges, 1)
        XCTAssertEqual(model.library.books.map(\.totalWordCount), [1_234, 1_234, 1_234, nil])
        XCTAssertEqual(model.analysisSummaries.pendingCount, 0)
    }

    /// A flush, as a pass's end makes, applies the waiting summaries at once,
    /// and the flush scheduled for them then finds nothing to do.
    func testAFlushAppliesTheWaitingSummariesAtOnce() async throws {
        var applications: [[ContentAnalysisSummary]] = []
        let buffer = ContentAnalysisSummaryBuffer(notificationCenter: NotificationCenter()) {
            applications.append($0)
        }
        let books = Self.books(count: 2)

        buffer.add(Self.summary(of: books[0], words: 10))
        buffer.add(Self.summary(of: books[1], words: 20))
        buffer.flush()
        try await Task.sleep(for: .seconds(ContentAnalysisSummaryBuffer.flushInterval * 2))

        XCTAssertEqual(applications.map { $0.map(\.bookID) }, [[books[0].id, books[1].id]])
        XCTAssertEqual(buffer.pendingCount, 0)
    }

    /// Summaries that keep arriving for longer than a second reach the
    /// library at most once per flush interval, plus the pass's final
    /// flush, and every one of them exactly once.
    func testSteadySummariesReachTheLibraryAtMostOncePerInterval() async throws {
        var applications: [[ContentAnalysisSummary]] = []
        let buffer = ContentAnalysisSummaryBuffer(notificationCenter: NotificationCenter()) {
            applications.append($0)
        }
        let books = Self.books(count: 24)
        let clock = ContinuousClock()
        let start = clock.now

        // One finished book every 50 ms, for 1.2 seconds.
        for book in books {
            buffer.add(Self.summary(of: book, words: 5))
            try await Task.sleep(for: .milliseconds(50))
        }
        buffer.flush()
        let elapsed = clock.now - start

        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let allowed = Int((seconds / ContentAnalysisSummaryBuffer.flushInterval).rounded(.up)) + 1
        XCTAssertLessThanOrEqual(applications.count, allowed)
        XCTAssertGreaterThanOrEqual(applications.count, 2, "nothing was applied before the pass ended")
        XCTAssertEqual(applications.flatMap { $0 }.map(\.bookID), books.map(\.id))
    }

    /// Summaries still waiting when TextMouth quits reach the library as it
    /// quits.
    func testWaitingSummariesAreFlushedWhenTextMouthQuits() {
        let center = NotificationCenter()
        var applied: [UUID] = []
        let buffer = ContentAnalysisSummaryBuffer(notificationCenter: center) {
            applied.append(contentsOf: $0.map(\.bookID))
        }
        let book = Self.books(count: 1)[0]
        buffer.add(Self.summary(of: book, words: 7))

        center.post(name: NSApplication.willTerminateNotification, object: nil)

        XCTAssertEqual(applied, [book.id])
        XCTAssertEqual(buffer.pendingCount, 0)
    }

    // MARK: - Applying

    /// Applying gives each row its summary's analysis fields and nothing
    /// else, in one change of the library: a book no longer in the library
    /// is skipped, and for a book summarized twice the later summary wins.
    func testApplyingChangesEachRowOnceAndSkipsBooksThatLeft() throws {
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        let model = makeModel(bookCount: 2)
        var row = model.library.books[0]
        row.readingPosition = ReadingPosition(characterOffset: 77)
        model.library.books[0] = row
        let departed = Self.books(count: 1)[0]
        var libraryChanges = 0
        let counter = model.$library.dropFirst().sink { _ in libraryChanges += 1 }
        defer { counter.cancel() }

        model.applyAnalysisSummaries([
            Self.summary(of: row, words: 1),
            Self.summary(of: departed, words: 2),
            Self.summary(of: row, words: 3)
        ])

        XCTAssertEqual(libraryChanges, 1)
        XCTAssertEqual(model.library.books[0].totalWordCount, 3)
        XCTAssertEqual(model.library.books[0].readingPosition?.characterOffset, 77, "the row lost its own state")
        XCTAssertNil(model.library.books[1].totalWordCount)
        XCTAssertEqual(model.library.books.count, 2)
    }

    /// Summaries for books none of which is in the library change nothing.
    func testApplyingOnlyDepartedBooksChangesNothing() {
        let model = makeModel(bookCount: 1)
        var libraryChanges = 0
        let counter = model.$library.dropFirst().sink { _ in libraryChanges += 1 }
        defer { counter.cancel() }

        model.applyAnalysisSummaries([Self.summary(of: Self.books(count: 1)[0], words: 9)])

        XCTAssertEqual(libraryChanges, 0)
    }

    // MARK: - Progress

    /// The batch's progress counts its books and says what it does, and
    /// ending it clears the line but keeps the counts.
    func testProgressCountsTheBatchAndSaysWhatItDoes() {
        let progress = TextExtractionProgress()

        progress.begin("Updating text cache", total: 3)
        XCTAssertTrue(progress.isExtracting)
        XCTAssertEqual(progress.message, "Updating text cache: 0 of 3...")
        progress.advance()
        progress.advance()
        XCTAssertEqual(progress.current, 2)
        XCTAssertEqual(progress.message, "Updating text cache: 2 of 3...")
        progress.end()

        XCTAssertFalse(progress.isExtracting)
        XCTAssertEqual(progress.message, "")
        XCTAssertEqual(progress.current, 2)
        XCTAssertEqual(progress.total, 3)
    }

    /// Progress publishes its own object, never the library model, whose
    /// every publish re-renders each Library window's list.
    func testProgressNeverPublishesTheLibraryModel() {
        let model = makeModel(bookCount: 1)
        var modelPublishes = 0
        var progressPublishes = 0
        let watchers = [
            model.objectWillChange.sink { modelPublishes += 1 },
            model.textExtraction.objectWillChange.sink { progressPublishes += 1 }
        ]
        defer { watchers.forEach { $0.cancel() } }

        model.textExtraction.begin("Re-extracting text", total: 2)
        model.textExtraction.advance()
        model.textExtraction.end()

        XCTAssertEqual(modelPublishes, 0)
        XCTAssertGreaterThan(progressPublishes, 0)
        XCTAssertFalse(model.isExtracting)
    }

    // MARK: - Moves the Record Took

    /// The row takes only the moves its record took: when the record took
    /// every move, so does the row.
    func testTheRowTakesEveryMoveTheRecordTook() {
        let moving = Moving()
        var row = Self.book(holding: moving.original)

        Self.summary(from: moving.original, to: moving.moved, recordedAs: moving.moved).apply(to: &row)

        XCTAssertEqual(row.relocatablePlaces, moving.moved)
    }

    /// Another Mac wrote a newer position into the record, which refused the
    /// position's move: the row keeps the position it had, which the move
    /// would have dated at the move and made look newer than the other Mac's
    /// save. The bookmarks and the skips, which the record took, move.
    func testARefusedPositionStaysWhileTheMovesTheRecordTookMove() {
        let moving = Moving()
        var row = Self.book(holding: moving.original)
        var otherMacs = moving.moved
        otherMacs.position = Self.position(chapter: 3, offset: 9, savedAt: 1_700_000_600)

        Self.summary(from: moving.original, to: moving.moved, recordedAs: otherMacs).apply(to: &row)

        XCTAssertEqual(row.readingPosition, moving.original.position)
        XCTAssertEqual(row.bookmarks, moving.moved.bookmarks)
        XCTAssertEqual(row.skippedHeadings, moving.moved.skippedHeadings)
        XCTAssertEqual(row.waitingSkippedHeadings, moving.moved.waitingSkippedHeadings)
    }

    /// The record holds its places as read back from its file, with dates
    /// cut to whole seconds: the moves are still the ones it took, so the
    /// row takes them.
    func testMovesTheRecordHoldsWithDatesToTheSecondAreTaken() {
        let moving = Moving()
        var fractional = moving.moved
        fractional.position?.lastUpdated = Date(timeIntervalSince1970: 1_700_000_200.75)
        fractional.bookmarks = fractional.bookmarks.map { mark in
            var dated = mark
            dated.dateCreated = Date(timeIntervalSince1970: 1_700_000_100.5)
            return dated
        }
        var readBack = fractional
        readBack.position?.lastUpdated = Date(timeIntervalSince1970: 1_700_000_200)
        readBack.bookmarks = readBack.bookmarks.map { mark in
            var dated = mark
            dated.dateCreated = Date(timeIntervalSince1970: 1_700_000_100)
            return dated
        }
        XCTAssertNotEqual(readBack.position, fractional.position, "the fixture's record should have lost the fractions")
        var row = Self.book(holding: moving.original)

        Self.summary(from: moving.original, to: fractional, recordedAs: readBack).apply(to: &row)

        XCTAssertEqual(row.readingPosition, fractional.position)
        XCTAssertEqual(row.bookmarks, fractional.bookmarks)
    }

    /// Another Mac changed one bookmark in the record (the same ID, another
    /// note), which refused its move: that bookmark stays as the row has it,
    /// and the other bookmark, the position, and the skips move.
    func testABookmarkAnotherMacChangedStaysWhileTheOthersMove() throws {
        let moving = Moving()
        var row = Self.book(holding: moving.original)
        var changed = try XCTUnwrap(moving.moved.bookmarks.first)
        changed.label = "A, renamed on the other Mac"
        var otherMacs = moving.moved
        otherMacs.bookmarks = [changed] + moving.moved.bookmarks.dropFirst()

        Self.summary(from: moving.original, to: moving.moved, recordedAs: otherMacs).apply(to: &row)

        let unchanged = try XCTUnwrap(moving.original.bookmarks.first)
        XCTAssertEqual(row.bookmarks, [unchanged] + moving.moved.bookmarks.dropFirst())
        XCTAssertEqual(row.readingPosition, moving.moved.position)
        XCTAssertEqual(row.skippedHeadings, moving.moved.skippedHeadings)
    }

    /// The listener toggled a skip in the record, which refused the skips'
    /// move: both of the row's skip lists stay as they were, and the
    /// position and the bookmarks move.
    func testSkipsTheListenerToggledStayWhileTheOtherPlacesMove() {
        let moving = Moving()
        var row = Self.book(holding: moving.original)
        var toggled = moving.moved
        toggled.skippedHeadings = [SkippedHeading(level: 1, label: "Toggled", chapterIndex: 0, characterOffset: 3)]

        Self.summary(from: moving.original, to: moving.moved, recordedAs: toggled).apply(to: &row)

        XCTAssertEqual(row.skippedHeadings, moving.original.skippedHeadings)
        XCTAssertEqual(row.waitingSkippedHeadings, moving.original.waitingSkippedHeadings)
        XCTAssertEqual(row.readingPosition, moving.moved.position)
        XCTAssertEqual(row.bookmarks, moving.moved.bookmarks)
    }

    /// A move with no original of its bookmark's ID is not trapped on: the
    /// bookmark stays as the move has it.
    func testAMovedBookmarkWithNoOriginalStaysAsMoved() throws {
        let moving = Moving()
        let extra = Bookmark(number: 3, chapterIndex: 0, characterOffset: 5, label: "Extra", dateCreated: Date(timeIntervalSince1970: 1_700_000_050))
        var movedWithExtra = moving.moved
        movedWithExtra.bookmarks.append(extra)
        let movedPlaces = MovedPlaces(bookID: UUID(), original: moving.original, moved: movedWithExtra, snapshot: nil)

        let narrowed = movedPlaces.taken(by: Self.book(holding: moving.original))

        XCTAssertEqual(narrowed.moved.bookmarks, moving.original.bookmarks + [extra])
    }

    // MARK: - Fixtures

    /// Places a rebuild moves, and the same places moved: every place in
    /// `moved` differs from its place in `original`, so a test can tell which
    /// ones a row took. The bookmarks keep their IDs, as the relocator leaves
    /// them.
    private struct Moving {
        let original = PlaceRelocator.Places(
            position: ContentAnalysisSummaryBufferTests.position(chapter: 1, offset: 10, savedAt: 1_700_000_000),
            bookmarks: [
                Bookmark(number: 1, chapterIndex: 1, characterOffset: 20, label: "A", dateCreated: Date(timeIntervalSince1970: 1_700_000_001)),
                Bookmark(number: 2, chapterIndex: 2, characterOffset: 30, label: "B", dateCreated: Date(timeIntervalSince1970: 1_700_000_002)),
            ],
            skippedHeadings: [SkippedHeading(level: 2, label: "Notes", chapterIndex: 1, characterOffset: 40)],
            waitingSkippedHeadings: [SkippedHeading(level: 3, label: "Appendix", chapterIndex: 3, characterOffset: 50)]
        )

        /// The places as the relocator moved them: every place five
        /// characters on, the position dated at the move.
        var moved: PlaceRelocator.Places {
            PlaceRelocator.Places(
                position: ContentAnalysisSummaryBufferTests.position(chapter: 1, offset: 15, savedAt: 1_700_000_300),
                bookmarks: original.bookmarks.map { mark in
                    var shifted = mark
                    shifted.characterOffset += 5
                    return shifted
                },
                skippedHeadings: [SkippedHeading(level: 2, label: "Notes", chapterIndex: 1, characterOffset: 45)],
                waitingSkippedHeadings: [SkippedHeading(level: 3, label: "Appendix", chapterIndex: 3, characterOffset: 55)]
            )
        }
    }

    /// A reading position saved at `seconds` since 1970.
    private nonisolated static func position(chapter: Int, offset: Int, savedAt seconds: TimeInterval) -> ReadingPosition {
        var position = ReadingPosition(chapterIndex: chapter, characterOffset: offset)
        position.lastUpdated = Date(timeIntervalSince1970: seconds)
        return position
    }

    /// A plain text book holding `places`.
    private static func book(holding places: PlaceRelocator.Places) -> Book {
        var book = Book(
            title: "Moved Places", format: .txt,
            filePath: "/tmp/\(UUID().uuidString)-moved-places.txt", md5Hash: UUID().uuidString,
            readingPosition: places.position,
            bookmarks: places.bookmarks,
            waitingSkippedHeadings: places.waitingSkippedHeadings
        )
        book.setSkippedHeadings(places.skippedHeadings)
        return book
    }

    /// The summary of a book whose record holds `recorded` places once the
    /// analysis is saved, for a rebuild that moved the places `original` to
    /// `moved`.
    private static func summary(
        from original: PlaceRelocator.Places,
        to moved: PlaceRelocator.Places,
        recordedAs recorded: PlaceRelocator.Places
    ) -> ContentAnalysisSummary {
        let committed = book(holding: recorded)
        return ContentAnalysisSummary(
            committed: committed,
            movedPlaces: MovedPlaces(bookID: committed.id, original: original, moved: moved, snapshot: nil)
        )
    }

    // MARK: - Other Fixtures

    /// An inert model holding `bookCount` plain text books.
    private func makeModel(bookCount: Int) -> LibraryViewModel {
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: Self.books(count: bookCount))
        return model
    }

    /// `count` plain text books with no analysis yet.
    private static func books(count: Int) -> [Book] {
        (0..<count).map {
            Book(title: "Summary \($0)", format: .txt, filePath: "/tmp/summary-\($0).txt", md5Hash: "summary-\($0)")
        }
    }

    /// A summary of `book` analyzed to `words` words, as a pass makes once
    /// its package record holds the analysis.
    private static func summary(of book: Book, words: Int) -> ContentAnalysisSummary {
        var committed = book
        committed.totalWordCount = words
        committed.totalCharacterCount = words * 6
        committed.contentIndexVersion = BookContentIndex.currentVersion
        return ContentAnalysisSummary(committed: committed)
    }
}
