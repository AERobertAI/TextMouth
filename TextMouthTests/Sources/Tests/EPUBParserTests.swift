import Foundation
import SwiftSoup
import ZIPFoundation

#if canImport(TextMouth)
@testable import TextMouth

private func extractStringFromArchive(_ archive: Archive, path: String) throws -> String {
    try EPUBParser.extractString(archive: archive, path: path)
}

private func parseContainerForOPFPath(_ xml: String) throws -> String {
    try EPUBParser.parseContainerForOPFPath(xml)
}

private func parseOPF(_ xml: String) throws -> EPUBParser.OPFData {
    try EPUBParser.parseOPF(xml)
}

private func parseEPUB(url: URL) throws -> DocumentContent {
    try EPUBParser.parse(url: url)
}

private func parseChapterHTML(_ html: String) throws -> Chapter {
    try EPUBParser.parseChapterHTML(html)
}

private func parseHTML(html: String, title: String) throws -> DocumentContent {
    try HTMLParser.parse(html: html, title: title)
}
#endif

@MainActor
func runEPUBParserTests() {
print("\n--- EPUB Parser Tests (Alice in Wonderland) ---")

test("EPUB file exists") {
    let url = try requireFile("alice.epub")
    try assertTrue(FileManager.default.fileExists(atPath: url.path))
}

test("EPUB opens as ZIP archive") {
    let url = try requireFile("alice.epub")
    let archive = try Archive(url: url, accessMode: .read)
    var count = 0
    for _ in archive { count += 1 }
    try assertGreater(count, 0, "Should open as ZIP with entries")
}

test("EPUB has container.xml") {
    let url = try requireFile("alice.epub")
    let archive = try Archive(url: url, accessMode: .read)
    let xml = try extractStringFromArchive(archive, path: "META-INF/container.xml")
    try assertTrue(xml.contains("rootfile"), "Should contain rootfile element")
}

test("EPUB container.xml points to OPF") {
    let url = try requireFile("alice.epub")
    let archive = try Archive(url: url, accessMode: .read)
    let xml = try extractStringFromArchive(archive, path: "META-INF/container.xml")
    let opfPath = try parseContainerForOPFPath(xml)
    try assertTrue(!opfPath.isEmpty, "OPF path should not be empty")
    print("    OPF path: \(opfPath)")
}

test("EPUB OPF parses with title and author") {
    let url = try requireFile("alice.epub")
    let archive = try Archive(url: url, accessMode: .read)
    let containerXML = try extractStringFromArchive(archive, path: "META-INF/container.xml")
    let opfPath = try parseContainerForOPFPath(containerXML)
    let opfXML = try extractStringFromArchive(archive, path: opfPath)
    let opf = try parseOPF(opfXML)
    try assertTrue(!opf.title.isEmpty, "Title should not be empty")
    try assertTrue(!opf.author.isEmpty, "Author should not be empty")
    try assertGreater(opf.manifest.count, 0, "Manifest should have items")
    try assertGreater(opf.spineItemRefs.count, 0, "Spine should have items")
    print("    Title: \(opf.title)")
    print("    Author: \(opf.author)")
    print("    Manifest items: \(opf.manifest.count)")
    print("    Spine items: \(opf.spineItemRefs.count)")
}

test("EPUB full parse produces chapters with text") {
    let url = try requireFile("alice.epub")
    let content = try parseEPUB(url: url)
    try assertTrue(!content.title.isEmpty, "Title should not be empty")
    try assertGreater(content.chapters.count, 0, "Should have chapters")
    let totalText = content.chapters.map { $0.text.count }.reduce(0, +)
    try assertGreater(totalText, 1000, "Should have substantial text")
    print("    Title: \(content.title)")
    print("    Author: \(content.author)")
    print("    Chapters: \(content.chapters.count)")
    print("    Total characters: \(totalText)")
    // Print first 3 chapter titles
    for (i, ch) in content.chapters.prefix(5).enumerated() {
        print("    Chapter \(i+1): \"\(ch.title)\" (\(ch.text.count) chars, \(ch.headings.count) headings)")
    }
}

test("EPUB heading extraction finds headings") {
    let url = try requireFile("alice.epub")
    let content = try parseEPUB(url: url)
    let allHeadings = content.allHeadings
    try assertGreater(allHeadings.count, 0, "Should find headings")
    print("    Total headings found: \(allHeadings.count)")
    for h in allHeadings.prefix(8) {
        print("    H\(h.level): \"\(h.text)\" (ch:\(h.chapterIndex), offset:\(h.characterOffset))")
    }
}

test("EPUB chapter text contains expected content") {
    let url = try requireFile("alice.epub")
    let content = try parseEPUB(url: url)
    let allText = content.chapters.map { $0.text }.joined(separator: " ").lowercased()
    // Alice in Wonderland should contain these words
    try assertTrue(allText.contains("alice"), "Should contain 'alice'")
    try assertTrue(allText.contains("rabbit"), "Should contain 'rabbit'")
    try assertTrue(allText.contains("wonderland") || allText.contains("wonder"), "Should contain 'wonderland' or 'wonder'")
}

// ---- Heading Duplication Tests (through parser functions) ----
print("\n--- Heading Duplication Tests ---")

test("parseChapterHTML: nav with duplicate headings strips nav") {
    // EPUB3 nav TOC duplicates heading text via link labels.
    // parseChapterHTML should strip the nav since headings exist
    // outside it, so TTS reads each heading only once.
    let html = """
    <html>
    <body>
    <nav>
    <ol>
    <li><a href="#ch1">Chapter 1: Introduction</a></li>
    <li><a href="#ch2">Chapter 2: Methods</a></li>
    </ol>
    </nav>
    <h1 id="ch1">Chapter 1: Introduction</h1>
    <p>Content here.</p>
    </body>
    </html>
    """
    let chapter = try parseChapterHTML(html)
    let count = chapter.text.components(separatedBy: "Chapter 1: Introduction").count - 1
    try assertEqual(count, 1,
        "Heading should appear once — nav duplicate removed")
    try assertEqual(chapter.title, "Chapter 1: Introduction",
        "Chapter title should come from the h1")
    try assertEqual(chapter.headings.count, 1,
        "Should have exactly one heading (the h1)")
}

test("parseChapterHTML: heading only inside nav is preserved") {
    // If the only heading is inside <nav>, stripping it would lose
    // the heading entirely. Parser must keep it.
    let html = """
    <html>
    <body>
    <nav>
    <h1>Chapter 1: Introduction</h1>
    <ol><li><a href="#s1">Section 1</a></li></ol>
    </nav>
    <p>Content without any heading element outside nav.</p>
    </body>
    </html>
    """
    let chapter = try parseChapterHTML(html)
    try assertTrue(chapter.text.contains("Chapter 1: Introduction"),
        "Heading from nav must be preserved when it's the only source")
    try assertEqual(chapter.title, "Chapter 1: Introduction",
        "Chapter title should come from the nav h1")
    try assertTrue(chapter.headings.count >= 1,
        "Nav heading should be in the headings list")
}

test("parseChapterHTML: nested nav stripped when content headings exist") {
    let html = """
    <html>
    <body>
    <section>
    <nav epub:type="toc">
    <h2>Contents</h2>
    <ol>
    <li><a href="#s1">Section 1</a></li>
    <li><a href="#s2">Section 2</a></li>
    </ol>
    </nav>
    <h1>Chapter Title</h1>
    <h2 id="s1">Section 1</h2>
    <p>First section content.</p>
    <h2 id="s2">Section 2</h2>
    <p>Second section content.</p>
    </section>
    </body>
    </html>
    """
    let chapter = try parseChapterHTML(html)
    let s1Count = chapter.text.components(separatedBy: "Section 1").count - 1
    try assertEqual(s1Count, 1,
        "Section heading should appear once — nav duplicate removed")
    try assertTrue(!chapter.text.contains("Contents"),
        "Nav-only heading 'Contents' should be gone (it was inside nav)")
    try assertTrue(chapter.text.contains("Chapter Title"),
        "Content heading preserved")
}

test("parseChapterHTML: no nav — headings preserved normally") {
    let html = """
    <html>
    <body>
    <h1>Chapter 1</h1>
    <p>Content here.</p>
    <h2>Section 1.1</h2>
    <p>More content.</p>
    </body>
    </html>
    """
    let chapter = try parseChapterHTML(html)
    try assertTrue(chapter.text.contains("Chapter 1"), "H1 preserved")
    try assertTrue(chapter.text.contains("Section 1.1"), "H2 preserved")
    try assertTrue(chapter.text.contains("Content here"), "Body preserved")
    try assertEqual(chapter.headings.count, 2, "Both headings found")
}

test("parseChapterHTML: nav with link-only duplicates stripped") {
    // Most common EPUB3 pattern: nav has <a> links (not h1-h6),
    // body has actual heading elements. Nav should be stripped.
    let html = """
    <html>
    <body>
    <nav epub:type="toc">
    <ol>
    <li><a href="#ch1">Chapter 1</a></li>
    <li><a href="#ch2">Chapter 2</a></li>
    </ol>
    </nav>
    <h1 id="ch1">Chapter 1</h1>
    <p>First chapter content.</p>
    </body>
    </html>
    """
    let chapter = try parseChapterHTML(html)
    let count = chapter.text.components(separatedBy: "Chapter 1").count - 1
    try assertEqual(count, 1, "Nav link text stripped, heading once")
    try assertTrue(!chapter.text.contains("Chapter 2"),
        "Chapter 2 link text from nav should be gone")
}

test("parseHTML: nav with duplicate headings strips nav") {
    // Same fix applies to HTMLParser — test through parseHTML().
    let html = """
    <html>
    <body>
    <nav>
    <ol><li><a href="#s1">Introduction</a></li></ol>
    </nav>
    <h1 id="s1">Introduction</h1>
    <p>Welcome to the guide.</p>
    </body>
    </html>
    """
    let content = try parseHTML(html: html, title: "Test")
    let text = content.chapters.first!.text
    let count = text.components(separatedBy: "Introduction").count - 1
    try assertEqual(count, 1,
        "parseHTML should also strip nav when headings exist outside it")
}

test("parseHTML: heading only in nav is preserved") {
    let html = """
    <html>
    <body>
    <nav>
    <h1>Guide Overview</h1>
    <ol><li><a href="#s1">Part 1</a></li></ol>
    </nav>
    <p>This guide covers important topics.</p>
    </body>
    </html>
    """
    let content = try parseHTML(html: html, title: "Test")
    let text = content.chapters.first!.text
    try assertTrue(text.contains("Guide Overview"),
        "parseHTML must preserve heading when it only exists in nav")
}

test("EPUB alice.epub: no heading duplication in chapter text") {
    let url = try requireFile("alice.epub")
    let content = try parseEPUB(url: url)
    var duplicateCount = 0
    for (i, chapter) in content.chapters.enumerated() {
        for heading in chapter.headings {
            let text = chapter.text
            let occurrences = text.components(separatedBy: heading.text).count - 1
            if occurrences > 1 {
                duplicateCount += 1
                print("    DUPLICATE in ch\(i): '\(heading.text)' appears \(occurrences)x")
            }
        }
    }
    print("    Chapters checked: \(content.chapters.count), duplicates: \(duplicateCount)")
}

} // end runEPUBParserTests
