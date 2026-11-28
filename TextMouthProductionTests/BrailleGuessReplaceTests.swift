import XCTest
@testable import TextMouth

// MARK: - Replace Existing and Who Chose a Braille Book's Table (brfguess)

/// Replace Existing keeps who chose the table of the braille book it replaces
/// (`DuplicateReplacement.brailleTableOrigin(replacing:with:)`): a copy of the
/// same bytes that ends with the old copy's table takes the old copy's origin,
/// nil included, so a guess the listener kept does not come back, a guess made
/// while the guess was on is not shown as the listener's choice when the guess
/// has been switched off since, and a plain guess stays a guess. A different
/// file keeps the guess of its own reading. Every text is invented
/// (`BrailleGuessFixtures`), and every import binds the table, the file
/// characters, and the guess it names, never the user's settings.
@MainActor
final class BrailleGuessReplaceTests: CloudMaintenanceTestCase {

    // MARK: Fixtures

    /// Contracted UEB, the table the Braille setting names here.
    private static let grade2 = "en-ueb-g2.ctb"
    /// The bundled contracted EBAE table, the guess.
    private static let ebae = BrailleTableGuess.ebaeTableID

    /// A BRF of invented EBAE prose, long enough to be clearly EBAE, in a
    /// folder of its own; `extraRows` makes a different file of it (other
    /// bytes, as clearly EBAE).
    private func ebaeFile(named name: String = "Ledger Book.brf", extraRows: [String] = []) throws -> URL {
        let url = try makeSandboxDirectory("BrailleGuessReplace").appendingPathComponent(name)
        let rows = Array((0..<2).map { _ in BrailleGuessFixtures.ebaeProse }.joined()) + extraRows
        try Data(rows.joined(separator: "\r\n").utf8).write(to: url)
        return url
    }

    /// `url` imported with the Braille setting's table `grade2` and the guess
    /// `guessing`.
    private func imported(_ url: URL, guessing: Bool = true) throws -> Book {
        try BraillePreferences.$tableForImports.withValue(Self.grade2) {
            try BraillePreferences.$fileCodeForImports.withValue("ascii-na") {
                try BraillePreferences.$guessesTableForImports.withValue(guessing) {
                    try importedForTest(url).book
                }
            }
        }
    }

    /// Adds `copy` to `model` as a duplicate of `existing` and answers Replace
    /// Existing; returns the row that took the old book's place, which must
    /// hold the copy.
    private func replace(_ existing: Book, with copy: Book, in model: LibraryViewModel) throws -> Book {
        XCTAssertEqual(copy.md5Hash, existing.md5Hash, "the same file must have the same content hash, or this proves nothing")
        XCTAssertFalse(model.addBookCheckingDuplicate(copy), "the copy was not asked about as a duplicate")
        XCTAssertEqual(model.answerCurrentImportDecision(.replaceExisting), .success(nil))
        let row = try XCTUnwrap(model.bookByID(existing.id))
        XCTAssertEqual(row.tmbDirectoryName, copy.tmbDirectoryName, "the copy did not take the book's place")
        return row
    }

    /// The braille table and its origin the package record of `book` holds,
    /// read after every queued write.
    private func record(of book: Book) throws -> (table: String?, origin: BrailleTableOrigin?) {
        UnsavedChangesTerminationGuard.flushPendingWrites()
        let metadata = try BookInfo.load(from: book.tmbDirectory).metadata
        return (metadata.brailleTable, metadata.brailleTableOrigin)
    }

    // MARK: Cases

