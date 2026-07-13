import XCTest
@testable import TextMouth

/// Regression coverage for production bookmark collision adjustment.
final class BookmarkPlacementTests: XCTestCase {
    func testForwardAdjustmentIsClampedToLastCharacterInChapter() {
        let bookmark = Bookmark(number: 1, chapterIndex: 0, characterOffset: 95)

        let result = ReaderViewModel.adjustedBookmarkOffset(
            bookmarks: [bookmark],
            chapterIndex: 0,
            characterOffset: 99,
            threshold: 10,
            chapterLength: 100
        )

        XCTAssertEqual(result, 99)
    }

    func testEmptyChapterClampsAdjustedPositionToZero() {
        let bookmark = Bookmark(number: 1, chapterIndex: 0, characterOffset: 0)

        let result = ReaderViewModel.adjustedBookmarkOffset(
            bookmarks: [bookmark],
            chapterIndex: 0,
            characterOffset: 0,
            threshold: 10,
            chapterLength: 0
        )

        XCTAssertEqual(result, 0)
    }

    func testPositionWithoutCollisionIsPreservedWithinChapter() {
        let result = ReaderViewModel.adjustedBookmarkOffset(
            bookmarks: [],
            chapterIndex: 0,
            characterOffset: 40,
            threshold: 10,
            chapterLength: 100
        )

        XCTAssertEqual(result, 40)
    }
}
