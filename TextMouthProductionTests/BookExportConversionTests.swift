import os
import XCTest
@testable import TextMouth

/// The export's job runner converting instead of copying (FMT18): a text
/// book's "Text as Markdown" item, when a writer is chosen, is walked from
/// content.md into an `ExportDocument` and written by that writer, one book
/// at a time, never over an existing file and never leaving half a file.
///
/// Every book lives in a library folder of the test's own, and every export
/// goes to a sandbox folder; nothing reaches the user's Documents or library.
@MainActor
final class BookExportConversionTests: XCTestCase {

    // MARK: - Converting

    /// A book with three "## Notes" headings, converted to HTML beside its
    /// reading text, writes the page and the text and no Markdown; the page
    /// is well-formed, with three headings of three distinct ids and a
    /// contents link to each.
    func testAMarkdownItemConvertsToAPageWithADistinctIdPerHeading() throws {
        let world = try makeIntegrationWorld("Export Convert Html")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.threeNotes))
        let stem = BookExportService.fileNameStem(for: book.title)
        let destination = try makeSandboxDirectory("Export Convert Html Destination")

        let outcome = BookExportService.export(
            [BookExportService.offer(for: book)],
            kinds: [.markdown, .plainText],
            conversions: [.markdown: Self.html],
            to: destination
        )

        XCTAssertEqual(outcome.failures, [])
        XCTAssertFalse(outcome.wasCancelled)
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: destination.path)),
            ["\(stem) - Text.html", "\(stem) - Text.txt"],
            "no Markdown is written when the Markdown is converted"
        )
        let pageURL = destination.appendingPathComponent("\(stem) - Text.html")
        let page = try String(contentsOf: pageURL, encoding: .utf8)
        let parser = XMLParser(data: try Data(contentsOf: pageURL))
        XCTAssertTrue(parser.parse(), "the page is not well-formed: \(String(describing: parser.parserError))")
        XCTAssertEqual(page.components(separatedBy: "<h2").count - 1, 3, "three level-2 headings")
        let ids = Self.matches(of: #"<h2 id="([^"]+)""#, in: page)
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(Set(ids).count, 3, "the three headings share an id: \(ids)")
        for id in ids {
            XCTAssertTrue(page.contains("<a href=\"#\(id)\">Notes</a>"), "no contents link to \(id)")
        }
    }

    /// With no conversion, the Markdown written is the book's content.md
    /// byte for byte: today's export, unchanged.
    func testWithoutAConversionTheMarkdownIsCopiedByteForByte() throws {
        let world = try makeIntegrationWorld("Export No Conversion")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.threeNotes))
        let stem = BookExportService.fileNameStem(for: book.title)
        let destination = try makeSandboxDirectory("Export No Conversion Destination")

        let outcome = BookExportService.export([BookExportService.offer(for: book)], kinds: [.markdown], to: destination)

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("\(stem) - Text.md")),
            try Data(contentsOf: MarkdownCacheService.cacheURL(for: book))
        )
    }

    /// Two books converted each get a folder of their own holding their
    /// page; exporting a book again writes a numbered page beside the first,
    /// which is left as it was.
    func testSeveralBooksEachGetAPageAndAnotherExportNumbersItsPage() throws {
        let world = try makeIntegrationWorld("Export Convert Two")
        let first = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.threeNotes))
        let second = try world.importBook(from: writeSource(named: "Lock Keeper.md", Self.threeNotes))
        let both = try makeSandboxDirectory("Export Convert Two Destination")

        let outcome = BookExportService.export(
            [BookExportService.offer(for: first), BookExportService.offer(for: second)],
            kinds: [.markdown],
            conversions: [.markdown: Self.html],
            to: both
        )

        XCTAssertEqual(outcome.failures, [])
        for book in [first, second] {
            let stem = BookExportService.fileNameStem(for: book.title)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: both.appendingPathComponent(stem).path),
                ["\(stem) - Text.html"]
            )
        }

        // The same book twice into one folder: the second page is numbered.
        let single = try makeSandboxDirectory("Export Convert Again Destination")
        let stem = BookExportService.fileNameStem(for: first.title)
        let offer = BookExportService.offer(for: first)
        _ = BookExportService.export([offer], kinds: [.markdown], conversions: [.markdown: Self.html], to: single)
        let firstPage = try Data(contentsOf: single.appendingPathComponent("\(stem) - Text.html"))
        let again = BookExportService.export([offer], kinds: [.markdown], conversions: [.markdown: Self.html], to: single)

        XCTAssertEqual(again.exported.map(\.lastPathComponent), ["\(stem) - Text 2.html"])
        XCTAssertEqual(try Data(contentsOf: single.appendingPathComponent("\(stem) - Text.html")), firstPage)
    }

    /// A hand-edited content.md is what is converted: the page holds the
    /// edited words and none of the old.
    func testAHandEditedBookConvertsItsEditedWords() throws {
        let world = try makeIntegrationWorld("Export Convert Edited")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.threeNotes))
        let stem = BookExportService.fileNameStem(for: book.title)
        // As Edit Text leaves them: new bytes in the package's content.md.
        try Data("# Edited Pilots\n\nRevised lanterns burn.\n".utf8).write(to: MarkdownCacheService.cacheURL(for: book))
        let destination = try makeSandboxDirectory("Export Convert Edited Destination")

        let outcome = BookExportService.export(
            [BookExportService.offer(for: book)],
            kinds: [.markdown],
            conversions: [.markdown: Self.html],
            to: destination
        )

        XCTAssertEqual(outcome.failures, [])
        let page = try String(contentsOf: destination.appendingPathComponent("\(stem) - Text.html"), encoding: .utf8)
        XCTAssertTrue(page.contains("Revised lanterns burn."))
        XCTAssertFalse(page.contains("Alpha notes"), "the old words are still in the page")
    }

    /// A conversion given for the reading text, which is not a kind a text
    /// writer converts, is ignored: the text is written as ".txt".
    func testAConversionGivenForTheReadingTextIsIgnored() throws {
        let world = try makeIntegrationWorld("Export Convert Ignored")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.threeNotes))
        let stem = BookExportService.fileNameStem(for: book.title)
        let destination = try makeSandboxDirectory("Export Convert Ignored Destination")

        let outcome = BookExportService.export(
            [BookExportService.offer(for: book)],
            kinds: [.plainText],
            conversions: [.plainText: Self.html],
            to: destination
        )

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["\(stem) - Text.txt"])
    }

    // MARK: - Planning

    /// A converted file takes the conversion's extension and a number when
    /// the name is taken, and its source names the book's details.
    func testPlanNumbersAConvertedNameAndKeepsTheBookDetails() throws {
        let world = try makeIntegrationWorld("Export Convert Plan")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.threeNotes))
        let stem = BookExportService.fileNameStem(for: book.title)
        let destination = try makeSandboxDirectory("Export Convert Plan Destination")
        let taken = destination.appendingPathComponent("\(stem) - Text.html")

        let plan = BookExportService.plan(
            [BookExportService.offer(for: book)],
            kinds: [.markdown],
            conversions: [.markdown: Self.html],
            in: destination,
            fileExists: { $0 == taken }
        )

        let planned = try XCTUnwrap(plan.files.first)
        XCTAssertEqual(plan.files.count, 1)
        XCTAssertEqual(planned.target.lastPathComponent, "\(stem) - Text 2.html")
        XCTAssertEqual(
            planned.file.source,
            .converted(
                from: MarkdownCacheService.cacheURL(for: book),
                book: ExportBookDetails(book),
                by: Self.html
            )
        )
    }

    // MARK: - Failing

    /// A writer that refuses one book fails that file alone, named with the
    /// writer's sentence; the other book is written, and the words say so.
    func testARefusedBookIsNamedWithTheWritersSentenceAndTheOthersAreWritten() throws {
        let world = try makeIntegrationWorld("Export Convert Refused")
        let refused = try world.importBook(from: writeSource(named: "Refused Harbour.md", Self.threeNotes))
        let fine = try world.importBook(from: writeSource(named: "Lock Keeper.md", Self.threeNotes))
        let destination = try makeSandboxDirectory("Export Convert Refused Destination")

        let outcome = BookExportService.export(
            [BookExportService.offer(for: refused), BookExportService.offer(for: fine)],
            kinds: [.markdown],
            conversions: [.markdown: Self.test(RefusingWriter())],
            to: destination
        )

        XCTAssertEqual(
            outcome.failures,
            [BookExportFailure(name: "Refused Harbour - Text.test", reason: "The test writer refuses this book.")]
        )
        XCTAssertEqual(outcome.exported.map(\.lastPathComponent), ["Lock Keeper - Text.test"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Lock Keeper/Lock Keeper - Text.test").path))
        XCTAssertEqual(
            BookExportWording.finished(outcome, folderName: "Folder"),
            "Exported 1 item to Folder. Couldn't export Refused Harbour - Text.test: The test writer refuses this book."
        )
    }

    /// A content.md that is not UTF-8 fails that book's file, named for the
    /// page; another book still exports.
    func testABookWhoseTextIsNotUTF8FailsAloneAndTheNextExports() throws {
        let world = try makeIntegrationWorld("Export Convert Bad Bytes")
        let broken = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.threeNotes))
        let fine = try world.importBook(from: writeSource(named: "Lock Keeper.md", Self.threeNotes))
        try Data([0xFF, 0xFE, 0x41]).write(to: MarkdownCacheService.cacheURL(for: broken))
        let destination = try makeSandboxDirectory("Export Convert Bad Bytes Destination")
        let brokenStem = BookExportService.fileNameStem(for: broken.title)
        let fineStem = BookExportService.fileNameStem(for: fine.title)

        let outcome = BookExportService.export(
            [BookExportService.offer(for: broken), BookExportService.offer(for: fine)],
            kinds: [.markdown],
            conversions: [.markdown: Self.html],
            to: destination
        )

        XCTAssertEqual(outcome.failures.map(\.name), ["\(brokenStem) - Text.html"])
        XCTAssertEqual(outcome.exported.map(\.lastPathComponent), ["\(fineStem) - Text.html"])
        XCTAssertFalse(outcome.wasCancelled)
    }

    // MARK: - Stop

    /// Stop pressed while a writer is partway through a book ends the
    /// export: that book and the ones after it leave no file, and the
    /// scratch file the writer had begun is gone with its folder.
    func testStopPartwayThroughABookLeavesNothingOfItOrTheBooksAfter() throws {
        let world = try makeIntegrationWorld("Export Convert Stop Partway")
        let books = try ["Aaron Wharf", "Bell Mooring", "Cask Landing"].map {
            try world.importBook(from: writeSource(named: "\($0).md", Self.threeNotes))
        }
        let destination = try makeSandboxDirectory("Export Convert Stop Partway Destination")
        let writer = StoppingWriter(stopsOn: "Bell Mooring", finishesFirst: false)

        let outcome = BookExportService.export(
            books.map { BookExportService.offer(for: $0) },
            kinds: [.markdown],
            conversions: [.markdown: Self.test(writer)],
            to: destination,
            cancellation: BookExportCancellation()
        )

        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(outcome.failures, [], "a stopped file is not a failure")
        XCTAssertEqual(outcome.exported.map(\.lastPathComponent), ["Aaron Wharf - Text.test"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["Aaron Wharf"])
        try assertScratchGone(writer)
    }

    /// Stop pressed just as a writer finishes a whole file still leaves no
    /// file of that book: the file is moved into place only when the export
    /// has not been stopped.
    func testStopJustAfterTheWriterFinishedLeavesNoFileOfThatBook() throws {
        let world = try makeIntegrationWorld("Export Convert Stop After")
        let books = try ["Aaron Wharf", "Bell Mooring", "Cask Landing"].map {
            try world.importBook(from: writeSource(named: "\($0).md", Self.threeNotes))
        }
        let destination = try makeSandboxDirectory("Export Convert Stop After Destination")
        let writer = StoppingWriter(stopsOn: "Bell Mooring", finishesFirst: true)

        let outcome = BookExportService.export(
            books.map { BookExportService.offer(for: $0) },
            kinds: [.markdown],
            conversions: [.markdown: Self.test(writer)],
            to: destination,
            cancellation: BookExportCancellation()
        )

        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["Aaron Wharf"])
        try assertScratchGone(writer)
    }

    // MARK: - Progress

    /// Progress hears each converted book finish, out of two.
    func testProgressHearsEachConvertedBook() throws {
        let world = try makeIntegrationWorld("Export Convert Progress")
        let first = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.threeNotes))
        let second = try world.importBook(from: writeSource(named: "Lock Keeper.md", Self.threeNotes))
        let destination = try makeSandboxDirectory("Export Convert Progress Destination")
        let heard = OSAllocatedUnfairLock<[[Int]]>(initialState: [])

        _ = BookExportService.export(
            [BookExportService.offer(for: first), BookExportService.offer(for: second)],
            kinds: [.markdown],
            conversions: [.markdown: Self.html],
            to: destination,
            progress: { done, total in heard.withLock { $0.append([done, total]) } }
        )

        XCTAssertEqual(heard.withLock { $0 }, [[1, 2], [2, 2]])
    }

    // MARK: - Fixtures

    /// A book with chapter markers and "## Notes" under each of its three
    /// chapters.
    private static let threeNotes = """
    <!-- chapter: First -->
    # First

    ## Notes

    Alpha notes.

    <!-- chapter: Second -->
    # Second

    ## Notes

    Beta notes.

    <!-- chapter: Third -->
    # Third

    ## Notes

    Gamma notes.
    """

    /// The HTML writer, as the dialog's model hands it to the export.
    private static let html = BookExportConversion.text(
        TextExportConversion(HTMLExportWriter(), options: NoTextExportOptions())
    )

    /// `writer`, a test's, as the export is handed it.
    private static func test<Writer: TextExportWriter>(_ writer: Writer) -> BookExportConversion
    where Writer.Options == NoTextExportOptions {
        .text(TextExportConversion(writer, options: NoTextExportOptions()))
    }

    /// Every capture of group 1 of `pattern` in `text`, in order.
    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// Writes `text` as a file named `name` in a sandbox folder of its own,
    /// for an import to read.
    private func writeSource(named name: String, _ text: String) throws -> URL {
        let file = try makeSandboxDirectory("Export Convert Source").appendingPathComponent(name)
        try Data(text.utf8).write(to: file)
        return file
    }

    /// Asserts that the scratch file `writer` recorded, and the folder it
    /// was made in, no longer exist.
    private func assertScratchGone(_ writer: StoppingWriter) throws {
        let recorded = try XCTUnwrap(writer.scratchFiles.withLock { $0 }.last, "the writer never ran")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorded.path), "the scratch file is still there")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: recorded.deletingLastPathComponent().path),
            "the scratch folder is still there"
        )
    }
}

