import Foundation
import ZIPFoundation
@testable import TextMouth

// The pieces of the Markdown walk corpus (`MarkdownWalkCorpusTests`): the
// Markdown it generates, the damage it does to real books' Markdown, and the
// records it makes of what the app reads from a Markdown text.
//
// What it is for: every text book is read from its content.md by
// `MarkdownDocParser`, and exported from it by `ExportDocumentWalker`. Both
// walk a tree a Markdown parser builds. The records here were made on
// November 15, 2026 with the walks over swift-markdown's tree, before those
// walks were moved to cmark's own tree, and a walk that reads any input
// differently fails the corpus test.

/// One Markdown text of the corpus, with the name its records go by.
struct MarkdownCorpusCase {
    /// The case's name, unique in its group.
    let name: String
    /// The Markdown read.
    let markdown: String
}

/// Everything the corpus test does that needs no test case.
enum MarkdownWalkCorpusKit {

    // MARK: - Markers

    /// A page marker as content.md carries it (`MarkdownMarkers.page(_:)`).
    static func page(_ label: String) -> String {
        MarkdownMarkers.page(label)
    }

    /// A heading annotation as content.md carries it.
    static func target(_ level: Int, _ text: String) -> String {
        MarkdownHeadingAnnotation(level: level, text: text).markdown
    }

    /// `count` block quotes around one word.
    static func quotes(_ count: Int) -> String {
        String(repeating: "> ", count: count) + "deep"
    }

    /// `count` lists, each inside the item of the one before.
    static func lists(_ count: Int) -> String {
        (0..<count).map { String(repeating: "  ", count: $0) + "- level \($0)" }.joined(separator: "\n")
    }

    // MARK: - The Named Cases

