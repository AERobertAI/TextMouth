import XCTest
@testable import TextMouth

/// The HTML writer (FMT18) and the XML escaping every XML writer shares.
///
/// The documents are built by hand, with the ids the walker would make, so
/// these tests stand beside the walker's. Every page a test makes goes
/// through `page(of:)`, which fails the test unless an XML parser accepts it.
final class HTMLExportWriterTests: XCTestCase {

    // MARK: - XMLEscaping

    /// Text escapes `&`, `<`, and `>`, and leaves quotes and white space.
    func testTextEscapesTheThreeMarkupCharacters() {
        XCTAssertEqual(XMLEscaping.text("a & b < c > d"), "a &amp; b &lt; c &gt; d")
        XCTAssertEqual(XMLEscaping.text("say \"hi\"\tnow\r\nplease"), "say \"hi\"\tnow\r\nplease")
    }

    /// An attribute also escapes the quote, tab, line feed, and carriage return.
    func testAttributeEscapesQuotesAndWhiteSpace() {
        XCTAssertEqual(XMLEscaping.attribute("a & b < c > d \"e\""), "a &amp; b &lt; c &gt; d &quot;e&quot;")
        XCTAssertEqual(XMLEscaping.attribute("a\tb\nc\rd"), "a&#9;b&#10;c&#13;d")
    }

    /// "\r\n" is one Character, and still two escapes in an attribute.
    func testAttributeEscapesACarriageReturnLineFeedPair() {
        XCTAssertEqual(XMLEscaping.attribute("x\r\ny"), "x&#13;&#10;y")
    }

    /// Every scalar XML 1.0 forbids is left out of both; its neighbours stay.
    func testEveryForbiddenScalarIsLeftOut() {
        let forbidden: [UInt32] = Array(0x00...0x08) + [0x0B, 0x0C] + Array(0x0E...0x1F) + [0xFFFE, 0xFFFF]
        for value in forbidden {
            guard let scalar = Unicode.Scalar(value) else {
                XCTFail("U+\(String(value, radix: 16)) is not a scalar")
                continue
            }
            let input = "a\(Character(scalar))b"
            XCTAssertEqual(XMLEscaping.text(input), "ab", "U+\(String(value, radix: 16)) in text")
            XCTAssertEqual(XMLEscaping.attribute(input), "ab", "U+\(String(value, radix: 16)) in an attribute")
        }
        // The white space XML allows, and the scalars next to the forbidden ranges, stay.
        XCTAssertEqual(XMLEscaping.text("\t\n\r\u{20}\u{7F}\u{FFFD}"), "\t\n\r\u{20}\u{7F}\u{FFFD}")
    }

    /// An emoji, with its joiners and modifiers, passes through whole.
    func testAnEmojiIsKeptWhole() {
        let emoji = "I \u{1F469}\u{200D}\u{1F4BB} & \u{1F44D}\u{1F3FD} e\u{301}"
        XCTAssertEqual(XMLEscaping.text(emoji), "I \u{1F469}\u{200D}\u{1F4BB} &amp; \u{1F44D}\u{1F3FD} e\u{301}")
        XCTAssertEqual(XMLEscaping.attribute(emoji), XMLEscaping.text(emoji))
    }
}
