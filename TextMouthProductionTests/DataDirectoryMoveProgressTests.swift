import XCTest
@testable import TextMouth

/// What a data-directory move under way shows and says (FR02): its phase,
/// the percentage copied, the progress bar's spoken value, each quarter
/// announced once, and Cancel, which counts until the copy is complete.
@MainActor
final class DataDirectoryMoveProgressTests: XCTestCase {

    // MARK: - Announcements

    /// VoiceOver hears what the move waits for, each kind once, where the
    /// library goes when the copy starts, and each quarter once, only the
    /// highest when one large book carries the copy past several; never
    /// 100 percent, which the move's ending says.
    func testTheMoveAnnouncesItsStepsAndEachQuarterOnce() {
        let move = DataDirectoryMoveProgress(destination: URL(fileURLWithPath: "/Volumes/Backup/Library"))

        let recorder = recordingAnnouncements {
            move.wait(for: .importing)
            move.wait(for: .importing)
            move.wait(for: .textExtraction)
            move.beginPreparing()
            move.beginCopying()
            move.receive(Self.progress(percent: 10))
            move.receive(Self.progress(percent: 30))
            move.receive(Self.progress(percent: 80))
            move.receive(Self.progress(percent: 90))
            move.receive(Self.complete)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), [
            "Waiting for the current import to finish...",
            "Waiting for text extraction to finish...",
            "Moving the library to /Volumes/Backup/Library.",
            "Moving the library, 25 percent.",
            "Moving the library, 75 percent.",
        ])
        XCTAssertEqual(move.phase, .finishing)
        XCTAssertEqual(move.percent, 100)
    }

    /// Reset to Default says it is going to the default location.
    func testResetToDefaultSaysItGoesToTheDefaultLocation() {
        let move = DataDirectoryMoveProgress(destination: URL(fileURLWithPath: "/Users/reader/.TextMouth"), isResetToDefault: true)

        let recorder = recordingAnnouncements { move.beginCopying() }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Moving the library to the default location, /Users/reader/.TextMouth."])
        XCTAssertEqual(move.destinationText, "To the default location, /Users/reader/.TextMouth")
        XCTAssertEqual(
            DataDirectoryMoveProgress(destination: URL(fileURLWithPath: "/Volumes/Backup/Library")).destinationText,
            "To /Volumes/Backup/Library"
        )
    }

    // MARK: - What Is Shown

    /// The status shown, the bar's spoken value, and how full the bar is,
    /// in each phase: the bar shows an amount only once the copy starts.
    func testWhatEachPhaseShowsAndSays() {
        let move = DataDirectoryMoveProgress(destination: URL(fileURLWithPath: "/Volumes/Backup/Library"))
        recordingAnnouncements {
            XCTAssertEqual(move.statusText, "Getting ready to move the library…")
            XCTAssertEqual(move.spokenValue, "Getting ready")
            XCTAssertNil(move.fraction)

            move.wait(for: .contentAnalysis)
            XCTAssertEqual(move.statusText, "Waiting for book analysis to finish...")
            XCTAssertEqual(move.spokenValue, "Waiting for book analysis to finish...")
            XCTAssertNil(move.fraction)

            move.beginCopying()
            move.receive(Self.progress(percent: 40))
            XCTAssertEqual(move.statusText, "Moving the library… 40 percent")
            XCTAssertEqual(move.spokenValue, "40 percent")
            XCTAssertEqual(move.fraction, 0.4)

            move.receive(Self.complete)
            XCTAssertEqual(move.statusText, "Finishing the move…")
            XCTAssertEqual(move.spokenValue, "Finishing")
            XCTAssertEqual(move.fraction, 1)
        }
    }

    // MARK: - Cancel

    /// Cancel is heard to count at once, shows as cancelling, and is seen
    /// by the copy's thread; a second press says nothing more.
    func testCancelIsAnnouncedShownAndSeenByTheCopy() throws {
        let move = DataDirectoryMoveProgress(destination: URL(fileURLWithPath: "/Volumes/Backup/Library"))
        move.beginCopying()
        let observer = move.copyObserver(followedBy: nil)
        XCTAssertFalse(observer.isCancelled())

        let recorder = recordingAnnouncements {
            move.cancel()
            move.cancel()
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Cancelling the move."])
        XCTAssertTrue(move.isCancelRequested)
        XCTAssertTrue(observer.isCancelled())
        XCTAssertEqual(move.statusText, "Cancelling the move…")
        XCTAssertEqual(move.spokenValue, "Cancelling")
        XCTAssertThrowsError(try move.checkCancellation()) { error in
            guard case DataDirectoryMigrationError.cancelled = error else {
                return XCTFail("Expected the cancellation, received \(error)")
            }
        }
    }

    /// Once the copy is complete, Cancel can no longer stop the move: it is
    /// unavailable, and a press changes nothing.
    func testCancelDoesNothingOnceTheCopyIsComplete() {
        let move = DataDirectoryMoveProgress(destination: URL(fileURLWithPath: "/Volumes/Backup/Library"))
        recordingAnnouncements {
            move.beginCopying()
            move.receive(Self.complete)
        }
        XCTAssertFalse(move.canCancel)

        let recorder = recordingAnnouncements { move.cancel() }

        XCTAssertEqual(recorder.announcements, [])
        XCTAssertFalse(move.isCancelled)
        XCTAssertEqual(move.statusText, "Finishing the move…")
    }

    /// An observer bound around the move hears every report after the
    /// move, and can cancel the move too.
    func testAnOuterObserverHearsTheCopyAndCanCancelIt() {
        let move = DataDirectoryMoveProgress(destination: URL(fileURLWithPath: "/Volumes/Backup/Library"))
        let heard = CopyReports(cancellingAfterItems: 1)
        let observer = move.copyObserver(followedBy: heard.observer())

        observer.report(Self.progress(percent: 10))

        XCTAssertEqual(heard.all, [Self.progress(percent: 10)])
        XCTAssertTrue(observer.isCancelled(), "the outer observer's cancel was not heard")
        XCTAssertFalse(move.isCancelled, "the move's own Cancel was pressed")
    }

    // MARK: - Words

    /// A move is refused while books are open, naming them: none known, one,
    /// two, or more than three, which are counted.
    func testTheOpenBooksRefusalNamesTheBooks() {
        XCTAssertEqual(
            DataDirectoryMoveRefusal.booksOpen([]).localizedDescription,
            "The library can't move while a book is open. Close it first."
        )
        XCTAssertEqual(
            DataDirectoryMoveRefusal.booksOpen(["Tide Tables"]).localizedDescription,
            "The library can't move while a book is open. Close “Tide Tables” first."
        )
        XCTAssertEqual(
            DataDirectoryMoveRefusal.booksOpen(["Anchor Watch", "Tide Tables"]).localizedDescription,
            "The library can't move while books are open. Close these first: “Anchor Watch” and “Tide Tables”."
        )
        XCTAssertEqual(
            DataDirectoryMoveRefusal.booksOpen(["A", "B", "C", "D"]).localizedDescription,
            "The library can't move while books are open. Close these first: “A”, “B”, “C”, and 1 more."
        )
    }

    /// A move is refused while books are only in the cloud, counting them
    /// and saying how to download them.
    func testTheCloudRefusalCountsTheBooks() {
        XCTAssertEqual(
            DataDirectoryMoveRefusal.booksNotDownloaded(1).localizedDescription,
            "1 book isn't downloaded. Download it first: select it in the library, then choose Download Now."
        )
        XCTAssertEqual(
            DataDirectoryMoveRefusal.booksNotDownloaded(5).localizedDescription,
            "5 books aren't downloaded. Download them first: select them in the library, then choose Download Now."
        )
    }

    /// While the library moves, a Library window refuses to open or add
    /// books; books opened from Finder wait for the move instead, and
    /// bringing the Library window forward needs no library.
    func testWhatALibraryWindowRefusesWhileTheLibraryMoves() {
        let book = UUID()
        let refusals: [(GlobalAction, String?)] = [
            (.openBookFile, "Books can't be added while the library is moving."),
            (.newFromText, "Books can't be added while the library is moving."),
            (.importDAISYFolder, "Books can't be added while the library is moving."),
            (.openBookWindow(book), "Books can't be opened while the library is moving."),
            (.continueToNextBook(book), "Books can't be opened while the library is moving."),
            (.openFiles([URL(fileURLWithPath: "/tmp/Tide Tables.epub")]), nil),
            (.goToLibrary, nil),
        ]
        for (action, refusal) in refusals {
            XCTAssertEqual(DataDirectoryMoveWording.refusal(of: action), refusal, "\(action)")
        }
    }

    // MARK: - Fixtures

    /// A copy `percent` done, with items still to copy.
    private static func progress(percent: Int) -> DataDirectoryCopyProgress {
        DataDirectoryCopyProgress(copiedBytes: Int64(percent), totalBytes: 100, copiedItems: 1, totalItems: 10)
    }

    /// A complete copy.
    private static let complete = DataDirectoryCopyProgress(copiedBytes: 100, totalBytes: 100, copiedItems: 10, totalItems: 10)
}
