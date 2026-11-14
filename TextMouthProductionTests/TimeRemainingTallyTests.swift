import XCTest
@testable import TextMouth

/// The Library's summary bar adds up the time left once and keeps it, so a
/// reader's live position, reported about once a second, costs an estimate
/// of the books readers have open and not of every book listed (the audit's
/// C7, November 13, 2026), and says what a full addition says.
@MainActor
final class TimeRemainingTallyTests: XCTestCase {

    /// The speed the tests count at, in words a minute.
    private static let wpm = 200.0

    // MARK: - The Same Figures

    /// What the bar added up before the tally: each book copied with its
    /// live position in place of its own, in the list's order.
    private func fullRecomputation(
        of books: [Book],
        wpm: Double = TimeRemainingTallyTests.wpm,
        livePositions: LiveReadingPositions
    ) -> TimeRemainingTally.Sum {
        var sum = TimeRemainingTally.Sum()
        for book in books {
            if let remaining = livePositions.applied(to: book).estimatedTimeRemaining(wpm: wpm) {
                sum.time += remaining
                sum.known += 1
            } else {
                sum.unknown += 1
            }
        }
        return sum
    }

    /// A library of books of every kind the sum meets: text books read and
    /// unread, books whose length is not known, and audiobooks.
    private func makeBooks(count: Int) throws -> [Book] {
        var books = try LibraryBenchmarkFixture.library(bookCount: count).books
        for index in books.indices {
            switch index % 11 {
            case 3:
                // A book whose length is not known has no time left to give.
                books[index].totalCharacterCount = nil
                books[index].totalWordCount = nil
            case 5:
                books[index].format = .audio
                books[index].audioDuration = 3_600 + Double(index)
            default:
                break
            }
        }
        return books
    }

    /// With no live position, with one, with several, and after they go, the
    /// tally's figures equal the full addition's, to the last bit.
    func testTheTallyAddsUpTheFiguresOfAFullAddition() throws {
        let model = LibraryViewModel(initializeServices: false)
        let books = try makeBooks(count: 300)
        model.library = Library(books: books, folders: [])
        let tally = TimeRemainingTally()
        let live = model.livePositions

        XCTAssertEqual(tally.sum(of: books, wpm: Self.wpm, livePositions: live), fullRecomputation(of: books, livePositions: live))

        for (step, index) in [1, 5, 40, 41, 299].enumerated() {
            let total = books[index].totalCharacterCount ?? 10_000
            let offset = total / 2 + step
            model.updateLiveReadingPosition(
                bookID: books[index].id,
                position: ReadingPosition(chapterIndex: 0, characterOffset: offset, globalCharacterOffset: offset)
            )
            XCTAssertEqual(
                tally.sum(of: books, wpm: Self.wpm, livePositions: live),
                fullRecomputation(of: books, livePositions: live),
                "after the live position of book \(index)"
            )
        }
        XCTAssertEqual(TimeRemainingTally.sum(of: books, wpm: Self.wpm, livePositions: live), fullRecomputation(of: books, livePositions: live))

        live.keepOnly([])
        XCTAssertEqual(tally.sum(of: books, wpm: Self.wpm, livePositions: live), fullRecomputation(of: books, livePositions: live))
    }

    /// The bar's spoken summary says what the tally adds up: the label with a
    /// live position is the one a full addition gives.
    func testTheSpokenSummaryFollowsALivePosition() throws {
        let model = LibraryViewModel(initializeServices: false)
        let books = try makeBooks(count: 40)
        model.library = Library(books: books, folders: [])
        let before = TimeRemainingBar(books: books, wpm: Self.wpm, livePositions: model.livePositions).summaryAccessibilityLabel

        model.updateLiveReadingPosition(
            bookID: books[0].id,
            position: ReadingPosition(chapterIndex: 0, characterOffset: 1, globalCharacterOffset: 1)
        )
        let after = TimeRemainingBar(books: books, wpm: Self.wpm, livePositions: model.livePositions).summaryAccessibilityLabel

        let full = fullRecomputation(of: books, livePositions: model.livePositions)
        XCTAssertTrue(after.contains(TimeFormatting.spoken(full.time)), after)
        XCTAssertNotEqual(before, after)
    }

