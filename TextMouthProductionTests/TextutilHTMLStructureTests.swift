import XCTest
import SwiftSoup
@testable import TextMouth

/// `TextutilHTMLStructure`, the pass that restores headings, lists, and
/// silence for pictures in the HTML `/usr/bin/textutil` writes. Every
/// fixture is textutil's output in its own shape (a stylesheet of
/// `tag.class` rules, a bold or larger `<p>` per heading); the tests never
/// run textutil. Results are read as the reader reads them: through
/// `HTMLToMarkdownConverter` and the Markdown parser.
final class TextutilHTMLStructureTests: XCTestCase {

    // MARK: - Helpers

    /// A plain 12 px paragraph of body text (about 100 characters), so a
    /// document made of these has a body size of 12 px.
    private let plain = """
        <p class="p2">The ferry leaves at seven, and the cafe tables fill early with people who read the news.</p>
        """

    /// Several `plain` paragraphs, for a document whose body text must
    /// outweigh its other paragraphs by far.
    private var manyPlain: String { String(repeating: plain + "\n", count: 6) }

    /// A document in textutil's shape: `style` is the body of its stylesheet
    /// and `body` its paragraphs. `p.p2` is always the 12 px body rule.
    private func html(style: String = "", body: String) -> String {
        """
        <!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd">
        <html><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
        <style type="text/css">
        p.p2 {margin: 0.0px 0.0px 12.0px 0.0px; font: 12.0px Times}
        \(style)
        </style></head><body>
        \(body)
        </body></html>
        """
    }

    /// Parse `markup`, restore its structure, and return the document.
    private func restored(_ markup: String) throws -> Document {
        let document = try SwiftSoup.parse(markup)
        try TextutilHTMLStructure.restore(in: document)
        return document
    }

    /// The Markdown the converter writes for the restored `markup`.
    private func markdown(_ markup: String) throws -> String {
        try HTMLToMarkdownConverter.convert(
            document: try restored(markup),
            readingFlow: PublicationSemantics.ReadingFlow(source: markup)
        )
    }

    /// The headings a reader lists for the restored `markup`, as "level: text".
    private func headings(_ markup: String) throws -> [String] {
        try MarkdownDocParser.parse(markdown: try markdown(markup)).chapters.flatMap { chapter in
            chapter.headings.map { "\($0.level): \($0.text)" }
        }
    }

    /// The text a reader hears for the restored `markup`.
    private func spokenText(_ markup: String) throws -> String {
        try MarkdownDocParser.parse(markdown: try markdown(markup)).chapters.map(\.text)
            .joined(separator: "\n\n")
    }

    // MARK: - Headings from size and weight

    /// Sizes and bold give headings and levels; body text stays paragraphs.
    func testSizesAndBoldGiveHeadingsAndLevels() throws {
        let markup = html(
            style: """
            p.p1 {font: 24.0px Times}
            p.p3 {font: 18.0px Times}
            """,
            body: """
            <p class="p1"><span class="s1"><b>Harbour Notes</b></span></p>
            \(plain)
            <p class="p3"><span class="s1"><b>Morning Tides</b></span></p>
            \(plain)
            <p class="p2"><b>Evening Lines</b></p>
            \(plain)
            """
        )
        XCTAssertEqual(try headings(markup), ["1: Harbour Notes", "2: Morning Tides", "3: Evening Lines"])
        XCTAssertTrue(try spokenText(markup).contains("The ferry leaves at seven"))
    }

    /// Word's Heading 1 to 6 as textutil writes them.
    func testChapterNumberingFixtureGivesLevelsOneToFive() throws {
        let markup = """
        <html><head><style type="text/css">
          p.p1 {margin: 12.0px 0.0px 6.0px 0.0px; font: 18.0px 'Times New Roman'}
          p.p2 {margin: 10.0px 0.0px 6.0px 0.0px; font: 16.0px 'Times New Roman'}
          p.p3 {margin: 7.0px 0.0px 6.0px 0.0px; font: 14.0px 'Times New Roman'}
          p.p4 {margin: 6.0px 0.0px 6.0px 0.0px; font: 13.5px 'Times New Roman'}
          p.p5 {margin: 6.0px 0.0px 3.0px 0.0px; font: 12.0px 'Times New Roman'}
          p.p6 {margin: 3.0px 0.0px 3.0px 0.0px; font: 12.0px 'Times New Roman'}
          p.p7 {margin: 0.0px 0.0px 0.0px 0.0px; text-align: center; font: 12.0px 'Times New Roman'}
          p.p8 {margin: 0.0px 0.0px 0.0px 0.0px; font: 12.0px 'Times New Roman'; min-height: 15.0px}
        </style></head>
        <body>
        <p class="p1"><b>Heading 1</b></p>
        <p class="p2"><b>Heading 2</b></p>
        <p class="p3"><b>Heading 3</b></p>
        <p class="p4"><b><i>Heading 4</i></b></p>
        <p class="p5"><b>Heading 5</b></p>
        <p class="p6"><b><i>Heading 6</i></b></p>
        <p class="p7">Chapter numbering</p>
        <p class="p8"><br></p>
        <p class="p8"><b><i></i></b><br></p>
        </body></html>
        """
        XCTAssertEqual(try headings(markup), [
            "1: Heading 1", "2: Heading 2", "3: Heading 3", "4: Heading 4",
            "5: Heading 5", "5: Heading 6",
        ])
        XCTAssertTrue(try spokenText(markup).contains("Chapter numbering"))
    }

