import XCTest
import SwiftSoup
@testable import TextMouth

// MARK: - Helpers Shared by the RTF Reader's Tests

extension XCTestCase {
    /// The HTML TextMouth's own reader makes of the rich text `source`.
    func rtfHTML(_ source: String, includesPages: Bool = true) throws -> String {
        try RTFDocumentReader.html(from: Data(source.utf8), includesPages: includesPages)
    }

    /// The HTML the reader makes of the sample at `path` (a copy of it).
    func rtfSampleHTML(_ path: String, as format: TextutilInputFormat = .rtf, includesPages: Bool = true) throws -> String {
        let copy = try copyOfFormatSample(path)
        return try RTFDocumentReader.html(of: copy, as: format, includesPages: includesPages)
    }

    /// The body of `html` as a parsed element.
    func rtfBody(_ html: String) throws -> Element {
        let document = try SwiftSoup.parse(html)
        return try XCTUnwrap(document.body())
    }

    /// The words of `html`'s body: runs of letters and digits, in order.
    /// Spacing, punctuation, emphasis, and page markers do not count.
    func rtfWords(_ html: String) throws -> [String] {
        let text = try rtfBody(html).text()
        var words: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if TextutilPageBreaks.isCounted(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// The headings of `html`, as "level: text" lines.
    func rtfHeadings(_ html: String) throws -> [String] {
        try rtfBody(html).select("h1, h2, h3, h4, h5, h6").array().map {
            "\($0.tagName().dropFirst()): \(try $0.text())"
        }
    }

    /// The page labels of `html`'s page-break elements, in order.
    func rtfPages(_ html: String) throws -> [String] {
        try rtfBody(html).select("span[role=doc-pagebreak]").array().map { try $0.attr("aria-label") }
    }
}

// MARK: - The Reader on Samples and Synthetic Documents

/// TextMouth's own reader of rich text (FMT47): every sample of
/// `TestData/format-samples/rtf` and `rtfd`, and documents written in the
/// tests to reach each rule of the format.
final class RTFReaderTests: XCTestCase {

    // MARK: - Samples

    /// word-styles.rtf: Word's heading styles, by style and by outline level.
    func testWordStylesHeadingsComeFromTheStyleSheet() throws {
        let html = try rtfSampleHTML("rtf/word-styles.rtf")
        XCTAssertEqual(try rtfHeadings(html), [
            "1: Chapter One: The Quay",
            "2: Morning Tides",
            // An outline level of 2 on a paragraph with no heading style.
            "3: A paragraph with outline level 3 but no heading style",
            "3: A third-level heading"
        ])
        XCTAssertTrue(html.contains("<title>Word Styles Sample</title>"))
        XCTAssertTrue(html.contains("<meta name=\"author\" content=\"A. Sample\">"))
        // Accents, \uN with a fallback, and the typographic words.
        let text = try rtfBody(html).text()
        XCTAssertTrue(text.contains("Café tables"), text)
        XCTAssertTrue(text.contains("señor"), text)
        XCTAssertTrue(text.contains("Unicode check: €5 and česky."), text)
        XCTAssertTrue(text.contains("\u{201C}good morning\u{201D}"), text)
        XCTAssertTrue(text.contains("Prices \u{2013} in euros \u{2013} are"), text)
        // "Body Text" has outline level 9: it is body text, not a heading.
        XCTAssertFalse(try rtfHeadings(html).contains { $0.contains("The ferry leaves") })
    }

    /// headings.rtf is textutil's own RTF with sizes only: its headings are
    /// found by size, as textutil's reading finds them.
    func testTextutilsOwnRTFHasItsHeadingsFromSizes() throws {
        let html = try rtfSampleHTML("rtf/headings.rtf")
        XCTAssertEqual(try rtfHeadings(html), ["1: Harbour Notes", "2: Morning Tides", "2: Timetable"])
        let body = try rtfBody(html)
        XCTAssertEqual(try body.select("ul > li").array().map { try $0.text() }, [
            "Bread from the bakery on Rue Ménard", "Smoked fish, naïve prices", "A newspaper already a day old"
        ])
        XCTAssertEqual(try body.select("tr").array().map { try $0.select("td").array().map { try $0.text() } }, [
            ["Boat", "Departs"], ["Ferry", "07:00"], ["Launch", "09:30"]
        ])
        XCTAssertTrue(try body.text().contains("Prices \u{2014} in euros \u{2014} are posted by the quay."))
        XCTAssertTrue(html.contains("<meta name=\"author\" content=\"A. Sample\">"))
        // The list's bullet is not one of the item's words.
        XCTAssertFalse(try body.text().contains("\u{2022}"))
    }

    /// page-breaks.rtf holds a \page inside a paragraph, a \pagebb, and a
    /// \sect: four pages, the words around the first break apart.
    func testPageBreaksSampleHasFourPages() throws {
        let html = try rtfSampleHTML("rtf/page-breaks.rtf")
        XCTAssertEqual(try rtfPages(html), ["1", "2", "3", "4"])
        let body = try rtfBody(html)
        // Page 1 is first in the body; page 2 begins right before "continues".
        XCTAssertTrue(html.contains("<body>\n<span role=\"doc-pagebreak\" aria-label=\"1\"></span>"))
        XCTAssertTrue(html.contains("runs on and <span role=\"doc-pagebreak\" aria-label=\"2\"></span>continues here."), html)
        XCTAssertTrue(html.contains("<span role=\"doc-pagebreak\" aria-label=\"3\"></span>Third paragraph"), html)
        XCTAssertTrue(html.contains("<span role=\"doc-pagebreak\" aria-label=\"4\"></span>Fifth paragraph"), html)
        XCTAssertEqual(try body.select("p").count, 5)
        // Without pages, the words are the same and no span is written.
        let plain = try rtfSampleHTML("rtf/page-breaks.rtf", includesPages: false)
        XCTAssertEqual(try rtfPages(plain), [])
        XCTAssertEqual(try rtfWords(plain), try rtfWords(html))
    }

    /// word-list-table.rtf: Word's list and table, its heading styles, and
    /// the info group.
    func testListAndTableSample() throws {
        let html = try rtfSampleHTML("rtf/word-list-table.rtf")
        XCTAssertEqual(try rtfHeadings(html), ["1: Shopping and Timetable", "2: Shopping", "2: Timetable"])
        let body = try rtfBody(html)
        XCTAssertEqual(try body.select("ul").count, 1, "The three items are one bullet list")
        XCTAssertEqual(try body.select("ol").count, 0)
        XCTAssertEqual(try body.select("li").array().map { try $0.text() }, ["Bread from the bakery", "Smoked fish", "A newspaper"])
        XCTAssertEqual(try body.select("tr").array().map { try $0.select("td").array().map { try $0.text() } }, [
            ["Boat", "Departs"], ["Ferry", "07:00"]
        ])
        XCTAssertTrue(html.contains("<title>List and Table</title>"))
        XCTAssertTrue(try body.select("p").array().map { try $0.text() }.contains("After the table."))
    }

    /// with-image.rtfd: the package's TXT.rtf is read and its picture is not.
    func testRTFDSampleReadsItsTextWithoutThePicture() throws {
        let html = try rtfSampleHTML("rtfd/with-image.rtfd", as: .rtfd)
        let text = try rtfBody(html).text()
        XCTAssertTrue(text.contains("The Pier"), text)
        XCTAssertTrue(text.contains("A picture of the pier follows."), text)
        XCTAssertTrue(text.contains("After the picture, the text goes on. Café."), text)
        XCTAssertFalse(text.contains("Attachment"), text)
        XCTAssertFalse(text.contains("NeXTGraphic"), text)
        XCTAssertFalse(text.contains("\u{FFFC}"), text)
        XCTAssertEqual(try rtfHeadings(html), ["1: The Pier"])
    }

    /// headings.rtfd holds the text of headings.rtf, and reads as it does.
    func testRTFDWithoutAttachmentsReadsAsItsTXTrtf() throws {
        let package = try rtfSampleHTML("rtfd/headings.rtfd", as: .rtfd)
        let file = try rtfSampleHTML("rtf/headings.rtf")
        XCTAssertEqual(package, file)
    }

    /// A package with no TXT.rtf, or with a link for it, is refused with the
    /// sentence textutil's failures use.
    func testRTFDWithoutTextIsRefused() throws {
        let folder = try makeSandboxDirectory("RTFDEmpty").appendingPathComponent("Empty.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try RTFDocumentReader.html(of: folder, as: .rtfd, includesPages: true)) { error in
            XCTAssertEqual(error as? TextutilConverter.Failure, .unreadable(.rtfd))
        }
        // A link in place of the text could point anywhere on the disk.
        let target = try makeSandboxDirectory("RTFDTarget").appendingPathComponent("elsewhere.rtf")
        try Data(#"{\rtf1 Secret\par}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("TXT.rtf"), withDestinationURL: target)
        XCTAssertThrowsError(try RTFDocumentReader.html(of: folder, as: .rtfd, includesPages: true)) { error in
            XCTAssertEqual(error as? TextutilConverter.Failure, .unreadable(.rtfd))
        }
    }

    /// A file that is not rich text, and an empty one, are refused with the
    /// sentence for a file that could not be read as rich text.
    func testFilesThatAreNotRichTextAreRefused() throws {
        let folder = try makeSandboxDirectory("RTFNot")
        let text = folder.appendingPathComponent("plain.rtf")
        try Data("Just some words.".utf8).write(to: text)
        XCTAssertThrowsError(try RTFDocumentReader.html(of: text, as: .rtf, includesPages: true)) { error in
            XCTAssertEqual(error as? TextutilConverter.Failure, .unreadable(.rtf))
            XCTAssertEqual(
                error.localizedDescription,
                "This file could not be read as a rich text document. It may be damaged, or another kind of file."
            )
        }
        let empty = folder.appendingPathComponent("empty.rtf")
        try Data().write(to: empty)
        XCTAssertThrowsError(try RTFDocumentReader.html(of: empty, as: .rtf, includesPages: true)) { error in
            XCTAssertEqual(error as? TextutilConverter.Failure, .unreadable(.rtf))
        }
        // Rich text with no words is read: the import decides what it holds.
        let blank = folder.appendingPathComponent("blank.rtf")
        try Data(#"{\rtf1\ansi\par}"#.utf8).write(to: blank)
        XCTAssertEqual(try rtfBody(RTFDocumentReader.html(of: blank, as: .rtf, includesPages: true)).text(), "")
    }

    // MARK: - Characters

    /// \uN is a signed 16-bit number, \ucN sets how many characters follow
    /// it as its fallback, and two in a row make a surrogate pair.
    func testUnicodeEscapes() throws {
        let html = try rtfHTML(#"{\rtf1\ansi\uc1 Euro \u\#(8364)?5, \u-3913? and {\uc2\u233??}rest, {\uc0\u\#(8226) }bullet. Pair \u-10179?\u-8704? and \u-10179\u-8704? end.\par}"#)
        let text = try rtfBody(html).text()
        XCTAssertEqual(text, "Euro \u{20AC}5, \u{F0B7} and \u{E9}rest, \u{2022}bullet. Pair \u{1F600} and \u{1F600} end.")
    }

    /// A \u out of range, and a lone surrogate, are the replacement character.
    func testUnicodeOutOfRangeIsTheReplacementCharacter() throws {
        let html = try rtfHTML(#"{\rtf1 a\u\#(99999999)?b \u-10179? c \u-8704? d\par}"#)
        let text = try rtfBody(html).text()
        XCTAssertEqual(text, "a\u{FFFD}b \u{FFFD} c \u{FFFD} d")
    }

    /// \'hh is a byte in the document's code page (\ansicpg1251), and a
    /// font's \fcharset names the code page of its own runs.
    func testHexBytesUseTheCodePageOfTheDocumentAndTheFont() throws {
        let cyrillic = try rtfHTML(#"{\rtf1\ansi\ansicpg1251\deff0{\fonttbl{\f0\fcharset204 Arial;}}\f0 \'cf\'f0\'e8\'e2\'e5\'f2\par}"#)
        XCTAssertEqual(try rtfBody(cyrillic).text(), "Привет")
        // No \fcharset on the font: the document's code page applies.
        let documentOnly = try rtfHTML(#"{\rtf1\ansi\ansicpg1251{\fonttbl{\f0 Arial;}}\f0 \'cf\'f0\'e8\'e2\'e5\'f2\par}"#)
        XCTAssertEqual(try rtfBody(documentOnly).text(), "Привет")
        // Two fonts, two code pages: Cyrillic 0xCF is П, Greek 0xE1 is α.
        let mixed = try rtfHTML(#"{\rtf1\ansi\ansicpg1251{\fonttbl{\f0\fcharset204 A;}{\f1\fcharset161 B;}}\f0 \'cf \f1 \'e1\par}"#)
        XCTAssertEqual(try rtfBody(mixed).text(), "П α")
        // Windows-1252 by default.
        let western = try rtfHTML(#"{\rtf1\ansi Caf\'e9 \'93quoted\'94\par}"#)
        XCTAssertEqual(try rtfBody(western).text(), "Café \u{201C}quoted\u{201D}")
        // Mac Roman: 0x8E is é.
        let mac = try rtfHTML(#"{\rtf1\mac Caf\'8e\par}"#)
        XCTAssertEqual(try rtfBody(mac).text(), "Café")
    }

    /// The two bytes of a Shift-JIS character make one character.
    func testDoubleByteCharactersAreDecodedTogether() throws {
        let html = try rtfHTML(#"{\rtf1\ansi\ansicpg932\deff0{\fonttbl{\f0\fcharset128 MS Mincho;}}\f0 \'82\'a0\'82\'a2\par}"#)
        XCTAssertEqual(try rtfBody(html).text(), "あい")
    }

    /// An invalid \' stands for no byte and swallows nothing after it.
    func testInvalidHexEscapeIsIgnored() throws {
        let html = try rtfHTML(#"{\rtf1 a\'zzb \'4 c \'4g d\par}"#)
        XCTAssertEqual(try rtfBody(html).text(), "azzb  c g d".replacingOccurrences(of: "  ", with: " "))
    }

    /// The control symbols and the typographic words.
    func testControlSymbolsAndWords() throws {
        let html = try rtfHTML(#"{\rtf1 a\~b\_c\-d \\ \{ \} \emdash \endash \bullet \lquote x\rquote \ldblquote y\rdblquote \tab t\line l\par}"#)
        let text = try rtfBody(html).text()
        // Each space after a control word ends the word and is not text.
        XCTAssertEqual(text, "a b-cd \\ { } \u{2014}\u{2013}\u{2022}\u{2018}x\u{2019}\u{201C}y\u{201D} t l")
        XCTAssertTrue(html.contains("t<br>l"), html)
    }

    /// Escaped text cannot become markup.
    func testTextIsEscaped() throws {
        let html = try rtfHTML(#"{\rtf1 Fish & chips <b>not bold</b> "quoted"\par}"#)
        XCTAssertTrue(html.contains("Fish &amp; chips &lt;b&gt;not bold&lt;/b&gt; \"quoted\""), html)
        XCTAssertEqual(try rtfBody(html).select("b").count, 0)
    }

    // MARK: - Destinations

    /// A field is read for its result alone.
    func testFieldsAreReadForTheirResult() throws {
        let html = try rtfHTML(#"{\rtf1 See {\field{\*\fldinst HYPERLINK "http://x.example"}{\fldrslt the page}} now.\par}"#)
        XCTAssertEqual(try rtfBody(html).text(), "See the page now.")
    }

    /// An ignorable destination the reader does not know is skipped whole,
    /// with the groups inside it.
    func testUnknownIgnorableDestinationsAreSkipped() throws {
        let html = try rtfHTML(#"{\rtf1 A{\*\unknowndest hidden words {\b more {\i deeper}}}B{\*\another \'e9\u233?}C\par}"#)
        XCTAssertEqual(try rtfBody(html).text(), "ABC")
    }

    /// Pictures, objects, headers, footers, footnotes, and hidden text are not read.
    func testWhatIsNotTheBodyIsNotRead() throws {
        let html = try rtfHTML(#"""
            {\rtf1\ansi{\header Header words\par}{\footer Footer words}
            Before{\super\chftn{\footnote\pard\plain Footnote words.}} after.\par
            {\pict\wmetafile8\picw10\pich10 0102030405}{\object{\*\objdata 0102}{\result Object words}}Pictured.\par
            Hidden{\v secret}shown.\par
            {\colortbl;\red0\green0\blue0;}{\*\generator Some Writer 1.0;}{\comment A comment.}Done.\par}
            """#)
        let text = try rtfBody(html).text()
        XCTAssertEqual(text, "Before after. Pictured. Hiddenshown. Done.")
    }

    /// The title and author are in the head, escaped; the rest of the info
    /// group is not read.
    func testInfoGivesTheTitleAndAuthor() throws {
        let html = try rtfHTML(#"{\rtf1 {\info{\title Fish & Chips}{\author A. "Quote" Writer}{\subject Not read}{\company Nor this}}Body.\par}"#)
        XCTAssertTrue(html.contains("<title>Fish &amp; Chips</title>"), html)
        XCTAssertTrue(html.contains("<meta name=\"author\" content=\"A. &quot;Quote&quot; Writer\">"), html)
        XCTAssertEqual(try rtfBody(html).text(), "Body.")
        // Without an info group, no title and no author.
        let bare = try rtfHTML(#"{\rtf1 Body.\par}"#)
        XCTAssertFalse(bare.contains("<title>"))
        XCTAssertFalse(bare.contains("name=\"author\""))
    }

    // MARK: - Emphasis

    /// Bold and italic are strong and em; nested groups set and reset them.
    func testBoldAndItalicAreEmphasis() throws {
        let html = try rtfHTML(#"{\rtf1 plain {\b bold {\i both} bold again} plain \b b\b0  \i i\i0  \b\i bi\plain  end\par}"#)
        XCTAssertTrue(html.contains("plain <strong>bold </strong><strong><em>both</em></strong><strong> bold again</strong> plain "), html)
        XCTAssertTrue(html.contains("<strong>b</strong> <em>i</em> <strong><em>bi</em></strong> end"), html)
    }

    /// White space between words does not become a mark of its own, and a
    /// heading carries no emphasis.
    func testHeadingsCarryNoEmphasis() throws {
        let html = try rtfHTML(#"{\rtf1{\stylesheet{\s1\outlinelevel0 heading 1;}}\pard\s1\b Bold {\i Title}\par\pard Body\par}"#)
        XCTAssertTrue(html.contains("<h1>Bold Title</h1>"), html)
    }

    // MARK: - Headings

    /// Heading styles by name in any capitals, up to level 9 (level 6 for
    /// 6 and deeper), "Title", "Subtitle", and the style a style is based on.
    func testHeadingStylesByNameLevelAndInheritance() throws {
        let sheet = #"""
            {\stylesheet{\s0 Normal;}{\s1 HEADING 1;}{\s2 Heading 2;}{\s7 heading 7;}{\s9 heading 9;}
            {\s10 Title;}{\s11 Subtitle;}{\s12\sbasedon1 My Heading;}{\s13\sbasedon12 Deeper;}
            {\s14\sbasedon14 Loop;}{\s15\sbasedon99 Orphan;}{\s16\sbasedon1\outlinelevel9 Not a heading;}}
            """#
        let paragraphs = [(1, "One"), (2, "Two"), (7, "Seven"), (9, "Nine"), (10, "Title"), (11, "Sub"), (12, "Mine"),
                          (13, "Deep"), (14, "Loop"), (15, "Orphan"), (16, "Plain"), (0, "Normal"), (5, "Unknown")]
        let body = paragraphs.map { #"\pard\s\#($0.0) \#($0.1)\par"# }.joined(separator: "\n")
        let html = try rtfHTML("{\\rtf1 \(sheet)\n\(body)}")
        XCTAssertEqual(try rtfHeadings(html), ["1: One", "2: Two", "6: Seven", "6: Nine", "1: Title", "2: Sub", "1: Mine", "1: Deep"])
    }

    /// An outline level on the paragraph wins over its style's; 9 is body text.
    func testParagraphOutlineLevelWinsOverTheStyle() throws {
        let html = try rtfHTML(#"""
            {\rtf1{\stylesheet{\s1\outlinelevel0 heading 1;}}
            \pard\s1\outlinelevel3 Four\par
            \pard\s1\outlinelevel9 Body\par
            \pard\outlinelevel8 Nine\par
            \pard\outlinelevel12 Out of range\par}
            """#)
        XCTAssertEqual(try rtfHeadings(html), ["4: Four", "6: Nine"])
    }

    /// A document that names its headings is not given others by size.
    func testNamedHeadingsSwitchOffTheSizeGuess() throws {
        let html = try rtfHTML(#"""
            {\rtf1{\stylesheet{\s1\outlinelevel0 heading 1;}}
            \pard\s1\fs48 Named\par
            \pard\fs24 Body body body body body body.\par
            \pard\b\fs36 Big and bold\par}
            """#)
        XCTAssertEqual(try rtfHeadings(html), ["1: Named"])
    }

    /// A document with no names guesses them from sizes, as textutil's
    /// reading does: larger sizes rank as levels 1, 2, ...; bold at the body
    /// size is the next level; a mostly bold body has no bold headings.
    func testHeadingsBySize() throws {
        let html = try rtfHTML(#"""
            {\rtf1
            \pard\fs48\b Title\par
            \pard\fs24\b0 This is the body text, long enough to be the body size of the document.\par
            \pard\fs36\b Chapter\par
            \pard\fs24\b0 More body text, again long enough to outweigh every heading.\par
            \pard\fs24\b Bold line\par
            \pard\fs24\b0 A\par
            \pard\fs48\b X\par}
            """#)
        // "X" is a single letter, so it is not a heading.
        XCTAssertEqual(try rtfHeadings(html), ["1: Title", "2: Chapter", "3: Bold line"])
    }

    // MARK: - Lists

    /// Bullets and numbers by the list table, nested by \ilvl, with the
    /// marker text left out of the items.
    func testListsAreBulletedOrNumberedByTheListTable() throws {
        let html = try rtfHTML(#"""
            {\rtf1\ansi{\fonttbl{\f1\fcharset2 Symbol;}}
            {\*\listtable{\list\listid10{\listlevel\levelnfc23{\leveltext\'01\'b7;}}{\listlevel\levelnfc0{\leveltext\'02\'00.;}}}
            {\list\listid20{\listlevel\levelnfc0{\leveltext\'02\'00.;}}}}
            {\*\listoverridetable{\listoverride\listid10\ls1}{\listoverride\listid20\ls2}}
            \pard\ls1\ilvl0{\listtext\f1\'b7\tab}Bullet one\par
            \pard\ls1\ilvl1{\listtext 1.\tab}Nested number\par
            \pard\ls1\ilvl1{\listtext 2.\tab}Nested number two\par
            \pard\ls1\ilvl0{\listtext\f1\'b7\tab}Bullet two\par
            \pard Between\par
            \pard\ls2\ilvl0{\listtext 1.\tab}First\par
            \pard\ls2\ilvl0{\listtext 2.\tab}Second\par}
            """#)
        let body = try rtfBody(html)
        XCTAssertEqual(try body.select("ul").count, 1)
        XCTAssertEqual(try body.select("ol").count, 2)
        XCTAssertEqual(try body.select("ul > li > ol > li").array().map { try $0.text() }, ["Nested number", "Nested number two"])
        XCTAssertEqual(try body.select("body > ul > li").array().map { try $0.ownText() }, ["Bullet one", "Bullet two"])
        XCTAssertEqual(try body.select("body > ol > li").array().map { try $0.text() }, ["First", "Second"])
        XCTAssertFalse(try body.text().contains("1."), "The numbers are not the items' words")
    }

    /// With no list table, a marker with a letter or digit is a number and
    /// any other is a bullet; a bullet and a tab begin an item in a document
    /// with no list at all (the way TextMouth's RTF export writes one).
    func testListMarkersWithoutAListTable() throws {
        let html = try rtfHTML(#"""
            {\rtf1{\pntext\f0 1.\tab}{\*\pn\pnlvlbody\pndec\pnstart1}One\par
            {\pntext\f0 2.\tab}Two\par
            {\pntext\f0\'b7\tab}Dot\par
            \u\#(8226)?\tab Writer bullet\par
            \u\#(8226)?\tab Writer bullet two\par
            - Dialogue dash, no tab.\par}
            """#)
        let body = try rtfBody(html)
        XCTAssertEqual(try body.select("ol > li").array().map { try $0.text() }, ["One", "Two"])
        XCTAssertEqual(try body.select("ul > li").array().map { try $0.text() }, ["Dot", "Writer bullet", "Writer bullet two"])
        XCTAssertEqual(try body.select("p").array().map { try $0.text() }, ["- Dialogue dash, no tab."])
    }

    /// A numbered heading is a heading, not a list item.
    func testAListMarkerOnAHeadingStaysAHeading() throws {
        let html = try rtfHTML(#"{\rtf1{\stylesheet{\s1\outlinelevel0 heading 1;}}\pard\s1\ls1{\listtext 1.\tab}Intro\par}"#)
        XCTAssertEqual(try rtfHeadings(html), ["1: Intro"])
        XCTAssertEqual(try rtfBody(html).select("li").count, 0)
    }

    // MARK: - Tables

    /// Rows and cells, words after the table, an empty cell, two paragraphs
    /// in one cell, and a nested cell whose words stay in the cell around it.
    func testTables() throws {
        let html = try rtfHTML(#"""
            {\rtf1 Before\par
            \trowd\cellx1000\cellx2000
            \pard\intbl A1\cell \pard\intbl B1 one\par B1 two\cell\row
            \trowd\cellx1000\cellx2000
            \pard\intbl\cell \pard\intbl B2 {\b bold}\cell\row
            \pard After\par}
            """#)
        let body = try rtfBody(html)
        XCTAssertEqual(try body.select("table").count, 1)
        let rows = try body.select("tr").array()
        XCTAssertEqual(try rows[0].select("td").array().map { try $0.select("p").array().map { try $0.text() } }, [["A1"], ["B1 one", "B1 two"]])
        XCTAssertEqual(try rows[1].select("td").array().map { try $0.text() }, ["", "B2 bold"])
        XCTAssertEqual(try body.select("body > p").array().map { try $0.text() }, ["Before", "After"])
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
    }

    /// A paragraph that is not in the table ends it: two tables apart are two.
    func testTwoTablesApartAreTwoTables() throws {
        let html = try rtfHTML(#"""
            {\rtf1 \trowd\cellx1000 \pard\intbl One\cell\row
            \pard\par
            \trowd\cellx1000 \pard\intbl Two\cell\row}
            """#)
        XCTAssertEqual(try rtfBody(html).select("table").count, 2)
    }

    /// A table the file leaves open (no \row) keeps its words; a table of
    /// empty cells makes no table.
    func testDamagedAndEmptyTables() throws {
        let open = try rtfHTML(#"{\rtf1 \trowd\cellx1000\cellx2000 \pard\intbl Left\cell Right}"#)
        XCTAssertEqual(try rtfWords(open), ["Left", "Right"])
        let empty = try rtfHTML(#"{\rtf1 \trowd\cellx1000\cellx2000 \pard\intbl\cell\cell\row\pard After\par}"#)
        XCTAssertEqual(try rtfBody(empty).select("table").count, 0)
        XCTAssertEqual(try rtfWords(empty), ["After"])
    }

    // MARK: - Pages

    /// \page, \pagebb, \sect with a section that starts a page; not \sbknone.
    func testPageBreakKinds() throws {
        let html = try rtfHTML(#"""
            {\rtf1 One\page Two\par
            \pard\pagebb Three\par
            Four\sect\sectd\sbknone Five\sect\sectd\sbkpage Six\sect\sectd\sbkodd Seven\par}
            """#)
        // One | Two | Three Four Five | Six | Seven
        XCTAssertEqual(try rtfPages(html), ["1", "2", "3", "4", "5"])
        XCTAssertTrue(html.contains("<span role=\"doc-pagebreak\" aria-label=\"4\"></span>Six"), html)
        XCTAssertTrue(html.contains("Four</p>\n<p>Five") || html.contains("Four</p>\n<p><span"), html)
    }

    /// A break with no word after it begins no page; several breaks in a row
    /// begin a page each; a document with no letter or digit has no pages.
    func testBreaksWithoutWordsAndEmptyDocuments() throws {
        let trailing = try rtfHTML(#"{\rtf1 One\page\par\page\par}"#)
        XCTAssertEqual(try rtfPages(trailing), ["1"])
        let blankPages = try rtfHTML(#"{\rtf1 One\page\page\page Two\par}"#)
        XCTAssertEqual(try rtfPages(blankPages), ["1", "2", "3", "4"])
        let punctuation = try rtfHTML(#"{\rtf1 ... \page ---\par}"#)
        XCTAssertEqual(try rtfPages(punctuation), [])
        let none = try rtfHTML(#"{\rtf1 One\page Two\par}"#, includesPages: false)
        XCTAssertEqual(try rtfPages(none), [])
    }

    /// A document with more breaks than a book may have pages has no pages.
    func testTooManyPageBreaksMeanNoPages() throws {
        let limit = TextutilPageBreaks.maximumPages
        let within = "{\\rtf1 " + String(repeating: "x\\page ", count: limit - 1) + "y\\par}"
        XCTAssertEqual(try rtfPages(try rtfHTML(within)).count, limit)
        let beyond = "{\\rtf1 " + String(repeating: "x\\page ", count: limit) + "y\\par}"
        XCTAssertEqual(try rtfPages(try rtfHTML(beyond)), [])
        XCTAssertEqual(try rtfWords(try rtfHTML(beyond)).count, limit + 1)
    }

    /// A style whose paragraphs begin a page does so once per paragraph, by
    /// its own \pagebb or the style it is based on; the first paragraph of
    /// the document begins page 1 and not a page of its own.
    func testStylesThatBeginAPage() throws {
        let html = try rtfHTML(#"""
            {\rtf1{\stylesheet{\s1\pagebb\outlinelevel0 heading 1;}{\s2\sbasedon1 Chapter;}}
            \pard\s1 First\par \pard Text\par \pard\s2\pagebb Second\par \pard\s1 Third\par}
            """#)
        XCTAssertEqual(try rtfPages(html), ["1", "2", "3"])
        XCTAssertTrue(html.contains("<span role=\"doc-pagebreak\" aria-label=\"1\"></span><h1>First</h1>"), html)
        XCTAssertTrue(html.contains("<h1><span role=\"doc-pagebreak\" aria-label=\"2\"></span>Second</h1>"), html)
    }

    // MARK: - Damage

    /// A document that ends before its groups do still gives its text, and
    /// so does one with an extra brace.
    func testUnterminatedAndUnbalancedDocumentsGiveTheirText() throws {
        let unterminated = try rtfHTML(#"{\rtf1 One\par {\b Two"#)
        XCTAssertEqual(try rtfWords(unterminated), ["One", "Two"])
        let extra = try rtfHTML(#"{\rtf1 One\par}} Ignored words"#)
        XCTAssertEqual(try rtfWords(extra), ["One"])
        let unclosedInside = try rtfHTML(#"{\rtf1 {\fonttbl{\f0 A;}{\stylesheet{\s1 heading 1;} One\par}"#)
        XCTAssertFalse(try rtfWords(unclosedInside).isEmpty)
    }

    /// Text outside the document's first group is not read.
    func testTextBeforeTheDocumentIsNotRead() throws {
        let html = try rtfHTML("Preamble words {\\rtf1 Body.\\par}")
        XCTAssertEqual(try rtfWords(html), ["Body"])
    }

    // MARK: - RTF That TextMouth Writes

    /// What the RTF export writes reads back: its headings by style, its
    /// emphasis, its bullets, its table, and its accented and astral text.
    func testTheRTFExportWritersOutputReadsBack() throws {
        let list = ExportList(isOrdered: false, start: 1, depth: 0, items: [
            ExportListItem(blocks: [.paragraph([ExportRun("First item")])]),
            ExportListItem(blocks: [.paragraph([ExportRun("Second item")])])
        ])
        let rtf = try RTFExportWriter.rtf(of: ExportDocument(
            book: ExportBookDetails(title: "Harbour Pilots", author: "Odette Varga"),
            blocks: [
                .heading(ExportHeading(level: 1, runs: [ExportRun("Arrivals")], id: "arrivals")),
                .paragraph([ExportRun("Caf\u{E9} "), ExportRun("bold", isStrong: true), ExportRun(" "),
                            ExportRun("slanted", isEmphasis: true), ExportRun(" \u{1F600} back\\slash {braces}")]),
                .heading(ExportHeading(level: 2, runs: [ExportRun("Quays")], id: "quays")),
                .list(list),
                .table(ExportTable(rows: [["Port", "Depth"], ["Hull", "9"]], hasHeaderRow: true))
            ]
        ))
        let html = try rtfHTML(rtf)
        XCTAssertEqual(try rtfHeadings(html), ["1: Arrivals", "2: Quays"])
        XCTAssertTrue(html.contains("<title>Harbour Pilots</title>"), html)
        XCTAssertTrue(html.contains("<meta name=\"author\" content=\"Odette Varga\">"), html)
        XCTAssertTrue(html.contains("Caf\u{E9} <strong>bold</strong> <em>slanted</em> \u{1F600} back\\slash {braces}"), html)
        let body = try rtfBody(html)
        XCTAssertEqual(try body.select("ul > li").array().map { try $0.text() }, ["First item", "Second item"])
        XCTAssertEqual(try body.select("tr").array().map { try $0.select("td").array().map { try $0.text() } }, [
            ["Port", "Depth"], ["Hull", "9"]
        ])
    }
}
