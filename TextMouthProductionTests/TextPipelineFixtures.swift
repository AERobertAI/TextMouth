import CryptoKit
import Darwin
import Foundation
import XCTest
import ZIPFoundation
@testable import TextMouth

/// The inputs shared by the text pipeline's golden and benchmark tests
/// (PERF18 to PERF25 in TODO-2026-09-04.md).
///
/// - The synthetic books are the performance review's own generators, with
///   its seeds and shapes, so a benchmark here measures what the review
///   measured, and a golden digest describes the same text at any size.
/// - The generated EPUBs exercise every navigation path the EPUB reader
///   has: a navigation document, an NCX, a guide, contents pages early and
///   late in the reading order, fragment destinations, hidden content, page
///   lists, landmarks, and a damaged or incomplete reading order.
/// - Digests name bytes and reading content compactly, so a golden test can
///   hold the output recorded before a change and compare it, byte for
///   byte, with the output after.
enum TextPipelineFixtures {

    // MARK: - Digests

    /// A short name for `data` that changes whenever any byte does: the
    /// first 16 hexadecimal digits (64 bits) of its SHA-256.
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// `digest(_:)` of `text`'s UTF-8 bytes.
    static func digest(_ text: String) -> String {
        digest(Data(text.utf8))
    }

    /// A digest of everything a reader takes from `chapters`: each title,
    /// reading text, and heading (level, UTF-16 offset, and label), and,
    /// from `index` when one is given, each chapter's word and character
    /// counts and the book's totals.
    static func digest(of chapters: [Chapter], index: BookContentIndex? = nil) -> String {
        var description = ""
        for (number, chapter) in chapters.enumerated() {
            description += "chapter \(number): \(chapter.title)\n\(chapter.text)\n"
            for heading in chapter.headings {
                description += "heading \(heading.level) at \(heading.characterOffset): \(heading.text)\n"
            }
            if let index, number < index.chapters.count {
                let counts = index.chapters[number]
                description += "words \(counts.wordCount), characters \(counts.characterCount)\n"
            }
        }
        if let index {
            description += "total words \(index.totalWordCount), characters \(index.totalCharacterCount)\n"
        }
        return digest(description)
    }

    // MARK: - Repository Fixtures

    /// TestData's books whose output the golden tests record, by file name:
    /// every book the repository holds except its PDFs, whose text comes
    /// from PDFKit and Vision, which change with macOS, and which none of
    /// PERF18 to PERF25 touch. They are named rather than found in the
    /// folder, which holds more in some checkouts than in others, so every
    /// checkout compares the same books with the same records.
    static let testDataBookNames = [
        "alice.docx", "alice.epub", "daisy202_test.zip", "frankenstein.html", "hyperion_daisy.zip",
        "lathe_of_heaven_daisy.zip", "pride.txt", "sample.md", "test_book.docx", "wipo-treaty-d202-text-only.zip",
    ]

    /// The large DAISY audio books some checkouts keep in TestData beside
    /// its own books, downloaded separately and ignored by git, so most
    /// checkouts lack them. Their output is recorded too, and compared
    /// wherever they are present.
    static let optionalTestDataBookNames = ["are-you-ready-d3-audio.zip", "fire-safety-d202-audio.zip"]

    /// TestData's recorded books with their files: every one of
    /// `testDataBookNames`, and those of `optionalTestDataBookNames` that
    /// this checkout holds.
    /// - Throws: `TestError.fileNotFound` when one of `testDataBookNames`
    ///   is missing.
    static func testDataBooks() throws -> [(name: String, url: URL)] {
        let required = try testDataBookNames.map { (name: $0, url: try requireFile($0)) }
        let optional = optionalTestDataBookNames.compactMap { name -> (name: String, url: URL)? in
            let url = URL(fileURLWithPath: testFilePath(name))
            return FileManager.default.fileExists(atPath: url.path) ? (name, url) : nil
        }
        return required + optional
    }

    // MARK: - Synthetic Prose

    /// English-like words with the curly quotes, dashes, and occasional
    /// accented words of a typical ebook, drawn by the review's generator.
    struct Prose {
        private var random: SeededGenerator

        /// The review's vocabulary: common words, some longer ones, and a
        /// few with Latin-1 letters.
        private static let vocabulary: [String] = {
            let base = """
            the of and to a in was he that it his her with as had for she on at by not be but from \
            they which you were this all one have are their we so would there what when been into \
            said could who more about them out if will no up some than then like only other its \
            time over now our also after first new very before through where just most well down \
            between should never these life much without under each long while away again still \
            house evening window river captain morning silence harbor letter village garden doctor \
            engine station kingdom twilight orchard lantern question answer journey distance machine \
            across against already although because behind beneath beside beyond during either \
            enough everything finally however instead itself nothing perhaps quickly rather \
            somewhere suddenly therefore together toward whatever whether yesterday tomorrow
            """.split(separator: " ").map(String.init)
            return base + ["café", "naïve", "Zürich", "façade", "rôle", "über", "mañana", "Ångström"]
        }()

        /// Prose drawn from the generator seeded with `seed`.
        init(seed: UInt64) {
            random = SeededGenerator(state: seed)
        }

        /// One word, sometimes quoted, capitalized, or followed by punctuation.
        mutating func word() -> String {
            var word = Self.vocabulary[Int(random.next() % UInt64(Self.vocabulary.count))]
            switch random.next() % 100 {
            case 0..<3: word = "“" + word.capitalized
            case 3..<6: word += "”"
            case 6..<12: word += ","
            case 12..<16: word += "."
            case 16..<18: word += "—"
            case 18..<19: word += "’s"
            default: break
            }
            return word
        }

