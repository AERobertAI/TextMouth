import XCTest
@testable import TextMouth

/// A book's saved places are checked at every load of its text (T06's branch
/// E, TEXT-ANCHORS-ADDENDUM-2026-10-10.md, section 9): one whose saved words
/// are not at its numbers is found by them, with no old text. This is the
/// backstop for every path a rebuild does not take: a text another Mac or an
/// editor changed, and a reader that saved at the old numbers while a
/// rebuild moved its book's places. Moves are silent.
final class PlaceRelocationAtLoadTests: CloudMaintenanceTestCase {
    // MARK: A Text That Changed Since Its Places

    /// A reader that opens a book whose text changed since its places were
    /// saved finds them by their words: its cursor, bookmarks, and skipped
    /// heading are on the same words in the new text, and so are the
    /// library's row and the record. The move is logged once, and no copy of
    /// any text is made.
    @MainActor
    func testPlacesFollowTheirWordsWhenTheTextChangedBetweenOpens() throws {
        let fixture = try makeBookWhoseTextChangedSinceItsPlaces(title: "Changed \(UUID().uuidString)")
        let model = makeModel(with: [fixture.book])

        let reader = openReader(on: fixture.book, in: model)
        waitForReaderToLoad(reader)

        // What the reader shows and holds.
        XCTAssertEqual(reader.currentChapterIndex, fixture.position.chapter)
        XCTAssertEqual(reader.currentCharacterOffset, fixture.position.offset)
        XCTAssertEqual(reader.bookmarks.count, 1)
        XCTAssertEqual(reader.bookmarks.first?.chapterIndex, fixture.bookmark.chapter)
        XCTAssertEqual(reader.bookmarks.first?.characterOffset, fixture.bookmark.offset)
        XCTAssertTrue(reader.isHeadingSkipped(fixture.notes))
        XCTAssertEqual(reader.skippedHeadingIDs, [fixture.notes.id])

        // The reader's copy, the row, and the record: the position may carry
        // the date and anchor of the save the load makes, so only its numbers
        // are compared.
        assertPlaces(of: reader.book, areThoseOf: fixture)
        assertPlaces(of: try XCTUnwrap(model.bookByID(fixture.book.id)), areThoseOf: fixture)
        assertPlaces(of: try recordedBook(like: fixture.book), areThoseOf: fixture)

        // Said once in the debug log, and no copy of a text was made.
        XCTAssertEqual(logLineCount("PLACES_RELOCATED: \(fixture.book.title):"), 1)
        XCTAssertFalse(snapshotsHoldACopy(of: fixture.book))
    }

    /// Once the places were found, the same text moves nothing: a read of the
    /// row's book returns no moves, and a second reader leaves the row's
    /// bookmarks and skips exactly as they were, anchors and all, and logs
    /// no second line.
    @MainActor
    func testAnUnchangedBookMovesNothingAtLoad() throws {
        let fixture = try makeBookWhoseTextChangedSinceItsPlaces(title: "Unchanged \(UUID().uuidString)")
        let model = makeModel(with: [fixture.book])
        let first = openReader(on: fixture.book, in: model)
        waitForReaderToLoad(first)
        first.close()
        let moved = try XCTUnwrap(model.bookByID(fixture.book.id))
        assertPlaces(of: moved, areThoseOf: fixture)
        XCTAssertEqual(logLineCount("PLACES_RELOCATED: \(fixture.book.title):"), 1)

        // A read of the book as the row holds it moves nothing.
        XCTAssertEqual(try ReaderViewModel.readContent(of: moved).movedPlaces, [])

        // A second reader changes none of the saved words.
        let second = openReader(on: moved, in: model)
        waitForReaderToLoad(second)
        let reread = try XCTUnwrap(model.bookByID(fixture.book.id))
        XCTAssertEqual(reread.bookmarks, moved.bookmarks)
        XCTAssertEqual(reread.skippedHeadings, moved.skippedHeadings)
        XCTAssertEqual(logLineCount("PLACES_RELOCATED: \(fixture.book.title):"), 1)
    }

    // MARK: Off the Main Thread

