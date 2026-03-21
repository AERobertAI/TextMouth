import Foundation

func runHTMLParserTests() {
print("\n--- HTML Parser Tests (Frankenstein) ---")

test("HTML file exists and loads") {
    let url = try requireFile("frankenstein.html")
    let html = try String(contentsOf: url, encoding: .utf8)
    try assertGreater(html.count, 1000, "HTML should be substantial")
    print("    File size: \(html.count) characters")
}

test("HTML parse produces content with title") {
    let url = try requireFile("frankenstein.html")
    let html = try String(contentsOf: url, encoding: .utf8)
    let content = try parseHTML(html: html, title: "Frankenstein")
    try assertTrue(!content.title.isEmpty, "Should have title")
    try assertGreater(content.chapters.count, 0, "Should have chapters")
    print("    Title: \(content.title)")
    print("    Text length: \(content.chapters[0].text.count) chars")
}

test("HTML heading extraction") {
    let url = try requireFile("frankenstein.html")
    let html = try String(contentsOf: url, encoding: .utf8)
    let content = try parseHTML(html: html, title: "Frankenstein")
    let headings = content.allHeadings
    try assertGreater(headings.count, 0, "Should find headings")
    print("    Headings found: \(headings.count)")
    for h in headings.prefix(10) {
        print("    H\(h.level): \"\(h.text)\" (offset:\(h.characterOffset))")
    }
}

test("HTML text contains expected Frankenstein content") {
    let url = try requireFile("frankenstein.html")
    let html = try String(contentsOf: url, encoding: .utf8)
    let content = try parseHTML(html: html, title: "Frankenstein")
    let text = content.chapters[0].text.lowercased()
    try assertTrue(text.contains("frankenstein") || text.contains("creature") || text.contains("monster"),
                   "Should contain Frankenstein-related words")
}

} // end runHTMLParserTests
