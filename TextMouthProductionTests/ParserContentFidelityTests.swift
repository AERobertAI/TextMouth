import XCTest
@testable import TextMouth

/// Check the emitted reading text, not just intermediate parser structures.
final class ParserContentFidelityTests: XCTestCase {
    /// Explicit body-text outline levels override a misleading style name;
    /// invalid numeric values must neither overflow nor invent a heading.
    func testDOCXBodyAndInvalidOutlineLevelsDoNotBecomeHeadings() {
        for level in [9, -1, Int.max] {
            let styles = DOCXStylesParser(xml: """
            <w:styles xmlns:w="urn:word"><w:style w:styleId="Heading1">
            <w:name w:val="heading 1"/><w:pPr><w:outlineLvl w:val="\(level)"/></w:pPr>
            </w:style></w:styles>
            """).parse()
            XCTAssertNil(styles.headingLevels["Heading1"], "outline level \(level)")
        }
    }

    /// Invalid list depths fall back to a readable top-level item rather than
    /// indexing before the level array or allocating unbounded indentation.
    func testDOCXInvalidListLevelsRemainReadable() {
        var numbering = DOCXNumbering()
        numbering.abstractNums["list"] = [ListLevelFormat(numFmt: "decimal")]
        numbering.numIdToAbstractId["1"] = "list"
        XCTAssertEqual(numbering.listType(numId: "1", level: -1), .bullet)
        for level in [-1, Int.max] {
            let converter = DOCXToMarkdownConverter(
                styles: DOCXStyles(), numbering: numbering, relationships: [:]
            )
            let markdown = converter.convert(xmlString: """
            <w:document xmlns:w="urn:word"><w:body><w:p><w:pPr><w:numPr>
            <w:ilvl w:val="\(level)"/><w:numId w:val="1"/>
            </w:numPr></w:pPr><w:r><w:t>Item</w:t></w:r></w:p></w:body></w:document>
            """)
            XCTAssertEqual(markdown, "1. Item")
        }
    }

    /// Both code node types are meaningful document content to read aloud.
    func testMarkdownRetainsInlineAndFencedCode() throws {
        let chapter = try MarkdownDocParser.parseChapter(markdown: """
        Use `print(value)` here.

        ```swift
        let value = 42
        print(value)
        ```

        Continue reading.
        """)
        XCTAssertTrue(chapter.text.contains("Use print(value) here."))
        XCTAssertTrue(chapter.text.contains("let value = 42\nprint(value)"))
        XCTAssertTrue(chapter.text.hasSuffix("Continue reading."))
    }

    /// Repeated body text must not steal a heading's position. Offsets use the
    /// same UTF-16 coordinates as speech, search, and bookmarks.
    func testHeadingPositionsReferToHeadingOccurrencesAfterUnicodeBodyText() throws {
        let chapter = try MarkdownDocParser.parseChapter(markdown: """
        🙂 The Introduction is described here.

        # Introduction

        Introduction is repeated again.

        ## Introduction
        """)
        let text = chapter.text as NSString
        let first = text.range(of: "\n\nIntroduction\n\n").location + 2
        let second = text.range(of: "Introduction", options: .backwards).location
        XCTAssertEqual(chapter.headings.map(\.characterOffset), [first, second])
    }

    /// A heading whose literal text merely spells "<!--" holds no comment,
    /// so its label is swift-markdown's plain text exactly: nothing, U+200B
    /// included, is trimmed from its ends. (A real comment in a heading is
    /// still left out of the label; see EPUBHeadingRecoveryTests.)
    func testMarkdownHeadingSpellingACommentKeepsItsLabelExactly() throws {
        let chapter = try MarkdownDocParser.parseChapter(markdown: "# \\<\\!\\-\\- note \\-\\-\\> x\u{200B}\n\nBody.")
        XCTAssertEqual(chapter.headings.map(\.text), ["<!-- note --> x\u{200B}"])
    }

    /// Hyperlink formatting should survive while its words appear only once.
    func testDOCXHyperlinkIsEmittedOnceInReadingOrder() throws {
        let converter = DOCXToMarkdownConverter(
            styles: DOCXStyles(), numbering: DOCXNumbering(),
            relationships: ["link1": "https://example.com/reference"]
        )
        let markdown = converter.convert(xmlString: """
        <w:document xmlns:w="urn:word" xmlns:r="urn:relationship"><w:body><w:p>
        <w:r><w:t>Read </w:t></w:r>
        <w:hyperlink r:id="link1"><w:r><w:rPr><w:b/></w:rPr><w:t>the reference</w:t></w:r></w:hyperlink>
        <w:r><w:t> next.</w:t></w:r>
        </w:p></w:body></w:document>
        """)
        XCTAssertTrue(markdown.contains("[**the reference**](https://example.com/reference)"))
        let chapter = try MarkdownDocParser.parseChapter(markdown: markdown)
        XCTAssertEqual(chapter.text, "Read the reference next.")
    }

