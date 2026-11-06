import XCTest
import ZIPFoundation
@testable import TextMouth

/// TextMouth's own OpenDocument text reader (FMT27): what it reads from the
/// samples and from small documents built in code, one rule at a time. The
/// reader's behaviour against hostile files is in `ODTHostileReaderTests`,
/// and against textutil's reading in `ODTTextutilComparisonTests`.
final class ODTReaderTests: XCTestCase {

    // MARK: - Helpers

    /// A page-break element as the reader writes it.
    private func page(_ number: Int) -> String {
        "<span role=\"doc-pagebreak\" aria-label=\"\(number)\"></span>"
    }

    /// The HTML of the sample at `path`.
    private func readHTML(ofSample path: String, pages: Bool = false) throws -> String {
        try ODTDocumentReader.html(of: copyOfFormatSample(path), includesPages: pages)
    }

    // MARK: - The Samples

    /// The hand-written sample has real `text:h` elements, a list, a table,
    /// and a title and author.
    func testHandwrittenSampleKeepsItsRealHeadingsListAndTable() throws {
        let html = try readHTML(ofSample: "odt/handwritten.odt")
        let lines = odfBodyLines(html)
        XCTAssertTrue(html.contains("<title>Harbour Notes</title>"))
        XCTAssertTrue(html.contains("<meta name=\"author\" content=\"A. Sample\">"))
        XCTAssertEqual(lines.filter { $0.hasPrefix("<h") }, [
            "<h1>Harbour Notes</h1>", "<h2>Morning Tides</h2>", "<h2>Timetable</h2>",
        ])
        XCTAssertTrue(lines.contains("<li>Smoked fish, naïve prices</li>"))
        XCTAssertTrue(lines.contains("<tr><td><p>Ferry</p></td><td><p>07:00</p></td></tr>"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("<p>Prices — in euros") })
    }

    /// The template reads as the document does.
    func testTemplateSampleReadsLikeTheDocument() throws {
        XCTAssertEqual(
            try readHTML(ofSample: "ott/handwritten.ott"),
            try readHTML(ofSample: "odt/handwritten.odt")
        )
    }

    /// textutil writes no `text:h`: the headings of its own ODT come from
    /// the sizes, as they do from textutil's reading, and its bold header
    /// row stays bold.
    func testTextutilsOwnODTHasItsHeadingsFromSizes() throws {
        let lines = odfBodyLines(try readHTML(ofSample: "odt/headings.odt"))
        XCTAssertEqual(lines.filter { $0.hasPrefix("<h") }, [
            "<h1>Harbour Notes</h1>", "<h2>Morning Tides</h2>", "<h2>Timetable</h2>",
        ])
        XCTAssertTrue(lines.contains("<li>A newspaper already a day old</li>"))
        XCTAssertTrue(lines.contains { $0.contains("<strong>Boat</strong>") })
    }

    /// Pages are marked only when asked for, and the reading is the same
    /// either way but for the page elements, on every sample.
    func testTheTextIsTheSameWithAndWithoutPagesOnEverySample() throws {
        let samples = try FileManager.default.contentsOfDirectory(
            atPath: formatSampleURL("odt").path
        ).filter { $0.hasSuffix(".odt") }.sorted()
        XCTAssertGreaterThan(samples.count, 10)
        for sample in samples {
            let withPages = try readHTML(ofSample: "odt/\(sample)", pages: true)
            let without = try readHTML(ofSample: "odt/\(sample)", pages: false)
            XCTAssertFalse(without.contains("doc-pagebreak"), sample)
            // The pages add their elements and nothing else.
            XCTAssertEqual(
                withPages.replacingOccurrences(of: "<span role=\"doc-pagebreak\"[^>]*></span>", with: "", options: .regularExpression),
                without,
                sample
            )
        }
    }

    /// The HTML goes through the shared converter into a reading text with
    /// its headings and page markers.
    func testTheConverterReadsTheHTMLAsMarkdownWithPages() throws {
        let markdown = try HTMLToMarkdownConverter.convert(
            readHTML(ofSample: "odt/handwritten.odt", pages: true), includesPages: true
        )
        XCTAssertTrue(markdown.contains("# Harbour Notes"))
        XCTAssertTrue(markdown.contains("## Morning Tides"))
        XCTAssertTrue(markdown.contains("<!-- page: 1 -->"))
        // The list items are Markdown list items, whichever the bullet.
        XCTAssertNotNil(markdown.range(of: "(?m)^\\s*[-*+] +Smoked fish", options: .regularExpression), markdown)
    }

    // MARK: - Styles and Headings

    /// Bold and italic come from a style and the styles it is based on; a
    /// heading comes from an outline level a parent style carries; a loop
    /// of parents ends.
    func testStylesAreResolvedThroughTheirParentsWithoutLooping() throws {
        let lines = try odfLines(
            """
            <text:p text:style-name="Child">Plain <text:span text:style-name="B2">bold child</text:span> and \
            <text:span text:style-name="Em">slanted</text:span>.</text:p>\
            <text:p text:style-name="Sub">A heading by inheritance</text:p>\
            <text:p text:style-name="Loop1">Loop one</text:p>\
            <text:p text:style-name="Self">Self parent</text:p>
            """,
            styles: """
            <style:style style:name="B1" style:family="text"><style:text-properties fo:font-weight="700"/></style:style>\
            <style:style style:name="B2" style:family="text" style:parent-style-name="B1"/>\
            <style:style style:name="Em" style:family="text"><style:text-properties fo:font-style="oblique"/></style:style>\
            <style:style style:name="Child" style:family="paragraph" style:parent-style-name="Mid"/>\
            <style:style style:name="Mid" style:family="paragraph" style:parent-style-name="Child"/>\
            <style:style style:name="Head" style:family="paragraph" style:default-outline-level="2"/>\
            <style:style style:name="Sub" style:family="paragraph" style:parent-style-name="Head"/>\
            <style:style style:name="Loop1" style:family="paragraph" style:parent-style-name="Loop2"/>\
            <style:style style:name="Loop2" style:family="paragraph" style:parent-style-name="Loop1">\
            <style:text-properties fo:font-weight="bold"/></style:style>\
            <style:style style:name="Self" style:family="paragraph" style:parent-style-name="Self"/>
            """
        )
        XCTAssertEqual(lines, [
            "<p>Plain <strong>bold child</strong> and <em>slanted</em>.</p>",
            "<h2>A heading by inheritance</h2>",
            "<p><strong>Loop one</strong></p>",
            "<p>Self parent</p>",
        ])
    }

