import Foundation
import ZIPFoundation
import SwiftSoup

#if canImport(TextMouth)
@testable import TextMouth

private func isDAISYZipFile(url: URL) -> Bool {
    DAISYParser.isDAISYZip(url: url)
}

private func parseDAISYMetadata(from url: URL) throws -> DAISYMetadata {
    guard let metadata = try DAISYParser.readMetadata(from: url) else {
        throw TestError.assertionFailed("Production DAISY parser returned no metadata")
    }
    return metadata
}

private func parseDAISYToMarkdown(from url: URL) throws -> String {
    try DAISYParser.extractMarkdown(from: url)
}

func convertDTBookSnippet(_ xml: String) -> String {
    guard let data = xml.data(using: .utf8) else { return "" }
    return DTBookToMarkdownConverter().convert(data: data)
}

private func parseDAISY202MetadataFromZip(url: URL) throws -> DAISYMetadata {
    try parseDAISYMetadata(from: url)
}

private func parseDAISY202ToMarkdown(url: URL) throws -> String {
    try DAISYParser.extractMarkdown(from: url)
}

private func parseMarkdown(markdown: String, title: String = "Untitled") throws -> DocumentContent {
    try MarkdownDocParser.parse(markdown: markdown, title: title)
}

private func parseHTML(html: String, title: String = "Untitled") throws -> DocumentContent {
    try HTMLParser.parse(html: html, title: title)
}
#endif

