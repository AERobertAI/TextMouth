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
        XCTAssertTrue(odfBodyLines(html).contains("<p>First page paragraph two runs on and\(page(2))continues here.</p>"))
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
            "<p>Box: </p>", "<p>Boxed words</p>", "<p> after box.</p>",
            "<p>Field: 7 today link</p>",
            "<p>One<br>two\(page(3))three</p>",
            "<p>Foot text</p>",
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
        let start = Date()
        defer {
            XCTAssertLessThan(Date().timeIntervalSince(start), allowedSeconds, "\(label) took too long", file: file, line: line)
        }
        do {
            return try WordMLDocumentReader.html(of: url, includesPages: true)
        } catch {
            let known = error is TextutilConverter.Failure || error is DocumentTooLargeError || error is FileImportError
            XCTAssertTrue(known, "\(label) threw an error the reader does not name: \(error)", file: file, line: line)
            return nil
        }
    }

    /// A sample cut off at many lengths ends in a clean error or a document.
    func testDocumentsTruncatedAtManyLengths() throws {
        let whole = try String(contentsOf: formatSampleURL("wordml/headings.wordml"), encoding: .utf8)
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
        DocumentByteLimit.$current.withValue(10_000) {
            XCTAssertThrowsError(try WordMLDocumentReader.html(of: url, includesPages: true)) {
                XCTAssertEqual($0 as? DocumentTooLargeError, DocumentTooLargeError(limit: 10_000))
            }
        }
    }

    /// Bytes flipped in a sample give a document or a clean error, every time.
    func testFlippedBytesNeverTrap() throws {
        let whole = try Data(contentsOf: formatSampleURL("wordml/headings.wordml"))
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
            let start = Date()
            do {
                _ = try WordMLDocumentReader.html(of: url, includesPages: true)
            } catch {
                XCTAssertTrue(error is TextutilConverter.Failure || error is DocumentTooLargeError, "round \(round): \(error)")
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), allowedSeconds, "round \(round)")
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
            XCTAssertEqual(markdownWords(own), markdownWords(textutil), sample)
            let ownHeadings = markdownHeadings(own)
            XCTAssertEqual(markdownHeadings(textutil).filter { !ownHeadings.contains($0) }, [], "\(sample): own \(ownHeadings)")
        }
    }

    /// The words of `markdown`, comments removed: runs of letters and digits.
    private func markdownWords(_ markdown: String) -> [String] {
        markdown.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// The headings of `markdown`, as "level: text".
    private func markdownHeadings(_ markdown: String) -> [String] {
        markdown.split(separator: "\n").compactMap { line in
            let hashes = line.prefix { $0 == "#" }
            guard (1...6).contains(hashes.count), line.dropFirst(hashes.count).first == " " else { return nil }
            return "\(hashes.count): \(line.dropFirst(hashes.count + 1).trimmingCharacters(in: .whitespaces))"
        }
    }

    // MARK: - The Switch

    /// iOS always reads Word 2003 XML with this reader; the Mac, once checked.
    func testTheSwitchIsOnForIOS() {
        #if os(macOS)
        XCTAssertFalse(WordMLDocumentReader.isOn)
        #else
        XCTAssertTrue(WordMLDocumentReader.isOn)
        #endif
    }
}
