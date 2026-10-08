import XCTest
@testable import TextMouth

/// The library's Book Information sheet for plain text, Markdown, and HTML
/// books (`LibraryBookInfoSheet`), whose Save keeps the book titled: a title
/// of spaces alone could be saved until October 6, 2026, leaving a book the
/// library shows without a name, and the spaces typed around a title or an
/// author were kept. What it saves is compared with what it opened with, and
/// the fields it changed are recorded as edited by hand.
@MainActor
final class LibraryBookInfoSheetTests: XCTestCase {

    /// Save has nothing to save while the title is empty or only spaces,
    /// and what it saves is the title and author without the spaces around
    /// them, beside what the sheet opened with, trimmed the same way.
    func testSaveKeepsATitleAndTrimsWhatWasTyped() {
        let book = Book(
            title: "Harbour Soundings",
            format: .txt,
            filePath: "/nowhere/Harbour Soundings.tmb/book.txt",
            md5Hash: "info-fixture",
            folderPath: "",
            tmbDirectoryName: "Harbour Soundings.tmb"
        )
        let opened = LibraryBookInfoSheet.values(title: " \(book.title)\n", author: book.author)
        XCTAssertEqual(opened, [.title: "Harbour Soundings", .author: Book.unknownAuthor])

        XCTAssertNil(LibraryBookInfoSheet.edit(from: opened, title: "", author: "Port Authority"))
        XCTAssertNil(LibraryBookInfoSheet.edit(from: opened, title: " \n\t", author: "Port Authority"))

        let edit = LibraryBookInfoSheet.edit(from: opened, title: "  Tide Tables ", author: " Port Authority\n")
        XCTAssertEqual(edit?.opened, opened)
        XCTAssertEqual(edit?.saved, [.title: "Tide Tables", .author: "Port Authority"])

        let blankAuthor = LibraryBookInfoSheet.edit(from: opened, title: book.title, author: "")
        XCTAssertEqual(blankAuthor?.changes, [.author: ""], "an author may be left blank")
    }

    /// What Save gives the library records the title and author it
    /// changed as edited by hand; a later save, from the sheet opened
    /// again, that changes only the author adds the author.
    func testSaveRecordsTheTitleAndAuthorItChanged() throws {
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        // Without a package, so the save writes no record anywhere.
        let book = Book(title: "Harbour Soundings", format: .txt, filePath: "/nowhere/Harbour Soundings.txt", md5Hash: "info-fixture")
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])

        let opened = LibraryBookInfoSheet.values(title: book.title, author: book.author)
        let retitled = try XCTUnwrap(LibraryBookInfoSheet.edit(from: opened, title: " Tide Tables ", author: book.author))
        model.updateBookMetadata(retitled, of: book.id)
        XCTAssertEqual(model.bookByID(book.id)?.title, "Tide Tables")
        XCTAssertEqual(model.bookByID(book.id)?.handEdits, Book.HandEdits(fields: [.title], sinceImport: false))

        let row = try XCTUnwrap(model.bookByID(book.id))
        let reopened = LibraryBookInfoSheet.values(title: row.title, author: row.author)
        let attributed = try XCTUnwrap(LibraryBookInfoSheet.edit(from: reopened, title: row.title, author: "Port Authority"))
        model.updateBookMetadata(attributed, of: book.id)
        XCTAssertEqual(model.bookByID(book.id)?.author, "Port Authority")
        XCTAssertEqual(model.bookByID(book.id)?.handEdits, Book.HandEdits(fields: [.title, .author], sinceImport: false))
    }

    /// The sheet's title field is labeled "Book title, edited by hand" for
    /// a book whose title the user typed, and its author field "Book
    /// author" alone, as VoiceOver reads them from the hosted sheet.
    func testTheFieldsSayWhichValuesWereEditedByHand() throws {
        var book = Book(title: "Harbour Soundings", format: .txt, filePath: "/nowhere/Harbour Soundings.txt", md5Hash: "info-fixture")
        book.markEditedByHand([.title])
        let sheet = LibraryBookInfoSheet(book: book, libraryViewModel: LibraryViewModel(initializeServices: false))

        try withHostedControls(sheet) { controls in
            let labels = controls.filter { $0.role == .textField }.map(\.label)
            XCTAssertTrue(labels.contains("Book title, edited by hand"), "\(labels)")
            XCTAssertTrue(labels.contains("Book author"), "\(labels)")
        }
    }
}
