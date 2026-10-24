import XCTest
@testable import TextMouth

/// Book Information and Speak Info name the encoding a text book's file was
/// guessed to be in (FMT16): "Windows-1251 (Cyrillic), a guess". Both say it
/// from the one expression, `Book.textEncodingDescription`; a book with no
/// guess says nothing of an encoding.
@MainActor
final class TextEncodingBookInfoTests: XCTestCase {

    // MARK: - Fixtures

    /// A book of `format` whose file was guessed to be in `encoding`, nil for none.
    private func book(encoding: String?, format: BookFormat = .txt) -> Book {
        Book(
            title: "Ledger", format: format, filePath: "/nowhere/Ledger.\(format.fileExtensions[0])",
            md5Hash: "text-encoding-info-fixture", textEncoding: encoding
        )
    }

    /// The facts Speak Info makes of `book`, as the Library window makes them
    /// from the row.
    private func facts(of book: Book) -> BookInfoFacts {
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book])
        return BookInfoFacts(
            book,
            library: library,
            wordsPerMinute: 200,
            cloudStates: BookCloudStates(),
            keptBooks: KeptBooks(file: nil),
            measuresFileSize: false
        )
    }

    /// The full Speak Info summary of `book`, in a fixed calendar and locale.
    private func fullSummary(of book: Book) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return LibraryInfoWording.full(
            .book(facts(of: book)), now: book.dateAdded, calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: - The Words

    /// The description is the catalog's name for the encoding, then that it
    /// is a guess; an identifier the catalog does not know is said as it is;
    /// a book with no record, and a book of a format that has no use for an
    /// encoding, have none.
    func testTheDescriptionIsTheEncodingsNameAndThatItIsAGuess() {
        XCTAssertEqual(book(encoding: "windows-1251").textEncodingDescription, "Windows-1251 (Cyrillic), a guess")
        XCTAssertEqual(book(encoding: "koi8-r").textEncodingDescription, "KOI8-R (Russian), a guess")
        XCTAssertEqual(book(encoding: "macintosh").textEncodingDescription, "Mac Roman (Western European), a guess")
        XCTAssertEqual(book(encoding: "cp932").textEncodingDescription, "Shift JIS (Japanese), a guess")
        XCTAssertEqual(book(encoding: "x-klingon").textEncodingDescription, "x-klingon, a guess")
        XCTAssertNil(book(encoding: nil).textEncodingDescription)
        // The three formats the text decoder reads can have one; the rest cannot.
        XCTAssertNotNil(book(encoding: "windows-1251", format: .markdown).textEncodingDescription)
        XCTAssertNotNil(book(encoding: "windows-1251", format: .html).textEncodingDescription)
        XCTAssertNil(book(encoding: "windows-1251", format: .epub).textEncodingDescription)
    }

    /// The wording is pinned in one place.
    func testTheWordsAreThePinnedOnes() {
        XCTAssertEqual(TextEncodingWording.bookInfoLabel, "Read As")
        XCTAssertEqual(TextEncodingWording.guessNote, "a guess")
        XCTAssertEqual(TextEncodingWording.speakInfoPart("Windows-1251 (Cyrillic), a guess"), "Read as Windows-1251 (Cyrillic), a guess")
    }

    // MARK: - Book Information's Row

    /// Book Information's "Read As" row, which the sheet draws from
    /// `bookInfoTextEncodingRow`: its label and the description for a book
    /// whose encoding was guessed, and no row for any other. This needs no
    /// hosted sheet, whose texts SwiftUI does not always expose to a test run.
    func testTheBookInfoRowIsLabelledReadAsForAGuessedBookOnly() throws {
        let row = try XCTUnwrap(book(encoding: "windows-1251").bookInfoTextEncodingRow)
        XCTAssertEqual(row.label, "Read As")
        XCTAssertEqual(row.value, "Windows-1251 (Cyrillic), a guess")

        XCTAssertNil(book(encoding: nil).bookInfoTextEncodingRow)
        XCTAssertNil(book(encoding: "windows-1251", format: .pdf).bookInfoTextEncodingRow)
    }

    // MARK: - Speak Info

    /// The full summary of a guessed book says the encoding right after its
    /// bookmarks; the brief summary does not; a book with no guess says none.
    func testTheFullSummaryNamesTheEncodingAfterTheBookmarks() throws {
        let guessed = book(encoding: "windows-1251")
        let full = fullSummary(of: guessed)
        let sentence = "Read as Windows-1251 (Cyrillic), a guess."
        let bookmarks = try XCTUnwrap(full.range(of: "ookmark"), full)
        let encoding = try XCTUnwrap(full.range(of: sentence), full)
        XCTAssertLessThan(bookmarks.lowerBound, encoding.lowerBound, "the encoding comes after the bookmarks: \(full)")

        XCTAssertEqual(facts(of: guessed).textEncoding, "Windows-1251 (Cyrillic), a guess")
        XCTAssertFalse(LibraryInfoWording.brief(.book(facts(of: guessed))).contains("Read as"))

        XCTAssertFalse(fullSummary(of: book(encoding: nil)).contains("Read as"))
    }

    /// The encoding's part sits between the bookmarks and the parts after
    /// them (the file size, the cloud note), in `fullParts`'s own order, and
    /// after a braille book's code.
    func testThePartsPutTheEncodingAfterTheBookmarks() {
        let facts = BookInfoFacts(
            title: "Ledger", author: Book.unknownAuthor, format: "Plain Text", folderPath: "",
            progress: nil, timeRemaining: nil, isUnopened: true, dateAdded: Date(), lastOpened: nil,
            bookmarkCount: 2, fileSize: 2_000, cloudNote: "In Cloud", isKeptOnThisMac: false, isOpenInWindow: false,
            brailleCode: "Unified English Braille, contracted (Grade 2)",
            textEncoding: "Windows-1251 (Cyrillic), a guess"
        )
        let parts = LibraryInfoWording.fullParts(of: facts, now: facts.dateAdded, calendar: .current, locale: Locale(identifier: "en_US_POSIX"))
        let names = parts.filter { $0.hasPrefix("Braille code") || $0.hasPrefix("Read as") || $0.hasPrefix("File size") || $0 == "In Cloud" }
        XCTAssertEqual(names.count, 4, "\(parts)")
        XCTAssertEqual(names.first, "Braille code: Unified English Braille, contracted (Grade 2)")
        XCTAssertEqual(names.dropFirst().first, "Read as Windows-1251 (Cyrillic), a guess")
        XCTAssertTrue(names.last == "In Cloud", "\(names)")
    }
}
