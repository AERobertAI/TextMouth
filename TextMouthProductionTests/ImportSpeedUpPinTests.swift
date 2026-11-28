import XCTest
@testable import TextMouth

// MARK: - What the Import Speed-Ups Must Not Change

/// Pins two behaviors that the November 14, 2026 import speed-ups (H2, H3)
/// rewrote, written before the rewrite and passing before and after it: the
/// name an element has with its namespace prefix taken off, and the line
/// ending normalization every text file passes through.
final class ImportSpeedUpPinTests: XCTestCase {

    /// `text` held as Foundation holds a string, not as contiguous UTF-8.
    private func bridged(_ text: String) -> String {
        (text as NSString) as String
    }

    // MARK: - The prefix of an element's name

    /// The name after the last colon, as `components(separatedBy: ":").last`
    /// gives it: for a name with none, with one, with several, with the
    /// colon first or last, and with characters beyond ASCII.
    func testANamespacePrefixIsStrippedAsItAlwaysWas() {
        let names = [
            "", ":", "::", "title", "dc:title", "opf:item", "a:b:c", ":x", "x:", "w:t", "xml:lang", "\u{E9}:\u{E8}", "a:\u{0301}b",
            "a\u{0301}:b", "\u{6F22}:\u{5B57}", "dc:\u{1F600}", "w:p:", "https:",
        ]
        for name in names {
            let expected = name.components(separatedBy: ":").last ?? name
            XCTAssertEqual(ParserUtilities.stripNamespacePrefix(name), expected, "\(name.debugDescription)")
            XCTAssertEqual(ParserUtilities.stripNamespacePrefix(bridged(name)), expected, "bridged \(name.debugDescription)")
        }
        XCTAssertEqual(ParserUtilities.stripNamespacePrefix("dc:title"), "title")
        XCTAssertEqual(ParserUtilities.stripNamespacePrefix("title"), "title")
        XCTAssertEqual(ParserUtilities.stripNamespacePrefix("a:b:c"), "c")
        XCTAssertEqual(ParserUtilities.stripNamespacePrefix("x:"), "")
    }

    // MARK: - Line endings

    /// The reader's line ending normalization keeps its rules: a text with no
    /// carriage return comes back as it is; CR LF is one line feed; a lone CR
    /// is a line feed wherever it stands; the other line-ending characters
    /// are left alone.
    func testLineEndingsAreNormalizedAsTheyAlwaysWere() {
        let cases: [(input: String, normalized: String)] = [
            ("", ""), ("plain\nlines\n", "plain\nlines\n"), ("a\r\nb\r\n", "a\nb\n"), ("a\rb", "a\nb"), ("a\r", "a\n"), ("\r", "\n"),
            ("a\r\rb", "a\n\nb"), ("a\r\r\nb", "a\n\nb"), ("\r\n", "\n"), ("\u{E9}\r\u{E9}", "\u{E9}\n\u{E9}"),
            ("a\u{85}b\u{2028}c\u{0C}d\r\ne", "a\u{85}b\u{2028}c\u{0C}d\ne"), ("x\u{0301}\r\ny", "x\u{0301}\ny"),
        ]
        for (input, normalized) in cases {
            XCTAssertEqual(TextFileDecoder.normalizingLineEndings(input), normalized, "\(Array(input.unicodeScalars))")
            XCTAssertEqual(TextFileDecoder.normalizingLineEndings(bridged(input)), normalized, "bridged \(Array(input.unicodeScalars))")
        }
        // A long text with its only carriage return at the very end.
        let long = String(repeating: "line\n", count: 20_000)
        XCTAssertEqual(TextFileDecoder.normalizingLineEndings(long), long)
        XCTAssertEqual(TextFileDecoder.normalizingLineEndings(long + "\r"), long + "\n")
    }
}
