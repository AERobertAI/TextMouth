import XCTest
@testable import TextMouth

/// The words of the imports under way (FR10), pinned, so the import overlay
/// and VoiceOver say exactly these: the book under way and its step, named
/// as its failure would name it, the archive's extraction, the count, and
/// what VoiceOver reads for the overlay.
final class ImportProgressWordingTests: XCTestCase {

    // MARK: - The Book and Its Step

    /// Every step a book can be at is named as its failure names it
    /// (`ImportStep.activity`), begun in lowercase, so the overlay and a
    /// failure use the same words for the same step.
    func testEveryStepIsNamedAsItsFailureNamesIt() {
        let expected: [(ImportStep, String)] = [
            (.checkingFormat, "checking its format"),
            (.readingSource, "reading the file"),
            (.preparingPackage, "creating its package"),
            (.copying, "copying it into the library"),
            (.extractingArchive, "extracting the archive"),
            (.convertingAudio, "converting its DAISY audio"),
            (.checkingPackage, "checking the package"),
            (.readingText, "reading its text"),
            (.readingAudio, "reading its audio"),
            (.savingRecord, "saving its bookInfo.json file"),
            (.publishing, "adding it to the library folder"),
            (.reinstating, "returning it to the library")
        ]
        for (step, phrase) in expected {
            XCTAssertEqual(ImportProgressWording.step(step), phrase)
            XCTAssertEqual(phrase.prefix(1).uppercased() + phrase.dropFirst(), step.activity, "\(step) is worded unlike its failure")
        }
    }

    /// The book a batch is importing is named by its number of the total,
    /// its name in the archive, and its step.
    func testTheBookLineNamesTheBookItsNumberAndItsStep() {
        XCTAssertEqual(
            ImportProgressWording.book("Moby Dick.epub", number: 3, of: 100, step: .readingText),
            "Book 3 of 100: “Moby Dick.epub”, reading its text"
        )
        XCTAssertEqual(
            ImportProgressWording.book("Talking Book", number: 1, of: 1, step: .readingSource),
            "Book 1 of 1: “Talking Book”, reading the file"
        )
    }

    /// The one book an import brings in, a file or an archive holding one
    /// book, is named with the step it is at, and an audiobook's archive
    /// with how far it has been extracted, while it is.
    func testTheOneBookLineNamesTheBookAndItsStep() {
        XCTAssertEqual(ImportProgressWording.book("Moby Dick.epub", step: .readingText), "“Moby Dick.epub”, reading its text")
        XCTAssertEqual(
            ImportProgressWording.book("Harbor Talks.zip", step: .extractingArchive),
            "“Harbor Talks.zip”, extracting the archive"
        )
        XCTAssertEqual(
            ImportProgressWording.book(
                "Harbor Talks.zip",
                step: .extractingArchive,
                extraction: ArchiveExtractionProgress(entriesDone: 12, entries: 30, bytesDone: 120_000_000, bytes: 340_000_000)
            ),
            "“Harbor Talks.zip”, extracting the archive: 12 of 30 items, 120 MB of 340 MB"
        )
    }

    // MARK: - It Is Moving

    /// The time on a book is said once it has taken 10 seconds, counted in
    /// steps of 5 seconds, so a book that never leaves its step shows as a
    /// time that keeps growing, while what VoiceOver reads changes only
    /// every few seconds.
    func testTheTimeOnABookIsSaidOnceItIsLongInStepsOfFiveSeconds() {
        XCTAssertEqual(ImportProgressWording.timeOnBookShownAfter, 10)
        XCTAssertEqual(ImportProgressWording.timeOnBookStep, 5)
        XCTAssertNil(ImportProgressWording.timeOnBook(0))
        XCTAssertNil(ImportProgressWording.timeOnBook(9.9))
        XCTAssertEqual(ImportProgressWording.timeOnBook(10), "10 seconds on this book")
        XCTAssertEqual(ImportProgressWording.timeOnBook(14.9), "10 seconds on this book")
        XCTAssertEqual(ImportProgressWording.timeOnBook(15), "15 seconds on this book")
        XCTAssertEqual(ImportProgressWording.timeOnBook(60), "1 minute on this book")
        XCTAssertEqual(ImportProgressWording.timeOnBook(69.9), "1 minute, 5 seconds on this book")
        XCTAssertEqual(ImportProgressWording.timeOnBook(3_725), "1 hour, 2 minutes, 5 seconds on this book")
        XCTAssertNil(ImportProgressWording.timeOnBook(.nan))
    }