        /// `count` words.
        mutating func words(_ count: Int) -> [String] {
            (0..<count).map { _ in word() }
        }

        /// A number in `range`.
        mutating func number(_ range: Range<Int>) -> Int {
            range.lowerBound + Int(random.next() % UInt64(range.count))
        }
    }

    // MARK: - Synthetic Books

    /// Plain text of about `bytes` bytes: paragraphs wrapped at 70 columns
    /// with blank lines between them, and an all-caps chapter line every
    /// 150 paragraphs.
    static func plainText(bytes target: Int) -> String {
        var prose = Prose(seed: 7)
        var text = ""
        text.reserveCapacity(target + 4_096)
        var paragraphs = 0
        var chapter = 0
        while text.utf8.count < target {
            if paragraphs % 150 == 0 {
                chapter += 1
                text += "CHAPTER \(chapter)\n\n"
            }
            text += wrapped(prose.words(prose.number(40..<140)), width: 70) + "\n\n"
            paragraphs += 1
        }
        return text
    }

    /// One HTML document of about `bytes` bytes: chapters in divs with h2
    /// headings, paragraphs wrapped over source lines, and a table every 40
    /// paragraphs. With `inlineMarkup`, each paragraph also holds one
    /// emphasis and one link, the markup whose conversion PERF18 measured.
    static func html(bytes target: Int, inlineMarkup: Bool = true) -> String {
        var prose = Prose(seed: 11)
        var html = "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>Synthetic Book</title></head><body>\n"
        html.reserveCapacity(target + 4_096)
        var paragraphs = 0
        var chapter = 0
        while html.utf8.count < target {
            if paragraphs % 120 == 0 {
                if chapter > 0 { html += "</div>\n" }
                chapter += 1
                html += "<div class=\"chapter\" id=\"ch\(chapter)\"><h2 id=\"c\(chapter)\">Chapter \(chapter)</h2>\n"
            }
            if paragraphs % 40 == 39 {
                html += "<table class=\"data\">\n<tr>" + (0..<4).map { _ in "<th>\(prose.word())</th>" }.joined() + "</tr>\n"
                for _ in 0..<6 {
                    html += "<tr>" + (0..<4).map { _ in "<td>\(prose.words(3).joined(separator: " "))</td>" }.joined() + "</tr>\n"
                }
                html += "</table>\n"
            }
            var words = prose.words(prose.number(40..<140))
            if inlineMarkup {
                let emphasis = prose.number(0..<max(1, words.count - 3))
                words[emphasis] = "<em>" + words[emphasis]
                words[emphasis + 2] += "</em>"
                let link = prose.number(0..<words.count)
                words[link] = "<a href=\"#c\(prose.number(1..<max(2, chapter + 1)))\">\(words[link])</a>"
            }
            html += "<p class=\"para\">" + wrapped(words, width: 90) + "</p>\n"
            paragraphs += 1
        }
        html += "</div>\n</body></html>\n"
        return html
    }

    /// Markdown of about `bytes` bytes: ATX chapter headings, wrapped
    /// paragraphs with emphasis and links, and a five-column table of ten
    /// rows every 15 paragraphs.
    static func markdownWithTables(bytes target: Int) -> String {
        var prose = Prose(seed: 13)
        var markdown = ""
        markdown.reserveCapacity(target + 4_096)
        var paragraphs = 0
        var chapter = 0
        while markdown.utf8.count < target {
            if paragraphs % 100 == 0 {
                chapter += 1
                markdown += "# Chapter \(chapter)\n\n"
            }
            if paragraphs % 15 == 14 {
                markdown += "| " + (0..<5).map { _ in prose.word() }.joined(separator: " | ") + " |\n"
                markdown += "|---|---|---|---|---|\n"
                for _ in 0..<10 {
                    markdown += "| " + (0..<5).map { _ in prose.words(3).joined(separator: " ") }.joined(separator: " | ") + " |\n"
                }
                markdown += "\n"
            }
            var words = prose.words(prose.number(40..<140))
            let emphasis = prose.number(0..<max(1, words.count - 3))
            words[emphasis] = "*" + words[emphasis]
            words[emphasis + 1] += "*"
            let link = prose.number(0..<words.count)
            words[link] = "[\(words[link])](https://example.com/\(paragraphs))"
            markdown += wrapped(words, width: 72) + "\n\n"
            paragraphs += 1
        }
        return markdown
    }

    /// A content.md of `chapters` chapters, each its marker line and
    /// `paragraphs` one-line paragraphs of a dozen words with blank lines
    /// between them: shaped like the cache of a large anthology, whose
    /// opening splits hundreds of thousands of lines into its chapters.
    static func multiChapterCache(chapters: Int, paragraphs: Int) -> String {
        var prose = Prose(seed: 19)
        var cache = ""
        for chapter in 1...chapters {
            cache += "<!-- chapter: Story \(chapter) -->\n# Story \(chapter)\n\n"
            for _ in 0..<paragraphs {
                cache += prose.words(12).joined(separator: " ") + "\n\n"
            }
        }
        return cache
    }

