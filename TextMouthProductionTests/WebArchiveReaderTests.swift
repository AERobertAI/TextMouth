import XCTest
@testable import TextMouth

/// `WebArchiveReader` (FMT03): the main page of a Safari web archive, read
/// from its property list without following anything the archive names.
final class WebArchiveReaderTests: XCTestCase {

    // MARK: Helpers

    /// The bytes of a web archive whose main resource has the given fields;
    /// a nil field is left out, as another tool may leave it out. `extra`
    /// adds top-level entries beside `WebMainResource`, such as subresources.
    private func archive(
        data: Data? = Data("<h1>Title</h1>".utf8),
        mimeType: String? = "text/html",
        encoding: String? = "utf-8",
        extra: [String: Any] = [:],
        format: PropertyListSerialization.PropertyListFormat = .binary
    ) throws -> Data {
        var main: [String: Any] = ["WebResourceURL": "file:///index.html"]
        main["WebResourceData"] = data
        main["WebResourceMIMEType"] = mimeType
        main["WebResourceTextEncodingName"] = encoding
        var root: [String: Any] = ["WebMainResource": main]
        root.merge(extra) { _, new in new }
        return try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
    }

    /// The main page of `bytes`, as an archive named "page.webarchive".
    private func page(_ bytes: Data) throws -> WebArchiveReader.MainPage {
        try WebArchiveReader.mainPage(in: bytes, fileName: "page.webarchive")
    }

