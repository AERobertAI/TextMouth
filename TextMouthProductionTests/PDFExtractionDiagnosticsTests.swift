import XCTest
@testable import TextMouth

/// How a PDF's pages were read, in lists the Library can show and in
/// sentences a reader hears: where each page's text came from, where OCR
/// found nothing, and where it could not run and why.
final class PDFExtractionDiagnosticsTests: XCTestCase {

    // MARK: - Page Lists

    /// Every page is listed by where its text came from and by what OCR
    /// did on it.
    func testPagesAreListedBySourceAndByWhatOCRDid() {
        let diagnostics = Self.sevenPages

        XCTAssertEqual(diagnostics.pagesWithEmbeddedTextOnly, [1, 5, 6])
        XCTAssertEqual(diagnostics.pagesWithOCRTextOnly, [2])
        XCTAssertEqual(diagnostics.pagesWithEmbeddedAndOCRText, [3])
        XCTAssertEqual(diagnostics.pagesWithoutText, [4, 7])
        XCTAssertEqual(diagnostics.pagesWhereOCRFoundNothing, [4, 5])
        XCTAssertEqual(diagnostics.pagesWhereOCRCouldNotRun, [6, 7])
        XCTAssertEqual(diagnostics.firstOCRFailureReason, "text recognition is not available")
    }

    /// A PDF is read in full when OCR ran wherever it was needed, even
    /// where it found nothing; one page it could not run on is enough to
    /// make it incomplete.
    func testCompletenessDependsOnlyOnWhereOCRCouldNotRun() {
        let foundNothing = PDFExtractionDiagnostics(pages: [page(1, .none, .foundNothing)])
        let unread = PDFExtractionDiagnostics(pages: [page(1, .embedded, .couldNotRun("no model"))])

        XCTAssertTrue(foundNothing.isComplete)
        XCTAssertNil(foundNothing.problem)
        XCTAssertNil(foundNothing.firstOCRFailureReason)
        XCTAssertFalse(unread.isComplete)
    }

    // MARK: - Page Phrases

    /// Pages are said in order without repeats, with runs of three or more
    /// said as ranges in words a speech synthesizer cannot misread.
    func testPagePhraseSaysRunsAsRanges() {
        XCTAssertEqual(PDFExtractionDiagnostics.pagePhrase([3]), "page 3")
        XCTAssertEqual(PDFExtractionDiagnostics.pagePhrase([7, 3]), "pages 3 and 7")
        XCTAssertEqual(PDFExtractionDiagnostics.pagePhrase([5, 6]), "pages 5 and 6")
        XCTAssertEqual(PDFExtractionDiagnostics.pagePhrase([1, 2, 3]), "pages 1 to 3")
        XCTAssertEqual(PDFExtractionDiagnostics.pagePhrase([9, 1, 2, 3, 4, 7, 2]), "pages 1 to 4, 7, and 9")
        XCTAssertEqual(PDFExtractionDiagnostics.pagePhrase([1, 2, 3, 5, 6, 7]), "pages 1 to 3 and 5 to 7")
    }

    // MARK: - Summary

    /// The summary counts each source of text, then names the pages OCR
    /// found nothing on and those it could not run on, with why.
    func testSummaryCountsEachSourceThenNamesOCRPages() {
        XCTAssertEqual(
            Self.sevenPages.summary,
            "Of 7 pages, 3 have embedded text only, 1 has OCR text only, 1 has both embedded and OCR text, "
                + "and 2 have no text. OCR found no text on pages 4 and 5. "
                + "OCR could not run on pages 6 and 7 (text recognition is not available)."
        )
    }