    /// The cases written by hand for what a walk of another tree could read
    /// differently: tables, comments that carry markers, breaks, nesting,
    /// code, links and images, entities, emphasis, smart punctuation,
    /// headings' labels, raw HTML, odd characters, and deep trees. Their
    /// records are kept whole (`generated.records`), so a difference is shown
    /// in words.
    static let namedCases: [MarkdownCorpusCase] = {
        let p7 = page("7")
        let p8 = page("8")
        let t2 = target(2, "Target")
        let t3 = target(3, "Other Target")
        let cases: [(String, String)] = [
            // Paragraphs and breaks.
            ("empty", ""),
            ("whitespace only", " \n\t\n  "),
            ("one paragraph", "Plain words in one paragraph."),
            ("two paragraphs", "First paragraph.\n\nSecond paragraph."),
            ("soft break", "A line that wraps\nonto a second line\nand a third."),
            ("hard break by spaces", "First line  \nsecond line"),
            ("hard break by backslash", "First line\\\nsecond line"),
            ("hard break at the end", "Words  \n\nNext\\\n"),
            ("break inside emphasis", "*soft\nbreak* and **hard  \nbreak**"),
            ("leading and trailing blank lines", "\n\n\n  Words after blank lines.  \n\n\n"),
            ("carriage returns", "One\r\nTwo\rThree\r\n\r\nFour"),
            // A carriage return right before a blank line: with the line feed after it, it is
            // one Character, so the text does not end with a blank line, and another follows.
            ("carriage return entity before a block", "a&#13;\n\nb\n\n# h&#13;\n\nc"),
            ("carriage return entity before a block, not ASCII", "é&#13;\n\nb\n\n# h&#13;\n\nc"),
            ("code ending in a carriage return", "```\ncode\r```\n\nafter\n\n    more code\rlast"),
            ("code with carriage returns and line feeds", "```\r\ncode\r\n```\r\n\r\nafter é\r\n\r\n    more\r\n\r\nlast"),
            ("carriage return entity in a table and a list", "| a&#13; |\n|---|\n| b&#13; |\n\nafter\n\n- item&#13;\n\n> quote&#13;\n\nend"),
            ("line feed entities", "a&#10;&#10;\n\nb&#10;\n\nc&#13;&#10;&#10;\n\nd"),
            ("line separators", "One\u{2028}Two\u{2029}Three\u{85}Four\u{0C}Five\u{0B}Six"),
            ("tabs and nonbreaking spaces", "A\tB\u{A0}C\u{2003}D\n\n\tindented by a tab"),
            ("null character", "Before\u{0}after"),
            ("emoji and combining marks", "Cafe\u{301} 👩‍👩‍👧 naïve שלום مرحبا 🏳️‍🌈"),
            ("zero width characters", "\u{200B}Edge\u{200B}\n\n# \u{200B}Label\u{200B}\n\n\u{FEFF}Mark"),

            // Headings.
            ("atx headings", "# One\n\n## Two\n\n### Three\n\n#### Four\n\n##### Five\n\n###### Six\n\n####### Seven"),
            ("setext headings", "Title\n=====\n\nSection\n-------\n\nBody"),
            ("heading with closing hashes", "## Closed ##\n\n# Trailing space   \n\n#NoSpace"),
            ("empty headings", "#\n\n## \n\nBody\n\n### ###"),
            ("heading then text without a blank line", "# Head\nBody right after\n## Next\nMore"),
            ("heading with emphasis", "# A *slanted* and **strong** and ***both*** head"),
            ("heading with code", "## Use `code` here\n\n### ``a ` b``"),
            ("heading with strikethrough", "## A ~~struck~~ word and ~one~ tilde"),
            ("heading with link and image", "# See [the page](https://example.org) and ![a picture](pic.png)"),
            ("heading with breaks", "Setext with a\nsoft break  \nand a hard one\n==="),
            ("heading with a comment", "# Head <!-- note --> tail\n\n## <!-- only -->"),
            ("heading with a page marker", "# Head \(p7) tail\n\nBody"),
            ("heading with a target", "## Head \(t2) tail\n\nBody"),
            ("heading with only a marker", "# \(p7)\n\nBody\n\n## \(t2)\n\nMore"),
            ("heading spelling a comment", "# About \\<!-- comments\n\n## `<!--` in code\n\n### &lt;!-- entity"),
            ("heading with raw html", "# A <b>bold</b> head <br/> end"),
            ("heading with entities", "# Fish &amp; Chips &copy; &#8212; &nosuch;"),
            ("heading with smart punctuation", "# \"Quoted\" -- and 'single' --- dots..."),
            ("repeated headings", "# Same\n\ntext\n\n# Same\n\ntext\n\n# Same"),
            ("heading in a quote and a list", "> # Quoted head\n> body\n\n- ## Item head\n  body"),

            // Emphasis and inline text.
            ("emphasis", "*a* _b_ **c** __d__ ***e*** ~~f~~ ~g~ *nested **strong** inside*"),
            ("unbalanced emphasis", "*open and **more and _under and ~~tilde and `tick"),
            ("intraword emphasis", "snake_case_word and star*in*word and 2*3*4"),
            ("escapes", "\\*not\\* \\_not\\_ \\# \\> \\- \\[x\\] \\\\ \\` \\<b\\> \\& \\!"),
            ("every escaped punctuation", "\\!\\\"\\#\\$\\%\\&\\'\\(\\)\\*\\+\\,\\-\\.\\/\\:\\;\\<\\=\\>\\?\\@\\[\\\\\\]\\^\\_\\`\\{\\|\\}\\~"),
            ("smart quotes", "\"Double\" and 'single' and it's and '90s and \"nested 'inner' quote\""),
            ("smart dashes and dots", "a--b c---d e----f g-----h i... j.... k . . ."),
            ("entities", "&amp; &lt; &gt; &quot; &apos; &nbsp; &copy; &#65; &#x41; &#0; &#xD800; &nosuch; &amp"),
            ("inline code", "`code` and ``a ` b`` and ` spaced ` and `` and `unclosed"),
            ("code with markup inside", "`*not emphasis*` `<!-- not a comment -->` `&amp;` `[x](y)`"),
            ("inline attributes", "^[styled words](rainbow: 'extreme') and ^[more](a: b, c: d) and ^[*slanted*](x)"),
            ("at signs and directives", "@Directive {\n  inside\n}\n\n@mention and \\param name text"),

            // Links and images.
            ("links", "[text](https://example.org) [mail](mailto:a@example.org) [local](chapter2.html) [empty]() [script](javascript:alert(1))"),
            ("link titles", "[text](https://example.org \"A title\") [text](<https://example.org/a b> 'single')"),
            ("reference links", "[text][ref] and [ref] and [missing][nowhere]\n\n[ref]: https://example.org/ref \"Reference\""),
            ("autolinks", "<https://example.org/auto> <mailto:b@example.org> <not a link> https://example.org/bare www.example.org"),
            ("link with markup inside", "[*slanted* and `code` and **strong**](https://example.org)"),
            ("link with spaces around its address", "[text]( https://example.org/spaced )"),
            ("images", "![alt words](pic.png) ![](empty.png) ![*slanted* alt](pic.png \"title\") ![ref alt][pic]\n\n[pic]: other.png"),
            ("image inside a link", "[![alt](pic.png)](https://example.org) and [text ![alt](pic.png) more](https://example.org)"),
            ("link across a soft break", "[first\nsecond](https://example.org)"),

            // Lists.
            ("bullet list", "- one\n- two\n- three"),
            ("ordered list", "1. one\n2. two\n3. three"),
            ("ordered list starts", "7. seven\n8. eight\n\ntext\n\n0. zero\n\ntext\n\n999999999. large\n\ntext\n\n1234567890. no list"),
            ("ordered list with parentheses", "1) one\n2) two"),
            ("loose list", "- one\n\n- two\n\n  second paragraph\n\n- three"),
            ("nested lists", "- a\n  - b\n    - c\n      1. d\n      2. e\n  - f\n- g"),
            ("list with other blocks", "- item\n\n  > quote in item\n\n  ```\n  code in item\n  ```\n\n  | a | b |\n  |---|---|\n  | c | d |\n- next"),
            ("task list", "- [ ] open\n- [x] done\n- [X] done too\n- [y] not a task\n- [ ]\n- [x]no space"),
            ("empty list items", "-\n- \n- words\n1.\n2. "),
            ("list markers", "* star\n\n+ plus\n\n- dash\n- dash two\n* star again"),
            ("list interrupted by text", "- item\ncontinues lazily\n\nparagraph\n1. not interrupting\n2. two"),
            ("ten nested lists", lists(10)),

            // Quotes.
            ("block quote", "> quoted words\n> on two lines\n\nafter"),
            ("nested quotes", "> one\n>> two\n>>> three\n>\n> back to one"),
            ("quote with blocks", "> # head\n>\n> - a\n> - b\n>\n> ```\n> code\n> ```\n>\n> | a | b |\n> |---|---|\n> | c | d |"),
            ("lazy quote", "> quoted\ncontinues lazily\n\n> another"),
            ("quote in list in quote", "> - item\n>   > inner quote\n>   >\n>   > - deep item"),
            ("twelve nested quotes", quotes(12)),

            // Code blocks.
            ("fenced code", "```\nline one\n\nline three\n```"),
            ("fenced code with a language", "```swift\nlet x = 1 // *not* emphasis\n```\n\n~~~ text more\ntildes\n~~~"),
            ("indented code", "    indented code\n      keeps spaces\n\n    after a blank line\n\ntext"),
            ("empty code blocks", "```\n```\n\ntext\n\n```\n\n```\n\ntext\n\n~~~\n\n\n~~~"),
            ("unclosed fence", "text\n\n```\nnever closed\nmore"),
            ("code holding markers", "```\n\(p7)\n<!-- comment -->\n# not a heading\n```"),
            ("code without a final line feed", "    code"),
            ("fence inside a list", "1. item\n   ```\n   code\n   ```\n2. next"),

            // Thematic breaks and raw HTML.
            ("thematic breaks", "above\n\n---\n\n***\n\n___\n\n- - -\n\nbelow"),
            ("html blocks", "<div class=\"x\">\ninside *div*\n</div>\n\n<p>paragraph</p>\n\n<script>\nlet a = 1;\n</script>\n\nafter"),
            ("inline html", "A <b>bold</b> word, a <br> break, <span class=\"x\">a span</span>, and </close>."),
            ("html block then text", "<div>\ntext in block\n\ntext after the blank line"),
            ("processing instructions and declarations", "<?xml version=\"1.0\"?>\n\n<!DOCTYPE html>\n\n<![CDATA[ data ]]>\n\ntext"),

            // Comments and markers.
            ("comment block", "before\n\n<!-- an ordinary comment -->\n\nafter"),
            ("comment across lines", "before\n\n<!-- a comment\nacross\nlines -->\n\nafter"),
            ("inline comment", "before <!-- inline --> after"),
            ("unclosed comment", "before\n\n<!-- never closed\n\nafter"),
            ("page marker alone", "before\n\n\(p7)\n\nafter"),
            ("page marker inline", "before \(p7) after and\(p8)inside a word"),
            ("page marker at the start", "\(p7)\n\nFirst words"),
            ("page marker at the end", "Last words\n\n\(p7)"),
            ("page marker before a heading", "\(p7)\n\n# Head\n\nBody"),
            ("page marker followed by words", "\(p7) Words on the marker's line.\n\nNext"),
            ("page marker followed by markup", "\(p7) *slanted* and **strong** [link](https://example.org)\n\nNext"),
            ("page marker followed by a heading", "\(p7) # Head on the marker's line\n\nBody"),
            ("page marker followed by a list", "\(p7) - item one\n\nNext"),
            ("several markers on a line", "\(p7) \(p8)\t\(t2) Words after three markers."),
            ("several markers and nothing else", "\(p7) \(p8)\n\nNext"),
            ("marker line inside marker line", "\(p7)> \(p8)> \(p7) inner words\n\nNext"),
            ("marker line with a comment after", "\(p7) <!-- other --> words\n\n\(p7)<!-- page: 9 --> tight"),
            ("indented marker lines", " \(p7) one space\n\n   \(p8) three spaces\n\n    \(p7) four spaces is code"),
            ("marker continued on the next lines", "\(p7) first line\nsecond line of the block\n\nNext"),
            ("marker in a quote and a list", "> \(p7)\n> quoted\n\n- \(p8)\n- \(p7) item words\n- item \(p8) end"),
            ("marker inside emphasis and a link", "*before \(p7) after* and [text \(p8) more](https://example.org) and `\(p7)`"),
            ("target alone", "before\n\n\(t2)\n\nafter"),
            ("target inline", "before \(t2) after"),
            ("target before a heading", "\(t2)\n\n## Target\n\nBody"),
            ("targets in a row", "\(t2)\n\n\(t3)\n\nBody\n\n\(t2) \(t3) words"),
            ("target followed by words", "\(t3) Words on the target's line."),
            ("malformed markers", "<!-- page:  -->\n\n<!-- page: -->\n\n<!--page: 7-->\n\n<!-- textmouth-heading: !!! -->\n\n<!-- page: a\nb -->\n\ntext"),
            ("long and odd page labels", "\(page("xii")) a \(page("A-3")) b \(page(String(repeating: "9", count: 40))) c \(page("Page")) d \(page("  spaced  out  ")) e"),
            ("chapter markers", "<!-- chapter: One -->\n# One\n\nFirst chapter.\n\n<!-- chapter: Two -->\nSecond chapter has no heading.\n\n<!-- chapter:  -->\nThird has no title."),
            ("text before the first chapter marker", "Orphan words.\n\n<!-- chapter: Only -->\nChapter words \(p7) here."),
            ("pages in whitespace and words", "end.\(p7) The next page. Hyphen-\(p8)ated word.\n\n\(p7)\n\n   \n\nLate"),

            // Tables.
            ("table", "| Name | Depth |\n|------|-------|\n| Pier | 4 |\n| Quay | 12 |"),
            ("table without outer pipes", "Name | Depth\n--- | ---\nPier | 4"),
            ("table with alignments", "| l | c | r |\n|:--|:-:|--:|\n| 1 | 2 | 3 |"),
            ("table with only a header", "| Name | Depth |\n|------|-------|"),
            ("table with empty cells", "| a |  | c |\n|---|---|---|\n|  |  |  |\n| d |  |  |\n|  |  | e |"),
            ("table with an empty header", "|  |  |\n|---|---|\n| a | b |"),
            ("table with ragged rows", "| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 | 5 |"),
            ("table with markup in cells", "| *slanted* | **strong** | `code` | [link](https://example.org) | ![alt](p.png) |\n|---|---|---|---|---|\n| ~~struck~~ | a<br>b | &amp; | \"quoted\" | x -- y |"),
            ("table with escaped pipes", "| a \\| b | `c \\| d` |\n|---|---|\n| e \\| f | g |"),
            ("table with spans", "| a | b | c |\n|---|---|---|\n| wide || x |\n| tall | y | z |\n| ^ | y2 | z2 |\n| \" | q | r |"),
            ("table with markers in cells", "| Name \(p7) | \(t2) Depth |\n|---|---|\n| \(p8) Pier | 4 \(p7) |\n| \(p8) | \(t3) |"),
            ("table with breaks in cells", "| a  \\\n b | c |\n|---|---|\n| d | e |"),
            ("table between paragraphs", "Words before.\n\n| a | b |\n|---|---|\n| c | d |\n\nWords after."),
            ("table then text without a blank line", "| a | b |\n|---|---|\n| c | d |\ntext right after\n\nlater"),
            ("text then table without a blank line", "text right before\n| a | b |\n|---|---|\n| c | d |"),
            ("two tables", "| a |\n|---|\n| b |\n\n| c |\n|---|\n| d |"),
            ("table in a list and a quote", "- | a | b |\n  |---|---|\n  | c | d |\n\n> | e | f |\n> |---|---|\n> | g | h |"),
            ("table cells running on", "| end.| start |\n|---|---|\n| a|b |\n|  \u{A0}  | \u{3000}wide |"),
            ("one column table", "| only |\n|---|\n| cell |\n| |"),
            ("not a table", "| a | b |\n| c | d |\n\na | b\n\n|---|---|"),

            // Deep trees.
            ("deep emphasis", "*a **b *c **d *e **f** e* d** c* b** a*"),
            ("nesting at the limit", quotes(128)),
            ("forty nested quotes", quotes(40)),
            ("forty nested lists", lists(40)),
            ("nesting past the limit", quotes(130)),
            ("quotes and lists in turn", (0..<12).map { $0.isMultiple(of: 2) ? "> " : "- " }.joined() + "bottom"),
        ]
        return cases.map { MarkdownCorpusCase(name: $0.0, markdown: $0.1) }
    }()

