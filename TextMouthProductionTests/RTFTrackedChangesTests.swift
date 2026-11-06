import XCTest
import SwiftSoup
@testable import TextMouth

// MARK: - Tracked Changes in Rich Text

/// How TextMouth's own reader of rich text treats a tracked change: text
/// a tracked deletion removed (`\deleted`) is left out, as the Word and DOCX
/// readers leave it out, and text a change inserted (`\revised`) is read.
/// The deleted text goes through the reader's run state as hidden text
/// (`\v`) does, so the emphasis, the pages, and the headings around it stay
/// right.
final class RTFTrackedChangesTests: XCTestCase {

    /// The body text of the rich text `source`.
    private func text(of source: String) throws -> String {
        try rtfBody(try rtfHTML(source)).text()
    }

    /// Deleted text is not read; inserted text is, and so is the text
    /// between them.
    func testDeletedTextIsLeftOutAndRevisedTextIsRead() throws {
        let source = #"{\rtf1\ansi Keep {\deleted gone} then {\revised added} end.\par}"#
        XCTAssertEqual(try text(of: source), "Keep then added end.")
    }

    /// `\deleted0` turns the deletion off inside the group, and the end of
    /// the group that set it turns it off, as for any character property.
    func testADeletionEndsWithItsGroupOrWithZero() throws {
        let source = #"{\rtf1\ansi A{\deleted B\deleted0 C}D{\deleted E}F\par}"#
        XCTAssertEqual(try text(of: source), "ACDF")
    }

    /// `\plain` resets character formatting but a revision mark is not
    /// formatting: deleted text stays deleted.
    func testPlainDoesNotBringDeletedTextBack() throws {
        let source = #"{\rtf1\ansi A{\deleted B\plain C}D\par}"#
        XCTAssertEqual(try text(of: source), "AD")
    }

    /// Hidden text and deleted text are both left out, together or apart.
    func testHiddenAndDeletedTextAreBothLeftOut() throws {
        let source = #"{\rtf1\ansi A{\v B}C{\deleted D}E{\v\deleted F}G\par}"#
        XCTAssertEqual(try text(of: source), "ACEG")
    }

    /// The emphasis of the words around a deletion is unbroken: the
    /// deleted words add no run of their own, and a bold word that was
    /// deleted adds no mark.
    func testEmphasisAroundADeletionIsKept() throws {
        let html = try rtfHTML(#"{\rtf1\ansi {\b Bold }{\b\deleted deleted bold }{\b stays}, plain.\par}"#)
        XCTAssertEqual(try rtfBody(html).select("strong").array().map { try $0.text() }, ["Bold stays"])
        XCTAssertEqual(try rtfBody(html).text(), "Bold stays, plain.")
    }

    /// A paragraph whose every word was deleted writes no empty paragraph,
    /// and a heading whose words were deleted writes no empty heading.
    func testAParagraphOfDeletedWordsIsDropped() throws {
        let html = try rtfHTML(#"{\rtf1\ansi\pard\outlinelevel0 {\deleted Gone heading}\par\pard Kept body.\par\pard {\deleted Gone body.}\par}"#)
        XCTAssertEqual(try rtfHeadings(html), [])
        XCTAssertEqual(try rtfBody(html).select("p").array().map { try $0.text() }, ["Kept body."])
    }

    /// A heading keeps its level when only some of its words were deleted.
    func testAHeadingKeepsItsKeptWords() throws {
        let html = try rtfHTML(#"{\rtf1\ansi\pard\outlinelevel0 Chapter {\deleted One }Two\par\pard Body.\par}"#)
        XCTAssertEqual(try rtfHeadings(html), ["1: Chapter Two"])
    }

    /// A page break inside deleted text begins no page, where one in
    /// inserted text does.
    func testAPageBreakInDeletedTextBeginsNoPage() throws {
        let deleted = try rtfHTML(#"{\rtf1\ansi First page.{\deleted\page} Still first.\par}"#)
        XCTAssertEqual(try rtfPages(deleted), ["1"])
        let revised = try rtfHTML(#"{\rtf1\ansi First page.{\revised\page} Second page.\par}"#)
        XCTAssertEqual(try rtfPages(revised), ["1", "2"])
    }

    /// A line break inside deleted text breaks no line.
    func testALineBreakInDeletedTextBreaksNoLine() throws {
        let html = try rtfHTML(#"{\rtf1\ansi One{\deleted\line}Two{\line}Three\par}"#)
        XCTAssertEqual(try rtfBody(html).select("br").count, 1)
    }

    /// A deletion that holds paragraph marks keeps the paragraphs apart:
    /// a deleted paragraph is dropped, and the paragraphs around it are not
    /// joined.
    func testADeletionAcrossParagraphsKeepsTheParagraphsApart() throws {
        let html = try rtfHTML(#"{\rtf1\ansi Before.\par{\deleted Gone one.\par Gone two.\par}After.\par}"#)
        XCTAssertEqual(try rtfBody(html).select("p").array().map { try $0.text() }, ["Before.", "After."])
    }
}
