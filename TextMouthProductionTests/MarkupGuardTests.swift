import SwiftSoup
import XCTest
@testable import TextMouth

extension MarkupGuard.Limits {
    /// The standard limits but for nesting, for the tests that hold the app's
    /// own walks over a tree to not recursing, on trees the guard would refuse.
    static let withoutDepthLimit = MarkupGuard.Limits(
        deepestNesting: .max, mostMemoryUnits: standard.mostMemoryUnits,
        mostAttributesOnATag: standard.mostAttributesOnATag, mostWork: standard.mostWork
    )
}

/// `MarkupGuard`: damaged or hostile markup is read or refused, never a trap, a
/// stack overflow, or a tree that fills the Mac's memory, and a real book's
/// markup reaches SwiftSoup unchanged.
///
/// Every document here was first run in a harness that catches a trap, since a
/// trap would end this test host (see the report of the `markupguard` branch):
/// with the guard taken out, the documents of the first two sections trap.
final class MarkupGuardTests: XCTestCase {

    // MARK: - Helpers

    /// The markup's Markdown by the path every format's text takes, on the stack an import has.
    private func converted(_ markup: String) -> Result<String, Error>? {
        onWorkerSizedStack {
            Result { try HTMLToMarkdownConverter.convert(markup, stripDuplicateNavigation: true) }
        }
    }

    /// What the guard's pass finds in `markup`, with limits none of it reaches.
    private func inspected(_ markup: String, as dialect: MarkupGuard.Dialect) throws -> MarkupGuard.Inspection {
        try MarkupGuard.inspect(Array(markup.utf8), as: dialect, limits: Self.unbounded)
    }

    /// Limits no document here reaches, to see what the pass counts.
    private static let unbounded = MarkupGuard.Limits(deepestNesting: .max, mostMemoryUnits: .max, mostAttributesOnATag: .max, mostWork: .max)

    /// How deep the tree SwiftSoup made goes, counting from the document.
    private func depth(of document: Document) -> Int {
        MarkupFuzzGenerator.depth(of: document as Node, children: { $0.getChildNodes() }, isElement: { $0 is Element })
    }

    /// The opening every XML document here has.
    private static let declaration = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"

    /// An XHTML document with `body` in its body.
    private func xhtml(_ body: String) -> String {
        Self.declaration + "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body>\(body)</body></html>"
    }

    // MARK: - The Trap

    /// Every shape of declaration that stopped the process in a document that
    /// opens as XML now reads as a comment would, with the words on both sides.
    func testEachBrokenDeclarationReadsWithTheWordsAroundIt() throws {
        let shapes = [
            "<?a>", "<??>", "<? >", "<?a b=\"c\">", "<?1?>", "<?=a>", "<? a?>", "</?a>", "</!a>", "<!!a>", "<!?a>",
            "<?a b='c?>", "<??a?>", "<?!a?>", "<?/a?>", "<?!-- a --?>", "<?!DOCTYPE a?>", "<?![CDATA[a]]?>", "<?é>", "<?=<a?>",
        ]
        for shape in shapes {
            let result = try XCTUnwrap(converted(xhtml("<p>Before.</p>\(shape)<p>After.</p>")), shape)
            let markdown = try result.get()
            // The words, not their full stops, which Markdown writes escaped.
            XCTAssertTrue(markdown.contains("Before"), shape)
            XCTAssertTrue(markdown.contains("After"), shape)
        }
    }

    /// A document cut off inside its own declaration, or torn by one flipped
    /// byte, opens as XML and has no element at all: it reads as nothing.
    func testADeclarationTheMarkupEndsInsideOfReadsAsNothing() throws {
        for markup in ["<?xml version=\"1.0\"", "<?xml n=\"h", "<?xml", "<?xml ", "<?xml a='", Self.declaration + "<?a", Self.declaration + "<?a b=\""] {
            let result = try XCTUnwrap(converted(markup), markup)
            XCTAssertEqual(try result.get(), "", markup)
        }
    }

    /// A declaration SwiftSoup can take apart is left alone, so the markup goes
    /// to the parser as it was, and stays a declaration in the tree.
    func testADeclarationSwiftSoupCanTakeApartIsLeftAlone() throws {
        let markup = Self.declaration
            + "<?xml-stylesheet type=\"text/css\" href=\"a.css\"?><?oxygen RNGSchema=\"a\"?><html><body><?xml:namespace prefix = \"o\" /><p>Words.</p></body></html>"
        XCTAssertEqual(try inspected(markup, as: .xml).brokenDeclarations, [])
        let document = try MarkupGuard.parse(markup)
        let names = document.getChildNodes().compactMap { ($0 as? XmlDeclaration)?.name() }
        XCTAssertEqual(names, ["xml", "xml-stylesheet", "oxygen"])
        XCTAssertEqual(try document.text(), "Words.")
    }

