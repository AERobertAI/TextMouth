import XCTest
@testable import TextMouth

/// Book Information and Speak Info name a braille book's code (FMT21): the
/// description of the table the book was imported with, such as "Unified
/// English Braille, contracted (Grade 2)". Both say it from the one
/// expression, `Book.brailleCodeDescription`; a book that is not braille
/// says nothing of braille.
@MainActor
final class BrailleBookInfoTests: XCTestCase {

    // MARK: - Fixtures

    /// A braille book read with `table`, nil for none.
    private func brailleBook(table: String?) -> Book {
        Book(
            title: "Short Sentences", format: .braille,
            filePath: "/nowhere/Short Sentences.brf", md5Hash: "braille-info-fixture",
            brailleTable: table
        )
    }

    /// An EPUB, which has no braille code.
    private func epubBook() -> Book {
        Book(title: "Ferry Timetable", format: .epub, filePath: "/nowhere/Ferry Timetable.epub", md5Hash: "epub-info-fixture")
    }

    /// The full Speak Info summary of `book`, as the Library window makes it
    /// (`BookInfoFacts` from the row), in a fixed calendar and locale.
    private func fullSummary(of book: Book) -> String {
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book])
        let facts = BookInfoFacts(
            book,
            library: library,
            wordsPerMinute: 200,
            cloudStates: BookCloudStates(),
            keptBooks: KeptBooks(file: nil),
            measuresFileSize: false
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return LibraryInfoWording.full(
            .book(facts), now: book.dateAdded, calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: - The code

    /// A table's description is its code and how far it contracts; a book
    /// with no table reads with the default's; a book that is not braille
    /// has none.
    func testTheCodeIsTheDescriptionOfTheBooksTable() {
        XCTAssertEqual(
            brailleBook(table: "en-ueb-g2.ctb").brailleCodeDescription, "Unified English Braille, contracted (Grade 2)")
        XCTAssertEqual(
            brailleBook(table: "en-us-g1.ctb").brailleCodeDescription,
            "English Braille, American Edition, uncontracted (Grade 1)")
        XCTAssertEqual(
            brailleBook(table: nil).brailleCodeDescription,
            BrailleTableCatalog.description(ofTableID: BrailleTableCatalog.defaultTableID))
        XCTAssertEqual(brailleBook(table: nil).brailleCodeDescription, "Unified English Braille, contracted (Grade 2)")
        XCTAssertNil(epubBook().brailleCodeDescription)
        // A table field on a book that is not braille is not a code.
        var stray = epubBook()
        stray.brailleTable = "en-ueb-g2.ctb"
        XCTAssertNil(stray.brailleCodeDescription)
    }

    // MARK: - Book Information's Row

    /// The words of Book Information's "Braille Code" row, which the sheet
    /// draws from `bookInfoBrailleCodeRow`: its label and the code for a
    /// braille book (the default table's when it has none of its own), and no
    /// row for an EPUB. This needs no hosted sheet, whose texts SwiftUI does
    /// not always expose to a test run.
    func testTheBookInfoRowIsLabelledBrailleCodeForABrailleBookOnly() throws {
        XCTAssertEqual(BrailleCodeWording.bookInfoLabel, "Braille Code")

        let row = try XCTUnwrap(brailleBook(table: "en-ueb-g2.ctb").bookInfoBrailleCodeRow)
        XCTAssertEqual(row.label, "Braille Code")
        XCTAssertEqual(row.value, "Unified English Braille, contracted (Grade 2)")

        let uncontracted = try XCTUnwrap(brailleBook(table: "en-us-g1.ctb").bookInfoBrailleCodeRow)
        XCTAssertEqual(uncontracted.value, "English Braille, American Edition, uncontracted (Grade 1)")

        let untabled = try XCTUnwrap(brailleBook(table: nil).bookInfoBrailleCodeRow)
        XCTAssertEqual(untabled.value, "Unified English Braille, contracted (Grade 2)")

        XCTAssertNil(epubBook().bookInfoBrailleCodeRow)
    }

    // MARK: - Speak Info

    /// The full summary of a braille book says its code right after the
    /// bookmarks; an EPUB's has no braille part; the brief summary says the
    /// format, Braille, and no code.
    func testTheFullSummaryNamesTheCodeAfterTheBookmarks() throws {
        var book = brailleBook(table: "en-ueb-g2.ctb")
        book.bookmarks = []
        let full = fullSummary(of: book)
        let code = "Braille code: Unified English Braille, contracted (Grade 2)"
        let bookmarks = try XCTUnwrap(full.range(of: "ookmark"), full)
        let codeRange = try XCTUnwrap(full.range(of: code), full)
        XCTAssertLessThan(bookmarks.lowerBound, codeRange.lowerBound, "the code comes after the bookmarks: \(full)")
        XCTAssertTrue(full.hasPrefix("Short Sentences. Braille."), full)

        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book])
        let facts = BookInfoFacts(
            book, library: library, wordsPerMinute: 200, cloudStates: BookCloudStates(),
            keptBooks: KeptBooks(file: nil), measuresFileSize: false)
        XCTAssertEqual(facts.brailleCode, "Unified English Braille, contracted (Grade 2)")
        XCTAssertFalse(LibraryInfoWording.brief(.book(facts)).contains("Braille code"))

        XCTAssertFalse(fullSummary(of: epubBook()).contains("Braille code"))
    }

    /// A book of one of this Mac's tables is named by its code, how far it
    /// contracts, and its language (October 20, 2026, decision 8), in Book
    /// Information's row and in Speak Info, from the one expression both use.
    func testAMacTableIsNamedWithItsLanguage() throws {
        try XCTSkipIf(BrailleTableCatalog.table(withID: "mac:fr-bfu-g2.ctb") == nil,
                      "This Mac does not offer its French contracted table (\(BrailleTableCatalog.macTablesFolder.path))")
        let language = Locale.current.localizedString(forIdentifier: "fr") ?? "fr"
        let words = "French braille, contracted (Grade 2), in \(language)"
        let book = brailleBook(table: "mac:fr-bfu-g2.ctb")
        XCTAssertEqual(book.brailleCodeDescription, words)
        XCTAssertEqual(book.bookInfoBrailleCodeRow?.value, words)
        XCTAssertTrue(fullSummary(of: book).contains("Braille code: \(words)."), fullSummary(of: book))
    }

    /// The braille part sits between the bookmarks and the parts after them
    /// (the file size, the cloud note), in `fullParts`'s own order.
    func testThePartsPutTheCodeAfterTheBookmarks() throws {
        let facts = BookInfoFacts(
            title: "Short Sentences", author: Book.unknownAuthor, format: "Braille", folderPath: "",
            progress: nil, timeRemaining: nil, isUnopened: true, dateAdded: Date(), lastOpened: nil,
            bookmarkCount: 2, fileSize: 2_000, cloudNote: "In Cloud", isKeptOnThisMac: false, isOpenInWindow: false,
            brailleCode: "Unified English Braille, contracted (Grade 2)"
        )
        let parts = LibraryInfoWording.fullParts(of: facts, now: Date(), calendar: .current, locale: Locale(identifier: "en_US"))
        let bookmarks = try XCTUnwrap(parts.firstIndex(of: "2 bookmarks"))
        XCTAssertEqual(parts.count > bookmarks + 3, true, "\(parts)")
        guard parts.count > bookmarks + 3 else { return }
        XCTAssertEqual(parts[bookmarks + 1], "Braille code: Unified English Braille, contracted (Grade 2)")
        XCTAssertTrue(parts[bookmarks + 2].hasPrefix("File size"))
        XCTAssertEqual(parts[bookmarks + 3], "In Cloud")
    }

    // MARK: - Book Information

    /// Every text the hosted sheet exposes to accessibility, labels and
    /// values together.
    private func texts(of book: Book) throws -> [String] {
        let sheet = LibraryBookInfoSheet(book: book, libraryViewModel: LibraryViewModel(initializeServices: false))
        var found: [String] = []
        try withHostedControls(sheet) { controls in
            found = controls.flatMap { [$0.label, $0.valueDescription] }
        }
        return found
    }

    /// The sheet has a "Braille Code" row with the description for a braille
    /// book, and none for an EPUB. SwiftUI builds the elements of its own
    /// texts only for a connected assistive app; where the sheet's Format row
    /// is not exposed either, the check is skipped, as the sheet's other
    /// hosted checks are.
    func testTheSheetHasABrailleCodeRowForABrailleBookOnly() throws {
        try skipUnlessSwiftUIExposesItsOwnElements()
        let braille = try texts(of: brailleBook(table: "en-ueb-g2.ctb"))
        guard braille.contains(where: { $0.contains("Format") }) else {
            throw XCTSkip("SwiftUI exposed no row of the sheet to accessibility in this run")
        }
        XCTAssertTrue(braille.contains { $0.contains("Braille Code") }, "\(braille)")
        XCTAssertTrue(braille.contains { $0.contains("Unified English Braille, contracted (Grade 2)") }, "\(braille)")

        let epub = try texts(of: epubBook())
        XCTAssertTrue(epub.contains { $0.contains("Format") }, "\(epub)")
        XCTAssertFalse(epub.contains { $0.contains("Braille Code") }, "\(epub)")
    }
}
