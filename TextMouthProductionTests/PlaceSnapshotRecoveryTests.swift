import XCTest
@testable import TextMouth

/// A stop between a rebuild's write of a book's new text and its commit of
/// the moved places leaves the copy of the old text aside (T06's branch D,
/// TEXT-ANCHORS-ADDENDUM-2026-10-10.md, section 9, step 6). The moved places
/// are saved alone, and the next launch finishes them.
final class PlaceSnapshotRecoveryTests: CloudMaintenanceTestCase {
    // MARK: Helpers

    /// Rebuilds `book`'s text and returns the places the rebuild moved,
    /// uncommitted: a stop between the rebuild's write and its commit.
    private func rebuildWithoutCommitting(_ book: Book) throws -> MovedPlaces {
        let generated = try XCTUnwrap(MarkdownCacheService.generateReportedCacheContent(for: book))
        return try XCTUnwrap(generated.movedPlaces)
    }

    // MARK: Saving Moved Places Alone

    /// The moved places are saved without an analysis: the record holds them,
    /// keeps its cache version and its content index, and the copy is gone.
    func testMovedPlacesAreSavedAlone() throws {
        let fixture = try makeBookInAnOlderText(title: "Saved Alone \(UUID().uuidString)")
        // A content index the package must keep.
        let index = BookContentIndex(
            version: BookContentIndex.currentVersion,
            kind: .text,
            format: .markdown,
            generatedAt: Date(timeIntervalSince1970: 1_790_000_000),
            totalWordCount: 0,
            totalCharacterCount: 0,
            totalAudioDuration: nil,
            audioLayout: nil,
            chapters: []
        )
        try fixture.book.saveBookInfoThrowing(contentIndex: index)
        let moved = try rebuildWithoutCommitting(fixture.book)
        XCTAssertTrue(snapshotsHoldACopy(of: fixture.book))

        let saved = try XCTUnwrap(LibraryPersistenceService.saveMovedPlaces(moved, for: fixture.book))

        assertPlaces(of: saved, areThoseOf: fixture)
        assertPlaces(of: try recordedBook(like: fixture.book), areThoseOf: fixture)
        let record = try BookInfo.load(from: fixture.book.tmbDirectory)
        XCTAssertEqual(record.state.cacheFormatVersion, "3.0.3", "the places alone do not make the cache current")
        XCTAssertEqual(record.contentIndex?.generatedAt, index.generatedAt)
        XCTAssertFalse(snapshotsHoldACopy(of: fixture.book))
    }

    /// A place saved again after the old text was copied aside stays as the
    /// listener saved it; the places not saved again move.
    func testAPlaceSavedAgainMeanwhileStays() throws {
        let fixture = try makeBookInAnOlderText(title: "Saved Again \(UUID().uuidString)")
        let moved = try rebuildWithoutCommitting(fixture.book)
        var again = fixture.book
        again.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: 3)
        try again.saveBookInfoThrowing()

        let saved = try XCTUnwrap(LibraryPersistenceService.saveMovedPlaces(moved, for: fixture.book))

