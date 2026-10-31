import XCTest
@testable import TextMouth

/// A braille book read again with other braille file characters, as Book
/// Information asks for it (braillecodes, BRAILLE-CODES-RESEARCH-2026-10-25.md,
/// sections 8.3 and 8.9), through the one re-read an encoding uses too
/// (`TextEncodingRereadTests`): the text, the row, and the record after it; a
/// place, which moves with its words; the record's decision over a row that
/// lags behind it; the debug log's line; and every refusal, after which
/// nothing has changed.
///
/// The format samples are North American Braille ASCII files, so a book in
/// another code is the grade 1 sample's cells written in that code
/// (`copyOfBrailleSample(_:writtenIn:)`). Every import binds the table and
/// the code it names, never the user's settings, and every book is a package
/// in the hosted test root's library, whose index is put back after each
/// test (`CloudMaintenanceTestCase`).
@MainActor
final class BrailleFileCodeRereadTests: CloudMaintenanceTestCase {

    // MARK: - Fixtures

    /// The grade 1 BRF sample, a North American Braille ASCII file.
    private static let sample = "brf/pride-and-prejudice-ch1-grade1.brf"

    // MARK: - The Pieces

    /// Book Information offers the choice of braille file characters to a
    /// BRF or BRL braille book only: not to a PEF, named .pef or .xml, whose
    /// rows are always Unicode braille patterns, not to a feed's item, and
    /// not to a book of another format.
    func testOnlyABRFOrBRLBookIsOfferedTheChoice() {
        func book(_ fileName: String, format: BookFormat = .braille) -> Book {
            Book(title: "Ledger", format: format, filePath: "/library/Ledger.tmb/\(fileName)", md5Hash: "ledger")
        }
        XCTAssertTrue(book("Ledger.brf").offersBrailleFileCodeChoice)
        XCTAssertTrue(book("Ledger.BRL").offersBrailleFileCodeChoice)
        XCTAssertFalse(book("Ledger.pef").offersBrailleFileCodeChoice)
        XCTAssertFalse(book("Ledger.xml").offersBrailleFileCodeChoice)
        XCTAssertFalse(book("Ledger.txt", format: .txt).offersBrailleFileCodeChoice)
        var item = book("Ledger.brf")
        item.feedLink = FeedBookLink(feedID: UUID(), itemID: "item")
        XCTAssertFalse(item.offersBrailleFileCodeChoice)
    }

    /// The check a re-read makes before it writes anything reads the file's
    /// pages with the code chosen, after the size limit: the sample's Unicode
    /// copy reads in Unicode braille patterns and is refused in Eurobraille
    /// with the reader's own refusal, the blank pattern it begins with named
    /// by its code; a file past 32 MB is refused before it is read.
    func testTheCheckReadsThePagesWithTheCodeChosenAfterTheSizeLimit() throws {
        let unicode = try copyOfBrailleSample(Self.sample, writtenIn: .unicode)
        XCTAssertNoThrow(try BrailleBookReader.requireReadable(unicode, as: .unicode))
        XCTAssertThrowsError(try BrailleBookReader.requireReadable(unicode, as: .eurobraille)) {
            XCTAssertEqual($0 as? BrailleFileError, .notInFileCode(.unseenCharacter(0x2800), line: 1, characters: "Eurobraille"))
        }

        // A file one byte past the limit, all holes (a sparse file, made at once).
        let huge = try makeSandboxDirectory("BrailleFileCodeReread").appendingPathComponent("huge.brf")
        XCTAssertTrue(FileManager.default.createFile(atPath: huge.path, contents: nil))
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(BrailleBookReader.maximumFileBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try BrailleBookReader.requireReadable(huge, as: .northAmerican)) {
            XCTAssertEqual($0 as? BrailleFileError, .fileTooLarge)
        }
    }

    /// Every sentence of `BrailleFileCodeWording`, exactly, and the
    /// announcement both re-reads share, with the code's name as the reading.
    func testTheWordsOfARefusalAndOfDone() {
        XCTAssertEqual(
            BrailleFileCodeWording.notReadableRefusal(
                bookTitle: "Ledger", codeName: "Eurobraille, six-dot (German-speaking countries)",
                reason: "Line 3 holds the control character U+0007, which is not Eurobraille."
            ),
            "“Ledger” can't be read as Eurobraille, six-dot (German-speaking countries): "
                + "Line 3 holds the control character U+0007, which is not Eurobraille. Nothing was changed."
        )
        XCTAssertEqual(
            BrailleFileCodeWording.readingAgainRefusal(bookTitle: "Ledger"),
            "TextMouth is reading “Ledger” again with other braille file characters. Try again when that finishes."
        )
        XCTAssertEqual(
            TextEncodingWording.readAgainAnnouncement(
                bookTitle: "Ledger", readingDescription: BrailleFileCode.eurobraille.name, keptCopy: nil
            ),
            "“Ledger” is now read as Eurobraille, six-dot (German-speaking countries)."
        )
        XCTAssertEqual(
            TextEncodingWording.readAgainAnnouncement(bookTitle: "Ledger", readingDescription: nil, keptCopy: nil),
            "“Ledger” was read again."
        )
    }
}
