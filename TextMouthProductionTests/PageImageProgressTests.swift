import XCTest
@testable import TextMouth

/// The pages an import reads, counted (FMT34): the overlay's words for a
/// book read page by page, and the thread's hook through which a reader
/// tells the import running on it how far it has got.
final class PageImageProgressTests: XCTestCase {

    // MARK: - The Overlay's Words

    /// Reading a book of several pages counts them, as converting tracks
    /// counts tracks; one picture needs no count, and the step is named as
    /// reading the text is, which a failure meanwhile is.
    func testTheOverlayCountsThePagesRead() {
        XCTAssertEqual(ImportProgressWording.step(.readingPages(done: 3, of: 12)), "reading its text: 3 of 12 pages")
        XCTAssertEqual(ImportProgressWording.step(.readingPages(done: 0, of: 2)), "reading its text: 0 of 2 pages")
        XCTAssertEqual(ImportProgressWording.step(.readingPages(done: 1, of: 1)), "reading its text")
        XCTAssertEqual(ImportStep.readingPages(done: 3, of: 12).activity, ImportStep.readingText.activity)
        XCTAssertEqual(
            ImportProgressWording.book("Harbour Notices.cbz", step: .readingPages(done: 1, of: 2)),
            "“Harbour Notices.cbz”, reading its text: 1 of 2 pages"
        )
        XCTAssertEqual(
            ImportProgressWording.book("Harbour Notices.cbz", number: 3, of: 10, step: .readingPages(done: 4, of: 30)),
            "Book 3 of 10: “Harbour Notices.cbz”, reading its text: 4 of 30 pages"
        )
        XCTAssertEqual(ImportProgressWording.pages(done: 0, of: 1), "0 of 1 page")
    }

    // MARK: - The Hook

    /// A reading tells whoever its thread's import set to listen, the
    /// innermost first, and the one before is listening again afterwards;
    /// outside an import it tells nobody, and nothing fails.
    func testTheThreadsListenerHearsThePagesRead() throws {
        var outer: [String] = []
        var inner: [String] = []

        try ImportPageProgress.pagesRead(1, of: 1)
        try ImportPageProgress.reporting(to: { outer.append("\($0)/\($1)") }) {
            try ImportPageProgress.pagesRead(0, of: 2)
            try ImportPageProgress.reporting(to: { inner.append("\($0)/\($1)") }) {
                try ImportPageProgress.pagesRead(1, of: 5)
            }
            try ImportPageProgress.pagesRead(2, of: 2)
        }
        try ImportPageProgress.pagesRead(3, of: 3)

        XCTAssertEqual(outer, ["0/2", "2/2"])
        XCTAssertEqual(inner, ["1/5"])
    }

    /// What the listener throws stops the reading that told it, and the
    /// listener is taken away all the same.
    func testWhatTheListenerThrowsStopsTheReading() {
        struct Stop: Error {}

        XCTAssertThrowsError(try ImportPageProgress.reporting(to: { _, _ in throw Stop() }) {
            try ImportPageProgress.pagesRead(0, of: 1)
        }) { error in
            XCTAssertTrue(error is Stop, "\(error)")
        }
        XCTAssertNoThrow(try ImportPageProgress.pagesRead(1, of: 1), "no listener is left behind")
    }
}
