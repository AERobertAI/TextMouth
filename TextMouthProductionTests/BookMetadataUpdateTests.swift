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

    // MARK: - What a Reader Takes from the Library (TODO P10)

    /// A reader taking the library's fields from the library's row gets the
    /// row's file location, editable metadata, and analysis, and keeps every
    /// part of its own state: position, bookmarks, voice, speed, pitch,
    /// navigation units, skipped sections, end-of-book behavior, and
    /// playback times. The library's bookkeeping stays the reader's too.
    func testLibraryFieldsCarryLocationMetadataAndAnalysisButNoReaderState() {
        let id = UUID()
        let readerPosition = ReadingPosition(chapterIndex: 3, characterOffset: 120)
        let readerBookmark = Bookmark(number: 1, chapterIndex: 2, characterOffset: 9, label: "Ebb")
        let started = Date(timeIntervalSince1970: 1_000)
        let stopped = Date(timeIntervalSince1970: 2_000)
        var reader = Book(
            id: id,
            title: "Old Title",
            author: "Old Author",
            format: .epub,
            filePath: "/Library/Old/book.tmb/book.epub",
            md5Hash: "old-hash",
            folderPath: "Old",
            lastOpened: started,
            readingPosition: readerPosition,
            bookmarks: [readerBookmark],
            totalWordCount: 10,
            tmbDirectoryName: "book.tmb",
            lastPlaybackStarted: started,
            lastPlaybackStopped: stopped,
            localVoiceID: "reader-voice",
            localWPM: 240,
            localPitch: 1.1,
            skippedHeadingIDs: ["notes"],
            localEndOfBookBehavior: EndOfBookBehavior.stop.rawValue,
            localSkipForwardUnit: "sentence",
            localSkipBackwardUnit: "paragraph",
            manualSortOrder: 4
        )
        let row = Book(
            id: id,
            title: "New Title",
            author: "New Author",
            format: .epub,
            filePath: "/Library/New/book-2.tmb/book.epub",
            md5Hash: "new-hash",
            folderPath: "New",
            lastOpened: stopped,
            readingPosition: ReadingPosition(chapterIndex: 0, characterOffset: 0),
            bookmarks: [],
            totalWordCount: 99,
            tmbDirectoryName: "book-2.tmb",
            localVoiceID: "library-voice",
            localWPM: 180,
            manualSortOrder: 0,
            epubPublisher: "Harbour Press",
            epubPublicationDate: "2026"
        )

        reader.libraryFields = row.libraryFields

        XCTAssertEqual(reader.libraryFields, row.libraryFields)
        XCTAssertEqual(reader.fileLocation, Book.FileLocation(
            folderPath: "New",
            filePath: "/Library/New/book-2.tmb/book.epub",
            tmbDirectoryName: "book-2.tmb"
        ))
        XCTAssertEqual(reader.editableMetadata, row.editableMetadata)
        XCTAssertEqual(reader.epubPublisher, "Harbour Press")
        XCTAssertEqual(reader.totalWordCount, 99)
        // The reader's own state, and the library's bookkeeping, are untouched.
        XCTAssertEqual(reader.readingPosition, readerPosition)
        XCTAssertEqual(reader.bookmarks, [readerBookmark])
        XCTAssertEqual(reader.localVoiceID, "reader-voice")
        XCTAssertEqual(reader.localWPM, 240)
        XCTAssertEqual(reader.localPitch, 1.1)
        XCTAssertEqual(reader.skippedHeadingIDs, ["notes"])
        XCTAssertEqual(reader.localEndOfBookBehavior, EndOfBookBehavior.stop.rawValue)
        XCTAssertEqual(reader.localSkipForwardUnit, "sentence")
        XCTAssertEqual(reader.localSkipBackwardUnit, "paragraph")
        XCTAssertEqual(reader.lastPlaybackStarted, started)
        XCTAssertEqual(reader.lastPlaybackStopped, stopped)
        XCTAssertEqual(reader.lastOpened, started)
        XCTAssertEqual(reader.manualSortOrder, 4)
    }

    /// Two rows that differ only in reader state or library bookkeeping have
    /// equal library fields, so such a change is nothing a reader must
    /// apply; a change of folder, of metadata, or of analysis is.
    func testOnlyLocationMetadataAndAnalysisChangeTheLibraryFields() {
        let book = Book(title: "Slack Water", format: .txt, filePath: "/Library/a.tmb/a.txt", md5Hash: "hash")

        var readerState = book
        readerState.readingPosition = ReadingPosition(chapterIndex: 1, characterOffset: 7)
        readerState.bookmarks = [Bookmark(number: 1, chapterIndex: 1, characterOffset: 7)]
        readerState.localWPM = 300
        readerState.lastOpened = Date()
        readerState.manualSortOrder = 2
        XCTAssertEqual(readerState.libraryFields, book.libraryFields)

        var moved = book
        moved.folderPath = "Shelf"
        XCTAssertNotEqual(moved.libraryFields, book.libraryFields)

        var renamed = book
        renamed.title = "Slack Water, Annotated"
        XCTAssertNotEqual(renamed.libraryFields, book.libraryFields)

        var measured = book
        measured.audioDuration = 61
        XCTAssertNotEqual(measured.libraryFields, book.libraryFields)
    }

    /// An audiobook's tags give way to the library's title and author, and
    /// to each of album, genre, and year once edited; a field never edited
    /// keeps its tag, and an edit to an empty string clears it.
    func testMergingEditableAudioMetadataOverlaysTheEditedFields() {
        var tags = AudioMetadata()
        tags.title = "Track Title"
        tags.artist = "Tag Artist"
        tags.album = "Tag Album"
        tags.genre = "Tag Genre"
        tags.year = "1987"
        let book = Book(
            title: "Breakwater Soundings",
            author: "Harbour Survey Office",
            format: .audio,
            filePath: "/Library/b.tmb/Tracks",
            md5Hash: "hash",
            audioAlbum: "Second Survey",
            audioGenre: nil,
            audioYear: ""
        )

        let merged = book.mergingEditableAudioMetadata(tags)

        XCTAssertEqual(merged.title, "Breakwater Soundings")
        XCTAssertEqual(merged.artist, "Harbour Survey Office")
        XCTAssertEqual(merged.album, "Second Survey")
        XCTAssertEqual(merged.genre, "Tag Genre")
        XCTAssertEqual(merged.year, "")
    }
}
