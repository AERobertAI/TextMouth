import XCTest
@testable import TextMouth

/// What a finished book's surfaces say (TODO P07). The user decided on
/// October 10, 2026 (question 12): "yes except the reader, those controls
/// with the info should still be there". So the library row, Speak Info,
/// Where Am I?, and Copy Reading Position say "Finished" for a book resting
/// at its end, in place of "100 percent" and its time left, while the
/// reader's own controls keep their percent and time. Every word is pinned
/// here, without a window.
@MainActor
final class FinishedBookWordingTests: XCTestCase {

    // MARK: - The Library Row

    /// A book resting at its end says "Finished" in its row, shown and
    /// spoken, where it said "100%" and "0:00 left": VoiceOver hears "Dune,
    /// by Frank Herbert, Finished, EPUB", and a braille display shows the
    /// word, beside a download's percentage too. A book at 100 percent short
    /// of its end, as one saved at its last word, still says its percent and
    /// time left, and so does a book Books Finished counts that is being
    /// read again: Finished means resting at the end.
    func testTheLibraryRowSaysFinishedForABookAtItsEnd() throws {
        let finished = Self.book(at: Self.total)
        XCTAssertEqual(BookRow.progressText(for: finished)?.visible, "Finished")
        XCTAssertEqual(BookRow.progressText(for: finished)?.spoken, "Finished")
        XCTAssertEqual(BookRow.spokenProgress(for: finished, besideDownloadPercentage: true), "Finished")
        XCTAssertNil(BookRow.timeRemaining(for: finished, wpm: 200), "A finished book's row says its time left")
        XCTAssertEqual(BookRow(book: finished, wpm: 200).rowAccessibilityLabel, "Dune, by Frank Herbert, Finished, EPUB")

        for (place, percent) in [(Self.total - 7, "100"), (Self.total * 2 / 5, "40")] {
            let reading = Self.book(at: place)
            let remaining = try XCTUnwrap(BookRow.timeRemaining(for: reading, wpm: 200), "No time left at \(percent) percent")
            XCTAssertEqual(BookRow.progressText(for: reading)?.visible, "\(percent)%")
            XCTAssertEqual(
                BookRow(book: reading, wpm: 200).rowAccessibilityLabel,
                "Dune, by Frank Herbert, \(percent) percent, \(BookRow.remainingText(remaining).spoken), EPUB"
            )
        }
    }

    // MARK: - Speak Info

    /// Speak Info says "Finished" for a book resting at its end, as its
    /// row does, where it said "100 percent. 0 seconds remaining.": the
    /// book's facts are its row's (`BookInfoFacts`), and the brief summary
    /// reads "Dune. By Frank Herbert. EPUB. In Classics. Finished."
    func testSpeakInfoSaysFinishedForABookAtItsEnd() {
        let finished = Self.book(at: Self.total)
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [finished], folders: [BookFolder(name: "Classics")])
        let facts = BookInfoFacts(
            finished,
            library: library,
            wordsPerMinute: 200,
            cloudStates: BookCloudStates(),
            keptBooks: KeptBooks(file: nil),
            measuresFileSize: false
        )

        XCTAssertEqual(facts.progress, "Finished")
        XCTAssertNil(facts.timeRemaining, "Speak Info says a finished book's time left")
        XCTAssertEqual(LibraryInfoWording.brief(.book(facts)), "Dune. By Frank Herbert. EPUB. In Classics. Finished.")
    }

    // MARK: - Where Am I? and Copy Reading Position

    /// Where Am I? says "Finished" for a book resting at its end, where it
    /// said "100 percent. 0 seconds remaining.": the brief summary is
    /// "Dune. Appendix. Heading 40 of 40. Finished."; the full one gives the
    /// book's whole time too, and no time left in the heading. A book short
    /// of its end says its percent and time left, as before.
    func testWhereAmISaysFinishedForABookAtItsEnd() {
        let place = Self.lastHeading
        let wholeTime: TimeInterval = 9 * 3_600 + 41 * 60 + 7
        XCTAssertEqual(
            ReaderViewModel.briefWhereAmISummary(
                bookTitle: "Dune", locationTitle: "Appendix", headingPosition: place,
                percentComplete: 100, timeRemaining: 0, isFinished: true
            ),
            "Dune. Appendix. Heading 40 of 40. Finished."
        )
        XCTAssertEqual(
            ReaderViewModel.fullWhereAmISummary(
                bookTitle: "Dune", locationTitle: "Appendix", headingPosition: place,
                percentComplete: 100, timeRemaining: 0, timeRemainingInHeading: 0, totalTime: wholeTime, isFinished: true
            ),
            "Dune. Appendix. Heading 40 of 40. Finished. Total book time: \(TimeFormatting.spoken(wholeTime))."
        )
        XCTAssertEqual(
            ReaderViewModel.briefWhereAmISummary(
                bookTitle: "Dune", locationTitle: "Appendix", headingPosition: place,
                percentComplete: 99.96, timeRemaining: 2
            ),
            "Dune. Appendix. Heading 40 of 40. 100 percent. \(TimeFormatting.spoken(2)) remaining."
        )
    }

    /// Copy Reading Position copies "Finished" for a book resting at its
    /// end, where it copied "100.0% through | 0:00 remaining"; a book short
    /// of its end copies its percent and time left, as before.
    func testCopyReadingPositionSaysFinishedForABookAtItsEnd() {
        XCTAssertEqual(
            ReaderViewModel.readingPositionSummary(
                bookTitle: "Dune", author: "Frank Herbert", locationTitle: "Appendix", headingPosition: Self.lastHeading,
                percentComplete: 100, formattedTimeRemaining: "0:00", isFinished: true
            ),
            "Dune | by Frank Herbert | Appendix | Heading 40 of 40 | Finished"
        )
        XCTAssertEqual(
            ReaderViewModel.readingPositionSummary(
                bookTitle: "Dune", author: "Frank Herbert", locationTitle: "Appendix", headingPosition: Self.lastHeading,
                percentComplete: 99.96, formattedTimeRemaining: "0:02"
            ),
            "Dune | by Frank Herbert | Appendix | Heading 40 of 40 | 100.0% through | 0:02 remaining"
        )
    }

    // MARK: - Fixtures

    /// A place in the last of forty headings, each a chapter of its own,
    /// the last named Appendix.
    private static var lastHeading: HeadingPosition {
        let headings = (0..<40).map { number in
            Heading(level: 1, text: number == 39 ? "Appendix" : "Part \(number + 1)", chapterIndex: number, characterOffset: 0)
        }
        return HeadingPosition(in: headings, chapterIndex: 39, characterOffset: 500)
    }

    /// The fixture book's measured text: 10,000 UTF-16 units, 2,000 words,
    /// so its last word, seven units short of its end, reads 100 percent,
    /// as a real book's does.
    private static let total = 10_000

    /// Dune by Frank Herbert, an EPUB opened before, measured, and saved
    /// `globalOffset` into its text.
    private static func book(at globalOffset: Int) -> Book {
        Book(
            title: "Dune",
            author: "Frank Herbert",
            format: .epub,
            filePath: "/nowhere/dune.epub",
            md5Hash: "dune",
            folderPath: "Classics",
            lastOpened: Date(timeIntervalSince1970: 1_790_000_000),
            readingPosition: ReadingPosition(chapterIndex: 3, characterOffset: 0, globalCharacterOffset: globalOffset),
            totalWordCount: 2_000,
            totalCharacterCount: total
        )
    }
}
