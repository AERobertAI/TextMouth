import XCTest
@testable import TextMouth

/// The library's Book Information sheet for plain text, Markdown, and HTML
/// books (`LibraryBookInfoSheet`), whose Save keeps the book titled: a title
/// of spaces alone could be saved until October 6, 2026, leaving a book the
/// library shows without a name, and the spaces typed around a title or an
/// author were kept.
@MainActor
final class LibraryBookInfoSheetTests: XCTestCase {

    /// Save has nothing to save while the title is empty or only spaces,
    /// and what it saves is the title and author without the spaces around
    /// them, on the same book.
    func testSaveKeepsATitleAndTrimsWhatWasTyped() {
        let book = Book(
            title: "Harbour Soundings",
            format: .txt,
            filePath: "/nowhere/Harbour Soundings.tmb/book.txt",
            md5Hash: "info-fixture",
            folderPath: "",
            tmbDirectoryName: "Harbour Soundings.tmb"
        )

        XCTAssertNil(LibraryBookInfoSheet.edited(book, title: "", author: "Port Authority"))
        XCTAssertNil(LibraryBookInfoSheet.edited(book, title: " \n\t", author: "Port Authority"))

        let edited = LibraryBookInfoSheet.edited(book, title: "  Tide Tables ", author: " Port Authority\n")
        XCTAssertEqual(edited?.id, book.id)
        XCTAssertEqual(edited?.title, "Tide Tables")
        XCTAssertEqual(edited?.author, "Port Authority")
        XCTAssertEqual(edited?.filePath, book.filePath, "only the title and author change")

        let unchanged = LibraryBookInfoSheet.edited(book, title: book.title, author: "")
        XCTAssertEqual(unchanged?.title, book.title)
        XCTAssertEqual(unchanged?.author, "", "an author may be left blank")
    }
}