    /// Which declarations count as broken, as `XmlTreeBuilder` reads them: those
    /// whose text, after its first and last character, makes no start tag.
    func testWhichDeclarationsTrap() {
        let table: [(String, Bool)] = [
            // A comment to SwiftSoup, taken apart by nothing.
            ("", false), ("?", false), ("!", false), ("a", false), ("ab", false),
            // Its first and last character gone, nothing is left.
            ("?a", true), ("??", true), ("!a", true),
            // A tag with a name.
            ("?a?", false), ("?a b=\"c\"?", false), ("?xml version=\"1.0\"?", false), ("?a/", false), ("?ab", false), ("!abc", false),
            // A quotation mark the last character was needed to end: the tag never ends.
            ("?a b=\"c\"", true), ("?xml version=\"1.0\"", true), ("?a b='c?", true), ("?a b=\"x", true),
            // A value that never begins: the tag ends at the ">".
            ("?a b=\"", false),
            // Not a name.
            ("?1?", true), ("?=a", true), ("? a?", true), ("?/a?", true), ("??a?", true), ("?!a?", true),
            // A quotation mark in a name opens nothing.
            ("?a\"b?", false), ("?a \"b?", false),
            // A carriage return and a line feed are one character.
            ("?\r\n", true), ("?a\r\n", false),
            // So is a letter and its accent, and "?" with an accent is not "?".
            ("?a\u{301}", true), ("?\u{301}a", false),
        ]
        for (data, traps) in table {
            XCTAssertEqual(MarkupDeclaration.wouldTrap(ArraySlice(data.utf8)), traps, data.debugDescription)
        }
    }

    /// The guard chooses the parser SwiftSoup's automatic parse would choose, whatever comes before `<?xml`.
    func testTheParserIsTheOneSwiftSoupWouldChoose() throws {
        // `<br>` and `<b>` nest in the XML parser, and not in the HTML parser.
        let markup = "<?xml version=\"1.0\"?><a><br><b>words"
        for opening in ["", " ", "\n", "\r\n", "\t", "\u{0C}", "  \n ", "\u{0B}", "\u{A0}", "\u{85}", "\u{FEFF}", "\u{2028}", "\u{3000}", "x", "<!-- a -->"] {
            let expected = try SwiftSoup.parse(opening + markup).outerHtml()
            XCTAssertEqual(try MarkupGuard.parse(opening + markup).outerHtml(), expected, opening.debugDescription)
        }
        for close in ["<?xml", "<?XML", "<?xmlx", "<?xm", "<?xml\u{301}", "<?x\u{301}ml"] {
            XCTAssertEqual(MarkupGuard.opensAsXML(close), close == "<?xml" || close == "<?xmlx", close.debugDescription)
        }
    }

    /// Where XHTML and HTML part ways, the tree is the one SwiftSoup's automatic
    /// parse makes, so a real book reads as it read: forcing the HTML parser would
    /// put a self-closed element's end elsewhere, add a table's body, and close a paragraph at a block.
    func testXHTMLIsParsedAsItEverWas() throws {
        let bodies = [
            "<head><title/></head><body><p>Words.</p></body>",
            "<head><script src=\"a.js\"/><style/></head><body><p>Words.</p></body>",
            "<body><a id=\"x\"/>Words.<div/>More.<span/>And.<textarea/>End.</body>",
            "<body><table><tr><td>One</td></tr></table></body>",
            "<body><p>Before<div>Inside</div>After</p></body>",
            "<body><svg viewBox=\"0 0 1 1\"><textPath>Curved</textPath></svg><DIV>Upper</DIV></body>",
            "<body><?page n=\"12\"?><p>Words.</p><![CDATA[Some <b>text</b>]]></body>",
        ]
        for body in bodies {
            let markup = Self.declaration + "<html xmlns=\"http://www.w3.org/1999/xhtml\">\(body)</html>"
            XCTAssertEqual(try MarkupGuard.parse(markup).outerHtml(), try SwiftSoup.parse(markup).outerHtml(), body)
        }
    }

    /// The HTML parser takes nothing apart, so nothing is rewritten for it.
    func testTheHTMLParserGetsItsDeclarationsAsTheyAre() throws {
        let markup = "<!DOCTYPE html><html><body><?a><p>Words.</p></body></html>"
        XCTAssertEqual(try inspected(markup, as: .html).brokenDeclarations, [])
        XCTAssertEqual(try MarkupGuard.parse(markup).text(), "Words.")
    }

    /// The direct HTML reader and the portable XML tree's lenient reader meet the
    /// same markup and hold.
    func testTheOtherReadersOfMarkupHold() throws {
        let content = try HTMLParser.parse(html: xhtml("<?a><p>Words.</p>"), title: "T")
        XCTAssertEqual(content.chapters.first?.text.trimmingCharacters(in: .whitespacesAndNewlines), "Words.")
        let tidied = try PortableXMLDocument(xmlString: "<a><?b><c>Words.</c></a>", options: [.documentTidyXML])
        XCTAssertEqual(tidied.stringValue, "Words.")
    }

    // MARK: - Nesting

