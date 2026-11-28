import CoreGraphics
import UniformTypeIdentifiers
import XCTest
import ZIPFoundation
@testable import TextMouth

/// Pictures of pages and comic book archives imported as books (FMT34),
/// through the import path Open Book takes, with Vision's own text
/// recognition: each sample's text, chapters, and pages; a picture with no
/// text refused; the pages the overlay counts; and a picture among an
/// archive's or a folder's files left as no book. A test skips when text
/// recognition cannot run in its host.
final class PageImageImportTests: XCTestCase {

    // MARK: - Fixtures

    /// Skips the test when Vision's text recognition cannot run in this test
    /// host, as the PDF recognizer's tests skip.
    private func requireTextRecognition() throws {
        let probe = try PageImageFixtures.picture(width: 400, height: 120, lines: ["Quay"], fontSize: 60)
        do {
            _ = try VisionTextRecognition.lines(in: probe)
        } catch PDFTextRecognitionError.unavailable(let reason) {
            throw XCTSkip("Vision text recognition is unavailable in this test host: \(reason)")
        }
    }

    /// The sample at `path` imported, with the book the reader opens.
    private func importSample(_ path: String) throws -> (book: Book, content: DocumentContent, report: ExtractionReport) {
        try requireTextRecognition()
        let imported = try importedForTest(try copyOfFormatSample(path))
        return (imported.book, try openedContent(of: imported.book), imported.report)
    }

    /// `text` in lowercase with its runs of white space made single spaces,
    /// so that a phrase is found however the lines were joined.
    private func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Fails unless `content`'s text holds each of `phrases`, ignoring case
    /// and line breaks, naming the text it holds.
    private func assertText(of content: DocumentContent, holds phrases: [String], _ sample: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let text = normalized(allText(of: content))
        for phrase in phrases where !text.contains(normalized(phrase)) {
            XCTFail("\(sample) lacks “\(phrase)”; its text is: \(text)", file: file, line: line)
        }
    }

    // MARK: - The Samples

    /// The opaque PNG is one page of text, listed by its file's name.
    func testThePNGSampleImportsAsAPictureOfOnePage() throws {
        let (book, content, report) = try importSample("png/page-one.png")

        XCTAssertEqual(book.format, .picture)
        XCTAssertEqual(book.title, "page-one")
        XCTAssertEqual(book.author, Book.unknownAuthor)
        XCTAssertEqual(book.pageReaderVersion, PageReaderVersions.current(for: .picture))
        XCTAssertEqual(content.chapters.count, 1)
        XCTAssertEqual(content.pages.breaks.map(\.label), ["1"])
        XCTAssertTrue(report.isComplete)
        assertText(of: content, holds: ["The Harbour Office", "leaves at half past nine"], "page-one.png")
    }

    /// The PNG of black text on a transparent background, which Vision reads
    /// nothing in as it is, is read once it is flattened onto white.
    func testTheTransparentPNGSampleIsReadOnWhite() throws {
        let (_, content, _) = try importSample("png/page-one-transparent.png")

        assertText(of: content, holds: ["The Harbour Office", "leaves at half past nine"], "page-one-transparent.png")
    }

    /// The JPEG and HEIC samples read as the PNG does.
    func testTheJPEGAndHEICSamplesImport() throws {
        for sample in ["jpeg/page-one.jpg", "heic/page-one.heic"] {
            let (book, content, _) = try importSample(sample)
            XCTAssertEqual(book.format, .picture, sample)
            XCTAssertEqual(content.pages.breaks.map(\.label), ["1"], sample)
            assertText(of: content, holds: ["The Harbour Office", "leaves at half past nine"], sample)
        }
    }

    /// The two-page TIFF is a chapter for each page, with its pages.
    func testTheTwoPageTIFFSampleIsAChapterAPage() throws {
        let (book, content, report) = try importSample("tiff-multipage/two-pages.tiff")

        XCTAssertEqual(book.format, .picture)
        XCTAssertEqual(content.chapters.map(\.title), ["Page 1", "Page 2"])
        XCTAssertEqual(content.pages.breaks.map(\.label), ["1", "2"])
        XCTAssertEqual(content.pages.breaks.map(\.chapterIndex), [0, 1])
        XCTAssertTrue(report.isComplete)
        let first = try XCTUnwrap(content.chapters.first)
        let last = try XCTUnwrap(content.chapters.last)
        XCTAssertTrue(normalized(first.text).contains("half past nine"), first.text)
        XCTAssertTrue(normalized(last.text).contains("thirty days"), last.text)
    }

    /// The comic book archive is a book of its two pictures, named by its
    /// ComicInfo.xml, its first page the front cover.
    func testTheCBZSampleIsABookOfPages() throws {
        let (book, content, report) = try importSample("cbz/harbour-notices.cbz")

        XCTAssertEqual(book.format, .comic)
        XCTAssertEqual(book.title, "The Harbour Office")
        XCTAssertEqual(book.author, "Odile Banerjee")
        XCTAssertEqual(content.chapters.map(\.title), ["Front Cover", "Page 2"])
        XCTAssertEqual(content.pages.breaks.map(\.label), ["1", "2"])
        XCTAssertTrue(report.isComplete)
        assertText(of: content, holds: ["The Harbour Office", "Lost property", "thirty days"], "harbour-notices.cbz")
    }

