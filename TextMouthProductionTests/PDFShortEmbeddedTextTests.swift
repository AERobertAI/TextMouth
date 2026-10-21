import CoreGraphics
import PDFKit
import XCTest
@testable import TextMouth

/// TODO T09: a PDF page's embedded text is always kept, however short; OCR
/// reads only what the page shows as pictures (or the whole of a page with
/// no embedded text); what OCR adds is merged in reading order without
/// repeating embedded text; and the report says how every page was read,
/// including where OCR could not run and why.
///
/// The decisions are checked with a scripted recognizer, so they do not
/// depend on Vision; the last tests run Vision itself on the same pages
/// and skip, saying so, where Vision cannot run.
final class PDFShortEmbeddedTextTests: XCTestCase {

    // MARK: - Short Embedded Text

    /// A title page holding one short line keeps it exactly. OCR is not
    /// asked, so it can no longer replace "Ballast" with its misreading.
    func testShortTitlePageKeepsItsEmbeddedText() throws {
        let url = try PDFFixtures.makePDF(for: self) { context, _ in
            PDFFixtures.drawText("Ballast", size: 36, at: CGPoint(x: 230, y: 500), in: context)
        }
        let recognizer = Self.misreadingEverything()

        let extraction = try PDFTextParser.extract(from: url, recognizer: recognizer, includesPages: false)

        XCTAssertEqual(extraction.markdown, "Ballast")
        XCTAssertEqual(recognizer.requests, [])
        XCTAssertEqual(extraction.report.pdf?.pages, [page(1, .embedded, .notNeeded)])
        XCTAssertTrue(extraction.report.isComplete)
    }

    /// Short lines in scripts OCR cannot read, and a lone folio, are kept
    /// even with no OCR at all, and a PDF that never needed OCR does not
    /// report it unavailable.
    func testShortLinesInAnyScriptAreKeptWithoutOCR() throws {
        let lines = ["Ὀδύσσεια", "בראשית", "iv"]
        let url = try PDFFixtures.makePDF(for: self, pages: lines.count) { context, index in
            PDFFixtures.drawText(lines[index], size: index == 2 ? 9 : 36, at: CGPoint(x: 230, y: 500), in: context)
        }

        let extraction = try PDFTextParser.extract(from: url, recognizer: nil, includesPages: false)

        XCTAssertEqual(extraction.markdown, "Ὀδύσσεια\n\nבראשית\n\niv")
        XCTAssertTrue(extraction.report.isComplete)
        XCTAssertNil(extraction.report.pdf?.ocrUnavailableReason)
        XCTAssertEqual(extraction.report.pdf?.pagesWithEmbeddedTextOnly, [1, 2, 3])
    }

    // MARK: - Pictures Beside Embedded Text

    /// A picture with a one-line caption: the caption is kept, OCR reads
    /// only the picture, and the picture's words come before the caption
    /// below it.
    func testPictureWithACaptionKeepsTheCaptionAndReadsThePicture() throws {
        let url = try PDFFixtures.captionedPicture(for: self)
        let recognizer = ScriptedTextRecognizer { _ in Self.signLines }

        let extraction = try PDFTextParser.extract(from: url, recognizer: recognizer, includesPages: false)

        XCTAssertEqual(extraction.markdown, "PIER 2\nNO MOORING\n\n\(PDFFixtures.caption)")
        XCTAssertEqual(
            recognizer.requests,
            [ScriptedTextRecognizer.Request(pageNumber: 1, region: PDFFixtures.captionedPictureRect)]
        )
        XCTAssertEqual(extraction.report.pdf?.pages, [page(1, .both, .recognizedText)])
    }

    /// A caption laid over its picture is read by OCR too, misread even,
    /// and still appears once.
    func testCaptionLaidOverThePictureIsNotRepeated() throws {
        let url = try PDFFixtures.makePDF(for: self) { context, _ in
            let pictureRect = PDFFixtures.captionedPictureRect
            context.draw(PDFFixtures.picture(size: pictureRect.size), in: pictureRect)
            PDFFixtures.drawText(PDFFixtures.caption, size: 11, at: CGPoint(x: 100, y: 410), in: context)
        }
        let (document, firstPage) = try PDFFixtures.firstPage(of: url)
        let captionBounds = try XCTUnwrap(
            firstPage.selection(for: NSRange(location: 0, length: (PDFFixtures.caption as NSString).length))?
                .bounds(for: firstPage)
        )
        withExtendedLifetime(document) {}
        let recognizer = ScriptedTextRecognizer { _ in
            [Self.signLines[0], PDFFixtures.line("Plate 4. The north pier at low watcr.", at: captionBounds)]
        }

        let extraction = try PDFTextParser.extract(from: url, recognizer: recognizer, includesPages: false)

        XCTAssertEqual(extraction.markdown, "PIER 2\n\n\(PDFFixtures.caption)")
        XCTAssertEqual(extraction.report.pdf?.pages, [page(1, .both, .recognizedText)])
    }

