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

    /// The book as its package record holds it, read from disk after every
    /// queued library write has landed.
    private func recordedBook(like book: Book) throws -> Book {
        LibraryPersistenceService.flushPendingSave()
        let record = try BookInfo.load(from: book.tmbDirectory)
        return Book(
            record: record,
            filePath: book.filePath,
            folderPath: book.folderPath,
            tmbDirectoryName: book.tmbDirectoryName
        )
    }

    /// Runs the launch's cache batch over `model` until its completion.
    @MainActor
    private func runCacheBatch(on model: LibraryViewModel, access: MaintenanceFileAccess = .live) async {
        let finished = expectation(description: "The cache batch finished")
        model.extractMissingContentCaches(access: access) { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 20)
    }

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
}
