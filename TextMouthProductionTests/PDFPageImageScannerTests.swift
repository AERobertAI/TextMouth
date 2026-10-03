import CoreGraphics
import PDFKit
import XCTest
@testable import TextMouth

/// Finding where a PDF page draws its images from the page's content
/// stream: every way of placing an image, and the matrices that place it.
final class PDFPageImageScannerTests: XCTestCase {

    // MARK: - Ways of Placing an Image

    /// An image Quartz draws into a PDF is found exactly where it was drawn.
    func testQuartzImageIsFoundWhereItWasDrawn() throws {
        let url = try PDFFixtures.makePDF(for: self) { context, _ in
            context.draw(PDFFixtures.picture(size: CGSize(width: 20, height: 10)), in: CGRect(x: 72, y: 250, width: 468, height: 324))
        }

        XCTAssertEqual(try imageRects(inPDFAt: url), [CGRect(x: 72, y: 250, width: 468, height: 324)])
    }

    /// A page of text alone draws no images.
    func testPageOfTextHasNoImages() throws {
        let url = try PDFFixtures.makePDF(for: self) { context, _ in
            PDFFixtures.drawText("Nothing here but words.", size: 12, at: CGPoint(x: 72, y: 700), in: context)
        }

        XCTAssertEqual(try imageRects(inPDFAt: url), [])
    }

    /// An image XObject fills the unit square under the current matrix.
    func testImageXObjectFillsTheUnitSquareUnderTheMatrix() throws {
        var pdf = RawPDF()
        let image = pdf.addStream(RawPDF.tinyImage, RawPDF.tinyImageData)
        pdf.addPage("q 200 0 0 100 50 600 cm /Im1 Do Q", entries: "/Resources << /XObject << /Im1 \(image) 0 R >> >>")

        XCTAssertEqual(try imageRects(in: pdf), [CGRect(x: 50, y: 600, width: 200, height: 100)])
    }

    /// An inline image (`BI` … `ID` … `EI`) is found like an XObject.
    func testInlineImageIsFound() throws {
        var pdf = RawPDF()
        pdf.addPage("q 80 0 0 40 400 400 cm BI /W 2 /H 2 /CS /G /BPC 8 /F /AHx ID 00FF00FF> EI Q")

        XCTAssertEqual(try imageRects(in: pdf), [CGRect(x: 400, y: 400, width: 80, height: 40)])
    }

    // MARK: - Forms

    /// An image inside a form XObject is placed by the form's `/Matrix`
    /// and then by the matrix the form was drawn under.
    func testImageInsideFormIsPlacedByTheFormMatrix() throws {
        var pdf = RawPDF()
        let image = pdf.addStream(RawPDF.tinyImage, RawPDF.tinyImageData)
        let form = pdf.addStream(
            "/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Matrix [1 0 0 1 10 10] "
                + "/Resources << /XObject << /Im1 \(image) 0 R >> >>",
            "q 100 0 0 50 0 0 cm /Im1 Do Q"
        )
        pdf.addPage("q 1 0 0 1 300 100 cm /Fm1 Do Q", entries: "/Resources << /XObject << /Fm1 \(form) 0 R >> >>")

        XCTAssertEqual(try imageRects(in: pdf), [CGRect(x: 310, y: 110, width: 100, height: 50)])
    }

    /// A form without resources of its own finds its image among the
    /// resources of the page that draws it, as older PDFs expect.
    func testFormWithoutResourcesUsesThePagesResources() throws {
        var pdf = RawPDF()
        let image = pdf.addStream(RawPDF.tinyImage, RawPDF.tinyImageData)
        let form = pdf.addStream("/Type /XObject /Subtype /Form /BBox [0 0 200 200]", "q 60 0 0 30 0 0 cm /Im1 Do Q")
        pdf.addPage(
            "q 1 0 0 1 300 300 cm /Fm2 Do Q",
            entries: "/Resources << /XObject << /Im1 \(image) 0 R /Fm2 \(form) 0 R >> >>"
        )

        XCTAssertEqual(try imageRects(in: pdf), [CGRect(x: 300, y: 300, width: 60, height: 30)])
    }

