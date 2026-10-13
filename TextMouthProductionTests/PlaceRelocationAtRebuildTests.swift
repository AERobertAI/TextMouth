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
}
