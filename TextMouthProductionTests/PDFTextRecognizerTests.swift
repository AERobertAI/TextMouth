import CoreGraphics
import PDFKit
import Vision
import XCTest
@testable import TextMouth

/// Text recognition in one region of a PDF page: drawing the region upright
/// at a resolution suited to OCR, mapping what Vision finds back onto the
/// page, and telling an OCR that cannot run apart from one that failed.
final class PDFTextRecognizerTests: XCTestCase {

    // MARK: - Rendering

    /// The quarter turns are exact: a point on the page lands where the
    /// page, turned clockwise as shown, puts it.
    func testUprightTransformTurnsByQuarterTurnsExactly() {
        let point = CGPoint(x: 10, y: 20)

        XCTAssertEqual(point.applying(PDFRegionRendering.uprightTransform(forRotation: 0)), CGPoint(x: 10, y: 20))
        XCTAssertEqual(point.applying(PDFRegionRendering.uprightTransform(forRotation: 90)), CGPoint(x: 20, y: -10))
        XCTAssertEqual(point.applying(PDFRegionRendering.uprightTransform(forRotation: 180)), CGPoint(x: -10, y: -20))
        XCTAssertEqual(point.applying(PDFRegionRendering.uprightTransform(forRotation: 270)), CGPoint(x: -20, y: 10))
        XCTAssertEqual(point.applying(PDFRegionRendering.uprightTransform(forRotation: -90)), CGPoint(x: -20, y: 10))
        XCTAssertEqual(point.applying(PDFRegionRendering.uprightTransform(forRotation: 450)), CGPoint(x: 20, y: -10))
    }

