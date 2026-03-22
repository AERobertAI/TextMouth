import Foundation
import ZIPFoundation

func runDAISYParserTests() {
print("\n--- DAISY 3 Parser Tests (Hyperion) ---")

test("DAISY 3 ZIP file exists (hyperion)") {
    let url = try requireFile("hyperion_daisy.zip")
    try assertTrue(FileManager.default.fileExists(atPath: url.path))
}

test("DAISY 3 ZIP opens as archive") {
    let url = try requireFile("hyperion_daisy.zip")
    let archive = try Archive(url: url, accessMode: .read)
    var count = 0
    for _ in archive { count += 1 }
    try assertGreater(count, 0, "Should have entries")
}

test("DAISY 3 ZIP contains OPF file") {
    let url = try requireFile("hyperion_daisy.zip")
    let archive = try Archive(url: url, accessMode: .read)
    let hasOPF = archive.contains { $0.path.lowercased().hasSuffix(".opf") }
    try assertTrue(hasOPF, "Should contain an OPF file")
}

test("DAISY 3 ZIP contains DTBook XML") {
    let url = try requireFile("hyperion_daisy.zip")
    let archive = try Archive(url: url, accessMode: .read)
    let hasXML = archive.contains { entry in
        entry.path.lowercased().hasSuffix(".xml") && !entry.path.lowercased().hasSuffix(".xsl")
    }
    try assertTrue(hasXML, "Should contain a DTBook XML file")
}

test("DAISY 3 ZIP contains NCX") {
    let url = try requireFile("hyperion_daisy.zip")
    let archive = try Archive(url: url, accessMode: .read)
    let hasNCX = archive.contains { $0.path.lowercased().hasSuffix(".ncx") }
    try assertTrue(hasNCX, "Should contain an NCX file")
}

test("DAISY 3 is detected as DAISY") {
    let url = try requireFile("hyperion_daisy.zip")
    let isDAISY = isDAISYZipFile(url: url)
    try assertTrue(isDAISY, "Should be detected as a DAISY ZIP")
}

test("DAISY 3 OPF metadata extracts title") {
    let url = try requireFile("hyperion_daisy.zip")
    let metadata = try parseDAISYMetadata(from: url)
    try assertTrue(!metadata.title.isEmpty, "Title should not be empty")
    try assertTrue(metadata.title.contains("Hyperion"), "Title should contain Hyperion")
}

test("DAISY 3 DTBook converts to Markdown") {
    let url = try requireFile("hyperion_daisy.zip")
    let markdown = try parseDAISYToMarkdown(from: url)
    try assertTrue(!markdown.isEmpty, "Markdown should not be empty")
    try assertGreater(markdown.count, 1000, "Should have substantial content")
}

test("DAISY 3 Markdown contains headings") {
    let url = try requireFile("hyperion_daisy.zip")
    let markdown = try parseDAISYToMarkdown(from: url)
    try assertTrue(markdown.contains("#"), "Should contain heading markers")
}

test("DAISY 3 Markdown contains paragraph text") {
    let url = try requireFile("hyperion_daisy.zip")
    let markdown = try parseDAISYToMarkdown(from: url)
    // Hyperion starts with "The Hegemony Consul" or similar content
    try assertGreater(markdown.count, 5000, "Should have substantial body text")
}

test("DAISY 3 produces valid DocumentContent") {
    let url = try requireFile("hyperion_daisy.zip")
    let markdown = try parseDAISYToMarkdown(from: url)
    let content = try parseMarkdown(markdown: markdown, title: "Hyperion")
    try assertGreater(content.chapters.count, 0, "Should have chapters")
    try assertGreater(content.chapters[0].text.count, 500, "Should have text content")
}

print("\n--- DAISY 3 Parser Tests (Lathe of Heaven) ---")

test("DAISY 3 with images ZIP exists") {
    let url = try requireFile("lathe_of_heaven_daisy.zip")
    try assertTrue(FileManager.default.fileExists(atPath: url.path))
}

test("DAISY 3 with images is detected as DAISY") {
    let url = try requireFile("lathe_of_heaven_daisy.zip")
    try assertTrue(isDAISYZipFile(url: url), "Should be detected as DAISY")
}

test("DAISY 3 with images converts to Markdown") {
    let url = try requireFile("lathe_of_heaven_daisy.zip")
    let markdown = try parseDAISYToMarkdown(from: url)
    try assertTrue(!markdown.isEmpty, "Markdown should not be empty")
    try assertGreater(markdown.count, 1000, "Should have substantial content")
}

test("DAISY 3 with images has headings") {
    let url = try requireFile("lathe_of_heaven_daisy.zip")
    let markdown = try parseDAISYToMarkdown(from: url)
    try assertTrue(markdown.contains("#"), "Should contain heading markers")
}

test("DAISY 3 with images metadata") {
    let url = try requireFile("lathe_of_heaven_daisy.zip")
    let metadata = try parseDAISYMetadata(from: url)
    try assertTrue(!metadata.title.isEmpty, "Title should not be empty")
}

test("DTBook emphasis converts to Markdown italic") {
    // Test with a minimal DTBook snippet
    let dtbook = """
    <?xml version="1.0" encoding="UTF-8"?>
    <dtbook xmlns="http://www.daisy.org/z3986/2005/dtbook/" version="2005-3">
    <head><meta name="dc:Title" content="Test"/></head>
    <book><bodymatter><level1>
    <h1>Test Chapter</h1>
    <p>This has <em>emphasized</em> and <strong>strong</strong> text.</p>
    </level1></bodymatter></book></dtbook>
    """
    let markdown = convertDTBookSnippet(dtbook)
    try assertTrue(markdown.contains("*emphasized*"), "Should contain italic text")
    try assertTrue(markdown.contains("**strong**"), "Should contain bold text")
}

test("DTBook lists convert to Markdown lists") {
    let dtbook = """
    <?xml version="1.0" encoding="UTF-8"?>
    <dtbook xmlns="http://www.daisy.org/z3986/2005/dtbook/" version="2005-3">
    <head><meta name="dc:Title" content="Test"/></head>
    <book><bodymatter><level1>
    <h1>Lists</h1>
    <list type="ul">
    <li>First item</li>
    <li>Second item</li>
    </list>
    <list type="ol">
    <li>Numbered one</li>
    <li>Numbered two</li>
    </list>
    </level1></bodymatter></book></dtbook>
    """
    let markdown = convertDTBookSnippet(dtbook)
    try assertTrue(markdown.contains("- First item"), "Should have bullet list")
    try assertTrue(markdown.contains("- Second item"), "Should have second bullet")
    try assertTrue(markdown.contains("1. Numbered one"), "Should have numbered list")
    try assertTrue(markdown.contains("2. Numbered two"), "Should have second numbered item")
}

test("DTBook doctitle converts to h1") {
    let dtbook = """
    <?xml version="1.0" encoding="UTF-8"?>
    <dtbook xmlns="http://www.daisy.org/z3986/2005/dtbook/" version="2005-3">
    <head><meta name="dc:Title" content="Test"/></head>
    <book><frontmatter>
    <doctitle>My Great Book</doctitle>
    <docauthor>Test Author</docauthor>
    </frontmatter></book></dtbook>
    """
    let markdown = convertDTBookSnippet(dtbook)
    try assertTrue(markdown.contains("# My Great Book"), "doctitle should become h1")
    try assertTrue(markdown.contains("*Test Author*"), "docauthor should become italic")
}

print("\n--- DAISY 2.02 Parser Tests ---")

test("DAISY 2.02 ZIP file exists") {
    let url = try requireFile("daisy202_test.zip")
    try assertTrue(FileManager.default.fileExists(atPath: url.path))
}

test("DAISY 2.02 is detected as DAISY") {
    let url = try requireFile("daisy202_test.zip")
    try assertTrue(isDAISYZipFile(url: url), "Should be detected as DAISY 2.02")
}

test("DAISY 2.02 metadata extracts title") {
    let url = try requireFile("daisy202_test.zip")
    let metadata = try parseDAISY202MetadataFromZip(url: url)
    try assertEqual(metadata.title, "The Manual of Tide Prediction")
}

test("DAISY 2.02 metadata extracts author") {
    let url = try requireFile("daisy202_test.zip")
    let metadata = try parseDAISY202MetadataFromZip(url: url)
    try assertEqual(metadata.author, "Josephine Halford")
}

test("DAISY 2.02 converts to Markdown with content") {
    let url = try requireFile("daisy202_test.zip")
    let markdown = try parseDAISY202ToMarkdown(url: url)
    try assertTrue(!markdown.isEmpty, "Should produce Markdown output")
    try assertGreater(markdown.count, 50, "Should have substantial content")
}

test("DAISY 2.02 Markdown contains headings from NCC") {
    let url = try requireFile("daisy202_test.zip")
    let markdown = try parseDAISY202ToMarkdown(url: url)
    // Should have heading markers since NCC headings are extracted
    try assertTrue(
        markdown.contains("Gravitational") || markdown.contains("#"),
        "Should contain heading text or markers"
    )
}

test("Real DAISY 2.02 (WIPO Treaty) exists") {
    let url = try requireFile("wipo-treaty-d202-text-only.zip")
    try assertTrue(FileManager.default.fileExists(atPath: url.path))
}

test("Real DAISY 2.02 (WIPO Treaty) detected as DAISY") {
    let url = try requireFile("wipo-treaty-d202-text-only.zip")
    try assertTrue(isDAISYZipFile(url: url), "Should be detected as DAISY 2.02")
}

test("Real DAISY 2.02 (WIPO Treaty) extracts metadata") {
    let url = try requireFile("wipo-treaty-d202-text-only.zip")
    let metadata = try parseDAISY202MetadataFromZip(url: url)
    try assertTrue(!metadata.title.isEmpty, "Title should not be empty")
}

test("Real DAISY 2.02 (WIPO Treaty) converts to Markdown") {
    let url = try requireFile("wipo-treaty-d202-text-only.zip")
    let markdown = try parseDAISY202ToMarkdown(url: url)
    try assertTrue(!markdown.isEmpty, "Should produce Markdown")
    try assertGreater(markdown.count, 100, "Should have substantial content")
}

print("\n--- DTBook Element Tests ---")

test("DTBook blockquote converts to Markdown blockquote") {
    let dtbook = """
    <?xml version="1.0" encoding="UTF-8"?>
    <dtbook xmlns="http://www.daisy.org/z3986/2005/dtbook/" version="2005-3">
    <head><meta name="dc:Title" content="Test"/></head>
    <book><bodymatter><level1>
    <h1>Quotes</h1>
    <blockquote><p>To be or not to be.</p></blockquote>
    </level1></bodymatter></book></dtbook>
    """
    let markdown = convertDTBookSnippet(dtbook)
    try assertTrue(markdown.contains(">"), "Should contain blockquote marker")
}

}