    /// A break belongs between its surrounding run text, and tabs must prevent
    /// adjacent words from being silently joined.
    func testDOCXRunBreaksAndTabsKeepTheirOriginalPosition() {
        let converter = DOCXToMarkdownConverter(
            styles: DOCXStyles(), numbering: DOCXNumbering(), relationships: [:]
        )
        let markdown = converter.convert(xmlString: """
        <w:document xmlns:w="urn:word"><w:body><w:p><w:r>
        <w:t>First</w:t><w:br/><w:t>Second</w:t><w:tab/><w:t>Third</w:t>
        </w:r></w:p></w:body></w:document>
        """)
        XCTAssertEqual(markdown, "First\nSecond\tThird")
    }

    // MARK: - Plain Text

    /// Read a plain-text source both ways TextMouth can: directly, as when no
    /// cache can be written, and from its content.md representation exactly
    /// as the cache loader parses it. The two must be one reading.
    @discardableResult
    private func assertPlainTextReadingsAgree(
        _ source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Chapter {
        let direct = PlainTextParser.parse(text: source, title: "Plain")
        let cached = MarkdownCacheService.parseMultiChapterMarkdown(
            PlainTextParser.markdown(text: source), bookTitle: "Plain", bookAuthor: "Author"
        )
        return assertSamePlainTextReading(
            cached: cached, direct: direct, context: "source \(source.debugDescription)", file: file, line: line
        ) ?? Chapter()
    }

    /// Every heading style is still recognized on both paths, and each heading
    /// sits where its label begins. ATX markers (including closing ones) and
    /// a setext underline are heading syntax, so the listener hears the label.
    func testPlainTextHeadingStylesAreRecognizedOnBothPaths() {
        let chapter = assertPlainTextReadingsAgree("""
        # Opening Words #
        Body of the opening.

        Second Part
        ===========
        Setext body.

        Minor Part
        ----
        CHAPTER THREE
        Closing words.
        ### Deep ###
        """)
        let expected = """
        Opening Words

        Body of the opening.

        Second Part

        Setext body.

        Minor Part

        CHAPTER THREE

        Closing words.

        Deep
        """
        XCTAssertEqual(chapter.text, expected)
        let labels = ["Opening Words", "Second Part", "Minor Part", "CHAPTER THREE", "Deep"]
        XCTAssertEqual(chapter.headings.map(\.text), labels)
        XCTAssertEqual(chapter.headings.map(\.level), [1, 1, 2, 2, 3])
        XCTAssertEqual(
            chapter.headings.map(\.characterOffset),
            labels.map { (expected as NSString).range(of: $0).location }
        )
    }

    /// The reading text differs from the source only by the documented
    /// whitespace normalization: lines are trimmed, a paragraph's lines are
    /// joined by single spaces, and any run of empty lines is one paragraph
    /// break. Inner tabs survive. Every newline character ends a line, so a
    /// CRLF pair also leaves an empty line, which separates paragraphs.
    func testPlainTextReadingTextNormalizesOnlyWhitespace() {
        let source = "  Indented first line\t\nwraps here  \n\n\n\tSecond paragraph\twith a tab\r"
            + "old Mac line\u{2028}separator line\r\nWindows line"
        let chapter = assertPlainTextReadingsAgree(source)
        XCTAssertEqual(
            chapter.text,
            "Indented first line wraps here\n\n"
                + "Second paragraph\twith a tab old Mac line separator line\n\nWindows line"
        )
        XCTAssertEqual(chapter.headings, [])
    }

    /// Heading offsets use UTF-16, like speech, search, and bookmarks, so an
    /// emoji or a combining mark before a heading moves it by its UTF-16 length.
    func testPlainTextHeadingOffsetsCountUTF16AfterEmoji() {
        let chapter = assertPlainTextReadingsAgree("🙂 Cafe\u{301} opens\n\nTHE MENU\nTea")
        XCTAssertEqual(chapter.text, "🙂 Cafe\u{301} opens\n\nTHE MENU\n\nTea")
        XCTAssertEqual(chapter.headings.map(\.characterOffset), [("🙂 Cafe\u{301} opens\n\n" as NSString).length])
    }

    /// The Markdown reader must replace U+0000 with U+FFFD; the direct path
    /// reads it the same way, in body text and in heading labels.
    func testPlainTextNullCharacterReadsAsReplacementOnBothPaths() {
        let chapter = assertPlainTextReadingsAgree("NUL\u{0}HEADING\n\nbody\u{0}text")
        XCTAssertEqual(chapter.text, "NUL\u{FFFD}HEADING\n\nbody\u{FFFD}text")
        XCTAssertEqual(chapter.headings.map(\.text), ["NUL\u{FFFD}HEADING"])
    }

    /// Markdown- and HTML-looking text in a .txt source is ordinary text. The
    /// cached reading keeps every character of each construct, in order,
    /// exactly as the direct reading does, and none of them adds a heading.
    func testPlainTextKeepsMarkdownAndHTMLLookalikesLiteral() {
        let paragraphs = [
            "Stars *around* words and **doubled** ones",
            "Underscores _around_ words and __doubled__ ones",
            "Backticks `around code` and a lone ` mark",
            "Tags <b>bold</b>, <span class=\"x\">spans</span>, and <br/>",
            "Brackets [a link](https://example.com), ![an image](i.png), and [ref]",
            "1. Numbered like a list item",
            "2) Numbered with a parenthesis",
            "- Dashed like a list item",
            "+ Plussed like a list item",
            "* Starred like a list item",
            "> Quoted like a block quote",
            "***",
            "Entities &amp; &lt;tag&gt; &#65; &#x42; &copy;",
            "Backslashes \\ C:\\Users\\*name* \\n and one at the end \\",
            "Comparisons a < b, b > a, and x<y>z",
            "Straight \"double\" and 'single' quotes in don't",
            "Dashes -- and --- and an ellipsis...",
            "Tildes ~~struck~~, pipes | a | b |, and carets ^[x](y)",
        ]
        let chapter = assertPlainTextReadingsAgree(paragraphs.joined(separator: "\n\n"))
        XCTAssertEqual(chapter.text.components(separatedBy: "\n\n"), paragraphs)
        XCTAssertEqual(chapter.headings, [])
    }

    /// Heading labels are literal too: markup characters stay in the label
    /// and in the spoken heading, whatever the heading style.
    func testPlainTextHeadingLabelsKeepMarkupCharacters() {
        let chapter = assertPlainTextReadingsAgree("""
        ## Part *One*: <draft> & [notes](x) `v2` \\ #1 ##
        Body.
        ISSUE #5 -- *DRAFT* <B>
        Title with _under_ & 'quotes'...
        ===
        """)
        let labels = [
            "Part *One*: <draft> & [notes](x) `v2` \\ #1",
            "ISSUE #5 -- *DRAFT* <B>",
            "Title with _under_ & 'quotes'...",
        ]
        XCTAssertEqual(chapter.headings.map(\.text), labels)
        XCTAssertEqual(chapter.headings.map(\.level), [2, 2, 1])
        XCTAssertEqual(chapter.text, [labels[0], "Body.", labels[1], labels[2]].joined(separator: "\n\n"))
    }

    /// A line that looks like an HTML comment is spoken text, not a hidden
    /// comment, whether it stands alone or sits inside a paragraph.
    func testPlainTextHTMLCommentLineIsSpokenText() {
        let chapter = assertPlainTextReadingsAgree("<!-- note -->\n\nBefore\n<!-- note -->\nafter")
        XCTAssertEqual(chapter.text, "<!-- note -->\n\nBefore <!-- note --> after")
        XCTAssertEqual(chapter.headings, [])
    }

    /// Lines the heuristics have never treated as headings are read exactly
    /// as written: seven markers, markers without a label, underlines with no
    /// heading above them (including one under an ATX heading), and all-caps
    /// lines with under three letters or over eighty characters.
    func testPlainTextLinesThatAreNotHeadingsStayLiteral() {
        let longCaps = String(repeating: "LONG ", count: 17).trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(longCaps.count, 84)
        let chapter = assertPlainTextReadingsAgree("""
        ####### Seven markers

        ###

        =====
        ---
        # Heading
        ---
        OK 42

        \(longCaps)
        """)
        XCTAssertEqual(chapter.text, [
            "####### Seven markers", "###", "===== ---", "Heading", "--- OK 42", longCaps,
        ].joined(separator: "\n\n"))
        XCTAssertEqual(chapter.headings.map(\.text), ["Heading"])
        XCTAssertEqual(chapter.headings.map(\.level), [1])
    }

    /// Escapes apply per Unicode scalar: a quote, dash, or period followed by
    /// a combining mark is one Swift Character, yet the Markdown parser would
    /// still curl the quote or merge the dashes. A byte-order mark at the
    /// start, which the parser would drop, stays a character.
    func testPlainTextKeepsPunctuationBeforeCombiningMarksAndLeadingByteOrderMark() {
        let source = "\u{FEFF}It'\u{301}s \"\u{301}odd\" -\u{301}- .\u{301}.."
        let chapter = assertPlainTextReadingsAgree(source)
        XCTAssertEqual(chapter.text, source)
    }

    /// Exactly CommonMark's 32 ASCII punctuation characters are escaped; a
    /// backslash before anything else would itself be read aloud.
    func testMarkdownLiteralEscapesExactlyTheASCIIPunctuation() {
        let punctuation = PlainTextFixture.asciiPunctuation
        XCTAssertEqual(punctuation.count, 32)
        XCTAssertEqual(MarkdownLiteral.escaped(punctuation), punctuation.map { "\\\($0)" }.joined())
        let unescaped = "Az09 e\u{301}🙂\t\u{00A0}“”‘’–—…\u{0}"
        XCTAssertEqual(MarkdownLiteral.escaped(unescaped), unescaped)
        XCTAssertEqual(MarkdownLiteral.escaped("a\u{FEFF}b"), "a&#xFEFF;b")
    }

    /// The invariant on one book that mixes every heading style, every
    /// construct the cache used to reinterpret, Unicode, inner tabs, and all
    /// line endings: the direct and cached readings are one text with one
    /// heading list, and each heading sits where its label begins.
    func testPlainTextReadingsAgreeOnCombinedFixture() {
        let chapter = assertPlainTextReadingsAgree(PlainTextFixture.combined)
        XCTAssertEqual(chapter.text, PlainTextFixture.combinedReading)
        XCTAssertEqual(chapter.headings.map(\.level), PlainTextFixture.combinedHeadings.map(\.level))
        XCTAssertEqual(chapter.headings.map(\.text), PlainTextFixture.combinedHeadings.map(\.text))
        let text = chapter.text as NSString
        for heading in chapter.headings {
            XCTAssertTrue(text.substring(from: heading.characterOffset).hasPrefix(heading.text), heading.text)
        }
    }

    /// The invariant for arbitrary text rather than chosen examples: sources
    /// assembled at random from every ASCII punctuation character, Markdown
    /// and HTML constructs, heading-shaped lines, Unicode marks and spaces,
    /// invisible characters, NUL, and every newline character read the same
    /// on both paths. The seed is fixed, so a failure names a source that
    /// replays exactly.
    func testPlainTextReadingsAgreeOnGeneratedSources() {
        var generator = SeededGenerator(state: 0x7E57)
        for _ in 0..<1_000 {
            assertPlainTextReadingsAgree(PlainTextFixture.randomSource(using: &generator))
            // One replayable failing source explains the rest; stop there.
            if (testRun?.totalFailureCount ?? 0) > 0 {
                break
            }
        }
    }

    // MARK: - HTML

    /// The one chapter HTMLParser reads directly from `html`, as when a book
    /// is opened before its cache exists.
    private func directHTMLReading(_ html: String) throws -> Chapter {
        try XCTUnwrap(HTMLParser.parse(html: html, title: "HTML").chapters.first)
    }

    /// Every boundary keeps the words on either side apart in the direct
    /// reading, after the element as well as before it: nested blocks, text
    /// after a block, table rows and cells, definition entries, line breaks,
    /// and the edit elements SwiftSoup counts as blocks.
    func testDirectHTMLKeepsWordsApartAtEveryBoundary() throws {
        let readings: [(html: String, text: String)] = [
            ("<div><div>One</div><div>Two</div></div>Three", "One Two Three"),
            ("<section>Tide</section>tables<aside>list</aside>soundings", "Tide tables list soundings"),
            (HTMLFixture.table, "Soundings Name Depth Odile 30 Bruno 41"),
            (HTMLFixture.definitions, "Ebb The falling tide. Flood The rising tide."),
            ("<p>High<br/>water</p>", "High water"),
            ("<p>Fare<del>ten</del>eight<ins>pence</ins></p>", "Fare ten eight pence"),
        ]
        for (html, text) in readings {
            XCTAssertEqual(try directHTMLReading(html).text, text, html)
        }
    }

    /// An image is read as its alt text, with the alt's whitespace collapsed
    /// like any other text's.
    func testDirectHTMLReadsImageAltText() throws {
        let chapter = try directHTMLReading("<p>See the <img src=\"m.png\" alt=\" tide\n   map \"/> below.</p>")
        XCTAssertEqual(chapter.text, "See the tide map below.")
    }

    /// A heading's label is the words the reading hears for it: alt text is
    /// part of it and hidden content is not. A heading nested inside another
    /// heading, or inside preformatted text or code, is part of that text
    /// rather than a heading of its own.
    func testDirectHTMLHeadingLabelsAreTheirReadWords() throws {
        let chapter = try directHTMLReading("""
        <h1>Part <span hidden="">secret</span><img src="n.png" alt="Two"/></h1>
        <h2>Outer <span><h3>Inner</h3></span></h2>
        <pre><h4>Preformatted</h4></pre><div><code><h5>Coded</h5></code></div>
        """)
        XCTAssertEqual(chapter.text, "Part Two Outer Inner Preformatted Coded")
        XCTAssertEqual(chapter.headings.map(\.text), ["Part Two", "Outer Inner"])
        XCTAssertEqual(chapter.headings.map(\.level), [1, 2])
        XCTAssertEqual(chapter.headings.map(\.characterOffset), [0, ("Part Two " as NSString).length])
    }

    /// The Markdown cache's reading of `html`: the Markdown the cache writes
    /// for an HTML book, parsed exactly as the cache loader parses it.
    private func cachedHTMLReading(_ html: String) throws -> Chapter {
        let markdown = try HTMLToMarkdownConverter.convert(html)
        let content = MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: "HTML", bookAuthor: "Author")
        XCTAssertEqual(content.chapters.count, 1, markdown)
        return try XCTUnwrap(content.chapters.first)
    }