    /// Each small file that once overflowed the stack is refused with the
    /// sentence, in either parser.
    func testMarkupThatWouldOverflowTheStackIsRefused() throws {
        let html = "<!DOCTYPE html><html><body>"
        let hostile = [
            // An end tag that closes nothing closes nothing.
            html + String(repeating: "<div></x>", count: 5_000),
            html + String(repeating: "<span></div>", count: 20_000),
            // An end tag stops at a block it does not name.
            html + String(repeating: "<span><div></span>", count: 5_000),
            // Formatting comes back inside the next block, once for each different one.
            html + (0..<5_000).map { "<div><b n=\($0)></div>" }.joined(),
            // Honest nesting.
            html + String(repeating: "<div>", count: 5_000) + "words" + String(repeating: "</div>", count: 5_000),
            html + String(repeating: "<table><tr><td>", count: 2_000) + "words",
            html + "<select>" + String(repeating: "<optgroup><option>", count: 5_000),
            // The XML parser closes nothing by itself.
            xhtml(String(repeating: "<br>", count: 5_000)),
            xhtml(String(repeating: "<p>w", count: 5_000)),
            xhtml(String(repeating: "<img>", count: 5_000)),
            xhtml(String(repeating: "<li>x", count: 5_000)),
            xhtml(String(repeating: "<div></x>", count: 5_000)),
            xhtml(String(repeating: "<div>", count: 5_000) + "words" + String(repeating: "</div>", count: 5_000)),
        ]
        for markup in hostile {
            let result = try XCTUnwrap(converted(markup))
            XCTAssertThrowsError(try result.get(), String(markup.prefix(80))) { error in
                XCTAssertEqual(error as? MarkupRefusal, .nestedTooDeeply(limit: MarkupGuard.Limits.standard.deepestNesting))
            }
        }
    }

    /// What the HTML parser closes by itself never nests, however much of it a
    /// book leaves open, and its words are all read.
    func testWhatTheHTMLParserClosesByItselfIsNotNesting() throws {
        let html = "<!DOCTYPE html><html><body>"
        let loose = [
            String(repeating: "<p>word<br>", count: 5_000),
            "<ul>" + String(repeating: "<li>word", count: 5_000) + "</ul>",
            "<dl>" + String(repeating: "<dt>word<dd>word", count: 5_000) + "</dl>",
            "<table>" + String(repeating: "<tr><td>word<td>word", count: 5_000) + "</table>",
            String(repeating: "<a name=x>word", count: 5_000),
            String(repeating: "<i><p>word</i></p>", count: 5_000),
            String(repeating: "<p><font size=2>word", count: 5_000),
            "<select>" + String(repeating: "<option>word", count: 5_000) + "</select>",
            String(repeating: "<span>word", count: 5).appending(String(repeating: "<br/><hr/><img/>", count: 5_000)),
        ]
        for body in loose {
            let inspection = try inspected(html + body, as: .html)
            XCTAssertLessThanOrEqual(inspection.deepest, 12, String(body.prefix(40)))
            let result = try XCTUnwrap(converted(html + body))
            XCTAssertNoThrow(try result.get(), String(body.prefix(40)))
        }
    }

    /// Exactly the limit passes the guard's own count, in the shapes that cost
    /// the parser most, and one level past it is refused before any parse. The
    /// limit is checked on the count alone: a debug build's converter, with
    /// over 4 KB of stack a level, reads only about 108 levels on an import's
    /// stack, so this suite converts 40 levels at most.
    func testTheDepthLimitIsExact() throws {
        let limit = MarkupGuard.Limits.standard.deepestNesting
        // In XML the guard counts `html` and `body` as it counts anything; in HTML it adds them to
        // what it sees. Each end tag makes the HTML parser walk to the root.
        let shapes: [(dialect: MarkupGuard.Dialect, markup: (Int) -> String)] = [
            (.xml, { self.xhtml(String(repeating: "<div>", count: $0) + "words" + String(repeating: "</div>", count: $0)) }),
            (.html, { "<html><body>" + String(repeating: "<div>", count: $0) + "words" + String(repeating: "</span></div>", count: $0) }),
        ]
        for shape in shapes {
            let atLimit = shape.markup(limit - 2)
            XCTAssertEqual(try MarkupGuard.inspect(Array(atLimit.utf8), as: shape.dialect, limits: .standard).deepest, limit)
            let past = shape.markup(limit - 1)
            XCTAssertThrowsError(try MarkupGuard.inspect(Array(past.utf8), as: shape.dialect, limits: .standard)) { error in
                XCTAssertEqual(error as? MarkupRefusal, .nestedTooDeeply(limit: limit))
            }
            // The real path refuses it the same way, before SwiftSoup parses it.
            XCTAssertThrowsError(try MarkupGuard.parse(past)) { error in
                XCTAssertEqual(error as? MarkupRefusal, .nestedTooDeeply(limit: limit))
            }
            // A conversion well inside a debug build's stack reads to its words.
            XCTAssertTrue(try XCTUnwrap(converted(shape.markup(38))).get().contains("words"))
        }
        // The worst that fits: each level a table's four, or a formatting element's copy.
        let tables = { (steps: Int) in "<html><body>" + String(repeating: "<table><td>", count: steps) + "words" }
        let fitting = try MarkupGuard.inspect(Array(tables((limit - 2) / 4).utf8), as: .html, limits: .standard).deepest
        XCTAssertLessThanOrEqual(fitting, limit)
        XCTAssertGreaterThan(fitting, limit - 4)
        XCTAssertTrue(try XCTUnwrap(converted(tables(9))).get().contains("words"))
    }

    // MARK: - The Pass Against the Parser

