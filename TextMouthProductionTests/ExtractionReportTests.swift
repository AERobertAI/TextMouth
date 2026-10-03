import XCTest
@testable import TextMouth

/// The sentence a reader hears when an extraction leaves chapters out.
final class ExtractionReportTests: XCTestCase {
    /// One missing chapter out of several: the count, then the chapter's
    /// number, its file, and why it could not be read.
    func testMessageForOneOmission() {
        let report = ExtractionReport(
            container: "this EPUB book",
            chapterCount: 3,
            omissions: [omission(2, "OEBPS/ch02.xhtml", .missingMember)]
        )

        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(
            report.message,
            "1 of 3 chapters could not be read: chapter 2 (“OEBPS/ch02.xhtml”) is missing from this EPUB book."
        )
    }

    /// Several omissions are listed in order, separated by semicolons.
    func testMessageForSeveralOmissions() {
        let report = ExtractionReport(
            container: "this EPUB book",
            chapterCount: 14,
            omissions: [
                omission(7, "OEBPS/ch07.xhtml", .missingMember),
                omission(9, "OEBPS/ch09.xhtml", .unreadableMember)
            ]
        )

        XCTAssertEqual(
            report.message,
            "2 of 14 chapters could not be read: chapter 7 (“OEBPS/ch07.xhtml”) is missing from this EPUB book; "
                + "chapter 9 (“OEBPS/ch09.xhtml”) is damaged or incomplete."
        )
    }

    /// When nothing could be read, the summary says so plainly instead of
    /// "3 of 3", and a one-chapter book is not given a count at all.
    func testMessageWhenNoChapterCouldBeRead() {
        let three = ExtractionReport(
            container: "this EPUB book",
            chapterCount: 3,
            omissions: (1...3).map { omission($0, "OEBPS/ch0\($0).xhtml", .missingMember) }
        )
        let one = ExtractionReport(
            container: "this EPUB book",
            chapterCount: 1,
            omissions: [omission(1, "OEBPS/only.xhtml", .unreadableMember)]
        )

        XCTAssertTrue(three.message.hasPrefix("None of the 3 chapters could be read: chapter 1 (“OEBPS/ch01.xhtml”)"))
        XCTAssertTrue(three.message.hasSuffix("chapter 3 (“OEBPS/ch03.xhtml”) is missing from this EPUB book."))
        XCTAssertEqual(
            one.message,
            "The only chapter could not be read: chapter 1 (“OEBPS/only.xhtml”) is damaged or incomplete."
        )
    }

    /// Every reason completes the clause in its own words, and the ones that
    /// name where a file should be use the report's container.
    func testEveryReasonHasItsOwnClause() {
        let report = ExtractionReport(
            container: "this DAISY book",
            chapterCount: 7,
            omissions: [
                omission(1, "a.xml", .missingMember),
                omission(2, "b.xml", .unreadableMember),
                omission(3, "c.xml", .malformedMarkup),
                omission(4, "d", .unlistedItem),
                omission(5, "e.txt", .unsupportedMediaType("text/plain")),
                omission(6, "f", .unsupportedMediaType(""))
            ]
        )

        XCTAssertEqual(
            report.message,
            "6 of 7 chapters could not be read: chapter 1 (“a.xml”) is missing from this DAISY book; "
                + "chapter 2 (“b.xml”) is damaged or incomplete; "
                + "chapter 3 (“c.xml”) has markup that could not be read; "
                + "chapter 4 (“d”) has no file listed in this DAISY book; "
                + "chapter 5 (“e.txt”) is a “text/plain” file, which TextMouth cannot read; "
                + "chapter 6 (“f”) has no media type, so TextMouth cannot read it."
        )
    }

    /// Blank chapters are counted but are never problems: a report with only
    /// blank chapters is complete.
    func testBlankChaptersAreNotOmissions() {
        let report = ExtractionReport(container: "this EPUB book", chapterCount: 3, blankChapterCount: 1)

        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.message, "Every chapter was read.")
    }

    /// The default report has nothing to tell, and names the book generically
    /// so a format that has not chosen its own wording still reads well.
    func testDefaultReportIsCompleteAndGeneric() {
        let report = ExtractionReport()

        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.container, "this book")
        XCTAssertEqual(report.chapterCount, 0)
        XCTAssertEqual(report.blankChapterCount, 0)
    }

    /// A report whose chapter count was never filled in gives no total
    /// rather than an impossible one such as "2 of 0".
    func testMissingChapterCountDoesNotProduceAnImpossibleFraction() {
        let one = ExtractionReport(omissions: [omission(2, "x.html", .missingMember)])
        let two = ExtractionReport(omissions: [
            omission(2, "x.html", .missingMember),
            omission(5, "y.html", .malformedMarkup)
        ])

        XCTAssertEqual(one.message, "1 chapter could not be read: chapter 2 (“x.html”) is missing from this book.")
        XCTAssertTrue(two.message.hasPrefix("2 chapters could not be read: chapter 2 (“x.html”)"), two.message)
    }

    // MARK: - PDF Pages

    /// A PDF whose pictures OCR could not read on some page is incomplete,
    /// so its import warns and keeps the original, and the message names
    /// those pages and why.
    func testPDFWithPagesOCRCouldNotReadIsIncompleteAndSaysWhy() {
        let report = ExtractionReport(container: "this PDF", pdf: PDFExtractionDiagnostics(pages: [
            PDFPageDiagnosis(pageNumber: 1, source: .embedded, recognition: .notNeeded),
            PDFPageDiagnosis(pageNumber: 2, source: .embedded, recognition: .couldNotRun("text recognition is not available"))
        ]))

        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(
            report.message,
            "OCR could not run on 1 of 2 pages, so text that appears only in its images is missing: "
                + "page 2 (text recognition is not available)."
        )
    }

    /// A PDF read in full is complete, whatever OCR found, and its message
    /// speaks of pages rather than chapters.
    func testPDFReadInFullIsComplete() {
        let report = ExtractionReport(container: "this PDF", pdf: PDFExtractionDiagnostics(pages: [
            PDFPageDiagnosis(pageNumber: 1, source: .both, recognition: .recognizedText),
            PDFPageDiagnosis(pageNumber: 2, source: .none, recognition: .foundNothing)
        ]))

        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.message, "Every page was read.")
    }

    /// Chapters left out and pages OCR could not read are both said, the
    /// chapters first.
    func testChapterAndPageProblemsAreBothSaid() {
        let report = ExtractionReport(
            container: "this book",
            chapterCount: 2,
            omissions: [omission(2, "b.html", .missingMember)],
            pdf: PDFExtractionDiagnostics(pages: [
                PDFPageDiagnosis(pageNumber: 1, source: .none, recognition: .couldNotRun("no model"))
            ])
        )

        XCTAssertEqual(
            report.message,
            "1 of 2 chapters could not be read: chapter 2 (“b.html”) is missing from this book. "
                + "OCR could not run on the PDF's only page, so text that appears only in its images is missing: "
                + "page 1 (no model)."
        )
    }

    // MARK: - Helpers

    /// An omission with the given number, file, and reason.
    private func omission(
        _ number: Int,
        _ member: String,
        _ reason: ExtractionOmission.Reason
    ) -> ExtractionOmission {
        ExtractionOmission(chapterNumber: number, member: member, reason: reason)
    }
}
