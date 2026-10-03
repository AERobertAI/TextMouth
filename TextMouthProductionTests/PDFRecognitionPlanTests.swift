import CoreGraphics
import XCTest
@testable import TextMouth

/// Which parts of a page that has embedded text OCR should read: the
/// pictures that may hold more text, shown on the page, legible, not
/// already transcribed, each read once, in the order the page shows them.
final class PDFRecognitionPlanTests: XCTestCase {
    private let page = PDFFixtures.letter

    // MARK: - What Is Read

    /// Only the part of a picture inside the shown page is read.
    func testPictureIsReadOnlyWhereThePageShowsIt() {
        let regions = plan(images: [CGRect(x: 400, y: 600, width: 400, height: 400)])

        XCTAssertEqual(regions, [CGRect(x: 400, y: 600, width: 212, height: 192)])
    }

    /// A picture largely covered by embedded text is a background or a
    /// scan with its own text layer, and is not read again; a picture with
    /// only a stamp or a caption over it is read.
    func testPictureCoveredByEmbeddedTextIsNotRead() {
        let scan = page
        let fortyLines = (0..<40).map { CGRect(x: 72, y: 720 - CGFloat($0) * 15, width: 400, height: 11) }
        let stamp = [CGRect(x: 72, y: 30, width: 200, height: 8)]

        XCTAssertEqual(plan(images: [scan], lines: fortyLines), [])
        XCTAssertEqual(plan(images: [scan], lines: stamp), [scan])
    }

    /// Bullets, rules, and icons are too small to hold a legible line.
    func testRegionsTooSmallToHoldALineAreNotRead() {
        let icon = CGRect(x: 72, y: 700, width: 10, height: 10)
        let rule = CGRect(x: 72, y: 600, width: 400, height: 4)
        let badge = CGRect(x: 72, y: 500, width: 30, height: 30)
        let label = CGRect(x: 72, y: 400, width: 100, height: 20)

        XCTAssertEqual(plan(images: [icon, rule, badge, label]), [label])
    }

    // MARK: - Merging

    /// A scan stored as strips is read whole, and overlapping pictures are
    /// read once.
    func testTouchingAndOverlappingPicturesAreReadAsOne() {
        let strips = (0..<4).map { CGRect(x: 0, y: CGFloat($0) * 198, width: 612, height: 198) }
        let photo = CGRect(x: 72, y: 72, width: 200, height: 200)
        let inset = CGRect(x: 150, y: 150, width: 200, height: 200)

        XCTAssertEqual(plan(images: strips), [page])
        XCTAssertEqual(plan(images: [photo, inset]), [CGRect(x: 72, y: 72, width: 278, height: 278)])
    }

    /// A union can grow to touch regions neither of its parts touched, and
    /// then absorbs them too.
    func testMergingContinuesUntilNothingTouches() {
        let left = CGRect(x: 0, y: 0, width: 10, height: 10)
        let right = CGRect(x: 30, y: 30, width: 10, height: 10)
        let bridge = CGRect(x: 5, y: 5, width: 30, height: 30)

        XCTAssertEqual(PDFRecognitionPlan.mergedTouching([left, right, bridge]), [CGRect(x: 0, y: 0, width: 40, height: 40)])
        XCTAssertEqual(PDFRecognitionPlan.mergedTouching([left, right]), [left, right])
    }

    /// A page strewn with pictures is read as one region holding them all.
    func testManyPicturesAreReadAsOneRegion() {
        let labels = (0..<13).map { CGRect(x: 40, y: 40 + CGFloat($0) * 50, width: 100, height: 20) }

        XCTAssertEqual(plan(images: labels), [CGRect(x: 40, y: 40, width: 100, height: 620)])
    }

    // MARK: - Order

    /// Regions are read top to bottom as the page is shown, which on a page
    /// turned a quarter clockwise is left to right in its own coordinates.
    func testRegionsAreReadInTheOrderThePageShowsThem() {
        let topRight = CGRect(x: 400, y: 600, width: 100, height: 100)
        let bottomLeft = CGRect(x: 72, y: 100, width: 100, height: 100)

        XCTAssertEqual(plan(images: [bottomLeft, topRight]), [topRight, bottomLeft])
        // Turned a quarter, a smaller x is higher on the shown page.
        XCTAssertEqual(plan(images: [topRight, bottomLeft], rotation: 90), [bottomLeft, topRight])
    }

    // MARK: - Geometry

    /// Coverage is the share of a rectangle's area that others cover,
    /// capped at all of it, and zero for a rectangle with no area.
    func testCoveredFraction() {
        let square = CGRect(x: 0, y: 0, width: 10, height: 10)

        XCTAssertEqual(PDFPageGeometry.coveredFraction(of: square, by: [CGRect(x: 5, y: 0, width: 10, height: 10)]), 0.5)
        XCTAssertEqual(PDFPageGeometry.coveredFraction(of: square, by: [square, square]), 1)
        XCTAssertEqual(PDFPageGeometry.coveredFraction(of: square, by: [CGRect(x: 20, y: 20, width: 5, height: 5)]), 0)
        XCTAssertEqual(PDFPageGeometry.coveredFraction(of: .zero, by: [square]), 0)
    }

    // MARK: - Helpers

    /// The regions planned for a letter page drawing `images`, with
    /// embedded text lines at `lines`.
    private func plan(images: [CGRect], lines: [CGRect] = [], rotation: Int = 0) -> [CGRect] {
        PDFRecognitionPlan.regions(images: images, visibleBounds: page, embeddedLines: lines, rotation: rotation)
    }
}