    /// The pass counts what SwiftSoup's HTML parser builds, tag by tag, rule by
    /// rule: each document's expected count is its real tree's depth, less the
    /// document's own level. `html` and `body` count as the pass says they do.
    func testThePassCountsWhatTheHTMLParserBuilds() throws {
        let cases: [(String, Int)] = [
            ("words", 2),
            ("<div><div><div>", 5),
            ("<div></div><div></div>", 3),
            ("<div></x>", 3),
            ("<span><div></span>", 4),
            ("<div><span></div>", 4),
            ("<p><p><p>", 3),
            ("<p><span><p>", 4),
            ("<li><li><li>", 3),
            ("<ul><li><ul><li>", 6),
            ("<li><blockquote><li>", 5),
            ("<li><div><li>", 4),
            ("<dd><dt><dd>", 3),
            ("<h1><h2><h3>", 3),
            ("<h1><p><h2>", 4),
            ("<br><hr><img><input><wbr>", 2),
            ("<div/><span/><p/><x/>", 2),
            ("<b><b><b><b><b>", 7),
            ("<b></b><b></b>", 3),
            ("<div><b></div><div>x", 4),
            ("<div><b></div><div><i></div><div>x", 5),
            ("<i><p>x</i></p>", 4),
            ("<b><div></b>", 4),
            ("<a><a><a>", 3),
            ("<table><td>", 6),
            ("<table><td><td><td>", 6),
            ("<table><tr><td></tr><tr><td></tr>", 6),
            ("<table><td><table><td>", 10),
            ("<table></table><table></table>", 3),
            ("<table><table><table>", 3),
            ("<td><td><td>", 2),
            ("<tr><th>", 2),
            ("<select><div><div>", 3),
            ("<select><option><option>", 4),
            ("<select><optgroup><option><optgroup><option>", 6),
            ("<select><input>", 3),
            ("<object><object></object></object>", 4),
            ("<object><name></object>", 4),
            ("<ruby><rt><rt>", 4),
            ("<rt>", 2),
            ("<form><form><form>", 3),
            ("<form><div></form>", 4),
            ("<title><div><div></title>", 2),
            ("<title><div>", 3),
            ("<title/><div>", 3),
            ("<style><div></style><div>", 3),
            ("<style></style</style><div>", 2),
            ("<script><div></script><div>", 3),
            ("<script><!--<script></script><div></script><div>", 3),
            ("<script><!--</script><div>", 3),
            ("<plaintext><div><div>", 3),
            ("<!-- <div><div> --><div>", 3),
            ("<!---><div>", 3),
            ("<!--><div>", 3),
            ("<!--a--!><div>", 3),
            ("<!DOCTYPE html><div>", 3),
            ("<!DOCTYPE ><div><div>", 3),
            ("<![CDATA[<div>]]><div>", 3),
            ("<?a <div><div>", 3),
            ("<div a=\"<div><div>\"><div>", 4),
            ("<div a=<div><div>", 4),
            ("<div a=\"<div><div>", 2),
            ("<div\0><div\0>", 4),
            ("</><div>", 3),
            ("< div><div>", 3),
            ("<é><div>", 3),
        ]
        for (markup, expected) in cases {
            let pass = try inspected(markup, as: .html).deepest
            XCTAssertEqual(pass, expected, markup.debugDescription)
            // The real tree goes no deeper than the pass said; the document itself is one level.
            let real = try depth(of: SwiftSoup.parseHTML(markup, ""))
            XCTAssertLessThanOrEqual(real, pass + 1, "the real tree of \(markup.debugDescription)")
        }
    }

    /// The pass's count for the XML parser is exact: the depth of the tree, less the document's own level.
    func testThePassCountsWhatTheXMLParserBuildsExactly() throws {
        let cases = [
            "<a><b><c>", "<a><b></a><c>", "<a></b><c>", "<a/><b/>", "<br><br><br>", "<p>x<p>y", "<A></a><b>", "<a b=\"<c><d>\"><e>", "<a b=<c><d>",
            "<!-- <a> --><a>", "<![CDATA[<a><b>]]><a>", "<?x <a> ?><a>", "<a><?b c=\"d\"?><e>", "<!DOCTYPE a><a>", "<!DOCTYPE ><a><b>", "<a / ><b>", "<a /b><c>",
            "<a b=\"c\"/><d>", "<a b='c'/ ><d>", "<a\0></a\0>", "<a", "<a><b", "</a><b>",
        ]
        for markup in cases {
            let inspection = try inspected(markup, as: .xml)
            let tree = try MarkupGuard.parseXML(markup, deepestNesting: .max)
            XCTAssertEqual(inspection.deepest, depth(of: tree), markup.debugDescription)
        }
    }

    /// In random markup made for it, the tree goes no deeper than the pass counts:
    /// the count follows the parser's rules, its moves of elements included (a
    /// `form` taken off the stack from under what is above it, the adoption
    /// agency's copies), and is never less than the real tree. The parser's rules
    /// are walked through thousands of ways here, so this also fails if an update
    /// of SwiftSoup changes them.
    func testRandomMarkupGoesNoDeeperThanThePassCounts() throws {
        for pieces in [6, 30, 150] {
            for round in 0..<600 {
                let (text, opensAsXML) = MarkupFuzzGenerator.document(seed: 1, round: round, pieces: pieces)
                let inspection = try inspected(text, as: opensAsXML ? .xml : .html)
                let parsed = opensAsXML ? try? MarkupGuard.parseXML(text, deepestNesting: .max) : try? SwiftSoup.parseHTML(text, "")
                guard let parsed else { continue }
                XCTAssertLessThanOrEqual(depth(of: parsed), inspection.deepest, text)
            }
        }
    }

