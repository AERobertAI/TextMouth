import XCTest
@testable import TextMouth

/// The metadata reader's version, stamped on the rows it reads for, and the
/// comparison that tells an older stamp from a newer one.
final class MetadataReaderVersionTests: XCTestCase {

    /// A stamp older than the code's version is outdated; a missing or
    /// empty one is older than anything; an equal or newer one, as another
    /// Mac running a newer TextMouth leaves, is not.
    func testAnOlderOrMissingStampIsOutdatedAndANewerOneIsNot() {
        XCTAssertTrue(SemanticVersion.isOutdated(stored: nil, current: "1.0.0"))
        XCTAssertTrue(SemanticVersion.isOutdated(stored: "", current: "1.0.0"))
        XCTAssertTrue(SemanticVersion.isOutdated(stored: "0.9.9", current: "1.0.0"))
        XCTAssertTrue(SemanticVersion.isOutdated(stored: "1.0", current: "1.0.1"))
        XCTAssertFalse(SemanticVersion.isOutdated(stored: "1.0.0", current: "1.0.0"))
        XCTAssertFalse(SemanticVersion.isOutdated(stored: "1", current: "1.0.0"))
        XCTAssertFalse(SemanticVersion.isOutdated(stored: "1.1.0", current: "1.0.0"))
        XCTAssertFalse(SemanticVersion.isOutdated(stored: "2.0.0", current: "1.0.0"))
    }

    /// The text cache's check is the same comparison.
    func testTheTextCacheCheckIsTheSameComparison() {
        XCTAssertTrue(MarkdownCacheService.isCacheOutdated(stored: "3.0.6", current: "3.0.7"))
        XCTAssertFalse(MarkdownCacheService.isCacheOutdated(stored: "3.0.7", current: "3.0.7"))
        XCTAssertFalse(MarkdownCacheService.isCacheOutdated(stored: "3.1.0", current: "3.0.7"))
        XCTAssertTrue(MarkdownCacheService.isCacheOutdated(stored: nil))
    }

    /// A row keeps its stamp through library.json, and a row written before
    /// stamps, which has no such key, reads back without one.
    func testARowKeepsItsStampThroughTheIndexAndAnOlderRowHasNone() throws {
        var book = Book(
            title: "Stamped", format: .epub, filePath: "/tmp/stamped.epub", md5Hash: "hash",
            metadataReaderVersion: "1.0.0"
        )

        let stamped = try JSONDecoder().decode(Book.self, from: try JSONEncoder().encode(book))
        XCTAssertEqual(stamped.metadataReaderVersion, "1.0.0")
        XCTAssertEqual(stamped, book)

        book.metadataReaderVersion = nil
        let olderRow = try JSONEncoder().encode(book)
        XCTAssertFalse(String(decoding: olderRow, as: UTF8.self).contains("metadataReaderVersion"))
        XCTAssertNil(try JSONDecoder().decode(Book.self, from: olderRow).metadataReaderVersion)
    }

    /// An imported book's row is stamped with the reader that read its file.
    func testAnImportStampsTheRowWithTheReaderThatReadItsFile() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestData/alice.epub")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).epub")
        try FileManager.default.copyItem(at: fixture, to: copy)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }

        let book = try TextPipelineFixtures.imported(copy, for: self)

        XCTAssertEqual(book.metadataReaderVersion, ImportedFileMetadata.readerVersion)
        XCTAssertEqual(book.author, "Lewis Carroll")
    }

    /// The reader opens the formats that keep a title or author in the file;
    /// a plain text, Markdown, or HTML file is never opened for one.
    func testTheReaderOpensOnlyTheFormatsThatKeepMetadataInTheFile() {
        for format in [BookFormat.epub, .docx, .pdf, .daisy, .audio] {
            XCTAssertTrue(ImportedFileMetadata.readsFile(of: format), "\(format)")
        }
        for format in [BookFormat.txt, .markdown, .html] {
            XCTAssertFalse(ImportedFileMetadata.readsFile(of: format), "\(format)")
        }
    }
}