    /// Text that looks like Markdown or HTML is read from the cache exactly
    /// as written: each paragraph keeps every character, in order, and none
    /// becomes a heading, list, quotation, rule, link, tag, or smart quote.
    func testCachedHTMLKeepsMarkdownLookalikesLiteral() throws {
        let paragraphs = HTMLFixture.lookalikeParagraphs
        let html = paragraphs.map { "<p>\(HTMLFixture.escaped($0))</p>" }.joined(separator: "\n")
        let chapter = try cachedHTMLReading(html)
        XCTAssertEqual(chapter.text.components(separatedBy: "\n\n"), paragraphs)
        XCTAssertEqual(chapter.headings, [])
    }

    /// A heading line holds its label as literal text: markup characters stay
    /// in the label and in the words read, and the link, emphasis, code, line
    /// break, and image inside the heading leave only their words.
    func testCachedHTMLHeadingLabelsKeepMarkupCharacters() throws {
        let chapter = try cachedHTMLReading("""
        <h2>Part *One* [draft] #1 &lt;b&gt; `v2` \\ -- ##</h2><p>Body.</p>
        <h3><a href="toc.xhtml#c1">Chapter <em>One</em></a><br/><code>x*y</code> <img src="m.png" alt="[map]"/></h3>
        """)
        let labels = ["Part *One* [draft] #1 <b> `v2` \\ -- ##", "Chapter One x*y [map]"]
        XCTAssertEqual(chapter.headings.map(\.text), labels)
        XCTAssertEqual(chapter.headings.map(\.level), [2, 3])
        XCTAssertEqual(chapter.text, [labels[0], "Body.", labels[1]].joined(separator: "\n\n"))
    }