    // MARK: - Generated Mixes

    /// Pieces of Markdown that begin, end, or bend a structure. A mix joins
    /// some of them, and damage inserts one into a real book's Markdown.
    static let pieces: [String] = [
        "word", "two words", "Sentence one. Sentence two.", " ", "  ", "\n", "\n\n", "  \n", "\\\n", "\t", "\r\n", "\r",
        "*", "**", "***", "_", "__", "~", "~~", "`", "``", "```\n", "\n```\n", "~~~\n", "\n    ", "    code",
        "\n> ", "> ", ">> ", "\n- ", "- ", "\n  - ", "\n1. ", "3) ", "\n+ ", "- [ ] ", "- [x] ",
        "# ", "\n## ", "\n###### ", " #", "\n===\n", "\n---\n", "\n***\n", "\n- - -\n",
        "\n\n| a | b |\n|---|---|\n| ", " | ", "|", "||", " |\n", "\n|---|---|\n", "\n|:-:|\n", "^", "\\|",
        "<!-- page: 7 -->", "\n<!-- page: 8 -->\n", "\n<!-- page: 9 --> ", "<!-- chapter: Mixed -->\n",
        "<!-- textmouth-heading: eyJsZXZlbCI6MiwidGV4dCI6Ik1peGVkIFRhcmdldCJ9 -->",
        "\n<!-- textmouth-heading: eyJsZXZlbCI6MywidGV4dCI6IlNlY29uZCJ9 -->\n",
        "<!--", "-->", "<!-- note -->", "\n<!-- note -->\n", "<b>", "</b>", "<br/>", "\n<div>\n", "\n</div>\n", "<", ">",
        "&amp;", "&#x41;", "&#0;", "&#13;", "&#10;", "&nosuch;", "&", "[", "]", "[link](https://example.org/x)", "](https://example.org/y)",
        "[ref]", "\n[ref]: https://example.org/r\n", "![", "![alt](pic.png \"t\")", "<https://example.org/a>", "(", ")",
        "\"", "'", "--", "---", "...", "^[", "](k: v)", "\\", "\\*", "@", "@Dir {", "}", ":", "!",
        "\u{0}", "\u{2028}", "\u{A0}", "\u{200B}", "é", "👩‍👧", "\u{301}", "ß",
    ]

