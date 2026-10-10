import XCTest
@testable import TextMouth

/// What a finished book is, apart from any window (TODO P07): where it
/// rests, and how Books Finished counts it.
///
/// The user decided on October 10, 2026 that a book that plays to its end
/// is saved exactly at its end and stays finished after TextMouth quits
/// ("yes", question 11), with no field of its own: the place says it
/// (`Book.restsAtEnd`).
final class FinishedBookModelTests: XCTestCase {

    // MARK: - Resting at the End

    /// The book's measured text: 1,000 UTF-16 units over its chapters.
    private static let total = 1_000

    /// A book `total` units long whose saved place is `place`, given by its
    /// global offset, or none.
    private func book(at globalOffset: Int?, chapter: Int = 2, offset: Int = 0, total: Int? = total) -> Book {
        Book(
            title: "Breakwater Survey",
            format: .epub,
            filePath: "/nowhere/breakwater.epub",
            md5Hash: "breakwater",
            readingPosition: ReadingPosition(chapterIndex: chapter, characterOffset: offset, globalCharacterOffset: globalOffset),
            totalCharacterCount: total
        )
    }

    /// A place at the end of the text, or past it, as a place saved before
    /// the text was extracted again can be, rests at the end; a place short
    /// of it, however near, does not: speech saved there stopped before the
    /// book did.
    func testABookRestsAtItsEndOnlyAtOrPastTheEndOfItsText() {
        XCTAssertTrue(book(at: Self.total).restsAtEnd, "The end itself")
        XCTAssertTrue(book(at: Self.total + 40).restsAtEnd, "Past the end")
        XCTAssertFalse(book(at: Self.total - 1).restsAtEnd, "One unit short")
        XCTAssertFalse(book(at: Self.total - 7).restsAtEnd, "The last word, where speech left it")
        XCTAssertFalse(book(at: 0).restsAtEnd, "The beginning")
    }

    /// A book at its end reads 100 percent, as the row's percent and its
    /// end agree.
    func testABookAtItsEndReadsAHundredPercent() {
        XCTAssertEqual(book(at: Self.total).percentComplete, 100)
        XCTAssertEqual(book(at: Self.total + 40).percentComplete, 100)
    }

    /// A book with no saved place, or not measured yet, is not at its end:
    /// nothing says where it is.
    func testABookWithNoPlaceOrNoMeasureIsNotAtItsEnd() {
        var unplaced = book(at: Self.total)
        unplaced.readingPosition = nil
        XCTAssertFalse(unplaced.restsAtEnd, "No saved place")
        XCTAssertFalse(book(at: Self.total, total: nil).restsAtEnd, "Not measured")
        XCTAssertFalse(book(at: 0, total: 0).restsAtEnd, "Measured empty")
    }

    /// A place saved before global offsets were kept is read as the row's
    /// percent reads it: by its offset in its chapter.
    func testAPlaceWithoutAGlobalOffsetIsReadByItsOffset() {
        XCTAssertTrue(book(at: nil, chapter: 0, offset: Self.total).restsAtEnd)
        XCTAssertFalse(book(at: nil, chapter: 0, offset: Self.total - 1).restsAtEnd)
    }
}