    /// The styles Title and Subtitle, and the base style Heading that Writer
    /// bases its headings and titles on, make headings though they name no
    /// outline level: Title and Heading level 1, Subtitle level 2, as the
    /// DOCX and rich-text readers read "Title" and "Subtitle". A style that
    /// names its outline level keeps it.
    func testTitleSubtitleAndTheBaseHeadingStyleAreHeadings() throws {
        let styles = """
            <style:style style:name="Heading" style:family="paragraph"/>\
            <style:style style:name="Title" style:family="paragraph" style:parent-style-name="Heading"/>\
            <style:style style:name="Subtitle" style:family="paragraph" style:parent-style-name="Heading"/>\
            <style:style style:name="Contents_20_Heading" style:family="paragraph" style:parent-style-name="Heading"/>\
            <style:style style:name="Heading_20_2" style:family="paragraph" style:parent-style-name="Heading" style:default-outline-level="2"/>\
            <style:style style:name="Table_20_Heading" style:family="paragraph"/>\
            <style:style style:name="Mine" style:family="paragraph" style:parent-style-name="Undefined_20_Title"/>\
            <style:style style:name="Mine2" style:family="paragraph" style:parent-style-name="Title"/>
            """
        let lines = try odfLines(
            """
            <text:p text:style-name="Title">The Title</text:p><text:p text:style-name="Subtitle">The Subtitle</text:p>\
            <text:p text:style-name="Contents_20_Heading">Contents</text:p><text:p text:style-name="Heading_20_2">Two</text:p>\
            <text:p text:style-name="Table_20_Heading">Not a heading</text:p><text:p text:style-name="Mine">Not one either</text:p>\
            <text:p text:style-name="Mine2">A title's child</text:p>
            """,
            styles: styles
        )
        XCTAssertEqual(lines, [
            "<h1>The Title</h1>", "<h2>The Subtitle</h2>", "<h1>Contents</h1>", "<h2>Two</h2>",
            "<p>Not a heading</p>", "<p>Not one either</p>", "<h1>A title's child</h1>",
        ])
    }

    /// `text:h` without a level is a heading of level 1; a level past 6
    /// is a level-6 heading; the number a heading shows is not read.
    func testTextHLevels() throws {
        let lines = try odfLines(
            """
            <text:h>No level</text:h><text:h text:outline-level="9">Deep</text:h>\
            <text:h text:outline-level="2"><text:number>1.2</text:number>Numbered</text:h>
            """
        )
        XCTAssertEqual(lines, ["<h1>No level</h1>", "<h6>Deep</h6>", "<h2>Numbered</h2>"])
    }

    /// A document that names no heading keeps the headings found by size
    /// (a length in points, inches, or a share of the size around it); one
    /// that names any keeps exactly those.
    func testHeadingsBySizeOnlyWhenNoneAreNamed() throws {
        let styles = """
            <style:style style:name="Big" style:family="paragraph"><style:text-properties fo:font-size="24pt"/></style:style>\
            <style:style style:name="Mid" style:family="paragraph"><style:text-properties fo:font-size="0.2in"/></style:style>\
            <style:style style:name="Sm" style:family="text"><style:text-properties fo:font-size="150%"/></style:style>
            """
        let body = """
            <text:p text:style-name="Big">Large words</text:p>\
            <text:p>Body words here are many enough to be the body size.</text:p>\
            <text:p>More body words to outweigh the large one entirely.</text:p>\
            <text:p text:style-name="Mid"><text:span text:style-name="Sm">Medium</text:span></text:p>
            """
        XCTAssertEqual(try odfLines(body, styles: styles).filter { $0.hasPrefix("<h") }, [
            "<h1>Large words</h1>", "<h2>Medium</h2>",
        ])
        let named = try odfLines(body + "<text:h text:outline-level=\"3\">Named</text:h>", styles: styles)
        XCTAssertEqual(named.filter { $0.hasPrefix("<h") }, ["<h3>Named</h3>"])
    }

    /// The default style of a family gives the size the others are measured
    /// against.
    func testDefaultStyleSizesTheBody() throws {
        let content = odfContent(
            body: """
                <text:p text:style-name="Big">Large words</text:p>\
                <text:p>Body words here are many enough to be the body size.</text:p>
                """,
            automaticStyles: """
                <style:style style:name="Big" style:family="paragraph"><style:text-properties fo:font-size="20pt"/></style:style>
                """
        )
        let styles = odfStyles(
            "<style:default-style style:family=\"paragraph\"><style:text-properties fo:font-size=\"10pt\"/></style:default-style>"
        )
        let url = try makeODT(content: content, styles: styles)
        let lines = odfBodyLines(try ODTDocumentReader.html(of: url, includesPages: false))
        XCTAssertEqual(lines.first, "<h1>Large words</h1>")
    }

    /// Styles come from `styles.xml` too, and a name in `content.xml` can
    /// use them.
    func testStylesFromTheStylesPartApply() throws {
        let content = odfContent(body: "<text:p text:style-name=\"Heading_20_1\">From styles</text:p><text:p>Body</text:p>")
        let styles = odfStyles(
            "<style:style style:name=\"Heading_20_1\" style:family=\"paragraph\" style:default-outline-level=\"1\"/>"
        )
        let url = try makeODT(content: content, styles: styles)
        XCTAssertEqual(
            odfBodyLines(try ODTDocumentReader.html(of: url, includesPages: false)),
            ["<h1>From styles</h1>", "<p>Body</p>"]
        )
    }

    /// Prefixes other than the usual ones are read by their namespaces.
    func testNamespacePrefixesNeedNotBeTheUsualOnes() throws {
        let content = """
            <?xml version="1.0"?><o:document-content xmlns:o="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
            xmlns:t="urn:oasis:names:tc:opendocument:xmlns:text:1.0" \
            xmlns:s="urn:oasis:names:tc:opendocument:xmlns:style:1.0" \
            xmlns:f="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0">\
            <o:automatic-styles><s:style s:name="Big" s:family="paragraph" s:default-outline-level="2"/>\
            <s:style s:name="Bold" s:family="text"><s:text-properties f:font-weight="bold"/></s:style></o:automatic-styles>\
            <o:body><o:text><t:p t:style-name="Big">Prefixes <t:span t:style-name="Bold">differ</t:span></t:p>\
            <x:p xmlns:x="urn:oasis:names:tc:opendocument:xmlns:text:1.0">Declared late</x:p></o:text></o:body>\
            </o:document-content>
            """
        let url = try makeODT(content: content)
        XCTAssertEqual(
            odfBodyLines(try ODTDocumentReader.html(of: url, includesPages: false)),
            ["<h2>Prefixes differ</h2>", "<p>Declared late</p>"]
        )
    }

    // MARK: - White Space

    /// The specification's rules: a run of white space is one space, none at
    /// the start of a paragraph or after a line break, spans do not break a
    /// word, and `text:s` and `text:tab` stand as they are.
    func testWhiteSpaceIsReadAsTheSpecificationSays() throws {
        let lines = try odfLines(
            """
            <text:p>
               leading   and
               trailing   </text:p>\
            <text:p><text:span>a</text:span><text:span>b</text:span></text:p>\
            <text:p>a <text:span> b</text:span></text:p>\
            <text:p>a<text:s/>b<text:s text:c="3"/>c</text:p>\
            <text:p>one<text:line-break/>  two</text:p>
            """
        )
        XCTAssertEqual(lines, [
            "<p>leading and trailing </p>", "<p>ab</p>", "<p>a b</p>", "<p>a b   c</p>", "<p>one<br>two</p>",
        ])
    }

