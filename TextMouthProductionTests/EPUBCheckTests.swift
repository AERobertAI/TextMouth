import XCTest
import ZIPFoundation
@testable import TextMouth

/// What EPUB's own validator says of the EPUB writer's files, on the shapes
/// that real books make and the reviews found failing: skipped and rising
/// heading levels (B2, S1), contents targets (B3), links (B5), right-to-left
/// text (S8), pages in table cells (S3), and plates (S2).
///
/// Each test skips where `epubcheck` is not installed, and fails where it ran
/// and gave no answer (`EPUBCheck.Outcome`). Where it is absent, the
/// structure the validator would find is still checked by reading the files.
final class EPUBCheckTests: XCTestCase {

    // MARK: - Helpers

    /// Exports `markdown` for a book titled "Harbour Notes", failing the test
    /// unless every file of the package is well-formed.
    private func export(
        _ markdown: String,
        language: String? = "en",
        writer: EPUBExportWriter = EPUBExportWriterTests.writer()
    ) throws -> URL {
        let folder = try makeSandboxDirectory("EPUB Check")
        let url = try EPUBRoundTrip.export(markdown, title: "Harbour Notes", in: folder, writer: writer, language: language)
        let archive = try Archive(url: url, accessMode: .read)
        for entry in archive where entry.path != "mimetype" {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            let parser = XMLParser(data: data)
            XCTAssertTrue(parser.parse(), "\(entry.path) is not well-formed: \(String(describing: parser.parserError))")
        }
        return url
    }

    /// The contents list of the navigation document of the EPUB at `url`.
    private func contents(of url: URL) throws -> ContentsStructure {
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive["OEBPS/nav.xhtml"] else {
            XCTFail("no navigation document")
            return ContentsStructure()
        }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return ContentsStructure.read(data)
    }

    /// Fails unless EPUBCheck, where it is installed, finds nothing in `url`;
    /// returns whether it ran.
    private func assertEPUBCheckIsClean(_ url: URL, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let outcome = EPUBCheck.run(on: url, in: try makeSandboxDirectory("EPUB Check Output"))
        XCTAssertTrue(outcome.isAcceptable, "\(what): epubcheck: \(outcome.summary)", file: file, line: line)
    }

    // MARK: - The Validator Itself

    /// The validator is installed and accepts a plain export: a test that
    /// skips where it is absent, so a skip shows in the results, and fails
    /// where it ran and gave no summary.
    func testEPUBCheckAcceptsAnExport() throws {
        try XCTSkipUnless(EPUBCheck.isInstalled, "epubcheck is not installed")
        let url = try export("# One\n\nWords of the book.")
        let outcome = EPUBCheck.run(on: url, in: try makeSandboxDirectory("EPUB Check Output"))
        guard case .answered(let summary, let isClean) = outcome else {
            return XCTFail("epubcheck was installed and gave no answer: \(outcome.summary)")
        }
        XCTAssertTrue(isClean, summary)
    }

    /// A validator that finds an error says so: a book with a heading level
    /// it cannot nest (made by hand here, two lists in one item) fails it, so
    /// "clean" means something.
    func testEPUBCheckFindsAnErrorInAPackageWithTwoListsInOneItem() throws {
        try XCTSkipUnless(EPUBCheck.isInstalled, "epubcheck is not installed")
        let url = try export("# One\n\nWords.")
        // Break the navigation document the way the review found: a second list in one item.
        let broken = try makeSandboxDirectory("EPUB Check Broken").appendingPathComponent("broken.epub")
        let source = try Archive(url: url, accessMode: .read)
        let target = try Archive(url: broken, accessMode: .create)
        for entry in source {
            var data = Data()
            _ = try source.extract(entry) { data.append($0) }
            if entry.path == "OEBPS/nav.xhtml" {
                let text = String(decoding: data, as: UTF8.self)
                    .replacingOccurrences(of: "</a></li>\n</ol>", with: "</a><ol><li><a href=\"chapter-1.xhtml\">x</a></li></ol><ol><li><a href=\"chapter-1.xhtml\">y</a></li></ol></li>\n</ol>")
                data = Data(text.utf8)
            }
            let bytes = data
            try target.addEntry(
                with: entry.path, type: .file, uncompressedSize: Int64(bytes.count),
                compressionMethod: entry.path == "mimetype" ? .none : .deflate,
                provider: { position, size in bytes.subdata(in: Int(position)..<min(Int(position) + size, bytes.count)) }
            )
        }
        let outcome = EPUBCheck.run(on: broken, in: try makeSandboxDirectory("EPUB Check Output"))
        guard case .answered(_, let isClean) = outcome else {
            return XCTFail("epubcheck gave no answer: \(outcome.summary)")
        }
        XCTAssertFalse(isClean, "the validator did not notice two lists in one item")
    }

    // MARK: - Heading Levels (B2, S1)

