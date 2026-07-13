import XCTest
@testable import TextMouth

/// Regression coverage for the production library sort comparator.
final class LibraryBookSorterTests: XCTestCase {
    func testDescendingTitleSortUsesExplicitReverseComparison() {
        let alpha = makeBook(title: "Alpha")
        let zulu = makeBook(title: "Zulu")

        let result = LibraryBookSorter.sorted([alpha, zulu], by: .title, ascending: false)

        XCTAssertEqual(result.map(\.title), ["Zulu", "Alpha"])
    }

    /// Equal primary values must not compare as less-than in both directions.
    func testEqualPrimaryValuesMaintainStrictOrdering() {
        let first = makeBook(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "Same", author: "Author")
        let second = makeBook(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "Same", author: "Author")

        let firstBeforeSecond = LibraryBookSorter.areInIncreasingOrder(
            first, second, by: .author, ascending: false
        )
        let secondBeforeFirst = LibraryBookSorter.areInIncreasingOrder(
            second, first, by: .author, ascending: false
        )

        XCTAssertNotEqual(firstBeforeSecond, secondBeforeFirst)
    }

    func testDescendingDateSortUsesTitleAsDeterministicTieBreaker() {
        let date = Date(timeIntervalSince1970: 100)
        let beta = makeBook(title: "Beta", dateAdded: date)
        let alpha = makeBook(title: "Alpha", dateAdded: date)

        let result = LibraryBookSorter.sorted([beta, alpha], by: .dateAdded, ascending: false)

        XCTAssertEqual(result.map(\.title), ["Alpha", "Beta"])
    }

    private func makeBook(
        id: UUID = UUID(),
        title: String,
        author: String = "Unknown",
        dateAdded: Date = Date()
    ) -> Book {
        Book(
            id: id,
            title: title,
            author: author,
            format: .txt,
            filePath: "/tmp/\(id.uuidString).txt",
            md5Hash: id.uuidString,
            dateAdded: dateAdded
        )
    }
}
