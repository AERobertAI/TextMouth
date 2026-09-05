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
}
