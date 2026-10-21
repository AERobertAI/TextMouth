import Markdown
import XCTest
@testable import TextMouth

/// `MarkdownEmphasis` (October 21, 2026): a line of text whose characters
/// carry emphasis, written as Markdown that TextMouth's own reader reads
/// back as exactly those characters, with that emphasis. Every check here
/// reads the Markdown with swift-markdown, the parser the reader uses, so a
/// delimiter it would not pair, which a listener would hear as an asterisk,
/// fails a test. Hermetic: no helper, no library, no file.
final class MarkdownEmphasisTests: XCTestCase {
    typealias Style = MarkdownEmphasis.Style

    // MARK: - Helpers

    /// What swift-markdown reads from `markdown`: the text, and the style of
    /// each of its scalars from the emphasis and strong emphasis around it.
    private func read(_ markdown: String) -> (text: String, styles: [Style]) {
        var reader = StyleReader()
        reader.visit(Document(parsing: markdown))
        return (reader.text, reader.styles)
    }

    /// Asserts that `styles` on `text`, written and read back, give:
    /// - the text exactly, so no delimiter is ever read as an asterisk and
    ///   no character is lost;
    /// - no character more emphasis than it had;
    /// - each letter, digit, and mark its own style, unless its stretch of
    ///   one style touches another styled stretch letter to letter, which
    ///   the writer gives the style they share.
    private func assertReadsBack(
        _ text: String, _ styles: [Style],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let markdown = MarkdownEmphasis.markdown(text, styles: styles)
        let back = read(markdown)
        let context = "\(text.debugDescription) \(styles.map(\.rawValue)) as \(markdown.debugDescription)"
        XCTAssertEqual(back.text, text, context, file: file, line: line)
        guard back.text == text, back.styles.count == styles.count else { return }
        let scalars = Array(text.unicodeScalars)
        for index in scalars.indices {
            XCTAssertTrue(styles[index].isSuperset(of: back.styles[index]), "\(context) at \(index)", file: file, line: line)
            if MarkdownLiteral.isFlankingSafe(scalars[index]), !touchesAnotherStyle(index, in: scalars, styles) {
                XCTAssertEqual(back.styles[index], styles[index], "\(context) at \(index)", file: file, line: line)
            }
        }
    }

    /// Whether the stretch of one style around `index` touches another
    /// styled stretch letter to letter: its first scalar and the one before
    /// it, or its last and the one after it, are letters, digits, or marks,
    /// and the neighbour is styled. (Stretches of one style meet only scalars
    /// of other styles.)
    private func touchesAnotherStyle(_ index: Int, in scalars: [Unicode.Scalar], _ styles: [Style]) -> Bool {
        let safe = MarkdownLiteral.isFlankingSafe
        var start = index
        var end = index + 1
        while start > 0, styles[start - 1] == styles[index] { start -= 1 }
        while end < scalars.count, styles[end] == styles[index] { end += 1 }
        let before = start > 0 && safe(scalars[start]) && safe(scalars[start - 1]) && !styles[start - 1].isEmpty
        let after = end < scalars.count && safe(scalars[end - 1]) && safe(scalars[end]) && !styles[end].isEmpty
        return before || after
    }

    /// `count` styles: none, emphasis, strong, or both, from the base-4
    /// digits of `number`.
    private func styles(_ number: Int, count: Int) -> [Style] {
        var number = number
        return (0..<count).map { _ in
            defer { number /= 4 }
            return Style(rawValue: UInt8(number % 4))
        }
    }

    // MARK: - Writing

    /// Text with no style is a Markdown literal, as before emphasis: every
    /// ASCII punctuation character escaped. So is text whose styles do not
    /// number its scalars.
    func testTextWithNoStyleIsALiteral() {
        let text = "Plain *text* with_marks \\ and # signs."
        XCTAssertEqual(MarkdownEmphasis.markdown(text, styles: []), MarkdownLiteral.escaped(text))
        XCTAssertEqual(MarkdownEmphasis.markdown(text, styles: Array(repeating: [], count: text.unicodeScalars.count)), MarkdownLiteral.escaped(text))
        XCTAssertEqual(MarkdownEmphasis.markdown("abc", styles: [.emphasis]), "abc")
    }