    /// However the page is turned, the whole picture maps back onto the
    /// region it was drawn from, so recognized lines land where they are.
    func testWholePictureMapsBackOntoItsRegionAtEveryRotation() throws {
        let region = CGRect(x: 130, y: 220, width: 300, height: 120)
        for rotation in [0, 90, 180, 270] {
            var pdf = RawPDF()
            pdf.addPage("", entries: "/Rotate \(rotation)", mediaBox: CGRect(x: 100, y: 100, width: 612, height: 792))
            let page = try XCTUnwrap(CGPDFDocument(PDFFixtures.write(pdf, for: self) as CFURL)?.page(at: 1))
            let rendering = try XCTUnwrap(PDFRegionRendering(page: page, region: region))

            let mapped = rendering.pageRect(forNormalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            // The picture is a whole number of pixels, so it may reach up
            // to a pixel (a quarter point here) past the region.
            XCTAssertEqual(mapped.minX, region.minX, accuracy: 0.5, "rotation \(rotation)")
            XCTAssertEqual(mapped.minY, region.minY, accuracy: 0.5, "rotation \(rotation)")
            XCTAssertEqual(mapped.width, region.width, accuracy: 0.5, "rotation \(rotation)")
            XCTAssertEqual(mapped.height, region.height, accuracy: 0.5, "rotation \(rotation)")

            // A page turned a quarter is drawn with its sides exchanged.
            let isQuarterTurn = rotation % 180 != 0
            let wide = CGFloat(rendering.image.width) > CGFloat(rendering.image.height)
            XCTAssertEqual(wide, !isQuarterTurn, "rotation \(rotation)")
        }
    }

    /// A full page is drawn at about 2 pixels per point, a small region is
    /// enlarged up to 4, and nothing is drawn longer than the limit (here
    /// a long, thin strip of a poster, so the picture stays small).
    func testRenderingScaleSuitsTheRegion() throws {
        var pdf = RawPDF()
        pdf.addPage("")
        pdf.addPage("", mediaBox: CGRect(x: 0, y: 0, width: 5_000, height: 5_000))
        let document = try XCTUnwrap(CGPDFDocument(PDFFixtures.write(pdf, for: self) as CFURL))
        let letterPage = try XCTUnwrap(document.page(at: 1))
        let posterPage = try XCTUnwrap(document.page(at: 2))

        let fullPage = try XCTUnwrap(PDFRegionRendering(page: letterPage, region: PDFFixtures.letter))
        XCTAssertEqual(CGFloat(fullPage.image.height) / 792, 2, accuracy: 0.05)

        let small = try XCTUnwrap(PDFRegionRendering(page: letterPage, region: CGRect(x: 0, y: 0, width: 100, height: 40)))
        XCTAssertEqual(small.image.width, 400)

        let poster = try XCTUnwrap(PDFRegionRendering(page: posterPage, region: CGRect(x: 0, y: 0, width: 4_500, height: 100)))
        XCTAssertEqual(CGFloat(poster.image.width), PDFRegionRendering.maximumSide, accuracy: 1)
    }

    /// An empty region has nothing to draw.
    func testEmptyRegionIsNotDrawn() throws {
        var pdf = RawPDF()
        pdf.addPage("")
        let page = try XCTUnwrap(CGPDFDocument(PDFFixtures.write(pdf, for: self) as CFURL)?.page(at: 1))

        XCTAssertNil(PDFRegionRendering(page: page, region: CGRect(x: 10, y: 10, width: 0, height: 50)))
    }

    // MARK: - Errors

    /// Vision's codes for a request it cannot run at all mean OCR is
    /// unavailable; any other error means this region failed.
    func testVisionErrorsAreSortedIntoUnavailableAndFailed() {
        let unsupported = NSError(domain: VNErrorDomain, code: VNErrorCode.unsupportedRevision.rawValue)
        let internalError = NSError(domain: VNErrorDomain, code: VNErrorCode.internalError.rawValue)
        let elsewhere = NSError(domain: NSCocoaErrorDomain, code: VNErrorCode.unsupportedRevision.rawValue)

        guard case .unavailable(let reason) = VisionPDFTextRecognizer.recognitionError(for: unsupported) else {
            return XCTFail("An unsupported revision should make OCR unavailable")
        }
        XCTAssertTrue(reason.hasPrefix("text recognition failed: "), reason)
        guard case .failed = VisionPDFTextRecognizer.recognitionError(for: internalError) else {
            return XCTFail("An internal error should fail this region only")
        }
        guard case .failed = VisionPDFTextRecognizer.recognitionError(for: elsewhere) else {
            return XCTFail("Only Vision's own codes can make OCR unavailable")
        }
    }

    /// A recognition error's reason is the words it carries.
    func testRecognitionErrorReasonIsItsWords() {
        XCTAssertEqual(PDFTextRecognitionError.unavailable("no model").reason, "no model")
        XCTAssertEqual(PDFTextRecognitionError.failed("could not draw").reason, "could not draw")
    }

    // MARK: - Vision

    /// Words that exist only as pixels in a picture are read, in order, and
    /// placed on the page inside the picture.
    func testVisionReadsWordsInAPictureAndPlacesThemInsideIt() throws {
        let pictureRect = CGRect(x: 72, y: 250, width: 468, height: 324)
        let url = try PDFFixtures.makePDF(for: self) { context, _ in
            let picture = PDFFixtures.picture(
                size: pictureRect.size, words: ["TIMETABLE CHANGES", "Evening sailing 21:40"], fontSize: 30
            )
            context.draw(picture, in: pictureRect)
        }
        let (document, page) = try PDFFixtures.firstPage(of: url)

        let lines = try recognizeOrSkip(pictureRect, of: page)

        withExtendedLifetime(document) {}
        XCTAssertEqual(lines.map { $0.text.lowercased() }, ["timetable changes", "evening sailing 21:40"])
        for line in lines {
            XCTAssertTrue(pictureRect.insetBy(dx: -2, dy: -2).contains(line.bounds), "\(line)")
        }
    }

    /// On a page shown turned a quarter, a line drawn to read upright is
    /// read, and placed where the page's own text for it is.
    func testVisionPlacesLinesCorrectlyOnATurnedPage() throws {
        var pdf = RawPDF()
        let font = pdf.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        pdf.addPage(
            "BT /F1 36 Tf 0 1 -1 0 300 200 Tm (Sideways title) Tj ET",
            entries: "/Rotate 90 /Resources << /Font << /F1 \(font) 0 R >> >>"
        )
        let (document, page) = try PDFFixtures.firstPage(of: PDFFixtures.write(pdf, for: self))
        let embedded = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 14))?.bounds(for: page))

        let lines = try recognizeOrSkip(page.bounds(for: .mediaBox), of: page)

        withExtendedLifetime(document) {}
        let line = try XCTUnwrap(lines.first)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(line.text.lowercased(), "sideways title")
        XCTAssertGreaterThan(sharedFraction(of: line.bounds, with: embedded), 0.6, "\(line.bounds) vs \(embedded)")
    }

    // MARK: - Helpers

    /// The share of `rect`'s area that `other` also covers.
    private func sharedFraction(of rect: CGRect, with other: CGRect) -> CGFloat {
        let overlap = rect.intersection(other)
        guard !overlap.isNull, rect.width * rect.height > 0 else { return 0 }
        return overlap.width * overlap.height / (rect.width * rect.height)
    }

    /// What Vision reads in `region` of `page`, or a skip naming why
    /// Vision cannot run in this test host. A region that Vision fails on
    /// is a test failure.
    private func recognizeOrSkip(_ region: CGRect, of page: PDFPage) throws -> [PDFRecognizedLine] {
        do {
            return try VisionPDFTextRecognizer().recognizeLines(in: region, of: page)
        } catch PDFTextRecognitionError.unavailable(let reason) {
            throw XCTSkip("Vision text recognition is unavailable in this test host: \(reason)")
        }
    }
}
