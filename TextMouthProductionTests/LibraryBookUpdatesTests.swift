import Combine
import XCTest
@testable import TextMouth

/// How the library publishes changes to the books open in readers (TODO
/// P10): what is published, with which revision, to whom, in what order,
/// and how package moves are bracketed.
///
/// Each test watches its books directly, as a reader does when it opens, and
/// records every event the library sends about them. Most change the
/// library model's library in place, which saves nothing to disk; the one
/// that goes through the library's own edit path puts the index back.
@MainActor
final class LibraryBookUpdatesTests: XCTestCase {

    // MARK: - What Is Published

    /// Each change of a watched book's folder, file, metadata, or analysis
    /// is published once, carrying the row as the library now holds it,
    /// with a revision one higher than the last.
    func testEachChangeOfAWatchedBookIsPublishedWithTheNextRevision() {
        let (model, books) = makeLibrary()
        let book = books[0]
        let recorder = record(book, in: model)
        model.bookUpdates.watch(book)

        model.library.books[0].title = "Spring Tides"
        model.library.books[0].folderPath = "Shelf"
        model.library.books[0].audioDuration = 90

        XCTAssertEqual(recorder.updates.map(\.revision), [1, 2, 3])
        XCTAssertEqual(recorder.updates.map(\.book.title), ["Spring Tides", "Spring Tides", "Spring Tides"])
        XCTAssertEqual(recorder.updates.map(\.book.folderPath), ["", "Shelf", "Shelf"])
        XCTAssertEqual(recorder.updates.last?.book.audioDuration, 90)
        XCTAssertEqual(model.bookUpdates.revision(of: book.id), 3)
    }

    /// What a reader writes for itself (its position, a bookmark, its voice,
    /// its playback times) and what only the library keeps (when the book
    /// was last opened, its manual order) is published to no one, and the
    /// revision stays where it was.
    func testReaderStateAndLibraryBookkeepingArePublishedToNoOne() {
        let (model, books) = makeLibrary()
        let book = books[0]
        let recorder = record(book, in: model)
        model.bookUpdates.watch(book)

        model.updateLiveReadingPosition(bookID: book.id, position: ReadingPosition(chapterIndex: 1, characterOffset: 12))
        model.library.addBookmark(bookID: book.id, chapterIndex: 1, characterOffset: 12)
        model.library.books[0].localWPM = 260
        model.library.books[0].lastPlaybackStarted = Date()
        model.library.books[0].lastOpened = Date()
        model.library.books[0].manualSortOrder = 3

        XCTAssertEqual(recorder.events.count, 0, "Reader state or bookkeeping was published")
        XCTAssertEqual(model.bookUpdates.revision(of: book.id), 0)
    }

    /// The library's own metadata edit, `updateBookMetadata`, as the Library
    /// window's editors make it, is published to the book's readers.
    func testAMetadataEditThroughTheLibraryModelIsPublished() throws {
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        let (model, books) = makeLibrary()
        let book = books[0]
        let recorder = record(book, in: model)
        model.bookUpdates.watch(book)

        var edited = book
        edited.title = "Neap Tides"
        edited.author = "Harbour Survey Office"
        model.updateBookMetadata(edited)

        XCTAssertEqual(recorder.updates.count, 1)
        XCTAssertEqual(recorder.updates.first?.revision, 1)
        XCTAssertEqual(recorder.updates.first?.book.title, "Neap Tides")
        XCTAssertEqual(recorder.updates.first?.book.author, "Harbour Survey Office")
    }

    // MARK: - Who Hears It

    /// A book no reader has open publishes nothing. Once a reader opens it,
    /// its changes are published; with two readers open, closing one keeps
    /// them coming, and closing the last stops them. Each reader hears only
    /// its own book.
    func testOnlyBooksOpenInReadersArePublished() {
        let (model, books) = makeLibrary(count: 2)
        let book = books[0]
        let recorder = record(book, in: model)
        let otherRecorder = record(books[1], in: model)

        model.library.books[0].title = "Unwatched Edit"
        XCTAssertEqual(recorder.events.count, 0, "A book no reader has open was published")

        model.bookUpdates.watch(book)
        model.bookUpdates.watch(book)
        model.library.books[0].title = "Seen by Two Readers"
        model.bookUpdates.unwatch(book.id)
        model.library.books[0].title = "Seen by the Reader Still Open"
        model.bookUpdates.unwatch(book.id)
        model.library.books[0].title = "Seen by No One"

        XCTAssertEqual(recorder.updates.map(\.book.title), ["Seen by Two Readers", "Seen by the Reader Still Open"])
        XCTAssertEqual(model.bookUpdates.watchedBookIDs, [])
        XCTAssertEqual(otherRecorder.events.count, 0, "Another book's reader heard about this book")
    }