    // MARK: - What Is Not Read

    /// Hidden text in every form leaves nothing: a style that hides, a
    /// hidden section, a hidden-paragraph field, and a hidden-text field;
    /// a paragraph that is all hidden leaves no empty paragraph.
    func testHiddenTextIsNotRead() throws {
        let lines = try odfLines(
            """
            <text:p text:style-name="Shown">Shown</text:p>\
            <text:p text:style-name="Gone">Hidden whole</text:p>\
            <text:p>Mixed <text:span text:style-name="Gone">secret</text:span> visible</text:p>\
            <text:section text:display="none"><text:p>Hidden section</text:p></text:section>\
            <text:p>Cond<text:hidden-paragraph text:condition="x" text:is-hidden="true"/>ition</text:p>\
            <text:p>Keep <text:hidden-text text:is-hidden="true" text:string-value="s">gone</text:hidden-text>\
            <text:hidden-text text:is-hidden="false">shown</text:hidden-text></text:p>\
            <text:p text:style-name="Conditional">Cond text</text:p>
            """,
            styles: """
            <style:style style:name="Gone" style:family="paragraph"><style:text-properties text:display="none"/></style:style>\
            <style:style style:name="Gone" style:family="text"><style:text-properties text:display="none"/></style:style>\
            <style:style style:name="Conditional" style:family="paragraph">\
            <style:text-properties text:display="condition" text:condition="none"/></style:style>\
            <style:style style:name="Shown" style:family="paragraph"><style:text-properties text:display="true"/></style:style>
            """
        )
        XCTAssertEqual(lines, ["<p>Shown</p>", "<p>Mixed visible</p>", "<p>Keep shown</p>"])
    }

    /// A tracked deletion is not read, a tracked insertion is; a comment
    /// (`office:annotation`) is not read; a picture is read as its
    /// description, after the paragraph that holds its anchor.
    func testTrackedDeletionsAndCommentsAreNotReadAndAPictureIsItsDescription() throws {
        let lines = try odfLines(
            """
            <text:tracked-changes><text:changed-region text:id="c"><text:deletion>\
            <text:p>deleted paragraph</text:p></text:deletion></text:changed-region></text:tracked-changes>\
            <text:p>after<text:change-start text:change-id="c"/> inserted <text:change-end text:change-id="c"/>text\
            <office:annotation><text:p>a comment</text:p></office:annotation>\
            <draw:frame><draw:image><office:binary-data>AAAA</office:binary-data></draw:image><svg:desc>alt words</svg:desc></draw:frame>\
            </text:p>
            """
        )
        XCTAssertEqual(lines, ["<p>after inserted text</p>", "<p>alt words</p>"])
    }

    /// A picture, formula, chart, or shape is read as its description
    /// (`svg:desc`, or else `svg:title`) in a paragraph after the one that
    /// holds its anchor, so the sentence stays whole; one with neither is
    /// silent, and so is one anchored in hidden text. The description of a
    /// frame anchored to the page is a paragraph of its own.
    func testPicturesAreReadAsTheirDescriptions() throws {
        let lines = try odfLines(
            """
            <text:p>One <draw:frame><draw:image/><svg:title>T1</svg:title><svg:desc>Described</svg:desc></draw:frame> two.</text:p>\
            <text:p>Three <draw:frame><draw:image/><svg:title>Only title</svg:title></draw:frame> four.</text:p>\
            <text:p>Five <draw:frame><draw:image/></draw:frame> six.</text:p>\
            <text:p>Seven <draw:custom-shape><svg:desc>A shape</svg:desc></draw:custom-shape> eight.</text:p>\
            <text:p>Nine <draw:frame><draw:object/><svg:desc>A formula</svg:desc></draw:frame> ten.</text:p>\
            <text:p>Hid <text:span text:style-name="Gone"><draw:frame><svg:desc>Hidden picture</svg:desc></draw:frame></text:span> end.</text:p>\
            <draw:frame><draw:image/><svg:desc>Anchored to the page</svg:desc></draw:frame>
            """,
            styles: gone
        )
        XCTAssertEqual(lines, [
            "<p>One two.</p>", "<p>Described</p>", "<p>Three four.</p>", "<p>Only title</p>", "<p>Five six.</p>",
            "<p>Seven eight.</p>", "<p>A shape</p>", "<p>Nine ten.</p>", "<p>A formula</p>", "<p>Hid end.</p>",
            "<p>Anchored to the page</p>",
        ])
    }

    /// A phonetic guide is not read, only the word it guides; the fields
    /// are read for their results; the source an index is made from is not
    /// read, even where its words lie in a paragraph (an index in a text box
    /// anchored in one), and its entries are.
    func testRubyFieldsAndIndexSources() throws {
        let lines = try odfLines(
            """
            <text:p>Say <text:ruby><text:ruby-base>base</text:ruby-base><text:ruby-text>guide</text:ruby-text></text:ruby> \
            on <text:date>1 January</text:date> page <text:page-number>7</text:page-number>.\
            <draw:frame><draw:text-box><text:table-of-content><text:table-of-content-source>\
            <text:index-title-template>Template</text:index-title-template></text:table-of-content-source>\
            <text:index-body><text:p>Entry one</text:p></text:index-body></text:table-of-content></draw:text-box></draw:frame></text:p>
            """
        )
        XCTAssertEqual(lines, ["<p>Say base on 1 January page 7.</p>", "<p>Entry one</p>"])
    }

    // MARK: - Notes and Text Boxes

    /// A note's body follows the main text, in the order the file keeps the
    /// notes, without its mark and without a heading; the paragraph around
    /// the note goes on.
    func testNotesFollowTheMainText() throws {
        let lines = try odfLines(
            """
            <text:p>First<text:note text:note-class="footnote"><text:note-citation>1</text:note-citation>\
            <text:note-body><text:p>Foot text</text:p></text:note-body></text:note> goes on.</text:p>\
            <text:p>Second<text:note text:note-class="endnote"><text:note-citation>i</text:note-citation>\
            <text:note-body><text:p>End text</text:p><text:p>More end text</text:p></text:note-body></text:note>.</text:p>
            """
        )
        XCTAssertEqual(lines, [
            "<p>First goes on.</p>", "<p>Second.</p>", "<p>Foot text</p>", "<p>End text</p>", "<p>More end text</p>",
        ])
    }

    // MARK: - Lists