    // MARK: - What a Redraw Costs

    /// 1,500 books and one reader: the first addition estimates every book,
    /// and each of ten live updates estimates one, the book playing, not
    /// the 15,000 that adding the list up each time did.
    func testTenLiveUpdatesEstimateTenBooksNotFifteenThousand() throws {
        let model = LibraryViewModel(initializeServices: false)
        let books = try makeBooks(count: 1_500)
        model.library = Library(books: books, folders: [])
        let tally = TimeRemainingTally()
        let live = model.livePositions
        let playing = books[700]
        _ = tally.sum(of: books, wpm: Self.wpm, livePositions: live)
        XCTAssertEqual(tally.estimateCount, 1_500, "the first addition estimates every book")
        let total = try XCTUnwrap(playing.totalCharacterCount)

        for second in 1...10 {
            let offset = total / 4 + second * 100
            model.updateLiveReadingPosition(
                bookID: playing.id,
                position: ReadingPosition(chapterIndex: 0, characterOffset: offset, globalCharacterOffset: offset)
            )
            let sum = tally.sum(of: books, wpm: Self.wpm, livePositions: live)
            XCTAssertEqual(sum, fullRecomputation(of: books, livePositions: live), "second \(second)")
        }

        XCTAssertEqual(tally.estimateCount, 1_510, "ten live updates cost ten estimates")
    }

    /// The figures are made again when the list is, which a library change
    /// does, or when the speed changes, and then only.
    func testAChangedListOrSpeedIsAddedUpAgain() throws {
        let model = LibraryViewModel(initializeServices: false)
        let books = try makeBooks(count: 200)
        let tally = TimeRemainingTally()
        let live = model.livePositions
        _ = tally.sum(of: books, wpm: Self.wpm, livePositions: live)
        _ = tally.sum(of: books, wpm: Self.wpm, livePositions: live)
        XCTAssertEqual(tally.estimateCount, 200, "the same list at the same speed was added up again")

        // A change of one book's position, as a checkpoint makes it, gives
        // a list of its own storage.
        var checkpointed = books
        let total = try XCTUnwrap(checkpointed[10].totalCharacterCount)
        checkpointed[10].readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: total / 3, globalCharacterOffset: total / 3)
        let afterCheckpoint = tally.sum(of: checkpointed, wpm: Self.wpm, livePositions: live)
        XCTAssertEqual(afterCheckpoint, fullRecomputation(of: checkpointed, livePositions: live))
        XCTAssertEqual(tally.estimateCount, 400, "a changed list was not added up again")
        XCTAssertNotEqual(afterCheckpoint, tally.sum(of: books, wpm: Self.wpm, livePositions: live), "the old list shows the new position")

        let slower = tally.sum(of: checkpointed, wpm: 100, livePositions: live)
        XCTAssertEqual(slower, fullRecomputation(of: checkpointed, wpm: 100, livePositions: live))
        XCTAssertGreaterThan(slower.time, afterCheckpoint.time)
    }

    /// The store knows which books have a live position as readers report
    /// and close.
    func testTheStoreNamesTheBooksWithALivePosition() throws {
        let model = LibraryViewModel(initializeServices: false)
        let books = try makeBooks(count: 5)
        model.library = Library(books: books, folders: [])
        let live = model.livePositions
        XCTAssertTrue(live.liveBookIDs.isEmpty)

        model.updateLiveReadingPosition(
            bookID: books[2].id,
            position: ReadingPosition(chapterIndex: 0, characterOffset: 7, globalCharacterOffset: 7)
        )
        XCTAssertEqual(live.liveBookIDs, [books[2].id])

        live.keepOnly([books[2].id])
        XCTAssertEqual(live.liveBookIDs, [books[2].id], "a book a reader still has open lost its live position")
        live.keepOnly([])
        XCTAssertTrue(live.liveBookIDs.isEmpty)
    }
}
