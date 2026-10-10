import XCTest
@testable import TextMouth

/// A reading checkpoint reaches a book's record at once and its index within
/// minutes (PERF15), and the journal names the books whose records are ahead,
/// so a launch after a crash takes their newer positions from the records.
/// For a feed's items (FR11) that held only for rows whose files are here,
/// which join the library's books; a row kept on its feed's shelf after its
/// download went kept the older place its index held, which is where
/// downloading the item again would open it (REV10, item 10).
final class LibraryFeedCheckpointTests: FeedItemIndexTestCase {

    /// A kept row on the shelf, and a row whose file is here, each take the
    /// journaled checkpoint newer than their own from their records; the
    /// kept row stays on the shelf, and the other joins the books.
    @MainActor
    func testEveryShelfRowTakesItsJournaledCheckpoint() throws {
        let kept = try makeFeedItem(title: "Kept After Its Download Went", position: Self.position(10, at: 60))
        let here = try makeFeedItem(title: "Still Downloaded", position: Self.position(20, at: 60))
        try FileManager.default.removeItem(at: kept.bookFileURL)
        // The records hold the newer checkpoints, which the index never got.
        for (row, offset) in [(kept, 900), (here, 950)] {
            var newer = row
            newer.readingPosition = Self.position(offset, at: 7_200)
            try newer.saveBookInfoThrowing()
        }
        let model = makeModel(with: [])
        model.library = Library(feedShelf: FeedShelf(rows: [kept, here]))

        XCTAssertTrue(model.joinFeedItems(journaled: [kept.id, here.id]))

        XCTAssertEqual(model.library.feedShelf.rows.map(\.id), [kept.id])
        XCTAssertEqual(model.library.feedShelf.rows.first?.readingPosition, Self.position(900, at: 7_200))
        XCTAssertEqual(model.bookByID(here.id)?.readingPosition, Self.position(950, at: 7_200))
        XCTAssertNil(model.bookByID(kept.id), "the kept row joined the books")
    }
}