    /// The plain case: the guess is still on, the copy is guessed again, the
    /// tables match, and the book stays guessed, in its row and its record.
    func testAGuessedBookReplacedByTheSameFileStaysGuessed() throws {
        keepDeletionsOutOfTheTrash()
        let file = try ebaeFile()
        let existing = try imported(file)
        let copy = try imported(file)
        XCTAssertEqual(copy.brailleTableOrigin, .guessed)

        let row = try replace(existing, with: copy, in: makeModel(with: [existing]))

        XCTAssertEqual(row.brailleTable, Self.ebae)
        XCTAssertEqual(row.brailleTableOrigin, .guessed)
        let recorded = try record(of: row)
        XCTAssertEqual(recorded.table, Self.ebae)
        XCTAssertEqual(recorded.origin, .guessed)
    }

    /// (a) The guess is switched off after the first import: the copy is read
    /// with the setting's UEB table, then read again with the old copy's EBAE
    /// table, which records no origin; the book is still the guess it was.
    func testAGuessStaysAGuessWhenTheSettingIsSwitchedOffBeforeTheReplacement() throws {
        keepDeletionsOutOfTheTrash()
        let file = try ebaeFile()
        let existing = try imported(file)
        let copy = try imported(file, guessing: false)
        XCTAssertEqual(copy.brailleTable, Self.grade2)
        XCTAssertNil(copy.brailleTableOrigin)

        let row = try replace(existing, with: copy, in: makeModel(with: [existing]))

        XCTAssertEqual(row.brailleTable, Self.ebae, "the copy was not read again with the old copy's table")
        XCTAssertEqual(row.brailleTableOrigin, .guessed)
        let recorded = try record(of: row)
        XCTAssertEqual(recorded.table, Self.ebae)
        XCTAssertEqual(recorded.origin, .guessed)
    }

    /// (b) The listener pressed Keep This Code: the guess is their word now,
    /// and the copy's fresh guess of the same table must not say "guessed".
    func testAKeptGuessIsNotGuessedAgainByTheReplacement() async throws {
        keepDeletionsOutOfTheTrash()
        let file = try ebaeFile()
        let first = try imported(file)
        let library = makeModel(with: [first])
        let choice = BrailleCodeChoiceModel(book: first, library: library)
        await choice.load()
        await choice.choose(.table(Self.ebae))
        let existing = try XCTUnwrap(library.bookByID(first.id))
        XCTAssertNil(existing.brailleTableOrigin, "the guess was not kept, or this proves nothing")
        let copy = try imported(file)
        XCTAssertEqual(copy.brailleTableOrigin, .guessed)

        let row = try replace(existing, with: copy, in: library)

        XCTAssertEqual(row.brailleTable, Self.ebae)
        XCTAssertNil(row.brailleTableOrigin)
        let recorded = try record(of: row)
        XCTAssertEqual(recorded.table, Self.ebae)
        XCTAssertNil(recorded.origin, "the record still says guessed")
    }

    /// A different file is not the old copy's: it keeps the guess of its own
    /// reading, whatever the old copy's origin, and its own absence of one.
    /// Different files are not duplicates of each other, so the book is put
    /// together directly (`DuplicateReplacement.carriedBook`), where the rule sits.
    func testADifferentFileKeepsItsOwnGuess() throws {
        let existing = try imported(try ebaeFile())
        let other = try ebaeFile(named: "Another Ledger.brf", extraRows: BrailleGuessFixtures.ebaeProse)
        let guessedCopy = try imported(other)
        let plainCopy = try imported(other, guessing: false)
        XCTAssertNotEqual(guessedCopy.md5Hash, existing.md5Hash, "the files must differ, or this proves nothing")
        XCTAssertEqual(existing.brailleTableOrigin, .guessed)
        XCTAssertEqual(guessedCopy.brailleTableOrigin, .guessed)
        XCTAssertNil(plainCopy.brailleTableOrigin)

        for copy in [guessedCopy, plainCopy] {
            let carried = DuplicateReplacement.carriedBook(
                replacing: existing, with: copy, places: existing.relocatablePlaces, location: copy.fileLocation
            )
            XCTAssertEqual(carried.brailleTable, copy.brailleTable)
            XCTAssertEqual(carried.brailleTableOrigin, copy.brailleTableOrigin)
        }
    }
}
