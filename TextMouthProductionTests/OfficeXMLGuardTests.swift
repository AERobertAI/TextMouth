import XCTest
import ZIPFoundation
@testable import TextMouth

/// What the readers of OpenDocument and Word 2003 XML refuse before
/// `XMLParser` sees a part (`XMLInputGuard`), what they do about the
/// hazards a part at the size limit could hold (scaled to what a test can
/// build: each takes seconds at most where it took minutes or hours), the
/// encodings a part may be in, and the cancelling of an import.
final class OfficeXMLGuardTests: XCTestCase {

    // MARK: - Helpers

    /// The longest any one hostile read may take, in a debug build.
    private let allowedSeconds = 10.0

    /// Reads the OpenDocument package holding `content` as its `content.xml`,
    /// and returns its HTML or the error; fails the test if it took too long.
    private func read(_ content: Data, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws -> Result<String, Error> {
        let url = try makeODT(entries: [
            TestZIPEntry("mimetype", Data("application/vnd.oasis.opendocument.text".utf8)),
            TestZIPEntry("content.xml", content),
        ], compression: .deflate)
        let start = Date()
        let result = Result { try ODTDocumentReader.html(of: url, includesPages: false) }
        XCTAssertLessThan(Date().timeIntervalSince(start), allowedSeconds, "\(label) took too long", file: file, line: line)
        return result
    }

    /// A `content.xml` in UTF-8 with `prolog` before its root and `body` as its text.
    private func content(prolog: String = "", namespaces: String = "", body: String) -> String {
        "<?xml version=\"1.0\"?>\(prolog)<office:document-content \(Self.odfNamespaces) \(namespaces)>"
            + "<office:body><office:text>\(body)</office:text></office:body></office:document-content>"
    }

    private func assertRefused(_ result: Result<String, Error>, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let error) = result else { return XCTFail("\(label) was read", file: file, line: line) }
        XCTAssertEqual(error as? TextutilConverter.Failure, .unreadable(.odt), label, file: file, line: line)
    }

    private func words(_ result: Result<String, Error>, _ label: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        switch result {
        case .success(let html): return odfPlainText(html)
        case .failure(let error):
            XCTFail("\(label) was refused: \(error)", file: file, line: line)
            return nil
        }
    }

    // MARK: - Escaping

