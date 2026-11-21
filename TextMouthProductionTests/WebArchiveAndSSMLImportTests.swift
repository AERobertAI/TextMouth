import XCTest
import UniformTypeIdentifiers
@testable import TextMouth

/// Web archives and SSML files as books (FMT03 and FMT07, part 2): both
/// import through the HTML path every HTML book takes, so headings, lists,
/// tables, and emphasis arrive as they do in an HTML book. Every import is
/// of a copy in the test's own folder, and every book opens as the reader
/// opens it.
final class WebArchiveAndSSMLImportTests: XCTestCase {

    // MARK: - Helpers

    /// The words every refusal of a file's text begins with after its name.
    private let readingFailed = "Reading its text failed: "

    /// A file named `name` in a new folder of this test's own, holding `bytes`.
    private func file(named name: String, holding bytes: Data) throws -> URL {
        let url = try makeSandboxDirectory("WebArchiveAndSSML").appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    /// Asserts that importing `url` fails with exactly `sentence`, the
    /// import's own words including the file's name.
    private func assertRefused(
        _ url: URL, saying sentence: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try FileImportService.importFileWithReport(from: url), file: file, line: line) {
            XCTAssertEqual($0.localizedDescription, sentence, file: file, line: line)
        }
    }

    /// An SSML document whose `speak` element holds `body`.
    private func speak(_ body: String) -> String {
        "<speak version=\"1.1\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\">\(body)</speak>"
    }

    /// Asserts that `book`'s text and headings read the same again from its
    /// source after content.md is removed, as they first read.
    private func assertReopensFromContent(
        _ book: Book, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let before = try openedContent(of: book)
        try FileManager.default.removeItem(at: MarkdownCacheService.cacheURL(for: book))
        let after = try BookContentAnalysisService.load(book: book, regenerateTextCache: true).content
        XCTAssertEqual(allText(of: after), allText(of: before), file: file, line: line)
        XCTAssertEqual(headingLines(of: after), headingLines(of: before), file: file, line: line)
        XCTAssertTrue(MarkdownCacheService.cacheExists(for: book), file: file, line: line)
    }

    // MARK: - Web archives

    func testTheWebArchiveSampleImportsTitledByItsFileNameWithItsHeadingsListAndTable() throws {
        let imported = try importedForTest(try copyOfFormatSample("webarchive/headings.webarchive"))
        XCTAssertEqual(imported.book.format, .webarchive)
        // The page's own title ("Harbour Notes") is not read: an HTML file keeps none either.
        XCTAssertEqual(imported.book.title, "headings")

        let content = try openedContent(of: imported.book)
        XCTAssertEqual(headingLines(of: content), ["1: Harbour Notes", "2: Morning Tides", "2: Timetable"])
        let text = allText(of: content)
        XCTAssertTrue(text.contains("The ferry leaves at seven."))
        for item in ["Bread from the bakery on Rue Ménard", "Smoked fish, naïve prices", "A newspaper already a day old"] {
            XCTAssertTrue(text.contains(item), item)
        }
        XCTAssertTrue(text.contains("Departs"))
    }

    func testAWebArchiveWhoseMainResourceIsTextOpensAsThatText() throws {
        let bytes = try webArchiveBytes(
            data: Data("Dock Notes\n\nThe ferry leaves at seven.".utf8), mimeType: "text/plain; charset=utf-8"
        )
        let imported = try importedForTest(try file(named: "dock.webarchive", holding: bytes))
        XCTAssertEqual(imported.book.format, .webarchive)
        XCTAssertEqual(imported.book.title, "dock")
        let text = allText(of: try openedContent(of: imported.book))
        XCTAssertTrue(text.contains("Dock Notes"))
        XCTAssertTrue(text.contains("The ferry leaves at seven."))
        try assertReopensFromContent(imported.book)
    }

