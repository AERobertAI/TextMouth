import AppKit
import XCTest
@testable import TextMouth

/// The library list's cloud notes (FR02): a row in a cloud library shows and
/// speaks its book's state after the New or Now Reading badge, and a row in a
/// local library, or one on another volume, looks and reads as it always has.
/// Every row reads only what `BookCloudStates` recorded.
@MainActor
final class LibraryCloudNoteTests: XCTestCase {
    /// A download partway done: 2 of 5 files, 40 percent by size.
    private let partway = BookDownloadProgress(
        completedFiles: 2,
        totalFiles: 5,
        completedBytes: 400,
        totalBytes: 1_000
    )

    /// Why a download failed, as the list records it.
    private let failureReason = BookCloudError.offline.explanation(in: .iCloudDrive)

    /// Every state a book can be recorded in.
    private var everyState: [BookCloudState] {
        [.local, .downloaded, .inCloud, .downloading(partway), .downloadFailed(failureReason), .waitingForSync]
    }

    // MARK: - Spoken Labels

    /// Without a cloud state, a row reads exactly as it did before FR02.
    func testRowWithoutACloudStateReadsAsBefore() {
        XCTAssertEqual(
            BookRow(book: book()).rowAccessibilityLabel,
            "Moby-Dick, by Herman Melville, 42 percent, EPUB"
        )
    }

    /// Each state's spoken note follows the title and author, in the place
    /// the New and Now Reading badges take, and the contract's words are
    /// used as they are. A local state has nothing to say.
    func testRowSpeaksEachStatesNoteAfterTheAuthor() {
        let expected: [(BookCloudState, String)] = [
            (.downloaded, "Moby-Dick, by Herman Melville, Downloaded, 42 percent, EPUB"),
            (.inCloud, "Moby-Dick, by Herman Melville, In Cloud, 42 percent, EPUB"),
            (.downloading(partway), "Moby-Dick, by Herman Melville, Downloading, 40 percent, 42 percent read, EPUB"),
            (.downloadFailed(failureReason), "Moby-Dick, by Herman Melville, Download Failed, 42 percent, EPUB"),
            (.waitingForSync, "Moby-Dick, by Herman Melville, Waiting for Sync, 42 percent, EPUB"),
            (.local, "Moby-Dick, by Herman Melville, 42 percent, EPUB"),
        ]
        for (state, label) in expected {
            XCTAssertEqual(BookRow(book: book(), cloudState: state).rowAccessibilityLabel, label, "\(state)")
        }
    }

    /// The note comes after the New badge, after the Now Reading badge, and
    /// after "Selected" and the rest of the row's start in edit mode.
    func testNoteFollowsTheRowsBadges() {
        XCTAssertEqual(
            BookRow(book: book(percentRead: nil, opened: false), cloudState: .inCloud).rowAccessibilityLabel,
            "Moby-Dick, by Herman Melville, New, In Cloud, EPUB"
        )
        XCTAssertEqual(
            BookRow(book: book(), isOpenInWindow: true, cloudState: .downloaded).rowAccessibilityLabel,
            "Moby-Dick, by Herman Melville, Now Reading, Downloaded, 42 percent, EPUB"
        )
        XCTAssertEqual(
            BookRow(book: book(), isEditMode: true, isEditSelected: true, cloudState: .waitingForSync)
                .rowAccessibilityLabel,
            "Selected, Moby-Dick, by Herman Melville, Waiting for Sync, 42 percent, EPUB"
        )
    }

    /// While the note speaks a download's percentage, the reading progress
    /// says it is the part read; a book with no progress speaks only the
    /// download's percentage.
    func testDownloadPercentageMakesTheProgressSayRead() {
        XCTAssertEqual(
            BookRow.spokenProgress(for: book(), besideDownloadPercentage: true),
            "42 percent read"
        )
        XCTAssertEqual(
            BookRow.spokenProgress(for: book(), besideDownloadPercentage: false),
            "42 percent"
        )
        XCTAssertEqual(
            BookRow(book: book(percentRead: nil), cloudState: .downloading(partway)).rowAccessibilityLabel,
            "Moby-Dick, by Herman Melville, Downloading, 40 percent, EPUB"
        )
    }

    /// Whatever the state, and with or without reading progress, the label
    /// never holds two bare percentages: at most one "percent" is not
    /// followed by "read".
    func testLabelNeverHoldsTwoBarePercentages() {
        for state in everyState {
            for percentRead in [nil, 0, 42, 100] {
                for opened in [true, false] {
                    let label = BookRow(book: book(percentRead: percentRead, opened: opened), cloudState: state)
                        .rowAccessibilityLabel
                    let percents = label.components(separatedBy: " percent").count - 1
                    let readPercents = label.components(separatedBy: " percent read").count - 1
                    XCTAssertLessThanOrEqual(percents - readPercents, 1, label)
                }
            }
        }
    }

    /// Only a download's state speaks a percentage.
    func testOnlyADownloadSpeaksAPercentage() {
        for state in everyState {
            let speaksPercent = state.spokenNote?.contains("percent") ?? false
            XCTAssertEqual(state.speaksPercentage, speaksPercent, "\(state)")
        }
    }

    // MARK: - Which State a Row Shows