    /// Writes `bytes` to a file in this test's own folder and returns it.
    private func file(_ bytes: Data, named name: String = "page.webarchive") throws -> URL {
        let url = try makeSandboxDirectory("WebArchive").appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    // MARK: The Sample

    func testTheSampleReadsAsAnHTMLPageWithItsHeadingAndTable() throws {
        let copy = try copyOfFormatSample("webarchive/headings.webarchive")
        let main = try WebArchiveReader.mainPage(of: copy)
        XCTAssertTrue(main.isHTML)
        XCTAssertTrue(main.text.contains("<h1"))
        XCTAssertTrue(main.text.contains("Harbour Notes"))
        XCTAssertTrue(main.text.contains("Departs"))
    }

    // MARK: Encodings

    func testAWindows1252PageNamedByTheArchiveReadsItsAccent() throws {
        let bytes = Data("<p>caf".utf8) + Data([0xE9]) + Data("</p>".utf8)
        let main = try page(archive(data: bytes, encoding: "windows-1252"))
        XCTAssertEqual(main.text, "<p>café</p>")
    }

    func testTheSameBytesWithoutAnEncodingNameReadByThePagesOwnDeclaration() throws {
        let bytes = Data("<meta charset=\"windows-1252\"><p>caf".utf8) + Data([0xE9]) + Data("</p>".utf8)
        let main = try page(archive(data: bytes, encoding: nil))
        XCTAssertTrue(main.text.contains("café"))
    }

    func testAnEncodingNameTheBytesDoNotReadInFallsToTheDecoder() throws {
        // 0xE9 alone is not valid UTF-8; the decoder reads it as Windows-1252.
        let bytes = Data("<p>caf".utf8) + Data([0xE9]) + Data("</p>".utf8)
        let main = try page(archive(data: bytes, encoding: "utf-8"))
        XCTAssertEqual(main.text, "<p>café</p>")
    }

    func testAnUnknownEncodingNameFallsToTheDecoder() throws {
        let main = try page(archive(data: Data("<p>plain</p>".utf8), encoding: "no-such-encoding"))
        XCTAssertEqual(main.text, "<p>plain</p>")
    }

    func testAByteOrderMarkIsDroppedAndLineEndingsAreNormalized() throws {
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("<p>a</p>\r\n<p>b</p>\r".utf8)
        let main = try page(archive(data: bytes, encoding: "utf-8"))
        XCTAssertEqual(main.text, "<p>a</p>\n<p>b</p>\n")
    }

    // MARK: Types

    func testPlainTextWithParametersReadsAsText() throws {
        let main = try page(archive(data: Data("Just words.".utf8), mimeType: "text/plain; charset=utf-8"))
        XCTAssertEqual(main, WebArchiveReader.MainPage(text: "Just words.", isHTML: false))
    }

    func testXHTMLAndAMissingTypeReadAsHTML() throws {
        let xhtml = try page(archive(mimeType: " Application/XHTML+XML "))
        XCTAssertTrue(xhtml.isHTML)
        let missing = try page(archive(mimeType: nil))
        XCTAssertTrue(missing.isHTML)
        let empty = try page(archive(mimeType: ""))
        XCTAssertTrue(empty.isHTML)
    }

    func testAnImageMainResourceIsRefusedWithItsSentence() throws {
        let bytes = try archive(mimeType: " image/png ")
        XCTAssertThrowsError(try page(bytes)) { error in
            XCTAssertEqual(error as? WebArchiveReader.Failure, .notAPage(mimeType: "image/png"))
            XCTAssertEqual(
                error.localizedDescription,
                "This web archive holds a file of the type “image/png”, not a web page or text, so it has nothing to read."
            )
        }
    }

    func testNotAWebArchiveHasItsSentence() {
        XCTAssertEqual(
            WebArchiveReader.Failure.notAWebArchive.errorDescription,
            "This file is not a web archive TextMouth can read. It may be damaged, or another kind of file."
        )
    }

    // MARK: Shapes That Are Not Archives

    /// Asserts that `bytes` is refused as not a web archive.
    private func assertNotAnArchive(_ bytes: Data, line: UInt = #line) {
        XCTAssertThrowsError(try page(bytes), line: line) { error in
            XCTAssertEqual(error as? WebArchiveReader.Failure, .notAWebArchive, line: line)
        }
    }

    func testBytesThatAreNotAPropertyListAreNotAnArchive() {
        assertNotAnArchive(Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00]))
    }

    func testAPropertyListThatIsAnArrayIsNotAnArchive() throws {
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["a", "b"], format: .binary, options: 0)
        assertNotAnArchive(bytes)
    }

    func testADictionaryWithoutAMainResourceIsNotAnArchive() throws {
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["WebSubresources": []], format: .binary, options: 0)
        assertNotAnArchive(bytes)
    }

    func testAMainResourceWithoutDataIsNotAnArchive() throws {
        assertNotAnArchive(try archive(data: nil))
    }

    // MARK: Nothing Else Is Read

    func testSubresourcesAndSubframesAreNotPartOfTheText() throws {
        let subresources: [[String: Any]] = [[
            "WebResourceData": Data(repeating: 0x41, count: 2_000_000),
            "WebResourceMIMEType": "image/png",
            "WebResourceURL": "https://example.invalid/big.png"
        ]]
        let subframes: [[String: Any]] = [[
            "WebMainResource": [
                "WebResourceData": Data("<h1>Frame</h1>".utf8),
                "WebResourceMIMEType": "text/html"
            ] as [String: Any]
        ]]
        let bytes = try archive(
            data: Data("<h1>Main</h1>".utf8),
            extra: ["WebSubresources": subresources, "WebSubframeArchives": subframes]
        )
        XCTAssertEqual(try page(bytes).text, "<h1>Main</h1>")
    }

    func testAnXMLPropertyListReadsAsABinaryOneDoes() throws {
        let binary = try page(archive(format: .binary))
        let xml = try page(archive(format: .xml))
        XCTAssertEqual(xml, binary)
        XCTAssertEqual(xml.text, "<h1>Title</h1>")
    }

    // MARK: Empty and Large Files

    func testAnEmptyFileHasNoTextToRead() throws {
        let url = try file(Data())
        XCTAssertThrowsError(try WebArchiveReader.mainPage(of: url)) { error in
            guard case FileImportError.noTextToRead = error else { return XCTFail("Expected noTextToRead, got \(error)") }
            XCTAssertEqual(error.localizedDescription, "This file has no text to read.")
        }
    }

    func testAnEmptyMainResourceHasNoTextToRead() throws {
        let bytes = try archive(data: Data())
        XCTAssertThrowsError(try page(bytes)) { error in
            guard case FileImportError.noTextToRead = error else { return XCTFail("Expected noTextToRead, got \(error)") }
            XCTAssertEqual(error.localizedDescription, "This file has no text to read.")
        }
    }

    func testAFilePastTheLimitIsRefusedBeforeItIsRead() throws {
        let url = try file(try archive())
        // Read under a bound limit, keeping the outcome as a value so the
        // bound operation itself cannot throw.
        let outcome = DocumentByteLimit.$current.withValue(16) {
            Result { try WebArchiveReader.mainPage(of: url) }
        }
        XCTAssertThrowsError(try outcome.get()) { error in
            XCTAssertEqual(error as? DocumentTooLargeError, DocumentTooLargeError(limit: 16))
        }
    }
}