// MARK: - Test Writers

/// A writer that refuses the book titled "Refused Harbour" with a sentence
/// of its own and writes a short file for any other.
private struct RefusingWriter: TextExportWriter {
    let id = "test"
    let name = "Test"
    let hint = "A writer for tests."
    let fileExtension = "test"

    func write(_ document: ExportDocument, options: NoTextExportOptions, to url: URL, cancellation: BookExportCancellation) throws {
        if document.book.title == "Refused Harbour" {
            throw TextExportError("The test writer refuses this book.")
        }
        try Data("written".utf8).write(to: url, options: .withoutOverwriting)
    }
}

/// A writer that, for the book titled `stopsOn`, presses Stop: after writing
/// some bytes and then checking for Stop (`finishesFirst` false), or after
/// writing a whole file and returning (`finishesFirst` true). It records the
/// scratch URL of every file it is given. Other books are written whole.
private struct StoppingWriter: TextExportWriter {
    let id = "test"
    let name = "Test"
    let hint = "A writer for tests."
    let fileExtension = "test"
    /// The title of the book at which Stop is pressed.
    let stopsOn: String
    /// Whether the writer finishes its file before Stop is noticed.
    let finishesFirst: Bool
    /// The URLs the writer was asked to write, in order.
    let scratchFiles = OSAllocatedUnfairLock<[URL]>(initialState: [])

    func write(_ document: ExportDocument, options: NoTextExportOptions, to url: URL, cancellation: BookExportCancellation) throws {
        scratchFiles.withLock { $0.append(url) }
        try Data("some bytes".utf8).write(to: url, options: .withoutOverwriting)
        guard document.book.title == stopsOn else { return }
        // Stop is pressed now, while this book's file is being written.
        cancellation.cancel()
        if !finishesFirst {
            try cancellation.checkCancelled()
        }
    }
}
