import XCTest
@testable import TextMouth

/// Reader loading at the real boundary (TODO Q04; repair T01): a book
/// imported as a user imports it, whose saved content index is then
/// damaged on disk, is opened in a reader, which loads it through its own
/// background loader.
@MainActor
final class IntegrationReaderLoadingTests: XCTestCase {
    /// The content index saved in a book's bookInfo.json has lost its
    /// chapter list while keeping its version and format, the only things
    /// that used to be checked. Opening the book sets the index aside,
    /// indexes the cached text again, and the reader shows the book as it
    /// is: all three chapters, the first heading "Semaphore Towers", and
    /// "Heading 1 of 3" at the start. The rebuilt index is saved, so the
    /// next open has a sound one.
    ///
    /// Before the repair, a saved index was trusted when its version and
    /// format matched, and its chapters supply the reader's heading list.
    /// With that trust rule restored and the comparison with the cached
    /// chapters skipped in `BookContentAnalysisService` (commits c9797a7,
    /// f5b8326, and a9c3b9d no longer revert cleanly), this test fails with
    /// "XCTAssertEqual failed: ("nil") is not equal to
    /// ("Optional("Semaphore Towers")")": the book opens with no headings
    /// at all, its position reads "" instead of "Heading 1 of 3", and the
    /// broken index stays saved.
    func testBookWhoseSavedIndexLostItsChaptersOpensWithEveryChapterAndHeading() throws {
        let world = try makeIntegrationWorld("Integration Reader Loading")
        let book = try world.importBook(from: writeSignalsEPUB())
        var record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.contentIndex?.chapters.count, 3, "The import did not index three chapters")
        record.contentIndex?.chapters = []
        try record.save(to: book.tmbDirectory)

        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)

        XCTAssertNil(reader.errorMessage, "The book did not open")
        XCTAssertEqual(reader.content?.chapters.count, 3)
        XCTAssertEqual(reader.headings.first?.text, "Semaphore Towers")
        XCTAssertEqual(reader.headings.map(\.text), ["Semaphore Towers", "Telegraph Keys", "Undersea Cables"])
        XCTAssertEqual(reader.currentHeadingPosition.label, "Heading 1 of 3")
        // The reader saves the index it rebuilt with the book's record.
        LibraryPersistenceService.flushPendingSave()
        XCTAssertEqual(
            try BookInfo.load(from: book.tmbDirectory).contentIndex?.chapters.count,
            3,
            "The rebuilt index was not saved"
        )
    }

    // MARK: - Fixture

    /// A three-chapter history of signalling, each chapter listed in the
    /// table of contents under its own heading, written as an EPUB in a
    /// folder of this test's own.
    private func writeSignalsEPUB() throws -> URL {
        let epub = try makeSandboxDirectory("IntegrationReaderLoadingSources").appendingPathComponent("signals.epub")
        let chapters = [
            ("Semaphore Towers", "Arms on a mast spelled one letter at a time across the hills."),
            ("Telegraph Keys", "An operator could send thirty words a minute down the wire."),
            ("Undersea Cables", "The first cable across the ocean failed within a month."),
        ]
        try IntegrationEPUB.write(
            title: "Signals",
            chapters: chapters.enumerated().map { number, chapter in
                IntegrationEPUBChapter(
                    fileName: "ch0\(number + 1).xhtml",
                    body: "<h1>\(chapter.0)</h1><p>\(chapter.1)</p>"
                )
            },
            contents: chapters.enumerated().map { number, chapter in
                IntegrationTOCEntry(label: chapter.0, target: "ch0\(number + 1).xhtml")
            },
            to: epub
        )
        return epub
    }
}
