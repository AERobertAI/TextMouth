import XCTest
import SwiftSoup
@testable import TextMouth

// MARK: - List Items Inside Table Cells

/// A list item inside a table cell of a rich text document is a list item
/// as it is outside a table: the cell writes it in a list (HTML's `ol` or
/// `ul`), so that the Markdown, and the exports made from it, have the list
/// as they have a list outside a table, and the item's words stay in their
/// cell. The reading text leaves every list's number out, in a table and
/// out of one, in every format (`docs/user/what-textmouth-reads.md`), so this
/// changes no word a listener hears.
final class RTFTableListTests: XCTestCase {

    /// The list table and override table of the sample documents below: a
    /// numbered list (`\ls1`) and a bulleted one (`\ls2`).
    private let lists = #"""
        {\fonttbl{\f1\fcharset2 Symbol;}}
        {\*\listtable{\list\listid10{\listlevel\levelnfc0{\leveltext\'02\'00.;}}{\listlevel\levelnfc0{\leveltext\'02\'00.;}}}
        {\list\listid20{\listlevel\levelnfc23{\leveltext\'01\'b7;}}}}
        {\*\listoverridetable{\listoverride\listid10\ls1}{\listoverride\listid20\ls2}}
        """#

    /// The Markdown the reading text has for the rich text `body`, set after
    /// the list tables.
    private func markdown(_ body: String) throws -> String {
        let html = try rtfHTML("{\\rtf1\\ansi" + lists + body + "}")
        return try HTMLToMarkdownConverter.convert(html, includesPages: true)
    }

    /// A numbered item in a cell, ended by `\cell` alone (as Word writes
    /// it) or by `\par` and then `\cell`, is a numbered list in the cell.
    func testANumberedItemInACellIsInAList() throws {
        for ending in [#"\cell"#, #"\par\cell"#] {
            let html = try rtfHTML("{\\rtf1\\ansi" + lists + #"""
                \trowd\cellx3000\cellx6000
                \pard\intbl\ls1\ilvl0{\listtext 1.\tab}Numbered item\#(ending)
                \pard\intbl Beside it\cell\row}
                """#)
            let cells = try rtfBody(html).select("td").array()
            XCTAssertEqual(cells.count, 2, ending)
            XCTAssertEqual(try cells[0].select("ol > li").array().map { try $0.text() }, ["Numbered item"], ending)
            XCTAssertEqual(try cells[0].text(), "Numbered item", ending)
            XCTAssertEqual(try cells[1].select("li").count, 0, ending)
            XCTAssertEqual(try cells[1].text(), "Beside it", ending)
        }
    }

    /// The Markdown has the list of a list item in a cell as it has one outside
    /// a table. (It is the Markdown that has the number: the reading text
    /// leaves it out of both.)
    func testTheMarkdownHasTheListAsOutsideATable() throws {
        let inCell = try markdown(#"""
            \trowd\cellx3000
            \pard\intbl\ls1\ilvl0{\listtext 1.\tab}First\par
            \pard\intbl\ls1\ilvl0{\listtext 2.\tab}Second\cell\row
            """#)
        let outside = try markdown(#"""
            \pard\ls1\ilvl0{\listtext 1.\tab}First\par
            \pard\ls1\ilvl0{\listtext 2.\tab}Second\par
            """#)
        XCTAssertTrue(inCell.contains("1. First"), inCell)
        XCTAssertTrue(inCell.contains("2. Second"), inCell)
        XCTAssertTrue(outside.contains("1. First"), outside)
        XCTAssertTrue(outside.contains("2. Second"), outside)
        // What a listener hears is the same with or without the list
        let heard = { (markdown: String) in try MarkdownDocParser.parseChapter(markdown: markdown).text }
        XCTAssertFalse(try heard(inCell).contains("1."), "The number is not heard")
        XCTAssertTrue(try heard(inCell).contains("First"))
    }

    /// Words in a table cell that no `\cell` or `\row` ever closed are in a
    /// table all the same, and are not lost, whether the file ends there or
    /// not, and in a note as in the body.
    func testWordsOfACellThatIsNeverClosedAreKept() throws {
        let body = try rtfHTML(#"{\rtf1\ansi\pard\intbl Lost words\par\pard After\par}"#)
        XCTAssertEqual(try rtfBody(body).select("td").array().map { try $0.text() }, ["Lost words"])
        XCTAssertEqual(try rtfBody(body).select("body > p").array().map { try $0.text() }, ["After"])
        let cutOff = try rtfHTML(#"{\rtf1\ansi\trowd\cellx1000\pard\intbl Cut off in the first cell"#)
        XCTAssertEqual(try rtfBody(cutOff).text(), "Cut off in the first cell")
        let note = try rtfHTML(#"{\rtf1\ansi A{\footnote\pard\intbl In table words\par}B\par}"#)
        XCTAssertEqual(try rtfBody(note).text(), "AB In table words")
    }

    /// A cell is charged to the budget as a paragraph is, so that a small
    /// file cannot make millions of table cells for the next steps to hold.
    func testEveryCellIsChargedLikeAParagraph() throws {
        let source = "{\\rtf1\\trowd\\cellx1\\pard\\intbl " + String(repeating: "x\\cell ", count: 2_000) + "}"
        // Each cell costs 64 bytes and its word's 17: 2,000 of them are about 162,000
        try DocumentByteLimit.$current.withValue(250_000) {
            XCTAssertNoThrow(try RTFDocumentReader.html(from: Data(source.utf8), includesPages: false))
        }
        try DocumentByteLimit.$current.withValue(120_000) {
            XCTAssertThrowsError(try RTFDocumentReader.html(from: Data(source.utf8), includesPages: false)) { error in
                XCTAssertTrue(error is DocumentTooLargeError)
            }
        }
    }

    /// A bulleted item and a nested numbered item in a cell are a bulleted
    /// list and a list inside it, and a plain paragraph between lists ends
    /// the list.
    func testBulletsNestingAndPlainParagraphsInACell() throws {
        let html = try rtfHTML("{\\rtf1\\ansi" + lists + #"""
            \trowd\cellx3000
            \pard\intbl\ls2\ilvl0{\listtext\f1\'b7\tab}Bullet\par
            \pard\intbl\ls1\ilvl1{\listtext 1.\tab}Nested\par
            \pard\intbl Plain\par
            \pard\intbl\ls1\ilvl0{\listtext 1.\tab}Again\cell\row}
            """#)
        let cell = try XCTUnwrap(try rtfBody(html).select("td").first())
        XCTAssertEqual(try cell.select("ul").count, 1)
        XCTAssertEqual(try cell.select("ul > li > ol > li").array().map { try $0.text() }, ["Nested"])
        XCTAssertEqual(try cell.select("td > p").array().map { try $0.text() }, ["Plain"])
        XCTAssertEqual(try cell.select("td > ol > li").array().map { try $0.text() }, ["Again"])
    }

    /// A list in one cell does not run on into the next cell's list.
    func testAListDoesNotContinueIntoTheNextCell() throws {
        let html = try rtfHTML("{\\rtf1\\ansi" + lists + #"""
            \trowd\cellx3000\cellx6000
            \pard\intbl\ls1\ilvl0{\listtext 1.\tab}Left\cell
            \pard\intbl\ls1\ilvl0{\listtext 1.\tab}Right\cell\row}
            """#)
        let cells = try rtfBody(html).select("td").array()
        XCTAssertEqual(try cells.map { try $0.select("ol").count }, [1, 1])
        XCTAssertEqual(try cells.map { try $0.text() }, ["Left", "Right"])
    }

    /// The real LibreOffice file with a numbered item in a cell reads the
    /// number and keeps the item in its cell.
    func testTheRealSampleReadsItsNumberedCell() throws {
        let html = try rtfSampleHTML("rtf/libreoffice-tdf146489.rtf")
        let items = try rtfBody(html).select("td ol > li").array().map { try $0.text() }
        XCTAssertEqual(items.count, 1, html)
        XCTAssertTrue(try XCTUnwrap(items.first).hasSuffix("para"), "\(items)")
        let markdown = try HTMLToMarkdownConverter.convert(html, includesPages: true)
        XCTAssertTrue(markdown.contains("1. "), markdown)
    }
}