    /// The shapes of heading levels that nest badly: the contents list has one
    /// list to an item, every heading is linked, and EPUBCheck finds nothing.
    func testHeadingLevelShapesMakeValidContents() throws {
        let shapes: [[Int]] = [[1, 3, 2], [1, 2, 4, 3], [1, 6, 3, 5, 2], [3, 1, 2, 1, 2], [2, 1], [1, 4, 2, 6, 1]]
        for levels in shapes {
            let markdown = levels.enumerated()
                .map { "\(String(repeating: "#", count: $1)) Heading \($0 + 1)\n\nWords of section \($0 + 1)." }
                .joined(separator: "\n\n")
            let url = try export(markdown)
            let found = try contents(of: url)
            XCTAssertEqual(found.titles, levels.indices.map { "Heading \($0 + 1)" }, "\(levels)")
            XCTAssertLessThanOrEqual(found.mostListsInAnItem, 1, "\(levels): two lists in one item")
            try assertEPUBCheckIsClean(url, "levels \(levels)")
        }
    }

    // MARK: - Links (B5)

    /// Every one of the review's 45 link inputs: each address the writer writes
    /// is a URL (no space, quote, bar, brace, caret, backslash, bracket, or
    /// second "#", and a host), whatever the book held, and the whole set
    /// passes EPUBCheck as one book.
    func testEveryLinkCaseWritesOnlyURLsAndPassesEPUBCheck() throws {
        let markdown = EPUBLinkCases.all.map { "\($0.markdown) \($0.name)" }.joined(separator: "\n\n")
        let url = try export(markdown)
        let archive = try Archive(url: url, accessMode: .read)
        var data = Data()
        _ = try archive.extract(try XCTUnwrap(archive["OEBPS/chapter-1.xhtml"])) { data.append($0) }
        let chapter = String(decoding: data, as: UTF8.self)
        let addresses = EPUBExportWriterTests.captures(of: "href=\"([^\"]*)\"", in: chapter)
        XCTAssertGreaterThan(addresses.count, 15, "most of the cases keep a link")
        for address in addresses {
            let decoded = address.replacingOccurrences(of: "&amp;", with: "&")
            XCTAssertNotNil(
                decoded.range(of: #"^(https?://[A-Za-z0-9._~-]+(:[0-9]{1,5})?|mailto:)[A-Za-z0-9._~!$&'()*+,;=:@/?%#-]*$"#, options: .regularExpression),
                "not a URL: \(decoded)"
            )
            XCTAssertLessThanOrEqual(decoded.filter { $0 == "#" }.count, 1, "a second #: \(decoded)")
            XCTAssertFalse(decoded.contains("["), "a bracket: \(decoded)")
            XCTAssertFalse(decoded.hasSuffix("://"), "no host: \(decoded)")
            XCTAssertNotEqual(decoded, "mailto:", "no mail address")
        }
        try assertEPUBCheckIsClean(url, "the 45 link cases")
    }

    // MARK: - Right to Left (S8)

    /// A Hebrew book with its language, and one with none: the first is set
    /// right to left from the root and the spine, the second guessed from the
    /// words block by block; EPUBCheck accepts both.
    func testRightToLeftBooksPassEPUBCheck() throws {
        let markdown = "# \u{5E9}\u{5DC}\u{5D5}\u{5DD}\n\n\u{5D4}\u{5D9}\u{5D4} \u{5D6}\u{5DE}\u{5DF} \u{5D0}\u{5D7}\u{5D3}.\n\n- \u{5D0}\u{5D7}\u{5D3}\n\n| \u{5D0} | \u{5D1} |\n|---|---|\n| \u{5D2} | \u{5D3} |"
        for language in ["he", "ar-EG", nil] as [String?] {
            let url = try export(markdown, language: language)
            try assertEPUBCheckIsClean(url, "language \(language ?? "none")")
        }
    }

    // MARK: - Places, Tables, and Plates

    /// A book with contents targets, pages in a table's cells and in a
    /// heading, and a chapter of only a page: valid, as every shape of a real
    /// book the review made.
    func testTargetsCellPagesAndPlatesPassEPUBCheck() throws {
        let one = MarkdownHeadingAnnotation(level: 1, text: "Chapter One").markdown
        let two = MarkdownHeadingAnnotation(level: 2, text: "First Section").markdown
        let markdown = """
        <!-- chapter: One -->
        \(one)

        Chapter One

        Words <!-- page: 1 --> of the chapter.

        \(two)

        First Section

        | Port | Depth |
        |------|-------|
        | Alder <!-- page: 2 --> | 12 |
        | Brant | 9 |

        <!-- chapter: Plate -->
        <!-- page: 3 -->

        <!-- chapter: Two -->
        ## <!-- page: 4 -->A heading with its page

        More words.
        """
        let url = try export(markdown)
        try assertEPUBCheckIsClean(url, "targets, cell pages, and a plate")
    }
}
