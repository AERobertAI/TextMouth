import XCTest
@testable import TextMouth

/// Regression coverage for combined duplicate-finder criteria.
final class DuplicateFinderTests: XCTestCase {
    func testCombinedTitleAndAuthorRequiresBothFieldsToMatch() {
        let first = makeBook(title: "Shared", author: "First Author")
        let second = makeBook(title: "Shared", author: "Second Author")

        let groups = DuplicateFinderEngine.findDuplicates(
            books: [first, second],
            filters: [.title, .author],
            isbnCache: [:]
        )

        XCTAssertTrue(groups.isEmpty)
    }

    func testCombinedCriteriaGroupsBooksWhenEveryFieldMatches() {
        let first = makeBook(title: " Shared ", author: "Same Author", hash: "one")
        let second = makeBook(title: "shared", author: "same author", hash: "two")

        let groups = DuplicateFinderEngine.findDuplicates(
            books: [first, second],
            filters: [.title, .author],
            isbnCache: [:]
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].books.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(groups[0].matchTypes, [.title, .author])
    }

    func testMissingSelectedISBNExcludesBookFromCombinedMatch() {
        let first = makeBook(title: "Shared", author: "Author")
        let second = makeBook(title: "Shared", author: "Author")

        let groups = DuplicateFinderEngine.findDuplicates(
            books: [first, second],
            filters: [.title, .isbn],
            isbnCache: [first.id: "9780000000001"]
        )

        XCTAssertTrue(groups.isEmpty)
    }

    private func makeBook(
        title: String,
        author: String,
        hash: String = UUID().uuidString
    ) -> Book {
        Book(
            title: title,
            author: author,
            format: .epub,
            filePath: "/tmp/\(UUID().uuidString).epub",
            md5Hash: hash
        )
    }
}
