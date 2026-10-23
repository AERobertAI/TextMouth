import Markdown
import XCTest
@testable import TextMouth

// MARK: - Escaping Only What Markdown Needs

/// `MarkdownLiteral.minimallyEscaped` and `guardingLineStart` (October 23,
/// 2026): the escaping of the Markdown an export writes, which backslashes only
/// the characters a Markdown reader would otherwise read as syntax (the user:
/// "every , and . character seems to be escaped in the markdown"). The
/// examples pin each rule both ways; a round trip through swift-markdown
/// itself proves that every short string comes back as exactly its
/// characters. Hermetic: no helper, no library, no file.
final class MarkdownMinimalEscapingTests: XCTestCase {
    // MARK: - Helpers

    /// `text` minimally escaped, as the plain form unless `smart`.
    private func escaped(_ text: String, smart: Bool = false) -> String {
        MarkdownLiteral.minimallyEscaped(text, smartPunctuation: smart)
    }

    /// The 32 ASCII punctuation characters, each as a one-character string.
    private let punctuation: [String] = (0x21...0x7E).compactMap { value in
        Unicode.Scalar(UInt8(value)).flatMap { scalar in
            MarkdownLiteral.isASCIIPunctuation(scalar) ? String(scalar) : nil
        }
    }

    // MARK: - Examples: what is left alone