    /// A list is bulleted or numbered by its style's level, nested lists go
    /// deeper, a heading in a list stays a heading, and the lists of
    /// OpenDocument 1.1 say what they are.
    func testListsAreMarkedByTheirStyles() throws {
        let lines = try odfLines(
            """
            <text:list text:style-name="N"><text:list-item><text:p>one</text:p>\
            <text:list><text:list-item><text:p>sub</text:p></text:list-item></text:list></text:list-item>\
            <text:list-item><text:h text:outline-level="3">numbered heading</text:h></text:list-item>\
            <text:list-item><text:p>two</text:p></text:list-item></text:list>\
            <text:p>Between</text:p>\
            <text:ordered-list><text:list-item><text:p>old ordered</text:p></text:list-item></text:ordered-list>\
            <text:p>Between</text:p>\
            <text:unordered-list><text:list-item><text:p>old bullet</text:p></text:list-item></text:unordered-list>\
            <text:p>Between</text:p>\
            <text:list><text:list-item><text:p>no style</text:p></text:list-item></text:list>
            """,
            styles: """
            <text:list-style style:name="N"><text:list-level-style-number text:level="1" style:num-format="1"/>\
            <text:list-level-style-bullet text:level="2" text:bullet-char="x"/></text:list-style>
            """
        )
        XCTAssertEqual(lines, [
            "<ol>", "<li>one<ul>", "<li>sub</li>", "</ul>", "</li>", "</ol>",
            "<h3>numbered heading</h3>",
            "<ol>", "<li>two</li>", "</ol>",
            "<p>Between</p>",
            "<ol>", "<li>old ordered</li>", "</ol>",
            "<p>Between</p>",
            "<ul>", "<li>old bullet</li>", "</ul>",
            "<p>Between</p>",
            "<ul>", "<li>no style</li>", "</ul>",
        ])
    }

    /// A list whose level shows no mark reads its items as paragraphs, and a
    /// list named by the paragraph's style is read by that style.
    func testListLevelsWithoutMarksAndListsNamedByTheParagraphStyle() throws {
        let lines = try odfLines(
            """
            <text:list text:style-name="None"><text:list-item><text:p>unmarked</text:p></text:list-item></text:list>\
            <text:list><text:list-item><text:p text:style-name="Lettered">lettered</text:p></text:list-item></text:list>
            """,
            styles: """
            <text:list-style style:name="None"><text:list-level-style-number text:level="1" style:num-format=""/></text:list-style>\
            <text:list-style style:name="Letters"><text:list-level-style-number text:level="1" style:num-format="a"/></text:list-style>\
            <style:style style:name="Lettered" style:family="paragraph" style:list-style-name="Letters"/>
            """
        )
        XCTAssertEqual(lines, ["<p>unmarked</p>", "<ol>", "<li>lettered</li>", "</ol>"])
    }

    // MARK: - Tables

    /// Tables keep their rows and cells; a table in a cell is read into the
    /// cell; a covered cell leaves no cell; a cell repeated a million times
    /// is one cell; two tables apart are two tables; a table that is not
    /// displayed is not read.
    func testTables() throws {
        let lines = try odfLines(
            """
            <table:table><table:table-header-rows><table:table-row><table:table-cell><text:p>Head</text:p></table:table-cell>\
            </table:table-row></table:table-header-rows><table:table-row><table:table-cell><text:p>A1</text:p>\
            <table:table><table:table-row><table:table-cell><text:p>nested</text:p></table:table-cell></table:table-row></table:table>\
            </table:table-cell><table:covered-table-cell><text:p>covered</text:p></table:covered-table-cell>\
            <table:table-cell table:number-columns-repeated="1000000"/></table:table-row></table:table>\
            <table:table><table:table-row><table:table-cell><text:p>second</text:p></table:table-cell></table:table-row></table:table>\
            <table:table table:display="false"><table:table-row><table:table-cell><text:p>unseen</text:p></table:table-cell></table:table-row>\
            </table:table>
            """
        )
        // The cell repeated a million times is read 16 times, the most a cell is repeated.
        XCTAssertEqual(lines, [
            "<table>", "<tr><td><p>Head</p></td></tr>",
            "<tr><td><p>A1</p><p>nested</p></td>" + String(repeating: "<td></td>", count: 16) + "</tr>", "</table>",
            "<table>", "<tr><td><p>second</p></td></tr>", "</table>",
        ])
    }

    // MARK: - Pages

    /// Pages begin at a style's break before and break after (the paragraph
    /// after "Ends a page." has no break of its own), at a paragraph or
    /// table that names a master page, and at the layout's soft page breaks;
    /// breaks that meet before a word are one page, but a blank paragraph
    /// between two breaks is a page of its own; a break in hidden text
    /// begins none; the first words are on page 1 already.
    func testPagesBeginWhereTheFileBreaksThem() throws {
        let lines = try odfLines(
            """
            <text:p text:style-name="Chap">Chapter one starts the document.</text:p>\
            <text:p>Body text.<text:soft-page-break/> more text on page two.</text:p>\
            <text:p text:style-name="After">Ends a page.</text:p>\
            <text:p>Plain after the break.</text:p>\
            <text:p text:style-name="Hid">hidden break</text:p>\
            <text:p text:style-name="Chap">Chapter two.</text:p>\
            <text:p text:style-name="Master">Master page.</text:p>\
            <text:soft-page-break/><table:table table:style-name="TB"><table:table-row><table:table-cell>\
            <text:p>In table</text:p></table:table-cell></table:table-row></table:table>\
            <text:p text:style-name="Chap">   </text:p><text:p text:style-name="Chap">Last.</text:p>
            """,
            styles: """
            <style:style style:name="Chap" style:family="paragraph"><style:paragraph-properties fo:break-before="page"/></style:style>\
            <style:style style:name="After" style:family="paragraph"><style:paragraph-properties fo:break-after="page"/></style:style>\
            <style:style style:name="Hid" style:family="paragraph"><style:paragraph-properties fo:break-before="page"/>\
            <style:text-properties text:display="none"/></style:style>\
            <style:style style:name="Master" style:family="paragraph" style:master-page-name="Landscape"/>\
            <style:style style:name="TB" style:family="table" style:master-page-name="Standard"/>
            """,
            pages: true
        )
        XCTAssertEqual(lines, [
            page(1) + "<p>Chapter one starts the document.</p>",
            "<p>Body text. \(page(2))more text on page two.</p>",
            "<p>Ends a page.</p>",
            "<p>\(page(3))Plain after the break.</p>",
            "<p>\(page(4))Chapter two.</p>",
            "<p>\(page(5))Master page.</p>",
            "<table>",
            "<tr><td><p>\(page(6))In table</p></td></tr>",
            "</table>",
            "<p>\(page(7))\(page(8))Last.</p>",
        ])
    }

