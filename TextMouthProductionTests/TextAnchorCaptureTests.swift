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

    // MARK: - Where a Saved Place Opens (Question 7)

    /// A saved place opens where the loaded text holds it; one the text
    /// does not hold opens nearby: an offset past its chapter's end at that
    /// end (the book's end in the last chapter), one before its start at its
    /// start, a chapter before the first at the book's start, and a chapter
    /// past the last at the book's end when the place was at or past the
    /// book's end by its offset in the whole book, else at the last
    /// chapter's start. Pure: no window.
    func testASavedPlaceOpensWithinTheBook() {
        let content = DocumentContent(
            title: "Breakwater Survey",
            author: "Odalys Pretorius",
            chapters: [
                Chapter(title: "Piles", text: String(repeating: "pile ", count: 20)),
                Chapter(title: "Stones", text: String(repeating: "stone ", count: 30)),
            ]
        )
        let first = 100
        let total = 280
        XCTAssertEqual(content.totalCharacterCount, total)
        func opening(_ chapter: Int, _ offset: Int, global: Int? = nil) -> TextPlace {
            ReaderViewModel.openingPlace(of: TextPlace(chapter: chapter, offset: offset), savedGlobalOffset: global, in: content)
        }

        XCTAssertEqual(opening(0, 37), TextPlace(chapter: 0, offset: 37), "a place the text holds moved")
        XCTAssertEqual(opening(1, 180, global: total + 40), TextPlace(chapter: 1, offset: 180), "a held place moved by its global offset")
        XCTAssertEqual(opening(0, first + 9), TextPlace(chapter: 0, offset: first), "past a chapter's end")
        XCTAssertEqual(opening(1, 400, global: 500), TextPlace(chapter: 1, offset: 180), "past the book's end")
        XCTAssertEqual(opening(1, -3), TextPlace(chapter: 1, offset: 0), "before a chapter's start")
        XCTAssertEqual(opening(-1, 50), TextPlace(chapter: 0, offset: 0), "a chapter before the first")
        XCTAssertEqual(opening(4, 10, global: total), TextPlace(chapter: 1, offset: 180), "a finished book's lost chapter")
        XCTAssertEqual(opening(4, 10, global: total - 1), TextPlace(chapter: 1, offset: 0), "a lost chapter short of the end")
        XCTAssertEqual(opening(4, 10), TextPlace(chapter: 1, offset: 0), "a lost chapter with no global offset")
        let empty = DocumentContent(title: "Blank", author: "", chapters: [])
        XCTAssertEqual(
            ReaderViewModel.openingPlace(of: TextPlace(chapter: 2, offset: 9), savedGlobalOffset: 9, in: empty),
            TextPlace(chapter: 0, offset: 0)
        )
    }

    /// A finished one-chapter book whose text then loses its last
    /// character, as a new text extraction or an edit trimming its end
    /// leaves it, opens at its new end, finished, and is saved there, so
    /// its row and its record read Finished still (REV14; board #2028). It
    /// used to open at its start and be saved there.
    func testAFinishedBookWhoseTextLosesItsLastCharacterOpensFinished() throws {
        let world = try makeIntegrationWorld("Anchor Capture Shortened End")
        let book = try world.importBook(from: writeSource(named: "Pier Notices.txt", Self.pierNotices))
        XCTAssertNotNil(book.textCacheFingerprint, "the import recorded no fingerprints, so a changed file would go unnoticed")
        let first = world.openReader(for: book)
        waitForReaderToLoad(first)
        XCTAssertEqual(first.content?.chapters.count, 1, "the fixture is not one chapter")
        let length = try XCTUnwrap(first.content?.chapters.first?.text.utf16Length)
        first.restAtEnd()
        first.close()
        XCTAssertTrue(world.library.bookByID(book.id)?.restsAtEnd ?? false, "the book was not saved at its end")

        // The book's own file loses its last character, and the next open
        // reads the shorter text, rebuilding the cache it no longer matches.
        let trimmed = String(Self.pierNotices.dropLast())
        try Data(trimmed.utf8).write(to: book.bookFileURL)
        let reopened = world.openReader(for: try XCTUnwrap(world.library.bookByID(book.id)))
        waitForReaderToLoad(reopened)

        let shortened = try XCTUnwrap(reopened.content?.chapters.first?.text.utf16Length)
        XCTAssertLessThan(shortened, length, "the text did not shorten")
        XCTAssertEqual(reopened.currentChapterIndex, 0)
        XCTAssertEqual(reopened.currentCharacterOffset, shortened, "the book did not open at its end")
        XCTAssertTrue(reopened.hasFinishedBook, "the book did not open finished")
        let row = try XCTUnwrap(world.library.bookByID(book.id))
        XCTAssertEqual(row.readingPosition?.characterOffset, shortened)
        XCTAssertEqual(row.readingPosition?.globalCharacterOffset, shortened)
        XCTAssertTrue(row.restsAtEnd, "the row no longer reads Finished")
        LibraryPersistenceService.flushPendingSave()
        let recorded = try XCTUnwrap(BookInfo.load(from: book.tmbDirectory).state.readingPosition)
        XCTAssertEqual(recorded.characterOffset, shortened, "the record holds another place")
    }

    /// A place saved past a chapter's end opens at that end: past a middle
    /// chapter's end, at that end, not finished; past the last chapter's
    /// end, at the book's end, finished, as three of the user's books were
    /// saved (T06's design note found them at offsets 534 of 530, 445 of
    /// 194, and 2,786 of 2,782). Each is saved where it opened.
    func testAPlacePastItsChaptersEndOpensAtThatEnd() throws {
        let world = try makeIntegrationWorld("Anchor Capture Chapter End")
        let book = try world.importBook(from: writeOrchardEPUB())
        let content = try MarkdownCacheService.loadFromCache(for: book)
        let lengths = content.chapters.map(\.text.utf16Length)
        XCTAssertEqual(lengths.count, 3, "the fixture is not three chapters")
        guard lengths.count == 3 else { return }

        world.library.persistReadingPosition(
            bookID: book.id,
            position: ReadingPosition(chapterIndex: 0, characterOffset: lengths[0] + 12, globalCharacterOffset: lengths[0] + 12)
        )
        let middle = world.openReader(for: try XCTUnwrap(world.library.bookByID(book.id)))
        waitForReaderToLoad(middle)
        XCTAssertEqual(middle.currentChapterIndex, 0)
        XCTAssertEqual(middle.currentCharacterOffset, lengths[0], "a place past a middle chapter's end did not open at that end")
        XCTAssertFalse(middle.hasFinishedBook, "a place in the middle of the book opened finished")
        XCTAssertEqual(world.library.bookByID(book.id)?.readingPosition?.characterOffset, lengths[0])
        middle.close()

        let total = lengths.reduce(0, +)
        world.library.persistReadingPosition(
            bookID: book.id,
            position: ReadingPosition(chapterIndex: 2, characterOffset: lengths[2] + 4, globalCharacterOffset: total + 4)
        )
        let last = world.openReader(for: try XCTUnwrap(world.library.bookByID(book.id)))
        waitForReaderToLoad(last)
        XCTAssertEqual(last.currentChapterIndex, 2)
        XCTAssertEqual(last.currentCharacterOffset, lengths[2], "a place past the last chapter's end did not open at the book's end")
        XCTAssertTrue(last.hasFinishedBook, "a place past the book's end did not open finished")
        XCTAssertTrue(world.library.bookByID(book.id)?.restsAtEnd ?? false, "the row does not read Finished")
    }

    // MARK: - Fixture

    /// A one-chapter text book about a pier's notices, ending in a full
    /// stop: two paragraphs and nothing a parser could take for a chapter.
    private static let pierNotices = """
        The harbour office pins the week's tide tables beside the gangway every Monday, \
        and the ferry crews copy the low waters into their logbooks before the first sailing.

        A notice about the dredger working the inner basin stays up until the channel buoys \
        are moved back to their summer marks.
        """

    /// Writes `text` to a file named `name` in a folder of this test's own,
    /// for an import to read.
    private func writeSource(named name: String, _ text: String) throws -> URL {
        let source = try makeSandboxDirectory("AnchorCaptureSources").appendingPathComponent(name)
        try Data(text.utf8).write(to: source)
        return source
    }

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
        let epub = try makeSandboxDirectory("AnchorCaptureEPUB").appendingPathComponent("orchard.epub")
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
