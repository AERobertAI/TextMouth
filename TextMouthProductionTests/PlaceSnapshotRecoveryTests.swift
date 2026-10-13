import XCTest
@testable import TextMouth

/// A stop between a rebuild's write of a book's new text and its commit of
/// the moved places leaves the copy of the old text aside (T06's branch D,
/// TEXT-ANCHORS-ADDENDUM-2026-10-10.md, section 9, step 6). The moved places
/// are saved alone, and the next launch finishes them.
final class PlaceSnapshotRecoveryTests: CloudMaintenanceTestCase {
    // MARK: Helpers

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
}