    func testAWebArchiveWhoseMainResourceIsAnImageIsRefusedWithTheReadersSentence() throws {
        let bytes = try webArchiveBytes(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png", encoding: nil)
        assertRefused(
            try file(named: "picture.webarchive", holding: bytes),
            saying: "Could not import “picture.webarchive”. \(readingFailed)"
                + "This web archive holds a file of the type “image/png”, not a web page or text, so it has nothing to read."
        )
    }

    func testAWebArchiveWhosePageHasNoWordsIsRefused() throws {
        let bytes = try webArchiveBytes(data: Data("<html><body> </body></html>".utf8))
        assertRefused(
            try file(named: "blank.webarchive", holding: bytes),
            saying: "Could not import “blank.webarchive”. \(readingFailed)This file has no text to read."
        )
    }

    // MARK: - SSML files

    func testTheSSMLSampleImportsAsTwoParagraphsOfText() throws {
        let imported = try importedForTest(try copyOfFormatSample("ssml/passage.ssml"))
        XCTAssertEqual(imported.book.format, .ssml)
        XCTAssertEqual(imported.book.title, "passage")

        let content = try openedContent(of: imported.book)
        XCTAssertEqual(headingLines(of: content), [])
        let text = allText(of: content)
        for forbidden in ["<", ">", "*", "W3C"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        for words in ["World Wide Web Consortium", "9:30am", "It is not a long crossing."] {
            XCTAssertTrue(text.contains(words), words)
        }
        XCTAssertEqual(text.components(separatedBy: "\n\n").count, 2, text)
    }

    func testAnSSMLFileWithNoWordsIsRefused() throws {
        assertRefused(
            try file(named: "silent.ssml", holding: Data(speak("<break time=\"2s\"/>").utf8)),
            saying: "Could not import “silent.ssml”. \(readingFailed)This file has no text to read."
        )
    }

    func testAnHTMLFileNamedSSMLIsRefusedWithTheReadersSentence() throws {
        assertRefused(
            try file(named: "page.ssml", holding: Data("<html><body><p>Hello</p></body></html>".utf8)),
            saying: "Could not import “page.ssml”. \(readingFailed)"
                + "This file is not SSML: it begins with the element “html”, not “speak”."
        )
    }

    // MARK: - Reopening

    /// A web archive's HTML page honors `includesPages` as an .html file does:
    /// its page-break element is a page marker when pages are included, and
    /// the page as it was read before pages when they are not (the launch
    /// re-read's compare), by the cache's own extraction and by the page alone.
    func testAWebArchiveHonorsIncludesPages() throws {
        let page = "<html><body><p>One <span role=\"doc-pagebreak\" aria-label=\"12\">12</span>two</p></body></html>"
        let bytes = try webArchiveBytes(data: Data(page.utf8), mimeType: "text/html")
        let url = try file(named: "pages.webarchive", holding: bytes)
        let imported = try importedForTest(url)

        let with = try XCTUnwrap(MarkdownCacheService.extractedMarkdown(for: imported.book, includesPages: true))
        XCTAssertTrue(with.contains("<!-- page: 12 -->"), with)
        let without = try XCTUnwrap(MarkdownCacheService.extractedMarkdown(for: imported.book, includesPages: false))
        XCTAssertFalse(without.contains("<!--"), without)
        XCTAssertTrue(without.contains("One 12two"), without)

        let mainPage = try WebArchiveReader.mainPage(of: url)
        XCTAssertTrue(try mainPage.markdown().contains("<!-- page: 12 -->"), "pages are included by default")
        XCTAssertFalse(try mainPage.markdown(includesPages: false).contains("<!--"))
    }

    func testBothReopenFromContentAsTheyFirstRead() throws {
        for sample in ["webarchive/headings.webarchive", "ssml/passage.ssml"] {
            let imported = try importedForTest(try copyOfFormatSample(sample))
            try assertReopensFromContent(imported.book)
        }
    }

    // MARK: - The cases

    func testTheNewCasesKeepTheirRawValuesNamesAndExtensions() {
        XCTAssertEqual(BookFormat(rawValue: "webarchive"), .webarchive)
        XCTAssertEqual(BookFormat(rawValue: "ssml"), .ssml)
        XCTAssertEqual(BookFormat.webarchive.displayName, "Web Archive")
        XCTAssertEqual(BookFormat.ssml.displayName, "SSML")
        XCTAssertEqual(BookFormat.webarchive.fileExtensions, ["webarchive"])
        XCTAssertEqual(BookFormat.ssml.fileExtensions, ["ssml"])
        for (name, format) in [("a.webarchive", BookFormat.webarchive), ("a.WEBARCHIVE", .webarchive), ("a.ssml", .ssml)] {
            XCTAssertEqual(BookFormat.detect(from: URL(fileURLWithPath: "/tmp/\(name)")), format, name)
        }
        // Neither format keeps a title or author the import reads.
        XCTAssertFalse(ImportedFileMetadata.readsFile(of: .webarchive))
        XCTAssertFalse(ImportedFileMetadata.readsFile(of: .ssml))
    }

    func testABookOfEachNewFormatEncodesAndDecodesWithItsFormat() throws {
        for format in [BookFormat.webarchive, .ssml] {
            let book = Book(title: "Pier", format: format, filePath: "/tmp/pier", md5Hash: "hash")
            let data = try JSONEncoder().encode(book)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"\(format.rawValue)\""), format.rawValue)
            XCTAssertEqual(try JSONDecoder().decode(Book.self, from: data).format, format)
        }
    }

    // MARK: - The Open Book panel

    func testTheOpenBookPanelOffersWebArchivesAndSSML() throws {
        let identifiers = FileImportService.supportedTypes.map(\.identifier)
        XCTAssertTrue(identifiers.contains("com.apple.webarchive"))
        // The SSML type is declared in Info.plist and always offered: a type
        // whose preferred extension is "ssml" must be among the panel's types.
        let hasSSML = FileImportService.supportedTypes.contains { $0.preferredFilenameExtension == "ssml" }
        XCTAssertTrue(hasSSML, "The Open Book panel offers no type for .ssml files")
        XCTAssertTrue(identifiers.contains("org.w3.ssml"))
    }
}
