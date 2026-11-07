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
}

/// The digest TextMouth stores as each book's identity (`md5Hash` in
/// bookInfo.json and library.json), the duplicate check at import, and the
/// text cache's fingerprint. Every digest pinned here was computed outside
/// the app (`md5 -q`, and Python's `hashlib` for the generated file), so a
/// change of algorithm, of formatting, or of the read loop fails here, and
/// a book's identity can never change silently under the hashes already on
/// disk. Comparing the function with itself, as two of these tests once
/// did, could not fail.
final class LegacyMD5Tests: XCTestCase {
    func testHashIsA32CharacterHexString() throws {
        let hash = try FileImportService.md5Hash(of: requireFile("alice.epub"))
        XCTAssertEqual(hash.count, 32)
        XCTAssertTrue(hash.allSatisfy(\.isHexDigit))
    }

    /// The same bytes always give the same, known digest: alice.epub's.
    func testHashIsDeterministic() throws {
        XCTAssertEqual(try FileImportService.md5Hash(of: requireFile("alice.epub")), "a96b5829861c1e9a579d66dedf4ae51e")
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

    /// A text file read in one go, under one read's size, has its known digest.
    func testTextFileHashMatchesAcrossReads() throws {
        XCTAssertEqual(try FileImportService.md5Hash(of: requireFile("pride.txt")), "f61a708aabe9df087601a5d85b859526")
    }

    /// A file far smaller than one read has its known digest.
    func testASmallFileHasItsKnownDigest() throws {
        XCTAssertEqual(try FileImportService.md5Hash(of: requireFile("sample.md")), "1686307c1c2ecb9675d7613e8f9217ce")
    }

    /// An empty file has MD5's digest of nothing.
    func testAnEmptyFileHasTheDigestOfNothing() throws {
        let file = try makeSandboxDirectory("MD5Empty").appendingPathComponent("empty.txt")
        try Data().write(to: file)
        XCTAssertEqual(try FileImportService.md5Hash(of: file), "d41d8cd98f00b204e9800998ecf8427e")
    }

    /// A file of three full 1 MiB reads and 17 bytes more is hashed whole,
    /// every read in order. Byte i is i modulo 251, so no two reads hold the
    /// same bytes, and a loop that stopped early, skipped a read, or read
    /// one twice would give another digest.
    func testAFileOfSeveralReadsIsHashedWhole() throws {
        let file = try makeSandboxDirectory("MD5Reads").appendingPathComponent("reads.bin")
        try Data((0..<3_145_745).map { UInt8($0 % 251) }).write(to: file)
        XCTAssertEqual(try FileImportService.md5Hash(of: file), "7114d559ffda7029526064baa992a30d")
    }
}