    /// Inline code is read verbatim, backticks and all. Whitespace at its
    /// edges is read as the spaces around it.
    func testCachedHTMLCodeSpansKeepBackticksAndPunctuation() throws {
        let chapter = try cachedHTMLReading("""
        <p>Run <code>echo `date` *now* \\n</code>, type <code>`</code> or <code>``x``</code> then<code> spaced </code>.</p>
        """)
        XCTAssertEqual(chapter.text, "Run echo `date` *now* \\n, type ` or ``x`` then spaced .")
    }

    /// Code beside code is read as written. A second span's opening fence
    /// would merge with the first span's closing fence into one run of
    /// backticks; neither span would close, and the backticks would be read.
    func testCachedHTMLAdjacentCodeSpansKeepTheirWords() throws {
        let chapter = try cachedHTMLReading("<p>Type <code>``</code><code>|</code><code>x</code> now.</p>")
        XCTAssertEqual(chapter.text, "Type ``|x now.")
    }

    /// Alt text is read as written, brackets included.
    func testCachedHTMLImageAltTextKeepsBrackets() throws {
        let chapter = try cachedHTMLReading("<p>Chart <img src=\"c.png\" alt=\"Figure [1]: tides\"/> here.</p>")
        XCTAssertEqual(chapter.text, "Chart Figure [1]: tides here.")
    }

