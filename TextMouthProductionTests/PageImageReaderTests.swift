import CoreGraphics
import UniformTypeIdentifiers
import XCTest
@testable import TextMouth

/// What the reader of pictures of pages makes of what text recognition finds
/// (FMT34), with a scripted recognizer in Vision's place: the pages and
/// chapters it writes, a transparent page read again on black, pages that
/// cannot be read, the refusal it gives when nothing can be, Cancel between
/// pages, and the pages it reports read.
final class PageImageReaderTests: XCTestCase {
    private typealias Script = ScriptedPageRecognizer

    // MARK: - Fixtures

    /// A picture file of `pages` plain white pages named `name`: a TIFF of
    /// several, or a PNG of one.
    private func pictureFile(pages: Int = 1, named name: String? = nil, transparent: Bool = false) throws -> URL {
        let page = try PageImageFixtures.picture(width: 120, height: 90, ground: transparent ? nil : CGColor(gray: 1, alpha: 1))
        let type: UTType = pages > 1 ? .tiff : .png
        let data = try PageImageFixtures.encoded(Array(repeating: page, count: pages), as: type)
        return try PageImageFixtures.write(data, named: name ?? (pages > 1 ? "letter.tiff" : "letter.png"), for: self)
    }

    /// `url` read as a picture file's pages with `recognizer`.
    private func read(_ url: URL, with recognizer: (any PageImageTextRecognizer)?) throws -> PageImageReader.Extraction {
        try PageImageReader.extract(PageImageFilePages(url: url), includesPages: true, recognizer: recognizer)
    }

    // MARK: - One Picture

    /// A picture's text is one page of the book, read on white once.
    func testAPictureIsOnePage() throws {
        let script = Script([.lines(PageImageFixtures.paragraph(["Harbour Office", "12 Quay Road"]))])

        let extraction = try read(try pictureFile(), with: script)

        XCTAssertEqual(extraction.markdown, "<!-- page: 1 -->\n\nHarbour Office\n12 Quay Road")
        XCTAssertTrue(extraction.report.isComplete)
        XCTAssertEqual(script.pictures, [Script.Asked(width: 120, height: 90, cornerGray: 255)])
    }

    /// A transparent picture in which nothing is found on white is read
    /// again on black, where light print shows.
    func testATransparentPictureIsReadAgainOnBlack() throws {
        let script = Script([.lines([]), .lines(PageImageFixtures.paragraph(["Ferry leaves at noon"]))])

        let extraction = try read(try pictureFile(transparent: true), with: script)

        XCTAssertEqual(script.pictures.map(\.cornerGray), [255, 0])
        XCTAssertEqual(extraction.markdown, "<!-- page: 1 -->\n\nFerry leaves at noon")
    }

    /// An opaque HEIC, which ImageIO decodes with an alpha channel (measured
    /// on macOS 26: premultiplied alpha), is judged by what it says of
    /// itself: with nothing found on white, it is not read again on black.
    func testAnOpaqueHEICIsReadOnce() throws {
        let heic = try copyOfFormatSample("heic/page-one.heic")
        let script = Script([.lines([])])

        XCTAssertThrowsError(try read(heic, with: script))

        XCTAssertEqual(script.pictures.count, 1, "an opaque HEIC is not read again on black")
    }

    /// An opaque picture in which nothing is found is not read again, and
    /// imports nothing, saying so.
    func testAPictureWithoutTextIsRefused() throws {
        let script = Script([.lines([])])

        XCTAssertThrowsError(try read(try pictureFile(), with: script)) { error in
            XCTAssertEqual(error as? PageImageError, .noText(.picture, pageCount: 1))
            XCTAssertEqual(error.localizedDescription, "No text was found in this picture.")
        }
        XCTAssertEqual(script.pictures.count, 1)
    }

