import XCTest
@testable import TextMouth

/// Every saved place of a text book takes the words around it as it is
/// saved (T06's branch B): the reading position at each save, a bookmark as
/// either add makes it, and a skipped heading as it is toggled, each in the
/// book's row and its record. The skipped headings themselves are what is
/// saved, and their IDs are written from them.
///
/// Each book is an EPUB imported as a user imports one, into a library
/// folder of the test's own, and opened in a real reader that loads it
/// through its own background loader; nothing is spoken.
@MainActor
final class TextAnchorCaptureTests: XCTestCase {

    // MARK: - Skipped Headings

    /// The library saves skipped headings as they are given, with their IDs
    /// written from them; a heading given without its text keeps the text
    /// the row already holds for the same heading, as a reader whose copy
    /// of the book predates a capture would give it, and the record takes
    /// the same.
    func testAHeadingSavedWithoutItsTextKeepsTheTextTheRowHolds() throws {
        let world = try makeIntegrationWorld("Anchor Capture Skip Save")
        let book = try world.importBook(from: writeOrchardEPUB())
        let pruning = SkippedHeading(level: 1, label: "Pruning in Frost", chapterIndex: 1, characterOffset: 0)
        let pressing = SkippedHeading(level: 1, label: "The Cider Press", chapterIndex: 2, characterOffset: 0)
        var anchoredPruning = pruning
        anchoredPruning.anchor = TextAnchor(before: "", after: "Pruning in Frost", fraction: 0.3, measuredIn: "3.0.7/1.0.0")
        world.library.updateSkippedHeadings(bookID: book.id, headings: [anchoredPruning])

        world.library.updateSkippedHeadings(bookID: book.id, headings: [pruning, pressing])

        let row = try XCTUnwrap(world.library.bookByID(book.id))
        XCTAssertEqual(row.skippedHeadings, [anchoredPruning, pressing])
        XCTAssertEqual(row.skippedHeadingIDs, [pruning.id, pressing.id])
        LibraryPersistenceService.flushPendingSave()
        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.state.skippedHeadings, [anchoredPruning, pressing])
        XCTAssertEqual(record.state.skippedHeadingIDs, [pruning.id, pressing.id])

        world.library.updateSkippedHeadings(bookID: book.id, headings: [])
        XCTAssertNil(world.library.bookByID(book.id)?.skippedHeadings)
        XCTAssertNil(world.library.bookByID(book.id)?.skippedHeadingIDs)
    }

    // MARK: - Fixture

    /// The three chapters of the orchard book: each heading, and the
    /// paragraphs under it.
    private static let orchardChapters: [(heading: String, paragraphs: [String])] = [
        ("Grafting the Old Trees", [
            "A scion cut in late winter keeps its buds closed until the stock beneath it wakes, so the cuts are wrapped in waxed cloth and left alone for six weeks.",
            "Thessaly Amundsen kept a ledger of every graft she made along the north wall, and the ledger says that forty of the fifty-two took in a wet spring.",
        ]),
        ("Pruning in Frost", [
            "Branches pruned on a frozen morning split along the grain, which is why the crew waits for the sun to reach the lower terraces before the saws come out.",
            "A tree that loses more than a third of its wood in one season answers with a thicket of water shoots, each one thin, upright, and useless for fruit.",
        ]),
        ("The Cider Press", [
            "The press in the long barn takes two hundredweight of milled apples at a time, stacked in cloths between slatted boards and squeezed by a screw of oak.",
            "Juice from the first pressing goes into the cool cellar the same evening, and the pomace is carted to the pigs before it can sour in the yard.",
        ]),
    ]

    /// The orchard book as an EPUB in a folder of this test's own: three
    /// chapters, each listed in the table of contents under its heading.
    private func writeOrchardEPUB() throws -> URL {
        let epub = try makeSandboxDirectory("AnchorCaptureSources").appendingPathComponent("orchard.epub")
        let chapters = Self.orchardChapters
        try IntegrationEPUB.write(
            title: "Orchard Ledger",
            chapters: chapters.enumerated().map { number, chapter in
                IntegrationEPUBChapter(
                    fileName: "ch0\(number + 1).xhtml",
                    body: "<h1>\(chapter.heading)</h1>" + chapter.paragraphs.map { "<p>\($0)</p>" }.joined()
                )
            },
            contents: chapters.enumerated().map { number, chapter in
                IntegrationTOCEntry(label: chapter.heading, target: "ch0\(number + 1).xhtml")
            },
            to: epub
        )
        return epub
    }
}