    // MARK: - The Time Left

    /// The time left is said in steps that suit its size, so an estimate
    /// recomputed as each book finishes changes its words only when it moves
    /// by a step that matters: less than a minute, then whole minutes under
    /// 10, five minutes under an hour, and a quarter hour beyond.
    func testTimeLeftIsRoundedToStepsThatSuitItsSize() {
        let expected: [(TimeInterval, String)] = [
            (0, "Less than a minute left"),
            (59, "Less than a minute left"),
            (60, "About 1 minute left"),
            (89, "About 1 minute left"),
            (90, "About 2 minutes left"),
            (4 * 60 + 29, "About 4 minutes left"),
            (9 * 60 + 40, "About 10 minutes left"),
            (12 * 60 + 29, "About 10 minutes left"),
            (12 * 60 + 30, "About 15 minutes left"),
            (58 * 60, "About 1 hour left"),
            (70 * 60, "About 1 hour, 15 minutes left"),
            (2 * 3_600 + 31 * 60, "About 2 hours, 30 minutes left")
        ]
        for (seconds, words) in expected {
            XCTAssertEqual(ImportProgressWording.timeLeft(seconds), words, "\(seconds) seconds")
        }
        XCTAssertEqual(ImportTimeEstimate.rounded(.infinity), 0)
        XCTAssertEqual(ImportTimeEstimate.rounded(.nan), 0)
    }

    /// The estimate is the average time of the books timed so far times the
    /// books left, and there is none before a book is timed or once no book
    /// is left.
    func testTheEstimateIsTheAverageOfTheBooksTimedTimesTheBooksLeft() {
        XCTAssertEqual(ImportTimeEstimate.secondsLeft(timedSeconds: 90, timedBooks: 3, remaining: 7), 210)
        XCTAssertNil(ImportTimeEstimate.secondsLeft(timedSeconds: 0, timedBooks: 0, remaining: 7), "no book timed yet")
        XCTAssertNil(ImportTimeEstimate.secondsLeft(timedSeconds: 90, timedBooks: 3, remaining: 0), "no book left")
        XCTAssertNil(ImportTimeEstimate.secondsLeft(timedSeconds: .infinity, timedBooks: 3, remaining: 2))
    }

    /// The imports waiting behind the one shown are counted, in agreement
    /// with their number (FR10).
    func testTheImportsWaitingAreCounted() {
        XCTAssertEqual(ImportProgressWording.waiting(1), "1 more import waiting")
        XCTAssertEqual(ImportProgressWording.waiting(2), "2 more imports waiting")
    }

    /// Once Cancel is pressed the overlay says the import stops after the
    /// book under way, or, before any book, only that it is cancelling.
    func testCancellingIsSaidInPlaceOfTheTimeLeft() {
        XCTAssertEqual(ImportProgressWording.cancelling(afterBook: true), "Cancelling after this book...")
        XCTAssertEqual(ImportProgressWording.cancelling(afterBook: false), "Cancelling...")
    }

    // MARK: - Counts and Extraction