    /// An RTF written as Word writes it: sizes in Arial, no heading tags.
    func testWordStylesFixtureGivesThreeLevels() throws {
        let markup = """
        <html><head><style type="text/css">
          p.p1 {margin: 12.0px 0.0px 3.0px 0.0px; font: 16.0px Arial}
          p.p2 {margin: 0.0px 0.0px 0.0px 0.0px; font: 12.0px 'Times New Roman'}
          p.p3 {margin: 12.0px 0.0px 3.0px 0.0px; font: 14.0px Arial}
          p.p4 {margin: 0.0px 0.0px 0.0px 0.0px; font: 13.0px Arial}
          p.p5 {margin: 12.0px 0.0px 3.0px 0.0px; font: 13.0px Arial}
        </style></head>
        <body>
        <p class="p1"><b>Chapter One: The Quay</b></p>
        <p class="p2">The ferry leaves at seven. Café tables fill early, and the señor at the counter pours coffee without asking.</p>
        <p class="p3"><b><i>Morning Tides</i></b></p>
        <p class="p2">Gulls argue over crusts; the crane operators wave, and everyone says “good morning” in three languages. Prices – in euros – are posted by the quay. Unicode check: €5 and česky.</p>
        <p class="p4"><b>A paragraph with outline level 3 but no heading style</b></p>
        <p class="p5"><b>A third-level heading</b></p>
        <p class="p2">The last paragraph is plain.</p>
        </body></html>
        """
        XCTAssertEqual(try headings(markup), [
            "1: Chapter One: The Quay", "2: Morning Tides",
            "3: A paragraph with outline level 3 but no heading style", "3: A third-level heading",
        ])
        let spoken = try spokenText(markup)
        XCTAssertTrue(spoken.contains("The last paragraph is plain."))
        XCTAssertTrue(spoken.contains("Gulls argue over crusts"))
    }

    /// Plain text only: no headings, and the words are unchanged.
    func testNoLargerTextAndNoBoldGivesNoHeadings() throws {
        let markup = html(body: manyPlain)
        XCTAssertEqual(try headings(markup), [])
        XCTAssertEqual(try restored(markup).select("h1, h2, h3, h4, h5, h6").size(), 0)
        XCTAssertTrue(try spokenText(markup).contains("who read the news."))
    }

    /// A document without any stylesheet still has bold headings, at the
    /// default 12 px body size.
    func testBoldWithoutAStylesheetIsAHeading() throws {
        let body = String(repeating: "Some body words here. ", count: 8)
        let markup = "<html><body><p><b>Short Title</b></p><p>\(body)</p></body></html>"
        XCTAssertEqual(try headings(markup), ["1: Short Title"])
    }

    /// A document in bold throughout has no headings from bold, while a
    /// larger paragraph in it is still a heading.
    func testEveryParagraphBoldGivesNoHeadingsFromBold() throws {
        let boldLine = "<p class=\"p2\"><b>The ferry leaves at seven and the cafe tables fill early.</b></p>"
        let boldBody = Array(repeating: boldLine, count: 3).joined(separator: "\n")
        let markup = html(
            style: "p.p3 {font: 18.0px Times}",
            body: boldBody + "\n<p class=\"p3\"><b>The Big One</b></p>\n" + boldBody
        )
        XCTAssertEqual(try headings(markup), ["1: The Big One"])
    }

