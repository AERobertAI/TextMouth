import XCTest
@testable import TextMouth

final class LegacyFixtureParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: requireFile(name), encoding: .utf8)
    }

    func testPlainTextFixtureLoads() throws {
        XCTAssertGreaterThan(try fixture("pride.txt").count, 1_000)
    }

    func testPlainTextParseProducesContent() throws {
        let content = PlainTextParser.parse(
            text: try fixture("pride.txt"),
            title: "Pride and Prejudice"
        )
        XCTAssertEqual(content.title, "Pride and Prejudice")
        XCTAssertGreaterThan(content.chapters[0].text.count, 1_000)
    }

    func testPlainTextHeadingDetectionRunsOnBookFixture() throws {
        let content = PlainTextParser.parse(
            text: try fixture("pride.txt"),
            title: "Pride and Prejudice"
        )
        XCTAssertFalse(content.chapters.isEmpty)
        for heading in content.allHeadings {
            XCTAssertGreaterThanOrEqual(heading.characterOffset, 0)
            XCTAssertLessThanOrEqual(heading.characterOffset, content.chapters[0].text.utf16.count)
        }
    }

    func testPlainTextFixtureContainsExpectedContent() throws {
        let text = try fixture("pride.txt").lowercased()
        XCTAssertTrue(text.contains("darcy"))
        XCTAssertTrue(text.contains("elizabeth") || text.contains("bennet"))
    }

    func testMarkdownFixtureLoads() throws {
        XCTAssertGreaterThan(try fixture("sample.md").count, 100)
    }

    func testMarkdownExtractsHeadingLevels() throws {
        let content = try MarkdownDocParser.parse(
            markdown: fixture("sample.md"),
            title: "Sample"
        )
        let headings = content.allHeadings
        XCTAssertGreaterThan(headings.count, 3)
        XCTAssertTrue(headings.contains { $0.level == 1 })
        XCTAssertTrue(headings.contains { $0.level == 2 })
        XCTAssertTrue(headings.contains { $0.level == 3 })
    }

    func testMarkdownUsesFirstHeadingAsTitle() throws {
        let content = try MarkdownDocParser.parse(
            markdown: fixture("sample.md"),
            title: "Fallback Title"
        )
        XCTAssertEqual(content.title, "The Art of Testing")
    }

    func testMarkdownPlainTextStripsFormatting() throws {
        let content = try MarkdownDocParser.parse(
            markdown: fixture("sample.md"),
            title: "Sample"
        )
        let plainText = content.chapters[0].text
        XCTAssertFalse(plainText.contains("**"))
        XCTAssertFalse(plainText.contains("##"))
        XCTAssertTrue(plainText.contains("The Art of Testing"))
        XCTAssertTrue(plainText.contains("Once upon a time"))
    }

    func testHTMLFixtureLoads() throws {
        XCTAssertGreaterThan(try fixture("frankenstein.html").count, 1_000)
    }

    func testHTMLParseProducesTitledContent() throws {
        let content = try HTMLParser.parse(
            html: fixture("frankenstein.html"),
            title: "Frankenstein"
        )
        XCTAssertFalse(content.title.isEmpty)
        XCTAssertFalse(content.chapters.isEmpty)
    }

    func testHTMLExtractsHeadings() throws {
        let content = try HTMLParser.parse(
            html: fixture("frankenstein.html"),
            title: "Frankenstein"
        )
        XCTAssertFalse(content.allHeadings.isEmpty)
    }

    func testHTMLContainsExpectedBookContent() throws {
        let content = try HTMLParser.parse(
            html: fixture("frankenstein.html"),
            title: "Frankenstein"
        )
        let text = content.chapters[0].text.lowercased()
        XCTAssertTrue(
            text.contains("frankenstein") || text.contains("creature") || text.contains("monster")
        )
    }
}

final class LegacyHTMLToMarkdownTests: XCTestCase {
    func testBasicParagraphConversion() throws {
        XCTAssertTrue(try HTMLToMarkdownConverter.convert("<p>Hello world</p>").contains("Hello world"))
    }

    func testHeadingConversionPreservesLevels() throws {
        let result = try HTMLToMarkdownConverter.convert("<h1>Title</h1><h2>Subtitle</h2><h3>Section</h3>")
        XCTAssertTrue(result.contains("# Title"))
        XCTAssertTrue(result.contains("## Subtitle"))
        XCTAssertTrue(result.contains("### Section"))
    }

