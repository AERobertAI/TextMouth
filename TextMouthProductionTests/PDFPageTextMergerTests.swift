import CoreGraphics
import XCTest
@testable import TextMouth

/// Merging what OCR read in a page's pictures with the page's embedded
/// text: nothing embedded is repeated, and what OCR adds goes where it
/// appears, between whole paragraphs.
final class PDFPageTextMergerTests: XCTestCase {

    // MARK: - Normalizing

    /// Text is compared on letters and digits alone, with case, accents,
    /// widths, Markdown emphasis, spacing, and punctuation folded away.
    func testNormalizedTextKeepsOnlyFoldedLettersAndDigits() {
        XCTAssertEqual(PDFPageTextMerger.normalized("Été, déjà vu!"), "etedejavu")
        XCTAssertEqual(PDFPageTextMerger.normalized("**Bold** text 21:40"), "boldtext2140")
        XCTAssertEqual(PDFPageTextMerger.normalized("Ｆｕｌｌ ｗｉｄｔｈ"), "fullwidth")
        XCTAssertEqual(PDFPageTextMerger.normalized("Ὀδύσσεια"), "οδυσσεια")
        XCTAssertEqual(PDFPageTextMerger.normalized("— • —"), "")
    }

    // MARK: - Repeats

    /// An OCR line that matches an embedded line once both are normalized
    /// is a repeat wherever it was found.
    func testLineMatchingAnEmbeddedLineIsDropped() {
        let caption = body("Plate 4. The north pier at low water.")
        let result = merge(
            [caption], at: [rect(y: 380)],
            recognized: [PDFFixtures.line("PLATE 4 THE NORTH PIER AT LOW WATER", at: rect(y: 600))]
        )

        XCTAssertEqual(result, PDFPageTextMerger.Result(markdown: "Plate 4. The north pier at low water.", addedLineCount: 0))
    }

    /// A phrase of the embedded text that OCR broke into lines differently
    /// is a repeat too.
    func testLineRepeatingAPhraseAcrossEmbeddedLinesIsDropped() {
        let lines = [body("The ferry leaves the north pier at seven"), body("and returns by noon.")]
        let result = merge(
            lines, at: [rect(y: 700), rect(y: 686)],
            recognized: [PDFFixtures.line("north pier at seven and returns", at: rect(y: 300))]
        )

        XCTAssertEqual(result.addedLineCount, 0)
    }

    /// A short word that also occurs inside an embedded sentence is not a
    /// repeat: only a whole line, or a long phrase, counts.
    func testShortWordFoundInsideASentenceIsKept() {
        let result = merge(
            [body("Turn left at the exit sign.")], at: [rect(y: 700)],
            recognized: [PDFFixtures.line("EXIT", at: rect(y: 400, width: 60))]
        )

        XCTAssertEqual(result, PDFPageTextMerger.Result(markdown: "Turn left at the exit sign.\n\nEXIT", addedLineCount: 1))
    }

    /// OCR reading text that sits where embedded text sits is a repeat,
    /// however it misreads it; a line only grazing embedded text is not.
    func testLineWhereEmbeddedTextSitsIsDroppedHoweverMisread() {
        let title = CGRect(x: 230, y: 494, width: 115, height: 31)
        let result = merge(
            [body("Ballast")], at: [title],
            recognized: [
                PDFFixtures.line("Ballasi", at: title.offsetBy(dx: -3, dy: 0)),
                PDFFixtures.line("Harbour Press", at: CGRect(x: 230, y: 460, width: 115, height: 40))
            ]
        )

        // The second line shares 6 of its 40 points of height with the title.
        XCTAssertEqual(result, PDFPageTextMerger.Result(markdown: "Ballast\n\nHarbour Press", addedLineCount: 1))
    }

    /// A line with no letters or digits has nothing to read.
    func testLineWithoutLettersOrDigitsIsDropped() {
        let result = merge(
            [body("Contents.")], at: [rect(y: 700)],
            recognized: [PDFFixtures.line("— • —", at: rect(y: 300))]
        )

        XCTAssertEqual(result.addedLineCount, 0)
    }

    // MARK: - Placement

    /// Lines go before the first paragraph that begins below them: a
    /// picture's words between the text above it and its caption below.
    func testLinesGoBeforeTheFirstParagraphBelowThem() {
        let result = merge(
            [body("A paragraph at the top of the page."), body("Plate 4. The north pier at low water.")],
            at: [rect(y: 700), rect(y: 380)],
            recognized: [
                PDFFixtures.line("PIER 2", at: CGRect(x: 110, y: 520, width: 80, height: 30)),
                PDFFixtures.line("NO MOORING", at: CGRect(x: 110, y: 470, width: 160, height: 30))
            ]
        )

        XCTAssertEqual(
            result.markdown,
            "A paragraph at the top of the page.\n\nPIER 2\nNO MOORING\n\nPlate 4. The north pier at low water."
        )
        XCTAssertEqual(result.addedLineCount, 2)
    }

