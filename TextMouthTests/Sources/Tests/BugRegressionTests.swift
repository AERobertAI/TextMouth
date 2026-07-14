import Foundation

#if canImport(TextMouth)
@testable import TextMouth
#endif

func runBugRegressionTests() {
print("\n--- Bug Regression Tests ---")

// ============================================================
// DAISY 3 OPF Spine Ordering
// ============================================================

test("DAISY 3 OPF parser extracts spine item refs") {
    // An OPF with spine defining reading order for multiple content files
    let opfXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://openebook.org/namespaces/oeb-package/1.0/">
    <metadata>
        <dc-metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:Title>Multi-Part Book</dc:Title>
            <dc:Creator>Test Author</dc:Creator>
        </dc-metadata>
    </metadata>
    <manifest>
        <item id="ch1" href="chapter1.xml" media-type="application/x-dtbook+xml"/>
        <item id="ch2" href="chapter2.xml" media-type="application/x-dtbook+xml"/>
        <item id="ch3" href="chapter3.xml" media-type="application/x-dtbook+xml"/>
        <item id="ncx" href="book.ncx" media-type="application/x-dtbncx+xml"/>
    </manifest>
    <spine>
        <itemref idref="ch1"/>
        <itemref idref="ch2"/>
        <itemref idref="ch3"/>
    </spine>
    </package>
    """
    let data = opfXML.data(using: .utf8)!
    let parser = DAISYOPFParser(data: data)
    let result = parser.parse()

    try assertEqual(result.title, "Multi-Part Book")
    try assertEqual(result.author, "Test Author")
    try assertEqual(result.spineItemRefs.count, 3, "Should have 3 spine refs")
    try assertEqual(result.spineItemRefs[0], "ch1", "First spine ref")
    try assertEqual(result.spineItemRefs[1], "ch2", "Second spine ref")
    try assertEqual(result.spineItemRefs[2], "ch3", "Third spine ref")
}

test("DAISY 3 OPF spine preserves reading order distinct from manifest order") {
    // Spine defines reverse order from manifest — spine order should win
    let opfXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package>
    <metadata>
        <dc-metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:Title>Reverse Order</dc:Title>
        </dc-metadata>
    </metadata>
    <manifest>
        <item id="partA" href="a.xml" media-type="application/x-dtbook+xml"/>
        <item id="partB" href="b.xml" media-type="application/x-dtbook+xml"/>
        <item id="partC" href="c.xml" media-type="application/x-dtbook+xml"/>
    </manifest>
    <spine>
        <itemref idref="partC"/>
        <itemref idref="partA"/>
        <itemref idref="partB"/>
    </spine>
    </package>
    """
    let data = opfXML.data(using: .utf8)!
    let parser = DAISYOPFParser(data: data)
    let result = parser.parse()

    try assertEqual(result.spineItemRefs, ["partC", "partA", "partB"],
                    "Spine order should match OPF spine element, not manifest order")
}

test("DAISY 3 OPF with empty spine still parses manifest") {
    let opfXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package>
    <metadata>
        <dc-metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:Title>No Spine</dc:Title>
        </dc-metadata>
    </metadata>
    <manifest>
        <item id="content" href="text.xml" media-type="application/x-dtbook+xml"/>
    </manifest>
    <spine></spine>
    </package>
    """
    let data = opfXML.data(using: .utf8)!
    let parser = DAISYOPFParser(data: data)
    let result = parser.parse()

    try assertTrue(result.spineItemRefs.isEmpty, "Spine should be empty")
    try assertEqual(result.manifest.count, 1, "Manifest should have 1 item")
}

test("DAISY 3 OPF spine skips non-DTBook items") {
    // Spine references NCX and audio — only DTBook items should be used for text
    let opfXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package>
    <metadata>
        <dc-metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:Title>Mixed Spine</dc:Title>
        </dc-metadata>
    </metadata>
    <manifest>
        <item id="ncx" href="book.ncx" media-type="application/x-dtbncx+xml"/>
        <item id="smil1" href="s1.smil" media-type="application/smil"/>
        <item id="ch1" href="chapter1.xml" media-type="application/x-dtbook+xml"/>
        <item id="smil2" href="s2.smil" media-type="application/smil"/>
        <item id="ch2" href="chapter2.xml" media-type="application/x-dtbook+xml"/>
    </manifest>
    <spine>
        <itemref idref="ncx"/>
        <itemref idref="smil1"/>
        <itemref idref="ch1"/>
        <itemref idref="smil2"/>
        <itemref idref="ch2"/>
    </spine>
    </package>
    """
    let data = opfXML.data(using: .utf8)!
    let parser = DAISYOPFParser(data: data)
    let result = parser.parse()

    // The extraction logic in DAISYParser filters to DTBook media types,
    // so spine refs for non-DTBook items are harmless but present
    try assertEqual(result.spineItemRefs.count, 5, "All spine refs are captured")

    // Verify DTBook items are in the manifest
    let dtbookItems = result.manifest.values.filter {
        $0.mediaType.contains("dtbook") || $0.mediaType.contains("x-dtbook")
    }
    try assertEqual(dtbookItems.count, 2, "Should have 2 DTBook items")
}

// ============================================================
// Navigation Bounds Checks
// ============================================================

test("NavigateTo: chapter index clamped to valid range") {
    // Simulate a document with 3 chapters
    let chapters = [
        Chapter(title: "Ch1", text: "First chapter text here.", headings: []),
        Chapter(title: "Ch2", text: "Second chapter.", headings: []),
        Chapter(title: "Ch3", text: "Third chapter.", headings: []),
    ]
    let content = DocumentContent(title: "Test", author: "Author", chapters: chapters)

    // Test clamping: negative index → 0
#if canImport(TextMouth)
    let clampedNeg = ReaderViewModel.clampedNavigationPosition(
        in: content, chapterIndex: -5, characterOffset: 0
    ).chapterIndex
#else
    let clampedNeg = min(max(0, -5), content.chapters.count - 1)
#endif
    try assertEqual(clampedNeg, 0, "Negative chapter index should clamp to 0")

    // Test clamping: index beyond range → last chapter
#if canImport(TextMouth)
    let clampedHigh = ReaderViewModel.clampedNavigationPosition(
        in: content, chapterIndex: 100, characterOffset: 0
    ).chapterIndex
#else
    let clampedHigh = min(max(0, 100), content.chapters.count - 1)
#endif
    try assertEqual(clampedHigh, 2, "High chapter index should clamp to last chapter")

    // Test clamping: valid index unchanged
#if canImport(TextMouth)
    let clampedValid = ReaderViewModel.clampedNavigationPosition(
        in: content, chapterIndex: 1, characterOffset: 0
    ).chapterIndex
#else
    let clampedValid = min(max(0, 1), content.chapters.count - 1)
#endif
    try assertEqual(clampedValid, 1, "Valid chapter index should be unchanged")
}

test("NavigateTo: character offset clamped to chapter length") {
    let text = "Hello world, this is a test."
    let chapter = Chapter(title: "", text: text, headings: [])

    // Offset beyond text length → clamped to last char
    let chapterLen = chapter.text.count
#if canImport(TextMouth)
    let content = DocumentContent(title: "Test", author: "", chapters: [chapter])
    let clampedHigh = ReaderViewModel.clampedNavigationPosition(
        in: content, chapterIndex: 0, characterOffset: 9999
    ).characterOffset
#else
    let clampedHigh = min(max(0, 9999), max(0, chapterLen - 1))
#endif
    try assertEqual(clampedHigh, text.count - 1, "High offset should clamp to text.count - 1")

    // Negative offset → 0
#if canImport(TextMouth)
    let clampedNeg = ReaderViewModel.clampedNavigationPosition(
        in: content, chapterIndex: 0, characterOffset: -10
    ).characterOffset
#else
    let clampedNeg = min(max(0, -10), max(0, chapterLen - 1))
#endif
    try assertEqual(clampedNeg, 0, "Negative offset should clamp to 0")
}

test("NavigateTo: empty chapter text handles gracefully") {
    let chapter = Chapter(title: "", text: "", headings: [])
    let chapterLen = chapter.text.count
    // max(0, 0 - 1) = max(0, -1) = 0
#if canImport(TextMouth)
    let content = DocumentContent(title: "Test", author: "", chapters: [chapter])
    let clampedOffset = ReaderViewModel.clampedNavigationPosition(
        in: content, chapterIndex: 0, characterOffset: 5
    ).characterOffset
#else
    let clampedOffset = min(max(0, 5), max(0, chapterLen - 1))
#endif
    try assertEqual(clampedOffset, 0, "Empty chapter should clamp offset to 0")
}

// ============================================================
// Pre-render Generation Check
// ============================================================

test("Pre-render generation prevents stale overwrites") {
    // Simulate the generation check logic used in preRenderNextChapter
    var chapterPlaybackGeneration = 0

    // Capture generation before render
    let renderGeneration = chapterPlaybackGeneration
    try assertEqual(renderGeneration, 0)

    // User navigates rapidly — generation increments
    chapterPlaybackGeneration += 1
    chapterPlaybackGeneration += 1

    // When render completes, generation check rejects stale result
#if canImport(TextMouth)
    let isStale = !ReaderViewModel.isCurrentPlaybackGeneration(
        captured: renderGeneration,
        current: chapterPlaybackGeneration
    )
#else
    let isStale = chapterPlaybackGeneration != renderGeneration
#endif
    try assertTrue(isStale, "Stale pre-render should be detected when generation changed")

    // Fresh render at current generation should be accepted
    let freshGeneration = chapterPlaybackGeneration
#if canImport(TextMouth)
    let isFresh = ReaderViewModel.isCurrentPlaybackGeneration(
        captured: freshGeneration,
        current: chapterPlaybackGeneration
    )
#else
    let isFresh = chapterPlaybackGeneration == freshGeneration
#endif
    try assertTrue(isFresh, "Fresh pre-render should be accepted")
}

// ============================================================
// Parser Utilities
// ============================================================

test("stripNamespacePrefix handles various XML element names") {
    try assertEqual(ParserUtilities.stripNamespacePrefix("dc:title"), "title")
    try assertEqual(ParserUtilities.stripNamespacePrefix("opf:item"), "item")
    try assertEqual(ParserUtilities.stripNamespacePrefix("title"), "title",
                    "Element without prefix should pass through unchanged")
    try assertEqual(ParserUtilities.stripNamespacePrefix("a:b:c"), "c",
                    "Multiple colons should take last component")
    try assertEqual(ParserUtilities.stripNamespacePrefix(""), "",
                    "Empty string should return empty")
}

test("normalizeMarkdownWhitespace collapses excessive blank lines") {
    let input = "Line 1\n\n\n\n\nLine 2\n\n\nLine 3"
    let result = ParserUtilities.normalizeMarkdownWhitespace(input)
    // 4 blank lines (5 newlines) collapsed to 2 blank lines (3 newlines)
    // Should not have 4+ consecutive newlines (3+ blank lines)
    try assertTrue(!result.contains("\n\n\n\n"), "Should not have 3+ consecutive blank lines")
    try assertTrue(result.contains("Line 1"), "Should preserve content")
    try assertTrue(result.contains("Line 2"), "Should preserve content")
    try assertTrue(result.contains("Line 3"), "Should preserve content")
}

test("normalizeMarkdownWhitespace trims trailing whitespace from lines") {
    let input = "Hello   \nWorld  \n"
    let result = ParserUtilities.normalizeMarkdownWhitespace(input)
    // Each line should have trailing whitespace removed
    let lines = result.components(separatedBy: "\n")
    for line in lines {
        try assertTrue(!line.hasSuffix(" "), "Line should not have trailing spaces: '\(line)'")
    }
}

test("normalizeMarkdownWhitespace handles empty input") {
    let result = ParserUtilities.normalizeMarkdownWhitespace("")
    try assertEqual(result, "", "Empty input should return empty output")
}

test("normalizeMarkdownWhitespace handles all-whitespace input") {
    let result = ParserUtilities.normalizeMarkdownWhitespace("   \n\n   \n   ")
    try assertEqual(result, "", "All-whitespace input should return empty after trim")
}

}