    /// A paragraph of embedded text above a picture of words: both are
    /// read, in the order the page shows them.
    func testParagraphAndAPictureOfWordsAreBothRead() throws {
        let url = try Self.paragraphAbovePicture(for: self)
        let recognizer = ScriptedTextRecognizer { _ in Self.timetableLines }

        let extraction = try PDFTextParser.extract(from: url, recognizer: recognizer, includesPages: false)

        XCTAssertEqual(
            extraction.markdown,
            "\(Self.paragraph.joined(separator: " "))\n\nTIMETABLE CHANGES FROM MONDAY\nEvening sailing now 21:40"
        )
        XCTAssertEqual(recognizer.requests.map(\.region), [Self.timetableRect])
        XCTAssertEqual(extraction.report.pdf?.pagesWithEmbeddedAndOCRText, [1])
    }

    /// A page OCR finds nothing in is still read, and says so.
    func testPictureWithoutWordsIsReportedAsOCRFindingNothing() throws {
        let url = try PDFFixtures.captionedPicture(for: self)

        let extraction = try PDFTextParser.extract(
            from: url, recognizer: ScriptedTextRecognizer.findingNothing(), includesPages: false
        )

        XCTAssertEqual(extraction.markdown, PDFFixtures.caption)
        XCTAssertTrue(extraction.report.isComplete)
        XCTAssertEqual(extraction.report.pdf?.pages, [page(1, .embedded, .foundNothing)])
        XCTAssertEqual(extraction.report.pdf?.summary, "Its only page has embedded text only. OCR found no text on page 1.")
    }

    // MARK: - Scans

    /// A scan with one stamped line of embedded text: the stamp no longer
    /// hides the scan, which OCR reads whole, and the stamp is not
    /// repeated where OCR read it too.
    func testScanWithAStampedLineIsReadWhole() throws {
        let stamp = "Digitized from the county archive, box 7"
        let url = try PDFFixtures.makePDF(for: self) { context, _ in
            context.draw(PDFFixtures.picture(size: PDFFixtures.letter.size), in: PDFFixtures.letter)
            PDFFixtures.drawText(stamp, size: 8, at: CGPoint(x: 72, y: 30), in: context)
        }
        let recognizer = ScriptedTextRecognizer { _ in
            [
                PDFFixtures.line("The ferry leaves the north pier at seven.", at: CGRect(x: 72, y: 700, width: 300, height: 14)),
                PDFFixtures.line(stamp, at: CGRect(x: 72, y: 28, width: 160, height: 10))
            ]
        }

        let extraction = try PDFTextParser.extract(from: url, recognizer: recognizer, includesPages: false)

        XCTAssertEqual(extraction.markdown, "The ferry leaves the north pier at seven.\n\n\(stamp)")
        XCTAssertEqual(recognizer.requests.map(\.region), [PDFFixtures.letter])
    }

    /// A searchable scan carries its OCR text over the picture, invisibly.
    /// The picture is not read again, so the text is neither repeated nor
    /// slowed down, and it reads exactly as it does without OCR.
    func testSearchableScanIsNotReadAgain() throws {
        let lines = (1...40).map { String(format: "Line %02d of the transcribed page, which the scanner's OCR layer carries.", $0) }
        let url = try PDFFixtures.makePDF(for: self) { context, _ in
            context.draw(PDFFixtures.picture(size: PDFFixtures.letter.size), in: PDFFixtures.letter)
            for (index, line) in lines.enumerated() {
                PDFFixtures.drawText(line, size: 11, at: CGPoint(x: 72, y: 730 - CGFloat(index) * 15), in: context, mode: .invisible)
            }
        }
        let recognizer = Self.misreadingEverything()

        let extraction = try PDFTextParser.extract(from: url, recognizer: recognizer, includesPages: false)

        XCTAssertEqual(recognizer.requests, [])
        XCTAssertEqual(
            extraction.markdown,
            try PDFTextParser.extract(from: url, recognizer: nil, includesPages: false).markdown
        )
        XCTAssertTrue(lines.allSatisfy(extraction.markdown.contains))
        XCTAssertEqual(extraction.report.pdf?.pages, [page(1, .embedded, .notNeeded)])
    }

