import XCTest
import SwiftSoup
@testable import TextMouth

// MARK: - List Items Inside Table Cells

/// A list item inside a table cell of a rich text document is a list item
/// as it is outside a table: the cell writes it in a list, so the reading
/// text has its number or bullet, in the same words as a list outside a
/// table, and the item's words stay in their cell.
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

    /// The reading text has the number of a list item in a cell, as it has
    /// one outside a table.
    func testTheNumberIsReadInTheReadingText() throws {
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