    /// Repeated units, the shapes that walked past the first count: each is
    /// counted as deep as SwiftSoup builds it, 30 times over, which is shallow
    /// enough for a test host's stack. The harness holds every unit of one to
    /// three tags to this at 40 and 2,000 repeats, in child processes.
    func testRepeatedUnitsAreCountedAsDeepAsTheParserBuildsThem() throws {
        let units = [
            "<frameset><table>", "<marquee><table><tfoot>", "<tfoot><marquee><table>", "<object><table><tfoot>", "<applet><table><tfoot>",
            "<section></applet><p><applet>", "<p></marquee><marquee><figure>", "<select><p><frameset>", "<select><frameset><p>",
            "<frameset><select><p>", "<select><table><frameset>", "<table><tfoot><applet>", "<p><h1>", "<h1><p><caption>", "<form><div></form>",
        ]
        for head in ["<html><body>", "", "<!DOCTYPE html><html><head><title>T</title></head><body><p>words"] {
            for unit in units {
                let markup = head + String(repeating: unit, count: 30)
                let real = depth(of: try SwiftSoup.parseHTML(markup, ""))
                XCTAssertGreaterThanOrEqual(try inspected(markup, as: .html).deepest, real, markup.prefix(80).debugDescription)
            }
        }
    }

    /// The second layer: the parsed tree's own depth, found with a stack of its
    /// own, is held to the limit before any reader that calls itself for each
    /// level sees the tree, whatever the pass counted.
    func testTheParsedTreeIsHeldToTheLimitToo() throws {
        let markup = "<html><body>" + String(repeating: "<div>", count: 30) + "words"
        let document = try SwiftSoup.parseHTML(markup, "")
        // `html`, `body`, and 30 divisions.
        XCTAssertNoThrow(try MarkupGuard.requireDepth(of: document, atMost: 32))
        XCTAssertThrowsError(try MarkupGuard.requireDepth(of: document, atMost: 31)) { error in
            XCTAssertEqual(error as? MarkupRefusal, .nestedTooDeeply(limit: 31))
        }
        // Through the real path, with a limit the count meets exactly, it reads.
        let limits = MarkupGuard.Limits(deepestNesting: 32, mostMemoryUnits: .max, mostAttributesOnATag: .max, mostWork: .max)
        try MarkupGuard.$limits.withValue(limits) {
            XCTAssertNoThrow(try MarkupGuard.parse(markup))
        }
    }

    /// A page of frames is counted as SwiftSoup builds it: before the body, a
    /// `frameset` opens the parser's mode for frames, which holds framesets and
    /// frames alone; once the body has begun, it is an ordinary element. A
    /// `noscript` of the head reads as text what it may not hold. Where text of
    /// character references leaves it unknown whether the body has begun, the
    /// pass takes the body's way, which builds deeper; and a `noscript` that
    /// would then have been in the head, holding what the tokeniser would read
    /// differently there, is counted as every tag that could lie ahead, left open.
    func testFramesAndTheHeadAreCountedAsTheParserBuildsThem() throws {
        let tags = String(repeating: "<i>", count: 100)
        func exactly(_ markup: String) throws {
            XCTAssertEqual(try inspected(markup, as: .html).deepest, depth(of: try SwiftSoup.parseHTML(markup, "")), markup.prefix(60).debugDescription)
        }
        // Frames before the body: the `i`s are ignored, and framesets nest in framesets.
        try exactly("<frameset>" + tags)
        try exactly("<frameset>" + String(repeating: "<table><frameset></table>", count: 300))
        try exactly("<frameset><noframes>" + tags + "</noframes></frameset>")
        // Frames in the body: ordinary elements.
        try exactly("words<frameset><div></div>")
        try exactly("<html><body>" + String(repeating: "<frameset><table>", count: 30))
        // A noscript of the head, and one of the body.
        try exactly("<noscript><title></noscript></title>" + tags)
        try exactly("<noscript><select></noscript></select>" + tags)
        try exactly("<noscript><plaintext></noscript>" + tags)
        try exactly("<head><noscript><link rel=x><style>\(tags)</style></noscript></head><body>")
        try exactly("words<noscript><title>\(tags)</title></noscript>")
        // Whitespace made of a character reference: the body's way, deeper than the parser's frames.
        XCTAssertGreaterThan(try inspected("&#32;<frameset>" + tags, as: .html).deepest, depth(of: try SwiftSoup.parseHTML("&#32;<frameset>" + tags, "")))
        XCTAssertGreaterThanOrEqual(try inspected("&#32;<noscript><title></noscript></title>" + tags, as: .html).deepest, 100)
    }

    // MARK: - Each Format's Own Path

