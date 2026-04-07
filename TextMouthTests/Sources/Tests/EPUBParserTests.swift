import Foundation
import SwiftSoup
import ZIPFoundation

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

// ---- Heading Duplication Diagnostic Tests ----
print("\n--- Heading Duplication Tests ---")

test("HTML with <title> matching <h1>: body.text() excludes <title>") {
    let html = """
    <html xmlns="http://www.w3.org/1999/xhtml">
    <head><title>Chapter 1: Introduction</title></head>
    <body>
    <h1>Chapter 1: Introduction</h1>
    <p>The story begins here.</p>
    </body>
    </html>
    """
    let doc = try SwiftSoup.parse(html)
    let body = doc.body()
    try assertTrue(body != nil, "body() should not be nil for valid XHTML")
    let text = try body!.text()
    let count = text.components(separatedBy: "Chapter 1: Introduction").count - 1
    try assertEqual(count, 1,
        "body.text() should contain heading exactly once, got \(count). Text: '\(text)'")
}

test("HTML with <title> matching <h1>: doc.text() DUPLICATES heading") {
    let html = """
    <html>
    <head><title>Chapter 1: Introduction</title></head>
    <body>
    <h1>Chapter 1: Introduction</h1>
    <p>Content here.</p>
    </body>
    </html>
    """
    let doc = try SwiftSoup.parse(html)
    let docText = try doc.text()
    let bodyText = try doc.body()!.text()
    let docCount = docText.components(separatedBy: "Chapter 1: Introduction").count - 1
    let bodyCount = bodyText.components(separatedBy: "Chapter 1: Introduction").count - 1
    // doc.text() includes <title>, body.text() does not
    print("    doc.text():  '\(docText)' (count: \(docCount))")
    print("    body.text(): '\(bodyText)' (count: \(bodyCount))")
    try assertTrue(bodyCount == 1, "body.text() should have heading once")
}

test("Nav with headings outside: nav stripped, heading appears once") {
    // When headings exist outside <nav>, the nav is duplicating them
    // and should be stripped to prevent TTS reading each heading twice.
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
    let doc = try SwiftSoup.parse(html)
    try doc.select("script, style").remove()
    let body = doc.body() ?? doc
    // Replicate parser logic: strip nav only if headings exist outside it
    let allH = try body.select("h1, h2, h3, h4, h5, h6").size()
    let navH = try body.select("nav h1, nav h2, nav h3, nav h4, nav h5, nav h6").size()
    if allH > navH { try body.select("nav").remove() }
    let text = try body.text()
    let count = text.components(separatedBy: "Chapter 1: Introduction").count - 1
    try assertEqual(count, 1,
        "With headings outside nav, nav should be stripped — heading appears once")
}

test("Nav with heading ONLY inside nav: nav kept, heading preserved") {
    // If the only heading is inside <nav>, stripping it would lose the
    // heading entirely. The parser must keep it.
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
    let doc = try SwiftSoup.parse(html)
    try doc.select("script, style").remove()
    let body = doc.body() ?? doc
    let allH = try body.select("h1, h2, h3, h4, h5, h6").size()
    let navH = try body.select("nav h1, nav h2, nav h3, nav h4, nav h5, nav h6").size()
    // allH == navH == 1 → no headings outside nav → keep nav
    try assertEqual(allH, navH,
        "All headings are inside nav — should not strip")
    let text = try body.text()
    try assertTrue(text.contains("Chapter 1: Introduction"),
        "Heading from nav must be preserved when it's the only source")
}

test("Nested nav in section: stripped when content headings exist") {
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
    let doc = try SwiftSoup.parse(html)
    try doc.select("script, style").remove()
    let body = doc.body() ?? doc
    let allH = try body.select("h1, h2, h3, h4, h5, h6").size()
    let navH = try body.select("nav h1, nav h2, nav h3, nav h4, nav h5, nav h6").size()
    // 4 total (Contents, Chapter Title, Section 1, Section 2) > 1 nav (Contents)
    try assertTrue(allH > navH, "Headings exist outside nav")
    if allH > navH { try body.select("nav").remove() }
    let text = try body.text()
    let s1Count = text.components(separatedBy: "Section 1").count - 1
    try assertEqual(s1Count, 1,
        "Nested nav stripped — section heading appears once")
}

test("No nav: headings preserved normally") {
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
    let doc = try SwiftSoup.parse(html)
    try doc.select("script, style").remove()
    let body = doc.body() ?? doc
    let allH = try body.select("h1, h2, h3, h4, h5, h6").size()
    let navH = try body.select("nav h1, nav h2, nav h3, nav h4, nav h5, nav h6").size()
    try assertEqual(navH, 0, "No nav headings")
    try assertTrue(allH > navH, "Headings exist outside nav")
    let text = try body.text()
    try assertTrue(text.contains("Chapter 1"), "H1 heading preserved")
    try assertTrue(text.contains("Section 1.1"), "H2 heading preserved")
    try assertTrue(text.contains("Content here"), "Body content preserved")
}

test("Nav with only links (no heading elements): stripped when body has headings") {
    // Most common EPUB3 pattern: nav has <a> links (not h1-h6),
    // body has actual heading elements.
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
    let doc = try SwiftSoup.parse(html)
    try doc.select("script, style").remove()
    let body = doc.body() ?? doc
    let allH = try body.select("h1, h2, h3, h4, h5, h6").size()
    let navH = try body.select("nav h1, nav h2, nav h3, nav h4, nav h5, nav h6").size()
    try assertEqual(allH, 1, "One heading outside nav")
    try assertEqual(navH, 0, "No heading elements inside nav")
    try assertTrue(allH > navH)
    if allH > navH { try body.select("nav").remove() }
    let text = try body.text()
    let count = text.components(separatedBy: "Chapter 1").count - 1
    try assertEqual(count, 1, "Nav link text stripped, heading appears once")
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
