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

    // MARK: - Counts and Extraction

    /// The count says the books done of the total, with the overlay's noun,
    /// as the overlay's count line shows it; the extraction line counts the
    /// archive's items.
    func testTheCountAndTheExtractionLine() {
        XCTAssertEqual(ImportProgressWording.count(done: 2, of: 100), "2 of 100 books processed")
        XCTAssertEqual(ImportProgressWording.count(done: 1, of: 1), "1 of 1 books processed")
        XCTAssertEqual(CountWording.progress(3, of: 60, "books extracted"), "3 of 60 books extracted")
        XCTAssertEqual(
            ImportProgressWording.extracting(archive: "Library Export.zip", done: 37, total: 120),
            "Extracting “Library Export.zip”: 37 of 120 items..."
        )
        XCTAssertEqual(ImportProgressWording.startingArchive, "Extracting archive...")
        XCTAssertEqual(ImportProgressWording.title, "Importing Books")
        XCTAssertEqual(ImportProgressWording.itemNoun, "books processed")
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
}