    /// The count says the books done of the total, with the overlay's noun,
    /// as the overlay's count line shows it, under the overlay's title; a
    /// ZIP import starts by saying it extracts the archive.
    func testTheCountTheTitleAndTheStart() {
        XCTAssertEqual(ImportProgressWording.count(done: 2, of: 100), "2 of 100 books processed")
        XCTAssertEqual(ImportProgressWording.count(done: 1, of: 1), "1 of 1 books processed")
        XCTAssertEqual(CountWording.progress(3, of: 60, "books extracted"), "3 of 60 books extracted")
        XCTAssertEqual(ImportProgressWording.startingArchive, "Extracting archive...")
        XCTAssertEqual(ImportProgressWording.title, "Importing Books")
        XCTAssertEqual(ImportProgressWording.itemNoun, "books processed")
    }

    /// The extraction line counts the archive's items and the bytes they
    /// declare, written as Finder writes sizes, from "0 bytes" up; an
    /// archive declaring no bytes is counted by its items alone (FR10).
    func testTheExtractionLineCountsItemsAndBytes() {
        XCTAssertEqual(
            ImportProgressWording.extracting(
                archive: "Library Export.zip",
                progress: ArchiveExtractionProgress(entriesDone: 120, entries: 300, bytesDone: 1_200_000_000, bytes: 3_400_000_000)
            ),
            "Extracting “Library Export.zip”: 120 of 300 items, 1.2 GB of 3.4 GB..."
        )
        XCTAssertEqual(
            ImportProgressWording.extracting(
                archive: "Library Export.zip",
                progress: ArchiveExtractionProgress(entriesDone: 0, entries: 300, bytesDone: 0, bytes: 45_000_000)
            ),
            "Extracting “Library Export.zip”: 0 of 300 items, 0 bytes of 45 MB..."
        )
        XCTAssertEqual(
            ImportProgressWording.extracting(
                archive: "Folders.zip",
                progress: ArchiveExtractionProgress(entriesDone: 2, entries: 3, bytesDone: 0, bytes: 0)
            ),
            "Extracting “Folders.zip”: 2 of 3 items..."
        )
        XCTAssertEqual(
            ImportProgressWording.extracted(ArchiveExtractionProgress(entriesDone: 120, entries: 300, bytesDone: 1_200_000_000, bytes: 3_400_000_000)),
            "120 of 300 items, 1.2 GB of 3.4 GB",
            "the counts a batch's line and a one-book archive's line share"
        )
        XCTAssertEqual(ImportProgressWording.extracted(ArchiveExtractionProgress(entriesDone: 2, entries: 3, bytesDone: 0, bytes: 0)), "2 of 3 items")
        XCTAssertEqual(ImportProgressWording.size(999), ArchiveFigures.size(999), "sizes read as the archive messages write them")
        XCTAssertEqual(ImportProgressWording.size(1_200_000_000), ArchiveFigures.size(1_200_000_000))
    }

    // MARK: - What VoiceOver Reads

    /// VoiceOver reads the title, then each line shown as a sentence: a line
    /// that ends in a period or an ellipsis keeps it, and an empty line is
    /// left out; with no line, the title alone.
    func testSpokenStatusReadsTheTitleThenEachLine() {
        XCTAssertEqual(
            ImportProgressWording.spokenStatus([
                "2 of 100 books processed",
                "Book 3 of 100: “Moby Dick.epub”, reading its text"
            ]),
            "Importing Books: 2 of 100 books processed. Book 3 of 100: “Moby Dick.epub”, reading its text."
        )
        XCTAssertEqual(
            ImportProgressWording.spokenStatus(["Extracting “Library Export.zip”: 37 of 120 items..."]),
            "Importing Books: Extracting “Library Export.zip”: 37 of 120 items..."
        )
        XCTAssertEqual(ImportProgressWording.spokenStatus(["", ""]), "Importing Books")
        XCTAssertEqual(ImportProgressWording.spokenStatus([]), "Importing Books")
    }

    // MARK: - What VoiceOver Hears Unasked