    /// A paragraph is never split: a line beside its middle follows it.
    func testParagraphsAreNeverSplit() {
        let lines = [
            body("The ferry leaves the north pier at seven and"),
            body("returns by noon, though in winter that"),
            body("boat may leave sooner than the board says.")
        ]
        let result = merge(
            lines, at: [rect(y: 700), rect(y: 686), rect(y: 672)],
            recognized: [PDFFixtures.line("TIDE TABLE", at: CGRect(x: 480, y: 676, width: 80, height: 14))]
        )

        XCTAssertEqual(
            result.markdown,
            "The ferry leaves the north pier at seven and returns by noon, though in winter that "
                + "boat may leave sooner than the board says.\n\nTIDE TABLE"
        )
    }

    /// At the same height, what is further left is read first.
    func testLinesAtTheSameHeightAreReadLeftToRight() {
        let result = merge(
            [body("Plate 4. The north pier at low water.")],
            at: [CGRect(x: 300, y: 500, width: 250, height: 12)],
            recognized: [
                PDFFixtures.line("PIER 2", at: CGRect(x: 90, y: 498, width: 100, height: 14)),
                PDFFixtures.line("NO MOORING", at: CGRect(x: 560, y: 498, width: 40, height: 14))
            ]
        )

        XCTAssertEqual(result.markdown, "PIER 2\n\nPlate 4. The north pier at low water.\n\nNO MOORING")
    }

    /// Without the embedded lines' positions, OCR text follows all of the
    /// embedded text, and is still never a repeat.
    func testWithoutPositionsOCRTextFollowsTheEmbeddedText() {
        let lines = [body("See the plates below."), body("Plate 4. The north pier at low water.")]
        let recognized = [
            PDFFixtures.line("PIER 2", at: rect(y: 750)),
            PDFFixtures.line("Plate 4 the north pier at low water", at: rect(y: 100))
        ]

        let unknown = merge(lines, at: [], recognized: recognized)
        let partlyKnown = PDFPageTextMerger.merge(
            lines: lines, lineBounds: [rect(y: 700), nil], recognized: recognized, rotation: 0
        )

        XCTAssertEqual(unknown.markdown, "See the plates below.\n\nPlate 4. The north pier at low water.\n\nPIER 2")
        XCTAssertEqual(partlyKnown.markdown, unknown.markdown)
    }

    /// On a page shown turned a quarter, "above" is what is above as shown:
    /// the same lines are read in the opposite order unturned.
    func testTurnedPageIsReadInTheOrderItIsShown() {
        let paragraph = [body("The evening crossing leaves from berth four.")]
        let paragraphBounds = [CGRect(x: 300, y: 100, width: 12, height: 400)]
        let sign = [PDFFixtures.line("BERTH FOUR", at: CGRect(x: 100, y: 100, width: 14, height: 200))]

        let turned = PDFPageTextMerger.merge(lines: paragraph, lineBounds: paragraphBounds, recognized: sign, rotation: 90)
        let upright = PDFPageTextMerger.merge(lines: paragraph, lineBounds: paragraphBounds, recognized: sign, rotation: 0)

        XCTAssertEqual(turned.markdown, "BERTH FOUR\n\nThe evening crossing leaves from berth four.")
        XCTAssertEqual(upright.markdown, "The evening crossing leaves from berth four.\n\nBERTH FOUR")
    }

    /// Headings keep the layout the paragraph joiner gives them, and when
    /// OCR adds nothing the page's Markdown is exactly what it was.
    func testHeadingsKeepTheirLayoutAndNothingAddedChangesNothing() {
        let lines = [
            PDFTextParser.TextLine(text: "Harbour Notes", isHeading: true, headingLevel: 1, fontSize: 24),
            body("Ferries leave on the hour.")
        ]
        let bounds = [rect(y: 740, height: 24), rect(y: 700)]

        let merged = merge(lines, at: bounds, recognized: [PDFFixtures.line("NO MOORING", at: rect(y: 400))])
        let unchanged = merge(lines, at: bounds, recognized: [])

        XCTAssertEqual(merged.markdown, "# Harbour Notes\n\n\nFerries leave on the hour.\n\nNO MOORING")
        XCTAssertEqual(unchanged, PDFPageTextMerger.Result(
            markdown: PDFTextParser.joinLinesIntoParagraphs(lines), addedLineCount: 0
        ))
    }

    // MARK: - Helpers

    /// A body-text line in 12-point type.
    private func body(_ text: String) -> PDFTextParser.TextLine {
        PDFTextParser.TextLine(text: text, isHeading: false, headingLevel: 0, fontSize: 12)
    }

    /// A line's bounds on a letter page, starting at the left margin.
    private func rect(y: CGFloat, width: CGFloat = 400, height: CGFloat = 12) -> CGRect {
        CGRect(x: 72, y: y, width: width, height: height)
    }

    /// `lines` at `bounds` on an unturned page merged with `recognized`.
    private func merge(
        _ lines: [PDFTextParser.TextLine],
        at bounds: [CGRect],
        recognized: [PDFRecognizedLine]
    ) -> PDFPageTextMerger.Result {
        PDFPageTextMerger.merge(lines: lines, lineBounds: bounds, recognized: recognized, rotation: 0)
    }
}