    func testEmphasisAndStrongConversion() throws {
        let result = try HTMLToMarkdownConverter.convert(
            "<p>This is <em>italic</em> and <strong>bold</strong> text.</p>"
        )
        XCTAssertTrue(result.contains("*italic*"))
        XCTAssertTrue(result.contains("**bold**"))
    }

    /// Destinations are written in angle brackets, so one holding spaces or
    /// parentheses cannot break the link and leave its syntax to be read.
    func testLinkConversion() throws {
        let result = try HTMLToMarkdownConverter.convert(
            "<p>Visit <a href=\"https://example.com\">Example</a> site.</p>"
        )
        XCTAssertTrue(result.contains("[Example](<https://example.com>)"))
    }

    func testUnorderedListConversion() throws {
        let result = try HTMLToMarkdownConverter.convert(
            "<ul><li>Item 1</li><li>Item 2</li><li>Item 3</li></ul>"
        )
        XCTAssertTrue(result.contains("- Item 1"))
        XCTAssertTrue(result.contains("- Item 2"))
        XCTAssertTrue(result.contains("- Item 3"))
    }

    func testOrderedListConversion() throws {
        let result = try HTMLToMarkdownConverter.convert("<ol><li>First</li><li>Second</li></ol>")
        XCTAssertTrue(result.contains("1. First"))
        XCTAssertTrue(result.contains("2. Second"))
    }

    func testBlockquoteConversion() throws {
        let result = try HTMLToMarkdownConverter.convert(
            "<blockquote><p>A quoted passage</p></blockquote>"
        )
        XCTAssertTrue(result.contains("> "))
        XCTAssertTrue(result.contains("A quoted passage"))
    }

    func testScriptAndStyleRemoval() throws {
        let result = try HTMLToMarkdownConverter.convert(
            "<p>Visible</p><script>alert('hidden')</script><style>.foo{}</style><p>Also visible</p>"
        )
        XCTAssertTrue(result.contains("Visible"))
        XCTAssertTrue(result.contains("Also visible"))
        XCTAssertFalse(result.contains("alert"))
        XCTAssertFalse(result.contains(".foo"))
    }

