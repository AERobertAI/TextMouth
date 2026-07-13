import XCTest
@testable import TextMouth

/// Regression coverage for collision-resistant package naming.
final class TMBNameTests: XCTestCase {
    func testSameMetadataAndTimestampProduceDifferentNamesForDifferentBooks() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        let first = TextMouthPaths.tmbName(
            title: "Shared Title",
            author: "Shared Author",
            dateAdded: date,
            bookID: firstID
        )
        let second = TextMouthPaths.tmbName(
            title: "Shared Title",
            author: "Shared Author",
            dateAdded: date,
            bookID: secondID
        )

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasSuffix("\(firstID.uuidString.lowercased()).tmb"))
        XCTAssertTrue(second.hasSuffix("\(secondID.uuidString.lowercased()).tmb"))
    }

    func testPackageNameIsDeterministicForStableBookIdentity() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let id = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

        let first = TextMouthPaths.tmbName(
            title: "A Title",
            author: "An Author",
            dateAdded: date,
            bookID: id
        )
        let second = TextMouthPaths.tmbName(
            title: "A Title",
            author: "An Author",
            dateAdded: date,
            bookID: id
        )

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasSuffix(".tmb"))
    }
}
