import XCTest
@testable import TextMouth

/// TextMouth's own Word 2003 XML reader (FMT53): what it reads from the
/// samples and from documents built in code, its hostile-file behaviour, and
/// its comparison with textutil's reading of the same files.
final class WordMLReaderTests: XCTestCase {

    // MARK: - Helpers

    /// A page-break element as the reader writes it.
    private func page(_ number: Int) -> String {
        "<span role=\"doc-pagebreak\" aria-label=\"\(number)\"></span>"
    }

    /// The namespaces a Word 2003 XML document declares.
    private let namespaces = """
        xmlns:w="http://schemas.microsoft.com/office/word/2003/wordml" \
        xmlns:wx="http://schemas.microsoft.com/office/word/2003/auxHint" \
        xmlns:aml="http://schemas.microsoft.com/aml/2001/core" \
        xmlns:o="urn:schemas-microsoft-com:office:office" \
        xmlns:v="urn:schemas-microsoft-com:vml"
        """

    /// A Word 2003 XML document with `head` (properties, lists, styles) before
    /// its body, whose body holds `body`.
    private func document(body: String, head: String = "") -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<w:wordDocument \(namespaces) xml:space=\"preserve\">\(head)<w:body><wx:sect>\(body)</wx:sect></w:body></w:wordDocument>"
    }

    /// A file holding `text`, in a folder of this test's own.
    private func file(holding text: String, named name: String = "test.xml") throws -> URL {
        let url = try makeSandboxDirectory("WordML").appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// The body of the HTML the reader makes of `xml`, as lines.
    private func bodyLines(of xml: String, pages: Bool = false) throws -> [String] {
        odfBodyLines(try WordMLDocumentReader.html(of: file(holding: xml), includesPages: pages))
    }

    /// A paragraph of one run holding `text`.
    private func paragraph(_ text: String) -> String {
        "<w:p><w:r><w:t>\(text)</w:t></w:r></w:p>"
    }

    // MARK: - The Samples

    /// textutil's own Word 2003 XML has no styles: its headings come from the
    /// sizes, as they do from textutil's reading, and its bullets become a list.
    func testHeadingsSampleHasItsHeadingsFromSizesAndItsList() throws {
        let html = try WordMLDocumentReader.html(of: copyOfFormatSample("wordml/headings.wordml"), includesPages: false)
        let lines = odfBodyLines(html)
        XCTAssertTrue(html.contains("<meta name=\"author\" content=\"A. Sample\">"))
        XCTAssertEqual(Array(lines.filter { $0.hasPrefix("<h") }.prefix(3)), [
            "<h1>Harbour Notes</h1>", "<h2>Morning Tides</h2>", "<h2>Timetable</h2>",
        ])
        XCTAssertEqual(lines.filter { $0.hasPrefix("<li>") }, [
            "<li>Bread from the bakery on Rue Ménard</li>", "<li>Smoked fish, naïve prices</li>",
            "<li>A newspaper already a day old</li>",
        ])
    }

    /// The one page break textutil keeps is a page.
    func testPageBreaksSampleHasItsOneBreak() throws {
        let html = try WordMLDocumentReader.html(of: copyOfFormatSample("wordml/page-breaks.wordml"), includesPages: true)
        XCTAssertEqual(html.components(separatedBy: "doc-pagebreak").count - 1, 2)
        XCTAssertTrue(odfBodyLines(html).contains("<p>First page paragraph two runs on and \(page(2))continues here.</p>"))
    }

    /// The reading is the same with and without pages, but for the page elements.
    func testTheTextIsTheSameWithAndWithoutPages() throws {
        for sample in ["wordml/headings.wordml", "wordml/page-breaks.wordml"] {
            let copy = try copyOfFormatSample(sample)
            let withPages = try WordMLDocumentReader.html(of: copy, includesPages: true)
            let without = try WordMLDocumentReader.html(of: copy, includesPages: false)
            // The pages add their elements and nothing else.
            XCTAssertEqual(
                withPages.replacingOccurrences(of: "<span role=\"doc-pagebreak\"[^>]*></span>", with: "", options: .regularExpression),
                without,
                sample
            )
        }
    }

    // MARK: - A Document Built to Use Every Rule

    /// A document with styles, lists, a table, hidden text, tracked changes, a
    /// comment, a note, a text box, fields, and page breaks reads by the
    /// policy: what a person sees, in order, notes last.
    func testEveryRule() throws {
        let head = """
            <o:DocumentProperties><o:Title>The Title</o:Title><o:Author>Ada Quill</o:Author></o:DocumentProperties>\
            <w:lists>\
            <w:listDef w:listDefId="0"><w:lvl w:ilvl="0"><w:nfc w:val="0"/></w:lvl><w:lvl w:ilvl="1"><w:nfc w:val="23"/></w:lvl></w:listDef>\
            <w:listDef w:listDefId="1"><w:lvl w:ilvl="0"><w:nfc w:val="23"/></w:lvl></w:listDef>\
            <w:list w:ilfo="1"><w:ilst w:val="0"/></w:list><w:list w:ilfo="2"><w:ilst w:val="1"/></w:list>\
            </w:lists>\
            <w:styles>\
            <w:style w:type="paragraph" w:default="on" w:styleId="Normal"><w:name w:val="Normal"/><w:rPr><w:sz w:val="22"/></w:rPr></w:style>\
            <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>\
            <w:pPr><w:pageBreakBefore/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>\
            <w:style w:type="paragraph" w:styleId="Sub"><w:name w:val="My Sub"/><w:basedOn w:val="Heading1"/></w:style>\
            <w:style w:type="paragraph" w:styleId="Outlined"><w:name w:val="Outlined"/><w:pPr><w:outlineLvl w:val="2"/></w:pPr></w:style>\
            <w:style w:type="paragraph" w:styleId="Gone"><w:name w:val="Gone"/><w:rPr><w:vanish/></w:rPr></w:style>\
            <w:style w:type="paragraph" w:styleId="Loop"><w:name w:val="Loop"/><w:basedOn w:val="Loop"/></w:style>\
            <w:style w:type="character" w:styleId="Strong"><w:name w:val="Strong"/><w:rPr><w:b/></w:rPr></w:style>\
            </w:styles>
            """
        let body = """
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Chapter One</w:t></w:r></w:p>\
            <w:p><w:r><w:t>Plain </w:t></w:r><w:r><w:rPr><w:rStyle w:val="Strong"/></w:rPr><w:t>strong</w:t></w:r>\
            <w:r><w:rPr><w:i/></w:rPr><w:t> slanted</w:t></w:r><w:r><w:rPr><w:vanish/></w:rPr><w:t> secret</w:t></w:r>\
            <w:r><w:delText>deleted</w:delText></w:r><w:r><w:t> end.</w:t></w:r></w:p>\
            <w:p><w:pPr><w:pStyle w:val="Sub"/></w:pPr><w:r><w:t>Based on heading</w:t></w:r></w:p>\
            <w:p><w:pPr><w:pStyle w:val="Outlined"/></w:pPr><w:r><w:t>Outline three</w:t></w:r></w:p>\
            <w:p><w:pPr><w:pStyle w:val="Gone"/></w:pPr><w:r><w:t>Hidden by style</w:t></w:r></w:p>\
            <w:p><w:pPr><w:pStyle w:val="Loop"/></w:pPr><w:r><w:t>Loop style</w:t></w:r></w:p>\
            <w:p><w:pPr><w:listPr><w:ilvl w:val="0"/><w:ilfo w:val="1"/><wx:t wx:val="1."/></w:listPr></w:pPr><w:r><w:t>numbered one</w:t></w:r></w:p>\
            <w:p><w:pPr><w:listPr><w:ilvl w:val="1"/><w:ilfo w:val="1"/><wx:t wx:val="o"/></w:listPr></w:pPr><w:r><w:t>bulleted sub</w:t></w:r></w:p>\
            <w:p><w:pPr><w:listPr><w:ilvl w:val="0"/><w:ilfo w:val="2"/></w:listPr></w:pPr><w:r><w:t>bullet by list</w:t></w:r></w:p>\
            <w:p><w:r><w:t>Table follows</w:t></w:r></w:p>\
            <w:tbl><w:tr><w:tc><w:p><w:r><w:t>A1</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B1</w:t></w:r></w:p></w:tc></w:tr>\
            <w:tr><w:tc><w:p><w:r><w:t>A2</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B2</w:t></w:r></w:p></w:tc></w:tr></w:tbl>\
            <w:p><w:r><w:t>Deletion </w:t></w:r><aml:annotation aml:id="1" w:type="Word.Deletion"><aml:content>\
            <w:r><w:delText>gone words</w:delText></w:r><w:r><w:t>gone t</w:t></w:r></aml:content></aml:annotation>\
            <aml:annotation aml:id="2" w:type="Word.Insertion"><aml:content><w:r><w:t>inserted words</w:t></w:r></aml:content></aml:annotation>\
            <aml:annotation aml:id="3" w:type="Word.Comment"><aml:content><w:p><w:r><w:t>comment text</w:t></w:r></w:p></aml:content></aml:annotation></w:p>\
            <w:p><w:r><w:t>Note here</w:t></w:r><w:r><w:footnote><w:p><w:r><w:footnoteRef/></w:r><w:r><w:t>Foot text</w:t></w:r></w:p></w:footnote></w:r>\
            <w:r><w:t> and on.</w:t></w:r></w:p>\
            <w:p><w:r><w:t>Box: </w:t></w:r><w:r><w:pict><v:shape><v:textbox><w:txbxContent><w:p><w:r><w:t>Boxed words</w:t></w:r></w:p>\
            </w:txbxContent></v:textbox></v:shape></w:pict></w:r><w:r><w:t> after box.</w:t></w:r></w:p>\
            <w:p><w:r><w:t>Field: </w:t></w:r><w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText> PAGE </w:instrText></w:r>\
            <w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>7</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r>\
            <w:fldSimple w:instr=" DATE "><w:r><w:t> today</w:t></w:r></w:fldSimple><w:hlink w:dest="http://x"><w:r><w:t> link</w:t></w:r></w:hlink></w:p>\
            <w:p><w:r><w:t>One</w:t><w:br/><w:t>two</w:t><w:br w:type="page"/><w:t>three</w:t></w:r></w:p>\
            <w:sectPr><w:hdr w:type="odd"><w:p><w:r><w:t>Header words</w:t></w:r></w:p></w:hdr></w:sectPr>
            """
        let xml = document(body: body, head: head)
        let html = try WordMLDocumentReader.html(of: file(holding: xml), includesPages: true)
        XCTAssertTrue(html.contains("<title>The Title</title>"))
        XCTAssertTrue(html.contains("<meta name=\"author\" content=\"Ada Quill\">"))
        XCTAssertEqual(odfBodyLines(html), [
            page(1) + "<h1>Chapter One</h1>",
            "<p>Plain <strong>strong</strong><em> slanted</em> end.</p>",
            "<h1>\(page(2))Based on heading</h1>",
            "<h3>Outline three</h3>",
            "<p>Loop style</p>",
            "<ol>", "<li>numbered one<ul>", "<li>bulleted sub</li>", "</ul>", "</li>", "</ol>",
            "<ul>", "<li>bullet by list</li>", "</ul>",
            "<p>Table follows</p>",
            "<table>",
            "<tr><td><p>A1</p></td><td><p>B1</p></td></tr>",
            "<tr><td><p>A2</p></td><td><p>B2</p></td></tr>",
            "</table>",
            "<p>Deletion inserted words</p>",
            "<p>Note here and on.</p>",
            "<p>Box:  after box.</p>", "<p>Boxed words</p>",
            "<p>Field: 7 today link</p>",
            "<p>One<br>two \(page(3))three</p>",
            "<p>Foot text</p>",
        ])
    }

    /// A text box is read right after the paragraph that holds its anchor;
    /// one in a hidden run is not read; a note in a hidden run, a hidden
    /// paragraph, or a tracked deletion (or moved-from text) is not read.
    func testTextBoxesFollowTheirParagraphAndHiddenNotesAreNotRead() throws {
        let box = "<w:r><w:pict><v:shape><v:textbox><w:txbxContent><w:p><w:r><w:t>Boxed</w:t></w:r></w:p></w:txbxContent></v:textbox></v:shape></w:pict></w:r>"
        let note = "<w:r><w:footnote><w:p><w:r><w:t>Noted</w:t></w:r></w:p></w:footnote></w:r>"
        let hidden = "<w:rPr><w:vanish/></w:rPr>"
        let body = """
            <w:p><w:r><w:t>Before </w:t></w:r>\(box)<w:r><w:t>after.</w:t></w:r></w:p>\
            <w:p><w:r><w:t>Hid </w:t></w:r><w:r>\(hidden)<w:pict><v:shape><v:textbox><w:txbxContent><w:p><w:r><w:t>Hidden box</w:t></w:r></w:p>\
            </w:txbxContent></v:textbox></v:shape></w:pict></w:r><w:r><w:t>end.</w:t></w:r></w:p>\
            <w:p><w:pPr><w:pStyle w:val="Gone"/></w:pPr><w:r><w:t>Gone</w:t></w:r>\(note)\(box)</w:p>\
            <w:p><w:r><w:t>Seen</w:t></w:r><w:r>\(hidden)<w:footnote><w:p><w:r><w:t>Hidden note</w:t></w:r></w:p></w:footnote></w:r>\
            <aml:annotation aml:id="1" w:type="Word.Deletion"><aml:content><w:r><w:t>deleted</w:t></w:r>\(note)</aml:content></aml:annotation>\
            <w:moveFrom><w:r><w:t>moved away</w:t></w:r></w:moveFrom><w:r><w:t> here.</w:t></w:r>\(note)</w:p>
            """
        let head = "<w:styles><w:style w:type=\"paragraph\" w:styleId=\"Gone\"><w:name w:val=\"Gone\"/><w:rPr><w:vanish/></w:rPr></w:style></w:styles>"
        XCTAssertEqual(try bodyLines(of: document(body: body, head: head)), [
            "<p>Before after.</p>", "<p>Boxed</p>", "<p>Hid end.</p>", "<p>Seen here.</p>", "<p>Noted</p>",
        ])
    }

    /// A paragraph that holds only hidden words begins no page, whatever its
    /// style says; a heading of only hidden words writes no heading and does
    /// not turn off the guess at headings.
    func testHiddenWordsBeginNoPageAndNameNoHeading() throws {
        let hiddenRun = "<w:r><w:rPr><w:vanish/></w:rPr><w:t>hidden words</w:t></w:r>"
        let body = """
            <w:p><w:pPr><w:outlineLvl w:val="0"/></w:pPr>\(hiddenRun)</w:p>\
            <w:p><w:r><w:rPr><w:sz w:val="40"/></w:rPr><w:t>Large words</w:t></w:r></w:p>\
            <w:p><w:r><w:t>Body words here are many enough to be the body size.</w:t></w:r></w:p>\
            <w:p><w:pPr><w:pageBreakBefore/></w:pPr>\(hiddenRun)<w:r><w:br w:type="page"/></w:r></w:p>\
            <w:p><w:r><w:t>More body words to outweigh the large one entirely.</w:t></w:r></w:p>
            """
        XCTAssertEqual(try bodyLines(of: document(body: body), pages: true), [
            page(1) + "<h1>Large words</h1>",
            "<p>Body words here are many enough to be the body size.</p>",
            "<p>More body words to outweigh the large one entirely.</p>",
        ])
    }

    /// A no-break space, a soft hyphen, and a page break join no words, and a
    /// tab and a break are spacing, in what is heard.
    func testSpacingCharactersJoinNoWordsAndAreNotSpoken() throws {
        let xml = document(body: "<w:p><w:r><w:t>one</w:t><w:br/><w:t>two</w:t><w:tab/><w:t>three \u{00A0}four\u{00AD}five\u{00A0}six</w:t><w:br w:type=\"page\"/><w:t>seven</w:t></w:r></w:p>")
        let html = try WordMLDocumentReader.html(of: file(holding: xml), includesPages: false)
        let markdown = try HTMLToMarkdownConverter.convert(html, includesPages: false)
        let heard = try MarkdownDocParser.parseChapter(markdown: markdown, title: "", includeNavigationHeadings: true)
            .text.split(whereSeparator: \.isWhitespace).map(String.init)
        XCTAssertEqual(heard, ["one", "two", "three", "fourfive", "six", "seven"])
    }

    // MARK: - Outline Levels, Toggles, Rows, Lists, and Sections

    /// A document with no `wx:sect` wrapper, so a test can write several.
    private func sections(_ body: String, head: String = "") -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<w:wordDocument \(namespaces) xml:space=\"preserve\">\(head)<w:body>\(body)</w:body></w:wordDocument>"
    }

    /// Outline levels follow the DOCX reader's rule: 0 to 8 are headings, 9
    /// is body text that overrides a style's heading level, and a number too
    /// large for an Int (which once trapped) is body text. Title is level 1
    /// and Subtitle level 2. Every other integer of the format is held to a
    /// range or parsed safely, and one more than a number reads as nothing.
    func testOutlineLevelsTitlesAndIntegersAtTheirExtremes() throws {
        let max = "9223372036854775807"
        let head = """
            <w:styles>\
            <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/></w:style>\
            <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/></w:style>\
            <w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/></w:style>\
            <w:style w:type="paragraph" w:styleId="TOCHeading"><w:name w:val="TOC Heading"/><w:basedOn w:val="Heading1"/>\
            <w:pPr><w:outlineLvl w:val="9"/></w:pPr></w:style>\
            <w:style w:type="paragraph" w:styleId="Huge"><w:name w:val="Huge"/><w:pPr><w:outlineLvl w:val="\(max)"/></w:pPr></w:style>\
            <w:style w:type="paragraph" w:styleId="Listed"><w:name w:val="Listed"/><w:pPr><w:listPr><w:ilvl w:val="\(max)"/>\
            <w:ilfo w:val="1"/></w:listPr></w:pPr></w:style>\
            </w:styles>
            """
        let body = """
            <wx:sect>\
            <w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>The Title</w:t></w:r></w:p>\
            <w:p><w:pPr><w:pStyle w:val="Subtitle"/></w:pPr><w:r><w:t>The Subtitle</w:t></w:r></w:p>\
            <w:p><w:pPr><w:pStyle w:val="TOCHeading"/></w:pPr><w:r><w:t>Body text level nine</w:t></w:r></w:p>\
            <w:p><w:pPr><w:pStyle w:val="Huge"/><w:outlineLvl w:val="\(max)"/></w:pPr><w:r><w:rPr><w:sz w:val="\(max)"/></w:rPr>\
            <w:t>Huge numbers</w:t></w:r></w:p>\
            <w:p><w:pPr><w:outlineLvl w:val="-\(max)"/><w:pageBreakBefore w:val="\(max)"/></w:pPr><w:r><w:rPr><w:sz w:val="-9223372036854775808"/>\
            <w:b w:val="OFF"/></w:rPr><w:t>Negative numbers</w:t></w:r></w:p>\
            <w:p><w:pPr><w:pStyle w:val="Listed"/></w:pPr><w:r><w:t>list by style</w:t></w:r></w:p>\
            </wx:sect>
            """
        let lines = try bodyLines(of: sections(body, head: head), pages: false)
        XCTAssertEqual(lines, [
            "<h1>The Title</h1>", "<h2>The Subtitle</h2>", "<p>Body text level nine</p>", "<p>Huge numbers</p>",
            "<p>Negative numbers</p>", "<ul>", "<li>list by style</li>", "</ul>",
        ])
    }

    /// Hidden text, bold, and italic are settled run by run: the paragraph's
    /// style XOR the character style, unless the run states it itself, and
    /// `w:val="off"` works on all three. A character style that does not
    /// mention bold leaves the paragraph style's bold as it is.
    func testTogglePropertiesAreSettledRunByRun() throws {
        let head = """
            <w:styles>\
            <w:style w:type="paragraph" w:styleId="Bolded"><w:name w:val="Bolded"/><w:rPr><w:b/><w:i w:val="off"/></w:rPr></w:style>\
            <w:style w:type="paragraph" w:styleId="Hides"><w:name w:val="Hides"/><w:rPr><w:vanish/></w:rPr></w:style>\
            <w:style w:type="character" w:styleId="Strong"><w:name w:val="Strong"/><w:rPr><w:b/></w:rPr></w:style>\
            <w:style w:type="character" w:styleId="Slant"><w:name w:val="Slant"/><w:rPr><w:i/></w:rPr></w:style>\
            <w:style w:type="character" w:styleId="Gone"><w:name w:val="Gone"/><w:rPr><w:vanish/></w:rPr></w:style>\
            </w:styles>
            """
        let body = """
            <w:p><w:pPr><w:pStyle w:val="Bolded"/></w:pPr>\
            <w:r><w:rPr><w:rStyle w:val="Strong"/></w:rPr><w:t>twice is plain</w:t></w:r>\
            <w:r><w:rPr><w:rStyle w:val="Slant"/></w:rPr><w:t> slanted</w:t></w:r>\
            <w:r><w:rPr><w:b w:val="off"/></w:rPr><w:t> off</w:t></w:r><w:r><w:t> bold</w:t></w:r></w:p>\
            <w:p><w:pPr><w:pStyle w:val="Hides"/></w:pPr><w:r><w:rPr><w:vanish w:val="off"/></w:rPr><w:t>shown by off</w:t></w:r>\
            <w:r><w:rPr><w:rStyle w:val="Gone"/></w:rPr><w:t> toggled back</w:t></w:r><w:r><w:t> hidden</w:t></w:r></w:p>
            """
        XCTAssertEqual(try bodyLines(of: document(body: body, head: head)), [
            "<p>twice is plain<strong><em> slanted</em></strong> off<strong> bold</strong></p>",
            "<p>shown by off toggled back</p>",
        ])
    }

    /// A row marked hidden hides nothing of its own (see
    /// `testARowMarkedHiddenIsReadRunByRun`); a title in the custom
    /// properties is not the document's; a list mark with no list table
    /// decides numbered or bulleted; sections that are not continuous begin
    /// pages.
    func testHiddenRowMarksCustomPropertiesListMarksAndSections() throws {
        let head = """
            <o:DocumentProperties><o:Title>Real Title</o:Title></o:DocumentProperties>\
            <o:CustomDocumentProperties><o:Title>Custom</o:Title></o:CustomDocumentProperties>
            """
        let body = """
            <wx:sect>\
            <w:p><w:pPr><w:listPr><w:ilvl w:val="0"/><w:ilfo w:val="7"/><wx:t wx:val="1."/></w:listPr></w:pPr><w:r><w:t>numbered by mark</w:t></w:r></w:p>\
            <w:p><w:pPr><w:listPr><w:ilvl w:val="0"/><w:ilfo w:val="7"/><wx:t wx:val="\u{2022}"/></w:listPr></w:pPr><w:r><w:t>bullet by mark</w:t></w:r></w:p>\
            <w:tbl><w:tr><w:trPr><w:hidden/></w:trPr><w:tc><w:p><w:r><w:t>hidden row</w:t></w:r></w:p></w:tc></w:tr>\
            <w:tr><w:tc><w:p><w:r><w:t>shown row</w:t></w:r></w:p></w:tc></w:tr></w:tbl>\
            <w:sectPr><w:type w:val="continuous"/></w:sectPr></wx:sect>\
            <wx:sect><w:p><w:r><w:t>Second section next page.</w:t></w:r></w:p><w:sectPr/></wx:sect>\
            <wx:sect><w:p><w:r><w:t>Third continuous.</w:t></w:r></w:p><w:sectPr><w:type w:val="continuous"/></w:sectPr></wx:sect>
            """
        let html = try WordMLDocumentReader.html(of: file(holding: sections(body, head: head)), includesPages: true)
        XCTAssertTrue(html.contains("<title>Real Title</title>"))
        XCTAssertEqual(odfBodyLines(html), [
            page(1) + "<ol>", "<li>numbered by mark</li>", "</ol>", "<ul>", "<li>bullet by mark</li>", "</ul>",
            "<table>", "<tr><td><p>hidden row</p></td></tr>", "<tr><td><p>shown row</p></td></tr>", "</table>",
            "<p>\(page(2))Second section next page.</p>", "<p>Third continuous.</p>",
        ])
    }

    /// A row marked hidden (`w:trPr` holding `w:hidden`) hides nothing of its
    /// own, as in a DOCX: ECMA-376 §17.4.20 hides the glyph of the row's end
    /// marker, "to ensure that the entire table row is hidden and not
    /// displayed in the document, as if any part of the row is visible, the
    /// row is displayed". So a row with an ordinary run shows its words, and
    /// a row whose runs and marks are all `w:vanish` reads nothing, which each
    /// run's own toggle says. (Nothing here has been checked in Word.)
    func testARowMarkedHiddenIsReadRunByRun() throws {
        func row(_ text: String, runProperties: String = "", markProperties: String = "") -> String {
            "<w:tr><w:trPr><w:hidden/></w:trPr><w:tc><w:p><w:pPr><w:rPr>\(markProperties)</w:rPr></w:pPr>"
                + "<w:r><w:rPr>\(runProperties)</w:rPr><w:t>\(text)</w:t></w:r></w:p></w:tc></w:tr>"
        }
        func lines(_ rows: String) throws -> [String] {
            try bodyLines(of: document(body: "<w:tbl>\(rows)</w:tbl>"))
        }
        XCTAssertEqual(try lines(row("ordinary")), ["<table>", "<tr><td><p>ordinary</p></td></tr>", "</table>"])
        XCTAssertEqual(try lines(row("shown", runProperties: "<w:vanish w:val=\"off\"/>")),
                       ["<table>", "<tr><td><p>shown</p></td></tr>", "</table>"])
        // Runs and marks hidden: nothing is read, but the row stays.
        let hiddenRun = row("gone", runProperties: "<w:vanish/>", markProperties: "<w:vanish/>")
        XCTAssertEqual(try lines(hiddenRun + row("seen")), ["<table>", "<tr><td></td></tr>", "<tr><td><p>seen</p></td></tr>", "</table>"])
    }

    /// A list that a `w:lists` table defines is numbered or bulleted by its
    /// number format, and a level with the format "none" is a paragraph.
    func testListsByTheirDefinition() throws {
        let head = """
            <w:lists><w:listDef w:listDefId="0"><w:lvl w:ilvl="0"><w:nfc w:val="0"/></w:lvl><w:lvl w:ilvl="1"><w:nfc w:val="23"/></w:lvl>\
            </w:listDef><w:list w:ilfo="1"><w:ilst w:val="0"/></w:list></w:lists>
            """
        func item(_ level: Int, _ text: String) -> String {
            "<w:p><w:pPr><w:listPr><w:ilvl w:val=\"\(level)\"/><w:ilfo w:val=\"1\"/><wx:t wx:val=\"x\"/></w:listPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>"
        }
        XCTAssertEqual(try bodyLines(of: document(body: item(0, "one") + item(1, "sub"), head: head)), [
            "<ol>", "<li>one<ul>", "<li>sub</li>", "</ul>", "</li>", "</ol>",
        ])
    }

    /// A bullet and a tab that begin a paragraph make it a bullet item; a
    /// dash and a space are words.
    func testBulletsWrittenAsTextAreItemsButDashesAreWords() throws {
        let lines = try bodyLines(of: document(body: """
            <w:p><w:r><w:t></w:t><w:tab/><w:t>•</w:t><w:tab/></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>Item words</w:t></w:r></w:p>\
            <w:p><w:r><w:t>- not a bullet</w:t></w:r></w:p>\
            <w:p><w:r><w:t>•</w:t></w:r></w:p>
            """))
        XCTAssertEqual(lines, ["<ul>", "<li><strong>Item words</strong></li>", "</ul>", "<p>- not a bullet</p>", "<p>•</p>"])
    }

    /// Whitespace in `w:t` is kept as written, and Word's tabs and breaks are
    /// white space.
    func testWhiteSpaceInTextIsKept() throws {
        let lines = try bodyLines(of: document(body: paragraph("two  spaces") + "<w:p><w:r><w:t>a</w:t><w:tab/><w:t>b</w:t></w:r></w:p>"))
        XCTAssertEqual(lines, ["<p>two  spaces</p>", "<p>a\tb</p>"])
    }

    /// Without a default style, sizes alone guess the headings; a document
    /// that names any heading keeps exactly those.
    func testHeadingsBySizeOnlyWhenNoneAreNamed() throws {
        let big = "<w:p><w:r><w:rPr><w:sz w:val=\"40\"/></w:rPr><w:t>Large words</w:t></w:r></w:p>"
        let body = big + paragraph("Body words here are many enough to be the body size.")
            + paragraph("More body words to outweigh the large one entirely.")
        XCTAssertEqual(try bodyLines(of: document(body: body)).filter { $0.hasPrefix("<h") }, ["<h1>Large words</h1>"])
        let named = "<w:p><w:pPr><w:outlineLvl w:val=\"1\"/></w:pPr><w:r><w:t>Named</w:t></w:r></w:p>"
        XCTAssertEqual(try bodyLines(of: document(body: body + named)).filter { $0.hasPrefix("<h") }, ["<h2>Named</h2>"])
    }

    /// Prefixes other than the usual ones are read by their namespaces.
    func testNamespacePrefixesNeedNotBeTheUsualOnes() throws {
        let xml = """
            <?xml version="1.0"?><d:wordDocument xmlns:d="http://schemas.microsoft.com/office/word/2003/wordml">\
            <d:body><d:p><d:r><d:t>Other prefixes</d:t></d:r></d:p></d:body></d:wordDocument>
            """
        XCTAssertEqual(try bodyLines(of: xml), ["<p>Other prefixes</p>"])
    }

    // MARK: - What Is Refused

    private var unreadable: TextutilConverter.Failure { .unreadable(.wordml) }

    /// An XML file that is not a Word document, text that is not XML, and a
    /// document cut off are refused with the sentence for an unreadable
    /// document; an empty file has no text to read.
    func testFilesThatAreNotWordXMLAreRefused() throws {
        for (label, text) in [
            ("another root", "<?xml version=\"1.0\"?><html><body>Words</body></html>"),
            ("no XML", "Just some words."),
            ("cut off", document(body: paragraph("First") + "<w:p><w:r><w:t>Second wor")),
            ("a document type", "<?xml version=\"1.0\"?><!DOCTYPE d [<!ENTITY e \"x\">]>" + document(body: paragraph("&e;"))),
        ] {
            let url = try file(holding: text)
            XCTAssertThrowsError(try WordMLDocumentReader.html(of: url, includesPages: true), label) {
                XCTAssertEqual($0 as? TextutilConverter.Failure, unreadable, label)
            }
        }
        let empty = try file(holding: "")
        XCTAssertThrowsError(try WordMLDocumentReader.html(of: empty, includesPages: true)) { error in
            guard case .noTextToRead? = error as? FileImportError else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Hostile Files

    /// The longest any one hostile read may take.
    private let allowedSeconds = 2.0

    /// Reads `xml`, returning the HTML or nil for an error the reader names;
    /// fails the test for any other error or for a read that took too long.
    @discardableResult
    private func read(_ xml: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws -> String? {
        let url = try self.file(holding: xml)
        // On another thread, so that a read that hangs fails the test.
        guard let outcome = finishing(within: allowedSeconds, label, file: file, line: line, {
            try WordMLDocumentReader.html(of: url, includesPages: true)
        }) else { return nil }
        do {
            return try outcome.get()
        } catch {
            let known = error is TextutilConverter.Failure || error is DocumentTooLargeError || error is FileImportError
            XCTAssertTrue(known, "\(label) threw an error the reader does not name: \(error)", file: file, line: line)
            return nil
        }
    }

    /// A sample cut off at many lengths ends in a clean error or a document.
    func testDocumentsTruncatedAtManyLengths() throws {
        let whole = try String(contentsOf: copyOfFormatSample("wordml/headings.wordml"), encoding: .utf8)
        let characters = Array(whole)
        for length in stride(from: 0, to: characters.count, by: max(characters.count / 150, 1)) {
            try read(String(characters.prefix(length)), "cut at \(length)")
        }
    }

    /// 100,000 nested runs, tables, and text boxes are refused quickly.
    func testNestingPastTheCapIsRefused() throws {
        let depth = 100_000
        XCTAssertNil(try read(document(body: "<w:p>" + String(repeating: "<w:r>", count: depth) + "<w:t>words</w:t>"
            + String(repeating: "</w:r>", count: depth) + "</w:p>"), "nested runs"))
        XCTAssertNil(try read(document(body: String(repeating: "<w:tbl><w:tr><w:tc>", count: 20_000) + paragraph("words")
            + String(repeating: "</w:tc></w:tr></w:tbl>", count: 20_000)), "nested tables"))
        XCTAssertNil(try read(document(body: String(repeating: "<w:p><w:r><w:txbxContent>", count: 20_000) + paragraph("words")
            + String(repeating: "</w:txbxContent></w:r></w:p>", count: 20_000)), "nested text boxes"))
    }

    /// Nesting inside the cap is read.
    func testNestingWithinTheCapIsRead() throws {
        let body = String(repeating: "<w:tbl><w:tr><w:tc>", count: 30) + paragraph("deep words")
            + String(repeating: "</w:tc></w:tr></w:tbl>", count: 30)
        XCTAssertEqual(odfPlainText(try XCTUnwrap(read(document(body: body), "30 nested tables"))), "deep words")
    }

    /// Twenty thousand cells in one row are read inside the budget and
    /// quickly, and a ring of styles ends.
    func testManyCellsAndStyleLoops() throws {
        let cells = String(repeating: "<w:tc><w:p><w:r><w:t>c</w:t></w:r></w:p></w:tc>", count: 20_000)
        let html = try XCTUnwrap(read(document(body: "<w:tbl><w:tr>\(cells)</w:tr></w:tbl>"), "20,000 cells"))
        XCTAssertEqual(odfBodyLines(html).count, 3)

        var styles = "<w:styles>"
        for index in 0..<2_000 {
            styles += "<w:style w:type=\"paragraph\" w:styleId=\"S\(index)\"><w:basedOn w:val=\"S\((index + 1) % 2_000)\"/></w:style>"
        }
        styles += "</w:styles>"
        let looped = try XCTUnwrap(read(
            document(body: "<w:p><w:pPr><w:pStyle w:val=\"S0\"/></w:pPr><w:r><w:t>words</w:t></w:r></w:p>", head: styles),
            "a ring of 2,000 styles"
        ))
        XCTAssertEqual(odfPlainText(looped), "words")
    }

    /// Text past the byte limit is refused.
    func testTextPastTheLimitIsRefused() throws {
        let body = paragraph(String(repeating: "word ", count: 5_000))
        let url = try file(holding: document(body: body))
        try DocumentByteLimit.$current.withValue(10_000) {
            XCTAssertThrowsError(try WordMLDocumentReader.html(of: url, includesPages: true)) {
                XCTAssertEqual($0 as? DocumentTooLargeError, DocumentTooLargeError(limit: 10_000))
            }
        }
    }

    /// Bytes flipped in a sample give a document or a clean error, every time.
    func testFlippedBytesNeverTrap() throws {
        let whole = try Data(contentsOf: copyOfFormatSample("wordml/headings.wordml"))
        var state: UInt64 = 20_261_105
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(truncatingIfNeeded: state >> 33)
        }
        let folder = try makeSandboxDirectory("WordMLFlipped")
        for round in 0..<100 {
            var damaged = whole
            for _ in 0..<(1 + round % 8) { damaged[next() % damaged.count] = UInt8(truncatingIfNeeded: next()) }
            let url = folder.appendingPathComponent("flipped-\(round).xml")
            try damaged.write(to: url)
            // On another thread, so that a read that hangs fails the test.
            guard let outcome = finishing(within: allowedSeconds, "round \(round)", { try WordMLDocumentReader.html(of: url, includesPages: true) }) else { return }
            if case .failure(let error) = outcome {
                XCTAssertTrue(error is TextutilConverter.Failure || error is DocumentTooLargeError, "round \(round): \(error)")
            }
        }
    }

    // MARK: - Against textutil

    /// The samples read with the same words as textutil's reading and at
    /// least its headings, on the Mac, where textutil runs in tests.
    func testSamplesMatchTextutil() throws {
        for sample in ["wordml/headings.wordml", "wordml/page-breaks.wordml"] {
            let copy = try copyOfFormatSample(sample, named: "sample.xml")
            let work = try makeSandboxDirectory("WordMLComparison")
            let textutil = try OwnDocumentReaders.$forcesTextutil.withValue(true) {
                try TextutilDocumentReader.$temporaryRoot.withValue(work) {
                    try TextutilDocumentReader.extract(from: copy, bookFormat: .wordml, includesPages: true).markdown
                }
            }
            let own = try HTMLToMarkdownConverter.convert(
                WordMLDocumentReader.html(of: copy, includesPages: true), includesPages: true
            )
            XCTAssertEqual(try heardWords(own), try heardWords(textutil), sample)
            let ownHeadings = markdownHeadings(own)
            XCTAssertEqual(markdownHeadings(textutil).filter { !ownHeadings.contains($0) }, [], "\(sample): own \(ownHeadings)")
        }
    }

    /// The words a listener hears of `markdown`: runs of letters and digits in
    /// the reading text (`MarkdownDocParser.parseChapter`), which writes no
    /// list marker.
    private func heardWords(_ markdown: String) throws -> [String] {
        try MarkdownDocParser.parseChapter(markdown: markdown, title: "", includeNavigationHeadings: true)
            .text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// The headings of `markdown`, as "level: text".
    private func markdownHeadings(_ markdown: String) -> [String] {
        markdown.split(separator: "\n").compactMap { line in
            let hashes = line.prefix { $0 == "#" }
            guard (1...6).contains(hashes.count), line.dropFirst(hashes.count).first == " " else { return nil }
            return "\(hashes.count): \(line.dropFirst(hashes.count + 1).trimmingCharacters(in: .whitespaces))"
        }
    }

    /// A document may define 100,000 styles; the 100,001st ends the read as
    /// an unreadable document (the limit is met where a style ends, so the
    /// last style of a part is checked too).
    func testTheStyleLimitHoldsAtItsEdge() throws {
        func styles(_ count: Int) -> String {
            "<w:styles>" + (0..<count).map { "<w:style w:type=\"character\" w:styleId=\"S\($0)\"/>" }.joined() + "</w:styles>"
        }
        let url = try file(holding: document(body: paragraph("words"), head: styles(WordMLStyleSheet.maximumStyles)))
        XCTAssertEqual(odfPlainText(try WordMLDocumentReader.html(of: url, includesPages: false)), "words")
        let over = try file(holding: document(body: paragraph("words"), head: styles(WordMLStyleSheet.maximumStyles + 1)), named: "over.xml")
        XCTAssertThrowsError(try WordMLDocumentReader.html(of: over, includesPages: false)) {
            XCTAssertEqual($0 as? TextutilConverter.Failure, .unreadable(.wordml))
        }
    }

    // MARK: - The Switch

    /// iOS always reads Word 2003 XML with this reader, and the Mac does since
    /// the reader was checked against textutil's reading
    /// (`testSamplesMatchTextutil`).
    func testTheSwitchIsOn() {
        XCTAssertTrue(WordMLDocumentReader.isOn)
    }
}
