import XCTest
@testable import TextMouth

// MARK: - Headings by Size: the Census and the Length Test

/// Pins `RTFSizeHeadings` at the two places its speed was changed (the
/// November 14, 2026 import speed-up, H1): the count of characters that are
/// not white space, by size, which decides the body size; and the length
/// test, which decides whether a paragraph is short enough to be a heading.
///
/// The speed-up must leave every answer as it was, so these cases sit at the
/// edges: 120 and 121 characters, runs of white space of every kind, text
/// with accents, and white space the first and last bytes of a long text.
final class RTFSizeHeadingsTests: XCTestCase {

    // MARK: - Helpers

    /// A paragraph of one run of `text` at `size` (half points), not bold.
    private func paragraph(_ text: String, size: Int, bold: Bool = false) -> RTFParagraph {
        RTFParagraph(inlines: [.text(text, bold: bold, italic: false, size: size)])
    }

    /// A body paragraph at size 24 with 3,200 letters, so the body size is 24
    /// whatever the paragraphs under test hold.
    private var bodyBlock: RTFBlock {
        .paragraph(paragraph(String(repeating: "body ", count: 800), size: 24))
    }

    /// Text whose white-space-collapsed length is exactly `length`
    /// characters: words of four letters, the last one longer. `length`
    /// must be at least 6.
    private func label(ofLength length: Int) -> String {
        var text = ""
        while length - text.count > 10 { text += "abcd " }
        return text + String(repeating: "x", count: length - text.count)
    }

    /// The levels `apply` gave, one per block: 0 for a block that stayed a
    /// paragraph (or a list item or table), otherwise the heading's level.
    private func levels(_ blocks: [RTFBlock]) -> [Int] {
        RTFSizeHeadings.apply(to: blocks).map { block in
            if case .heading(_, let level) = block { return level }
            return 0
        }
    }

    // MARK: - The length test

    /// A paragraph of 120 characters can be a heading; one of 121 cannot.
    func testHeadingLengthStopsAtOneHundredTwentyCharacters() {
        let blocks: [RTFBlock] = [
            bodyBlock,
            .paragraph(paragraph(label(ofLength: 120), size: 36)),
            .paragraph(paragraph(label(ofLength: 121), size: 36)),
        ]
        XCTAssertEqual(levels(blocks), [0, 1, 0])
    }

    /// The length is of the words joined by one space: runs of white space of
    /// any kind, at the edges too, add nothing.
    func testHeadingLengthIgnoresRunsOfWhiteSpace() {
        let spread = label(ofLength: 120).replacingOccurrences(of: " ", with: " \t \u{00A0}\u{3000}\r\n  ")
        let padded = "   \n" + label(ofLength: 120) + "\u{2003}  "
        let tooLong = label(ofLength: 121).replacingOccurrences(of: " ", with: "   ")
        let blocks: [RTFBlock] = [
            bodyBlock,
            .paragraph(paragraph(spread, size: 36)),
            .paragraph(paragraph(padded, size: 36)),
            .paragraph(paragraph(tooLong, size: 36)),
        ]
        XCTAssertEqual(levels(blocks), [0, 1, 1, 0])
    }

    /// A paragraph that begins with far more white space than a heading's
    /// length (the case a quick look at its first bytes cannot settle) is
    /// judged by its words.
    func testHeadingLengthOfAParagraphThatBeginsWithAPageOfWhiteSpace() {
        let blocks: [RTFBlock] = [
            bodyBlock,
            .paragraph(paragraph(String(repeating: " ", count: 900) + "Title", size: 36)),
            .paragraph(paragraph("Short" + String(repeating: "\n", count: 900) + label(ofLength: 130), size: 36)),
            .paragraph(paragraph(String(repeating: "\n", count: 900) + label(ofLength: 121), size: 36)),
        ]
        XCTAssertEqual(levels(blocks), [0, 1, 0, 0])
    }

    /// The characters counted are Characters: an accent is part of its
    /// letter, so 120 accented letters are 120 characters long, though each
    /// is two or three bytes, and 121 are too many.
    func testHeadingLengthCountsCharactersNotBytes() {
        let accented = "e\u{0301}"
        let blocks: [RTFBlock] = [
            bodyBlock,
            .paragraph(paragraph(String(repeating: accented, count: 120), size: 36)),
            .paragraph(paragraph(String(repeating: accented, count: 121), size: 36)),
            .paragraph(paragraph(String(repeating: "\u{6F22}", count: 120), size: 36)),
            .paragraph(paragraph(String(repeating: "\u{6F22}", count: 121), size: 36)),
            .paragraph(paragraph(String(repeating: "\u{1F600}", count: 120), size: 36)),
            .paragraph(paragraph(String(repeating: "\u{1F600}", count: 121), size: 36)),
        ]
        XCTAssertEqual(levels(blocks), [0, 1, 0, 1, 0, 1, 0])
    }

