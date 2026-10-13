import Foundation

@testable import TextMouth

private func parseHTML(html: String, title: String) throws -> DocumentContent {
    try HTMLParser.parse(html: html, title: title)
}

private func parseMarkdown(markdown: String, title: String) throws -> DocumentContent {
    try MarkdownDocParser.parse(markdown: markdown, title: title)
}

private func parsePlainText(text: String, title: String) -> DocumentContent {
    PlainTextParser.parse(text: text, title: title)
}

@MainActor
func runParserEdgeCaseTests() {
print("\n--- Parser Edge Cases ---")

test("HTML parser handles an empty heading element gracefully") {
    let content = try parseHTML(html: "<html><body><h1></h1></body></html>", title: "Empty Heading")
    try assertEqual(content.title, "Empty Heading")
    try assertEqual(content.chapters.count, 1)
}

test("HTML parser handles malformed heading levels") {
    let html = "<html><body><h7>Not a heading</h7><h0>Also not</h0><h3>Real heading</h3></body></html>"
    let content = try parseHTML(html: html, title: "Test")
    // h7 and h0 may parse oddly, but shouldn't crash
    try assertTrue(content.chapters.count > 0, "Should produce at least one chapter")
}

test("HTML parser handles empty document") {
    let html = "<html><body></body></html>"
    let content = try parseHTML(html: html, title: "Empty")
    try assertEqual(content.title, "Empty", "Should use fallback title")
    try assertEqual(content.chapters[0].headings.count, 0, "Should have no headings")
}

test("HTML parser handles whitespace-only document") {
    let html = "<html><body>   \n  \t  </body></html>"
    let content = try parseHTML(html: html, title: "Whitespace")
    try assertTrue(content.chapters.count > 0, "Should produce a chapter")
}

test("Markdown parser handles empty input") {
    let content = try parseMarkdown(markdown: "", title: "Empty")
    try assertEqual(content.title, "Empty", "Should use fallback title")
    try assertEqual(content.chapters[0].text.count, 0, "Should have empty text")
}

test("Markdown parser handles no headings") {
    let content = try parseMarkdown(markdown: "Just a paragraph of text.\n\nAnother paragraph.", title: "NoHeadings")
    try assertEqual(content.chapters[0].headings.count, 0, "Should have no headings")
    try assertTrue(content.chapters[0].text.contains("Just a paragraph"), "Should contain text")
}

test("Markdown parser handles duplicate heading text with searchStart tracking") {
    let md = """
    # Introduction

    Some text.

    # Middle

    More text.

    # Introduction

    Final text.
    """
    let content = try parseMarkdown(markdown: md, title: "Test")
    let headings = content.chapters[0].headings
    try assertEqual(headings.count, 3, "Should have 3 headings")

    // The two "Introduction" headings must have different offsets
    let introHeadings = headings.filter { $0.text == "Introduction" }
    try assertEqual(introHeadings.count, 2, "Should have 2 Introduction headings")
    try assertTrue(introHeadings[0].characterOffset < introHeadings[1].characterOffset,
                   "Second Introduction should have a larger offset than first")
    print("    Introduction offsets: \(introHeadings.map { $0.characterOffset })")
}

test("HTML parser handles duplicate heading text with searchStart tracking") {
    let html = """
    <html><body>
    <h2>Section</h2>
    <p>First section content</p>
    <h2>Section</h2>
    <p>Second section content</p>
    <h2>Section</h2>
    <p>Third section content</p>
    </body></html>
    """
    let content = try parseHTML(html: html, title: "Test")
    let headings = content.chapters[0].headings
    try assertEqual(headings.count, 3, "Should have 3 headings")
    // Each "Section" heading should have a different offset
    try assertTrue(headings[0].characterOffset < headings[1].characterOffset, "Second should be after first")
    try assertTrue(headings[1].characterOffset < headings[2].characterOffset, "Third should be after second")
    print("    Section offsets: \(headings.map { $0.characterOffset })")
}

test("PlainText parser handles empty input") {
    let content = parsePlainText(text: "", title: "Empty")
    try assertEqual(content.chapters[0].headings.count, 0, "Should have no headings")
    try assertEqual(content.chapters[0].text, "", "Should have empty text")
}

test("PlainText parser handles whitespace-only input") {
    let content = parsePlainText(text: "   \n  \n  \t  \n", title: "Whitespace")
    try assertEqual(content.chapters[0].headings.count, 0, "Should have no headings")
}

test("PlainText parser handles setext + all-caps mutual exclusion") {
    let text = "CHAPTER ONE\n===\n\nSome text."
    let content = parsePlainText(text: text, title: "Test")
    let headings = content.allHeadings
    // "CHAPTER ONE" is setext (h1 via ===), should NOT also be all-caps
    let chOne = headings.filter { $0.text == "CHAPTER ONE" }
    try assertEqual(chOne.count, 1, "CHAPTER ONE should appear exactly once (setext only)")
    try assertEqual(chOne[0].level, 1, "Should be level 1 from setext ===")
    print("    Headings: \(headings.map { "H\($0.level):\($0.text)" })")
}

test("PlainText parser handles Unicode in headings") {
    let text = "# Caf\u{00E9} Culture\n\nSome text.\n\n## \u{1F4DA} Book Review\n\nMore text."
    let content = parsePlainText(text: text, title: "Unicode")
    let headings = content.allHeadings
    try assertEqual(headings.count, 2, "Should detect 2 headings")
    try assertEqual(headings[0].text, "Caf\u{00E9} Culture")
    print("    Headings: \(headings.map { $0.text })")
}

test("PlainText parser handles mixed line endings") {
    // CRLF, a lone CR, and LF each end one line, so a wrapped paragraph
    // stays one paragraph and the text reads exactly as its LF copy does.
    let text = "# Heading One\r\n\r\nSome text\rwraps here\n\r\n# Heading Two\r\rMore text"
    let lfText = "# Heading One\n\nSome text\nwraps here\n\n# Heading Two\n\nMore text"
    let content = parsePlainText(text: text, title: "Mixed")
    let lfContent = parsePlainText(text: lfText, title: "Mixed")
    try assertEqual(content.allHeadings.map(\.text), ["Heading One", "Heading Two"])
    try assertEqual(content.chapters.first?.text, "Heading One\n\nSome text wraps here\n\nHeading Two\n\nMore text")
    try assertEqual(content.chapters.first?.text, lfContent.chapters.first?.text)
    try assertEqual(content.allHeadings, lfContent.allHeadings)
}

} // end runParserEdgeCaseTests