    /// A page with no embedded text is read whole by OCR, within its crop
    /// box, one Markdown line per recognized line, as scanned pages always
    /// were.
    func testPageWithoutEmbeddedTextIsReadWholeWithinItsCropBox() throws {
        var pdf = RawPDF()
        let image = pdf.addStream(RawPDF.tinyImage, RawPDF.tinyImageData)
        pdf.addPage(
            "q 612 0 0 792 0 0 cm /Im1 Do Q",
            entries: "/CropBox [50 50 562 742] /Resources << /XObject << /Im1 \(image) 0 R >> >>"
        )
        let recognizer = ScriptedTextRecognizer { _ in
            [
                PDFFixtures.line("The ferry leaves at seven.", at: CGRect(x: 72, y: 700, width: 300, height: 14)),
                PDFFixtures.line("It returns by noon.", at: CGRect(x: 72, y: 680, width: 300, height: 14))
            ]
        }

        let extraction = try PDFTextParser.extract(
            from: PDFFixtures.write(pdf, for: self), recognizer: recognizer, includesPages: false
        )

        XCTAssertEqual(extraction.markdown, "The ferry leaves at seven.\nIt returns by noon.")
        XCTAssertEqual(recognizer.requests.map(\.region), [CGRect(x: 50, y: 50, width: 512, height: 692)])
        XCTAssertEqual(extraction.report.pdf?.pages, [page(1, .recognized, .recognizedText)])
    }

    // MARK: - When OCR Cannot Run

    /// Without OCR, embedded text is kept and the report says, page by
    /// page, that OCR did not run and why; the import then warns and keeps
    /// the original.
    func testWithoutOCREmbeddedTextIsKeptAndTheReportSaysWhy() throws {
        let first = try Self.paragraphAbovePicture(for: self)
        let second = try PDFFixtures.captionedPicture(for: self)
        let url = try Self.joined([first, second], for: self)

        let extraction = try PDFTextParser.extract(from: url, recognizer: nil, includesPages: false)

        XCTAssertEqual(extraction.markdown, "\(Self.paragraph.joined(separator: " "))\n\n\(PDFFixtures.caption)")
        let reason = "text recognition is not available"
        XCTAssertEqual(extraction.report.pdf?.pages, [page(1, .embedded, .couldNotRun(reason)), page(2, .embedded, .couldNotRun(reason))])
        XCTAssertEqual(extraction.report.pdf?.ocrUnavailableReason, reason)
        XCTAssertFalse(extraction.report.isComplete)
        XCTAssertEqual(extraction.report.container, "this PDF")
        XCTAssertEqual(
            extraction.report.message,
            "OCR could not run on all 2 pages, so text that appears only in their images is missing: "
                + "pages 1 and 2 (text recognition is not available)."
        )
    }

    /// A recognizer that reports it cannot run is asked once; every page
    /// after it records the same reason without asking again.
    func testUnavailableRecognizerIsAskedOnlyOnce() throws {
        let reason = "Vision has no text model here"
        let url = try Self.joined((0..<3).map { _ in try PDFFixtures.captionedPicture(for: self) }, for: self)
        let recognizer = ScriptedTextRecognizer { _ in throw PDFTextRecognitionError.unavailable(reason) }

        let extraction = try PDFTextParser.extract(from: url, recognizer: recognizer, includesPages: false)

        XCTAssertEqual(recognizer.requests.count, 1)
        XCTAssertEqual(extraction.report.pdf?.pagesWhereOCRCouldNotRun, [1, 2, 3])
        XCTAssertEqual(extraction.report.pdf?.ocrUnavailableReason, reason)
        XCTAssertEqual(extraction.markdown, Array(repeating: PDFFixtures.caption, count: 3).joined(separator: "\n\n"))
    }