    /// A picture text recognition fails on is refused with the reason, as a
    /// PDF's is.
    func testAPictureRecognitionFailsOnIsRefusedWithTheReason() throws {
        let script = Script([.failure(PDFTextRecognitionError.failed("text recognition failed: the model gave up"))])

        XCTAssertThrowsError(try read(try pictureFile(), with: script)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "No text could be read from this picture: OCR could not run (text recognition failed: the model gave up)."
            )
        }
    }

    /// Without text recognition nothing can be read, and the sentence says
    /// why.
    func testWithoutTextRecognitionNothingIsRead() throws {
        XCTAssertThrowsError(try read(try pictureFile(), with: nil)) { error in
            XCTAssertEqual(
                error as? PageImageError,
                .recognitionUnavailable(.picture, reason: PageImageReader.recognitionNotAvailable)
            )
        }
    }

    // MARK: - Several Pages

    /// Each page with text of a TIFF is a chapter; a page without text keeps
    /// its marker, and is no failure.
    func testEachPageWithTextIsAChapter() throws {
        let script = Script([
            .lines(PageImageFixtures.paragraph(["Notice of works"])), .lines([]), .lines(PageImageFixtures.paragraph(["Signed, the harbour master"])),
        ])

        let extraction = try read(try pictureFile(pages: 3), with: script)

        XCTAssertEqual(
            extraction.markdown,
            "<!-- chapter: Page 1 -->\n<!-- page: 1 -->\n\nNotice of works\n\n<!-- page: 2 -->\n\n"
                + "<!-- chapter: Page 3 -->\n<!-- page: 3 -->\n\nSigned, the harbour master"
        )
        XCTAssertTrue(extraction.report.isComplete)
        XCTAssertEqual(extraction.report.pdf?.pagesWhereOCRFoundNothing, [2])
        XCTAssertEqual(script.pictures.count, 3)
    }

    /// A page text recognition fails on is left out and named, while the
    /// others are read, and the report keeps the original.
    func testAPageThatFailsIsNamedAndTheOthersRead() throws {
        let script = Script([
            .lines(PageImageFixtures.paragraph(["Notice of works"])),
            .failure(PDFTextRecognitionError.failed("text recognition failed: the model gave up")),
            .lines(PageImageFixtures.paragraph(["Signed"])),
        ])

        let extraction = try read(try pictureFile(pages: 3), with: script)

        XCTAssertFalse(extraction.report.isComplete)
        XCTAssertEqual(
            extraction.report.message,
            "Text recognition could not read 1 of 3 pages: page 2 (text recognition failed: the model gave up)."
        )
        XCTAssertTrue(extraction.markdown.contains("<!-- page: 2 -->"), extraction.markdown)
        XCTAssertTrue(extraction.markdown.hasSuffix("Signed"), extraction.markdown)
    }

    /// When every page fails, nothing is imported, and the sentence names
    /// the pages and why.
    func testABookWhosePagesAllFailIsRefusedNamingThem() throws {
        let failure = PDFTextRecognitionError.failed("text recognition failed: the model gave up")
        let script = Script([.failure(failure), .failure(failure)])

        XCTAssertThrowsError(try read(try pictureFile(pages: 2), with: script)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Text recognition could not read any of the 2 pages: pages 1 and 2 (text recognition failed: the model gave up)."
            )
        }
    }

    /// Once text recognition proves unavailable, no later page asks it, and
    /// the book is refused with the reason.
    func testRecognitionUnavailableStopsAsking() throws {
        let script = Script([.failure(PDFTextRecognitionError.unavailable("text recognition failed: no model"))])

        XCTAssertThrowsError(try read(try pictureFile(pages: 3), with: script)) { error in
            XCTAssertEqual(
                error as? PageImageError, .recognitionUnavailable(.picture, reason: "text recognition failed: no model")
            )
        }
        XCTAssertEqual(script.pictures.count, 1)
    }

    /// Several pages without text are refused, counting them.
    func testSeveralPagesWithoutTextAreRefused() throws {
        XCTAssertThrowsError(try read(try pictureFile(pages: 2), with: Script([]))) { error in
            XCTAssertEqual(error.localizedDescription, "No text was found on any of the 2 pages of this picture.")
        }
    }

    // MARK: - Progress and Cancel

    /// The import reading the book hears the pages read, from none to all.
    func testThePagesReadAreReported() throws {
        var reports: [String] = []
        let script = Script([.lines(PageImageFixtures.paragraph(["One"])), .lines(PageImageFixtures.paragraph(["Two"])), .lines([])])

        _ = try ImportPageProgress.reporting(to: { done, total in reports.append("\(done)/\(total)") }) {
            try read(try pictureFile(pages: 3), with: script)
        }

        XCTAssertEqual(reports, ["0/3", "1/3", "2/3", "3/3"])
    }

    /// Cancel stops the reading before the next page, as an import's Cancel
    /// stops TextMouth's own readers, and before the first when it came
    /// first.
    func testCancelStopsBeforeTheNextPage() throws {
        let url = try pictureFile(pages: 3)
        let script = Script([.lines(PageImageFixtures.paragraph(["One"])), .lines(PageImageFixtures.paragraph(["Two"]))])
        let cancellation = ImportCancellation()

        XCTAssertThrowsError(
            try ImportCancellation.$current.withValue(cancellation) {
                try ImportPageProgress.reporting(to: { done, _ in if done == 1 { cancellation.cancel() } }) {
                    try read(url, with: script)
                }
            }
        ) { error in
            XCTAssertTrue(error is ImportCancelled, "\(error)")
        }
        XCTAssertEqual(script.pictures.count, 1, "the page after the cancel was not read")

        let early = Script([.lines(PageImageFixtures.paragraph(["One"]))])
        let cancelled = ImportCancellation()
        cancelled.cancel()
        XCTAssertThrowsError(try ImportCancellation.$current.withValue(cancelled) { try read(url, with: early) }) { error in
            XCTAssertTrue(error is ImportCancelled, "\(error)")
        }
        XCTAssertEqual(early.pictures.count, 0)
    }

    /// Without pages, the same pages write the same text and chapters, and
    /// no marker.
    func testWithoutPagesNoMarkerIsWritten() throws {
        let script = Script([.lines(PageImageFixtures.paragraph(["Notice of works"])), .lines([])])

        let extraction = try PageImageReader.extract(
            PageImageFilePages(url: try pictureFile(pages: 2)), includesPages: false, recognizer: script
        )

        XCTAssertEqual(extraction.markdown, "<!-- chapter: Page 1 -->\nNotice of works")
    }
}