    /// The user's case: commas, periods, colons, semicolons, question and
    /// exclamation marks, and apostrophes are not escaped.
    func testOrdinarySentencePunctuationIsLeftAlone() {
        let sentence = "Hello, world. It's 3:00; really? Yes!"
        XCTAssertEqual(escaped(sentence), sentence)
        // Smart punctuation changes only the apostrophe.
        XCTAssertEqual(escaped(sentence, smart: true), #"Hello, world. It\'s 3:00; really? Yes!"#)
    }

    /// The characters the brief names are never escaped mid-line.
    func testNothingElseIsEscapedMidLine() {
        let text = #"x ,.:;?!()/%$@^{}=+->'" x"#
        XCTAssertEqual(escaped(text), text)
    }

    /// The empty piece stays empty.
    func testEmptyPieceStaysEmpty() {
        XCTAssertEqual(escaped(""), "")
        XCTAssertEqual(MarkdownLiteral.guardingLineStart(""), "")
    }

    // MARK: - Examples: always escaped

    /// A backtick, asterisk, brackets, bar, and tilde are always escaped.
    func testAlwaysEscapedCharacters() {
        XCTAssertEqual(escaped("a`b*c[d]e|f~g"), #"a\`b\*c\[d\]e\|f\~g"#)
    }

    // MARK: - Examples: underscore

    /// An underscore inside a word is left alone; one anywhere else is escaped.
    func testUnderscoreIsEscapedOnlyOutsideAWord() {
        XCTAssertEqual(escaped("snake_case"), "snake_case")
        XCTAssertEqual(escaped("a_1_é"), "a_1_é")
        XCTAssertEqual(escaped("_x"), #"\_x"#)
        XCTAssertEqual(escaped("x_"), #"x\_"#)
        XCTAssertEqual(escaped("a_ b"), #"a\_ b"#)
        XCTAssertEqual(escaped("a _b"), #"a \_b"#)
        XCTAssertEqual(escaped("__init__"), #"\_\_init\_\_"#)
        XCTAssertEqual(escaped("a_.b"), #"a\_.b"#)
    }

    // MARK: - Examples: backslash

    /// A backslash is escaped before ASCII punctuation and at the end of the
    /// piece, and left alone before anything else.
    func testBackslashIsEscapedBeforePunctuationAndAtTheEnd() {
        XCTAssertEqual(escaped(#"C:\path"#), #"C:\path"#)
        XCTAssertEqual(escaped(#"a\*"#), #"a\\\*"#)
        XCTAssertEqual(escaped(#"a\"#), #"a\\"#)
        XCTAssertEqual(escaped(#"\\"#), #"\\\\"#)
        XCTAssertEqual(escaped(#"a\ b"#), #"a\ b"#)
        XCTAssertEqual(escaped(#"a\é"#), #"a\é"#)
    }

    // MARK: - Examples: less-than

    /// A less-than sign is escaped before a letter, slash, exclamation mark,
    /// or question mark, and at the end; elsewhere it is plain.
    func testLessThanIsEscapedWhereHTMLCouldBegin() {
        XCTAssertEqual(escaped("a < b"), "a < b")
        XCTAssertEqual(escaped("1<2"), "1<2")
        XCTAssertEqual(escaped("<3"), "<3")
        XCTAssertEqual(escaped("<b>"), #"\<b>"#)
        XCTAssertEqual(escaped("</p>"), #"\</p>"#)
        XCTAssertEqual(escaped("<!--"), #"\<!--"#)
        XCTAssertEqual(escaped("<?x"), #"\<?x"#)
        XCTAssertEqual(escaped("a<"), #"a\<"#)
    }

    // MARK: - Examples: ampersand

    /// An ampersand is escaped when a character reference's body follows it,
    /// and not otherwise.
    func testAmpersandIsEscapedBeforeACharacterReference() {
        XCTAssertEqual(escaped("AT&T"), "AT&T")
        XCTAssertEqual(escaped("Q&A"), "Q&A")
        XCTAssertEqual(escaped("a & b"), "a & b")
        XCTAssertEqual(escaped("&;"), "&;")
        XCTAssertEqual(escaped("&amp"), "&amp")
        XCTAssertEqual(escaped("&amp;"), #"\&amp;"#)
        XCTAssertEqual(escaped("R&D;"), #"R\&D;"#)
        XCTAssertEqual(escaped("&#35;"), #"\&#35;"#)
        XCTAssertEqual(escaped("&#1234567;"), #"\&#1234567;"#)
        XCTAssertEqual(escaped("&#12345678;"), "&#12345678;")
        XCTAssertEqual(escaped("&#x1F600;"), #"\&#x1F600;"#)
        XCTAssertEqual(escaped("&#X1f;"), #"\&#X1f;"#)
        XCTAssertEqual(escaped("&#xFFFFFFF;"), "&#xFFFFFFF;")
        XCTAssertEqual(escaped("&#;"), "&#;")
        XCTAssertEqual(escaped("&#x;"), "&#x;")
        XCTAssertEqual(escaped("&#xZ;"), "&#xZ;")
    }

    // MARK: - Examples: number sign

    /// A number sign is escaped only where it opens a heading's closing
    /// sequence.
    func testNumberSignIsEscapedOnlyAsAClosingSequence() {
        XCTAssertEqual(escaped("Issue #"), #"Issue \#"#)
        XCTAssertEqual(escaped("#"), #"\#"#)
        XCTAssertEqual(escaped("a ##"), #"a \##"#)
        XCTAssertEqual(escaped("a #  "), #"a \#  "#)
        XCTAssertEqual(escaped("a # #"), #"a # \#"#)
        XCTAssertEqual(escaped("C#"), "C#")
        XCTAssertEqual(escaped("C##"), "C##")
        XCTAssertEqual(escaped("#378"), "#378")
        XCTAssertEqual(escaped("a # b"), "a # b")
        XCTAssertEqual(escaped("a ## b"), "a ## b")
        XCTAssertEqual(escaped("## a"), "## a")
    }

    // MARK: - Examples: smart punctuation

    /// For TextMouth's own reader, quotes are always escaped, and a hyphen
    /// or period only beside its own kind.
    func testSmartPunctuationEscapesQuotesDashesAndEllipses() {
        XCTAssertEqual(escaped(#"He said "hi""#, smart: true), #"He said \"hi\""#)
        XCTAssertEqual(escaped("It's", smart: true), #"It\'s"#)
        XCTAssertEqual(escaped("well... no -- yes", smart: true), #"well\.\.\. no \-\- yes"#)
        XCTAssertEqual(escaped("--", smart: true), #"\-\-"#)
        XCTAssertEqual(escaped("---", smart: true), #"\-\-\-"#)
        // Lone ones, and a period ending the piece, are left alone.
        XCTAssertEqual(escaped("Done.", smart: true), "Done.")
        XCTAssertEqual(escaped("a-b 3.5 a - b.", smart: true), "a-b 3.5 a - b.")
        // The plain form leaves all of them.
        XCTAssertEqual(escaped(#"well... no -- yes "x" 'y'"#), #"well... no -- yes "x" 'y'"#)
    }

    // MARK: - Examples: byte-order mark

    /// U+FEFF is written as a character reference, as `escaped` writes it.
    func testByteOrderMarkIsWrittenAsAReference() {
        XCTAssertEqual(escaped("a\u{FEFF}b"), "a&#xFEFF;b")
        XCTAssertEqual(escaped("\u{FEFF}"), MarkdownLiteral.escaped("\u{FEFF}"))
    }

    // MARK: - Examples: guarding a line's start

    /// A heading marker at a line's start is guarded; a run of seven, or a
    /// number sign with a word after it, is not a heading.
    func testGuardingAHeadingMarker() {
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("# a"), #"\# a"#)
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("#"), #"\#"#)
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("###### a"), #"\###### a"#)
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("####### a"), "####### a")
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("#a"), "#a")
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("#378 was"), "#378 was")
    }

    /// A bullet, a thematic break, a setext underline, and a quote marker are
    /// guarded; a hyphen or equals sign that begins a word is not.
    func testGuardingBulletsRulesAndQuotes() {
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("- a"), #"\- a"#)
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("-"), #"\-"#)
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("+ a"), #"\+ a"#)
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("+a"), "+a")
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("-a"), "-a")
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("---"), #"\---"#)
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("- - -"), #"\- - -"#)
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("==="), #"\==="#)
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("= "), #"\= "#)
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("=a"), "=a")
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("> a"), #"\> a"#)
        XCTAssertEqual(MarkdownLiteral.guardingLineStart(">a"), #"\>a"#)
    }

    /// A numbered item's marker is guarded when one to nine digits are
    /// followed by a period or parenthesis and a blank, and not otherwise.
    func testGuardingANumberedItem() {
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("2019. That"), #"2019\. That"#)
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("1) a"), #"1\) a"#)
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("1."), #"1\."#)
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("123456789. a"), #"123456789\. a"#)
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("1234567890. a"), "1234567890. a")
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("1.5 million"), "1.5 million")
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("12 men"), "12 men")
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("a. b"), "a. b")
    }

    /// A line that already begins with a backslash needs nothing more.
    func testGuardingLeavesAnEscapedStartAlone() {
        XCTAssertEqual(MarkdownLiteral.guardingLineStart(#"\# a"#), #"\# a"#)
        XCTAssertEqual(MarkdownLiteral.guardingLineStart(#"\-\-"#), #"\-\-"#)
    }

    // MARK: - The Round Trip Through swift-markdown

    /// The kinds of block the round trip puts a piece in.
    private enum Place: String, CaseIterable {
        case paragraph, heading, listItem

        /// The Markdown of `piece` (already minimally escaped) in this place.
        func markdown(_ piece: String) -> String {
            switch self {
            case .paragraph: return MarkdownLiteral.guardingLineStart(piece)
            case .heading: return "# " + piece
            case .listItem: return "- " + MarkdownLiteral.guardingLineStart(piece)
            }
        }
    }

    /// What swift-markdown reads from `markdown` for `place`: the strings of
    /// the one block's children joined, or nil when the document is not
    /// that one block, or the block holds anything but `Text`.
    private func readBack(_ markdown: String, place: Place, smart: Bool) -> String? {
        let document = Document(parsing: markdown, options: smart ? [] : [.disableSmartOpts])
        guard document.childCount == 1, let block = document.child(at: 0) else { return nil }
        let container: Markup?
        switch place {
        case .paragraph:
            container = block as? Paragraph
        case .heading:
            container = block as? Heading
        case .listItem:
            // One bullet list of one item with no checkbox, holding one paragraph.
            if let list = block as? UnorderedList, list.childCount == 1,
               let item = list.child(at: 0) as? ListItem, item.checkbox == nil, item.childCount == 1 {
                container = item.child(at: 0) as? Paragraph
            } else {
                container = nil
            }
        }
        guard let container else { return nil }
        var text = ""
        for child in container.children {
            guard let piece = child as? Text else { return nil }
            text += piece.string
        }
        return text
    }

    /// Every string of `length` characters from `alphabet`.
    private func strings(of length: Int, over alphabet: [String]) -> [String] {
        (0..<length).reduce([""]) { strings, _ in
            strings.flatMap { prefix in alphabet.map { prefix + $0 } }
        }
    }

    /// Asserts that each of `strings`, minimally escaped (for `smart`
    /// punctuation or not), reads back from swift-markdown as exactly its
    /// characters in a paragraph, a heading, and a list item. Strings that
    /// begin or end with a space are skipped: Markdown trims a line's ends.
    private func assertRoundTrip(_ strings: [String], smart: Bool, file: StaticString = #filePath, line: UInt = #line) {
        var failures: [String] = []
        for string in strings where !string.hasPrefix(" ") && !string.hasSuffix(" ") {
            let piece = MarkdownLiteral.minimallyEscaped(string, smartPunctuation: smart)
            for place in Place.allCases {
                let markdown = place.markdown(piece)
                if readBack(markdown, place: place, smart: smart) != string {
                    failures.append("\(string.debugDescription) as \(place.rawValue) \(markdown.debugDescription)")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failed, such as: \(failures.prefix(25))", file: file, line: line)
    }

    /// Every string of one or two characters over `a`, `1`, `é`, a space, and
    /// the 32 ASCII punctuation characters reads back exactly (plain form).
    func testShortStringsReadBackExactly() {
        let alphabet = ["a", "1", "é", " "] + punctuation
        XCTAssertEqual(punctuation.count, 32)
        assertRoundTrip(strings(of: 1, over: alphabet) + strings(of: 2, over: alphabet), smart: false)
    }

    /// The same under smart punctuation, which the reader would otherwise
    /// substitute.
    func testShortStringsReadBackExactlyWithSmartPunctuation() {
        let alphabet = ["a", "1", "é", " "] + punctuation
        assertRoundTrip(strings(of: 1, over: alphabet) + strings(of: 2, over: alphabet), smart: true)
    }

    /// Every string of three characters over the punctuation, `a`, and a
    /// space reads back exactly (plain form).
    func testThreeCharacterStringsReadBackExactly() {
        assertRoundTrip(strings(of: 3, over: punctuation + ["a", " "]), smart: false)
    }

    /// The same under smart punctuation.
    func testThreeCharacterStringsReadBackExactlyWithSmartPunctuation() {
        assertRoundTrip(strings(of: 3, over: punctuation + ["a", " "]), smart: true)
    }

    /// Longer lines of ordinary prose, with the cases the short strings
    /// cannot hold, read back exactly in all three places.
    func testLongerLinesReadBackExactly() {
        let lines = [
            "Hello, world. It's 3:00; really? Yes! (Maybe.)",
            "AT&T and Q&A, R&D; &amp; &#35; &#x1F;",
            "Issue # and C# and #378 and a ##",
            "snake_case, _private, trailing_, __init__, 2_000_000",
            #"C:\path\to\file and a\*b and trailing\"#,
            "a < b, 1<2, <b>bold</b>, <!-- no --> <?php ?> <https://example.com>",
            "Costs $5 or 5% off; 50% of x = y + z > 0, a-b, a--b, a---b, a...b",
            "x ^ y {z} @home ~tilde~ `code` *star* [link](u) ![img](u) | pipe",
            "2019. That was a year; 1) not a list; 1.5 million",
            "https://example.com/a_b?c=d&e=f#g www.example.com a@b.co",
        ]
        assertRoundTrip(lines, smart: false)
        assertRoundTrip(lines, smart: true)
    }
}