    /// Forms inside forms compose their matrices from the inside out.
    func testNestedFormsComposeTheirMatrices() throws {
        var pdf = RawPDF()
        let image = pdf.addStream(RawPDF.tinyImage, RawPDF.tinyImageData)
        let inner = pdf.addStream(
            "/Type /XObject /Subtype /Form /BBox [0 0 500 500] /Resources << /XObject << /Im1 \(image) 0 R >> >>",
            "q 10 0 0 10 0 0 cm /Im1 Do Q"
        )
        let outer = pdf.addStream(
            "/Type /XObject /Subtype /Form /BBox [0 0 500 500] /Matrix [2 0 0 2 0 0] "
                + "/Resources << /XObject << /Fm4 \(inner) 0 R >> >>",
            "q 1 0 0 1 10 0 cm /Fm4 Do Q"
        )
        pdf.addPage("q 1 0 0 1 100 100 cm /Fm3 Do Q", entries: "/Resources << /XObject << /Fm3 \(outer) 0 R >> >>")

        // 10 by 10 at (10, 0) in the outer form, doubled, then moved by (100, 100).
        XCTAssertEqual(try imageRects(in: pdf), [CGRect(x: 120, y: 100, width: 20, height: 20)])
    }

    /// A damaged file whose form draws itself is entered only as deep as
    /// the limit allows, so the scan ends, with one image per level.
    func testFormThatDrawsItselfStopsAtTheDepthLimit() throws {
        var pdf = RawPDF()
        let image = pdf.addStream(RawPDF.tinyImage, RawPDF.tinyImageData)
        let form = pdf.nextObjectNumber
        pdf.addStream(
            "/Type /XObject /Subtype /Form /BBox [0 0 500 500] "
                + "/Resources << /XObject << /Fm5 \(form) 0 R /Im1 \(image) 0 R >> >>",
            "/Fm5 Do q 5 0 0 5 300 300 cm /Im1 Do Q"
        )
        pdf.addPage("/Fm5 Do", entries: "/Resources << /XObject << /Fm5 \(form) 0 R >> >>")

        let rects = try imageRects(in: pdf)
        XCTAssertEqual(rects.count, PDFPageImageScanner.maximumFormDepth)
        XCTAssertTrue(rects.allSatisfy { $0 == CGRect(x: 300, y: 300, width: 5, height: 5) }, "\(rects)")
    }

    // MARK: - Matrices

    /// `Q` restores the matrix `q` saved, and an unbalanced `Q` changes
    /// nothing.
    func testSaveAndRestoreScopeTheMatrix() throws {
        var pdf = RawPDF()
        let image = pdf.addStream(RawPDF.tinyImage, RawPDF.tinyImageData)
        pdf.addPage(
            "q 2 0 0 2 0 0 cm Q Q q 50 0 0 50 10 10 cm /Im1 Do Q",
            entries: "/Resources << /XObject << /Im1 \(image) 0 R >> >>"
        )

        XCTAssertEqual(try imageRects(in: pdf), [CGRect(x: 10, y: 10, width: 50, height: 50)])
    }

    /// An image turned by its matrix is reported as the upright rectangle
    /// holding it.
    func testTurnedImageIsReportedAsTheRectangleHoldingIt() throws {
        var pdf = RawPDF()
        let image = pdf.addStream(RawPDF.tinyImage, RawPDF.tinyImageData)
        // A quarter turn: the unit square's corners land at (300, 300),
        // (300, 350), (200, 300), and (200, 350).
        pdf.addPage("q 0 50 -100 0 300 300 cm /Im1 Do Q", entries: "/Resources << /XObject << /Im1 \(image) 0 R >> >>")

        XCTAssertEqual(try imageRects(in: pdf), [CGRect(x: 200, y: 300, width: 100, height: 50)])
    }

    /// An image squeezed to no area shows nothing and is not reported.
    func testImageWithNoAreaIsIgnored() throws {
        var pdf = RawPDF()
        let image = pdf.addStream(RawPDF.tinyImage, RawPDF.tinyImageData)
        pdf.addPage("q 0 0 0 0 100 100 cm /Im1 Do Q", entries: "/Resources << /XObject << /Im1 \(image) 0 R >> >>")

        XCTAssertEqual(try imageRects(in: pdf), [])
    }

    // MARK: - Helpers

    /// The image rectangles on the first page of `pdf`.
    private func imageRects(in pdf: RawPDF) throws -> [CGRect] {
        try imageRects(inPDFAt: PDFFixtures.write(pdf, for: self))
    }

    /// The image rectangles on the first page of the PDF at `url`.
    private func imageRects(inPDFAt url: URL) throws -> [CGRect] {
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        let page = try XCTUnwrap(document.page(at: 1))
        return PDFPageImageScanner.imageRects(on: page)
    }
}
