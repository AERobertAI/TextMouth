import XCTest
@testable import TextMouth

/// `PhoneRowValue`: a row's kind follows its identity, and a sentence's row
/// says its sentence and offers nothing.
final class PhoneRowValueTests: XCTestCase {
    /// A sentence's row says what it reads, and has no commands.
    func testASentencesRow() {
        let row = PhoneRowValue.note(.emptyFolder)

        XCTAssertEqual(row.id, .note(.emptyFolder))
        XCTAssertEqual(row.kind, .note)
        XCTAssertEqual(row.label, "This folder is empty.")
        XCTAssertEqual(row.title, row.label)
        XCTAssertNil(row.detail)
        XCTAssertTrue(row.commands.isEmpty)
    }

    /// The kind follows the identity.
    func testTheKindFollowsTheIdentity() {
        let book = PhoneRowValue(id: .book(UUID()), label: "Dune", title: "Dune", detail: nil, commands: [])
        let folder = PhoneRowValue(id: .folder(UUID()), label: "Fiction, 1 book", title: "Fiction", detail: "1 book", commands: [])

        XCTAssertEqual(book.kind, .book)
        XCTAssertEqual(folder.kind, .folder)
    }
}