    /// A decorative letter takes no rank, an inline drop cap stays text,
    /// and a chapter's number is a heading.
    func testDecorativeInitialsAreNotHeadings() throws {
        let markup = html(
            style: """
            p.p4 {font: 72.0px Times}
            p.p3 {font: 18.0px Times}
            span.s9 {font: 48.0px Times}
            """,
            body: """
            <p class="p4"><b>T</b></p>
            <p class="p3"><b>Real Heading</b></p>
            <p class="p2"><span class="s9">I</span>t was a quiet morning at the harbour and nothing moved on the water.</p>
            <p class="p3"><b>1</b></p>
            \(manyPlain)
            """
        )
        // "T" takes no rank, so the 18 px heading is level 1, and so is the number.
        XCTAssertEqual(try headings(markup), ["1: Real Heading", "1: 1"])
        XCTAssertTrue(try spokenText(markup).contains("t was a quiet morning"))
    }

    /// Table cells and list items are never headings, however bold or large.
    func testTableCellsAndListItemsAreNeverHeadings() throws {
        let markup = html(
            style: """
            p.p3 {font: 18.0px Times}
            td.td1 {font: 18.0px Times}
            """,
            body: """
            <table cellspacing="0" cellpadding="0" class="t1"><tbody><tr>
            <td valign="middle" class="td1"><p class="p3"><b>Boat</b></p></td>
            <td valign="middle" class="td1"><b>Passengers</b></td></tr></tbody></table>
            <ul class="ul1"><li class="li4"><p class="p3"><b>Smoked fish</b></p></li></ul>
            \(manyPlain)
            """
        )
        XCTAssertEqual(try headings(markup), [])
    }

    /// A paragraph over 120 characters is not a heading, bold or larger.
    func testLongParagraphsAreNotHeadings() throws {
        let long = String(repeating: "word ", count: 30)  // 150 characters
        let markup = html(
            style: "p.p3 {font: 18.0px Times}",
            body: """
            <p class="p2"><b>\(long)</b></p>
            <p class="p3">\(long)</p>
            \(manyPlain)\(manyPlain)\(manyPlain)
            """
        )
        XCTAssertEqual(try headings(markup), [])
    }

    /// Seven larger sizes give levels 1 to 6; the smallest two share 6.
    func testSevenSizesShareTheDeepestLevel() throws {
        let sizes = [30, 28, 26, 24, 22, 20, 18]
        let style = sizes.enumerated().map { "p.q\($0.offset) {font: \($0.element).0px Times}" }
            .joined(separator: "\n")
        let paragraphs = sizes.indices.map { "<p class=\"q\($0)\">Size \(sizes[$0])</p>" }
            .joined(separator: "\n")
        XCTAssertEqual(try headings(html(style: style, body: paragraphs + manyPlain)), [
            "1: Size 30", "2: Size 28", "3: Size 26", "4: Size 24", "5: Size 22",
            "6: Size 20", "6: Size 18",
        ])
    }

    /// Sizes compare to the half pixel: 13.4 and 13.5 are one size, 14 another.
    func testSizesCompareToTheHalfPixel() throws {
        let markup = html(
            style: """
            p.a {font: 13.5px Times}
            p.b {font: 13.4px Times}
            p.c {font: 14.0px Times}
            """,
            body: """
            <p class="c">Wide</p><p class="a">First</p><p class="b">Second</p>
            \(manyPlain)
            """
        )
        XCTAssertEqual(try headings(markup), ["1: Wide", "2: First", "2: Second"])
    }

    /// A span's size wins over its paragraph's, and a class rule can make
    /// text bold (by font-weight, a number, or the font shorthand).
    func testSpanSizeAndClassRuleWeight() throws {
        let markup = html(
            style: """
            span.s3 {font: 18.0px Helvetica}
            p.p4 {font: 12.0px Times; font-weight: bold}
            p.p5 {font: bold 12.0px Times}
            p.p6 {font-size: 12px; font-weight: 700}
            """,
            body: """
            <p class="p2"><span class="s3">Spanned</span></p>
            <p class="p4">Bold By Class</p>
            <p class="p5">Bold By Shorthand</p>
            <p class="p6">Bold By Number</p>
            \(manyPlain)
            """
        )
        XCTAssertEqual(try headings(markup), [
            "1: Spanned", "2: Bold By Class", "2: Bold By Shorthand", "2: Bold By Number",
        ])
    }

    // MARK: - Bullets