    /// Links and images keep their syntax whatever their destination holds
    /// (spaces, parentheses, angle brackets, a backslash), so none of it is
    /// read. Alt text is read with its outer whitespace around the image. A
    /// link holding blocks, or nothing, is written as its words alone.
    func testCachedHTMLLinksAndImagesKeepTheirSyntaxWhateverTheirDestination() throws {
        let html = """
        <p>See <a href="notes (draft).xhtml#n 1">the <em>notes</em></a> and <a href="a&lt;b&gt;\\c">odd</a>.</p>
        <p><img src="tide (1).png" alt=" Chart [1] "/>after</p>
        <div><a href="x.xhtml"><span>Block</span><div>link</div></a><a href="y.xhtml"> </a>end</div>
        """
        let markdown = try HTMLToMarkdownConverter.convert(html)
        XCTAssertTrue(markdown.contains("[the *notes*](<notes (draft).xhtml#n 1>)"), markdown)
        XCTAssertTrue(markdown.contains("[odd](<a\\<b\\>\\\\c>)"), markdown)
        XCTAssertTrue(markdown.contains("![Chart \\[1\\]](<tide (1).png>) after"), markdown)
        XCTAssertFalse(markdown.contains("[Block"), markdown)
        XCTAssertFalse(markdown.contains("y.xhtml"), markdown)
        XCTAssertEqual(
            try cachedHTMLReading(html).text,
            "See the notes and odd.\n\nChart [1] after\n\nBlock\n\nlink\n\nend"
        )
    }

    /// Emphasis never reaches speech as asterisks: not with whitespace or
    /// punctuation at its edges, nor when empty, nested, beside other
    /// emphasis, or around blocks, links, code, or line breaks. Each reads
    /// as its words alone. Plainly emphasized words keep their markers, with
    /// edge punctuation outside them.
    func testCachedHTMLEmphasisMarkersAreNeverRead() throws {
        let readings: [(html: String, text: String)] = [
            ("<p>The<i> Titanic </i>sank</p>", "The Titanic sank"),
            ("<p><b>Note:</b>Read <i>\"Stop!\"</i>, she said.</p>", "Note:Read \"Stop!\", she said."),
            ("<p><i>Mr.</i><i>Smith</i> and <b>a</b><b>b</b></p>", "Mr.Smith and ab"),
            ("<p><b>Warning: <i>hot</i> surface</b></p>", "Warning: hot surface"),
            ("<p>a<em></em>b<strong> </strong>c</p>", "ab c"),
            ("<em><div>A</div><div>B</div></em>", "A\n\nB"),
            ("<p>Wait<i>...</i><i>*</i>x<i>*y</i></p>", "Wait...*x*y"),
            ("<p><em>“Quoted”</em> 🙂<i>🙂 smile</i></p>", "“Quoted” 🙂🙂 smile"),
            ("<p><em><a href=\"x\">see</a></em>here and x<em><code>y</code> z</em></p>", "seehere and xy z"),
            ("<p><em>line<br/>break</em></p>", "line\nbreak"),
        ]
        for (html, text) in readings {
            XCTAssertEqual(try cachedHTMLReading(html).text, text, html)
        }
        let markdown = try HTMLToMarkdownConverter.convert("<p>The <i>Titanic</i>'s <b>last voyage</b>.</p>")
        XCTAssertEqual(markdown, "The *Titanic*\\'s **last voyage**\\.")
    }

