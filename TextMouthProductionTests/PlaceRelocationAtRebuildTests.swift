import XCTest
@testable import TextMouth

/// A rebuild of a book's text moves the book's saved places from the old
/// text to the new one (T06's branch D, TEXT-ANCHORS-ADDENDUM-2026-10-10.md,
/// section 9): the generation copies the old text aside with the places,
/// writes the new text, and moves the places, which the caller commits with
/// the book's analysis.
final class PlaceRelocationAtRebuildTests: CloudMaintenanceTestCase {
    // MARK: Generation

    /// A book with places, rebuilt from an older text, gets its places moved
    /// onto the same words in the new one, and the copy of the old text
    /// stays until the caller discards it.
    func testAGenerationMovesThePlacesAndKeepsTheCopy() throws {
        let fixture = try makeBookInAnOlderText(title: "Moved \(UUID().uuidString)")

        let generated = try XCTUnwrap(MarkdownCacheService.generateReportedCacheContent(for: fixture.book))
        let moved = try XCTUnwrap(generated.movedPlaces)

        XCTAssertEqual(moved.bookID, fixture.book.id)
        XCTAssertEqual(moved.original, fixture.book.relocatablePlaces)
        XCTAssertEqual(moved.moved.position?.chapterIndex, fixture.position.chapter)
        XCTAssertEqual(moved.moved.position?.characterOffset, fixture.position.offset)
        XCTAssertEqual(moved.moved.bookmarks.first?.chapterIndex, fixture.bookmark.chapter)
        XCTAssertEqual(moved.moved.bookmarks.first?.characterOffset, fixture.bookmark.offset)
        XCTAssertEqual(moved.moved.skippedHeadings.map(\.id), [fixture.notes.id])
        XCTAssertEqual(try Data(contentsOf: MarkdownCacheService.cacheURL(for: fixture.book)), fixture.newBytes)

        // The copy stays until the book's record holds the places.
        let snapshot = try XCTUnwrap(moved.snapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.folder.path))
        XCTAssertTrue(snapshotsHoldACopy(of: fixture.book))
        moved.discardSnapshot()
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.folder.path))
        XCTAssertFalse(snapshotsHoldACopy(of: fixture.book))
    }

    /// A book with no place to move has nothing to copy aside.
    func testABookWithoutPlacesLeavesNoCopy() throws {
        let fixture = try makeBookInAnOlderText(title: "No Places \(UUID().uuidString)")
        var bare = fixture.book
        bare.readingPosition = nil
        bare.bookmarks = []
        bare.setSkippedHeadings(nil)
        XCTAssertFalse(bare.holdsPlacesToMove)

        let generated = try XCTUnwrap(MarkdownCacheService.generateReportedCacheContent(for: bare))

        XCTAssertNil(generated.movedPlaces)
        XCTAssertFalse(snapshotsHoldACopy(of: bare))
    }

    /// A rebuild that writes the text already there moves nothing, so it
    /// copies nothing.
    func testAnUnchangedTextLeavesNoCopy() throws {
        let fixture = try makeBookInAnOlderText(title: "Unchanged \(UUID().uuidString)")
        try fixture.newBytes.write(to: MarkdownCacheService.cacheURL(for: fixture.book), options: .atomic)

        let generated = try XCTUnwrap(MarkdownCacheService.generateReportedCacheContent(for: fixture.book))

        XCTAssertNil(generated.movedPlaces)
        XCTAssertFalse(snapshotsHoldACopy(of: fixture.book))
    }

    /// A book held by an Edit Text session is left to its session: the
    /// generation copies nothing (it may refuse to replace the text at all).
    func testABookInAnEditSessionLeavesNoCopy() throws {
        let fixture = try makeBookInAnOlderText(title: "Edited \(UUID().uuidString)")
        holdInAnEditSession(fixture.book)

        _ = try? MarkdownCacheService.generateReportedCacheContent(for: fixture.book)

        XCTAssertFalse(snapshotsHoldACopy(of: fixture.book))
    }

    // MARK: Committing the Moved Places

    /// The cache batch rebuilds the older text and commits the moved places
    /// with the analysis: the row and the record hold them, the copy is
    /// gone, and the debug log says once that the places were moved.
    @MainActor
    func testTheBatchCommitsTheMovedPlacesToTheRowAndTheRecord() async throws {
        let title = "Batch \(UUID().uuidString)"
        let fixture = try makeBookInAnOlderText(title: title)
        let model = makeModel(with: [fixture.book])

        await runCacheBatch(on: model)

        assertPlaces(of: try XCTUnwrap(model.bookByID(fixture.book.id)), areThoseOf: fixture)
        let record = try recordedBook(like: fixture.book)
        assertPlaces(of: record, areThoseOf: fixture)
        XCTAssertEqual(record.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        XCTAssertFalse(snapshotsHoldACopy(of: fixture.book))
        XCTAssertEqual(logLineCount("PLACES_RELOCATED: \(title):"), 1)
    }

    /// Redo Text Extraction moves the places the same way.
    @MainActor
    func testRedoTextExtractionCommitsTheMovedPlaces() async throws {
        let fixture = try makeBookInAnOlderText(title: "Redo \(UUID().uuidString)")
        let model = makeModel(with: [fixture.book])
        let finished = expectation(description: "Redo Text Extraction finished")

        XCTAssertTrue(model.redoAllTextExtraction(access: .live) { _ in finished.fulfill() })
        await fulfillment(of: [finished], timeout: 20)

        assertPlaces(of: try XCTUnwrap(model.bookByID(fixture.book.id)), areThoseOf: fixture)
        assertPlaces(of: try recordedBook(like: fixture.book), areThoseOf: fixture)
        XCTAssertFalse(snapshotsHoldACopy(of: fixture.book))
    }

    /// A position saved while the batch rebuilds the text is the listener's
    /// newest: it wins over the moved one, in the row and in the record,
    /// while the bookmark and the skip still move.
    @MainActor
    func testAPositionSavedMeanwhileIsKept() async throws {
        let fixture = try makeBookInAnOlderText(title: "Meanwhile \(UUID().uuidString)")
        let model = makeModel(with: [fixture.book])
        let held = holdCacheGeneration(of: fixture.book)
        let finished = expectation(description: "The cache batch finished")

        model.extractMissingContentCaches { finished.fulfill() }
        await fulfillment(of: [held.reached], timeout: 20)
        model.persistReadingPosition(bookID: fixture.book.id, position: ReadingPosition(chapterIndex: 0, characterOffset: 3))
        held.gate.signal()
        await fulfillment(of: [finished], timeout: 20)

        let row = try XCTUnwrap(model.bookByID(fixture.book.id))
        let record = try recordedBook(like: fixture.book)
        for book in [row, record] {
            XCTAssertEqual(book.readingPosition?.chapterIndex, 0)
            XCTAssertEqual(book.readingPosition?.characterOffset, 3)
            XCTAssertEqual(book.bookmarks.first?.chapterIndex, fixture.bookmark.chapter)
            XCTAssertEqual(book.bookmarks.first?.characterOffset, fixture.bookmark.offset)
            XCTAssertEqual(book.skippedHeadingIDs, [fixture.notes.id])
        }
        XCTAssertFalse(snapshotsHoldACopy(of: fixture.book))
    }

    /// Another Mac wrote a newer position into the book's record (not into
    /// this Mac's row) before the batch moved the places: the record refuses
    /// the position's move, and the row must refuse it too. A moved position
    /// is dated at the move, so a row that took it would look newer than the
    /// other Mac's save, and the next launch would keep the stale place. The
    /// bookmark and the skipped heading, which the record took, move in both.
    @MainActor
    func testAMoveNeverWinsOverANewerPositionFromAnotherMac() async throws {
        let fixture = try makeBookInAnOlderText(title: "Newer \(UUID().uuidString)")
        let model = makeModel(with: [fixture.book])
        let rowPosition = try XCTUnwrap(fixture.book.readingPosition)

        // The other Mac's save: another place in the older text, a minute
        // newer, written into the record only, as the fixture writes it.
        var otherMacsPosition = ReadingPosition(chapterIndex: 0, characterOffset: 3)
        otherMacsPosition.lastUpdated = rowPosition.lastUpdated.addingTimeInterval(60)
        var elsewhere = fixture.book
        elsewhere.readingPosition = otherMacsPosition
        try elsewhere.saveBookInfoThrowing()

        await runCacheBatch(on: model)

        // The record keeps the other Mac's position, as the file stores it.
        let record = try recordedBook(like: fixture.book)
        XCTAssertTrue(Book.isAsStored(record.readingPosition, otherMacsPosition), "the record lost the other Mac's position")
        // The row keeps the position it had, and is older than the record's.
        let row = try XCTUnwrap(model.bookByID(fixture.book.id))
        XCTAssertTrue(Book.isAsStored(row.readingPosition, rowPosition), "the row took the refused move")
        let rowDate = try XCTUnwrap(row.readingPosition?.lastUpdated)
        let recordDate = try XCTUnwrap(record.readingPosition?.lastUpdated)
        XCTAssertLessThan(rowDate, recordDate)
        // The moves the record took reach the row too.
        for book in [row, record] {
            XCTAssertEqual(book.bookmarks.count, 1)
            XCTAssertEqual(book.bookmarks.first?.chapterIndex, fixture.bookmark.chapter)
            XCTAssertEqual(book.bookmarks.first?.characterOffset, fixture.bookmark.offset)
            XCTAssertEqual(book.skippedHeadingIDs, [fixture.notes.id])
        }
        XCTAssertFalse(snapshotsHoldACopy(of: fixture.book))
    }

    /// A book whose text is only in the cloud is left alone: its places stay
    /// as they were, and nothing is copied.
    @MainActor
    func testABookInTheCloudKeepsItsPlaces() async throws {
        let fixture = try makeBookInAnOlderText(title: "Cloud \(UUID().uuidString)")
        let model = makeModel(with: [fixture.book])
        cloud.markDataless(MarkdownCacheService.cacheURL(for: fixture.book))

        await runCacheBatch(on: model, access: cloud.access)

        let row = try XCTUnwrap(model.bookByID(fixture.book.id))
        XCTAssertEqual(row.relocatablePlaces, fixture.book.relocatablePlaces)
        XCTAssertFalse(snapshotsHoldACopy(of: fixture.book))
    }

    // MARK: A Stop After the Commit

    /// What a batch that stopped right after committing a book leaves: the
    /// book's package record holds the rebuilt analysis and the moved
    /// places, and the library row (the fixture's book) holds neither.
    private func commitTheBatchAndStop(for fixture: BookInAnOlderText) throws {
        var updated = fixture.book
        let generated = try XCTUnwrap(MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(for: &updated))
        let moved = try XCTUnwrap(generated.movedPlaces)
        _ = try XCTUnwrap(LibraryPersistenceService.saveContentAnalysis(
            for: updated,
            index: generated.content.contentIndex,
            cacheFormatVersion: MarkdownCacheService.currentCacheVersion,
            movedPlaces: moved
        ))
        // The record holds the moved places now.
        assertPlaces(of: try recordedBook(like: fixture.book), areThoseOf: fixture)
    }

    /// Runs the next launch's passes over `model` until they end.
    @MainActor
    private func runTheNextLaunchsPasses(on model: LibraryViewModel) async {
        let finished = expectation(description: "The launch's passes ended")
        model.updateContentCachesAndStatistics(access: .live) { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 60)
    }

    /// TextMouth stopped after the batch committed a book's analysis and
    /// moved places to its record, before the summary reached library.json.
    /// The next launch recovers the analysis from the record, and the row
    /// takes the record's places with it, so a later change of the row does
    /// not write its old places over the moved ones.
    @MainActor
    func testAStopAfterTheCommitStillBringsTheMovedPlacesToTheRow() async throws {
        let fixture = try makeBookInAnOlderText(title: "Stopped \(UUID().uuidString)")
        try commitTheBatchAndStop(for: fixture)

        // The next launch: library.json's row is the book as it was.
        let model = makeModel(with: [fixture.book])
        await runTheNextLaunchsPasses(on: model)

        let row = try XCTUnwrap(model.bookByID(fixture.book.id))
        XCTAssertEqual(row.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        assertPlaces(of: row, areThoseOf: fixture)

        // Any change of the row writes its places to the record.
        model.updateEndOfBookBehavior(bookID: fixture.book.id, behavior: "stop")
        assertPlaces(of: try recordedBook(like: fixture.book), areThoseOf: fixture)
        XCTAssertFalse(snapshotsHoldACopy(of: fixture.book))
    }

    /// A row whose position was saved after the move keeps it through the
    /// recovery: the record's moved position is older, and a place saved
    /// meanwhile wins. The bookmark and the skip, which nothing newer
    /// changed, take the record's.
    @MainActor
    func testARecoveryKeepsARowPositionSavedAfterTheMove() async throws {
        let fixture = try makeBookInAnOlderText(title: "Saved After \(UUID().uuidString)")
        try commitTheBatchAndStop(for: fixture)

        // The listener moved on after the move, in a row library.json kept.
        var row = fixture.book
        var later = ReadingPosition(chapterIndex: 0, characterOffset: 3)
        later.lastUpdated = Date().addingTimeInterval(60)
        row.readingPosition = later
        let model = makeModel(with: [row])
        await runTheNextLaunchsPasses(on: model)

        let recovered = try XCTUnwrap(model.bookByID(fixture.book.id))
        // The launch may give the position the words around it (an anchor),
        // so its place and date are compared, not the whole position.
        XCTAssertEqual(recovered.readingPosition?.chapterIndex, later.chapterIndex, "the recovery replaced a newer position")
        XCTAssertEqual(recovered.readingPosition?.characterOffset, later.characterOffset, "the recovery replaced a newer position")
        XCTAssertEqual(recovered.readingPosition?.lastUpdated, later.lastUpdated, "the recovery dated the position afresh")
        XCTAssertEqual(recovered.bookmarks.first?.chapterIndex, fixture.bookmark.chapter)
        XCTAssertEqual(recovered.bookmarks.first?.characterOffset, fixture.bookmark.offset)
        XCTAssertEqual(recovered.skippedHeadingIDs, [fixture.notes.id])
    }

    /// A row bookmark that differs from the record's in more than where it
    /// is (its label was edited) keeps the row's bookmark, at the row's
    /// place; the position and the skip still take the record's.
    @MainActor
    func testARecoveryKeepsARowBookmarkThatWasEdited() async throws {
        let fixture = try makeBookInAnOlderText(title: "Edited Label \(UUID().uuidString)")
        try commitTheBatchAndStop(for: fixture)

        var row = fixture.book
        let before = try XCTUnwrap(row.bookmarks.first)
        var renamed = before
        renamed.label = "Renamed"
        row.bookmarks = [renamed]
        let model = makeModel(with: [row])
        await runTheNextLaunchsPasses(on: model)

        let recovered = try XCTUnwrap(model.bookByID(fixture.book.id))
        XCTAssertEqual(recovered.bookmarks.count, 1)
        XCTAssertEqual(recovered.bookmarks.first?.label, "Renamed")
        XCTAssertEqual(recovered.bookmarks.first?.chapterIndex, before.chapterIndex)
        XCTAssertEqual(recovered.bookmarks.first?.characterOffset, before.characterOffset)
        XCTAssertEqual(recovered.readingPosition?.chapterIndex, fixture.position.chapter)
        XCTAssertEqual(recovered.readingPosition?.characterOffset, fixture.position.offset)
        XCTAssertEqual(recovered.skippedHeadingIDs, [fixture.notes.id])
    }

    // MARK: A Reader's Own Rebuild

    /// A reader that opens a book whose text is outdated rebuilds it and
    /// takes the moved places: its cursor, bookmarks, and skipped headings
    /// are on the same words in the new text, the library's row and the
    /// record hold them, and no copy of the old text is left.
    @MainActor
    func testAReadersRebuildMovesThePlacesItOpensAt() throws {
        let fixture = try makeBookInAnOlderText(title: "Reader \(UUID().uuidString)")
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

        // The row and the record: the position may carry the date and
        // anchor of the save the load makes, so only its numbers are compared.
        assertPlaces(of: reader.book, areThoseOf: fixture)
        assertPlaces(of: try XCTUnwrap(model.bookByID(fixture.book.id)), areThoseOf: fixture)
        assertPlaces(of: try recordedBook(like: fixture.book), areThoseOf: fixture)
        XCTAssertFalse(snapshotsHoldACopy(of: fixture.book))
    }

    /// Places moved for a cursor that is not at the place they were saved at
    /// change nothing: the cursor, the reader's copy, and the library's row
    /// stay as they are, and the row is not saved again.
    @MainActor
    func testMovedPlacesForAPlaceTheReaderLeftAreNotTaken() throws {
        let fixture = try makeBookInAnOlderText(title: "Left \(UUID().uuidString)")
        let model = makeModel(with: [fixture.book])
        let reader = openReader(on: fixture.book, in: model)
        waitForReaderToLoad(reader)
        let oldPosition = try XCTUnwrap(fixture.book.readingPosition)
        let rowPosition = try XCTUnwrap(model.bookByID(fixture.book.id)?.readingPosition)
        let readerPosition = try XCTUnwrap(reader.book.readingPosition)
        let cursor = TextPlace(chapter: reader.currentChapterIndex, offset: reader.currentCharacterOffset)
        XCTAssertNotEqual(
            TextPlace(chapter: oldPosition.chapterIndex, offset: oldPosition.characterOffset),
            cursor,
            "the fixture's old position should differ from where the reader is"
        )

        // The places as saved at the old position, moved to the book's start.
        var moved = fixture.book.relocatablePlaces
        moved.position = ReadingPosition(chapterIndex: 0, characterOffset: 1)
        reader.takeMovedPlaces(MovedPlaces(
            bookID: fixture.book.id,
            original: fixture.book.relocatablePlaces,
            moved: moved,
            snapshot: nil
        ))

        XCTAssertEqual(reader.currentChapterIndex, cursor.chapter)
        XCTAssertEqual(reader.currentCharacterOffset, cursor.offset)
        XCTAssertEqual(reader.book.readingPosition, readerPosition)
        XCTAssertEqual(model.bookByID(fixture.book.id)?.readingPosition, rowPosition)
    }
}
