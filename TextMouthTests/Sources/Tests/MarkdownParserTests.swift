import Foundation

func runMarkdownParserTests() {
print("\n--- Markdown Parser Tests (sample.md) ---")

test("Markdown file exists and loads") {
    let url = try requireFile("sample.md")
    let text = try String(contentsOf: url, encoding: .utf8)
    try assertGreater(text.count, 100, "Should have content")
}

test("Markdown parse extracts headings at correct levels") {
    let url = try requireFile("sample.md")
    let text = try String(contentsOf: url, encoding: .utf8)
    let content = try parseMarkdown(markdown: text, title: "Sample")
    let headings = content.allHeadings
    try assertGreater(headings.count, 3, "Should find multiple headings")

    // Verify heading levels
    let h1s = headings.filter { $0.level == 1 }
    let h2s = headings.filter { $0.level == 2 }
    let h3s = headings.filter { $0.level == 3 }
    try assertGreater(h1s.count, 0, "Should have H1 headings")
    try assertGreater(h2s.count, 0, "Should have H2 headings")
    try assertGreater(h3s.count, 0, "Should have H3 headings")

    print("    Headings found: \(headings.count) (H1:\(h1s.count), H2:\(h2s.count), H3:\(h3s.count))")
    for h in headings {
        print("    H\(h.level): \"\(h.text)\" (offset:\(h.characterOffset))")
    }
}

test("Markdown title extraction") {
    let url = try requireFile("sample.md")
    let text = try String(contentsOf: url, encoding: .utf8)
    let content = try parseMarkdown(markdown: text, title: "Fallback Title")
    try assertEqual(content.title, "The Art of Testing", "Should extract H1 as title")
    print("    Title: \(content.title)")
}

test("Markdown plain text extraction strips formatting") {
    let url = try requireFile("sample.md")
    let text = try String(contentsOf: url, encoding: .utf8)
    let content = try parseMarkdown(markdown: text, title: "Sample")
    let plain = content.chapters[0].text
    // Should not contain markdown syntax
    try assertTrue(!plain.contains("**"), "Should not contain bold markers")
    try assertTrue(!plain.contains("##"), "Should not contain heading markers")
    // Should contain the actual text
    try assertTrue(plain.contains("The Art of Testing"), "Should contain heading text")
    try assertTrue(plain.contains("Once upon a time"), "Should contain paragraph text")
    print("    Plain text length: \(plain.count) chars")
}

} // end runMarkdownParserTests
