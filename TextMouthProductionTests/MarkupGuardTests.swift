import SwiftSoup
import XCTest
@testable import TextMouth

extension MarkupGuard.Limits {
    /// The standard limits but for nesting, for the tests that hold the app's
    /// own walks over a tree to not recursing, on trees the guard would refuse.
    static let withoutDepthLimit = MarkupGuard.Limits(
        deepestNesting: .max, mostTags: standard.mostTags, mostAttributesOnATag: standard.mostAttributesOnATag
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
    private static let unbounded = MarkupGuard.Limits(deepestNesting: .max, mostTags: .max, mostAttributesOnATag: .max)

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
            XCTAssertTrue(markdown.contains("Before."), shape)
            XCTAssertTrue(markdown.contains("After."), shape)
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

    /// Exactly the limit reads to its words on an import's stack, in the shapes
    /// that cost the parser most; one level past it is refused.
    func testTheDepthLimitIsExact() throws {
        let limit = MarkupGuard.Limits.standard.deepestNesting
        // In XML the guard counts `html` and `body` as it counts anything; in HTML it adds them to
        // what it sees. Each end tag makes the HTML parser walk to the root.
        let shapes: [(Int) -> String] = [
            { self.xhtml(String(repeating: "<div>", count: $0) + "words" + String(repeating: "</div>", count: $0)) },
            { "<html><body>" + String(repeating: "<div>", count: $0) + "words" + String(repeating: "</span></div>", count: $0) },
        ]
        for shape in shapes {
            let atLimit = try XCTUnwrap(converted(shape(limit - 2)))
            XCTAssertTrue(try atLimit.get().contains("words"))
            let past = try XCTUnwrap(converted(shape(limit - 1)))
            XCTAssertThrowsError(try past.get()) { error in
                XCTAssertEqual(error as? MarkupRefusal, .nestedTooDeeply(limit: limit))
            }
        }
        // The worst that fits: each level a table's four, or a formatting element's copy.
        let tables = "<html><body>" + String(repeating: "<table><td>", count: (limit - 2) / 4) + "words"
        XCTAssertTrue(try XCTUnwrap(converted(tables)).get().contains("words"))
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
            ("<p><span><p>", 3),
            ("<li><li><li>", 3),
            ("<ul><li><ul><li>", 6),
            ("<li><blockquote><li>", 5),
            ("<li><div><li>", 3),
            ("<dd><dt><dd>", 3),
            ("<h1><h2><h3>", 3),
            ("<h1><p><h2>", 4),
            ("<br><hr><img><input><wbr>", 2),
            ("<div/><span/><p/><x/>", 2),
            ("<b><b><b><b><b>", 7),
            ("<b></b><b></b>", 2),
            ("<div><b></div><div>x", 5),
            ("<div><b></div><div><i></div><div>x", 6),
            ("<i><p>x</i></p>", 2),
            ("<b><div></b>", 4),
            ("<a><a><a>", 3),
            ("<table><td>", 6),
            ("<table><td><td><td>", 6),
            ("<table><tr><td></tr><tr><td></tr>", 6),
            ("<table><td><table><td>", 10),
            ("<table></table><table></table>", 2),
            ("<table><table><table>", 3),
            ("<td><td><td>", 2),
            ("<tr><th>", 2),
            ("<select><div><div>", 3),
            ("<select><option><option>", 4),
            ("<select><optgroup><option><optgroup><option>", 6),
            ("<select><input>", 2),
            ("<object><object></object></object>", 2),
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
            ("<!DOCTYPE ><div><div>", 2),
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
            let tree = try SwiftSoup.parse(markup, "", Parser.xmlParser())
            XCTAssertEqual(inspection.deepest, depth(of: tree), markup.debugDescription)
        }
    }

    /// In random markup made for it, the pass never counts less than the tree's
    /// real depth, by more than the two levels it leaves out for `html` and the
    /// document. The parser's rules are walked through thousands of ways here, so
    /// this also fails if an update of SwiftSoup changes them.
    func testRandomMarkupGoesNoDeeperThanThePassCounts() throws {
        for pieces in [6, 30, 150] {
            for round in 0..<600 {
                let (text, opensAsXML) = MarkupFuzzGenerator.document(seed: 1, round: round, pieces: pieces)
                let inspection = try inspected(text, as: opensAsXML ? .xml : .html)
                let parsed = opensAsXML ? try? MarkupGuard.parseXML(text, deepestNesting: .max) : try? SwiftSoup.parseHTML(text, "")
                guard let parsed else { continue }
                XCTAssertLessThanOrEqual(depth(of: parsed), inspection.deepest + 2, text)
            }
        }
    }