    /// Escaping a text of millions of ampersands takes time in proportion to
    /// its length (it once took the square of it: 12.8 million took hours).
    func testEscapingIsLinear() {
        let start = Date()
        let escaped = XMLEscaping.text(String(repeating: "&", count: 2_000_000))
        XCTAssertEqual(escaped.utf8.count, 5 * 2_000_000)
        XCTAssertEqual(XMLEscaping.attribute(String(repeating: "\"", count: 1_000_000)).utf8.count, 6 * 1_000_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), allowedSeconds)
    }

    /// A paragraph of two million ampersands in `content.xml` is read (it
    /// escapes into the HTML) in seconds.
    func testAnAmpersandFloodIsReadInSeconds() throws {
        let flood = String(repeating: "&amp;", count: 2_000_000)
        let result = try read(Data(content(body: "<text:p>\(flood)</text:p>").utf8), "an ampersand flood")
        guard case .success(let html) = result else { return XCTFail("the flood was refused") }
        XCTAssertGreaterThan(html.utf8.count, 5 * 2_000_000)
    }

    // MARK: - The namespaces

    /// A root that declares thousands of prefixes and a hundred thousand
    /// elements that each declare one again is read in seconds (it once
    /// copied the whole table for each element).
    func testAFloodOfNamespaceDeclarationsIsReadInSeconds() throws {
        let prefixes = (0..<2_000).map { "xmlns:p\($0)=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\"" }.joined(separator: " ")
        let flood = String(repeating: "<q xmlns:p0=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\"/>", count: 100_000)
        let result = try read(Data(content(namespaces: prefixes, body: flood + "<text:p>after</text:p>").utf8), "a namespace flood")
        XCTAssertEqual(words(result, "a namespace flood"), "after")
    }

    /// A declaration lasts only as long as its element: a prefix bound to
    /// the text namespace inside one element is not bound after it.
    func testADeclarationLastsOnlyAsLongAsItsElement() throws {
        let body = """
            <t:p xmlns:t="urn:oasis:names:tc:opendocument:xmlns:text:1.0">Inside</t:p><t:p>Outside</t:p><text:p>Usual</text:p>
            """
        let result = try read(Data(content(body: body).utf8), "scoped prefix")
        XCTAssertEqual(words(result, "scoped prefix"), "Inside Usual")
    }

    // MARK: - Start tags

    /// A start tag of more than a megabyte is refused; one a little shorter
    /// (a long attribute value is not a hostile tag) is read.
    func testAStartTagOverAMegabyteIsRefused() throws {
        let long = content(namespaces: "a=\"" + String(repeating: "x", count: 1_100_000) + "\"", body: "<text:p>words</text:p>")
        assertRefused(try read(Data(long.utf8), "a long start tag"), "a long start tag")
        let shorter = content(body: "<text:p>words<text:span a='" + String(repeating: ">", count: 900_000) + "'>fine</text:span></text:p>")
        XCTAssertEqual(words(try read(Data(shorter.utf8), "a long attribute"), "a long attribute"), "wordsfine")
    }

    /// 200,000 attributes in one start tag are refused before the parser
    /// reads them (it took seventeen seconds, and minutes at the limit).
    func testAStartTagOfManyAttributesIsRefused() throws {
        let attributes = (0..<200_000).map { "a\($0)=\"\"" }.joined(separator: " ")
        let result = try read(Data(content(body: "<text:p \(attributes)>words</text:p>").utf8), "many attributes")
        assertRefused(result, "many attributes")
    }

    // MARK: - Document types

    /// A document type declaration is refused in the prolog, in every
    /// encoding a part can have; the guard reads the prolog's bytes.
    func testADocumentTypeIsFoundInEveryEncoding() throws {
        let declaration = "<?xml version=\"1.0\"?><!DOCTYPE d [<!ENTITY e \"x\">]><d>&e;</d>"
        let encodings: [(String, Data?)] = [
            ("UTF-8", declaration.data(using: .utf8)),
            ("Latin-1", declaration.data(using: .isoLatin1)),
            ("UTF-16 with a mark", declaration.data(using: .utf16)),
            ("UTF-16 little-endian", declaration.data(using: .utf16LittleEndian)),
            ("UTF-16 big-endian", declaration.data(using: .utf16BigEndian)),
            ("UTF-32 little-endian", declaration.data(using: .utf32LittleEndian)),
            ("UTF-32 big-endian", declaration.data(using: .utf32BigEndian)),
            ("UTF-8 with a mark", Data([0xEF, 0xBB, 0xBF]) + Data(declaration.utf8)),
        ]
        for (name, data) in encodings {
            XCTAssertTrue(XMLInputGuard.declaresDocumentType(try XCTUnwrap(data, name)), name)
        }
        // And a whole package whose part is in UTF-16 is refused, not read
        // with the entity's reference dropped.
        let entity = String(repeating: "x", count: 1_000)
        let attack = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE d [<!ENTITY e \"\(entity)\">]>"
            + "<office:document-content \(Self.odfNamespaces)><office:body><office:text><text:p>&e;&e;&e;</text:p>"
            + "</office:text></office:body></office:document-content>"
        assertRefused(try read(try XCTUnwrap(attack.data(using: .utf16)), "a UTF-16 entity"), "a UTF-16 entity")
    }

    /// `<!DOCTYPE` and `<!ENTITY` in a comment, a CDATA section, a processing
    /// instruction, or text are no declaration, and the document reads.
    func testWhatLooksLikeADocumentTypeButIsNotIsRead() throws {
        let cases: [(String, String, String)] = [
            ("a comment in the prolog", "<!-- <!DOCTYPE d [<!ENTITY e 'x'>]> -->", "plain"),
            ("a processing instruction", "<?target <!DOCTYPE d> ?>", "plain"),
            ("a CDATA section", "", "<![CDATA[<!DOCTYPE d [<!ENTITY e 'x'>]>]]>"),
            ("a comment in the body", "", "<!-- <!DOCTYPE html> --><!-- <!ENTITY x> -->plain"),
            ("an escaped declaration", "", "&lt;!DOCTYPE d&gt;"),
        ]
        for (label, prolog, text) in cases {
            let result = try read(Data(content(prolog: prolog, body: "<text:p>\(text)</text:p>").utf8), label)
            XCTAssertNotNil(words(result, label), label)
        }
        let cdata = try read(Data(content(body: "<text:p><![CDATA[<!DOCTYPE html>]]> words</text:p>").utf8), "cdata")
        XCTAssertEqual(words(cdata, "cdata"), "&lt;!DOCTYPE html&gt; words")
    }

    // MARK: - Encodings

    /// Parts in UTF-16 (with a byte-order mark, and without one in either
    /// byte order) are read.
    func testPartsInUTF16AreRead() throws {
        let text = content(body: "<text:p>caf\u{E9} utf sixteen</text:p>")
        for (name, data) in [
            ("with a mark", text.data(using: .utf16)),
            ("little-endian", text.replacingOccurrences(of: "version=\"1.0\"", with: "version=\"1.0\" encoding=\"UTF-16LE\"").data(using: .utf16LittleEndian)),
            ("big-endian", text.replacingOccurrences(of: "version=\"1.0\"", with: "version=\"1.0\" encoding=\"UTF-16BE\"").data(using: .utf16BigEndian)),
        ] {
            let result = try read(try XCTUnwrap(data, name), name)
            XCTAssertEqual(words(result, name), "caf\u{E9} utf sixteen", name)
        }
    }

    // MARK: - Cancel

    /// A read inside an import that was cancelled stops at the next check
    /// (every few thousand elements) with `ImportCancelled`; one inside an
    /// import that was not, or outside any import, reads.
    func testACancelledImportStopsTheRead() throws {
        let body = String(repeating: "<text:p>w</text:p>", count: 20_000)
        let url = try makeODT(content: content(body: body), compression: .deflate)
        let cancelled = ImportCancellation()
        cancelled.cancel()
        try ImportCancellation.$current.withValue(cancelled) {
            XCTAssertThrowsError(try ODTDocumentReader.html(of: url, includesPages: false)) {
                XCTAssertEqual($0 as? ImportCancelled, ImportCancelled())
            }
        }
        try ImportCancellation.$current.withValue(ImportCancellation()) {
            XCTAssertNoThrow(try ODTDocumentReader.html(of: url, includesPages: false))
        }
        XCTAssertNoThrow(try ODTDocumentReader.html(of: url, includesPages: false))
    }
}