    /// A table's own style breaks the page before and after it; a break in a
    /// cell or a text box is not a page (a page cannot begin there); a
    /// paragraph whose only words are a hidden field begins no page.
    func testTableStylesBreakPagesButCellsAndHiddenFieldsDoNot() throws {
        let styles = """
            <style:style style:name="TA" style:family="table"><style:table-properties fo:break-after="page"/></style:style>\
            <style:style style:name="TBefore" style:family="table"><style:table-properties fo:break-before="page"/></style:style>\
            <style:style style:name="Chap" style:family="paragraph"><style:paragraph-properties fo:break-before="page"/></style:style>
            """
        let lines = try odfLines(
            """
            <text:p>Before.</text:p><table:table table:style-name="TBefore"><table:table-row><table:table-cell>\
            <text:p text:style-name="Chap">In first.</text:p></table:table-cell></table:table-row></table:table>\
            <table:table table:style-name="TA"><table:table-row><table:table-cell><text:p>In second.</text:p>\
            </table:table-cell></table:table-row></table:table><text:p>Tail.</text:p>\
            <text:p text:style-name="Chap"><text:hidden-text text:is-hidden="true">x</text:hidden-text></text:p>\
            <text:p>Same page.</text:p>\
            <text:p>Box <draw:frame><draw:text-box><text:p text:style-name="Chap">In a box.</text:p></draw:text-box></draw:frame></text:p>
            """,
            styles: styles,
            pages: true
        )
        XCTAssertEqual(lines, [
            page(1) + "<p>Before.</p>",
            "<table>", "<tr><td><p>\(page(2))In first.</p></td></tr>", "</table>",
            "<table>", "<tr><td><p>In second.</p></td></tr>", "</table>",
            "<p>\(page(3))Tail.</p>",
            "<p>Same page.</p>",
            "<p>Box </p>", "<p>In a box.</p>",
        ])
    }

    /// The layout's soft page breaks: one before any words begins a page;
    /// one adds no space inside a word; a row of a table has one, however
    /// many of its cells the layout broke.
    func testSoftPageBreaks() throws {
        let lines = try odfLines(
            """
            <text:soft-page-break/><text:p>First words.</text:p><text:p>exam<text:soft-page-break/>ple</text:p>\
            <table:table><table:table-row><table:table-cell><text:p>A<text:soft-page-break/> a</text:p></table:table-cell>\
            <table:table-cell><text:p>B<text:soft-page-break/> b</text:p></table:table-cell></table:table-row></table:table>
            """,
            pages: true
        )
        XCTAssertEqual(lines, [
            page(1) + "<p>\(page(2))First words.</p>",
            "<p>exam\(page(3))ple</p>",
            "<table>", "<tr><td><p>A \(page(4))a</p></td><td><p>B b</p></td></tr>", "</table>",
        ])
    }

    /// Without pages asked for, no page element is written.
    func testNoPagesWhenNotAskedFor() throws {
        let lines = try odfLines(
            "<text:p>One</text:p><text:p text:style-name=\"Chap\">Two</text:p>",
            styles: "<style:style style:name=\"Chap\" style:family=\"paragraph\"><style:paragraph-properties fo:break-before=\"page\"/></style:style>"
        )
        XCTAssertEqual(lines, ["<p>One</p>", "<p>Two</p>"])
    }

    /// Notes are not paged: a break inside a note begins no page, in the main
    /// text that follows either (a page that waited in the note would begin
    /// at the next words of the main text).
    func testABreakInANoteBeginsNoPage() throws {
        let lines = try odfLines(
            """
            <text:p>Main<text:note><text:note-citation>1</text:note-citation><text:note-body>\
            <text:p text:style-name="Chap">Note words</text:p></text:note-body></text:note>.</text:p><text:p>Then more.</text:p>
            """,
            styles: "<style:style style:name=\"Chap\" style:family=\"paragraph\"><style:paragraph-properties fo:break-before=\"page\"/></style:style>",
            pages: true
        )
        XCTAssertEqual(lines, [page(1) + "<p>Main.</p>", "<p>Then more.</p>", "<p>Note words</p>"])
    }

    // MARK: - The Names

    /// The title and author come from `meta.xml`; `meta:initial-creator`
    /// stands in for an author the document does not name.
    func testTitleAndAuthorComeFromTheMetadata() throws {
        let content = odfContent(body: "<text:p>Words</text:p>")
        let named = try makeODT(content: content, meta: odfMeta(
            "<dc:title>The &amp; Title</dc:title><dc:creator>Ada Quill</dc:creator><meta:initial-creator>First</meta:initial-creator>"
        ))
        let html = try ODTDocumentReader.html(of: named, includesPages: false)
        XCTAssertTrue(html.contains("<title>The &amp; Title</title>"))
        XCTAssertTrue(html.contains("<meta name=\"author\" content=\"Ada Quill\">"))

        let initial = try makeODT(content: content, meta: odfMeta("<meta:initial-creator>First Hand</meta:initial-creator>"))
        XCTAssertTrue(try ODTDocumentReader.html(of: initial, includesPages: false).contains("content=\"First Hand\""))

        let none = try makeODT(content: content)
        let plain = try ODTDocumentReader.html(of: none, includesPages: false)
        XCTAssertFalse(plain.contains("<title>"))
        XCTAssertFalse(plain.contains("name=\"author\""))
    }

    /// Damaged metadata loses the names and nothing else.
    func testDamagedMetadataLosesOnlyTheNames() throws {
        let url = try makeODT(content: odfContent(body: "<text:p>Words</text:p>"), meta: "<office:document-meta><broken")
        let html = try ODTDocumentReader.html(of: url, includesPages: false)
        XCTAssertEqual(odfBodyLines(html), ["<p>Words</p>"])
        XCTAssertFalse(html.contains("<title>"))
    }

    // MARK: - What Is Refused

    /// The sentence for a file that cannot be read.
    private var unreadable: TextutilConverter.Failure { .unreadable(.odt) }

    /// A package of another kind of document, a file that is no archive, and
    /// a package with no content are refused with the sentence for an
    /// unreadable document; an empty file has no text to read.
    func testFilesThatAreNotOpenDocumentTextAreRefused() throws {
        let spreadsheet = try makeODT(
            content: odfContent(body: ""), mediaType: "application/vnd.oasis.opendocument.spreadsheet"
        )
        XCTAssertThrowsError(try ODTDocumentReader.html(of: spreadsheet, includesPages: true)) {
            XCTAssertEqual($0 as? TextutilConverter.Failure, unreadable)
        }

        let notAnArchive = try makeSandboxDirectory("ODTRefused").appendingPathComponent("plain.odt")
        try Data("Just some words, no archive.".utf8).write(to: notAnArchive)
        XCTAssertThrowsError(try ODTDocumentReader.html(of: notAnArchive, includesPages: true)) {
            XCTAssertEqual($0 as? TextutilConverter.Failure, unreadable)
        }

        let noContent = try makeODT(entries: [TestZIPEntry("mimetype", Data("application/vnd.oasis.opendocument.text".utf8))])
        XCTAssertThrowsError(try ODTDocumentReader.html(of: noContent, includesPages: true)) {
            XCTAssertEqual($0 as? TextutilConverter.Failure, unreadable)
        }

        let empty = try makeSandboxDirectory("ODTRefused").appendingPathComponent("empty.odt")
        try Data().write(to: empty)
        XCTAssertThrowsError(try ODTDocumentReader.html(of: empty, includesPages: true)) { error in
            guard case .noTextToRead? = error as? FileImportError else { return XCTFail("\(error)") }
        }
    }