    /// One picture OCR fails on does not stop the others, and each failure
    /// keeps its own reason.
    func testFailureOnOnePictureDoesNotStopTheOthers() throws {
        let url = try Self.joined((0..<3).map { _ in try PDFFixtures.captionedPicture(for: self) }, for: self)
        let recognizer = ScriptedTextRecognizer { request in
            switch request.pageNumber {
            case 1: throw PDFTextRecognitionError.failed("the picture could not be drawn")
            case 2: throw NSError(domain: "Probe", code: 7, userInfo: [NSLocalizedDescriptionKey: "The bitmap was too large."])
            default: return Self.signLines
            }
        }

        let extraction = try PDFTextParser.extract(from: url, recognizer: recognizer, includesPages: false)

        XCTAssertEqual(recognizer.requests.map(\.pageNumber), [1, 2, 3])
        XCTAssertEqual(extraction.report.pdf?.pages, [
            page(1, .embedded, .couldNotRun("the picture could not be drawn")),
            page(2, .embedded, .couldNotRun("text recognition failed: The bitmap was too large.")),
            page(3, .both, .recognizedText)
        ])
        XCTAssertNil(extraction.report.pdf?.ocrUnavailableReason)
        XCTAssertFalse(extraction.report.isComplete)
    }

    /// A PDF with no embedded text anywhere, and no OCR to read it, fails
    /// with the reason instead of claiming it holds no text.
    func testScanWithoutOCRFailsWithTheReason() throws {
        let url = try PDFFixtures.makePDF(for: self) { context, _ in
            context.draw(PDFFixtures.picture(size: PDFFixtures.letter.size, words: ["Scanned words"]), in: PDFFixtures.letter)
        }

        XCTAssertThrowsError(try PDFTextParser.extract(from: url, recognizer: nil)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "No text could be read from the PDF: it has no embedded text, and OCR could not run "
                    + "(text recognition is not available)."
            )
        }
    }

    // MARK: - Default Recognizer

    /// Callers that name no recognizer, as imports and cache rebuilds do,
    /// read pictures with the default one: Vision's in the app, which a
    /// test can replace and put back.
    func testExtractionWithoutARecognizerUsesTheDefaultOne() throws {
        XCTAssertTrue(PDFTextParser.defaultRecognizer is VisionPDFTextRecognizer)
        let url = try PDFFixtures.captionedPicture(for: self)
        let recognizer = ScriptedTextRecognizer { _ in Self.signLines }

        let markdown = try PDFFixtures.withDefaultRecognizer(recognizer) {
            try PDFTextParser.extractMarkdown(from: url)
        }
        let unavailable = try PDFFixtures.withDefaultRecognizer(nil) {
            try PDFTextParser.extract(from: url).report.pdf?.ocrUnavailableReason
        }

        XCTAssertEqual(markdown, "PIER 2\nNO MOORING\n\n\(PDFFixtures.caption)")
        XCTAssertEqual(recognizer.requests.count, 1)
        XCTAssertEqual(unavailable, "text recognition is not available")
        XCTAssertTrue(PDFTextParser.defaultRecognizer is VisionPDFTextRecognizer)
    }

    // MARK: - Line Positions

    /// The parser finds its lines again in the page's text as the ranges
    /// of the lines holding more than spaces and tabs, trimmed of them.
    func testNonBlankLineRangesSkipBlankLinesAndTrimSpaces() {
        let text = "  a\n\n \t\nbc \nd" as NSString

        XCTAssertEqual(
            PDFTextParser.nonBlankLineRanges(in: text),
            [NSRange(location: 2, length: 1), NSRange(location: 8, length: 2), NSRange(location: 12, length: 1)]
        )
        XCTAssertEqual(PDFTextParser.nonBlankLineRanges(in: "" as NSString), [])
        XCTAssertEqual(PDFTextParser.nonBlankLineRanges(in: "x\n" as NSString), [NSRange(location: 0, length: 1)])
    }

    // MARK: - With Vision

    /// The three acceptance pages read by Vision itself: the title kept,
    /// the picture's words before its caption, and the paragraph before the
    /// words of the picture below it. Skips, saying why, where Vision
    /// cannot run in the test host.
    func testVisionReadsTheAcceptancePages() throws {
        let title = try PDFFixtures.makePDF(for: self) { context, _ in
            PDFFixtures.drawText("Ballast", size: 36, at: CGPoint(x: 230, y: 500), in: context)
        }
        let captioned = try PDFFixtures.captionedPicture(for: self, words: ["PIER 2", "NO MOORING"])
        let mixed = try Self.paragraphAbovePicture(for: self)

        XCTAssertEqual(try extractWithVision(title).markdown, "Ballast")

        let captionedMarkdown = try extractWithVision(captioned).markdown
        XCTAssertTrue(captionedMarkdown.hasSuffix("\n\n\(PDFFixtures.caption)"), captionedMarkdown)
        XCTAssertEqual(captionedMarkdown.components(separatedBy: PDFFixtures.caption).count, 2, captionedMarkdown)
        XCTAssertEqual(
            PDFPageTextMerger.normalized(captionedMarkdown),
            PDFPageTextMerger.normalized("PIER 2 NO MOORING \(PDFFixtures.caption)")
        )

        let mixedMarkdown = try extractWithVision(mixed).markdown
        XCTAssertTrue(mixedMarkdown.hasPrefix("\(Self.paragraph.joined(separator: " "))\n\n"), mixedMarkdown)
        XCTAssertEqual(
            PDFPageTextMerger.normalized(mixedMarkdown),
            PDFPageTextMerger.normalized(Self.paragraph.joined() + "TIMETABLE CHANGES FROM MONDAY Evening sailing now 21:40")
        )
    }

    // MARK: - Fixtures

    /// The words OCR finds on the captioned picture's sign, inside it.
    private static let signLines = [
        PDFFixtures.line("PIER 2", at: CGRect(x: 110, y: 640, width: 100, height: 30)),
        PDFFixtures.line("NO MOORING", at: CGRect(x: 110, y: 600, width: 200, height: 30))
    ]
    /// The embedded paragraph above the timetable picture, line by line.
    private static let paragraph = [
        "The ferry leaves the north pier at seven and returns by noon.",
        "Passengers with bicycles board after the vans and keep to the",
        "painted lane on the lower deck. Tickets bought on board cost a",
        "little more than those bought at the kiosk beside the ramp."
    ]
    /// Where the timetable picture is drawn, below the paragraph.
    private static let timetableRect = CGRect(x: 72, y: 250, width: 468, height: 324)
    /// The words OCR finds on the timetable picture, inside it.
    private static let timetableLines = [
        PDFFixtures.line("TIMETABLE CHANGES FROM MONDAY", at: CGRect(x: 109, y: 492, width: 377, height: 16)),
        PDFFixtures.line("Evening sailing now 21:40", at: CGRect(x: 109, y: 455, width: 250, height: 23))
    ]

    /// A page with the embedded paragraph above a picture of the timetable.
    private static func paragraphAbovePicture(for test: XCTestCase) throws -> URL {
        try PDFFixtures.makePDF(for: test) { context, _ in
            for (index, line) in paragraph.enumerated() {
                PDFFixtures.drawText(line, size: 12, at: CGPoint(x: 72, y: 700 - CGFloat(index) * 16), in: context)
            }
            let picture = PDFFixtures.picture(
                size: timetableRect.size, words: ["TIMETABLE CHANGES FROM MONDAY", "Evening sailing now 21:40"], fontSize: 20
            )
            context.draw(picture, in: timetableRect)
        }
    }

    /// One PDF holding the pages of `urls`, in order.
    private static func joined(_ urls: [URL], for test: XCTestCase) throws -> URL {
        let documents = try urls.map { try XCTUnwrap(PDFDocument(url: $0)) }
        return try PDFFixtures.makePDF(for: test, pages: documents.count) { context, index in
            guard let page = documents[index].page(at: 0)?.pageRef else { return }
            context.drawPDFPage(page)
        }
    }

    /// A recognizer whose every answer is a misreading over the whole
    /// region, so any use of it shows in the text.
    private static func misreadingEverything() -> ScriptedTextRecognizer {
        ScriptedTextRecognizer { request in [PDFFixtures.line("Ballasi", at: request.region)] }
    }

    /// A page's diagnosis.
    private func page(
        _ number: Int,
        _ source: PDFPageDiagnosis.TextSource,
        _ recognition: PDFPageDiagnosis.Recognition
    ) -> PDFPageDiagnosis {
        PDFPageDiagnosis(pageNumber: number, source: source, recognition: recognition)
    }

    /// The PDF at `url` read with Vision, or a skip naming why Vision
    /// cannot run in this test host.
    private func extractWithVision(_ url: URL) throws -> PDFTextParser.Extraction {
        let extraction = try PDFTextParser.extract(from: url, includesPages: false)
        if let reason = extraction.report.pdf?.ocrUnavailableReason {
            throw XCTSkip("Vision text recognition is unavailable in this test host: \(reason)")
        }
        return extraction
    }
}
