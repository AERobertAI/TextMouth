import XCTest
@testable import TextMouth

/// Regression coverage for metadata changes applied by both metadata editors.
final class BookMetadataUpdateTests: XCTestCase {
    /// Audio-specific editable fields must travel with title and author when the
    /// view model commits an edited Book back to the library.
    func testApplyingEditableMetadataIncludesAudioFields() {
        let id = UUID()
        var stored = Book(
            id: id,
            title: "Old Title",
            author: "Old Artist",
            format: .audio,
            filePath: "/tmp/book.m4b",
            md5Hash: "old-hash",
            audioAlbum: "Old Album",
            audioGenre: "Old Genre",
            audioYear: "1999",
            epubPublisher: "Old Publisher",
            epubPublicationDate: "1999"
        )
        let edited = Book(
            id: id,
            title: "New Title",
            author: "New Artist",
            format: .audio,
            filePath: "/tmp/book.m4b",
            md5Hash: "new-hash",
            audioAlbum: "New Album",
            audioGenre: "New Genre",
            audioYear: "2026",
            epubPublisher: "New Publisher",
            epubPublicationDate: "2026"
        )

        stored.applyEditableMetadata(from: edited)

        XCTAssertEqual(stored.title, "New Title")
        XCTAssertEqual(stored.author, "New Artist")
        XCTAssertEqual(stored.md5Hash, "new-hash")
        XCTAssertEqual(stored.audioAlbum, "New Album")
        XCTAssertEqual(stored.audioGenre, "New Genre")
        XCTAssertEqual(stored.audioYear, "2026")
        XCTAssertEqual(stored.epubPublisher, "New Publisher")
        XCTAssertEqual(stored.epubPublicationDate, "2026")
    }

    /// Metadata editing must not replace identity, storage, or reading state.
    func testApplyingEditableMetadataPreservesNonMetadataState() {
        let id = UUID()
        let position = ReadingPosition(chapterIndex: 2, characterOffset: 40)
        var stored = Book(
            id: id,
            title: "Old",
            format: .audio,
            filePath: "/library/book.m4b",
            md5Hash: "old",
            readingPosition: position,
            tmbDirectoryName: "book.tmb"
        )
        let edited = Book(
            id: id,
            title: "New",
            format: .audio,
            filePath: "/unexpected/path.m4b",
            md5Hash: "new"
        )

        stored.applyEditableMetadata(from: edited)

        XCTAssertEqual(stored.id, id)
        XCTAssertEqual(stored.filePath, "/library/book.m4b")
        XCTAssertEqual(stored.readingPosition, position)
        XCTAssertEqual(stored.tmbDirectoryName, "book.tmb")
    }
}