func runDAISYParserTests() {
print("\n--- DAISY 3 Parser Tests (Hyperion) ---")

test("DAISY 3 ZIP file exists (hyperion)") {
    let url = try requireFile("hyperion_daisy.zip")
    try assertTrue(FileManager.default.fileExists(atPath: url.path))
}

func extractDAISY202TestFragmentsFromHTML(_ files: [String: String], refs: [String]) throws -> String {
    var documents: [String: SwiftSoup.Document] = [:]
    var fragments: [String] = []
    var lastNormalized = ""

    for ref in refs {
        let parts = ref.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let filePath = String(parts[0])
        let fragmentID = parts.count > 1 ? String(parts[1]) : ""
        guard let html = files[filePath] else { continue }

        let doc: SwiftSoup.Document
        if let cached = documents[filePath] {
            doc = cached
        } else {
            doc = try SwiftSoup.parse(html)
            documents[filePath] = doc
        }

        let markdown: String
        if fragmentID.isEmpty {
            markdown = (try? parseHTML(html: html).chapters.first?.text) ?? ""
        } else if let element = try doc.getElementById(fragmentID) {
            markdown = try convertDAISY202TestFragmentElement(element)
        } else {
            continue
        }

        let normalized = ParserUtilities.normalizeMarkdownWhitespace(markdown)
        guard !normalized.isEmpty, normalized != lastNormalized else { continue }
        fragments.append(normalized)
        lastNormalized = normalized
    }

    return ParserUtilities.normalizeMarkdownWhitespace(fragments.joined(separator: "\n\n"))
}

func convertDAISY202TestFragmentElement(_ element: SwiftSoup.Element) throws -> String {
    let tag = element.tagName().lowercased()
    if tag == "a" {
        return try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let childElements = element.children().array()
    if ["span", "strong", "em", "b", "i", "sup", "sub"].contains(tag),
       let firstChild = childElements.first {
        return try convertDAISY202TestFragmentElement(firstChild)
    }
    return ((try? parseHTML(html: try element.outerHtml()).chapters.first?.text) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
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

test("DAISY 2.02 fragment extraction avoids whole-file duplicate wrapper text") {
    let html = """
    <html><body>
    <h1 id="title_heading"><a href="part1.smil#txt_1">Opening Title</a></h1>
    <div class="doctitle"><span id="title_sentence"><a href="part1.smil#txt_2">Opening Title</a></span></div>
    <p id="body_1"><span id="body_sentence">First real sentence.</span></p>
    </body></html>
    """

    let wholeFileMarkdown = (try? parseHTML(html: html).chapters.first?.text) ?? ""
    let refs = ["book.html#title_heading", "book.html#body_sentence"]
    let fragmentMarkdown = try extractDAISY202TestFragmentsFromHTML(["book.html": html], refs: refs)

    try assertTrue(wholeFileMarkdown.contains("Opening Title Opening Title"),
                   "Whole-file extraction should include duplicated wrapper text")
    try assertTrue(fragmentMarkdown.contains("Opening Title"), "Fragment extraction should keep the heading text")
    try assertTrue(fragmentMarkdown.contains("First real sentence."), "Fragment extraction should keep the body text")
    try assertTrue(!fragmentMarkdown.contains("Opening Title Opening Title"),
                   "Fragment extraction should not repeat the title wrapper text")
}

test("DAISY 2.02 Markdown extraction follows SMIL text fragments") {
    let daisyURL = try makeTemporaryDAISY202FragmentZip(entries: [
        "ncc.html": """
        <html><head>
        <meta name="dc:title" content="Fragment Test"/>
        <meta name="dc:creator" content="Tester"/>
        </head><body>
        <h1><a href="part1.smil#nav_1">Opening Title</a></h1>
        </body></html>
        """,
        "part1.smil": """
        <?xml version="1.0"?>
        <smil><body><seq>
          <par id="nav_1"><text src="book.html#title_heading"/></par>
          <par id="nav_2"><text src="book.html#body_sentence"/></par>
        </seq></body></smil>
        """,
        "book.html": """
        <html><body>
        <h1 id="title_heading"><a href="part1.smil#nav_1">Opening Title</a></h1>
        <div class="doctitle"><span id="title_sentence"><a href="part1.smil#nav_2">Opening Title</a></span></div>
        <p id="body_1"><span id="body_sentence">First real sentence.</span></p>
        <p id="unreferenced">This unreferenced paragraph should not be cached.</p>
        </body></html>
        """
    ])
    defer { try? FileManager.default.removeItem(at: daisyURL) }

    let markdown = try parseDAISY202ToMarkdown(url: daisyURL)
    try assertTrue(markdown.contains("Opening Title"), "Referenced title fragment should be present")
    try assertTrue(markdown.contains("First real sentence."), "Referenced body fragment should be present")
    try assertTrue(!markdown.contains("This unreferenced paragraph"),
                   "Unreferenced file-level text should not be included")
    try assertTrue(!markdown.contains("Opening Title Opening Title"),
                   "Wrapper title duplication should not be baked into content.md")
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

// MARK: - SMIL Fragment & Segment Boundary Tests

print("\n--- SMIL Fragment Audio Clip Tests ---")

test("SMIL parser records par IDs on audio clips") {
    let smilXML = """
    <?xml version="1.0"?>
    <smil>
    <body>
      <seq>
        <par id="par_001">
          <audio src="audio.mp3" clipBegin="0:00:00.000" clipEnd="0:00:10.500"/>
        </par>
        <par id="par_002">
          <audio src="audio.mp3" clipBegin="0:00:10.500" clipEnd="0:00:25.000"/>
        </par>
        <par id="par_003">
          <audio src="audio.mp3" clipBegin="0:00:25.000" clipEnd="0:00:42.300"/>
        </par>
      </seq>
    </body>
    </smil>
    """
    let parser = TestFragmentAwareSMILParser(data: smilXML.data(using: .utf8)!)
    let clips = parser.parse()

    try assertEqual(clips.count, 3, "Should parse 3 audio clips")
    try assertEqual(clips[0].parID, "par_001", "First clip should have par_001 ID")
    try assertEqual(clips[1].parID, "par_002", "Second clip should have par_002 ID")
    try assertEqual(clips[2].parID, "par_003", "Third clip should have par_003 ID")
}

test("SMIL parser clip(forFragment:) finds correct clip") {
    let smilXML = """
    <?xml version="1.0"?>
    <smil><body><seq>
      <par id="intro"><audio src="ch1.mp3" clipBegin="0.0" clipEnd="5.0"/></par>
      <par id="verse1"><audio src="ch1.mp3" clipBegin="5.0" clipEnd="20.0"/></par>
      <par id="verse2"><audio src="ch1.mp3" clipBegin="20.0" clipEnd="38.0"/></par>
    </seq></body></smil>
    """
    let parser = TestFragmentAwareSMILParser(data: smilXML.data(using: .utf8)!)
    _ = parser.parse()

    let clip1 = parser.clip(forFragment: "intro")
    try assertTrue(clip1 != nil, "Should find clip for 'intro'")
    try assertTrue(abs(clip1!.startTime - 0.0) < 0.001, "intro starts at 0")

    let clip2 = parser.clip(forFragment: "verse2")
    try assertTrue(clip2 != nil, "Should find clip for 'verse2'")
    try assertTrue(abs(clip2!.startTime - 20.0) < 0.001, "verse2 starts at 20")

    let missing = parser.clip(forFragment: "nonexistent")
    try assertTrue(missing == nil, "Should return nil for unknown fragment")

    let empty = parser.clip(forFragment: "")
    try assertTrue(empty == nil, "Should return nil for empty fragment")
}

test("Segments from same SMIL get distinct non-overlapping time ranges") {
    // Simulate what convertDAISY3Audio now does: two navPoints reference
    // the same SMIL file but different fragment IDs.
    let smilXML = """
    <?xml version="1.0"?>
    <smil><body><seq>
      <par id="heading_ch1"><audio src="book.mp3" clipBegin="0:00:00" clipEnd="0:01:00"/></par>
      <par id="body_ch1"><audio src="book.mp3" clipBegin="0:01:00" clipEnd="0:05:00"/></par>
      <par id="heading_ch2"><audio src="book.mp3" clipBegin="0:05:00" clipEnd="0:06:00"/></par>
      <par id="body_ch2"><audio src="book.mp3" clipBegin="0:06:00" clipEnd="0:10:00"/></par>
    </seq></body></smil>
    """
    let parser = TestFragmentAwareSMILParser(data: smilXML.data(using: .utf8)!)
    let clips = parser.parse()

    // NavPoint 1 references heading_ch1, NavPoint 2 references heading_ch2
    let clip1 = parser.clip(forFragment: "heading_ch1")!
    let clip2 = parser.clip(forFragment: "heading_ch2")!

    // Segment 1: starts at clip1.startTime, ends at clip2.startTime (same audio file)
    let seg1Start = clip1.startTime
    let seg1End = clip2.startTime  // next navPoint's clip start

    // Segment 2: starts at clip2.startTime, ends at last clip's endTime
    let seg2Start = clip2.startTime
    let seg2End = clips.last!.endTime

    try assertTrue(abs(seg1Start - 0.0) < 0.001, "Segment 1 should start at 0")
    try assertTrue(abs(seg1End - 300.0) < 0.001, "Segment 1 should end at 300 (5:00)")
    try assertTrue(abs(seg2Start - 300.0) < 0.001, "Segment 2 should start at 300 (5:00)")
    try assertTrue(abs(seg2End - 600.0) < 0.001, "Segment 2 should end at 600 (10:00)")

    // Crucially: segments must NOT overlap
    try assertTrue(seg1End <= seg2Start, "Segments must not overlap")
    // And must NOT be identical (the old bug)
    try assertTrue(seg1Start != seg2Start || seg1End != seg2End,
                   "Segments sharing a SMIL must have distinct time ranges")
}

test("Segments from different SMIL files use their own clip ranges") {
    // When navPoints reference different SMIL files, each segment uses
    // its own SMIL's clip range (end = last clip end, not next navPoint).
    let smil1 = """
    <?xml version="1.0"?>
    <smil><body><seq>
      <par id="s1"><audio src="part1.mp3" clipBegin="0.0" clipEnd="60.0"/></par>
    </seq></body></smil>
    """
    let smil2 = """
    <?xml version="1.0"?>
    <smil><body><seq>
      <par id="s2"><audio src="part2.mp3" clipBegin="0.0" clipEnd="45.0"/></par>
    </seq></body></smil>
    """

    let parser1 = TestFragmentAwareSMILParser(data: smil1.data(using: .utf8)!)
    let clips1 = parser1.parse()
    let parser2 = TestFragmentAwareSMILParser(data: smil2.data(using: .utf8)!)
    let clips2 = parser2.parse()

    let seg1Clip = parser1.clip(forFragment: "s1") ?? clips1[0]
    let seg2Clip = parser2.clip(forFragment: "s2") ?? clips2[0]

    // Different audio files → each segment ends at its own SMIL's last clip
    let seg1End = clips1.last!.endTime
    let seg2End = clips2.last!.endTime

    let seg1File = (seg1Clip.file as NSString).lastPathComponent
    let seg2File = (seg2Clip.file as NSString).lastPathComponent

    try assertTrue(seg1File != seg2File, "Different SMIL files should reference different audio")
    try assertTrue(abs(seg1End - 60.0) < 0.001, "Segment 1 end from its own SMIL")
    try assertTrue(abs(seg2End - 45.0) < 0.001, "Segment 2 end from its own SMIL")
}

test("DAISY 2.02 SMIL with npt= time format preserves par IDs") {
    let smilXML = """
    <?xml version="1.0"?>
    <smil><body><seq>
      <par id="tcp1">
        <audio src="audio.mp3" clip-begin="npt=0.000s" clip-end="npt=12.500s"/>
      </par>
      <par id="tcp2">
        <audio src="audio.mp3" clip-begin="npt=12.500s" clip-end="npt=38.228s"/>
      </par>
    </seq></body></smil>
    """
    let parser = TestFragmentAwareSMILParser(data: smilXML.data(using: .utf8)!)
    let clips = parser.parse()

    try assertEqual(clips.count, 2)
    try assertEqual(clips[0].parID, "tcp1")
    try assertEqual(clips[1].parID, "tcp2")
    try assertTrue(abs(clips[0].startTime - 0.0) < 0.001)
    try assertTrue(abs(clips[1].startTime - 12.5) < 0.001)
    try assertTrue(abs(clips[1].endTime - 38.228) < 0.001)
}

}

private func makeTemporaryDAISY202FragmentZip(entries: [String: String]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("TextMouthDAISYFragmentTest-\(UUID().uuidString).zip")
    let archive = try Archive(url: url, accessMode: .create)

    for (path, contents) in entries {
        let data = Data(contents.utf8)
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            provider: { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                return data[start..<end]
            }
        )
    }

    return url
}