    /// Revisions keep rising after a book's readers close, so a reader
    /// opened later starts from the latest one and never mistakes an old
    /// update for a new one.
    func testRevisionsKeepRisingAcrossReaders() {
        let (model, books) = makeLibrary()
        let book = books[0]
        let recorder = record(book, in: model)

        model.bookUpdates.watch(book)
        model.library.books[0].title = "First Reading"
        model.bookUpdates.unwatch(book.id)
        model.bookUpdates.watch(model.library.books[0])
        model.library.books[0].title = "Second Reading"

        XCTAssertEqual(recorder.updates.map(\.revision), [1, 2])
    }

    // MARK: - Order

    /// A change the library makes while a reader is applying an update, as
    /// when the reader saves in response, is published after every update
    /// of the change under way, never in the middle of them. So each book's
    /// revisions arrive in order and each ends with its newest row.
    func testAChangeMadeWhileAnUpdateIsAppliedIsPublishedAfterIt() {
        let (model, books) = makeLibrary(count: 2)
        let recorder = EventRecorder()
        var changedInResponse = false
        recorder.subscriptions = books.map { book in
            model.bookUpdates.events(for: book.id).sink { [weak model, weak recorder] event in
                recorder?.events.append(event)
                // The first update heard renames both books again at once.
                guard !changedInResponse, let model else { return }
                changedInResponse = true
                var library = model.library
                for index in library.books.indices {
                    library.books[index].title += ", Second Edition"
                }
                model.library = library
            }
        }
        for book in books {
            model.bookUpdates.watch(book)
        }

        var renamed = model.library
        renamed.books[0].title = "Spring Tides"
        renamed.books[1].title = "Neap Tides"
        model.library = renamed

        XCTAssertEqual(recorder.updates.map(\.revision), [1, 1, 2, 2])
        for book in books {
            let titles = recorder.updates.filter { $0.book.id == book.id }.map(\.book.title)
            XCTAssertEqual(titles.count, 2)
            XCTAssertEqual(titles.last, titles.first.map { $0 + ", Second Edition" })
        }
    }

    // MARK: - Package Moves

    /// A package move is bracketed for each book open in a reader: it hears
    /// that its package will move and that the move has ended, once each,
    /// however the brackets nest. A book no reader has open hears nothing.
    func testPackageMoveBracketsNestAndReachOnlyOpenBooks() {
        let (model, books) = makeLibrary(count: 2)
        let (watched, unwatched) = (books[0], books[1])
        let recorder = record(watched, in: model)
        let unwatchedRecorder = record(unwatched, in: model)
        model.bookUpdates.watch(watched)

        model.bookUpdates.packagesWillMove([watched.id, unwatched.id])
        model.bookUpdates.packagesWillMove([watched.id])
        model.bookUpdates.packagesDidMove([watched.id])
        XCTAssertEqual(recorder.descriptions, ["will move"], "A nested bracket ended the move early")

        model.bookUpdates.packagesDidMove([watched.id, unwatched.id])
        XCTAssertEqual(recorder.descriptions, ["will move", "move ended"])
        XCTAssertEqual(unwatchedRecorder.events.count, 0)

        // A bracket closed without being opened ends nothing.
        model.bookUpdates.packagesDidMove([watched.id])
        XCTAssertEqual(recorder.descriptions, ["will move", "move ended"])
    }

    // MARK: - Fixtures

    /// Every event the library sends about the books it listens to, in order.
    private final class EventRecorder {
        var events: [LibraryBookEvent] = []
        var subscriptions: [AnyCancellable] = []

        /// The updates among the events.
        var updates: [LibraryBookUpdate] {
            events.compactMap { event in
                guard case .updated(let update) = event else { return nil }
                return update
            }
        }

        /// Each event in a word or two, for comparing sequences.
        var descriptions: [String] {
            events.map { event in
                switch event {
                case .packageWillMove: return "will move"
                case .updated(let update): return "updated \(update.revision)"
                case .packageMoveEnded: return "move ended"
                case .textReplaced: return "text replaced"
                case .transcriptReplaced: return "transcript replaced"
                }
            }
        }
    }

    /// Records every event `model` sends about `book` until the test ends.
    private func record(_ book: Book, in model: LibraryViewModel) -> EventRecorder {
        let recorder = EventRecorder()
        recorder.subscriptions = [
            model.bookUpdates.events(for: book.id).sink { [weak recorder] in recorder?.events.append($0) }
        ]
        return recorder
    }

    /// An inert library model listing `count` text books, none in a package,
    /// so nothing these tests do writes a package record.
    private func makeLibrary(count: Int = 1) -> (LibraryViewModel, [Book]) {
        let books = (1...count).map { number in
            Book(
                title: "Tide Table \(number)",
                author: "Odalys Pretorius",
                format: .txt,
                filePath: "/nonexistent/tide-table-\(number).txt",
                md5Hash: "hash-\(number)"
            )
        }
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: books)
        return (model, books)
    }
}