    /// The cache keeps words apart at every boundary the direct reading
    /// has: blocks and definition entries are paragraphs, a table row is one
    /// paragraph of its cells separated by spaces, and line breaks and edit
    /// elements separate words within a paragraph.
    func testCachedHTMLKeepsWordsApartAtEveryBoundary() throws {
        let readings: [(html: String, text: String)] = [
            ("<div><div>One</div><div>Two</div></div>Three", "One\n\nTwo\n\nThree"),
            ("<section>Tide</section>tables<aside>list</aside>soundings", "Tide\n\ntables\n\nlist\n\nsoundings"),
            (HTMLFixture.table, "Soundings\n\nName Depth\n\nOdile 30\n\nBruno 41"),
            (HTMLFixture.definitions, "Ebb\n\nThe falling tide.\n\nFlood\n\nThe rising tide."),
            ("<p>High<br/>water</p>", "High\nwater"),
            ("<p>Fare<del>ten</del>eight<ins>pence</ins></p>", "Fare ten eight pence"),
            ("<table><tr><td>Top<br/>bottom</td><td>Side</td></tr></table>", "Top\nbottom Side"),
        ]
        for (html, text) in readings {
            XCTAssertEqual(try cachedHTMLReading(html).text, text, html)
        }
    }

    /// Preformatted text keeps its lines, indentation, tabs, and blank lines
    /// in the cache, markup-looking text included. A line of three backticks
    /// inside cannot close the block early, and the paragraph after the
    /// block is still read as prose.
    func testCachedHTMLPreformattedTextKeepsItsLines() throws {
        let code = "let x = 1\n    indented()\n```\nnot closed ``\n\n\ttabbed <b>*x*</b> \\"
        let chapter = try cachedHTMLReading("<p>Before.</p><pre>\(HTMLFixture.escaped(code))</pre><p>After.</p>")
        XCTAssertTrue(chapter.text.hasPrefix("Before.\n\n\(code)\n"), chapter.text)
        XCTAssertTrue(chapter.text.hasSuffix("\nAfter."), chapter.text)
    }

    /// Markup inside preformatted text (the spans of highlighted code and
    /// line breaks) keeps the text's layout, and a destination inside it
    /// precedes the block instead of becoming words of the code.
    func testCachedHTMLPreformattedMarkupKeepsLayoutAndDestinations() throws {
        let html = """
        <pre><code><span class="k">let</span> <span id="tide">tide</span> =
          <b>ebb</b><br/>flood</code></pre>
        """
        let targets = ["tide": MarkdownHeadingAnnotation(level: 2, text: "Tide target")]
        let markdown = try HTMLToMarkdownConverter.convert(html, headingTargets: targets)
        let chapter = try MarkdownDocParser.parseChapter(markdown: markdown, includeNavigationHeadings: true)
        XCTAssertEqual(chapter.text, "let tide =\n  ebb\nflood")
        XCTAssertEqual(chapter.headings.map(\.text), ["Tide target"])
        XCTAssertEqual(chapter.headings.map(\.characterOffset), [0])
    }

    /// Anything a list holds outside its items (text, a list nested directly
    /// inside the list, a paragraph) is read in place instead of dropped, and
    /// a hidden item is still left out.
    func testCachedHTMLListsKeepContentOutsideTheirItems() throws {
        let html = """
        <ul>Before<li>One</li>between<li>Two</li><ul><li>Nested</li></ul><p>After</p></ul>
        <ol><li>First</li><li hidden="">Hidden</li><li>Second</li></ol>
        """
        let words = ["Before", "One", "between", "Two", "Nested", "After", "First", "Second"]
        XCTAssertEqual(try cachedHTMLReading(html).text.split(whereSeparator: \.isWhitespace).map(String.init), words)
        XCTAssertTrue(try HTMLToMarkdownConverter.convert(html).hasSuffix("1. First\n2. Second"))
    }

    /// Boundaries are written only where missing, so nested and empty blocks
    /// never pile up blank lines around the words they hold.
    func testCachedHTMLNestedAndEmptyBlocksWriteOneBlankLine() throws {
        let markdown = try HTMLToMarkdownConverter.convert("""
        <div><p></p><section><div><p>First</p></div></section><p></p><ul></ul><blockquote><div>Second</div></blockquote></div>
        """)
        XCTAssertEqual(markdown, "First\n\n> Second")
    }

