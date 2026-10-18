import XCTest
@testable import TextMouth

/// The most TextMouth reads from one document that its own readers take
/// whole (`DocumentByteLimit`): 64 MB, refused beyond with a sentence that
/// names the limit, and an empty file refused as having no text. Tests bind
/// a small limit, so their files stay a few bytes.
final class DocumentByteLimitTests: XCTestCase {

    /// The documented limit is 64 MB, the limit for one text file inside a
    /// book's archive, and it is the one in force unless a test binds
    /// another, which applies only inside the operation that binds it.
    func testTheStandardLimitIsSixtyFourMegabytesUnlessBound() {
        XCTAssertEqual(DocumentByteLimit.standard, 64_000_000)
        XCTAssertEqual(DocumentByteLimit.standard, ArchiveEntryLimits.standard.text)
        XCTAssertEqual(DocumentByteLimit.current, DocumentByteLimit.standard)
        DocumentByteLimit.$current.withValue(10) {
            XCTAssertEqual(DocumentByteLimit.current, 10)
        }
        XCTAssertEqual(DocumentByteLimit.current, DocumentByteLimit.standard)
    }

    /// A document within the limit is read whole, up to the limit itself.
    func testADocumentWithinTheLimitIsReadWhole() throws {
        let file = try makeSandboxDirectory("DocumentByteLimit").appendingPathComponent("notes.ssml")
        try Data("0123456789".utf8).write(to: file)

        let data = try DocumentByteLimit.$current.withValue(10) { try DocumentByteLimit.contents(of: file) }

        XCTAssertEqual(data, Data("0123456789".utf8))
    }

    /// A document past the limit is refused, before it is read, with the
    /// sentence the listener hears after the file's name.
    func testADocumentPastTheLimitIsRefusedWithItsSentence() throws {
        let file = try makeSandboxDirectory("DocumentByteLimit").appendingPathComponent("notes.ssml")
        try Data("0123456789A".utf8).write(to: file)

        XCTAssertThrowsError(
            try DocumentByteLimit.$current.withValue(10) { try DocumentByteLimit.contents(of: file) }
        ) { error in
            XCTAssertEqual(error as? DocumentTooLargeError, DocumentTooLargeError(limit: 10))
        }
        XCTAssertEqual(
            DocumentTooLargeError(limit: DocumentByteLimit.standard).localizedDescription,
            "This document holds more than 64 MB, the most TextMouth reads from one document."
        )
    }

    /// An empty document is refused as having no text, as an empty
    /// Markdown or plain-text file is.
    func testAnEmptyDocumentHasNoTextToRead() throws {
        let file = try makeSandboxDirectory("DocumentByteLimit").appendingPathComponent("empty.ssml")
        try Data().write(to: file)

        XCTAssertThrowsError(try DocumentByteLimit.contents(of: file)) { error in
            XCTAssertEqual(error.localizedDescription, "This file has no text to read.")
        }
    }
}
