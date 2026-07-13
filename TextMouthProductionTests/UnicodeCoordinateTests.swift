import XCTest
@testable import TextMouth

final class UnicodeCoordinateTests: XCTestCase {
    func testStringIndexUsesUTF16CoordinatesAndSnapsSafely() {
        let text = "A🙂 café"
        let afterEmoji = text.index(atUTF16Offset: 3)

        XCTAssertEqual(String(text[afterEmoji...]), " café")
        XCTAssertEqual(text.utf16Offset(of: afterEmoji), 3)
        XCTAssertEqual(text.utf16Length, (text as NSString).length)
    }

    func testDocumentOffsetsUseSameCoordinatesAsFoundationRanges() {
        let content = DocumentContent(
            title: "Unicode",
            author: "Test",
            chapters: [
                Chapter(text: "🙂a"),
                Chapter(text: "é")
            ]
        )

        XCTAssertEqual(content.chapterStartOffset(1), 3)
        XCTAssertEqual(content.totalCharacterCount, 4)
        XCTAssertEqual(content.location(forGlobalOffset: 3).chapterIndex, 1)
    }

    func testSearchReturnsSpeechCompatibleUTF16Offset() throws {
        let text = "x🙂CAFÉ"

        let plain = try BookTextSearch.ranges(in: text, query: "café", useRegex: false)
        let regex = try BookTextSearch.ranges(in: text, query: "CAFÉ", useRegex: true)

        XCTAssertEqual(plain, [NSRange(location: 3, length: 4)])
        XCTAssertEqual(regex, plain)
    }

    func testSubstitutionMapAccountsForSurrogatePairsInReplacement() {
        let service = TextSubstitutionService(rules: [
            SubstitutionRule(pattern: "cat", replacement: "🐈", caseSensitive: true)
        ])

        let result = service.transform("🙂 cat")

        XCTAssertEqual(result.modifiedText, "🙂 🐈")
        XCTAssertEqual(result.modifiedText.utf16Length, 5)
        XCTAssertEqual(result.toOriginalOffset(5), 6)
        XCTAssertEqual(result.toModifiedOffset(6), 5)
    }
}