    /// A damaged media type is ignored: one that is too long, junk, or empty
    /// says nothing, and the book reads. Only a type that says another kind
    /// of OpenDocument document refuses.
    func testADamagedMediaTypeIsIgnored() throws {
        let content = odfContent(body: "<text:p>Words</text:p>")
        for (label, mediaType) in [
            ("too long", String(repeating: "x", count: 340)),
            ("junk", "\u{1}\u{2}\u{FFFD}"),
            ("empty", ""),
            ("another kind of package", "application/vnd.sun.xml.writer"),
        ] {
            let url = try makeODT(content: content, mediaType: mediaType)
            XCTAssertEqual(odfBodyLines(try ODTDocumentReader.html(of: url, includesPages: false)), ["<p>Words</p>"], label)
        }
        // A wrong checksum on it is no reason to refuse the book either.
        let wrongChecksum = try makeODT(content: content, compression: .deflate)
        try setRecordedChecksum(of: "mimetype", in: wrongChecksum, to: 1)
        XCTAssertEqual(odfBodyLines(try ODTDocumentReader.html(of: wrongChecksum, includesPages: false)), ["<p>Words</p>"])
    }

    /// A package may leave out its media type, and may name a template,
    /// master, or web form; each reads.
    func testTheMediaTypeMayBeAbsentOrAnotherOpenDocumentTextType() throws {
        let content = odfContent(body: "<text:p>Words</text:p>")
        for mediaType in [nil, "application/vnd.oasis.opendocument.text-template", "application/vnd.oasis.opendocument.text-master"] {
            let url = try makeODT(content: content, mediaType: mediaType)
            XCTAssertEqual(odfBodyLines(try ODTDocumentReader.html(of: url, includesPages: false)), ["<p>Words</p>"], mediaType ?? "none")
        }
    }

    /// A document with a password is refused with its own sentence by the
    /// import path, before the reader sees it: the check covers an
    /// OpenDocument package whatever reader is on, and the template too.
    func testAPasswordProtectedDocumentIsRefusedBeforeTheReaderReadsIt() throws {
        for sample in ["odt/handwritten.odt", "ott/handwritten.ott"] {
            let copy = try copyOfFormatSample(sample)
            try replaceManifest(in: copy, with: encryptedManifest)
            XCTAssertThrowsError(try TextutilDocumentReader.extract(from: copy, bookFormat: .odt), sample) {
                XCTAssertEqual($0 as? PasswordProtectedDocument, PasswordProtectedDocument(), sample)
            }
        }
    }

    // MARK: - Hidden Text, Notes, and Text Boxes

    /// The styles that hide paragraphs and text, break pages, and size text.
    private var gone: String {
        """
        <style:style style:name="Gone" style:family="text"><style:text-properties text:display="none"/></style:style>\
        <style:style style:name="Gone" style:family="paragraph"><style:text-properties text:display="none"/></style:style>\
        <style:style style:name="Chap" style:family="paragraph"><style:paragraph-properties fo:break-before="page"/></style:style>\
        <style:style style:name="Big" style:family="paragraph"><style:text-properties fo:font-size="24pt"/></style:style>\
        <style:style style:name="GoneP" style:family="paragraph"><style:text-properties text:display="none"/></style:style>\
        <style:style style:name="Show" style:family="text"><style:text-properties text:display="true"/></style:style>
        """
    }

    /// A text box is read right after the paragraph that holds its anchor,
    /// not in the middle of its sentence: also in a table cell. A box
    /// anchored in hidden text is not read.
    func testATextBoxFollowsTheParagraphThatHoldsItsAnchor() throws {
        let lines = try odfLines(
            """
            <text:p>Before <draw:frame><draw:text-box><text:p>Boxed words</text:p><text:p>Second box line</text:p>\
            </draw:text-box></draw:frame> after.</text:p>\
            <text:p>Hid <text:span text:style-name="Gone"><draw:frame><draw:text-box><text:p>Hidden box</text:p>\
            </draw:text-box></draw:frame></text:span>end.</text:p>\
            <text:p text:style-name="Gone">All hidden <draw:frame><draw:text-box><text:p>Box in hidden paragraph</text:p>\
            </draw:text-box></draw:frame></text:p>\
            <text:p>Dropped<draw:frame><draw:text-box><text:p>Box in hidden-paragraph field</text:p></draw:text-box></draw:frame>\
            <text:hidden-paragraph text:condition="x" text:is-hidden="true"/></text:p>\
            <table:table><table:table-row><table:table-cell><text:p>Cell <draw:frame><draw:text-box>\
            <text:p>Cell box</text:p></draw:text-box></draw:frame>text.</text:p></table:table-cell></table:table-row></table:table>
            """,
            styles: gone
        )
        XCTAssertEqual(lines, [
            "<p>Before after.</p>", "<p>Boxed words</p>", "<p>Second box line</p>", "<p>Hid end.</p>",
            "<table>", "<tr><td><p>Cell text.</p><p>Cell box</p></td></tr>", "</table>",
        ])
    }

    /// A note is read only if a person would see its reference: not one in a
    /// hidden span, a paragraph hidden by a field after the note, a hidden
    /// section, or tracked deleted content.
    func testANoteInHiddenOrDeletedTextIsNotRead() throws {
        let lines = try odfLines(
            """
            <text:tracked-changes><text:changed-region text:id="c"><text:deletion><text:p>Deleted\
            <text:note><text:note-citation>9</text:note-citation><text:note-body><text:p>Deleted note</text:p></text:note-body></text:note>\
            </text:p></text:deletion></text:changed-region></text:tracked-changes>\
            <text:p>Gone<text:note><text:note-citation>1</text:note-citation><text:note-body><text:p>Note of hidden paragraph</text:p>\
            </text:note-body></text:note><text:hidden-paragraph text:condition="x" text:is-hidden="true"/></text:p>\
            <text:p>Hid <text:span text:style-name="Gone">x<text:note><text:note-citation>2</text:note-citation><text:note-body>\
            <text:p>Note in hidden span</text:p></text:note-body></text:note></text:span>end.</text:p>\
            <text:section text:display="none"><text:p>Sect<text:note><text:note-citation>3</text:note-citation><text:note-body>\
            <text:p>Note in hidden section</text:p></text:note-body></text:note></text:p></text:section>\
            <text:p>Kept<text:note><text:note-citation>4</text:note-citation><text:note-body><text:p>Kept note</text:p></text:note-body>\
            </text:note>.</text:p>
            """,
            styles: gone
        )
        XCTAssertEqual(lines, ["<p>Hid end.</p>", "<p>Kept.</p>", "<p>Kept note</p>"])
    }