    /// `words` joined by spaces, with a line break before any word that
    /// would pass `width` columns.
    static func wrapped(_ words: [String], width: Int) -> String {
        var lines: [String] = []
        var line = ""
        for word in words {
            if !line.isEmpty, line.count + 1 + word.count > width {
                lines.append(line)
                line = ""
            }
            line += line.isEmpty ? word : " " + word
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }

    // MARK: - Edge Strings

    /// The review's strings where a fast path and the rule it replaces
    /// could part: clusters that mix whitespace with marks, controls,
    /// prepended scalars, emoji, and other scripts; a byte-order mark; and
    /// lines whose letters change, or do not, when uppercased.
    static let edgeTexts: [String] = [
        "", " ", "a", " \u{301}a", "\t\u{301}a", "a\r\nb", "\r\n\u{301}x", "\u{600} a", "x\u{200D} y",
        "\u{3000}\u{301}z", "e\u{301} f", "👍🏽 ok", "🇺🇸🇬🇧 x", "\u{85}\u{301}b", "\u{2028}\u{308}c",
        "\u{A0}\u{20DD}d", "한국어 단어", "नमस्ते दुनिया", "مرحبا بالعالم", "a\u{903} b", " \u{903}c",
        "word\u{FEFF}word", "“quoted” — dash…", "x \u{200B} y", "tab\there\u{0B}vt\u{0C}ff",
        "\u{1F469}\u{200D}\u{1F4BB} coder", "a\r", "\r", "\n\n", " a ", "\u{0}\u{1} \u{7F}",
        "a\u{FEFF}b\u{FEFF}",
        "CHAPTER ONE\nSTRASSE\nstraße\nﬁNAL\nǅOKTOR\nÉCOLE\nΣΟΦΙΑ\n#HEADING\nA B C\nAB\n",
    ]

    /// Pieces of text whose neighbors decide where Characters begin and end:
    /// every kind of whitespace, controls, combining and enclosing marks,
    /// joiners, a prepended scalar, a spacing mark, Hangul jamo, regional
    /// indicators, emoji and their modifiers, ASCII punctuation, and letters.
    static let trickyPieces: [String] = [
        "a", "Z", "7", " ", "  ", "\t", "\n", "\r", "\r\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{A0}", "\u{1680}",
        "\u{2000}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{3000}", "\u{301}", "\u{308}", "\u{20DD}",
        "\u{200C}", "\u{200D}", "\u{200B}", "\u{FEFF}", "\u{600}", "\u{903}", "é", "e\u{301}", "ß", "ǅ",
        "\u{1100}", "\u{1161}", "\u{11A8}", "한", "日", "👍", "🏽", "🇺", "🇸", "\u{1F469}", "—", "“", "*",
        "\\", "#", "<", "&", "\u{0}", "\u{7F}", "-", "=",
    ]

    /// `count` strings of up to `maximumPieces` pieces drawn from
    /// `trickyPieces` by a generator seeded with `seed`.
    static func randomTrickyTexts(count: Int, maximumPieces: Int = 24, seed: UInt64) -> [String] {
        var random = SeededGenerator(state: seed)
        return (0..<count).map { _ in
            let pieces = Int(random.next() % UInt64(maximumPieces + 1))
            return (0..<pieces).map { _ in
                trickyPieces[Int(random.next() % UInt64(trickyPieces.count))]
            }.joined()
        }
    }

    // MARK: - Generated EPUBs

    /// A file at `path` in a generated archive holding `text` as UTF-8.
    private static func file(_ path: String, _ text: String) -> TestZIPEntry {
        TestZIPEntry(path, Data(text.utf8))
    }

    /// The archive's first two members, which every EPUB begins with.
    private static func packageStart(opf: String = "OEBPS/package.opf") -> [TestZIPEntry] {
        [
            file("mimetype", "application/epub+zip"),
            file("META-INF/container.xml", """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="\(opf)" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """),
        ]
    }

    /// A package document whose metadata element holds `metadata` beside
    /// the identifier, naming one chapter, `chapter.xhtml`, in its reading
    /// order, as `minimalEPUB(packageDocument:)` holds it. The `opf` prefix
    /// is declared, for the role attributes of EPUB 2.
    static func packageDocument(metadata: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:opf="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="uid">urn:uuid:5d1c0e7a-2b4f-4c8e-9a6d-3f2e1b0c9d8e</dc:identifier>
        \(metadata)
        </metadata>
        <manifest><item id="c1" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="c1"/></spine>
        </package>
        """
    }

    /// The smallest EPUB: `opf` as its package document, at
    /// OEBPS/package.opf, and one short chapter at OEBPS/chapter.xhtml,
    /// which the package document is expected to name.
    static func minimalEPUB(packageDocument opf: String) -> [TestZIPEntry] {
        packageStart() + [
            file("OEBPS/package.opf", opf),
            file("OEBPS/chapter.xhtml", xhtml(title: "One", body: "<h1>One</h1><p>A page of words.</p>")),
        ]
    }

    /// An XHTML document titled `title` whose body is `body`.
    private static func xhtml(title: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>\(title)</title></head>
        <body>
        \(body)
        </body></html>
        """
    }

    /// An EPUB 3 book that takes every navigation path at once.
    ///
    /// - Its navigation document names chapters and fragments (one that no
    ///   element carries), hides one branch, and holds a page list and
    ///   landmarks; its NCX and its guide name more.
    /// - Its reading order holds a blank cover, an early contents page, four
    ///   chapters, and a late contents page that alone names destinations in
    ///   earlier chapters, beside an image, a plain-text document, an item
    ///   the manifest does not list, and one missing from the archive.
    /// - The chapters hold emphasis and links of every shape, named anchors,
    ///   lists, a table, preformatted text, code, a quotation, hidden
    ///   elements written in several cases, a page list and landmarks, and
    ///   a contents nav of their own. One chapter's markup never mentions
    ///   hiding; another mentions it only in its words.
    /// - The archive holds a second, later copy of one chapter, which a
    ///   reader must never take for the first.
    static func navigationEPUB() -> [TestZIPEntry] {
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="uid">urn:uuid:7a1d0c4e-5b55-4bd7-9a0e-3c1f2a9e0b11</dc:identifier>
        <dc:title>The Ferry Timetable Companion</dc:title><dc:creator>Ifeoma Szabo</dc:creator><dc:language>en</dc:language>
        </metadata>
        <manifest>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        <item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>
        <item id="contents" href="text/contents.xhtml" media-type="application/xhtml+xml"/>
        <item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
        <item id="plate" href="images/plate.jpg" media-type="image/jpeg"/>
        <item id="ch2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
        <item id="notes" href="notes.txt" media-type="text/plain"/>
        <item id="ch3" href="text/ch3.xhtml" media-type="application/xhtml+xml"/>
        <item id="lost" href="text/lost.xhtml" media-type="application/xhtml+xml"/>
        <item id="ch4" href="text/ch4.xhtml" media-type="application/xhtml+xml"/>
        <item id="back" href="text/index.xhtml" media-type="application/xhtml+xml"/>
        <item id="guide-toc" href="text/guide.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine toc="ncx">
        <itemref idref="cover"/><itemref idref="contents"/><itemref idref="ch1"/><itemref idref="plate"/>
        <itemref idref="ch2"/><itemref idref="notes"/><itemref idref="ghost"/><itemref idref="ch3"/>
        <itemref idref="lost"/><itemref idref="ch4"/><itemref idref="back"/>
        </spine>
        <guide><reference type="toc" title="Contents" href="text/guide.xhtml#gt"/></guide>
        </package>
        """
        let nav = xhtml(title: "Contents", body: """
        <nav epub:type="toc" id="toc"><h1>Contents</h1><ol>
        <li><a href="text/ch1.xhtml">Departures</a><ol>
          <li><a href="text/ch1.xhtml#weekday">Weekday sailings</a></li>
          <li><a href="text/ch1.xhtml#fares">Fares table</a></li>
          <li><a href="text/ch1.xhtml#code-target">Signal codes</a></li>
        </ol></li>
        <li><a href="text/ch2.xhtml#crossing">The crossing</a><ol>
          <li><a href="text/ch2.xhtml#deck">On deck</a></li>
          <li><a href="text/ch2.xhtml#nowhere">A destination no element carries</a></li>
        </ol></li>
        <li><a href="text/ch3.xhtml">Arrivals</a></li>
        <li hidden=""><a href="text/ch3.xhtml#hidden-branch">A hidden branch</a></li>
        <li><a href="https://example.invalid/ferry">The operator's site</a></li>
        </ol></nav>
        <nav epub:type="page-list"><ol><li><a href="text/ch1.xhtml#page1">1</a></li></ol></nav>
        <nav epub:type="landmarks"><ol><li><a epub:type="bodymatter" href="text/ch1.xhtml">Start</a></li></ol></nav>
        """)
        let ncx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
        <navPoint id="n1"><navLabel><text>Departures (NCX)</text></navLabel><content src="text/ch1.xhtml"/>
          <navPoint id="n1a"><navLabel><text>Night boats</text></navLabel><content src="text/ch1.xhtml#night"/></navPoint>
        </navPoint>
        <navPoint id="n2"><navLabel><text>On deck (NCX)</text></navLabel><content src="text/ch2.xhtml#deck"/></navPoint>
        <navPoint id="n4"><navLabel><text>Moorings</text></navLabel><content src="text/ch4.xhtml"/></navPoint>
        </navMap><pageList><pageTarget><navLabel><text>2</text></navLabel><content src="text/ch2.xhtml#page2"/></pageTarget></pageList></ncx>
        """
        let cover = xhtml(title: "Cover", body: "<div class=\"cover\" style=\"background:url(../images/plate.jpg)\"></div>")
        let contents = xhtml(title: "Contents page", body: """
        <div id="contents" class="toc"><p class="toc-title">Contents</p>
        <p><a href="ch2.xhtml#crossing">The crossing, from the contents page</a></p>
        <p><a href="ch3.xhtml#harbor-notes">Harbor notes</a></p>
        <p><a href="ch3.xhtml">Arrivals, from the contents page</a></p>
        </div>
        <p>Read on for the <a href="ch1.xhtml#weekday">weekday times</a>, which are prose, not contents.</p>
        """)
        let chapter1 = xhtml(title: "Departures", body: """
        <section epub:type="chapter" id="departures">
        <h1 class="chapter-title"><a id="weekday"></a>Weekday <em>sailings</em> &amp; times</h1>
        <p class="first">Boats leave at <strong>six</strong>, <em>seven</em>, and <b>eight</b>; the <i>last</i> one at <em>nine <strong>sharp</strong> o’clock</em>.</p>
        <p>See <a href="ch2.xhtml#deck">the deck plan</a>, <em>or <a href="ch3.xhtml">the arrivals board</a> instead</em>, or <a href="ch4.xhtml"><b>the moorings</b></a>.</p>
        <p>Escapes stay literal: <em>*starred*</em> <i>[bracketed]</i> <b>"quoted"</b> <em>back\\slash\\</em> and <code>a`b</code> then <code>``</code>.</p>
        <p>Non-ASCII: Café <em>naïve façade</em> — “quoted” <a href="#weekday">Ångström</a> 👍🏽 and x<em> \u{301}mark</em>y and 日本<em>語</em>です.</p>
        <p>Touching: <em>one</em><em>two</em>, <em>three</em> <strong>four</strong>, a<em></em>b, a<em> </em>b, <em><code>code</code> after</em>, <em>line<br/>break</em>.</p>
        <p>Spaced <a href="ch2.xhtml"> link words </a> and <a href="a&lt;b&gt;\\c d">odd destination</a> and <a href="x.xhtml"><img alt=" Alt text " src="../images/plate.jpg"/></a>.</p>
        <p><a name="night"></a>Night boats run <span class="small">on Fridays</span>.<br/>Second line.<a id="page1" epub:type="pagebreak"></a></p>
        <ul><li id="item-a">First <em>item</em></li><li hidden="">A hidden item</li><li>Second item<ul><li>Nested item</li></ul></li></ul>
        <ol><li>One</li><li>Two</li></ol>
        <table id="fares"><tr><th>Route</th><th>Fare</th></tr><tr><td>North <em>pier</em></td><td>£4</td></tr><tr><td></td><td>5</td></tr></table>
        <pre id="code-target">signal  A
          signal B
        ``` fenced</pre>
        <blockquote><p>Quoted <em>words</em>.</p><p>Second quoted paragraph.</p></blockquote>
        <p hidden="hidden">This paragraph is hidden.</p>
        <div HIDDEN=""><h2>A hidden heading</h2><p>Hidden words.</p></div>
        <p Hidden>Mixed-case hidden words.</p>
        <nav epub:type="page-list"><ol><li><a href="#page1">i</a></li></ol></nav>
        <nav epub:type="landmarks"><a href="#weekday">Landmark</a></nav>
        <nav epub:type="toc"><h2>In this chapter</h2><ol><li><a href="#night">Night boats, from the chapter</a></li></ol></nav>
        <hr/>
        <p>After the rule.</p>
        </section>
        """)
        let chapter2 = xhtml(title: "The Crossing", body: """
        <div class="calibre1" id="crossing" style="margin:0">
        <h2 class="calibre3"><span class="bold">The Crossing</span></h2>
        <p class="calibre5" style="text-indent:1em">The water was <em class="italic">calm</em> and the <a class="link" href="ch1.xhtml#weekday">schedule</a> held.</p>
        <p class="calibre5" id="deck"><span class="smcap">On deck</span> the wind <strong class="bold">rose</strong>.</p>
        <div class="calibre6"><p class="calibre5">Inside a <i class="calibre7">wrapper</i>.<a id="page2"></a></p></div>
        </div>
        """)
        let chapter3 = xhtml(title: "Arrivals", body: """
        <h1 id="arrivals">Arrivals</h1>
        <p>The ticket office kept a hidden drawer, and nobody marked it hidden in the markup.</p>
        <h2 id="harbor-notes">Harbor notes</h2>
        <p id="late-only">Notes only the late contents page names.</p>
        <div hidden=""><div id="toc"><a href="ch4.xhtml#ghost-late">A contents page that is hidden</a></div></div>
        <p id="hidden-branch">Text a hidden contents branch names.</p>
        """)
        let chapter4 = xhtml(title: "", body: """
        <p class="calibre5">Moorings open the chapter without a heading.</p>
        <p class="calibre5" id="late1">The first mooring, named only from the back of the book.</p>
        <p class="calibre5"><span id="late2">The second</span> mooring.</p>
        """)
        let backMatter = xhtml(title: "Index", body: """
        <section epub:type="toc" id="back-toc"><h1>Index of places</h1><ol>
        <li><a href="ch4.xhtml#late1">First mooring</a></li>
        <li><a href="ch4.xhtml#late2">Second mooring</a></li>
        <li><a href="ch3.xhtml#late-only">Late notes</a></li>
        <li><a href="ch1.xhtml#night">Night boats again</a></li>
        <li><a href="ch2.xhtml#crossing">The crossing again</a></li>
        </ol></section>
        """)
        let guide = xhtml(title: "Guide contents", body: """
        <div id="gt"><a href="ch3.xhtml#harbor-notes">Harbor notes, from the guide</a> <a href="ch4.xhtml">Fourth, from the guide</a></div>
        <div id="other"><a href="ch1.xhtml#fares">Not the guide's fragment</a></div>
        """)
        return packageStart() + [
            file("OEBPS/package.opf", opf),
            file("OEBPS/nav.xhtml", nav),
            file("OEBPS/toc.ncx", ncx),
            file("OEBPS/text/cover.xhtml", cover),
            file("OEBPS/text/contents.xhtml", contents),
            file("OEBPS/text/ch1.xhtml", chapter1),
            TestZIPEntry("OEBPS/images/plate.jpg", Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])),
            file("OEBPS/text/ch2.xhtml", chapter2),
            file("OEBPS/notes.txt", "Plain notes the reading order cannot read."),
            file("OEBPS/text/ch3.xhtml", chapter3),
            file("OEBPS/text/ch4.xhtml", chapter4),
            file("OEBPS/text/index.xhtml", backMatter),
            file("OEBPS/text/guide.xhtml", guide),
            file("OEBPS/text/ch2.xhtml", xhtml(title: "Second copy", body: "<p>A LATER COPY THAT MUST NEVER BE READ</p>")),
        ]
    }

    /// An EPUB 2 book read through its NCX alone: nested navigation points,
    /// a file name with a space written percent-encoded, a document in a
    /// sibling folder, an id written with a character reference, a document
    /// in ISO Latin 1 with CR LF line endings, and hidden elements whose
    /// attribute names are written in capitals.
    static func ncxEPUB() -> [TestZIPEntry] {
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
        <dc:identifier id="uid" opf:scheme="ISBN">9780000000002</dc:identifier>
        <dc:title>Notes on Lock Keeping</dc:title><dc:creator>Teodor Okonkwo-Lind</dc:creator>
        </metadata>
        <manifest>
        <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        <item id="one" href="text/chapter%20one.xhtml" media-type="application/xhtml+xml"/>
        <item id="two" href="other/two.html" media-type="text/html"/>
        <item id="three" href="text/three.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine toc="ncx"><itemref idref="one"/><itemref idref="two"/><itemref idref="three"/></spine>
        </package>
        """
        let ncx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
        <navPoint id="a"><navLabel><text>Part One</text></navLabel><content src="text/chapter%20one.xhtml"/>
          <navPoint id="a1"><navLabel><text>The first   lock</text></navLabel><content src="text/chapter%20one.xhtml#sec1"/>
            <navPoint id="a1x"><navLabel><text>Gates</text></navLabel><content src="text/chapter%20one.xhtml#gates"/></navPoint>
          </navPoint>
        </navPoint>
        <navPoint id="b"><navLabel><text>Upstream</text></navLabel><content src="other/two.html#up"/></navPoint>
        <navPoint id="c"><navLabel><text>Three</text></navLabel><content src="text/three.xhtml"/></navPoint>
        </navMap></ncx>
        """
        let one = xhtml(title: "Part One", body: """
        <h1>Part One</h1>
        <p id="sec&#49;">The <EM>first</EM> lock opens <A HREF="#gates">at the gates</A>.</p>
        <P HIDDEN>Capital hidden words.</P>
        <DIV Hidden="hidden"><P>More capital hidden words.</P></DIV>
        <h3 id="gates">Gates</h3><p>Gates swing <strong>inward</strong>.</p>
        """)
        // ISO Latin 1 bytes: "é" and "ü" are single bytes that are not UTF-8.
        let two = "<html><head><title>Upstream</title></head><body>\r\n<p id=\"up\">Caf\u{E9} on the \u{FC}pper reach, <em>slow</em> water.</p>\r\n</body></html>\r\n"
        let three = xhtml(title: "Three", body: "<p>Three has no heading, and its title is <b>Three</b>.</p>")
        return packageStart(opf: "content.opf") + [
            file("content.opf", opf),
            file("toc.ncx", ncx),
            file("text/chapter one.xhtml", one),
            TestZIPEntry("other/two.html", two.data(using: .isoLatin1) ?? Data()),
            file("text/three.xhtml", three),
        ]
    }

    /// An EPUB shaped like the converted books most of the library holds:
    /// `documents` chapter files whose every element carries class and
    /// style attributes, each a heading and `paragraphs` paragraphs with
    /// emphasis, links, and spans; a navigation document and an NCX naming
    /// each chapter, and every fourth one by a fragment; and, ahead of the
    /// chapters in the archive, `images` small images, which every lookup
    /// of a chapter in the archive passes over.
    static func convertedBookEPUB(documents: Int, paragraphs: Int, images imageCount: Int = 0) -> [TestZIPEntry] {
        var prose = Prose(seed: 17)
        let names = (1...documents).map { String(format: "part%04d.xhtml", $0) }
        let manifest = names.enumerated().map { "<item id=\"p\($0.offset + 1)\" href=\"\($0.element)\" media-type=\"application/xhtml+xml\"/>" }
        let images = (0..<imageCount).map { String(format: "images/img%04d.jpg", $0) }
        let imageItems = images.enumerated().map { "<item id=\"i\($0.offset)\" href=\"\($0.element)\" media-type=\"image/jpeg\"/>" }
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="uid">urn:uuid:3b9f61d2-0c3e-4f7a-8d1e-6a2b5c9d8e70</dc:identifier>
        <dc:title>A Converted Anthology</dc:title><dc:creator>Saoirse Adeyemi-Holm</dc:creator>
        </metadata>
        <manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        \(manifest.joined(separator: "\n"))
        \(imageItems.joined(separator: "\n"))
        </manifest>
        <spine toc="ncx">\((1...documents).map { "<itemref idref=\"p\($0)\"/>" }.joined())</spine>
        </package>
        """
        /// The destination naming document `number`: every fourth by fragment.
        func destination(_ number: Int) -> String {
            names[number - 1] + (number % 4 == 0 ? "#h\(number)" : "")
        }
        let navigationPoints = (1...documents).map { "<li><a href=\"\(destination($0))\">Part \($0)</a></li>" }
        let nav = xhtml(title: "Contents", body: "<nav epub:type=\"toc\"><ol>\(navigationPoints.joined())</ol></nav>")
        let ncxPoints = (1...documents).map {
            "<navPoint id=\"n\($0)\"><navLabel><text>Part \($0)</text></navLabel><content src=\"\(destination($0))\"/></navPoint>"
        }
        let ncx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>\(ncxPoints.joined())</navMap></ncx>
        """
        var entries = packageStart() + [
            file("OEBPS/package.opf", opf),
            file("OEBPS/nav.xhtml", nav),
            file("OEBPS/toc.ncx", ncx),
        ]
        entries += images.map { TestZIPEntry("OEBPS/" + $0, Data([0xFF, 0xD8, 0xFF, 0xE0])) }
        for (offset, name) in names.enumerated() {
            let number = offset + 1
            var body = "<div class=\"calibre1\" id=\"d\(number)\" style=\"margin:0\">\n"
            body += "<h2 class=\"calibre3\" id=\"h\(number)\"><span class=\"bold\">Part \(number)</span></h2>\n"
            for _ in 0..<paragraphs {
                var words = prose.words(prose.number(40..<120))
                let emphasis = prose.number(0..<max(1, words.count - 3))
                words[emphasis] = "<em class=\"italic\">" + words[emphasis]
                words[emphasis + 1] += "</em>"
                let span = prose.number(0..<words.count)
                words[span] = "<span class=\"smcap\" style=\"font-variant:small-caps\">\(words[span])</span>"
                let link = prose.number(0..<words.count)
                words[link] = "<a class=\"link\" href=\"\(destination(prose.number(1..<(documents + 1))))\">\(words[link])</a>"
                body += "<p class=\"calibre5\" style=\"text-indent:1em\">" + wrapped(words, width: 100) + "</p>\n"
            }
            body += "</div>"
            entries.append(file("OEBPS/" + name, xhtml(title: "Part \(number)", body: body)))
        }
        return entries
    }

    /// Write `entries` as an EPUB named `name` in a new temporary folder
    /// that `testCase` removes when it ends, and return its URL.
    static func writeEPUB(_ entries: [TestZIPEntry], named name: String, for testCase: XCTestCase) throws -> URL {
        let zip = try makeTemporaryZip(prefix: "TextPipelineEPUB", orderedEntries: entries)
        return try moveIntoTemporaryFolder(zip, named: name, for: testCase)
    }

    /// Write `text` as UTF-8 to a file named `name` in a new temporary
    /// folder that `testCase` removes when it ends, and return its URL.
    static func writeText(_ text: String, named name: String, for testCase: XCTestCase) throws -> URL {
        let folder = try temporaryFolder(for: testCase)
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Move `file` into a new temporary folder under `name`.
    private static func moveIntoTemporaryFolder(_ file: URL, named name: String, for testCase: XCTestCase) throws -> URL {
        let destination = try temporaryFolder(for: testCase).appendingPathComponent(name)
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    /// A new, empty temporary folder that `testCase` removes when it ends.
    static func temporaryFolder(for testCase: XCTestCase) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextPipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    // MARK: - Generated DAISY Books

    /// A DAISY 2.02 audio book (path → bytes) whose two headings play from
    /// one audio file of `audioBytes` bytes, `track.mp3`, beside a short
    /// audio file no heading plays, `extra.mp3`, which conversion copies
    /// too. The audio is stand-in bytes, a repeating pattern: conversion
    /// copies audio without decoding it.
    static func daisyAudioBook(audioBytes: Int) -> [String: Data] {
        let ncc = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head>
        <meta name="dc:title" content="Soundings of the Upper Reach"/>
        <meta name="dc:creator" content="Wilhelmina Achterberg"/>
        <title>Soundings of the Upper Reach</title></head><body>
        <h1 id="h1"><a href="part1.smil#p1">The Weir</a></h1>
        <h1 id="h2"><a href="part2.smil#p2">The Sluice</a></h1>
        </body></html>
        """
        /// A SMIL file whose one clip plays `track.mp3` from `begin` to `end` seconds.
        func smil(_ id: String, text: String, begin: Double, end: Double) -> String {
            """
            <?xml version="1.0" encoding="utf-8"?>
            <smil><body><seq>
            <par id="\(id)"><text src="text.html#\(text)"/><audio src="track.mp3" clip-begin="npt=\(begin)s" clip-end="npt=\(end)s"/></par>
            </seq></body></smil>
            """
        }
        let content = """
        <html><body><h1 id="t1">The Weir</h1><p>Water over the weir.</p><h1 id="t2">The Sluice</h1><p>The sluice gate.</p></body></html>
        """
        let pattern: [UInt8] = Array("ID3 stand-in audio frame ".utf8)
        let audio = Data((0..<audioBytes).map { pattern[$0 % pattern.count] })
        return [
            "ncc.html": Data(ncc.utf8),
            "part1.smil": Data(smil("p1", text: "t1", begin: 0, end: 30).utf8),
            "part2.smil": Data(smil("p2", text: "t2", begin: 30, end: 75.5).utf8),
            "text.html": Data(content.utf8),
            "track.mp3": audio,
            "extra.mp3": Data("a short file no heading plays".utf8),
        ]
    }

    // MARK: - Timing

    /// The fastest of `runs` runs of `body`, in seconds: the run least
    /// disturbed by whatever else the machine was doing.
    static func fastestTime(of runs: Int, _ body: () throws -> Void) rethrows -> Double {
        var fastest = Double.infinity
        for _ in 0..<max(1, runs) {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            fastest = min(fastest, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000)
        }
        return fastest
    }

    // MARK: - Importing

    /// Import `source` as a reader imports it, into the hosted tests'
    /// isolated library, removing its package when `testCase` ends.
    static func imported(_ source: URL, for testCase: XCTestCase) throws -> Book {
        let book = try FileImportService.importFile(from: source)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: book.tmbDirectory) }
        return book
    }
}

// MARK: - The Code Each Change Replaced

/// The text pipeline's code as it was before each performance change
/// (PERF21 to PERF25 in TODO-2026-09-04.md), kept verbatim so the golden
/// tests can require today's code to give the same output on any input,
/// and the benchmarks can time the old and the new code side by side, in
/// one run, where a busy machine slows both alike.
enum TextPipelineBefore {
    /// The word count as it was counted before PERF21: the pieces a split
    /// at every whitespace Character leaves.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// The chapter split as it was before PERF22: every line copied into an
    /// array, and each chapter's lines joined again and trimmed.
    static func splitChapters(_ markdown: String) -> [(title: String, content: String)] {
        let prefix = "<!-- chapter: "
        let suffix = " -->"
        let lines = markdown.components(separatedBy: "\n")
        var sections: [(title: String, content: String)] = []
        var currentTitle = ""
        var currentLines: [String] = []
        var foundMarker = false
        for line in lines {
            if line.hasPrefix(prefix) && line.hasSuffix(suffix) {
                if foundMarker {
                    let content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty {
                        sections.append((title: currentTitle, content: content))
                    }
                }
                let titleStart = line.index(line.startIndex, offsetBy: prefix.count)
                let titleEnd = line.index(line.endIndex, offsetBy: -suffix.count)
                var title = String(line[titleStart..<titleEnd])
                if title.contains("<!--") {
                    title = title.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                }
                currentTitle = title
                currentLines = []
                foundMarker = true
            } else {
                currentLines.append(line)
            }
        }
        if foundMarker {
            let content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                sections.append((title: currentTitle, content: content))
            }
        }
        return sections
    }

    /// `MarkdownLiteral.escaped` as it was before PERF23: a scalar at a time.
    static func escaped(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if MarkdownLiteral.isASCIIPunctuation(scalar) {
                result.append("\\")
                result.append(scalar)
            } else if scalar == "\u{FEFF}" {
                result.append(contentsOf: "&#xFEFF;".unicodeScalars)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// The plain-text line analysis as it was before PERF23
    /// (`PlainTextParser.blocks(in:)` with its heading rules).
    enum PlainText {
        static func blocks(in text: String) -> [PlainTextParser.Block] {
            let lines = TextFileDecoder.normalizingLineEndings(text)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let underlines = Set(lines.indices.filter { isSetextUnderline(lines[$0]) })
            var blocks: [PlainTextParser.Block] = []
            var paragraph: [String] = []
            var consumedUnderline: Int?
            func endParagraph() {
                guard !paragraph.isEmpty else { return }
                blocks.append(.paragraph(lines: paragraph))
                paragraph = []
            }
            for (index, line) in lines.enumerated() {
                if index == consumedUnderline { continue }
                if !underlines.contains(index), let heading = heading(at: index, in: lines, underlines: underlines) {
                    endParagraph()
                    blocks.append(.heading(level: heading.level, text: readable(heading.label)))
                    if heading.isUnderlined { consumedUnderline = index + 1 }
                } else if line.isEmpty {
                    endParagraph()
                } else {
                    paragraph.append(readable(line))
                }
            }
            endParagraph()
            return blocks
        }

        static func heading(at index: Int, in lines: [String], underlines: Set<Int>) -> (level: Int, label: String, isUnderlined: Bool)? {
            let line = lines[index]
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                if level <= 6 {
                    let label = String(line.dropFirst(level))
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                        .trimmingCharacters(in: .whitespaces)
                    if !label.isEmpty { return (level, label, false) }
                }
            }
            if !line.isEmpty && underlines.contains(index + 1) {
                return (lines[index + 1].hasPrefix("=") ? 1 : 2, line, true)
            }
            if line.count >= 3 && line.count <= 80
                && line.uppercased() == line
                && line.rangeOfCharacter(from: .letters) != nil
                && line.filter({ $0.isLetter }).count >= 3 {
                return (2, line, false)
            }
            return nil
        }

        static func isSetextUnderline(_ line: String) -> Bool {
            line.count >= 3 && (line.allSatisfy({ $0 == "=" }) || line.allSatisfy({ $0 == "-" }))
        }

        static func readable(_ line: String) -> String {
            guard line.unicodeScalars.contains("\u{0}") else { return line }
            return String(String.UnicodeScalarView(line.unicodeScalars.map { $0 == "\u{0}" ? "\u{FFFD}" : $0 }))
        }
    }

    /// `ParserUtilities.normalizeMarkdownWhitespace` as it was before
    /// PERF25: a regular expression for every line.
    static func normalizedWhitespace(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        var result: [String] = []
        var blankCount = 0
        for line in lines {
            if line.isEmpty {
                blankCount += 1
                if blankCount <= 2 { result.append(line) }
            } else {
                blankCount = 0
                result.append(line)
            }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Samples the bytes malloc holds live every half millisecond, on a thread
/// of its own, while a measured run goes on, keeping the highest.
///
/// `@unchecked Sendable`: `running` and `peak` are read and changed only
/// under `lock`; everything else is a constant.
final class HeapSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var peak: Int
    private let finished = DispatchSemaphore(value: 0)

    /// The bytes every malloc zone holds live now.
    static func heapInUse() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return Int(statistics.size_in_use)
    }

    /// Start sampling at once.
    init() {
        peak = Self.heapInUse()
        let thread = Thread { [self] in
            while true {
                let sample = Self.heapInUse()
                lock.lock()
                peak = max(peak, sample)
                let keepGoing = running
                lock.unlock()
                if !keepGoing { break }
                usleep(500)
            }
            finished.signal()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stop sampling and return the highest sample.
    func stop() -> Int {
        lock.lock()
        running = false
        lock.unlock()
        finished.wait()
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
}
