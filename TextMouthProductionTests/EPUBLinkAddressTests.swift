import XCTest
@testable import TextMouth

/// How a link's address becomes one EPUB's validator accepts (B5): what is
/// percent-encoded, and what cannot be made a URL and is left as words.
final class EPUBLinkAddressTests: XCTestCase {

    /// Addresses that become URLs, and the URL each becomes: the review's
    /// real shapes (a space, a bar, a second "#", brackets, braces), a
    /// quote, letters beyond ASCII, white space around, and an upper-case scheme.
    func testAddressesThatCanBeEncodedAreEncoded() {
        let cases: [(String, String)] = [
            ("https://example.com/My Report 2024.pdf", "https://example.com/My%20Report%202024.pdf"),
            ("https://fonts.googleapis.com/css?family=Open+Sans|Roboto", "https://fonts.googleapis.com/css?family=Open+Sans%7CRoboto"),
            ("https://example.com/#/page#section", "https://example.com/#/page%23section"),
            ("https://example.com/?a[]=1&a[]=2", "https://example.com/?a%5B%5D=1&a%5B%5D=2"),
            ("https://example.com/{id}/x", "https://example.com/%7Bid%7D/x"),
            ("https://example.com/a\"b", "https://example.com/a%22b"),
            ("https://example.com/^`{}", "https://example.com/%5E%60%7B%7D"),
            ("https://example.com/\u{FC}", "https://example.com/%C3%BC"),
            ("http://example.com/a%zz", "http://example.com/a%25zz"),
            ("http://example.com/a%41", "http://example.com/a%41"),
            ("  https://example.com/  ", "https://example.com/"),
            ("HTTP://EXAMPLE.COM/", "http://EXAMPLE.COM/"),
            ("https://example.com:8080/x", "https://example.com:8080/x"),
            ("https://user:pw@example.com/", "https://user:pw@example.com/"),
            ("http://[::1]:80/", "http://[::1]:80/"),
            ("https://example.com", "https://example.com"),
            ("https://example.com/a?b=1&c=2#frag", "https://example.com/a?b=1&c=2#frag"),
            ("mailto:a@example.com", "mailto:a@example.com"),
            ("mailto:a b@example.com", "mailto:a%20b@example.com"),
            ("mailto:a@example.com?subject=Hi%20there&body=x", "mailto:a@example.com?subject=Hi%20there&body=x"),
        ]
        for (address, expected) in cases {
            XCTAssertEqual(EPUBLinkAddress.url(from: address), expected, address)
        }
    }

    /// Addresses that are not URLs once everything encodable is encoded: no
    /// host, a host that is not letters, digits, dots, and hyphens, a port
    /// that is no number, an empty mail address, or another scheme.
    func testAddressesThatCannotBeURLsAreLeftAsWords() {
        for address in [
            "https://", "http:", "mailto:", "http:///path", "http:javascript:alert(1)",
            "http://example.com:port/", "http://example.com:123456/", "http://example.com:/",
            "http://[::1", "http://[]/", "http://exam\\ple.com", "http://exa mple.com/a b",
            "https://\u{FF45}xample.com/", "https://\u{E9}.example/\u{FC}", "https://exa<mple.com/",
            "javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "#a", "other.xhtml#a", "", "   ",
        ] {
            XCTAssertNil(EPUBLinkAddress.url(from: address), address.debugDescription)
        }
    }

    /// Whatever the address, what comes out is a valid URL's characters only:
    /// no space, quote, angle bracket, backslash, caret, backtick, brace, bar,
    /// or control character, at most one "#", and no bracket outside a host.
    func testWhatComesOutHoldsOnlyURLCharacters() {
        let hostile = [
            "https://example.com/\u{1}\u{7F}\u{80}\u{A0}\u{2028}x y\ttab\nnewline",
            "https://example.com/<script>alert(1)</script>",
            "https://example.com/?q=\"a\"&r='b'#c#d#e",
            "https://example.com/[x][y]",
            "mailto:\"a b\"@example.com#x#y",
            "https://example.com/\u{1F600}\u{200D}\u{1F4BB}",
        ]
        for address in hostile {
            guard let url = EPUBLinkAddress.url(from: address) else { continue }
            XCTAssertNil(url.range(of: "[\\s\"<>\\\\^`{|}\\[\\]\\u0000-\\u001F\\u007F-\\uFFFF]", options: .regularExpression), url)
            XCTAssertLessThanOrEqual(url.filter { $0 == "#" }.count, 1, url)
        }
    }
}