    /// How many mixes the corpus generates.
    static let mixCount = 3_000

    /// The mixes: each a few of `pieces` joined, chosen by a generator seeded
    /// from the mix's number, so every run on every machine makes the same.
    static func mixes() -> [MarkdownCorpusCase] {
        (0..<mixCount).map { number in
            var random = SoupDamage(key: "markdown-mix-\(number)")
            let count = 2 + random.next(below: 14)
            let markdown = (0..<count).map { _ in pieces[random.next(below: pieces.count)] }.joined()
            return MarkdownCorpusCase(name: "mix:\(number)", markdown: markdown)
        }
    }

    /// A long document of about `bytes` bytes: prose, headings, lists, a
    /// quote, code, a table, and markers in turn, the same on every run.
    static func longDocument(bytes: Int) -> String {
        var prose = TextPipelineFixtures.Prose(seed: 20_261_115)
        var markdown = ""
        var section = 0
        while markdown.utf8.count < bytes {
            section += 1
            markdown += "## Section \(section)\n\n"
            markdown += prose.words(90).joined(separator: " ") + "\n\n"
            markdown += page(String(section)) + "\n\n"
            markdown += "- " + prose.words(8).joined(separator: " ") + "\n- *" + prose.words(5).joined(separator: " ") + "*\n  1. nested\n  2. list\n\n"
            markdown += "> " + prose.words(20).joined(separator: " ") + "\n\n"
            markdown += "| Name | Value |\n|---|---|\n| row \(section) | \(section * 7) |\n| " + prose.words(3).joined(separator: " ") + " |  |\n\n"
            markdown += "```\ncode of section \(section)\n```\n\n"
            markdown += prose.words(40).joined(separator: " ") + " " + page("\(section)b") + " " + prose.words(40).joined(separator: " ") + "\n\n"
        }
        return markdown
    }