    /// A quarter is announced with the archive's name, the books processed,
    /// and the time left when there is an estimate. A batch's end says what
    /// came of it, with only the counts that are not 0, or, when it brought
    /// no new book and lost none, what it found; one book's end, and a
    /// failure, name it.
    func testAnnouncementsSayWhatCameOfTheImport() {
        XCTAssertEqual(
            ImportProgressWording.quarter(of: "Library Export.zip", done: 25, total: 100, secondsLeft: 250),
            "Importing “Library Export.zip”: 25 of 100 books processed, about 4 minutes left."
        )
        XCTAssertEqual(
            ImportProgressWording.quarter(of: "Library Export.zip", done: 50, total: 100, secondsLeft: 30),
            "Importing “Library Export.zip”: 50 of 100 books processed, less than a minute left."
        )
        XCTAssertEqual(
            ImportProgressWording.quarter(of: "Library Export.zip", done: 1, total: 3, secondsLeft: nil),
            "Importing “Library Export.zip”: 1 of 3 books processed."
        )
        XCTAssertEqual(
            ImportProgressWording.finished(batch: "Library Export.zip", imported: 97, skippedDuplicates: 2, failed: 1),
            "Finished importing “Library Export.zip”: 97 books imported, 2 skipped as duplicates, 1 failed."
        )
        XCTAssertEqual(
            ImportProgressWording.finished(batch: "Shelf.zip", imported: 1, skippedDuplicates: 1, failed: 0),
            "Finished importing “Shelf.zip”: 1 book imported, 1 skipped as a duplicate."
        )
        XCTAssertEqual(
            ImportProgressWording.finished(batch: "Shelf.zip", imported: 0, skippedDuplicates: 2, failed: 1),
            "Finished importing “Shelf.zip”: 0 books imported, 2 skipped as duplicates, 1 failed."
        )
        // A batch that brought no new book and lost none says what it found.
        XCTAssertEqual(
            ImportProgressWording.finished(batch: "Shelf.zip", imported: 0, skippedDuplicates: 3, failed: 0),
            ImportProgressWording.noNewBooks(in: "Shelf.zip", alreadyInLibrary: 3)
        )
        XCTAssertEqual(
            ImportProgressWording.finished(batch: "Empty.zip", imported: 0, skippedDuplicates: 0, failed: 0),
            ImportProgressWording.noNewBooks(in: "Empty.zip", alreadyInLibrary: 0)
        )
        XCTAssertEqual(ImportProgressWording.finished(book: "Moby Dick.epub"), "Finished importing “Moby Dick.epub”.")
        XCTAssertEqual(ImportProgressWording.failed("Moby Dick.epub"), "Could not import “Moby Dick.epub”.")
    }

    /// A batch that found no new book says what it found: every book was
    /// already in the library, counted, both of them, or its one book, or
    /// the archive held no book TextMouth reads (FR10).
    func testABatchWithNoNewBookSaysWhatItFound() {
        XCTAssertEqual(
            ImportProgressWording.noNewBooks(in: "Library Export.zip", alreadyInLibrary: 24),
            "No new books in “Library Export.zip”: all 24 were already in your library."
        )
        XCTAssertEqual(
            ImportProgressWording.noNewBooks(in: "Library Export.zip", alreadyInLibrary: 3),
            "No new books in “Library Export.zip”: all 3 were already in your library."
        )
        XCTAssertEqual(
            ImportProgressWording.noNewBooks(in: "Pair.zip", alreadyInLibrary: 2),
            "No new books in “Pair.zip”: both were already in your library."
        )
        XCTAssertEqual(
            ImportProgressWording.noNewBooks(in: "Shelf.zip", alreadyInLibrary: 1),
            "No new books in “Shelf.zip”: its one book was already in your library."
        )
        XCTAssertEqual(
            ImportProgressWording.noNewBooks(in: "Empty.zip", alreadyInLibrary: 0),
            "No books were found in “Empty.zip”."
        )
    }
}
