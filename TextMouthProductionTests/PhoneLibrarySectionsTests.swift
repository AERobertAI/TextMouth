import XCTest
@testable import TextMouth

/// `PhoneLibrarySections`: the letter a book files under, and the runs that
/// become letter sections without reordering anything.
@MainActor
final class PhoneLibrarySectionsTests: XCTestCase {
    /// A title files under its first letter, in capitals and without accents,
    /// as the library's sort compares it; anything else files under "#".
    func testTheLetterATitleFilesUnder() {
        XCTAssertEqual(PhoneLibrarySections.letter(of: "middlemarch"), "M")
        XCTAssertEqual(PhoneLibrarySections.letter(of: "Émile"), "E")
        XCTAssertEqual(PhoneLibrarySections.letter(of: "1984"), "#")
        XCTAssertEqual(PhoneLibrarySections.letter(of: "“Quoted”"), "#")
        XCTAssertEqual(PhoneLibrarySections.letter(of: ""), "#")
    }

    /// Only a Title or Author sort of more than 30 books has letters.
    func testWhichListsHaveLetters() {
        XCTAssertTrue(PhoneLibrarySections.usesLetters(sortedBy: .title, count: 31))
        XCTAssertTrue(PhoneLibrarySections.usesLetters(sortedBy: .author, count: 700))
        XCTAssertFalse(PhoneLibrarySections.usesLetters(sortedBy: .title, count: 30))
        XCTAssertFalse(PhoneLibrarySections.usesLetters(sortedBy: .dateAdded, count: 700))
        XCTAssertFalse(PhoneLibrarySections.usesLetters(sortedBy: .manual, count: 700))
    }

    /// Runs follow the order given: an accented title stays beside its
    /// neighbors, and a letter the order brings back starts a run of its own
    /// rather than moving a book.
    func testRunsFollowTheOrder() {
        let books = ["Eagle", "Émile", "Emma", "Zeal", "Ember"].map { PhoneLibraryFixture.book($0) }

        let runs = PhoneLibrarySections.letterRuns(of: books, sortedBy: .title)

        XCTAssertEqual(runs.map(\.letter), ["E", "Z", "E"])
        XCTAssertEqual(runs.flatMap(\.books).map(\.title), books.map(\.title))
    }

    /// An Author sort files by the author.
    func testAuthorsFileByAuthor() {
        let books = [PhoneLibraryFixture.book("Zeal", by: "Agnes Ohlsson"), PhoneLibraryFixture.book("Able", by: "Viktor Lund")]

        XCTAssertEqual(PhoneLibrarySections.letterRuns(of: books, sortedBy: .author).map(\.letter), ["A", "V"])
    }
}