    /// Emphasis is one asterisk on each side, strong two, both three.
    func testEachStyleHasItsDelimiters() {
        let styled: (Style) -> [Style] = { style in [[], [], style, style, style, [], [], [], []] }
        XCTAssertEqual(MarkdownEmphasis.markdown("a cat sat", styles: styled(.emphasis)), "a *cat* sat")
        XCTAssertEqual(MarkdownEmphasis.markdown("a cat sat", styles: styled(.strong)), "a **cat** sat")
        XCTAssertEqual(MarkdownEmphasis.markdown("a cat sat", styles: styled([.emphasis, .strong])), "a ***cat*** sat")
    }

    /// White space and punctuation at the ends of a styled stretch stay
    /// outside its delimiters, as the HTML converter writes them: "*Titanic*."
    /// rather than "*Titanic.*"; inside a stretch they stay inside.
    func testWhiteSpaceAndPunctuationAtTheEndsStayOutside() {
        let text = "\u{201C}Hello, world.\u{201D} she said"
        let styles = text.unicodeScalars.enumerated().map { $0.offset < 15 ? Style.emphasis : [] }
        XCTAssertEqual(MarkdownEmphasis.markdown(text, styles: styles), "\u{201C}*Hello\\, world*\\.\u{201D} she said")
    }

    /// The text's own asterisks, underscores, backslashes, and other ASCII
    /// punctuation are escaped, inside a styled stretch and out, so they are
    /// never read as formatting.
    func testMarkdownCharactersInTheTextAreEscaped() {
        let text = "a*b_c\\d [e](f) `g` #h"
        let all = Array(repeating: Style.strong, count: text.unicodeScalars.count)
        XCTAssertEqual(MarkdownEmphasis.markdown(text, styles: all), "**a\\*b\\_c\\\\d \\[e\\]\\(f\\) \\`g\\` \\#h**")
        assertReadsBack(text, all)
    }

    /// A styled stretch with no letter, digit, or mark has nothing a
    /// delimiter could stand beside, so it is written plain.
    func testAStretchWithNoLetterIsPlain() {
        let text = "a !?! b"
        let styles: [Style] = [[], [], .emphasis, .emphasis, .emphasis, [], []]
        XCTAssertEqual(MarkdownEmphasis.markdown(text, styles: styles), "a \\!\\?\\! b")
    }

    /// Inside a word, emphasis that begins and ends against unstyled letters
    /// is written as it is. Stretches whose emphasis changes straight to
    /// another, letter to letter, are written as one stretch in the emphasis
    /// they share, or none, since delimiter runs that meet are where
    /// CommonMark stops pairing them: the bold "a", both on "b", and italic
    /// "c" of the exhaustive test's first failure were read back with their
    /// asterisks before this rule.
    func testStretchesThatTouchShareTheirEmphasis() {
        let word = "unbelievable"
        let middle: [Style] = [[], []] + Array(repeating: .emphasis, count: 6) + [[], [], [], []]
        XCTAssertEqual(MarkdownEmphasis.markdown(word, styles: middle), "un*believ*able")

        let italicThenBold: [Style] = [.emphasis, .emphasis] + Array(repeating: .strong, count: 10)
        XCTAssertEqual(MarkdownEmphasis.markdown(word, styles: italicThenBold), "unbelievable")
        let boldThenBoth: [Style] = Array(repeating: .strong, count: 6) + Array(repeating: [.emphasis, .strong], count: 6)
        XCTAssertEqual(MarkdownEmphasis.markdown(word, styles: boldThenBoth), "**unbelievable**")
        let three: [Style] = [.strong, [.emphasis, .strong], .emphasis, [], []]
        XCTAssertEqual(MarkdownEmphasis.markdown("abcde", styles: three), "abcde")
        for styles in [middle, italicThenBold, boldThenBoth] { assertReadsBack(word, styles) }
        assertReadsBack("abcde", three)
    }

    // MARK: - Every Mix, Read by swift-markdown

    /// Every one of the 4^n mixes of the four styles over short texts of
    /// letters, spaces, digits, and punctuation reads back exactly.
    func testEveryMixOfStylesOverShortTextsReadsBack() {
        for text in ["abcde", "ab cd", "a, b.", "1 2 3", "a\u{301}b c", "(ab)", "a-b_c"] {
            let count = text.unicodeScalars.count
            for number in 0..<Int(pow(4, Double(count))) {
                assertReadsBack(text, styles(number, count: count))
            }
        }
    }

