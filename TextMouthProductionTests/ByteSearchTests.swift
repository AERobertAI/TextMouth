import XCTest
@testable import TextMouth

// MARK: - Searching for One Byte, and the Readers That Use It

/// The byte searches of the November 14, 2026 import speed-up (H2, H3): they
/// must answer exactly as walking the bytes (or splitting the Characters) one
/// by one answers, for every text, however it is stored.
final class ByteSearchTests: XCTestCase {

    // MARK: - Helpers

    /// Strings with the bytes the readers look for, and the ways they come:
    /// at the start, the middle, and the end; as part of a pair; beside
    /// multi-byte characters; or not at all.
    private let samples: [String] = [
        "", "a", "\n", "\r", "\u{1B}", "a\nb", "\na", "a\n", "\n\n", "a\r\nb", "\r\n", "\r\r\n", "a\rb", "no line ending",
        "\u{E9}\n\u{E9}", "\u{6F22}\r\u{6F22}", "\u{1F600}\u{1B}", "e\u{0301}\n", "\u{2028}", "\u{85}", "\u{0}\u{0}",
        String(repeating: "x", count: 10_000), String(repeating: "x", count: 10_000) + "\n",
        "\n" + String(repeating: "\u{E9}", count: 5_000), String(repeating: "\u{6F22}", count: 3_000) + "\r",
    ]

    /// The bytes the readers search for, and two they do not.
    private let bytes: [UInt8] = [0x0A, 0x0D, 0x1B, 0x0C, 0x3A, 0x00, 0xFF, 0xA9]

    /// `text` held as Foundation holds a string, not as contiguous UTF-8.
    private func bridged(_ text: String) -> String {
        (text as NSString) as String
    }

    // MARK: - The search

    /// The answer is the walk's, for every sample and byte, whether the
    /// string is native or bridged.
    func testAStringIsSearchedAsItsBytesAreWalked() {
        for text in samples {
            for byte in bytes {
                XCTAssertEqual(text.containsUTF8Byte(byte), text.utf8.contains(byte), "\(byte) in \(Array(text.unicodeScalars).prefix(8))")
                XCTAssertEqual(bridged(text).containsUTF8Byte(byte), text.utf8.contains(byte), "bridged \(byte)")
            }
        }
    }

    /// The same for data, whole, sliced (a slice's indices do not begin at
    /// zero), and empty.
    func testDataIsSearchedAsItsBytesAreWalked() {
        for text in samples {
            let data = Data(text.utf8)
            for byte in bytes {
                XCTAssertEqual(data.containsByte(byte), data.contains(byte), "\(byte)")
                // A slice that leaves out the first byte, and one that leaves out the last.
                let tail = data.dropFirst()
                let head = data.dropLast()
                XCTAssertEqual(tail.containsByte(byte), tail.contains(byte), "tail \(byte)")
                XCTAssertEqual(head.containsByte(byte), head.contains(byte), "head \(byte)")
            }
        }
        XCTAssertFalse(Data().containsByte(0))
        XCTAssertFalse(Data().containsByte(0x1B))
    }

    /// A byte only in the first place or only in the last of a long string is
    /// found, and one that is absent is not.
    func testTheFirstAndLastBytesOfALongTextAreSearched() {
        let middle = String(repeating: "abc", count: 40_000)
        XCTAssertTrue(("\u{1B}" + middle).containsUTF8Byte(0x1B))
        XCTAssertTrue((middle + "\u{1B}").containsUTF8Byte(0x1B))
        XCTAssertFalse(middle.containsUTF8Byte(0x1B))
        XCTAssertTrue(Data(("\r" + middle).utf8).containsByte(0x0D))
        XCTAssertTrue(Data((middle + "\r").utf8).containsByte(0x0D))
        XCTAssertFalse(Data(middle.utf8).containsByte(0x0D))
    }

    // MARK: - The split of a run at its line feeds

    /// The lines are the split's, kept empty ones and all; a carriage return
    /// and line feed together are one Character that is no line feed, so
    /// they split nothing.
    func testARunIsSplitAtItsLineFeedsAsItAlwaysWas() {
        for text in samples + ["x\u{0301}\ny", "a\u{200D}\nb", "\n\u{0301}"] {
            let expected = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(text.splitAtLineFeeds().map(String.init), expected, "\(Array(text.unicodeScalars).prefix(8))")
            XCTAssertEqual(bridged(text).splitAtLineFeeds().map(String.init), expected, "bridged")
        }
        // Spelled out: the cases that matter most.
        XCTAssertEqual("one line".splitAtLineFeeds().map(String.init), ["one line"])
        XCTAssertEqual("a\nb".splitAtLineFeeds().map(String.init), ["a", "b"])
        XCTAssertEqual("a\n".splitAtLineFeeds().map(String.init), ["a", ""])
        XCTAssertEqual("\na".splitAtLineFeeds().map(String.init), ["", "a"])
        XCTAssertEqual("a\r\nb".splitAtLineFeeds().map(String.init), ["a\r\nb"])
        XCTAssertEqual("".splitAtLineFeeds().map(String.init), [""])
    }
}