    /// A page break through a style, or a master page, on a paragraph that
    /// holds only hidden words begins no page; a heading whose words are all
    /// hidden writes no heading and does not turn off the guess at headings.
    func testHiddenWordsBeginNoPageAndNameNoHeading() throws {
        let lines = try odfLines(
            """
            <text:h text:outline-level="1"><text:span text:style-name="Gone">all hidden heading</text:span></text:h>\
            <text:p text:style-name="Big">Large words</text:p>\
            <text:p>Body words here are many enough to be the body size.</text:p>\
            <text:p text:style-name="Chap"><text:span text:style-name="Gone">only hidden words</text:span></text:p>\
            <text:p>More body words to outweigh the large one entirely.</text:p>
            """,
            styles: gone,
            pages: true
        )
        XCTAssertEqual(lines, [
            page(1) + "<h1>Large words</h1>",
            "<p>Body words here are many enough to be the body size.</p>",
            "<p>More body words to outweigh the large one entirely.</p>",
        ])
    }

    /// A tracked change's rules: the deleted text lives only under
    /// `text:tracked-changes`, so the body between `text:change-start` and
    /// `text:change-end` is the text a person sees, and a `text:change` point
    /// marks only where a deletion was.
    func testChangeMarkersAndTrackedDeletions() throws {
        let lines = try odfLines(
            """
            <text:tracked-changes>\
            <text:changed-region text:id="ins"><text:insertion/></text:changed-region>\
            <text:changed-region text:id="del"><text:deletion><text:p>removed words</text:p></text:deletion></text:changed-region>\
            <text:changed-region text:id="fmt"><text:format-change/></text:changed-region>\
            </text:tracked-changes>\
            <text:p>Kept <text:change-start text:change-id="ins"/>added words<text:change-end text:change-id="ins"/> and\
            <text:change text:change-id="del"/> <text:change-start text:change-id="fmt"/>reformatted<text:change-end text:change-id="fmt"/>.</text:p>
            """
        )
        XCTAssertEqual(lines, ["<p>Kept added words and reformatted.</p>"])
    }

    // MARK: - What a Listener Hears

    /// The reading text writes no list marker, so the numbers of a numbered
    /// list are not heard, nor is the number a heading or an item shows
    /// (`text:number`): the heading is its words. textutil's reading has the
    /// number, run into the heading's first word ("1.1Intro"), which the own
    /// reader leaves out as it leaves out every automatic number.
    func testNoNumberIsHeardOfListsOrNumberedHeadings() throws {
        let heard = try odfHeard(
            """
            <text:h text:outline-level="1"><text:number>1.1</text:number>Intro</text:h>\
            <text:ordered-list><text:list-item><text:p><text:number>7.</text:number>first</text:p></text:list-item>\
            <text:list-item><text:p>second</text:p></text:list-item><text:list-item><text:p>third</text:p></text:list-item></text:ordered-list>
            """
        )
        XCTAssertEqual(heard.filter { $0.contains(where: \.isNumber) }, [])
        XCTAssertEqual(heard.filter { ["first", "second", "third", "Intro"].contains($0) }.sorted(), ["Intro", "first", "second", "third"])
    }

    /// A line break, a tab, a no-break space, and a soft hyphen join no
    /// words and are spoken as nothing odd: the first three are spacing, the
    /// last is not there. Splitting on white space counts a no-break space as
    /// a space, so the HTML is checked as well: it holds a plain space.
    func testSpacingCharactersJoinNoWordsAndAreNotSpoken() throws {
        let heard = try odfHeard(
            "<text:p>one<text:line-break/>two<text:tab/>three<text:s text:c=\"2\"/>four \u{00A0}five\u{00A0}six co\u{00AD}operate</text:p>"
        )
        XCTAssertEqual(heard, ["one", "two", "three", "four", "five", "six", "cooperate"])
        XCTAssertEqual(try odfLines("<text:p>a\u{00A0}b\u{202F}c co\u{00AD}op</text:p>"), ["<p>a b c coop</p>"])
    }

    // MARK: - Fields, Bodies, and Cells

    /// Two `text:hidden-paragraph` fields, one hiding and one not, keep the
    /// paragraph; all hiding drops it; a paragraph whose style hides it shows
    /// the span that shows itself; a variable field with `text:display="none"`
    /// is hidden and one that shows its value is read.
    func testHiddenParagraphFieldsStyleSpansAndVariableFields() throws {
        let lines = try odfLines(
            """
            <text:p>Kept<text:hidden-paragraph text:is-hidden="true"/><text:hidden-paragraph text:is-hidden="false"/></text:p>\
            <text:p>Dropped<text:hidden-paragraph text:is-hidden="true"/><text:hidden-paragraph text:is-hidden="true"/></text:p>\
            <text:p text:style-name="GoneP">Hidden <text:span text:style-name="Show">shown</text:span> hidden</text:p>\
            <text:p>Var <text:variable-set text:display="none">secret</text:variable-set>shown \
            <text:user-field-get text:display="none">x</text:user-field-get><text:variable-set text:display="value">seen</text:variable-set> end.</text:p>
            """,
            styles: gone
        )
        XCTAssertEqual(lines, ["<p>Kept</p>", "<p>shown</p>", "<p>Var shown seen end.</p>"])
    }

    /// The body begins at the first child of `office:body` that is a text
    /// document, whatever it is named; a spreadsheet's is not read.
    func testTheBodyMayBeNamedOtherThanOfficeText() throws {
        func read(_ body: String) throws -> [String] {
            let content = """
                <?xml version="1.0"?><office:document-content \(Self.odfNamespaces)><office:body>\(body)</office:body></office:document-content>
                """
            return odfBodyLines(try ODTDocumentReader.html(of: makeODT(content: content), includesPages: false))
        }
        XCTAssertEqual(try read("<office:texture-mode><text:p>Misnamed body</text:p></office:texture-mode>"), ["<p>Misnamed body</p>"])
        XCTAssertEqual(try read("<office:spreadsheet><text:p>not text</text:p></office:spreadsheet>"), [])
    }

    /// An element of the text namespace written with the namespace as the
    /// default, not under a prefix, is read.
    func testTheDefaultNamespaceIsRead() throws {
        let content = """
            <?xml version="1.0"?><office:document-content \(Self.odfNamespaces)><office:body><office:text>\
            <p xmlns="urn:oasis:names:tc:opendocument:xmlns:text:1.0">Default namespace</p></office:text></office:body>\
            </office:document-content>
            """
        XCTAssertEqual(odfBodyLines(try ODTDocumentReader.html(of: makeODT(content: content), includesPages: false)), ["<p>Default namespace</p>"])
    }

    /// An empty `style:default-outline-level` declares no level and is not
    /// inherited from the style this one is based on.
    func testAnEmptyOutlineLevelDeclaresNoLevel() throws {
        let lines = try odfLines(
            """
            <text:p text:style-name="Plain">Not a heading</text:p><text:p text:style-name="Named">A heading</text:p>
            """,
            styles: """
            <style:style style:name="H1" style:family="paragraph" style:default-outline-level="1"/>\
            <style:style style:name="Plain" style:family="paragraph" style:parent-style-name="H1" style:default-outline-level=""/>\
            <style:style style:name="Named" style:family="paragraph" style:parent-style-name="H1"/>
            """
        )
        XCTAssertEqual(lines, ["<p>Not a heading</p>", "<h1>A heading</h1>"])
    }