    /// Tab, bullet, tab paragraphs become one list without bullets or tabs;
    /// a dialogue dash stays a paragraph; a bullet run in a table is untouched.
    func testBulletParagraphsBecomeOneList() throws {
        let tab = "<span class=\"Apple-tab-span\">\t</span>"
        let markup = html(
            style: "p.p4 {margin: 0.0px 0.0px 0.0px 36.0px; text-indent: -36.0px; font: 12.0px Times}",
            body: """
            <p class="p2">Before the list.</p>
            <p class="p4">\(tab)•\(tab)Bread from the bakery on Rue Ménard</p>
            <p class="p4">\(tab)•\(tab)Smoked fish, <b>naïve</b> prices</p>
            <p class="p4">\(tab)•\(tab)Coffee</p>
            <p class="p2">– Hello, she said.</p>
            <table><tbody><tr><td><p class="p4">\(tab)•\(tab)In a cell</p></td></tr></tbody></table>
            """
        )
        let document = try restored(markup)
        XCTAssertEqual(try document.select("body > ul").size(), 1)
        XCTAssertEqual(try document.select("body > ul > li").size(), 3)
        // Compared as markup (not SwiftSoup's text()) so the spaces around the
        // emphasis are checked exactly.
        XCTAssertEqual(try document.select("body > ul > li").array().map { try $0.html() }, [
            "Bread from the bakery on Rue Ménard", "Smoked fish, <b>naïve</b> prices", "Coffee",
        ])
        // Emphasis inside an item stays.
        XCTAssertEqual(try document.select("ul b").size(), 1)
        // The dialogue line is still a paragraph, and the table's run is not a list.
        let paragraphs = try document.select("p").array().map { try $0.text() }
        XCTAssertEqual(paragraphs.filter { $0.hasPrefix("–") }, ["– Hello, she said."])
        XCTAssertEqual(try document.select("td ul").size(), 0)
        XCTAssertEqual(try document.select("td p").size(), 1)

        // The items reach the reader without their bullets (the table's cell,
        // left alone, keeps its own).
        let lines = try markdown(markup).components(separatedBy: "\n")
        XCTAssertEqual(lines.filter { $0.contains("Bread from the bakery") }.count, 1)
        XCTAssertFalse(lines.contains { $0.contains("•") && !$0.contains("In a cell") })
    }

    /// The body size is counted before bullet paragraphs become list items,
    /// which carry no class and so would count at the 12 px default. Here the
    /// body is 10 px, and its bullets hold more characters than its other
    /// paragraphs: counted after the conversion, 12 px would win as the body
    /// size and the real 12 px heading "Notes" would not be larger. (Before
    /// the fix this test failed: no heading was found.)
    func testBulletListsDoNotChangeTheBodySize() throws {
        let tab = "<span class=\"Apple-tab-span\">\t</span>"
        let bullets = ["Bread from the bakery", "Smoked fish and salt", "Coffee, black, no sugar"]
            .map { "<p class=\"p9\">\(tab)•\(tab)\($0)</p>" }
            .joined(separator: "\n")
        let markup = html(
            style: "p.p9 {font: 10.0px Times}",
            body: """
            <p class="p9">The ferry leaves at seven and the cafe tables fill.</p>
            \(bullets)
            <p class="p2">Notes</p>
            """
        )
        XCTAssertEqual(try headings(markup), ["1: Notes"])
        XCTAssertEqual(try restored(markup).select("body > ul > li").size(), 3)
    }

    /// Two runs of bullets with a paragraph between them are two lists.
    func testSeparatedBulletRunsAreSeparateLists() throws {
        let line = "<p class=\"p2\">\t*\tItem</p>"
        let markup = html(body: line + line + "<p class=\"p2\">Between.</p>" + line)
        XCTAssertEqual(try restored(markup).select("body > ul").size(), 2)
    }

    // MARK: - Pictures and emphasis

    /// A picture's file name is never read: no image or object text remains.
    func testPicturesLeaveNoFileNameBehind() throws {
        let markup = html(body: """
            <p class="p2"><span class="s1"><img src="file:///Attachment.png" alt="Attachment.png"></span></p>
            <p class="p2"><object data="Attachment.png">Attachment.png</object></p>
            \(plain)
            """)
        let result = try markdown(markup)
        XCTAssertFalse(result.contains("Attachment"))
        XCTAssertTrue(result.contains("The ferry leaves at seven"))
    }

    /// Bold and italic in body text stay as they are, and so reach the
    /// converter as emphasis that is never spoken as symbols.
    func testEmphasisInBodyTextSurvives() throws {
        let markup = html(body: """
            <p class="p2">Smoked fish, <i>naïve</i> prices and <b>fresh</b> bread, all morning long at the quay.</p>
            """)
        let result = try markdown(markup)
        XCTAssertTrue(result.contains("*naïve*"))
        XCTAssertTrue(result.contains("**fresh**"))
        let spoken = try spokenText(markup)
        XCTAssertFalse(spoken.contains("*"))
        XCTAssertTrue(spoken.contains("Smoked fish, naïve prices and fresh bread"))
    }
}
