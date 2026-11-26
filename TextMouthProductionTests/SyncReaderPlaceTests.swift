import XCTest
@testable import TextMouth

/// An open reader and a sync merge that gives its book another place
/// (FR43, plan section 6): at rest, the reader moves to the place and says
/// so; playing, it plays on; a place that is not the later one changes
/// nothing. The readers are made from memory, so nothing plays or is read.
@MainActor
final class SyncReaderPlaceTests: XCTestCase {
    /// The hosted test root's library index, put back after each test: a
    /// reader's save writes it.
    private var sandbox: LibraryIndexSandbox!

    override func setUp() async throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDown() async throws {
        // Optional: tear-down also runs when capturing failed in set-up.
        sandbox?.restore()
    }

    /// A reader at rest, at the start of a book of two chapters, with its
    /// library; the book's row is in the library.
    private func makeReader() -> (reader: ReaderViewModel, library: LibraryViewModel, book: Book) {
        var book = Book(
            title: "Synced Place", format: .txt,
            filePath: "/tmp/\(UUID().uuidString)-synced-place.txt", md5Hash: UUID().uuidString
        )
        var saved = ReadingPosition(chapterIndex: 0, characterOffset: 10)
        saved.lastUpdated = Date(timeIntervalSince1970: 1_790_000_000)
        book.readingPosition = saved
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book])
        let reader = ReaderViewModel(
            book: book, libraryViewModel: library, settingsViewModel: SettingsViewModel(initializeServices: false)
        )
        let chapters = (0..<2).map { Chapter(title: "Part \($0 + 1)", text: String(repeating: "x", count: 500), headings: []) }
        reader.content = DocumentContent(title: book.title, author: book.author, chapters: chapters)
        reader.isLoading = false
        addTeardownBlock { @MainActor in reader.close() }
        return (reader, library, book)
    }

    /// The reading state of `book` with its place at `offset` of chapter 1,
    /// saved `seconds` after the book's own.
    private func state(of book: Book, offset: Int, savedAfter seconds: TimeInterval) -> Book.ReadingState {
        var changed = book
        var place = ReadingPosition(chapterIndex: 1, characterOffset: offset)
        place.lastUpdated = Date(timeIntervalSince1970: 1_790_000_000 + seconds)
        changed.readingPosition = place
        return changed.readingState
    }

    /// A reader at rest moves to the later place another device saved and
    /// says where it came from.
    func testAReaderAtRestMovesToTheLaterPlaceAndSaysSo() {
        let (reader, library, book) = makeReader()
        let recorder = recordingAnnouncements {
            library.syncedReadingStates.send(
                SyncedReadingState(bookID: book.id, state: state(of: book, offset: 200, savedAfter: 60), device: "iPhone")
            )
        }
        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertEqual(reader.currentCharacterOffset, 200)
        XCTAssertEqual(recorder.announcements.map(\.message), [SyncWording.announceMovedToPlace(from: "iPhone")])
    }

    /// Closing the reader after a sync moved it keeps the merged place's own
    /// date, so it never outranks later reading on the other device.
    func testClosingAfterASyncKeepsTheMergedPlacesDate() {
        let (reader, library, book) = makeReader()
        let merged = state(of: book, offset: 200, savedAfter: 60)
        library.syncedReadingStates.send(SyncedReadingState(bookID: book.id, state: merged, device: "iPhone"))
        reader.savePositionIfMoved()
        let saved = library.bookByID(book.id)?.readingPosition
        XCTAssertEqual(saved?.characterOffset, 200)
        XCTAssertEqual(saved?.lastUpdated, merged.readingPosition?.lastUpdated)
    }

    /// The same place with a newer date moves nothing and says nothing: only a
    /// move of the place itself is "Moved" (round 2, item 1).
    func testANewerDateAtTheSamePlaceSaysNothing() {
        let (reader, library, book) = makeReader()
        var same = book
        var place = ReadingPosition(chapterIndex: 0, characterOffset: 10)
        place.lastUpdated = Date(timeIntervalSince1970: 1_790_000_000 + 600)
        same.readingPosition = place
        let recorder = recordingAnnouncements {
            library.syncedReadingStates.send(SyncedReadingState(bookID: book.id, state: same.readingState, device: "iPhone"))
        }
        XCTAssertEqual(reader.currentChapterIndex, 0)
        XCTAssertEqual(reader.currentCharacterOffset, 10)
        XCTAssertTrue(recorder.announcements.isEmpty)
    }

    /// A place past the end of the text is kept within it, as a move of the cursor keeps it.
    func testAPlacePastTheEndIsClampedToTheText() {
        let (reader, library, book) = makeReader()
        library.syncedReadingStates.send(
            SyncedReadingState(bookID: book.id, state: state(of: book, offset: 90_000, savedAfter: 60), device: "iPhone")
        )
        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertEqual(reader.currentCharacterOffset, 500)
    }

    /// A paused reader is never moved either: a pause leaves the speech where
    /// it is, and a place saved elsewhere does not pull it away.
    func testAPausedReaderIsNeverMoved() {
        let (reader, library, book) = makeReader()
        reader.isCurrentlyPlaying = false
        reader.isCurrentlyPaused = true
        let recorder = recordingAnnouncements {
            library.syncedReadingStates.send(
                SyncedReadingState(bookID: book.id, state: state(of: book, offset: 200, savedAfter: 60), device: "iPhone")
            )
        }
        XCTAssertEqual(reader.currentChapterIndex, 0)
        XCTAssertEqual(reader.currentCharacterOffset, 10)
        XCTAssertTrue(recorder.announcements.isEmpty)
    }

    /// A playing reader plays on: its place and its words stay as they were.
    func testAPlayingReaderPlaysOn() {
        let (reader, library, book) = makeReader()
        reader.isCurrentlyPlaying = true
        let recorder = recordingAnnouncements {
            library.syncedReadingStates.send(
                SyncedReadingState(bookID: book.id, state: state(of: book, offset: 200, savedAfter: 60), device: "iPhone")
            )
        }
        XCTAssertEqual(reader.currentChapterIndex, 0)
        XCTAssertEqual(reader.currentCharacterOffset, 10)
        XCTAssertTrue(recorder.announcements.isEmpty)
    }

    /// A place saved before the reader's own is not the later one: nothing
    /// moves and nothing is said.
    func testAnEarlierPlaceChangesNothing() {
        let (reader, library, book) = makeReader()
        let recorder = recordingAnnouncements {
            library.syncedReadingStates.send(
                SyncedReadingState(bookID: book.id, state: state(of: book, offset: 200, savedAfter: -60), device: "iPhone")
            )
        }
        XCTAssertEqual(reader.currentChapterIndex, 0)
        XCTAssertEqual(reader.currentCharacterOffset, 10)
        XCTAssertTrue(recorder.announcements.isEmpty)
    }

    /// Another book's state is not this reader's business.
    func testAnotherBooksPlaceChangesNothing() {
        let (reader, library, book) = makeReader()
        let recorder = recordingAnnouncements {
            library.syncedReadingStates.send(
                SyncedReadingState(bookID: UUID(), state: state(of: book, offset: 200, savedAfter: 60), device: "iPhone")
            )
        }
        XCTAssertEqual(reader.currentCharacterOffset, 10)
        XCTAssertTrue(recorder.announcements.isEmpty)
    }
}