    /// A line break and the run after it count as words with a space between.
    func testHeadingLengthCountsALineBreakAsASpace() {
        let first = label(ofLength: 60)
        let second = label(ofLength: 59)
        let fits = RTFParagraph(inlines: [
            .text(first, bold: false, italic: false, size: 36), .lineBreak, .text(second, bold: false, italic: false, size: 36),
        ])
        let over = RTFParagraph(inlines: [
            .text(first, bold: false, italic: false, size: 36), .lineBreak, .text(second + "y", bold: false, italic: false, size: 36),
        ])
        XCTAssertEqual(levels([bodyBlock, .paragraph(fits), .paragraph(over)]), [0, 1, 0])
    }

    /// A single letter, with or without an accent, is a decorative initial,
    /// not a heading; a single digit may be one.
    func testASingleLetterIsNotAHeadingButADigitIs() {
        let blocks: [RTFBlock] = [
            bodyBlock,
            .paragraph(paragraph("X", size: 36)),
            .paragraph(paragraph(" \n 7 \n", size: 36)),
            .paragraph(paragraph("\u{00E9}", size: 36)),
        ]
        XCTAssertEqual(levels(blocks), [0, 0, 1, 0])
    }

    // MARK: - The census

    /// White space is not counted, in any of its forms, so the body size is
    /// the size with the most letters: here 20 (five letters) and not 24
    /// (four letters between a great deal of white space).
    func testTheCensusCountsNoWhiteSpace() {
        let spaces = String(repeating: " ", count: 40) + String(repeating: "\u{00A0}", count: 40)
            + String(repeating: "\u{3000}", count: 40) + "\r\n\r\n\t\u{000B}\u{000C}\u{0085}\u{2028}\u{2029}"
        let blocks: [RTFBlock] = [
            .paragraph(paragraph("wo" + spaces + "rd", size: 24)),
            .paragraph(paragraph("abcde", size: 20)),
        ]
        XCTAssertEqual(levels(blocks), [1, 0])
    }

    /// Letters with accents, Chinese characters, and emoji are each one
    /// character: the size of five of them outweighs the size of four ASCII
    /// letters, where counting bytes would say the opposite.
    func testTheCensusCountsCharactersNotBytes() {
        let blocks: [RTFBlock] = [
            .paragraph(paragraph("abcd", size: 24)),
            .paragraph(paragraph("e\u{0301}e\u{0301}e\u{0301}e\u{0301}e\u{0301}", size: 20)),
        ]
        // The accented size (20) is the body: 5 characters against 4.
        XCTAssertEqual(levels(blocks), [1, 0])
        let wide: [RTFBlock] = [
            .paragraph(paragraph("abcdef", size: 24)),
            .paragraph(paragraph("\u{6F22}\u{6F22}\u{6F22}\u{6F22}\u{6F22}", size: 20)),
        ]
        // 6 against 5: size 24 is the body, size 20 is smaller, no heading.
        XCTAssertEqual(levels(wide), [0, 0])
        let emoji: [RTFBlock] = [
            .paragraph(paragraph("abcd", size: 24)),
            .paragraph(paragraph(String(repeating: "\u{1F600}", count: 5), size: 20)),
        ]
        XCTAssertEqual(levels(emoji), [1, 0])
    }

    /// A run that is mostly ASCII with one accented letter is counted the
    /// same as the letters it holds: five here, so size 20 is the body.
    func testTheCensusCountsAMixedRun() {
        let blocks: [RTFBlock] = [
            .paragraph(paragraph("abcd", size: 24)),
            .paragraph(paragraph("ab c\u{00E9} d", size: 20)),
        ]
        XCTAssertEqual(levels(blocks), [1, 0])
    }

    // MARK: - Against the way it was counted

    /// The characters of `text` that are not white space, counted as the
    /// census once counted them: Character by Character.
    private func referenceCount(_ text: String) -> Int {
        text.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
    }

    /// Whether `paragraph` is short enough to be a heading, as it was once
    /// decided: the whole text split at white space, joined, and counted.
    private func referenceIsHeadingLength(_ paragraph: RTFParagraph) -> Bool {
        let label = paragraph.plainText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !label.isEmpty, label.count <= 120 else { return false }
        return !(label.count == 1 && label.first?.isLetter == true)
    }