    /// In a cloud library each row shows the state recorded for its book,
    /// and a book no refresh has checked yet shows nothing.
    func testCloudLibraryRowsShowTheirRecordedStates() {
        let states = BookCloudStates()
        let checked = UUID()
        states.setLibraryLocation(.cloud(.dropbox))
        states.record(.inCloud, for: checked)

        XCTAssertEqual(states.listedState(of: checked), .inCloud)
        XCTAssertNil(states.listedState(of: UUID()), "a book not checked yet has no note until the first refresh")
    }

    /// A local library, or one on another volume, shows no notes, even when
    /// something was recorded for its books, so its rows look and read as
    /// they always have.
    func testLocalAndOtherVolumeLibrariesShowNoNotes() {
        let bookID = UUID()
        for location in [StorageLocation.local, .otherVolume(name: "Archive Disk")] {
            let states = BookCloudStates()
            states.setLibraryLocation(location)
            states.record(.downloaded, for: bookID)

            XCTAssertFalse(states.showsCloudNotes)
            XCTAssertNil(states.listedState(of: bookID), "\(location)")
        }
    }

    /// Leaving the cloud takes every note away at once.
    func testLeavingTheCloudRemovesEveryNote() {
        let states = BookCloudStates()
        let bookID = UUID()
        states.setLibraryLocation(.cloud(.googleDrive))
        states.record(.downloaded, for: bookID)

        states.setLibraryLocation(.otherVolume(name: "Archive Disk"))

        XCTAssertNil(states.listedState(of: bookID))
    }

    // MARK: - Summary Line

    /// In a cloud library the summary counts the books whose files are not
    /// all on this Mac: in the cloud, downloading, left by a failed download,
    /// or not synced yet. Downloaded books, local ones, and books not checked
    /// yet are not counted.
    func testSummaryCountsTheBooksNotOnThisMac() {
        let states = BookCloudStates()
        states.setLibraryLocation(.cloud(.iCloudDrive))
        let recorded: [BookCloudState?] = [
            .inCloud, .downloading(partway), .downloadFailed(failureReason), .waitingForSync,
            .downloaded, .local, nil,
        ]
        let books = recorded.map { _ in book() }
        for (book, state) in zip(books, recorded) {
            if let state { states.record(state, for: book.id) }
        }

        XCTAssertEqual(states.countInTheCloud(books), 4)
        XCTAssertEqual(states.countInTheCloud(Array(books.suffix(3))), 0)
    }

    /// A local library, or one on another volume, counts nothing, whatever
    /// was recorded.
    func testSummaryCountsNothingOutsideTheCloud() {
        let books = [book(), book()]
        for location in [StorageLocation.local, .otherVolume(name: "Archive Disk")] {
            let states = BookCloudStates()
            states.setLibraryLocation(location)
            books.forEach { states.record(.inCloud, for: $0.id) }

            XCTAssertEqual(states.countInTheCloud(books), 0, "\(location)")
        }
    }

    /// The bar shows the count and speaks it after everything it said
    /// before, worded for one book or several.
    func testSummaryLineShowsAndSpeaksTheCount() {
        let books = [book(percentRead: nil, opened: false), book(percentRead: nil), book()]

        XCTAssertEqual(
            TimeRemainingBar(books: books, wpm: 200, booksInCloud: 1).summaryAccessibilityLabel,
            "3 books. 3 books have not been opened yet. 1 book is in the cloud"
        )
        XCTAssertEqual(
            TimeRemainingBar(books: books, wpm: 200, booksInCloud: 3).summaryAccessibilityLabel,
            "3 books. 3 books have not been opened yet. 3 books are in the cloud"
        )
        XCTAssertEqual(TimeRemainingBar.cloudCountText(1), "1 book in the cloud")
        XCTAssertEqual(TimeRemainingBar.cloudCountText(3), "3 books in the cloud")
    }

    /// With nothing in the cloud, as in every local library, the bar reads
    /// as it always has.
    func testSummaryLineWithNothingInTheCloudReadsAsBefore() {
        let books = [book(percentRead: nil, opened: false), book(percentRead: nil), book()]

        XCTAssertEqual(
            TimeRemainingBar(books: books, wpm: 200).summaryAccessibilityLabel,
            "3 books. 3 books have not been opened yet"
        )
    }

    // MARK: - The Note's Picture

    /// Every note has a picture that exists in SF Symbols, so no row draws an
    /// empty space; a state without a note has no picture either.
    func testEveryNoteHasAnExistingSymbol() {
        for state in everyState {
            if state.visibleNote == nil {
                XCTAssertNil(state.noteSymbolName, "\(state)")
            } else {
                let name = state.noteSymbolName
                XCTAssertNotNil(name, "\(state)")
                XCTAssertNotNil(
                    name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) },
                    "\(state): \(name ?? "no symbol")"
                )
            }
        }
    }

    // MARK: - Helpers

    /// An EPUB of Moby-Dick that is `percentRead` percent read (no progress
    /// at all when nil), opened before unless `opened` is false, which makes
    /// it New. It has no word count, so its row shows no time remaining.
    private func book(percentRead: Int? = 42, opened: Bool = true) -> Book {
        Book(
            title: "Moby-Dick",
            author: "Herman Melville",
            format: .epub,
            filePath: "/Library Rows/Moby-Dick.epub",
            md5Hash: "",
            lastOpened: opened ? Date() : nil,
            readingPosition: percentRead.map {
                ReadingPosition(chapterIndex: 0, characterOffset: 0, globalCharacterOffset: $0 * 10)
            },
            totalCharacterCount: percentRead == nil ? nil : 1_000
        )
    }
}
