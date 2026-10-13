import CryptoKit
import Foundation
import ZIPFoundation

@testable import TextMouth

/// Production-backed adapters retaining the legacy scenario bodies and names.
private func parseDOCXMetadata(from url: URL) throws -> DOCXMetadata {
    guard let metadata = try DOCXParser.readMetadata(from: url) else {
        throw TestError.assertionFailed("Production DOCX parser returned no metadata")
    }
    return metadata
}

private func parseDOCXStyles(from url: URL) throws -> DOCXStyles {
    try DOCXParser.readStyles(from: url)
}

private func parseDOCXToMarkdown(from url: URL) throws -> String {
    try DOCXParser.extractMarkdown(from: url)
}

private func parseMarkdown(markdown: String, title: String) throws -> DocumentContent {
    try MarkdownDocParser.parse(markdown: markdown, title: title)
}

/// Convert the fixture `name` and require exactly the Markdown pinned for
/// it, compared by UTF-8 byte count and SHA-256 digest (lowercase hex), with
/// no damage reported: damage found only after the last word would leave the
/// Markdown unchanged but still write a false alarm to the debug log.
private func assertPinnedMarkdown(_ name: String, bytes: Int, sha256: String) throws {
    var damageReports: [DOCXParserError] = []
    let markdown = try DOCXParser.extractMarkdown(from: try requireFile(name)) { damageReports.append($0) }
    try assertTrue(damageReports.isEmpty, "\(name) was reported as damaged: \(damageReports)")
    let actualBytes = markdown.utf8.count
    let actualDigest = SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined()
    try assertTrue(
        actualBytes == bytes && actualDigest == sha256,
        "\(name) now converts to \(actualBytes) bytes with SHA-256 \(actualDigest); "
            + "pinned: \(bytes) bytes with SHA-256 \(sha256)"
    )
}

@MainActor
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
    // Text is written as Markdown literals, so the colon is escaped.
    try assertTrue(markdown.contains("# "), "Should contain heading markers")
    try assertTrue(markdown.contains("Chapter 1\\: First Principles"), "Should contain chapter 1 heading")
    try assertTrue(markdown.contains("Chapter 2\\: Weather and Observation"), "Should contain chapter 2 heading")
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
    try assertTrue(markdown.contains("Reading \\(hPa\\)"), "Should contain table header text, as Markdown literals")
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

// Every byte of each fixture's Markdown, pinned on September 30, 2026, before
// the DOCX parts were checked for damaged XML (TODO T04), and pinned again on
// October 3, 2026, when DOCX text began to be written as Markdown literals
// (TODO T05). An intact document must convert exactly as pinned: a change
// here changes every DOCX book's cached text, so it needs a cache format
// version bump.
test("DOCX fixture test_book.docx converts to its pinned Markdown") {
    try assertPinnedMarkdown(
        "test_book.docx",
        bytes: 3270,
        sha256: "03acb604568b522cefed0a7284e349bb1ff5278269a9a5593346e347ba59c5de"
    )
}

test("DOCX fixture alice.docx converts to its pinned Markdown") {
    try assertPinnedMarkdown(
        "alice.docx",
        bytes: 175404,
        sha256: "3cd03f3458bf2cb10ef868498f9c16eb0eb132d8b0373a01ac1351244e88b5a0"
    )
}

}