    /// A fixed list of the pieces random text is made of: ASCII letters,
    /// every kind of white space, marks that join a letter, letters of other
    /// scripts, and a character that takes four bytes.
    private let pieces: [String] = [
        "a", "b", "word", " ", " ", "  ", "\t", "\n", "\r\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{A0}", "\u{2003}",
        "\u{2028}", "\u{3000}", "\u{0301}", "\u{E9}", "e\u{0301}", "\u{6F22}", "\u{1F600}", "\u{200D}", "\u{FEFF}", "\u{0}", "1",
    ]

    /// A text of `count` pieces, chosen by `generator` (a fixed sequence, so
    /// a failure repeats).
    private func randomText(pieces count: Int, _ generator: inout KFXSeededGenerator) -> String {
        (0..<count).map { _ in pieces.randomElement(using: &generator)! }.joined()
    }

    /// The count is what counting Characters gives for every ASCII byte
    /// alone, and for thousands of mixed texts.
    func testTheCensusMatchesCountingCharacters() {
        for value in 0..<128 {
            let text = String(UnicodeScalar(UInt8(value)))
            XCTAssertEqual(RTFSizeHeadings.nonWhitespaceCharacterCount(of: text), referenceCount(text), "byte \(value)")
        }
        var generator = KFXSeededGenerator(seed: 14)
        for _ in 0..<5_000 {
            let text = randomText(pieces: Int.random(in: 0...40, using: &generator), &generator)
            XCTAssertEqual(RTFSizeHeadings.nonWhitespaceCharacterCount(of: text), referenceCount(text), "\(Array(text.unicodeScalars))")
            // The same text held by Foundation, not as contiguous UTF-8.
            let bridged = (text as NSString) as String
            XCTAssertEqual(RTFSizeHeadings.nonWhitespaceCharacterCount(of: bridged), referenceCount(text))
        }
    }

    /// The length test is what splitting the whole text gives, for thousands
    /// of paragraphs of several runs, from empty to long enough that only
    /// their beginning is read.
    func testTheLengthTestMatchesSplittingTheWholeText() {
        var generator = KFXSeededGenerator(seed: 2026)
        for round in 0..<6_000 {
            var inlines: [RTFInline] = []
            // Every few paragraphs are far longer than a heading, with white
            // space run through them, so that the beginning decides.
            let runs = Int.random(in: 0...6, using: &generator)
            let size = round % 4 == 0 ? 200 : 25
            for _ in 0..<runs {
                if Int.random(in: 0..<8, using: &generator) == 0 {
                    inlines.append(Bool.random(using: &generator) ? .lineBreak : .pageBreak(2))
                } else {
                    let text = randomText(pieces: Int.random(in: 0...size, using: &generator), &generator)
                    inlines.append(.text(text, bold: false, italic: false, size: 24))
                }
            }
            let paragraph = RTFParagraph(inlines: inlines)
            XCTAssertEqual(
                RTFSizeHeadings.isHeadingLength(paragraph), referenceIsHeadingLength(paragraph),
                "\(inlines)"
            )
        }
    }

    /// The beginning is always the first part of the whole text, whole
    /// pieces of it, and the whole text when it stays short.
    func testTheBeginningOfAParagraphsTextIsItsFirstPart() {
        let paragraph = RTFParagraph(inlines: [
            .text("one ", bold: false, italic: false, size: 24), .lineBreak,
            .text("two", bold: true, italic: false, size: 24), .pageBreak(2),
            .text(" three", bold: false, italic: true, size: 24),
        ])
        XCTAssertEqual(paragraph.plainText, "one  two three")
        XCTAssertEqual(paragraph.plainText(stoppingAfter: 0), "one ")
        XCTAssertEqual(paragraph.plainText(stoppingAfter: 5), "one  ")
        XCTAssertEqual(paragraph.plainText(stoppingAfter: 6), "one  two")
        XCTAssertEqual(paragraph.plainText(stoppingAfter: 8), "one  two")
        XCTAssertEqual(paragraph.plainText(stoppingAfter: 100), paragraph.plainText)
        XCTAssertEqual(RTFParagraph().plainText(stoppingAfter: 0), "")
    }

    /// Bold is counted with the same census: bold text at the body size is a
    /// heading when the body is not mostly bold.
    func testBoldAtTheBodySizeIsAHeadingWhenTheBodyIsNotBold() {
        let blocks: [RTFBlock] = [
            bodyBlock,
            .paragraph(paragraph("Bold line", size: 24, bold: true)),
            .paragraph(paragraph("Bold with accents \u{00E9}\u{00E8}", size: 24, bold: true)),
        ]
        XCTAssertEqual(levels(blocks), [0, 1, 1])
    }
}
