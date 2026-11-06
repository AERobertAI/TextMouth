import XCTest
@testable import TextMouth

/// Amazon's own conversion of a small book of the things that sit inside a
/// paragraph (`TestData/format-samples/kfx/kfx-inline.kfx`, made by
/// `Scripts/make-kfx-sample.py` from the EPUB beside it): pictures with and
/// without alt text, a floated span, math, a page break inside a paragraph, a
/// page number shown in the text, a picture that is a heading, emphasis on a
/// whole paragraph, a table with a header row, and a cut that Amazon makes
/// where the author's style asks for a page break. It is compared with the
/// EPUB reader by paragraphs as well as words, because a count of words
/// hides a split or a joined paragraph.
final class KFXInlineBookTests: XCTestCase {

    // MARK: - Helpers

    private func epub(includesPages: Bool = false) throws -> [EPUBParser.PreparedChapter] {
        try EPUBParser.prepareBook(url: formatSampleURL("kfx/kfx-inline.epub"), includesPages: includesPages).chapters
    }

    private func kfx(includesPages: Bool = false) throws -> [EPUBParser.PreparedChapter] {
        try KFXParser.prepareBook(url: formatSampleURL("kfx/kfx-inline.kfx"), includesPages: includesPages).chapters
    }

    /// The paragraphs of the chapters: their reading text, a line each, trimmed.
    private func paragraphs(_ chapters: [EPUBParser.PreparedChapter]) -> [String] {
        chapters.flatMap { prepared in
            prepared.chapter.text.split(whereSeparator: \.isNewline)
                .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                .filter { !$0.isEmpty }
        }
    }

    // MARK: - The words and paragraphs

    func testEveryParagraphReadsAsTheEPUBReadsItButTheMath() throws {
        let fromEPUB = paragraphs(try epub()), fromKFX = paragraphs(try kfx())
        let epubWithoutMath = fromEPUB.filter { !$0.hasPrefix("Math inline") }
        let kfxWithoutMath = fromKFX.filter { !$0.hasPrefix("Math inline") }
        XCTAssertEqual(kfxWithoutMath, epubWithoutMath)
        XCTAssertGreaterThan(kfxWithoutMath.count, 10)
    }

    /// Named difference: the EPUB reads math from its markup (y=2); the KFX
    /// reads the formula's accessible name, which the author gave it.
    func testMathReadsByItsAccessibleName() throws {
        XCTAssertTrue(paragraphs(try kfx()).contains("Math inline y equals two done."))
    }

    func testEachInlinePictureAndSpanKeepsItsWordsInItsParagraph() throws {
        let lines = paragraphs(try kfx())
        for expected in [
            "Text then more text.",
            "Before picture first inline alt middle words after the page.",
            "first of two second of two",
            "Text floated span words tail.",
        ] {
            XCTAssertTrue(lines.contains(expected), "\(expected) in \(lines)")
        }
    }

    // MARK: - Headings and chapters

    func testHeadingsAreTheEPUBsHeadingForHeading() throws {
        func lines(_ chapters: [EPUBParser.PreparedChapter]) -> [String] {
            chapters.flatMap(\.chapter.headings).map { "\($0.level): \($0.text)" }
        }
        XCTAssertEqual(lines(try kfx()), lines(try epub()))
    }

    /// Named difference of finding 10, now repaired: Amazon cuts the second
    /// document where its style asks for a page break; the cut is no chapter.
    func testTheCutSectionJoinsItsChapterAsInTheEPUB() throws {
        let chapters = try kfx()
        XCTAssertEqual(chapters.count, try epub().count)
        XCTAssertFalse(chapters.contains { $0.chapter.title.hasPrefix("Chapter ") })
        XCTAssertTrue(chapters[1].chapter.text.contains("After the cut, in a new section with no heading."))
    }

    // MARK: - Emphasis, pages

    func testAWholeParagraphInEmphasisIsMarkedInTheMarkdown() throws {
        let markdown = try kfx().map(\.markdown).joined()
        XCTAssertTrue(markdown.contains("*Whole paragraph in em.*"), markdown)
    }

    /// The pages: label and the first words of the page, in the EPUB and the KFX.
    func testPagesLandOnTheSameWordsIncludingAMidParagraphPageAndAShownNumber() throws {
        func pages(_ chapters: [EPUBParser.PreparedChapter]) -> [String] {
            chapters.flatMap { prepared -> [String] in
                let chapter = prepared.chapter
                return chapter.pages.map { page in
                    let start = chapter.text.utf16.index(chapter.text.utf16.startIndex, offsetBy: page.characterOffset)
                    return page.label + ": " + chapter.text[start...].split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " ")
                }
            }
        }
        let fromKFX = pages(try kfx(includesPages: true))
        XCTAssertEqual(fromKFX, pages(try epub(includesPages: true)))
        XCTAssertEqual(fromKFX.count, 3)
    }

    /// Named difference of finding 23, now repaired: a page number shown in the
    /// text where the page begins ("before11") is the page's, not the words'.
    func testAPageNumberShownInTheTextIsNotRead() throws {
        let lines = paragraphs(try kfx(includesPages: true))
        XCTAssertTrue(lines.contains("Number shown before and after."), "\(lines)")
    }

    // MARK: - Tables

    func testARowOfATableIsOneParagraph() throws {
        let lines = paragraphs(try kfx())
        XCTAssertTrue(lines.contains("Row head Next head"), "\(lines)")
        XCTAssertTrue(lines.contains("Row value Next value"), "\(lines)")
        XCTAssertTrue(lines.contains("Cell with cell picture inside Plain cell"), "\(lines)")
    }
}