        let record = try recordedBook(like: fixture.book)
        for book in [saved, record] {
            XCTAssertEqual(book.readingPosition?.chapterIndex, 0)
            XCTAssertEqual(book.readingPosition?.characterOffset, 3)
            XCTAssertEqual(book.bookmarks.first?.chapterIndex, fixture.bookmark.chapter)
            XCTAssertEqual(book.bookmarks.first?.characterOffset, fixture.bookmark.offset)
            XCTAssertEqual(book.skippedHeadingIDs, [fixture.notes.id])
        }
        XCTAssertFalse(snapshotsHoldACopy(of: fixture.book))
    }

    // MARK: Finishing at Launch

    /// Runs `finishLeftoverPlaceMoves(access:)` over `model` until its
    /// completion.
    @MainActor
    private func finishLeftoverMoves(on model: LibraryViewModel, access: MaintenanceFileAccess = .live) async {
        let finished = expectation(description: "The recovery pass finished")
        model.finishLeftoverPlaceMoves(access: access) { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 30)
    }

    /// Rebuilds each of `books` without committing, and then forgets the
    /// copies this run is using, as a quit does: each copy is a leftover.
    private func stopAfterRebuilding(_ books: [Book]) throws {
        for book in books {
            _ = try rebuildWithoutCommitting(book)
        }
        PlaceSnapshot.forgetCopiesInUse()
    }

    /// The `PLACES_RECOVERED` line counting `finished` copies finished and
    /// `left` left.
    private func recoveredLine(finished: Int, left: Int) -> String {
        "PLACES_RECOVERED: finished \(finished), left \(left) for a later launch"
    }

    /// A rebuild stopped before its commit leaves the copy and the old
    /// places in the record; the launch's recovery moves them against the
    /// text now there, in the row and the record, deletes the copy, and logs
    /// the counts once.
    @MainActor
    func testALaunchFinishesTheMovesAStopLeftUndone() async throws {
        let fixture = try makeBookInAnOlderText(title: "Finished \(UUID().uuidString)")
        try stopAfterRebuilding([fixture.book])
        XCTAssertTrue(snapshotsHoldACopy(of: fixture.book))
        let model = makeModel(with: [fixture.book])
        let linesBefore = logLineCount(recoveredLine(finished: 1, left: 0))

        await finishLeftoverMoves(on: model)

        assertPlaces(of: try XCTUnwrap(model.bookByID(fixture.book.id)), areThoseOf: fixture)
        assertPlaces(of: try recordedBook(like: fixture.book), areThoseOf: fixture)
        XCTAssertFalse(snapshotsHoldACopy(of: fixture.book))
        XCTAssertEqual(logLineCount(recoveredLine(finished: 1, left: 0)), linesBefore + 1)
    }

    /// The record refuses a move of a place another Mac saved after the old
    /// text was copied aside, and the row takes only the moves its record
    /// took: it keeps its own position, unmoved, and moves the bookmark and
    /// the skip, which the record took. Otherwise the row would hold a stale
    /// position dated at the move, which later looks newer than the other
    /// Mac's save.
    @MainActor
    func testARowTakesOnlyTheMovesItsRecordTook() async throws {
        let fixture = try makeBookInAnOlderText(title: "Refused \(UUID().uuidString)")
        let rowPosition = try XCTUnwrap(fixture.book.readingPosition)
        try stopAfterRebuilding([fixture.book])
        XCTAssertTrue(snapshotsHoldACopy(of: fixture.book))
        // The other Mac's save, a minute newer, in the record only.
        var otherMacsPosition = ReadingPosition(chapterIndex: 0, characterOffset: 3)
        otherMacsPosition.lastUpdated = rowPosition.lastUpdated.addingTimeInterval(60)
        var elsewhere = fixture.book
        elsewhere.readingPosition = otherMacsPosition
        try elsewhere.saveBookInfoThrowing()
        let model = makeModel(with: [fixture.book])

        await finishLeftoverMoves(on: model)

        let record = try recordedBook(like: fixture.book)
        let row = try XCTUnwrap(model.bookByID(fixture.book.id))
        // The record keeps the other Mac's position; the row keeps its own.
        XCTAssertTrue(Book.isAsStored(record.readingPosition, otherMacsPosition), "the record lost the other Mac's position")
        XCTAssertTrue(Book.isAsStored(row.readingPosition, rowPosition), "the row took the move its record refused")
        // The bookmark and the skip, which the record took, moved in both.
        for (name, book) in [("record", record), ("row", row)] {
            XCTAssertEqual(book.bookmarks.count, 1, "\(name)'s bookmarks")
            XCTAssertEqual(book.bookmarks.first?.chapterIndex, fixture.bookmark.chapter, "\(name)'s bookmark chapter")
            XCTAssertEqual(book.bookmarks.first?.characterOffset, fixture.bookmark.offset, "\(name)'s bookmark offset")
            XCTAssertEqual(book.skippedHeadingIDs, [fixture.notes.id], "\(name)'s skipped headings")
        }
        XCTAssertFalse(snapshotsHoldACopy(of: fixture.book))
    }

    /// The launch's passes run the recovery first: the places are moved, the
    /// cache is current afterward, and no copy is left.
    @MainActor
    func testTheLaunchPassesFinishTheMovesFirst() async throws {
        let fixture = try makeBookInAnOlderText(title: "Launch \(UUID().uuidString)")
        try stopAfterRebuilding([fixture.book])
        let model = makeModel(with: [fixture.book])
        let finished = expectation(description: "The launch's passes ended")

        model.updateContentCachesAndStatistics(access: .live) { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 60)

        assertPlaces(of: try XCTUnwrap(model.bookByID(fixture.book.id)), areThoseOf: fixture)
        let record = try recordedBook(like: fixture.book)
        assertPlaces(of: record, areThoseOf: fixture)
        XCTAssertEqual(record.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        XCTAssertFalse(snapshotsHoldACopy(of: fixture.book))
    }

    /// The copy of a book that is no longer in the library is discarded,
    /// counted nowhere, and the package's record is not touched.
    @MainActor
    func testACopyOfABookNoLongerInTheLibraryIsDiscarded() async throws {
        let fixture = try makeBookInAnOlderText(title: "Gone \(UUID().uuidString)")
        try stopAfterRebuilding([fixture.book])
        let model = makeModel(with: [])
        let linesBefore = logLineCount("PLACES_RECOVERED:")

        await finishLeftoverMoves(on: model)

        XCTAssertFalse(snapshotsHoldACopy(of: fixture.book))
        XCTAssertEqual(try recordedBook(like: fixture.book).relocatablePlaces, fixture.book.relocatablePlaces)
        XCTAssertEqual(logLineCount("PLACES_RECOVERED:"), linesBefore, "a copy of a book not in the library was counted")
    }

    /// A book a reader has open, one an Edit Text session holds, and one
    /// whose text is only in the cloud keep their copies and places for a
    /// later launch; once the hold ends, the book is closed, and the files
    /// are back, that launch finishes each.
    @MainActor
    func testBooksOpenEditedOrInTheCloudWaitForALaterLaunch() async throws {
        let open = try makeBookInAnOlderText(title: "Open \(UUID().uuidString)")
        let edited = try makeBookInAnOlderText(title: "Edited \(UUID().uuidString)")
        let inCloud = try makeBookInAnOlderText(title: "In the Cloud \(UUID().uuidString)")
        try stopAfterRebuilding([open.book, edited.book, inCloud.book])
        holdInAnEditSession(edited.book)
        cloud.markDataless(MarkdownCacheService.cacheURL(for: inCloud.book))
        let model = makeModel(with: [open.book, edited.book, inCloud.book])
        model.openBookIDs.insert(open.book.id)
        let waitingLines = logLineCount(recoveredLine(finished: 0, left: 3))

        await finishLeftoverMoves(on: model, access: cloud.access)

        for fixture in [open, edited, inCloud] {
            let title = fixture.book.title
            XCTAssertTrue(snapshotsHoldACopy(of: fixture.book), "\(title) lost its copy")
            XCTAssertEqual(model.bookByID(fixture.book.id)?.relocatablePlaces, fixture.book.relocatablePlaces, "\(title) row changed")
            XCTAssertEqual(try recordedBook(like: fixture.book).relocatablePlaces, fixture.book.relocatablePlaces, "\(title) record changed")
        }
        XCTAssertEqual(logLineCount(recoveredLine(finished: 0, left: 3)), waitingLines + 1)

        BookTextEditSessions.shared.end(edited.book.id)
        model.openBookIDs.remove(open.book.id)
        await finishLeftoverMoves(on: model, access: .live)

        for fixture in [open, edited, inCloud] {
            assertPlaces(of: try XCTUnwrap(model.bookByID(fixture.book.id)), areThoseOf: fixture)
            assertPlaces(of: try recordedBook(like: fixture.book), areThoseOf: fixture)
            XCTAssertFalse(snapshotsHoldACopy(of: fixture.book), "\(fixture.book.title) kept its copy")
        }
    }
}