    func testEmptyHTMLProducesEmptyOutput() throws {
        let result = try HTMLToMarkdownConverter.convert("<html><body></body></html>")
        XCTAssertTrue(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testNestedEmphasisAndStrong() throws {
        let result = try HTMLToMarkdownConverter.convert("<p><strong><em>Both</em></strong></p>")
        XCTAssertTrue(result.contains("**"))
        XCTAssertTrue(result.contains("*"))
        XCTAssertTrue(result.contains("Both"))
    }

    func testHorizontalRuleConversion() throws {
        let result = try HTMLToMarkdownConverter.convert("<p>Before</p><hr><p>After</p>")
        XCTAssertTrue(result.contains("---"))
    }

    func testDuplicateNavigationIsRemovedWhenBodyHasHeadings() throws {
        let html = """
        <html><body>
        <nav><ol><li><a href="#ch1">Chapter 1</a></li><li><a href="#ch2">Chapter 2</a></li></ol></nav>
        <h1 id="ch1">Chapter 1</h1><p>Actual chapter content.</p>
        </body></html>
        """
        let result = try HTMLToMarkdownConverter.convert(html, stripDuplicateNavigation: true)
        XCTAssertEqual(result.components(separatedBy: "Chapter 1").count - 1, 1)
        XCTAssertFalse(result.contains("Chapter 2"))
    }

    func testNavigationOnlyHeadingIsPreserved() throws {
        let html = "<html><body><nav><h1>Contents</h1></nav><p>No heading exists outside nav.</p></body></html>"
        let result = try HTMLToMarkdownConverter.convert(html, stripDuplicateNavigation: true)
        XCTAssertTrue(result.contains("# Contents"))
    }

    func testBookFixtureConvertsToSubstantialMarkdown() throws {
        let html = try String(contentsOf: requireFile("frankenstein.html"), encoding: .utf8)
        let result = try HTMLToMarkdownConverter.convert(html)
        XCTAssertGreaterThan(result.count, 1_000)
        XCTAssertTrue(result.contains("#"))
    }

    /// Markup that opens 10,000 elements without closing them, as a feed's
    /// item or a web page can, converts on a worker thread's 512 KiB stack,
    /// where an import or a feed refresh converts it, keeping its words. The
    /// converter once recursed for every level and overflowed that stack,
    /// ending TextMouth at every launch that refreshed such a feed.
    func testMarkupNestedThousandsDeepConvertsOnAWorkerStack() {
        let html = String(repeating: "<div>", count: 10_000) + "Deep words"
        let markdown = onWorkerSizedStack { (try? HTMLToMarkdownConverter.convert(html)) ?? "" }
        XCTAssertEqual(markdown?.contains("Deep words"), true)
    }

    /// Nested past the deepest level the converter follows
    /// (`HTMLNesting.deepestLevel`), a subtree is written as one paragraph of
    /// its words: 150 nested block quotes give no line with more than that
    /// many quote markers, where every level once wrote one, and the words
    /// are all there.
    func testQuotesNestedPastTheDeepestLevelAreWrittenAsTheirWords() throws {
        let html = String(repeating: "<blockquote>", count: 150) + "Deep words"
            + String(repeating: "</blockquote>", count: 150)
        let markdown = try HTMLToMarkdownConverter.convert(html)
        XCTAssertTrue(markdown.contains("Deep words"))
        let deepestQuote = markdown.components(separatedBy: "\n")
            .map { line in line.filter { $0 == ">" }.count }
            .max() ?? 0
        XCTAssertLessThanOrEqual(deepestQuote, HTMLNesting.deepestLevel)
        XCTAssertGreaterThan(deepestQuote, 0)
    }
}

/// The scanner that says, before SwiftSoup parses markup, whether its
/// elements may nest past `HTMLNesting.deepestParsedLevel`
/// (`HTMLNesting.mayNest(_:deeperThan:as:)`). Each test pins one of its
/// rules with markup that crosses the limit only if the rule holds, or only
/// if it fails. The scanner may count more levels than SwiftSoup builds, but
/// never fewer of those it counts: an undercount would let SwiftSoup recurse
/// through markup too deep for a worker thread's stack.
final class HTMLNestingTests: XCTestCase {
    /// Whether `html`, read by `builder`, is past the shared parse's limit.
    private func isPastTheLimit(_ html: String, as builder: HTMLNesting.TreeBuilder = .html) -> Bool {
        HTMLNesting.mayNest(html, deeperThan: HTMLNesting.deepestParsedLevel, as: builder)
    }

    /// `markup` written `count` times.
    private func repeated(_ markup: String, _ count: Int) -> String {
        String(repeating: markup, count: count)
    }

    // MARK: - Nesting

    /// Lists nested 1,500 deep and closed level by level, as a table of
    /// contents is, are past the limit: each list counts a level.
    func testListsNestedPastTheLimitAndClosedLevelByLevelArePastIt() {
        XCTAssertTrue(isPastTheLimit(repeated("<ol><li>", 1_500) + "Deep words" + repeated("</li></ol>", 1_500)))
    }

    /// Markup 500 levels deep is within the limit.
    func testMarkupFiveHundredLevelsDeepIsWithinTheLimit() {
        XCTAssertFalse(isPastTheLimit(repeated("<div>", 500) + "Deep words" + repeated("</div>", 500)))
    }

    /// The limit counts the `html` and `body` elements SwiftSoup gives
    /// every HTML document, written or not: 998 elements inside them are at
    /// the limit, 999 past it.
    func testTheLimitCountsTheDocumentsHTMLAndBodyElements() {
        let depth = HTMLNesting.deepestParsedLevel - 2
        XCTAssertFalse(isPastTheLimit("<html><body>" + repeated("<div>", depth) + "</body></html>"))
        XCTAssertFalse(isPastTheLimit(repeated("<div>", depth)))
        XCTAssertTrue(isPastTheLimit(repeated("<div>", depth + 1)))
    }

    /// A long chapter of unclosed paragraphs nests nothing, since each
    /// paragraph ends where the next begins.
    func testUnclosedParagraphsNestNothing() {
        XCTAssertFalse(isPastTheLimit(repeated("<p>Words of a paragraph ", 1_500)))
    }

    /// A table counts four levels, for itself and the body, row, and cell
    /// SwiftSoup nests in it: 300 tables nested in cells are past the limit,
    /// 240 are not.
    func testATableCountsFourLevels() {
        XCTAssertTrue(isPastTheLimit(repeated("<table><tr><td>", 300) + "Deep words"))
        XCTAssertFalse(isPastTheLimit(repeated("<table><tr><td>", 240) + "Deep words"))
    }

    /// Ruby text and option groups, which SwiftSoup lets nest in one
    /// another, count a level each.
    func testRubyTextAndOptionGroupsCountALevelEach() {
        XCTAssertTrue(isPastTheLimit(repeated("<rt>", 1_200)))
        XCTAssertTrue(isPastTheLimit(repeated("<rb>", 1_200)))
        XCTAssertTrue(isPastTheLimit(repeated("<optgroup>", 1_200)))
    }

    // MARK: - What Is No Tag

    /// A script's comparisons are script, not tags: 2,000 of `a<b` are no
    /// elements.
    func testAScriptsComparisonsAreNoTags() {
        XCTAssertFalse(isPastTheLimit("<script>" + repeated("if (a<b) { total = a<b; }\n", 2_000) + "</script><p>After</p>"))
    }

    /// Comments, a doctype, and CDATA sections hold no elements, nor do a
    /// processing instruction or a tag the markup ends inside.
    func testCommentsDoctypesAndCDATACountNothing() {
        XCTAssertFalse(isPastTheLimit("<!DOCTYPE html><!-- " + repeated("<div>", 1_200) + " --><p>After</p>"))
        XCTAssertFalse(isPastTheLimit("<![CDATA[" + repeated("<div>", 1_200) + "]]><p>After</p>"))
        XCTAssertFalse(isPastTheLimit("<?xml-stylesheet href=\"a.css\"?><p>After</p>" + "<div class=\"" + repeated("<div>", 1_200)))
    }

    /// A comment ends where SwiftSoup ends it: at once after `<!--` and only
    /// dashes, or at `--!>`, so the tags after it count.
    func testACommentEndsWhereSwiftSoupEndsIt() {
        XCTAssertTrue(isPastTheLimit("<!-->" + repeated("<div>", 1_200)))
        XCTAssertTrue(isPastTheLimit("<!-- a note --!>" + repeated("<div>", 1_200)))
    }

    /// A tag ending `/>`, which SwiftSoup closes at once, opens nothing,
    /// whether a void element (`<br/>`) or not (`<div/>`), and so does
    /// SwiftSoup's `<div / >`.
    func testSelfClosedTagsCountNothing() {
        XCTAssertFalse(isPastTheLimit(repeated("Line<br/>", 1_500)))
        XCTAssertFalse(isPastTheLimit(repeated("<div/>", 1_500)))
        XCTAssertFalse(isPastTheLimit(repeated("<div class=\"x\"/>", 1_500)))
        XCTAssertFalse(isPastTheLimit(repeated("<div / >", 1_500)))
    }

    /// A value without quotes keeps a `/` before the `>`, so the tag does
    /// not close itself: `<div class=x/>` opens a division.
    func testAValueWithoutQuotesKeepsItsSlash() {
        XCTAssertTrue(isPastTheLimit(repeated("<div class=x/>", 1_200)))
    }

    /// A `>` in a quoted attribute value ends no tag, so the markup after it
    /// in the value is no tag either: 600 divisions whose titles hold two
    /// more each are 600 levels.
    func testAGreaterThanSignInAQuotedValueEndsNoTag() {
        XCTAssertFalse(isPastTheLimit(repeated("<div title=\"<div><div>\" data-note='a > b'>", 600)))
    }

    /// The text of `textarea`, `xmp`, `iframe`, and `noembed` is markup to
    /// SwiftSoup, whatever HTML says, so the elements in it count.
    func testTheTextOfTextareaXmpIframeAndNoembedIsMarkup() {
        for name in ["textarea", "xmp", "iframe", "noembed"] {
            XCTAssertTrue(isPastTheLimit("<\(name)>" + repeated("<span>", 1_200)), name)
        }
    }

    /// A script's `<!--` escapes its text, and a `<script>` inside the escape
    /// hides a `</script>`, as in SwiftSoup: the divisions after the hidden
    /// end tag are script. A `</script>` in a single escape still ends it.
    func testAScriptsEscapesFollowSwiftSoup() {
        XCTAssertFalse(isPastTheLimit("<script><!--<script></script>" + repeated("<div>", 1_200) + "--></script><p>After</p>"))
        XCTAssertTrue(isPastTheLimit("<script><!--</script>" + repeated("<div>", 1_200)))
        XCTAssertTrue(isPastTheLimit("<SCRIPT>var a;</ScRiPt>" + repeated("<div>", 1_200)))
    }

    /// A title's text runs to its end tag; with none anywhere after it,
    /// SwiftSoup ends the title at the first tag, which is markup.
    func testATitleWithoutAnEndTagEndsAtTheFirstTag() {
        XCTAssertFalse(isPastTheLimit("<title>A " + repeated("<div>", 1_200) + "</title><p>After</p>"))
        XCTAssertTrue(isPastTheLimit("<title>A " + repeated("<div>", 1_200)))
    }

    /// Everything after `plaintext` is text.
    func testEverythingAfterPlaintextIsText() {
        XCTAssertFalse(isPastTheLimit("<plaintext>" + repeated("<div>", 1_200)))
    }

    // MARK: - End Tags

    /// An end tag naming nothing open closes nothing. A template that
    /// closes each item's division as a span leaves 3,000 divisions open,
    /// which SwiftSoup nests, and the scanner too.
    func testAnEndTagNamingNothingOpenClosesNothing() {
        XCTAssertTrue(isPastTheLimit(repeated("<div class=item><span>x</span></span>", 3_000)))
    }

    /// An end tag never closes past a special element such as a division,
    /// where SwiftSoup ignores it.
    func testAnEndTagNeverClosesPastASpecialElement() {
        XCTAssertTrue(isPastTheLimit(repeated("<span><div></span>", 600)))
    }

    /// An end tag closes its element and everything still open inside it.
    func testAnEndTagClosesWhatItsElementHolds() {
        XCTAssertFalse(isPastTheLimit(repeated("<div><span>Words</div>", 1_200)))
    }

    /// A division's end tag never closes past a table, as SwiftSoup closes
    /// it only in scope: the divisions outside the table stay open.
    func testADivisionsEndTagNeverClosesPastATable() {
        let html = repeated("<div>", 500) + "<table><tr><td>" + repeated("</div>", 500) + repeated("<div>", 500)
        XCTAssertTrue(isPastTheLimit(html))
    }

    /// `</body>` and `</html>` close nothing, as SwiftSoup keeps its open
    /// elements there: markup after them goes on inside.
    func testTheDocumentsOwnEndTagsCloseNothing() {
        XCTAssertTrue(isPastTheLimit(repeated("<div>", 600) + "</body></html>" + repeated("<div>", 600)))
    }

    /// `</form>` closes only a form on top, since SwiftSoup takes the form
    /// off its stack but leaves what it holds inside it.
    func testAFormsEndTagClosesOnlyAFormOnTop() {
        XCTAssertTrue(isPastTheLimit(repeated("<form><div></form>", 600)))
        XCTAssertFalse(isPastTheLimit(repeated("<form>A field</form>", 1_200)))
    }

    /// A heading's end tag closes the nearest heading of any level.
    func testAHeadingsEndTagClosesAnyHeading() {
        XCTAssertFalse(isPastTheLimit(repeated("<h1>Title</h2>", 1_200)))
    }

    /// The end tag of an object closes nothing while an element named
    /// `name` is in scope, as SwiftSoup 2.13.9 has it.
    func testAnObjectsEndTagClosesNothingWhileANameElementIsInScope() {
        XCTAssertTrue(isPastTheLimit(repeated("<object><name></object>", 600)))
        XCTAssertFalse(isPastTheLimit(repeated("<object><div></object>", 600)))
    }

    // MARK: - Inside a Select

    /// Inside a `select`, SwiftSoup ignores most tags: end tags there close
    /// none of the divisions outside it.
    func testASelectIgnoresMostTags() {
        let html = repeated("<div>", 600) + "<select>" + repeated("</div>", 600) + "</select>" + repeated("<div>", 500)
        XCTAssertTrue(isPastTheLimit(html))
        XCTAssertFalse(isPastTheLimit("<select>" + repeated("<div>", 1_200) + "</select>"))
    }

    /// Inside a `select`, an option group that holds an option is not closed
    /// by the next group, so groups with options nest; groups alone do not.
    func testOptionGroupsHoldingOptionsNestInASelect() {
        XCTAssertTrue(isPastTheLimit("<select>" + repeated("<optgroup><option>Choice", 1_200) + "</select>"))
        XCTAssertFalse(isPastTheLimit("<select>" + repeated("<optgroup>", 1_200) + "</select>"))
    }

    // MARK: - XML

    /// SwiftSoup reads markup that begins with an XML declaration with its
    /// XML tree builder, where an unclosed paragraph holds what follows it:
    /// 1,500 of them are past the limit as XML, and nest nothing as HTML.
    func testUnclosedParagraphsNestInMarkupReadAsXML() {
        let body = repeated("<p>Words of a paragraph ", 1_500)
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + body
        XCTAssertEqual(HTMLNesting.TreeBuilder(reading: xml), .xml)
        XCTAssertTrue(isPastTheLimit(xml, as: .xml))
        XCTAssertFalse(isPastTheLimit(body, as: .html))
    }

    /// In XML every element without `/>` holds what follows it, a `<br>`
    /// too, and an end tag closes only an element of exactly its name.
    func testXMLElementsCloseOnlyAtTheirOwnEndTags() {
        let declaration = "<?xml version=\"1.0\"?>"
        XCTAssertTrue(isPastTheLimit(declaration + repeated("Line<br>", 1_200), as: .xml))
        XCTAssertFalse(isPastTheLimit(declaration + repeated("Line<br/>", 1_200), as: .xml))
        XCTAssertTrue(isPastTheLimit(declaration + repeated("<a></A>", 1_200), as: .xml))
        XCTAssertFalse(isPastTheLimit(declaration + repeated("<a><b></a>", 1_200), as: .xml))
    }

    /// The tree builder is chosen by SwiftSoup's own test: past whitespace,
    /// the markup begins with `<?xml`, in small letters.
    func testTheTreeBuilderIsChosenAsSwiftSoupChoosesIt() {
        XCTAssertEqual(HTMLNesting.TreeBuilder(reading: " \n\t<?xml version=\"1.0\"?><a/>"), .xml)
        XCTAssertEqual(HTMLNesting.TreeBuilder(reading: "<html><body>Words</body></html>"), .html)
        XCTAssertEqual(HTMLNesting.TreeBuilder(reading: "<?XML version=\"1.0\"?>"), .html)
        XCTAssertEqual(HTMLNesting.TreeBuilder(reading: "\u{FEFF}<?xml version=\"1.0\"?>"), .html)
        XCTAssertEqual(HTMLNesting.TreeBuilder(reading: ""), .html)
    }
}

final class LegacyMD5Tests: XCTestCase {
    func testHashIsA32CharacterHexString() throws {
        let hash = try FileImportService.md5Hash(of: requireFile("alice.epub"))
        XCTAssertEqual(hash.count, 32)
        XCTAssertTrue(hash.allSatisfy(\.isHexDigit))
    }

    func testHashIsDeterministic() throws {
        let url = try requireFile("alice.epub")
        XCTAssertEqual(
            try FileImportService.md5Hash(of: url),
            try FileImportService.md5Hash(of: url)
        )
    }

    func testDifferentFilesProduceDifferentHashes() throws {
        XCTAssertNotEqual(
            try FileImportService.md5Hash(of: requireFile("alice.epub")),
            try FileImportService.md5Hash(of: requireFile("pride.txt"))
        )
    }

    func testSmallFileHashHasExpectedShape() throws {
        let hash = try FileImportService.md5Hash(of: requireFile("sample.md"))
        XCTAssertEqual(hash.count, 32)
        XCTAssertTrue(hash.allSatisfy(\.isHexDigit))
    }

    func testTextFileHashMatchesAcrossReads() throws {
        let url = try requireFile("pride.txt")
        XCTAssertEqual(
            try FileImportService.md5Hash(of: url),
            try FileImportService.md5Hash(of: url)
        )
    }
}
