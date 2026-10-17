import XCTest
import ZIPFoundation
@testable import TextMouth

/// Package navigation must retain source order and resolve in-package URLs.
final class PackageNavigationAuditTests: XCTestCase {
    /// A nested NCX child must not replace its parent or move ahead of it.
    /// DAISY audio segments use this exact list as their playback sequence.
    func testNestedDAISYNCXRetainsParentsAndDocumentOrder() throws {
        let data = Data("""
        <ncx><navMap>
        <navPoint><navLabel><text>Part One</text></navLabel><content src="one.smil"/>
          <navPoint><navLabel><text>Section One</text></navLabel><content src="one.smil#section"/>
            <navPoint><navLabel><text>Detail</text></navLabel><content src="one.smil#detail"/></navPoint>
          </navPoint>
        </navPoint>
        <navPoint><navLabel><text>Part Two</text></navLabel><content src="two.smil"/></navPoint>
        </navMap></ncx>
        """.utf8)

        let points = try DAISYNCXParser(data: data, file: "book.ncx").parse()

        XCTAssertEqual(points.map(\.label), ["Part One", "Section One", "Detail", "Part Two"])
        XCTAssertEqual(points.map(\.contentSrc), ["one.smil", "one.smil#section", "one.smil#detail", "two.smil"])
        XCTAssertEqual(points.map(\.level), [1, 2, 3, 1])
    }

    /// Real ZIP entries cover both parser paths: an OPF in a sibling folder,
    /// percent-encoded spaces, and a filename containing two literal dots.
    func testEPUBDirectAndCachedParsingResolveSiblingChapterPaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Source")
        let files = [
            "META-INF/container.xml": """
            <container><rootfiles><rootfile full-path="Package/package.opf"/></rootfiles></container>
            """,
            "Package/package.opf": """
            <package><metadata><title>Sibling Chapters</title><creator>Writer</creator></metadata>
            <manifest>
              <item id="one" href="../Text/chapter%20one.xhtml" media-type="application/xhtml+xml"/>
              <item id="two" href="../Text/chapter..two.xhtml" media-type="application/xhtml+xml"/>
            </manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>
            """,
            "Text/chapter one.xhtml": "<html><body><h1>First Chapter</h1><p>Alpha content.</p></body></html>",
            "Text/chapter..two.xhtml": "<html><body><h1>Second Chapter</h1><p>Beta content.</p></body></html>"
        ]
        for (path, text) in files {
            let file = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        let archive = directory.appendingPathComponent("book.epub")
        try FileManager.default.zipItem(at: source, to: archive, shouldKeepParent: false)

        let direct = try EPUBParser.parse(url: archive)
        let book = try FileImportService.importFile(from: archive)
        defer { try? FileManager.default.removeItem(at: book.tmbDirectory) }
        let cached = try MarkdownCacheService.loadFromCache(for: book)

        XCTAssertEqual(direct.chapters.count, 2)
        // A parse that finds too few chapters fails here, not at a subscript below.
        _ = try XCTUnwrap(direct.chapters[safe: 1], "the directly parsed book has no second chapter")
        XCTAssertTrue(direct.chapters[0].text.contains("Alpha content."))
        XCTAssertTrue(direct.chapters[1].text.contains("Beta content."))
        XCTAssertEqual(cached.chapters.count, 2)
        _ = try XCTUnwrap(cached.chapters[safe: 1], "the cached book has no second chapter")
        XCTAssertTrue(cached.chapters[0].text.contains("Alpha content."))
        XCTAssertTrue(cached.chapters[1].text.contains("Beta content."))
    }
}
