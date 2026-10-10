import XCTest
@testable import TextMouth

/// How each feed's own index (FR11) is written: only when its bytes changed,
/// unless its file is gone, when the same bytes are written again (REV10,
/// item 9).
final class LibraryFeedIndexWriteTests: FeedItemIndexTestCase {

    /// A feed's index deleted since this process wrote it is written again
    /// by the next save, though its rows did not change; while it is there,
    /// the same rows write nothing.
    func testAnIndexWhoseFileIsGoneIsWrittenAgain() throws {
        let item = try makeFeedItem(title: "Written Again")
        let library = Library(books: [item])
        saveNow(library)
        let written = try XCTUnwrap(contents(of: feedIndexURL))
        try FileManager.default.removeItem(at: feedIndexURL)

        saveNow(library)

        XCTAssertEqual(contents(of: feedIndexURL), written, "the index deleted since the last write was not written again")
        // Each write replaces the file atomically, with a new file, so the
        // same file number means no write.
        let before = try fileNumber(of: feedIndexURL)
        saveNow(library)
        XCTAssertEqual(try fileNumber(of: feedIndexURL), before, "an unchanged index on disk was written again")
    }

    /// The file system's number of the file at `url`.
    private func fileNumber(of url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
    }
}