    /// Characters that `CharacterSet.whitespaces` holds but Unicode does not
    /// count as whitespace (U+200B) are words of both readings: nothing trims
    /// them from a list item, a quotation, or a heading label. A combining
    /// mark after a space joins it into one Character, yet the space still
    /// keeps the words before inline code apart from the code's.
    func testHTMLReadingsKeepCharactersThatCharacterSetTrims() throws {
        let html = """
        <p>Start</p><ul><li>\u{200B}</li></ul><blockquote>\u{200B}quoted\u{200B}</blockquote>\
        <h2>Label\u{200B}</h2><p>a]<code> \u{301}x</code></p>
        """
        let direct = try directHTMLReading(html)
        let cached = try cachedHTMLReading(html)
        XCTAssertEqual(direct.text, "Start \u{200B} \u{200B}quoted\u{200B} Label\u{200B} a] \u{301}x")
        XCTAssertEqual(cached.text, "Start\n\n\u{200B}\n\n\u{200B}quoted\u{200B}\n\nLabel\u{200B}\n\na] \u{301}x")
        XCTAssertEqual(direct.headings.map(\.text), ["Label\u{200B}"])
        XCTAssertEqual(cached.headings.map(\.text), ["Label\u{200B}"])
    }
}

extension XCTestCase {
    /// Assert that two readings of one plain-text book are the same reading:
    /// one chapter each, equal text, and equal headings (level, label, and
    /// UTF-16 offset) in the chapter and in the book-wide index. `context`
    /// names the source in failure messages. Returns the direct reading's
    /// chapter for further checks.
    @discardableResult
    func assertSamePlainTextReading(
        cached: DocumentContent,
        direct: DocumentContent,
        context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Chapter? {
        XCTAssertEqual(cached.chapters.count, 1, "cached chapters; \(context)", file: file, line: line)
        XCTAssertEqual(direct.chapters.count, 1, "parsed chapters; \(context)", file: file, line: line)
        guard let cachedChapter = cached.chapters.first, let directChapter = direct.chapters.first else {
            return nil
        }
        XCTAssertEqual(cachedChapter.text, directChapter.text, "reading text; \(context)", file: file, line: line)
        XCTAssertEqual(cachedChapter.headings, directChapter.headings, "chapter headings; \(context)", file: file, line: line)
        XCTAssertEqual(cached.allHeadings, direct.allHeadings, "indexed headings; \(context)", file: file, line: line)
        return directChapter
    }
}

/// SplitMix64: a tiny deterministic generator, so randomized tests repeat
/// exactly from run to run.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    /// Advance the state and scramble it into the next output.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// A plain-text book shared by the parser and cache tests, with its expected
/// reading written out in full.
enum PlainTextFixture {
    /// Every heading style, every construct the cache used to read as
    /// Markdown or HTML (a chapter-marker lookalike included), Unicode,
    /// surrounding and inner whitespace, and CRLF, CR, and LF line endings.
    static let combined = """
        THE PLAIN TEXT COMPANION
        A guide to *literal* reading, with _underscores_ and `code`.

        # Part 1: <Setup> & [notes](https://example.com) #
        Compare a < b and b > a; x<y>z is not a tag, nor is <b>bold</b>.
        Entities stay spelled out: &amp; &lt; &#65; &copy;
        Paths keep backslashes: C:\\Users\\*name* and a trailing one \\

        1. Numbered lines stay prose.
        2) So do parenthesized ones.
        - Dashed lines, + plussed lines, * starred lines.
        > Quoted lines too.
        ***
        <!-- note -->
        <!-- chapter: Not A Chapter -->

        Setext Title With 'Quotes' -- "Dashes"...
        =========================================
           Indented\tprose with an inner tab and trailing spaces\u{20}\u{20}\u{20}
        ~~Tildes~~, pipes | a | b |, carets ^[x](y), and ![alt](i.png).

        Minor Setext 🙂 Cafe\u{301}
        ----
        -----
        ## Emoji 🙂 and combining e\u{301} ##
        Last line.
        """ + "\r\nWindows ending\rold Mac ending\r\n\r\nFINAL WORDS"

    /// The reading both paths must produce: heading lines as their labels,
    /// the consumed setext underlines gone, the unconsumed one kept, and each
    /// paragraph's trimmed lines joined by spaces. Each CRLF also ends a
    /// paragraph, because it counts as a line break plus an empty line.
    static let combinedReading = [
        "THE PLAIN TEXT COMPANION",
        "A guide to *literal* reading, with _underscores_ and `code`.",
        "Part 1: <Setup> & [notes](https://example.com)",
        "Compare a < b and b > a; x<y>z is not a tag, nor is <b>bold</b>."
            + " Entities stay spelled out: &amp; &lt; &#65; &copy;"
            + " Paths keep backslashes: C:\\Users\\*name* and a trailing one \\",
        "1. Numbered lines stay prose. 2) So do parenthesized ones."
            + " - Dashed lines, + plussed lines, * starred lines. > Quoted lines too."
            + " *** <!-- note --> <!-- chapter: Not A Chapter -->",
        "Setext Title With 'Quotes' -- \"Dashes\"...",
        "Indented\tprose with an inner tab and trailing spaces"
            + " ~~Tildes~~, pipes | a | b |, carets ^[x](y), and ![alt](i.png).",
        "Minor Setext 🙂 Cafe\u{301}",
        "-----",
        "Emoji 🙂 and combining e\u{301}",
        "Last line.",
        "Windows ending old Mac ending",
        "FINAL WORDS",
    ].joined(separator: "\n\n")