    /// A cell a file repeats is read that many times, up to a limit; an
    /// empty one is that many empty cells.
    func testRepeatedCellsAreReadWithACap() throws {
        let html = try odfLines(
            """
            <table:table><table:table-row><table:table-cell table:number-columns-repeated="3"><text:p>cell</text:p></table:table-cell>\
            <table:table-cell table:number-columns-repeated="2"/>\
            <table:table-cell table:number-columns-repeated="999999999"><text:p>many</text:p></table:table-cell></table:table-row></table:table>
            """
        )
        let cells = html[1].components(separatedBy: "<td").dropFirst()
        XCTAssertEqual(cells.count, 3 + 2 + 16)
        XCTAssertEqual(cells.filter { $0.contains("cell") }.count, 3)
        XCTAssertEqual(cells.filter { $0.contains("many") }.count, 16)
    }

    /// A list in a text box starts at its own level, a list header is not an
    /// item, and a list nested 95 deep (193 elements deep, under the 200 the
    /// reader allows, and past the 40 list levels it tells apart) is read to
    /// its words. One nested 100 deep is 203 elements deep, past the limit,
    /// and is refused.
    func testListsInTextBoxesListHeadersAndDeepLists() throws {
        XCTAssertEqual(try odfLines(
            """
            <text:list><text:list-item><text:p>outer<draw:frame><draw:text-box><text:list><text:list-item>\
            <text:p>inner</text:p></text:list-item></text:list></draw:text-box></draw:frame></text:p></text:list-item></text:list>
            """
        ), ["<ul>", "<li>outer</li>", "<li>inner</li>", "</ul>"])
        XCTAssertEqual(try odfLines(
            "<text:list><text:list-header><text:p>Header words</text:p></text:list-header><text:list-item><text:p>item</text:p></text:list-item></text:list>"
        ), ["<p>Header words</p>", "<ul>", "<li>item</li>", "</ul>"])
        let deep = (0..<95).map { "<text:list><text:list-item><text:p>level \($0)</text:p>" }.joined()
            + String(repeating: "</text:list-item></text:list>", count: 95)
        let words = try odfHeard(deep).filter { $0.allSatisfy(\.isNumber) }
        XCTAssertEqual(words, (0..<95).map(String.init))
        // The limit is on the elements' depth (200), not on the lists: 100
        // levels of lists, with the three elements above them, is past it.
        let tooDeep = (0..<100).map { "<text:list><text:list-item><text:p>level \($0)</text:p>" }.joined()
            + String(repeating: "</text:list-item></text:list>", count: 100)
        XCTAssertThrowsError(try odfLines(tooDeep)) {
            XCTAssertEqual($0 as? TextutilConverter.Failure, .unreadable(.odt))
        }
    }

    /// A heading only in a table or in a note does not turn off the guess at
    /// headings; a script, an embedded object, and a table's title and
    /// description (also in a text box) are not read.
    func testHeadingsInTablesAndNotesScriptsObjectsAndTableTitles() throws {
        let lines = try odfLines(
            """
            <table:table><table:table-row><table:table-cell><text:h text:outline-level="1">In a cell</text:h>\
            </table:table-cell></table:table-row></table:table>\
            <text:p text:style-name="Big">Large words</text:p>\
            <text:p>Body words here are many enough to be the body size.</text:p>\
            <text:p>More body words to outweigh the large one entirely.</text:p>\
            <text:p>Ref<text:note><text:note-citation>1</text:note-citation><text:note-body>\
            <text:h text:outline-level="1">In a note</text:h></text:note-body></text:note></text:p>\
            <text:p>Words<text:script>secret script</text:script> <draw:frame><draw:object><office:document>\
            <text:p>inside object</text:p></office:document></draw:object></draw:frame> end.\
            <draw:frame><draw:text-box><table:table><table:title>Alt title</table:title><table:desc>Alt desc</table:desc>\
            <table:table-row><table:table-cell><text:p>cell</text:p></table:table-cell></table:table-row></table:table>\
            </draw:text-box></draw:frame></text:p>
            """,
            styles: gone
        )
        XCTAssertEqual(lines, [
            "<table>", "<tr><td><p>In a cell</p></td></tr>", "</table>",
            "<h1>Large words</h1>",
            "<p>Body words here are many enough to be the body size.</p>",
            "<p>More body words to outweigh the large one entirely.</p>",
            "<p>Ref</p>", "<p>Words end.</p>", "<table>", "<tr><td><p>cell</p></td></tr>", "</table>",
            "<h1>In a note</h1>",
        ])
    }

    // MARK: - A Damaged Optional Part

    /// A damaged, cut-off, or oversized `styles.xml` or `meta.xml` does not
    /// refuse the book: its body is read, the damage is reported by the
    /// closure, and what the part gave (the headings of its styles, or the
    /// title) is missing. Only `content.xml` refuses the book.
    func testADamagedOptionalPartIsReportedAndTheBookIsRead() throws {
        let content = odfContent(body: "<text:p text:style-name=\"Heading_20_1\">Named by styles</text:p><text:p>Words</text:p>")
        let goodStyles = odfStyles(
            "<style:style style:name=\"Heading_20_1\" style:family=\"paragraph\" style:default-outline-level=\"1\"/>"
        )
        for (label, styles, meta) in [
            ("a cut-off styles part", String(goodStyles.dropLast(60)), odfMeta("<dc:title>T</dc:title>")),
            ("an unreadable meta part", goodStyles, "<office:document-meta><dc:title>cut"),
        ] {
            let url = try makeODT(content: content, styles: styles, meta: meta)
            var reported: [String] = []
            let html = try ODTDocumentReader.html(of: url, includesPages: false) { reported.append($0.file) }
            XCTAssertEqual(reported.count, 1, label)
            XCTAssertTrue(odfBodyLines(html).contains("<p>Words</p>"), label)
        }
        // A part over the limit is a damaged part too, told in the package's words.
        let big = try makeODT(
            content: content, meta: odfMeta("<dc:title>" + String(repeating: "t", count: 200_000) + "</dc:title>"),
            compression: .deflate
        )
        var reported: [ODTPartDamage] = []
        let html = try DocumentByteLimit.$current.withValue(100_000) {
            try ODTDocumentReader.html(of: big, includesPages: false) { reported.append($0) }
        }
        XCTAssertEqual(reported.map(\.file), ["meta.xml"])
        XCTAssertTrue(reported.first?.errorDescription?.contains("meta.xml") == true)
        XCTAssertFalse(html.contains("<title>"))
        let noContent = try makeODT(entries: [TestZIPEntry("styles.xml", Data(goodStyles.utf8))])
        XCTAssertThrowsError(try ODTDocumentReader.html(of: noContent, includesPages: false))
    }

    // MARK: - The Switch

    /// iOS, which has no textutil, always reads OpenDocument text with this
    /// reader, and the Mac does since the reader was checked against
    /// textutil's reading (`ODTTextutilComparisonTests`).
    func testTheSwitchIsOn() {
        XCTAssertTrue(ODTDocumentReader.isOn)
    }
}