    /// One source for every page is said once, and a one-page PDF or one
    /// without pages is described plainly.
    func testSummaryOfAUniformOrTinyPDF() {
        let twelve = PDFExtractionDiagnostics(pages: (1...12).map { page($0, .embedded, .notNeeded) })
        let one = PDFExtractionDiagnostics(pages: [page(1, .recognized, .recognizedText)])
        let two = PDFExtractionDiagnostics(pages: [page(1, .embedded, .notNeeded), page(2, .both, .recognizedText)])

        XCTAssertEqual(twelve.summary, "All 12 pages have embedded text only.")
        XCTAssertEqual(one.summary, "Its only page has OCR text only.")
        XCTAssertEqual(two.summary, "Of 2 pages, 1 has embedded text only and 1 has both embedded and OCR text.")
        XCTAssertEqual(PDFExtractionDiagnostics().summary, "The PDF has no pages.")
    }

    // MARK: - Problem

    /// The problem sentence counts the pages OCR could not run on, then
    /// names them grouped by reason, in the order the reasons first appear.
    func testProblemNamesThePagesGroupedByReason() {
        var pages = (1...12).map { page($0, .embedded, .notNeeded) }
        pages[2] = page(3, .embedded, .couldNotRun("text recognition is not available"))
        pages[6] = page(7, .none, .couldNotRun("text recognition is not available"))
        pages[8] = page(9, .both, .couldNotRun("the page could not be drawn for text recognition"))

        XCTAssertEqual(
            PDFExtractionDiagnostics(pages: pages).problem,
            "OCR could not run on 3 of 12 pages, so text that appears only in their images is missing: "
                + "pages 3 and 7 (text recognition is not available); "
                + "page 9 (the page could not be drawn for text recognition)."
        )
    }

    /// When OCR could not run on any page, the count says so plainly, and
    /// one page is spoken of in the singular.
    func testProblemWhenOCRCouldNotRunOnAnyPage() {
        let reason = "text recognition is not available"
        let three = PDFExtractionDiagnostics(pages: (1...3).map { page($0, .none, .couldNotRun(reason)) })
        let only = PDFExtractionDiagnostics(pages: [page(1, .embedded, .couldNotRun(reason))])
        let oneOfTwo = PDFExtractionDiagnostics(pages: [page(1, .embedded, .notNeeded), page(2, .embedded, .couldNotRun(reason))])

        XCTAssertEqual(
            three.problem,
            "OCR could not run on all 3 pages, so text that appears only in their images is missing: "
                + "pages 1 to 3 (text recognition is not available)."
        )
        XCTAssertEqual(
            only.problem,
            "OCR could not run on the PDF's only page, so text that appears only in its images is missing: "
                + "page 1 (text recognition is not available)."
        )
        XCTAssertEqual(
            oneOfTwo.problem,
            "OCR could not run on 1 of 2 pages, so text that appears only in its images is missing: "
                + "page 2 (text recognition is not available)."
        )
    }

    // MARK: - Helpers

    /// Seven pages, one of each kind: embedded text only; OCR text only;
    /// both; nothing found; embedded text with OCR finding nothing in a
    /// picture; and two pages OCR could not run on.
    private static let sevenPages = PDFExtractionDiagnostics(
        pages: [
            PDFPageDiagnosis(pageNumber: 1, source: .embedded, recognition: .notNeeded),
            PDFPageDiagnosis(pageNumber: 2, source: .recognized, recognition: .recognizedText),
            PDFPageDiagnosis(pageNumber: 3, source: .both, recognition: .recognizedText),
            PDFPageDiagnosis(pageNumber: 4, source: .none, recognition: .foundNothing),
            PDFPageDiagnosis(pageNumber: 5, source: .embedded, recognition: .foundNothing),
            PDFPageDiagnosis(pageNumber: 6, source: .embedded, recognition: .couldNotRun("text recognition is not available")),
            PDFPageDiagnosis(pageNumber: 7, source: .none, recognition: .couldNotRun("text recognition is not available"))
        ],
        ocrUnavailableReason: "text recognition is not available"
    )

    /// A page's diagnosis.
    private func page(
        _ number: Int,
        _ source: PDFPageDiagnosis.TextSource,
        _ recognition: PDFPageDiagnosis.Recognition
    ) -> PDFPageDiagnosis {
        PDFPageDiagnosis(pageNumber: number, source: source, recognition: recognition)
    }
}