    // MARK: - Cuttings

    /// How many damaged cuttings each document of the corpus gets.
    static let cuttingsPerDocument = 8

    /// The most bytes of a document one cutting holds.
    static let cuttingBytes = 3_000

    /// Damaged cuttings of `markdown`, the document named `key`: each a
    /// stretch of at most `cuttingBytes` bytes (the whole text when it is
    /// shorter), with four pieces of `pieces` inserted and stretches deleted or
    /// repeated at places a generator seeded from the name picks. A real
    /// book's Markdown with structure broken into it reaches what neither the
    /// book nor a mix does.
    static func cuttings(of markdown: String, key: String) -> [MarkdownCorpusCase] {
        let bytes = Array(markdown.utf8)
        return (0..<cuttingsPerDocument).map { number in
            var random = SoupDamage(key: "\(key)#\(number)")
            let start = bytes.count > cuttingBytes ? random.next(below: bytes.count - cuttingBytes) : 0
            var cutting = Array(bytes[start..<min(bytes.count, start + cuttingBytes)])
            for _ in 0..<4 {
                let at = random.next(below: cutting.count + 1)
                let length = min(1 + random.next(below: 60), cutting.count - at)
                switch random.next(below: 4) {
                case 0: cutting.removeSubrange(at..<(at + length))
                case 1: cutting.insert(contentsOf: Array(cutting[at..<(at + length)]), at: at)
                default: cutting.insert(contentsOf: Array(pieces[random.next(below: pieces.count)].utf8), at: at)
                }
            }
            // A cut or an edit can split a character: each broken sequence reads as U+FFFD.
            return MarkdownCorpusCase(name: "cut:\(key)#\(number)", markdown: String(decoding: cutting, as: UTF8.self))
        }
    }