    /// The headings both paths must find, in reading order.
    static let combinedHeadings: [(level: Int, text: String)] = [
        (2, "THE PLAIN TEXT COMPANION"),
        (1, "Part 1: <Setup> & [notes](https://example.com)"),
        (1, "Setext Title With 'Quotes' -- \"Dashes\"..."),
        (2, "Minor Setext 🙂 Cafe\u{301}"),
        (2, "Emoji 🙂 and combining e\u{301}"),
        (2, "FINAL WORDS"),
    ]

    /// CommonMark's 32 ASCII punctuation characters, in code point order.
    static let asciiPunctuation = ##"!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~"##

    /// Pieces of generated lines: every ASCII punctuation character, Markdown
    /// and HTML constructs, words that make all-caps headings, Unicode letters
    /// and marks, spaces, and invisible characters.
    private static let fragments = asciiPunctuation.map { String($0) } + [
        "alpha", "Beta", "GAMMA", "CHAPTER ONE", "Part", "e\u{301}", "🙂", "👩‍👩‍👧", "ß", "ǅ", "ⅫⅫⅫ", "1984",
        "***", "---", "===", "--", "...", "&amp;", "&#65;", "<b>", "</b>", "<!-- note -->",
        "<!-- chapter: Fake -->", "[a](b)", "![i](j)", "`code`", "\\", "~~s~~", "^[x](y)", "a|b",
        "<http://x.y>", "#", "##", "#######", "1.", "2)", "- ", "> ", "[ ]", "\"quoted\"", "It's", "a < b",
        " ", "  ", "\t", "\u{00A0}", "\u{3000}", "\u{200B}",
        "\u{0}", "\u{FEFF}", "\u{0301}", "\u{200D}", "\u{0007}", "\u{FFFE}",
    ]

    /// Whole generated lines that probe the heading heuristics and Markdown
    /// block syntax: underlines, markers, indentation, fences, and tables.
    private static let wholeLines = [
        "", "   ", "=====", "-----", "===", "---", "#", "## Heading", "# CHAPTER #", "#hashtag",
        "   # Indented heading", "LOUD WORDS HERE", "\u{FEFF}# Title", "    four space indent", "\tTabbed",
        "trailing  ", "Title", "```", "| a | b |", "|---|---|", "1. item", "- [ ] task",
    ]

    /// Every character in `CharacterSet.newlines`, CRLF, and blank lines.
    private static let lineBreaks = [
        "\n", "\r\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}", "\n\n", "\n \t\n",
    ]

    /// A random plain-text source of up to twelve lines: a quarter of them
    /// whole lines from `wholeLines`, the rest built from `fragments`.
    static func randomSource<Generator: RandomNumberGenerator>(using generator: inout Generator) -> String {
        var source = ""
        for index in 0..<Int.random(in: 0...12, using: &generator) {
            if index > 0 {
                source += lineBreaks.randomElement(using: &generator)!
            }
            if Int.random(in: 0..<4, using: &generator) == 0 {
                source += wholeLines.randomElement(using: &generator)!
                continue
            }
            for _ in 0..<Int.random(in: 0...6, using: &generator) {
                source += fragments.randomElement(using: &generator)!
                if Bool.random(using: &generator) {
                    source += " "
                }
            }
        }
        return source
    }
}

/// HTML sources shared by the parser and cache tests.
enum HTMLFixture {
    /// A captioned table with a header row and two body rows.
    static let table = """
        <table><caption>Soundings</caption>
        <thead><tr><th>Name</th><th>Depth</th></tr></thead>
        <tbody><tr><td>Odile</td><td>30</td></tr><tr><td>Bruno</td><td>41</td></tr></tbody>
        </table>
        """

    /// A definition list of two terms, each with its description.
    static let definitions = """
        <dl><dt>Ebb</dt><dd>The falling tide.</dd><dt>Flood</dt><dd>The rising tide.</dd></dl>
        """

    /// Paragraph texts (as a listener must hear them) that Markdown would
    /// read as markup if the cache wrote them verbatim: emphasis, headings,
    /// list items, a quotation, a thematic break, links and images, tags and
    /// comments decoded from entities, backslashes, comparisons, the dashes,
    /// ellipsis, and straight quotes smart punctuation would replace, an
    /// entity spelled out, strikethrough, table pipes, and code spans.
    static let lookalikeParagraphs = [
        "Stars *around* words and **doubled** ones",
        "Underscores _around_ words and __doubled__ ones",
        "# Not a heading",
        "1. Not a list item",
        "- Not a bullet + nor this",
        "> Not a quotation",
        "***",
        "Brackets [x](y) and ![i](j) stay brackets",
        "Tags <b>bold</b> and <!-- note --> stay text",
        "A backslash \\ and C:\\path\\*name* \\",
        "Comparisons a < b and b > a",
        "Dashes -- and --- and an ellipsis...",
        "Straight \"double\" and 'single' quotes in don't",
        "Entities spelled &amp; out",
        "Tildes ~~struck~~ and pipes | a | b |",
        "`backticks` and a lone ` mark",
    ]

    /// `text` as HTML text content: the characters HTML would read as markup
    /// become character references.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