    /// The places of a large book are found by `readContent(of:)`, which
    /// runs off the main thread: a million units of text, a place past a
    /// paragraph put in before it, found by its words.
    func testALargeBooksPlacesAreFoundOffTheMainThread() throws {
        let fixture = try makeLargeBookWhoseTextChangedSinceItsPlaces(title: "Large \(UUID().uuidString)")
        let book = fixture.book
        let finished = expectation(description: "The read finished")
        let result = ReadResultBox()

        DispatchQueue.global().async {
            result.ranOnMainThread = Thread.isMainThread
            result.loaded = Result { try ReaderViewModel.readContent(of: book) }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 60)

        XCTAssertFalse(result.ranOnMainThread, "the read should run off the main thread")
        let loaded = try XCTUnwrap(result.loaded).get()
        let moves = loaded.movedPlaces
        XCTAssertEqual(moves.count, 1)
        let moved = try XCTUnwrap(moves.first?.moved)
        XCTAssertEqual(moved.position?.chapterIndex, fixture.position.chapter)
        XCTAssertEqual(moved.position?.characterOffset, fixture.position.offset)
        XCTAssertEqual(moved.bookmarks.first?.chapterIndex, fixture.bookmark.chapter)
        XCTAssertEqual(moved.bookmarks.first?.characterOffset, fixture.bookmark.offset)
        XCTAssertEqual(moved.skippedHeadings.map(\.id), [fixture.notes.id])
        // The move starts from the places the book held.
        XCTAssertEqual(moves.first?.original, book.relocatablePlaces)
    }

    // MARK: A Reader That Saved at the Old Numbers

    /// A reader that stays open while a rebuild moves its book's places, and
    /// then saves its position at the old text's numbers, is caught at the
    /// next load: the saved position keeps its words, which the new text
    /// holds elsewhere, so the next reader opens at them and the row's
    /// position follows.
    @MainActor
    func testAReaderThatSavedAtTheOldNumbersDuringARebuildIsCaughtAtTheNextLoad() async throws {
        // The older text, described as current so the first reader does not
        // rebuild it.
        let fixture = try makeBookInAnOlderText(title: "Stale \(UUID().uuidString)")
        var older = fixture.book
        older.cacheFormatVersion = MarkdownCacheService.currentCacheVersion
        try older.saveBookInfoThrowing()
        let current = try recordedBook(like: older)
        let oldPosition = try XCTUnwrap(current.readingPosition)
        let model = makeModel(with: [current])

        // A reader opens at the older text's numbers and stays open.
        let open = openReader(on: current, in: model)
        await waitForReaderToLoadYielding(open)
        XCTAssertEqual(open.currentChapterIndex, oldPosition.chapterIndex)
        XCTAssertEqual(open.currentCharacterOffset, oldPosition.characterOffset)

        // The text is rebuilt under a changed extraction: the places move in
        // the row and the record, and the open reader is not told.
        let rebuilt = expectation(description: "Redo Text Extraction finished")
        XCTAssertTrue(model.redoAllTextExtraction(access: .live) { _ in rebuilt.fulfill() })
        await fulfillment(of: [rebuilt], timeout: 20)
        assertPlaces(of: try XCTUnwrap(model.bookByID(current.id)), areThoseOf: fixture)
        XCTAssertEqual(open.currentChapterIndex, oldPosition.chapterIndex)
        XCTAssertEqual(open.currentCharacterOffset, oldPosition.characterOffset)

        // The open reader saves its position, at the old text's numbers.
        open.savePosition()
        let saved = try XCTUnwrap(model.bookByID(current.id)?.readingPosition)
        XCTAssertEqual(saved.chapterIndex, oldPosition.chapterIndex)
        XCTAssertEqual(saved.characterOffset, oldPosition.characterOffset)
        open.close()

        // The next reader finds the position by its words in the new text,
        // and the row follows.
        let next = openReader(on: try XCTUnwrap(model.bookByID(current.id)), in: model)
        await waitForReaderToLoadYielding(next)
        XCTAssertEqual(next.currentChapterIndex, fixture.position.chapter)
        XCTAssertEqual(next.currentCharacterOffset, fixture.position.offset)
        let row = try XCTUnwrap(model.bookByID(current.id))
        XCTAssertEqual(row.readingPosition?.chapterIndex, fixture.position.chapter)
        XCTAssertEqual(row.readingPosition?.characterOffset, fixture.position.offset)
    }
}

extension PlaceRelocationAtLoadTests {
    /// Waits until `reader` has finished loading, yielding the main actor
    /// between looks, as a test that is itself async must: the load finishes
    /// on the main queue, which a wait that spins the run loop from inside
    /// an async test never serves. Fails when it takes over ten seconds.
    @MainActor
    func waitForReaderToLoadYielding(_ reader: ReaderViewModel, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(10)
        while reader.isLoading && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(reader.isLoading, "\(reader.book.title) never finished loading", file: file, line: line)
    }
}

/// What a read of a book produced on a background thread, handed back to the
/// test that waits for it. Written once by the reading thread, before it
/// fulfills the expectation the test waits on, and read only after.
private final class ReadResultBox: @unchecked Sendable {
    /// Whether the read ran on the main thread.
    var ranOnMainThread = true
    /// What the read returned or threw.
    var loaded: Result<ReaderViewModel.LoadedContent, Error>?
}
