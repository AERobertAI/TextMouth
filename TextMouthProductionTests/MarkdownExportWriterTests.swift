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
    private let punctuation: [String] = (0x21...0x7E as ClosedRange<UInt8>)
        .map { Unicode.Scalar($0) }
        .filter { MarkdownLiteral.isASCIIPunctuation($0) }
        .map { String($0) }

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

    /// A less-than sign is always escaped, whatever follows it: raw HTML, a
    /// comment, and an autolink all begin with one, and an email address's
    /// autolink can begin with a digit or with most of the punctuation.
    func testLessThanIsAlwaysEscaped() {
        XCTAssertEqual(escaped("a < b"), #"a \< b"#)
        XCTAssertEqual(escaped("1<2"), #"1\<2"#)
        XCTAssertEqual(escaped("<3"), #"\<3"#)
        XCTAssertEqual(escaped("<b>"), #"\<b>"#)
        XCTAssertEqual(escaped("</p>"), #"\</p>"#)
        XCTAssertEqual(escaped("<!--"), #"\<!--"#)
        XCTAssertEqual(escaped("<?x"), #"\<?x"#)
        XCTAssertEqual(escaped("a<"), #"a\<"#)
        XCTAssertEqual(escaped("<12345@example.com>"), #"\<12345@example.com>"#)
        XCTAssertEqual(escaped("<+44@x.co>"), #"\<+44@x.co>"#)
        XCTAssertEqual(escaped("<<"), #"\<\<"#)
    }

    /// An email address between angle brackets is an autolink to swift-markdown
    /// whatever its first character is: a letter or digit, or any of
    /// `. ! # $ % & ' * + / = ? ^ _ { | } ~ - ` and a backtick. Each reads back
    /// as exactly its characters, brackets included, where it became a link
    /// and lost them when the less-than sign was left alone before a digit or
    /// a mark.
    func testEmailAutolinksReadBackAsTheirCharacters() {
        let first = Array("aZ09.!#$%&'*+/=?^_`{|}~-").map { String($0) }
        let lines = first.map { "<\($0)x@example.com>" }
            + ["<1@a>", "<12345@example.com>", "<.x@y.z>", "<+44@x.co>", "mail <1@b.co> or <a@b.co>."]
        assertRoundTrip(lines, smart: false)
        assertRoundTrip(lines, smart: true)
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
        XCTAssertEqual(escaped("Issue #"), ##"Issue \#"##)
        XCTAssertEqual(escaped("#"), ##"\#"##)
        XCTAssertEqual(escaped("a ##"), ###"a \##"###)
        XCTAssertEqual(escaped("a #  "), ##"a \#  "##)
        XCTAssertEqual(escaped("a # #"), ##"a # \#"##)
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
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("# a"), ##"\# a"##)
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("#"), ##"\#"##)
        XCTAssertEqual(MarkdownLiteral.guardingLineStart("###### a"), #######"\###### a"#######)
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
        XCTAssertEqual(MarkdownLiteral.guardingLineStart(##"\# a"##), ##"\# a"##)
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
        let document = Markdown.Document(parsing: markdown, options: smart ? [] : [.disableSmartOpts])
        guard document.childCount == 1, let block = document.child(at: 0) else { return nil }
        let container: Markdown.Markup?
        switch place {
        case .paragraph:
            container = block as? Markdown.Paragraph
        case .heading:
            container = block as? Markdown.Heading
        case .listItem:
            // One bullet list of one item with no checkbox, holding one paragraph.
            if let list = block as? Markdown.UnorderedList, list.childCount == 1,
               let item = list.child(at: 0) as? Markdown.ListItem, item.checkbox == nil, item.childCount == 1 {
                container = item.child(at: 0) as? Markdown.Paragraph
            } else {
                container = nil
            }
        }
        guard let container else { return nil }
        var text = ""
        for child in container.children {
            guard let piece = child as? Markdown.Text else { return nil }
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

// MARK: - The Writer

/// `MarkdownExportWriter` (October 23, 2026): the Markdown an export writes
/// from the `ExportDocument` walk, one exact string for each kind of block and
/// run, the whole thing walked back to the blocks it was written from, and
/// Stop. Hermetic: only a scratch folder of its own.
final class MarkdownExportWriterTests: XCTestCase {
    // MARK: - Helpers

    /// A plain run of `text`.
    private func run(_ text: String) -> ExportRun {
        ExportRun(text)
    }

    /// A paragraph block of one plain run.
    private func paragraph(_ text: String) -> ExportBlock {
        .paragraph([ExportRun(text)])
    }

    /// A heading block of `level` whose one plain run is `text`.
    private func heading(_ level: Int, _ text: String) -> ExportBlock {
        .heading(ExportHeading(level: level, runs: [ExportRun(text)], id: "h"))
    }

    /// A list of `items`, each of the blocks given.
    private func list(ordered: Bool = false, start: Int = 1, depth: Int = 0, _ items: [[ExportBlock]]) -> ExportBlock {
        .list(ExportList(isOrdered: ordered, start: start, depth: depth, items: items.map { ExportListItem(blocks: $0) }))
    }

    /// The Markdown of a document of `blocks`.
    private func markdown(_ blocks: [ExportBlock]) throws -> String {
        try MarkdownExportWriter.markdown(of: ExportDocument(book: ExportBookDetails(title: "T"), blocks: blocks))
    }

    /// `lines` as Markdown text: each ended by a line feed.
    private func text(_ lines: String...) -> String {
        lines.map { $0 + "\n" }.joined()
    }

    /// The document of `markdown` for a book with no title, so no title
    /// heading is added.
    private func walk(_ markdown: String) throws -> ExportDocument {
        try ExportDocumentWalker.document(fromMarkdown: markdown, book: ExportBookDetails(title: ""))
    }

    // MARK: - The Writer's Identity

    /// The writer's names, for the picker's Markdown choice.
    func testWriterIdentity() {
        let writer = MarkdownExportWriter()
        XCTAssertEqual(writer.id, "md")
        XCTAssertEqual(writer.name, "Markdown")
        XCTAssertEqual(writer.fileExtension, "md")
        XCTAssertEqual(writer.hint, BookExportWording.markdownChoiceHint)
        XCTAssertNotEqual(writer.id, TextExportWriters.markdownID)
        XCTAssertNil(TextExportWriters.writer(id: writer.id), "Markdown is the picker's first choice, not one of `all`")
    }

    // MARK: - Documents

    /// An empty document is an empty file, and a document ends in one line
    /// feed, its blocks apart by one blank line.
    func testDocumentsEndInOneLineFeedAndBlocksAreApartByABlankLine() throws {
        XCTAssertEqual(try markdown([]), "")
        XCTAssertEqual(try markdown([paragraph("One."), paragraph("Two.")]), "One.\n\nTwo.\n")
        // A block that writes nothing leaves no blank line behind.
        XCTAssertEqual(try markdown([paragraph("One."), .paragraph([]), list([]), paragraph("Two.")]), "One.\n\nTwo.\n")
    }

    /// The title heading is never written.
    func testTheTitleHeadingIsNotWritten() throws {
        let document = ExportDocument(
            book: ExportBookDetails(title: "T"),
            titleHeading: ExportHeading(level: 1, runs: [run("The Title")], id: "the-title"),
            blocks: [paragraph("Words.")]
        )
        XCTAssertEqual(try MarkdownExportWriter.markdown(of: document), "Words.\n")
    }

    // MARK: - Headings

    /// A heading is `#` times its level; a line feed in it is a space; its
    /// styles and a closing number sign are written.
    func testHeadings() throws {
        XCTAssertEqual(try markdown([heading(2, "Hello, world.")]), "## Hello, world.\n")
        XCTAssertEqual(try markdown([heading(6, "Deep"), heading(1, "Top")]), "###### Deep\n\n# Top\n")
        XCTAssertEqual(try markdown([.heading(ExportHeading(level: 1, runs: [run("a\nb")], id: "h"))]), "# a b\n")
        XCTAssertEqual(try markdown([.heading(ExportHeading(
            level: 3, runs: [run("Big "), ExportRun("bold", isStrong: true)], id: "h"
        ))]), "### Big **bold**\n")
        XCTAssertEqual(try markdown([heading(2, "Issue #")]), "## Issue \\#\n")
        // A level beyond the six Markdown has is kept within them.
        XCTAssertEqual(try markdown([heading(9, "Odd")]), "###### Odd\n")
    }

    // MARK: - Paragraphs and Runs

    /// Sentence punctuation is written as it is.
    func testAParagraphKeepsSentencePunctuation() throws {
        XCTAssertEqual(try markdown([paragraph("Hello, world. It's 3:00; really? Yes!")]), "Hello, world. It's 3:00; really? Yes!\n")
    }

    /// Emphasis, strong, and both are `*`, `**`, and `***`.
    func testEmphasisRuns() throws {
        let runs = [
            run("a "), ExportRun("em", isEmphasis: true), run(" and "), ExportRun("st", isStrong: true),
            run(" and "), ExportRun("both", isEmphasis: true, isStrong: true), run("."),
        ]
        XCTAssertEqual(try markdown([.paragraph(runs)]), "a *em* and **st** and ***both***.\n")
    }

    /// A code run is a code span: its fence is one backtick longer than the
    /// longest run in it, padded where Markdown would strip a space or a
    /// backtick, its line feeds spaces, and it holds no emphasis.
    func testCodeRuns() throws {
        func code(_ text: String, emphasis: Bool = false) -> ExportBlock {
            .paragraph([run("x "), ExportRun(text, isEmphasis: emphasis, isCode: true), run(" y")])
        }
        XCTAssertEqual(try markdown([code("a_b *c*")]), "x `a_b *c*` y\n")
        XCTAssertEqual(try markdown([code("x`y")]), "x ``x`y`` y\n")
        XCTAssertEqual(try markdown([code("`a")]), "x `` `a `` y\n")
        XCTAssertEqual(try markdown([code("a`")]), "x `` a` `` y\n")
        XCTAssertEqual(try markdown([code("a``b`c")]), "x ```a``b`c``` y\n")
        XCTAssertEqual(try markdown([code(" a ")]), "x `  a  ` y\n")
        XCTAssertEqual(try markdown([code("  ")]), "x `  ` y\n")
        XCTAssertEqual(try markdown([code("a\nb")]), "x `a b` y\n")
        XCTAssertEqual(try markdown([code("em", emphasis: true)]), "x `em` y\n")
    }

    /// Neighbouring runs of one link are one link; its address has `\`, `<`,
    /// and `>` escaped; a link holds its emphasis.
    func testLinkRuns() throws {
        let address = "https://example.com/a(b)"
        let runs = [
            run("see "), ExportRun("the ", link: address), ExportRun("site", isEmphasis: true, link: address), run("."),
        ]
        XCTAssertEqual(try markdown([.paragraph(runs)]), "see [the *site*](<https://example.com/a(b)>).\n")
        XCTAssertEqual(
            try markdown([.paragraph([ExportRun("odd", link: #"https://x.com/a>b<c\d"#)])]),
            #"[odd](<https://x.com/a\>b\<c\\d>)"# + "\n"
        )
        // An address that may not be a link is plain text.
        XCTAssertEqual(try markdown([.paragraph([ExportRun("words", link: "javascript:1")])]), "words\n")
    }

    /// An exclamation mark that ends the words before a link is escaped, since
    /// `![` begins an image, which keeps the link's words and loses the mark
    /// and the link; one that is not directly before the link is left alone.
    /// Each is walked back to the runs it was written from.
    func testAnExclamationMarkBeforeALinkIsEscaped() throws {
        let address = "https://example.com/"
        let link = ExportRun("here", link: address)
        let cases: [(runs: [ExportRun], written: String)] = [
            // The bare case: an image, were the mark not escaped.
            ([run("Wow!"), link], #"Wow\![here](<https://example.com/>)"#),
            // Not directly before the link: a space or a break between.
            ([run("Wow! "), link], "Wow! [here](<https://example.com/>)"),
            ([run("Wow!\n"), link], #"Wow!\"# + "\n" + "[here](<https://example.com/>)"),
            // Emphasis keeps punctuation outside its delimiters, so the mark is bare.
            ([ExportRun("Wow", isEmphasis: true), run("!"), link], #"*Wow*\![here](<https://example.com/>)"#),
            // A mark that follows a backslash the text had: the backslash is escaped, then the mark.
            ([run(#"a\!"#), link], #"a\\\![here](<https://example.com/>)"#),
            // A mark of its own between two links, and one after a link's own words.
            ([link, run("!"), ExportRun("there", link: "https://example.org/")],
             #"[here](<https://example.com/>)\![there](<https://example.org/>)"#),
            ([ExportRun("Wow!", link: address)], "[Wow!](<https://example.com/>)"),
            // After a code span, it is still bare.
            ([run("x"), ExportRun("code", isCode: true), run("!"), link], #"x`code`\![here](<https://example.com/>)"#),
        ]
        for (runs, written) in cases {
            let markdown = try self.markdown([.paragraph(runs)])
            XCTAssertEqual(markdown, written + "\n")
            let walked = try walk(markdown)
            XCTAssertEqual(walked.blocks, [.paragraph(runs)], "\(written) did not walk back to the runs it was written from")
        }
        // A heading takes the same care.
        XCTAssertEqual(
            try markdown([.heading(ExportHeading(level: 2, runs: [run("Hi!"), link], id: "h"))]),
            #"## Hi\![here](<https://example.com/>)"# + "\n"
        )
    }

    /// A line feed in a run is a hard break, a backslash and a line feed, and
    /// every line is guarded at its start.
    func testHardBreaksAndGuardedLines() throws {
        XCTAssertEqual(try markdown([paragraph("one\ntwo")]), "one\\\ntwo\n")
        XCTAssertEqual(try markdown([paragraph("a\n- b\n# c\n> d\n1. e")]), "a\\\n\\- b\\\n\\# c\\\n\\> d\\\n1\\. e\n")
        XCTAssertEqual(try markdown([paragraph("2019. That was a year; 1.5 million")]), "2019\\. That was a year; 1.5 million\n")
        // Spaces around a break and a break at either end go.
        XCTAssertEqual(try markdown([paragraph("\none  \n  two\n")]), "one\\\ntwo\n")
    }

    /// Characters Markdown would read as syntax are escaped inside a run.
    func testSyntaxCharactersAreEscaped() throws {
        XCTAssertEqual(
            try markdown([paragraph("a*b* `c` [d] | ~e~ _f_ snake_case")]),
            "a\\*b\\* \\`c\\` \\[d\\] \\| \\~e\\~ \\_f\\_ snake_case\n"
        )
    }

    // MARK: - Lists

    /// Unordered items begin `- `; ordered ones with their numbers from the
    /// list's start, which is kept within 0 and 999,999,999.
    func testListMarkers() throws {
        XCTAssertEqual(try markdown([list([[paragraph("One")], [paragraph("Two")]])]), "- One\n- Two\n")
        XCTAssertEqual(try markdown([list(ordered: true, start: 3, [[paragraph("a")], [paragraph("b")]])]), "3. a\n4. b\n")
        XCTAssertEqual(try markdown([list(ordered: true, start: -5, [[paragraph("a")]])]), "0. a\n")
        XCTAssertEqual(
            try markdown([list(ordered: true, start: 1_000_000_000, [[paragraph("a")], [paragraph("b")]])]),
            "999999999. a\n999999999. b\n"
        )
    }

    /// An item's blocks are apart by a blank line and indented by the
    /// marker's width, a list inside an item too; an item with no block is
    /// its marker alone.
    func testItemsHoldBlocks() throws {
        let nested = list(depth: 1, [[paragraph("Xray")], [paragraph("Yankee")]])
        XCTAssertEqual(
            try markdown([list([[paragraph("Alpha"), nested], [paragraph("Bravo")]])]),
            text("- Alpha", "", "  - Xray", "  - Yankee", "- Bravo")
        )
        XCTAssertEqual(
            try markdown([list(ordered: true, start: 9, [[paragraph("a"), .codeBlock("x\n\ny")], []])]),
            text("9. a", "", "   ```", "   x", "", "   y", "   ```", "10.")
        )
        XCTAssertEqual(try markdown([list([[], [paragraph("b")]])]), "-\n- b\n")
    }

    // MARK: - Quotes, Code, Breaks, and Tables

    /// A quote is its blocks' lines after `> `, a blank line `>`.
    func testBlockQuotes() throws {
        XCTAssertEqual(try markdown([.blockQuote([paragraph("Quoted"), paragraph("More")])]), text("> Quoted", ">", "> More"))
        XCTAssertEqual(
            try markdown([.blockQuote([paragraph("Items"), list([[paragraph("qa")], [paragraph("qb")]])])]),
            text("> Items", ">", "> - qa", "> - qb")
        )
        XCTAssertEqual(try markdown([.blockQuote([])]), ">\n")
    }

    /// A code block is fenced with one more backtick than its longest run,
    /// at least three, its lines as they are, backslashes included.
    func testCodeBlocks() throws {
        XCTAssertEqual(try markdown([.codeBlock("x = 1")]), text("```", "x = 1", "```"))
        XCTAssertEqual(
            try markdown([.codeBlock("a\\b\n```\n  c\\")]),
            text("````", "a\\b", "```", "  c\\", "````")
        )
        XCTAssertEqual(try markdown([.codeBlock("")]), text("```", "```"))
    }

    /// A thematic break is `---`.
    func testThematicBreak() throws {
        XCTAssertEqual(try markdown([paragraph("a"), .thematicBreak, paragraph("b")]), "a\n\n---\n\nb\n")
    }

    /// A table is GitHub's form: `|` and `\` in cells escaped, rows padded to
    /// the longest, line feeds spaces, and a table without a header row
    /// written with an empty one.
    func testTables() throws {
        let withHeader = ExportTable(rows: [["A|B", #"C\"#], ["1", "2"], ["only"]], hasHeaderRow: true)
        XCTAssertEqual(
            try markdown([.table(withHeader)]),
            text(#"| A\|B | C\\ |"#, "| --- | --- |", "| 1 | 2 |", "| only |  |")
        )
        let without = ExportTable(rows: [["x"], ["y", "z\nw"]], hasHeaderRow: false)
        XCTAssertEqual(
            try markdown([.table(without)]),
            text("|  |  |", "| --- | --- |", "| x |  |", "| y | z w |")
        )
        XCTAssertEqual(try markdown([.table(ExportTable(rows: [[]], hasHeaderRow: false))]), "")
    }

    // MARK: - The Round Trip

    /// A content.md with every kind of block and run, two chapters among
    /// them, walked into a document, written, and walked again, holds the
    /// same blocks (quotes, dashes, and ellipses aside: the walker's smart
    /// punctuation curls a plain quote); and none of its commas is escaped.
    func testARichContentWalksBackToTheSameBlocks() throws {
        let marker = { MarkdownCacheService.chapterMarker(title: $0) }
        // Every ASCII punctuation character but the two quotes: the walker
        // reads with smart punctuation, as TextMouth's reader does, so a plain
        // quote in the exported file reads as a curly one. The export leaves
        // quotes plain on purpose, for the people and programs that read it.
        let everyPunctuation = MarkdownLiteral.escaped("!#$%&()*+,-./:;<=>?@[\\]^_`{|}~ and words. Done, 1. 2)")
        let source = [
            marker("Opening"), "",
            "# Part One", "",
            "## Level two", "",
            "### Level three", "",
            "Plain *emphasis* and **strong** and ***both*** and `code` and [a link](https://example.com/a_b?x=1&y=2) end.", "",
            "line one  ", "line two", "",
            "- alpha", "  1. nested one", "  2. nested two", "- beta", "",
            "4. four", "5. five", "",
            "> Quoted words.", ">", "> - qa", "> - qb", "",
            "````", "some `code` and \\ here", "```", "````", "",
            "---", "",
            "| H1 | H2 |", "| --- | --- |", "| a | b\\|c |", "",
            everyPunctuation, "",
            MarkdownLiteral.escaped("# not a heading"), "",
            MarkdownLiteral.escaped("- not a bullet"), "",
            MarkdownLiteral.escaped("1. not a list"), "",
            MarkdownLiteral.escaped("> not a quote"), "",
            marker("Closing"), "",
            "Final words, with a period.", "",
        ].joined(separator: "\n")

        let first = try walk(source)
        XCTAssertFalse(first.blocks.isEmpty)
        let written = try MarkdownExportWriter.markdown(of: first)
        let second = try walk(written)

        XCTAssertEqual(second.blocks, first.blocks, written)
        XCTAssertFalse(written.contains("\\,"), written)
        XCTAssertTrue(written.contains("Final words, with a period.\n"), written)
    }

    /// The same, for paragraphs holding the user's own sentence and every
    /// kind of run in turn.
    func testRunsWalkBackToTheSameRuns() throws {
        let paragraphs = [
            "Hello, world. It's 3:00; really? Yes!",
            "A *very* **bold** and `a``b` and [site](<https://example.com/a(b)>) *[both](https://x.org)*.",
            "snake_case and _under_ and 2_000 and a_ b",
            "AT&T and &amp; and &#35; and Q&A",
            "Issue # and C# and #378",
        ]
        let first = try walk(paragraphs.joined(separator: "\n\n"))
        let second = try walk(try MarkdownExportWriter.markdown(of: first))
        XCTAssertEqual(second.blocks, first.blocks)
    }

    // MARK: - Writing a File

    /// The writer writes the Markdown as UTF-8 to a new file, and refuses to
    /// replace one that is there.
    func testWriteMakesANewFileAndNeverReplacesOne() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownExportWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("Book - Text.md")
        let document = ExportDocument(book: ExportBookDetails(title: "T"), blocks: [paragraph("Café, déjà vu.")])

        try MarkdownExportWriter().write(document, options: NoTextExportOptions(), to: target, cancellation: BookExportCancellation())
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "Café, déjà vu.\n")
        XCTAssertThrowsError(
            try MarkdownExportWriter().write(document, options: NoTextExportOptions(), to: target, cancellation: BookExportCancellation())
        )
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "Café, déjà vu.\n")
    }

    // MARK: - Stop

    /// A cancelled export throws `CancellationError` and writes no file.
    func testStopThrowsCancellationError() throws {
        let cancellation = BookExportCancellation()
        cancellation.cancel()
        let document = ExportDocument(book: ExportBookDetails(title: "T"), blocks: [paragraph("One."), paragraph("Two.")])
        XCTAssertThrowsError(try MarkdownExportWriter.markdown(of: document, cancellation: cancellation)) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        let target = FileManager.default.temporaryDirectory.appendingPathComponent("MarkdownExportWriterTests-stop-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: target) }
        XCTAssertThrowsError(
            try MarkdownExportWriter().write(document, options: NoTextExportOptions(), to: target, cancellation: cancellation)
        ) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
}