    // MARK: - Records

    /// How much of what the app makes of a text a record holds.
    struct Detail: OptionSet {
        let rawValue: Int
        /// What each export writer writes from the walk (HTML, RTF, Markdown,
        /// EPUB, and braille's blocks).
        static let writers = Detail(rawValue: 1)
        /// What the reader reads under each of `treeLimits`.
        static let treeLimits = Detail(rawValue: 2)
        /// The writers' HTML and Markdown in full, not as digests.
        static let readableWriters = Detail(rawValue: 4)
    }

    /// The limits on the tree's depth a record with `Detail.treeLimits` reads under.
    static let treeLimits = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 16]

    /// The book every export of the corpus is made for.
    static let book = ExportBookDetails(
        title: "Corpus Book", author: "Corpus Author", language: "en",
        identifier: UUID(uuidString: "5C0FFEE5-0000-4000-8000-00000000C0DE")
    )

    /// The day every EPUB of the corpus says it was made on.
    static let exportDate = Date(timeIntervalSince1970: 1_794_700_800)

    /// A short name for `text` that changes whenever any byte of it does.
    static func digest(_ text: String) -> String {
        TextPipelineFixtures.digest(text)
    }

    /// The record of `markdown`: lines that say everything the reader
    /// (`MarkdownDocParser`) and the export walk (`ExportDocumentWalker`) make
    /// of it, and with `Detail.writers` what each writer writes from the walk.
    /// Two walks that give one record read the text alike.
    /// - Parameter scratch: A folder the EPUB writer may write in, needed with `Detail.writers`.
    static func record(of markdown: String, detail: Detail = [], scratch: URL? = nil) -> String {
        var lines: [String] = []

        // The reader, as an importer calls it: the whole text, markers unread.
        lines.append("-- read whole")
        lines += chapterLines { try MarkdownDocParser.parseChapter(markdown: markdown, title: "Corpus") }

        // The reader, as a book is opened: each chapter of the cache, markers read and unread.
        var sections = MarkdownCacheService.splitChapters(markdown)
        if sections.isEmpty { sections = [(title: "", content: markdown)] }
        for (number, section) in sections.enumerated() {
            for readsMarkers in [true, false] {
                lines.append("-- read chapter \(number) \(quoted(section.title)) markers \(readsMarkers ? "read" : "unread")")
                lines += chapterLines {
                    try MarkdownDocParser.parseChapter(
                        markdown: section.content, title: section.title, includeNavigationHeadings: readsMarkers
                    )
                }
            }
        }

        // The reader held to a shallow tree, so the walk's own count of levels is recorded.
        if detail.contains(.treeLimits) {
            for limit in treeLimits {
                var limits = MarkupGuard.Limits.standard
                limits.deepestTree = limit
                let read = MarkupGuard.$limits.withValue(limits) {
                    chapterLines {
                        try MarkdownDocParser.parseChapter(markdown: markdown, title: "Corpus", includeNavigationHeadings: true)
                    }
                }
                lines.append("-- tree limit \(limit): \(digest(read.joined(separator: "\n"))) \(read.first ?? "")")
            }
        }

        // The export walk, for a writer of the words alone and for one of the book's structure.
        for (name, options) in [("words", ExportWalkOptions.plain), ("structure", ExportWalkOptions.bookStructure)] {
            lines.append("-- export \(name)")
            do {
                let document = try ExportDocumentWalker.document(fromMarkdown: markdown, book: book, options: options)
                lines += documentLines(document)
                if detail.contains(.writers) {
                    lines += writerLines(document, structure: options == .bookStructure, detail: detail, scratch: scratch)
                }
            } catch {
                lines.append("failed: \(String(describing: error))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: The Reader's Chapter

    /// The lines of the chapter `read` gives, or one line saying it was refused.
    private static func chapterLines(_ read: () throws -> Chapter) -> [String] {
        let chapter: Chapter
        do {
            chapter = try read()
        } catch {
            return ["refused: \(String(describing: error))"]
        }
        var lines = ["text \(quoted(chapter.text))", "title \(quoted(chapter.title))"]
        for heading in chapter.headings {
            lines.append(
                "heading \(heading.level) at \(heading.characterOffset) chapter \(heading.chapterIndex) "
                    + "\(quoted(heading.text)) id \(quoted(heading.id))"
            )
        }
        for page in chapter.pages {
            lines.append("page \(quoted(page.label)) at \(page.characterOffset) chapter \(page.chapterIndex)")
        }
        lines.append("heading ranges \(chapter.headingRanges.count)")
        return lines
    }

    // MARK: The Export Document

    /// The lines of `document`: its title heading, its chapters' starts, and
    /// its blocks, each block's children indented under it.
    private static func documentLines(_ document: ExportDocument) -> [String] {
        var lines: [String] = []
        if let title = document.titleHeading {
            lines.append("title heading \(title.level) #\(title.id) \(runsText(title.runs))")
        }
        for start in document.chapterStarts {
            lines.append("chapter starts at block \(start.blockIndex) \(quoted(start.title))")
        }
        appendBlocks(document.blocks, indent: "", to: &lines)
        return lines
    }

    /// Appends a line for each of `blocks`, and its children's under it.
    private static func appendBlocks(_ blocks: [ExportBlock], indent: String, to lines: inout [String]) {
        for block in blocks {
            switch block {
            case .heading(let heading):
                lines.append("\(indent)heading \(heading.level) #\(heading.id) \(runsText(heading.runs))")
            case .paragraph(let runs):
                lines.append("\(indent)paragraph \(runsText(runs))")
            case .list(let list):
                lines.append("\(indent)list \(list.isOrdered ? "ordered" : "bullets") start \(list.start) depth \(list.depth)")
                for item in list.items {
                    lines.append("\(indent)  item")
                    appendBlocks(item.blocks, indent: indent + "    ", to: &lines)
                }
            case .blockQuote(let quoted):
                lines.append("\(indent)quote")
                appendBlocks(quoted, indent: indent + "  ", to: &lines)
            case .codeBlock(let code):
                lines.append("\(indent)code \(quoted(code))")
            case .thematicBreak:
                lines.append("\(indent)break")
            case .table(let table):
                lines.append("\(indent)table \(table.hasHeaderRow ? "with" : "without") a header row")
                for row in table.rows {
                    lines.append("\(indent)  row \(row.map(quoted).joined(separator: " | "))")
                }
                for cellPage in table.cellPages {
                    lines.append(
                        "\(indent)  page in row \(cellPage.row) column \(cellPage.column) at \(cellPage.offset) \(pageText(cellPage.page))"
                    )
                }
            case .pageBreak(let page):
                lines.append("\(indent)page \(pageText(page))")
            case .navigationTarget(let target):
                lines.append("\(indent)target \(targetText(target))")
            }
        }
    }

    /// `runs` on one line, each with its style.
    private static func runsText(_ runs: [ExportRun]) -> String {
        runs.map { run in
            var text = quoted(run.text)
            if run.isEmphasis { text += " emphasis" }
            if run.isStrong { text += " strong" }
            if run.isCode { text += " code" }
            if let link = run.link { text += " link \(quoted(link))" }
            if let page = run.pageBreak { text += " page \(pageText(page))" }
            if let target = run.navigationTarget { text += " target \(targetText(target))" }
            return "[\(text)]"
        }.joined(separator: " ")
    }

    /// A page start's label and id.
    private static func pageText(_ page: ExportPageBreak) -> String {
        "\(quoted(page.label)) #\(page.id)"
    }

    /// A contents target's level, text, and id.
    private static func targetText(_ target: ExportNavigationTarget) -> String {
        "\(target.level) \(quoted(target.text)) #\(target.id)"
    }

    // MARK: The Writers

    /// What the writers that read a document walked with these options write
    /// of `document`: HTML, RTF, Markdown, and braille's blocks for the words
    /// alone, and the EPUB's files for the book's structure. Each is a digest,
    /// or with `Detail.readableWriters` the HTML and the Markdown in full.
    private static func writerLines(_ document: ExportDocument, structure: Bool, detail: Detail, scratch: URL?) -> [String] {
        guard !structure else {
            return ["epub \(outcome { try epubSummary(of: document, scratch: scratch) })"]
        }
        let readable = detail.contains(.readableWriters)
        let html = outcome { try HTMLExportWriter.page(of: document) }
        let markdown = outcome { try MarkdownExportWriter.markdown(of: document) }
        return [
            "html \(readable ? quoted(html) : digest(html))",
            "markdown \(readable ? quoted(markdown) : digest(markdown))",
            "rtf \(digest(outcome { try RTFExportWriter.rtf(of: document) }))",
            "braille blocks \(digest(String(reflecting: BrailleExportBlocks.printBlocks(of: document))))",
        ]
    }

    /// What `write` gives, or a line naming the error it throws, so a refusal
    /// is part of the record too.
    private static func outcome(_ write: () throws -> String) -> String {
        do {
            return try write()
        } catch {
            return "failed: \(String(describing: error))"
        }
    }

    /// One digest for the EPUB the writer makes of `document`: every file of
    /// the package, in the order of their paths, each with its bytes as they
    /// are once unpacked. The ZIP's own bytes are left out, since they change
    /// with the system's compressor.
    private static func epubSummary(of document: ExportDocument, scratch: URL?) throws -> String {
        guard let scratch else { return "not written" }
        let url = scratch.appendingPathComponent("\(UUID().uuidString).epub")
        let writer = EPUBExportWriter(modified: { exportDate })
        try writer.write(document, options: NoTextExportOptions(), to: url, cancellation: BookExportCancellation())
        let archive = try Archive(url: url, accessMode: .read, pathEncoding: nil)
        var files: [(path: String, digest: String)] = []
        for entry in archive {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            files.append((entry.path, TextPipelineFixtures.digest(data)))
        }
        files.sort { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
        return digest(files.map { "\($0.path) \($0.digest)" }.joined(separator: "\n")) + " in \(files.count) files"
    }

    // MARK: Quoting

    /// `text` between double quotes on one line: a backslash, a double quote,
    /// and every control character, line separator, and byte order mark
    /// written as an escape, so that a record's lines are the record's own and
    /// an invisible character is seen.
    static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                let value = scalar.value
                let isHidden = value < 0x20 || (0x7F...0x9F).contains(value) || value == 0x2028 || value == 0x2029
                    || value == 0xFEFF || (0x200B...0x200F).contains(value)
                if isHidden {
                    result += "\\u{\(String(value, radix: 16))}"
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}