    // MARK: - Refusals and Progress

    /// A picture with no text imports nothing, and the alert says so in the
    /// step's words.
    func testAPictureWithoutTextImportsNothing() throws {
        try requireTextRecognition()
        let blank = try PageImageFixtures.encoded(PageImageFixtures.picture(width: 600, height: 400), as: .png)
        let url = try PageImageFixtures.write(blank, named: "blank.png", for: self)

        XCTAssertThrowsError(try importedForTest(url)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Could not import “blank.png”. Reading its text failed: No text was found in this picture."
            )
        }
    }

    /// The import of a book of several pages tells its observer, and so the
    /// overlay, how many pages are read, after it begins reading the text.
    func testTheImportReportsThePagesRead() throws {
        try requireTextRecognition()
        var steps: [ImportStep] = []
        let imported = try FileImportService.importFileWithReport(
            from: copyOfFormatSample("tiff-multipage/two-pages.tiff"), observer: { step, _ in steps.append(step) }
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: imported.book.tmbDirectory) }

        let reading = steps.drop { $0 != .readingText }
        XCTAssertEqual(
            Array(reading.prefix(4)),
            [.readingText, .readingPages(done: 0, of: 2), .readingPages(done: 1, of: 2), .readingPages(done: 2, of: 2)],
            "\(steps)"
        )
    }

    /// A step observer that stops the import at a page's report stops it
    /// there, as a failure of reading the text, with nothing published.
    func testAnObserverStoppingAtAPageFailsTheImportThere() throws {
        try requireTextRecognition()
        struct Stop: Error {}
        let source = try copyOfFormatSample("tiff-multipage/two-pages.tiff")

        XCTAssertThrowsError(try FileImportService.importFileWithReport(from: source, observer: { step, _ in
            if step == .readingPages(done: 1, of: 2) { throw Stop() }
        })) { error in
            let failure = error as? ImportFailure
            XCTAssertEqual(failure?.step, .readingText, "\(error)")
            XCTAssertTrue(failure?.underlying is Stop, "\(error)")
        }
    }

    // MARK: - The Direct Reading

    /// A book read straight from its file, as one without a content.md is
    /// read (`BookParser`), has the cache's chapters and text, without pages:
    /// a picture of one page is one chapter named by its file, and one of
    /// several a chapter for each page with text. The scripted recognizer
    /// stands in for Vision through the reader's default.
    func testTheDirectReadingHasTheCachesChapters() throws {
        let page = try PageImageFixtures.picture(width: 120, height: 90)
        let several = try PageImageFixtures.write(
            try PageImageFixtures.encoded([page, page, page], as: .tiff), named: "Works Notice.tiff", for: self
        )
        let one = try PageImageFixtures.write(try PageImageFixtures.encoded(page, as: .png), named: "Harbour Letter.png", for: self)
        let saved = PageImageReader.defaultRecognizer
        defer { PageImageReader.defaultRecognizer = saved }
        PageImageReader.defaultRecognizer = ScriptedPageRecognizer([
            .lines(PageImageFixtures.paragraph(["Notice of works"])), .lines([]), .lines(PageImageFixtures.paragraph(["Signed"])),
            .lines(PageImageFixtures.paragraph(["Dear neighbour,"])),
        ])

        let pages = try BookParser.parse(url: several, format: .picture)
        let letter = try BookParser.parse(url: one, format: .picture)

        XCTAssertEqual(pages.chapters.map(\.title), ["Page 1", "Page 3"])
        XCTAssertEqual(pages.chapters.map(\.text), ["Notice of works", "Signed"])
        XCTAssertTrue(pages.pages.isEmpty)
        XCTAssertEqual(letter.title, "Harbour Letter")
        XCTAssertEqual(letter.chapters.map(\.title), ["Harbour Letter"])
        XCTAssertEqual(letter.chapters.map(\.text), ["Dear neighbour,"])
    }

    /// A comic book archive in a ZIP batch with a page that cannot be read is
    /// imported without that page, and the batch's alert lists it among the
    /// books with pages that could not be read, keeping the original; the
    /// scripted recognizer stands in for Vision.
    func testABatchNamesTheUnreadablePageOfAnArchive() throws {
        let saved = PageImageReader.defaultRecognizer
        defer { PageImageReader.defaultRecognizer = saved }
        PageImageReader.defaultRecognizer = ScriptedPageRecognizer([
            .lines(PageImageFixtures.paragraph(["Sailings resume at dawn"])),
        ])
        let comic = try PageImageFixtures.comicArchive(named: "notices.cbz", [
            TestZIPEntry("1.png", try PageImageFixtures.plainPage()),
            TestZIPEntry("2.png", Data("not a picture".utf8)),
        ], for: self)

        let result = FileImportService.importSupportedFiles([comic], toFolder: "")
        for book in result.books {
            addTeardownBlock { try? FileManager.default.removeItem(at: book.tmbDirectory) }
        }

        XCTAssertEqual(result.books.map(\.format), [.comic])
        XCTAssertTrue(result.keepsOriginal)
        XCTAssertEqual(
            result.failureSummary,
            "Imported 1 book, but 1 book has pages that could not be read:\nnotices.cbz: Text recognition could not read "
                + "1 of 2 pages: page 2 (its file could not be read as a picture).\nThe original file was kept."
        )
    }

    // MARK: - Pictures Among Other Files

    /// A picture is a book only when chosen on its own: among other files it
    /// is a cover or artwork. A comic book archive is a book anywhere.
    func testOnlyAPictureIsNoBookAmongOtherFiles() {
        for fileExtension in BookFormat.picture.fileExtensions {
            let url = URL(fileURLWithPath: "/tmp/cover.\(fileExtension)")
            XCTAssertEqual(BookFormat.detect(from: url), .picture, fileExtension)
            XCTAssertNil(BookFormat.detectBookAmongOtherFiles(from: url), fileExtension)
        }
        for format in BookFormat.allCases where format != .picture {
            XCTAssertTrue(format.isBookAmongOtherFiles, "\(format)")
        }
        XCTAssertEqual(BookFormat.detectBookAmongOtherFiles(from: URL(fileURLWithPath: "/tmp/notices.CBZ")), .comic)
    }

    /// A ZIP batch takes its books and its comic book archive, and counts
    /// its pictures among the files that are no book.
    func testAZIPBatchPassesOverItsPictures() throws {
        let folder = try makeSandboxDirectory("PageImageBatch")
        let page = try PageImageFixtures.plainPage()
        try Data("Ferry times".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try page.write(to: folder.appendingPathComponent("cover.jpg"))
        try page.write(to: folder.appendingPathComponent("scan.png"))
        let comic = try PageImageFixtures.comicArchive(named: "notices.cbz", [TestZIPEntry("1.png", page)], for: self)
        try FileManager.default.copyItem(at: comic, to: folder.appendingPathComponent("notices.cbz"))
        let unpacking = NestedArchiveUnpacking(
            directory: try makeSandboxDirectory("PageImageNested"), budget: ArchiveBudget(), depth: 1,
            isCancelled: { false }, progress: nil
        )

        let found = try FileImportService.importCandidates(in: folder, unpacking: unpacking)

        XCTAssertEqual(found.books.map(\.lastPathComponent), ["notes.txt", "notices.cbz"])
        XCTAssertEqual(found.nonBookFiles.countsByExtension, ["jpg": 1, "png": 1])
    }

    /// An archive of tracks with its cover picture is still one audiobook,
    /// and so is one with a comic book archive beside its tracks, as before
    /// TextMouth read comics; any other book beside them makes a batch.
    func testAnAudiobookArchiveWithItsCoverIsStillAnAudiobook() throws {
        let tracks = try makeTemporaryZip(prefix: "pageimage-album", orderedEntries: [
            TestZIPEntry("01 Arrival.mp3", Data(repeating: 0, count: 16)),
            TestZIPEntry("02 Departure.mp3", Data(repeating: 0, count: 16)),
            TestZIPEntry("cover.jpg", try PageImageFixtures.plainPage()),
            TestZIPEntry("folder.png", try PageImageFixtures.plainPage()),
        ])
        addTeardownBlock { try? FileManager.default.removeItem(at: tracks) }
        let withComic = try makeTemporaryZip(prefix: "pageimage-mixed", orderedEntries: [
            TestZIPEntry("01 Arrival.mp3", Data(repeating: 0, count: 16)),
            TestZIPEntry("notices.cbz", Data(repeating: 0, count: 16)),
        ])
        addTeardownBlock { try? FileManager.default.removeItem(at: withComic) }
        let withEPUB = try makeTemporaryZip(prefix: "pageimage-epub", orderedEntries: [
            TestZIPEntry("01 Arrival.mp3", Data(repeating: 0, count: 16)),
            TestZIPEntry("guide.epub", Data(repeating: 0, count: 16)),
        ])
        addTeardownBlock { try? FileManager.default.removeItem(at: withEPUB) }

        XCTAssertTrue(LibraryViewModel.isAudioZip(url: tracks))
        // As before TextMouth read comics, the comic is passed over and the tracks are one audiobook.
        XCTAssertTrue(LibraryViewModel.isAudioZip(url: withComic), "a comic book archive beside tracks leaves them one audiobook")
        XCTAssertFalse(LibraryViewModel.isAudioZip(url: withEPUB), "any other book beside tracks still makes a batch")
        XCTAssertFalse(BookFormat.comic.isBookBesideTracks)
        XCTAssertFalse(BookFormat.picture.isBookBesideTracks)
        XCTAssertTrue(BookFormat.epub.isBookBesideTracks)
    }
}
