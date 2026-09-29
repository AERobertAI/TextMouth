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
        return assertSamePlainTextReading(cached: cached, direct: direct, file: file, line: line) ?? Chapter()
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
}

extension XCTestCase {
    /// Assert that two readings of one plain-text book are the same reading:
    /// one chapter each, equal text, and equal headings (level, label, and
    /// UTF-16 offset) in the chapter and in the book-wide index. Returns the
    /// direct reading's chapter for further checks.
    @discardableResult
    func assertSamePlainTextReading(
        cached: DocumentContent,
        direct: DocumentContent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Chapter? {
        XCTAssertEqual(cached.chapters.count, 1, "a cached plain-text book is one chapter", file: file, line: line)
        XCTAssertEqual(direct.chapters.count, 1, "a parsed plain-text book is one chapter", file: file, line: line)
        guard let cachedChapter = cached.chapters.first, let directChapter = direct.chapters.first else {
            return nil
        }
        XCTAssertEqual(cachedChapter.text, directChapter.text, "reading text", file: file, line: line)
        XCTAssertEqual(cachedChapter.headings, directChapter.headings, "chapter headings", file: file, line: line)
        XCTAssertEqual(cached.allHeadings, direct.allHeadings, "indexed headings", file: file, line: line)
        return directChapter
    }
}
