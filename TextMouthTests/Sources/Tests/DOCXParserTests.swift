import Foundation
import ZIPFoundation

func runDOCXParserTests() {
print("\n--- DOCX Parser Tests (test_book.docx) ---")

test("DOCX file exists") {
    let url = try requireFile("test_book.docx")
    try assertTrue(FileManager.default.fileExists(atPath: url.path))
}

test("DOCX opens as ZIP archive") {
    let url = try requireFile("test_book.docx")
    let archive = try Archive(url: url, accessMode: .read)
    var count = 0
    for _ in archive { count += 1 }
    try assertGreater(count, 0, "Should open as ZIP with entries")
}

test("DOCX has word/document.xml") {
    let url = try requireFile("test_book.docx")
    let archive = try Archive(url: url, accessMode: .read)
    try assertTrue(archive["word/document.xml"] != nil, "Should contain word/document.xml")
}

test("DOCX has word/styles.xml") {
    let url = try requireFile("test_book.docx")
    let archive = try Archive(url: url, accessMode: .read)
    try assertTrue(archive["word/styles.xml"] != nil, "Should contain word/styles.xml")
}

test("DOCX has docProps/core.xml for metadata") {
    let url = try requireFile("test_book.docx")
    let archive = try Archive(url: url, accessMode: .read)
    try assertTrue(archive["docProps/core.xml"] != nil, "Should contain docProps/core.xml")
}

test("DOCX metadata extracts title") {
    let url = try requireFile("test_book.docx")
    let metadata = try parseDOCXMetadata(from: url)
    try assertEqual(metadata.title, "The Lighthouse Operator's Handbook")
}

test("DOCX metadata extracts author") {
    let url = try requireFile("test_book.docx")
    let metadata = try parseDOCXMetadata(from: url)
    try assertEqual(metadata.author, "Harriet Pemberton")
}

test("DOCX styles parser identifies heading levels") {
    let url = try requireFile("test_book.docx")
    let styles = try parseDOCXStyles(from: url)
    try assertTrue(styles.headingLevels["Heading1"] == 1, "Heading1 should be level 1")
    try assertTrue(styles.headingLevels["Heading2"] == 2, "Heading2 should be level 2")
    try assertTrue(styles.headingLevels["Heading3"] == 3, "Heading3 should be level 3")
}

test("DOCX styles parser identifies Title as heading") {
    let url = try requireFile("test_book.docx")
    let styles = try parseDOCXStyles(from: url)
    try assertTrue(styles.headingLevels["Title"] != nil, "Title should be recognized as a heading")
    try assertEqual(styles.headingLevels["Title"]!, 1, "Title should be heading level 1")
}

test("DOCX styles parser identifies list styles") {
    let url = try requireFile("test_book.docx")
    let styles = try parseDOCXStyles(from: url)
    try assertTrue(styles.bulletListStyles.contains("ListBullet"), "Should detect ListBullet style")
    try assertTrue(styles.numberedListStyles.contains("ListNumber"), "Should detect ListNumber style")
}

test("DOCX to Markdown conversion produces output") {
    let url = try requireFile("test_book.docx")
    let markdown = try parseDOCXToMarkdown(from: url)
    try assertTrue(!markdown.isEmpty, "Markdown should not be empty")
    try assertGreater(markdown.count, 100, "Markdown should have substantial content")
}

test("DOCX Markdown contains headings") {
    let url = try requireFile("test_book.docx")
    let markdown = try parseDOCXToMarkdown(from: url)
    try assertTrue(markdown.contains("# "), "Should contain heading markers")
    try assertTrue(markdown.contains("Chapter 1: First Principles"), "Should contain chapter 1 heading")
    try assertTrue(markdown.contains("Chapter 2: Weather and Observation"), "Should contain chapter 2 heading")
}

test("DOCX Markdown contains bold text") {
    let url = try requireFile("test_book.docx")
    let markdown = try parseDOCXToMarkdown(from: url)
    try assertTrue(markdown.contains("**The first rule**"), "Should contain bold text")
}

test("DOCX Markdown contains italic text") {
    let url = try requireFile("test_book.docx")
    let markdown = try parseDOCXToMarkdown(from: url)
    try assertTrue(markdown.contains("*Never*"), "Should contain italic text")
}

test("DOCX Markdown contains bold-italic text") {
    let url = try requireFile("test_book.docx")
    let markdown = try parseDOCXToMarkdown(from: url)
    try assertTrue(markdown.contains("***Critical observation***"), "Should contain bold-italic text")
}

test("DOCX Markdown contains strikethrough text") {
    let url = try requireFile("test_book.docx")
    let markdown = try parseDOCXToMarkdown(from: url)
    try assertTrue(markdown.contains("~~"), "Should contain strikethrough markers")
}

test("DOCX Markdown contains bullet list items") {
    let url = try requireFile("test_book.docx")
    let markdown = try parseDOCXToMarkdown(from: url)
    try assertTrue(markdown.contains("- Lens cleaning cloth"), "Should contain bullet list items")
    try assertTrue(markdown.contains("- Signal flags"), "Should contain signal flags bullet")
}

test("DOCX Markdown contains numbered list items") {
    let url = try requireFile("test_book.docx")
    let markdown = try parseDOCXToMarkdown(from: url)
    // Check for numbered items (1., 2., etc.)
    try assertTrue(markdown.contains("1. Sound the fog horn"), "Should contain first numbered item")
    try assertTrue(markdown.contains("2. Light the backup lamp"), "Should contain second numbered item")
}

test("DOCX Markdown contains table") {
    let url = try requireFile("test_book.docx")
    let markdown = try parseDOCXToMarkdown(from: url)
    try assertTrue(markdown.contains("|"), "Should contain table pipe separators")
    try assertTrue(markdown.contains("---"), "Should contain table header separator")
    try assertTrue(markdown.contains("Reading (hPa)"), "Should contain table header text")
}

test("DOCX Markdown contains paragraph text") {
    let url = try requireFile("test_book.docx")
    let markdown = try parseDOCXToMarkdown(from: url)
    try assertTrue(markdown.contains("Every coastal watchtower"), "Should contain first paragraph text")
    try assertTrue(markdown.contains("This handbook serves as a foundation"), "Should contain final paragraph")
}

test("DOCX Markdown preserves heading hierarchy") {
    let url = try requireFile("test_book.docx")
    let markdown = try parseDOCXToMarkdown(from: url)
    // Title should be h1, chapters should be h1, subsections should be h2
    let lines = markdown.components(separatedBy: "\n")
    var foundH1 = false
    var foundH2 = false
    var foundH3 = false
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("# ") && !trimmed.hasPrefix("## ") { foundH1 = true }
        if trimmed.hasPrefix("## ") && !trimmed.hasPrefix("### ") { foundH2 = true }
        if trimmed.hasPrefix("### ") { foundH3 = true }
    }
    try assertTrue(foundH1, "Should have h1 headings")
    try assertTrue(foundH2, "Should have h2 headings")
    try assertTrue(foundH3, "Should have h3 headings (Barometer Readings Reference)")
}

test("DOCX produces valid DocumentContent") {
    let url = try requireFile("test_book.docx")
    let markdown = try parseDOCXToMarkdown(from: url)
    let content = try parseMarkdown(markdown: markdown, title: "Test Book")
    try assertGreater(content.chapters.count, 0, "Should have at least one chapter")
    try assertGreater(content.chapters[0].headings.count, 0, "Should have headings")
    try assertGreater(content.chapters[0].text.count, 100, "Should have substantial text")
}

test("Alice DOCX file converts to Markdown") {
    let url = try requireFile("alice.docx")
    let markdown = try parseDOCXToMarkdown(from: url)
    try assertGreater(markdown.count, 1000, "Alice should produce substantial Markdown")
    // Alice has chapter headings — verify at least some are detected
    try assertTrue(
        markdown.contains("CHAPTER") || markdown.contains("chapter") || markdown.contains("#"),
        "Should contain chapter headings or heading markers"
    )
}

test("Alice DOCX produces DocumentContent with text") {
    let url = try requireFile("alice.docx")
    let markdown = try parseDOCXToMarkdown(from: url)
    let content = try parseMarkdown(markdown: markdown, title: "Alice")
    try assertGreater(content.chapters[0].text.count, 1000, "Should have substantial text")
}

}
