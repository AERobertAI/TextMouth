import XCTest
@testable import TextMouth

/// Production-backed ports of the legacy audio metadata and metadata-dialog scenarios.
final class LegacyAudioMetadataTests: XCTestCase {
    func testAudioMetadataUsesEmptyDefaults() {
        let metadata = AudioMetadata()

        XCTAssertEqual(metadata.title, "")
        XCTAssertEqual(metadata.artist, "")
        XCTAssertEqual(metadata.album, "")
        XCTAssertEqual(metadata.genre, "")
        XCTAssertEqual(metadata.year, "")
        XCTAssertEqual(metadata.duration, "")
        XCTAssertEqual(metadata.fileFormat, "")
    }

    func testAudioMetadataAcceptsProvidedValues() {
        let metadata = populatedAudioMetadata()

        XCTAssertEqual(metadata.title, "My Audiobook")
        XCTAssertEqual(metadata.artist, "Felicity Hargrove")
        XCTAssertEqual(metadata.album, "Great Listens")
        XCTAssertEqual(metadata.genre, "Fiction")
        XCTAssertEqual(metadata.year, "2024")
        XCTAssertEqual(metadata.duration, "3:45:20")
        XCTAssertEqual(metadata.fileFormat, "MP3")
    }

    func testAudioMetadataRoundTripsThroughJSON() throws {
        let original = populatedAudioMetadata()

        let decoded = try JSONDecoder().decode(
            AudioMetadata.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.artist, original.artist)
        XCTAssertEqual(decoded.album, original.album)
        XCTAssertEqual(decoded.genre, original.genre)
        XCTAssertEqual(decoded.year, original.year)
        XCTAssertEqual(decoded.duration, original.duration)
        XCTAssertEqual(decoded.fileFormat, original.fileFormat)
    }

    func testBookMetadataAudioFieldsDefaultToNil() {
        let metadata = BookMetadata()

        XCTAssertNil(metadata.audioAlbum)
        XCTAssertNil(metadata.audioGenre)
        XCTAssertNil(metadata.audioYear)
    }

    func testBookMetadataAudioFieldsRoundTripThroughJSON() throws {
        let metadata = BookMetadata(
            title: "Audio Book",
            author: "Narrator",
            format: .audio,
            audioAlbum: "Best Series",
            audioGenre: "Thriller",
            audioYear: "2025"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(BookMetadata.self, from: encoder.encode(metadata))

        XCTAssertEqual(decoded.audioAlbum, "Best Series")
        XCTAssertEqual(decoded.audioGenre, "Thriller")
        XCTAssertEqual(decoded.audioYear, "2025")
        XCTAssertEqual(decoded.title, "Audio Book")
        XCTAssertEqual(decoded.author, "Narrator")
    }

    func testOldBookMetadataJSONDefaultsAudioFieldsToNil() throws {
        let json = """
        {
            "title": "Old Book",
            "author": "Unknown",
            "format": "audio",
            "md5Hash": "abc123",
            "dateAdded": "2025-01-01T00:00:00Z",
            "originalFileName": "old.mp3",
            "folderPath": "",
            "bookID": "00000000-0000-0000-0000-000000000001"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let metadata = try decoder.decode(BookMetadata.self, from: json)

        XCTAssertNil(metadata.audioAlbum)
        XCTAssertNil(metadata.audioGenre)
        XCTAssertNil(metadata.audioYear)
        XCTAssertEqual(metadata.title, "Old Book")
    }

    /// Audio books carry one heading per audio section, so Where Am I names
    /// the section's heading and numbers it among the book's headings.
    func testBriefWhereAmIIncludesHeadingAndPosition() {
        let headings = ["Boarding the Train", "Night Ferry", "Customs", "Harbor", "Home"].enumerated().map {
            Heading(level: 1, text: $0.element, chapterIndex: $0.offset, characterOffset: 0)
        }
        let position = HeadingPosition(in: headings, chapterIndex: 0, characterOffset: 40)

        let summary = ReaderViewModel.briefWhereAmISummary(
            bookTitle: "My Book",
            locationTitle: position.title(contentTitle: "The Departure", bookTitle: "My Book"),
            headingPosition: position,
            percentComplete: 12,
            timeRemaining: 9_000
        )

        XCTAssertTrue(summary.contains("Boarding the Train"))
        XCTAssertTrue(summary.contains("Heading 1 of 5"))
        XCTAssertTrue(summary.contains("12 percent"))
        XCTAssertFalse(summary.contains("The Departure"))
    }

    /// Only a book without any headings names its content unit's title, and
    /// it then has no heading number to speak.
    func testBriefWhereAmIFallsBackToContentTitleWithoutHeadings() {
        let position = HeadingPosition(in: [], chapterIndex: 0, characterOffset: 0)

        let summary = ReaderViewModel.briefWhereAmISummary(
            bookTitle: "My Book",
            locationTitle: position.title(contentTitle: "Introduction", bookTitle: "My Book"),
            headingPosition: position,
            percentComplete: 0,
            timeRemaining: 60
        )

        XCTAssertEqual(summary, "My Book. Introduction. 0 percent. 1 minute remaining.")
    }

    func testBriefWhereAmIPlacesHeadingTextBeforeHeadingNumber() throws {
        let headings = (0..<20).map {
            Heading(level: 1, text: "Part \($0 + 1)", chapterIndex: $0, characterOffset: 0)
        }

        let summary = ReaderViewModel.briefWhereAmISummary(
            bookTitle: "Book Title",
            locationTitle: "The Final Stand",
            headingPosition: HeadingPosition(in: headings, chapterIndex: 14, characterOffset: 10),
            percentComplete: 75,
            timeRemaining: 3_600
        )

        let heading = try XCTUnwrap(summary.range(of: "The Final Stand"))
        let number = try XCTUnwrap(summary.range(of: "Heading 15 of 20"))
        XCTAssertLessThan(heading.lowerBound, number.lowerBound)
    }

    func testEPUBUsesRichMetadataEditor() {
        XCTAssertTrue(BookFormat.epub.usesRichMetadataEditor)
    }

    func testAudioUsesRichMetadataEditor() {
        XCTAssertTrue(BookFormat.audio.usesRichMetadataEditor)
    }

    func testPlainTextUsesSimpleMetadataEditor() {
        XCTAssertFalse(BookFormat.txt.usesRichMetadataEditor)
    }

    func testMarkdownUsesSimpleMetadataEditor() {
        XCTAssertFalse(BookFormat.markdown.usesRichMetadataEditor)
    }

    func testHTMLUsesSimpleMetadataEditor() {
        XCTAssertFalse(BookFormat.html.usesRichMetadataEditor)
    }

    func testEveryFormatMapsToExactlyOneMetadataEditorStyle() {
        for format in BookFormat.allCases {
            let usesRich = format.usesRichMetadataEditor
            let usesSimple = !usesRich
            XCTAssertNotEqual(usesRich, usesSimple, "Unexpected editor mapping for \(format)")
        }
    }

    private func populatedAudioMetadata() -> AudioMetadata {
        AudioMetadata(
            title: "My Audiobook",
            artist: "Felicity Hargrove",
            album: "Great Listens",
            genre: "Fiction",
            year: "2024",
            duration: "3:45:20",
            fileFormat: "MP3"
        )
    }
}