    /// 4,000 random texts with random styles read back exactly: letters and
    /// digits of several scripts, combining marks, spaces and no-break
    /// spaces, every ASCII punctuation character, typographic punctuation,
    /// symbols, and emoji. The generator is seeded (`SplitMix64`, the import
    /// fuzzer's), so every run checks the same texts.
    func testRandomTextsWithRandomStylesReadBack() {
        let alphabet = Array(
            "aBz\u{E9}\u{436}\u{4E2D}19\u{663} \u{A0}\u{301}!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~\u{2014}\u{201C}\u{201D}\u{2026}\u{20AC}\u{2192}\u{1F600}"
                .unicodeScalars
        )
        var generator = SplitMix64(seed: 0x5EED_B0A1)
        for _ in 0..<4_000 {
            let length = Int.random(in: 1...24, using: &generator)
            var scalars = (0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] }
            // One line, trimmed of white space at its ends, as the reader gives it.
            while let first = scalars.first, first.properties.isWhitespace { scalars.removeFirst() }
            while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
            guard !scalars.isEmpty else { continue }
            let text = String(String.UnicodeScalarView(scalars))
            let styles = (0..<scalars.count).map { _ in Style(rawValue: UInt8.random(in: 0...3, using: &generator)) }
            assertReadsBack(text, styles)
        }
    }

    // MARK: - Never Spoken

    /// A heading and a paragraph with emphasis read, through the reader's own
    /// parser, as their words alone: the heading list's label and the text
    /// speech is made from hold no asterisk, and match the same Markdown
    /// with no emphasis character for character, offsets included.
    func testHeadingsAndSpeechSeeOnlyTheWords() throws {
        let heading = "The Sea and Its Ships"
        let paragraph = "A plain line, with words."
        let headingStyles = heading.unicodeScalars.enumerated().map { (4...6).contains($0.offset) ? Style.emphasis : [] }
        let paragraphStyles = paragraph.unicodeScalars.enumerated().map { $0.offset < 7 ? Style.strong : [] }
        let styledMarkdown = "# " + MarkdownEmphasis.markdown(heading, styles: headingStyles) + "\n\n"
            + MarkdownEmphasis.markdown(paragraph, styles: paragraphStyles)
        let plainMarkdown = "# " + MarkdownLiteral.escaped(heading) + "\n\n" + MarkdownLiteral.escaped(paragraph)
        XCTAssertEqual(styledMarkdown, "# The *Sea* and Its Ships\n\n**A plain** line\\, with words\\.")

        let styled = try MarkdownDocParser.parseChapter(markdown: styledMarkdown)
        let plain = try MarkdownDocParser.parseChapter(markdown: plainMarkdown)
        XCTAssertEqual(styled.text, plain.text)
        XCTAssertEqual(styled.text, heading + "\n\n" + paragraph)
        XCTAssertFalse(styled.text.contains("*"))
        XCTAssertEqual(styled.headings.map(\.text), [heading])
        XCTAssertEqual(styled.headings.map(\.characterOffset), plain.headings.map(\.characterOffset))
        XCTAssertEqual(styled.headings.map(\.id), plain.headings.map(\.id))
    }
}

// MARK: - Reading Styles Back

/// Walks a parsed document, keeping each scalar of its text with the
/// emphasis and strong emphasis around it. Anything that is not text, such
/// as raw HTML or code, is kept as its raw characters, so it fails the
/// comparison with the input instead of slipping through.
private struct StyleReader: MarkupWalker {
    var text = ""
    var styles: [MarkdownEmphasis.Style] = []
    private var current: MarkdownEmphasis.Style = []

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        let outer = current
        current.insert(.emphasis)
        descendInto(emphasis)
        current = outer
    }

    mutating func visitStrong(_ strong: Strong) {
        let outer = current
        current.insert(.strong)
        descendInto(strong)
        current = outer
    }

    mutating func visitText(_ text: Markdown.Text) {
        keep(text.string)
    }

    mutating func visitInlineHTML(_ html: InlineHTML) {
        keep(html.rawHTML)
    }

    mutating func visitInlineCode(_ code: InlineCode) {
        keep("`" + code.code + "`")
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        keep("\n")
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        keep("\n")
    }

    /// Adds `string`'s scalars, each in the current style.
    private mutating func keep(_ string: String) {
        for scalar in string.unicodeScalars {
            text.unicodeScalars.append(scalar)
            styles.append(current)
        }
    }
}
