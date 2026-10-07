import XCTest
@testable import TextMouth

/// The one placeholder for an author nothing named, `Book.unknownAuthor`,
/// and the one test of whether a book's author is still it.
final class BookAuthorPlaceholderTests: XCTestCase {
    /// A book made without an author is listed under the placeholder, the
    /// word every import, parser, and recording has always written.
    func testABookMadeWithoutAnAuthorIsListedUnderThePlaceholder() {
        let book = Book(title: "Loose Pages", format: .txt, filePath: "/tmp/loose-pages.txt", md5Hash: "hash")

        XCTAssertEqual(book.author, Book.unknownAuthor)
        XCTAssertEqual(Book.unknownAuthor, "Unknown")
    }

    /// The placeholder and an empty author both count as no author; a name,
    /// or any other word, does not.
    func testThePlaceholderAndAnEmptyAuthorCountAsNoAuthor() {
        XCTAssertTrue(Book.isUnknownAuthor(""))
        XCTAssertTrue(Book.isUnknownAuthor(Book.unknownAuthor))
        XCTAssertFalse(Book.isUnknownAuthor("Ottoline Pryce-Mbeki"))
        XCTAssertFalse(Book.isUnknownAuthor("Anonymous"))
    }
}