    /// An EPUB of the given chapters, each an XHTML file, in reading order.
    private func makeEPUB(chapters: [String]) throws -> URL {
        let items = chapters.indices.map { "<item id=\"c\($0)\" href=\"c\($0).xhtml\" media-type=\"application/xhtml+xml\"/>" }.joined()
        let spine = chapters.indices.map { "<itemref idref=\"c\($0)\"/>" }.joined()
        let package = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:uuid:\(UUID().uuidString)</dc:identifier>
            <dc:title>Guarded \(UUID().uuidString)</dc:title><dc:language>en</dc:language></metadata>
            <manifest>\(items)</manifest><spine>\(spine)</spine></package>
            """
        var entries = [
            TestZIPEntry("mimetype", Data("application/epub+zip".utf8)),
            TestZIPEntry("META-INF/container.xml", Data("""
                <?xml version="1.0"?>
                <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
                </container>
                """.utf8)),
            TestZIPEntry("OEBPS/content.opf", Data(package.utf8)),
        ]
        for (number, chapter) in chapters.enumerated() {
            entries.append(TestZIPEntry("OEBPS/c\(number).xhtml", Data(chapter.utf8)))
        }
        let zip = try makeTemporaryZip(prefix: "TextMouthMarkupGuard", orderedEntries: entries)
        let epub = try makeSandboxDirectory("MarkupGuard").appendingPathComponent("book.epub")
        try FileManager.default.moveItem(at: zip, to: epub)
        return epub
    }

    /// An EPUB's chapter holding a broken declaration reads, on an import's stack, and one
    /// that would overflow the stack is left out by name, with the others read.
    func testAnEPUBReadsAroundWhatItsChaptersHold() throws {
        let epub = try makeEPUB(chapters: [
            xhtml("<?a><p>First chapter words.</p>"),
            xhtml(String(repeating: "<div></x>", count: 5_000)),
            Self.declaration + "<?1?><html><body><p>Third chapter words.</p></body></html>",
        ])
        let read = onWorkerSizedStack { Result { try EPUBParser.prepareBook(url: epub) }.map { book in
            (book.chapters.map(\.chapter.text), book.report.omissions.map(\.chapterNumber))
        } }
        let (texts, omitted) = try XCTUnwrap(read).get()
        XCTAssertEqual(texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }, ["First chapter words.", "Third chapter words."])
        XCTAssertEqual(omitted, [2])
    }

    /// An honest EPUB nested 5,000 deep, which once ended the app, says what is wrong with it.
    func testAnEPUBWhoseOnlyChapterIsTooDeepIsRefused() throws {
        let deep = String(repeating: "<div>", count: 5_000) + "words" + String(repeating: "</div>", count: 5_000)
        let epub = try makeEPUB(chapters: [xhtml(deep)])
        let read = onWorkerSizedStack { Result { try EPUBParser.prepareBook(url: epub).title } }
        XCTAssertThrowsError(try XCTUnwrap(read).get()) { error in
            guard case .noReadableChapters = error as? EPUBParserError else { return XCTFail("\(error)") }
        }
    }

    /// A Kindle book's section meets the same guard, through the reader's whole path.
    func testAKindleBookHoldsToo() throws {
        func prepared(_ html: String) throws -> Result<[String], Error> {
            var fixture = MOBIFixture()
            fixture.html = html
            let url = try writeMOBI(fixture.data())
            return try XCTUnwrap(onWorkerSizedStack {
                Result { try MOBIParser.prepareBook(url: url).chapters.map(\.chapter.text) }
            })
        }
        // A section that opens as XML goes to SwiftSoup's XML parser.
        let words = try prepared(Self.declaration + "<?a><p>The words.</p>").get().joined()
        XCTAssertEqual(words.trimmingCharacters(in: .whitespacesAndNewlines), "The words.")
        for hostile in [
            "<html><body>" + String(repeating: "<div></x>", count: 5_000) + "</body></html>",
            "<html><body>" + String(repeating: "<span><div></span>", count: 5_000) + "</body></html>",
            Self.declaration + String(repeating: "<br>", count: 5_000),
        ] {
            XCTAssertThrowsError(try prepared(hostile).get(), String(hostile.prefix(60))) { error in
                XCTAssertEqual(error as? MarkupRefusal, .nestedTooDeeply(limit: MarkupGuard.Limits.standard.deepestNesting))
            }
        }
    }

    /// A DAISY navigation file meets it too.
    func testADAISYNavigationFileHoldsToo() throws {
        let opening = Self.declaration + "<?a><html><head></head><body>"
        let navigation = opening + "<h1><a href=\"part1.smil#p1\">Leadline Readings</a></h1></body></html>"
        XCTAssertNoThrow(try DAISY202NCCParser(html: navigation, file: "ncc.html").parse())
        let deep = opening + String(repeating: "<div></x>", count: 5_000) + "</body></html>"
        let read = onWorkerSizedStack { Result { _ = try DAISY202NCCParser(html: deep, file: "ncc.html").parse() } }
        XCTAssertThrowsError(try XCTUnwrap(read).get()) { error in
            XCTAssertEqual(error as? MarkupRefusal, .nestedTooDeeply(limit: MarkupGuard.Limits.standard.deepestNesting))
        }
    }

    /// A web archive's main page reads through the two paths a page takes.
    func testAWebArchivePageHoldsToo() throws {
        let page = WebArchiveReader.MainPage(text: xhtml("<?a><p>Words.</p>"), isHTML: true)
        XCTAssertTrue(try page.markdown().contains("Words"))
        let deep = WebArchiveReader.MainPage(text: "<html><body>" + String(repeating: "<div></x>", count: 5_000), isHTML: true)
        let refused = onWorkerSizedStack {
            ((try? deep.markdown()) == nil, (try? deep.parsed(title: "T")) == nil)
        }
        XCTAssertEqual(refused?.0, true)
        XCTAssertEqual(refused?.1, true)
    }

    /// A feed's page or title is never read past the limits: it reads as nothing, or as the text it is.
    func testAFeedsMarkupHoldsToo() throws {
        let hostile = "<html><body>" + String(repeating: "<div></x>", count: 5_000) + "</body></html>"
        let page = try XCTUnwrap(URL(string: "https://example.com/feed"))
        let links = onWorkerSizedStack { FeedDiscovery.feedLinks(inPage: hostile, pageURL: page).count }
        XCTAssertEqual(links, 0)
        let text = onWorkerSizedStack { FeedTextConverter.read(html: hostile) == nil }
        XCTAssertEqual(text, true)
        let line = onWorkerSizedStack { FeedTextConverter.plainLine(hostile, isHTML: true) }
        XCTAssertEqual(line, hostile)
        XCTAssertEqual(FeedTextConverter.plainLine("<?a><b>Words</b>", isHTML: true), "Words")
    }

    /// Feed discovery reads pages nested deeper than any the converter reads,
    /// since it walks a page with a stack of its own and converts nothing, up
    /// to a limit of its own: a page nested 200 levels deep gives its feed, and
    /// one past that limit is refused before SwiftSoup parses it.
    func testFeedDiscoveryReadsPagesDeeperThanTheConverterDoes() throws {
        let page = try XCTUnwrap(URL(string: "https://example.com/show/"))
        func nested(_ levels: Int) -> String {
            "<html><head><link rel=\"alternate\" type=\"application/rss+xml\" href=\"feed.xml\"></head><body>"
                + String(repeating: "<div>", count: levels) + "words" + String(repeating: "</div>", count: levels) + "</body></html>"
        }
        XCTAssertGreaterThan(200, MarkupGuard.Limits.standard.deepestNesting)
        // The pages are made here, outside the closures the worker runs, which may hold only what can be sent.
        let deepPage = nested(200)
        let pastPage = nested(FeedDiscovery.deepestNesting)
        let deep = onWorkerSizedStack { FeedDiscovery.feedLinks(inPage: deepPage, pageURL: page).map(\.url.absoluteString) }
        XCTAssertEqual(deep, ["https://example.com/show/feed.xml"])
        let past = onWorkerSizedStack { FeedDiscovery.feedLinks(inPage: pastPage, pageURL: page).count }
        XCTAssertEqual(past, 0)
    }

    // MARK: - Size

    /// The limit on tags counts everything that takes a node in the tree.
    func testTheLimitOnTagsCountsWhatTakesMemory() throws {
        let limits = MarkupGuard.Limits(deepestNesting: 256, mostMemoryUnits: 1_000, mostAttributesOnATag: 100, mostWork: .max)
        func refused(_ markup: String, as dialect: MarkupGuard.Dialect) -> Bool {
            do {
                _ = try MarkupGuard.inspect(Array(markup.utf8), as: dialect, limits: limits)
                return false
            } catch {
                XCTAssertEqual(error as? MarkupRefusal, .tooMuchMarkup, String(markup.prefix(40)))
                return true
            }
        }
        for dialect in [MarkupGuard.Dialect.html, .xml] {
            // An end tag takes no node.
            XCTAssertFalse(refused(String(repeating: "<i></i>", count: 1_000), as: dialect))
            XCTAssertTrue(refused(String(repeating: "<i></i>", count: 1_001), as: dialect))
            XCTAssertFalse(refused(String(repeating: "</i>", count: 5_000), as: dialect))
            XCTAssertFalse(refused(String(repeating: "<!---->", count: 1_000), as: dialect))
            XCTAssertTrue(refused(String(repeating: "<!---->", count: 1_001), as: dialect))
            XCTAssertTrue(refused(String(repeating: "<?a?>", count: 1_001), as: dialect))
        }
        // A stray end tag of a paragraph makes a paragraph.
        XCTAssertFalse(refused(String(repeating: "</p>", count: 1_000), as: .html))
        XCTAssertTrue(refused(String(repeating: "</p>", count: 1_001), as: .html))
        // A tag with attributes takes two more than a plain tag, and each three of its
        // attributes one more: 300 tags of one attribute make 1,000, and 301 make 1,003.
        XCTAssertFalse(refused(String(repeating: "<i a></i>", count: 300), as: .html))
        XCTAssertTrue(refused(String(repeating: "<i a></i>", count: 301), as: .html))
        XCTAssertEqual(try inspected("<i a b c d>", as: .html).memoryUnits, 1 + 2 + 1)
        // Formatting made again costs what its element costs: 100 for each of 12 paragraphs, with their own.
        let formatting = "<p>" + (0..<100).map { "<b n=\($0)>" }.joined() + "</p>"
        XCTAssertTrue(refused(formatting + String(repeating: "<p>x</p>", count: 12), as: .html))
        // And each copy holds the attributes its original does.
        let copied = try inspected(formatting + String(repeating: "<p>x</p>", count: 12), as: .html)
        XCTAssertEqual(copied.attributes, 100 * 13)
        XCTAssertEqual(copied.tagsWithAttributes, 100 * 13)
    }

    /// What SwiftSoup spends the square of is counted: moving a block's children,
    /// looking through the attributes of `html` and `body`, and searching on from
    /// each tag in a `<title>`. A real book spends next to nothing this way.
    func testWorkThatGrowsWithTheSquareIsCounted() throws {
        let tens = try inspected("<b><div>" + String(repeating: "<br>", count: 10) + "</b>", as: .html).work
        let hundreds = try inspected("<b><div>" + String(repeating: "<br>", count: 100) + "</b>", as: .html).work
        XCTAssertGreaterThan(hundreds, tens * 50, "moving a block's children")
        let few = try inspected((0..<10).map { "<body a\($0)>" }.joined(), as: .html).work
        let many = try inspected((0..<100).map { "<body a\($0)>" }.joined(), as: .html).work
        XCTAssertGreaterThan(many, few * 50, "the attributes of the body")
        let short = try inspected("<title>" + String(repeating: "<a ", count: 10) + "</title>", as: .html).work
        let long = try inspected("<title>" + String(repeating: "<a ", count: 100) + "</title>", as: .html).work
        XCTAssertGreaterThan(long, short * 50, "searching on in a title")
        XCTAssertEqual(try inspected("<title>Words</title><p>Words</p><b>Words</b>", as: .html).work, 0)
    }

    /// A refusal reaches the reader through the real path, with the limits a test
    /// binds; a document under them reads.
    func testTheLimitsInForceReachTheRealPath() throws {
        let limits = MarkupGuard.Limits(deepestNesting: 10, mostMemoryUnits: 100, mostAttributesOnATag: 5, mostWork: 1_000)
        try MarkupGuard.$limits.withValue(limits) {
            // Markdown escapes the full stop.
            XCTAssertEqual(try HTMLToMarkdownConverter.convert("<p>Words.</p>"), "Words\\.")
            XCTAssertThrowsError(try HTMLToMarkdownConverter.convert(String(repeating: "<div>", count: 11))) {
                XCTAssertEqual($0 as? MarkupRefusal, .nestedTooDeeply(limit: 10))
            }
            XCTAssertThrowsError(try HTMLToMarkdownConverter.convert(String(repeating: "<br>", count: 101))) {
                XCTAssertEqual($0 as? MarkupRefusal, .tooMuchMarkup)
            }
            XCTAssertThrowsError(try HTMLToMarkdownConverter.convert("<a b c d e f g>")) {
                XCTAssertEqual($0 as? MarkupRefusal, .tooManyAttributes(limit: 5))
            }
            XCTAssertThrowsError(try HTMLToMarkdownConverter.convert(String(repeating: "<i a></i>", count: 34))) {
                XCTAssertEqual($0 as? MarkupRefusal, .tooMuchMarkup)
            }
            XCTAssertThrowsError(try HTMLToMarkdownConverter.convert("<title>" + String(repeating: "<a ", count: 100) + "</title>")) {
                XCTAssertEqual($0 as? MarkupRefusal, .tooMuchWork)
            }
            XCTAssertThrowsError(try HTMLParser.parse(html: String(repeating: "<div>", count: 11), title: "T"))
            XCTAssertThrowsError(try MarkupGuard.parseBodyFragment(String(repeating: "<div>", count: 11)))
            XCTAssertThrowsError(try MarkupGuard.parseXML(String(repeating: "<div>", count: 11)))
        }
    }

    /// The limits every reading has, as the report of the measurements behind them gives them.
    func testTheStandardLimitsArePinned() {
        XCTAssertEqual(
            MarkupGuard.Limits.standard,
            MarkupGuard.Limits(deepestNesting: 128, mostMemoryUnits: 1_000_000, mostAttributesOnATag: 1_000, mostWork: 30_000_000_000)
        )
    }

    // MARK: - The Sentences

    /// Each refusal says what is wrong and what a person can do, and no one of them calls the file damaged.
    func testTheRefusalsSpeakPlainly() {
        XCTAssertEqual(
            MarkupRefusal.nestedTooDeeply(limit: 256).errorDescription,
            "This file's markup nests more than 256 levels deep, which TextMouth can't read safely. "
                + "Get another copy of the file, or save it in another format, then import it again."
        )
        XCTAssertEqual(
            MarkupRefusal.tooMuchMarkup.errorDescription,
            "One document in this file holds too much markup for TextMouth to read without running out of memory. "
                + "Divide the document into smaller files, then import them."
        )
        XCTAssertEqual(
            MarkupRefusal.tooManyAttributes(limit: 1_000).errorDescription,
            "One tag in this file has more than \(1_000.formatted()) attributes, which TextMouth can't read safely. "
                + "Get another copy of the file, or save it in another format, then import it again."
        )
        XCTAssertEqual(
            MarkupRefusal.tooMuchWork.errorDescription,
            "This file's markup is built in a way that would take TextMouth far too long to read. "
                + "Get another copy of the file, or save it in another format, then import it again."
        )
    }

    // MARK: - One Way In

    /// Nothing in the app reaches SwiftSoup's parsers but through the guard, so a
    /// new reader cannot leave it behind.
    func testEveryParseGoesThroughTheGuard() throws {
        // `Parser.` with nothing joined to its front: `HTMLParser.parse` is another thing.
        let entryPoint = try NSRegularExpression(
            pattern: #"SwiftSoup\.parse|(?<![A-Za-z0-9_])Parser\.(parse|xmlParser|htmlParser)|\.parseInput\(|XmlTreeBuilder\("#
        )
        for source in try AppSourceFile.all() where source.name != "MarkupGuard.swift" {
            for (number, line) in source.text.components(separatedBy: .newlines).enumerated() {
                // What a comment says calls nothing.
                let code = line.components(separatedBy: "//").first ?? line
                let found = entryPoint.firstMatch(in: code, range: NSRange(code.startIndex..., in: code))
                XCTAssertNil(found, "\(source.path), line \(number + 1), reaches SwiftSoup itself: call MarkupGuard instead")
            }
        }
    }
}