    /// What could tell a page of frames, or a `noscript` of the head, from the
    /// body is read as many tags as could lie ahead, all left open.
    func testWhatCannotBeCertainCountsEveryTagAhead() throws {
        let tags = String(repeating: "<i>", count: 100)
        XCTAssertGreaterThanOrEqual(try inspected("<frameset>" + tags, as: .html).deepest, 100)
        XCTAssertGreaterThanOrEqual(try inspected("<noscript><title></noscript></title>" + tags, as: .html).deepest, 100)
        XCTAssertGreaterThanOrEqual(try inspected("<noscript><select></noscript></select>" + tags, as: .html).deepest, 100)
        XCTAssertGreaterThanOrEqual(try inspected("<noscript><plaintext></noscript>" + tags, as: .html).deepest, 100)
        // Once words have begun the body, a frameset is a plain element.
        XCTAssertLessThan(try inspected("words<frameset><div></div>", as: .html).deepest, 5)
        // A noscript of the body reads as anything else does.
        XCTAssertLessThan(try inspected("words<noscript><title>\(tags)</title></noscript>", as: .html).deepest, 5)
        // A noscript of the head with what such a one holds.
        XCTAssertLessThan(try inspected("<head><noscript><link rel=x><style>\(tags)</style></noscript></head><body>", as: .html).deepest, 5)
    }

    // MARK: - Size

    /// The limit on tags counts everything that takes a node in the tree.
    func testTheLimitOnTagsCountsWhatTakesMemory() throws {
        let limits = MarkupGuard.Limits(deepestNesting: 256, mostTags: 1_000, mostAttributesOnATag: 100)
        func refused(_ markup: String, as dialect: MarkupGuard.Dialect) -> Bool {
            do {
                _ = try MarkupGuard.inspect(Array(markup.utf8), as: dialect, limits: limits)
                return false
            } catch {
                XCTAssertEqual(error as? MarkupRefusal, .tooManyTags(limit: 1_000), String(markup.prefix(40)))
                return true
            }
        }
        for dialect in [MarkupGuard.Dialect.html, .xml] {
            XCTAssertFalse(refused(String(repeating: "<i></i>", count: 500), as: dialect))
            XCTAssertTrue(refused(String(repeating: "<i></i>", count: 501), as: dialect))
            XCTAssertFalse(refused(String(repeating: "<!---->", count: 1_000), as: dialect))
            XCTAssertTrue(refused(String(repeating: "<!---->", count: 1_001), as: dialect))
            XCTAssertTrue(refused(String(repeating: "<?a?>", count: 1_001), as: dialect))
        }
        // A stray end tag of a paragraph makes a paragraph.
        XCTAssertTrue(refused(String(repeating: "</p>", count: 501), as: .html))
        // Formatting made again costs what its element costs: 100 for each of 12 paragraphs.
        let formatting = "<p>" + (0..<100).map { "<b n=\($0)>" }.joined() + "</p>"
        XCTAssertTrue(refused(formatting + String(repeating: "<p>x</p>", count: 12), as: .html))
    }

    /// A refusal reaches the reader through the real path, with the limits a test
    /// binds; a document under them reads.
    func testTheLimitsInForceReachTheRealPath() throws {
        let limits = MarkupGuard.Limits(deepestNesting: 10, mostTags: 100, mostAttributesOnATag: 5)
        try MarkupGuard.$limits.withValue(limits) {
            XCTAssertEqual(try HTMLToMarkdownConverter.convert("<p>Words.</p>"), "Words.")
            XCTAssertThrowsError(try HTMLToMarkdownConverter.convert(String(repeating: "<div>", count: 11))) {
                XCTAssertEqual($0 as? MarkupRefusal, .nestedTooDeeply(limit: 10))
            }
            XCTAssertThrowsError(try HTMLToMarkdownConverter.convert(String(repeating: "<br>", count: 101))) {
                XCTAssertEqual($0 as? MarkupRefusal, .tooManyTags(limit: 100))
            }
            XCTAssertThrowsError(try HTMLToMarkdownConverter.convert("<a b c d e f g>")) {
                XCTAssertEqual($0 as? MarkupRefusal, .tooManyAttributes(limit: 5))
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
            MarkupGuard.Limits(deepestNesting: 256, mostTags: 4_000_000, mostAttributesOnATag: 10_000)
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
            MarkupRefusal.tooManyTags(limit: 1_000).errorDescription,
            "One document in this file holds more than \(1_000.formatted()) tags, too many for TextMouth to read without "
                + "running out of memory. Divide the document into smaller files, then import them."
        )
        XCTAssertEqual(
            MarkupRefusal.tooManyAttributes(limit: 1_000).errorDescription,
            "One tag in this file has more than \(1_000.formatted()) attributes, which TextMouth can't read safely. "
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
