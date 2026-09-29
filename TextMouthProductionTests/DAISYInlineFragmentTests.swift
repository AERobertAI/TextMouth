import XCTest
@testable import TextMouth

/// A SMIL reference to an inline element of a DAISY 2.02 book must yield
/// every word inside it, once and in source order (TODO I07). Extraction
/// used to descend into an inline element's first child only, so the text
/// around and after that child vanished. References that overlap must never
/// read the same words twice.
final class DAISYInlineFragmentTests: XCTestCase {

    // MARK: - Inline Containers

    /// The case the TODO names: text beside emphasized children.
    func testMixedInlineContainerKeepsEveryWordInOrder() throws {
        let html = #"<p><span id="s1">The <em>quick</em> brown <strong>fox</strong> jumps</span></p>"#

        XCTAssertEqual(try extract(["s1"], from: html), "The quick brown fox jumps")
    }

    /// Spans inside spans, and bold and italic runs, keep all their words.
    func testNestedSpansKeepEveryWord() throws {
        let html = """
        <p><span id="s1"><span>Tide</span> <span>tables <span>list</span></span> \
        <b>high</b> <i>and low</i> water</span></p>
        """

        XCTAssertEqual(try extract(["s1"], from: html), "Tide tables list high and low water")
    }

    /// Superscripts and subscripts, including a note reference that is
    /// itself a link, read in place.
    func testSuperscriptsAndSubscriptsKeepTheirText() throws {
        let html = """
        <p><span id="s1">Sea water is H<sub>2</sub>O plus salt<sup><a href="notes.html#n1">1</a></sup>.</span>
        <sup id="n2"><a href="notes.html#n2">12</a></sup></p>
        """

        XCTAssertEqual(try extract(["s1", "n2"], from: html), "Sea water is H2O plus salt1.\n\n12")
    }

    /// Links read as their words, inside a sentence or as the fragment itself,
    /// with no Markdown link syntax around them.
    func testLinksReadAsTheirWords() throws {
        let html = """
        <p><span id="s1">See <a href="part 1.smil#p9">the tide chart</a> for details.</span>
        <a id="a1" href="part1.smil#p10">Harbor <em>entrance</em></a></p>
        """

        let markdown = try extract(["s1", "a1"], from: html)

        XCTAssertEqual(markdown, "See the tide chart for details.\n\nHarbor entrance")
    }

    /// Real DAISY text wraps words in emphasis that ends in a space, which
    /// CommonMark would read as literal asterisks. Each fragment reads as its
    /// words, and so does the sentence that holds them.
    func testEmphasisEndingInASpaceReadsWithoutAsterisks() throws {
        let html = """
        <p><span id="s1"><strong id="w1"><a href="d.smil#t1">The </a></strong>\
        <strong id="w2"><a href="d.smil#t2">Contracting Parties,</a></strong></span></p>
        """

        let words = try extract(["w1", "w2"], from: html)
        XCTAssertEqual(try spokenText(of: words), "The\n\nContracting Parties,")
        XCTAssertEqual(try extract(["s1"], from: html), "The Contracting Parties,")
    }

    /// Hidden content is outside the reading flow, whether it sits inside a
    /// fragment or is the fragment.
    func testHiddenContentIsNotRead() throws {
        let html = """
        <p><span id="s1">Visible <span hidden="">secret</span> words</span>
        <span id="h1" hidden="">unseen</span></p>
        """

        XCTAssertEqual(try extract(["s1", "h1"], from: html), "Visible words")
    }

    /// Line breaks and images inside a fragment separate or supply words.
    func testLineBreaksAndImagesInsideAFragment() throws {
        let html = #"<p><span id="s1">High<br/>water <img src="gauge.png" alt="tide gauge"/> reading</span></p>"#

        XCTAssertEqual(try extract(["s1"], from: html), "High water tide gauge reading")
    }

    /// Block fragments still go through the Markdown converter, keeping
    /// headings and emphasis.
    func testBlockFragmentsKeepTheirMarkdownStructure() throws {
        let html = #"<h2 id="h">Tidal <em>Streams</em></h2><p id="p">Ebb and flood.</p>"#

        XCTAssertEqual(try extract(["h", "p"], from: html), "## Tidal *Streams*\n\nEbb and flood.")
    }

    // MARK: - Overlapping References

    /// A sentence, then a word inside it: the word is already read.
    func testParentThenChildReadsEachWordOnce() throws {
        let html = #"<p id="p1"><span id="s1">The <em id="e1">quick</em> fox</span> ran.</p>"#

        XCTAssertEqual(try extract(["s1", "e1"], from: html), "The quick fox")
        XCTAssertEqual(try spokenText(of: extract(["p1", "s1", "e1"], from: html)), "The quick fox ran.")
    }

    /// A word, then the sentence around it: the sentence leaves the word out,
    /// so every word is read once, in the order the SMIL file gives.
    func testChildThenParentReadsEachWordOnce() throws {
        let html = #"<p id="p1"><span id="s1">The <em id="e1">quick</em> fox</span> ran.</p>"#

        XCTAssertEqual(try extract(["e1", "s1"], from: html), "quick\n\nThe fox")
        XCTAssertEqual(try spokenText(of: extract(["s1", "p1"], from: html)), "The quick fox\n\nran.")
    }

    /// Two elements with the same words are two lines of the book. The old
    /// consecutive-duplicate check dropped the second.
    func testRepeatedLinesInDistinctElementsAreBothRead() throws {
        let html = #"<p><span id="s1">No.</span> <span id="s2">No.</span></p>"#

        XCTAssertEqual(try extract(["s1", "s2"], from: html), "No.\n\nNo.")
    }

    /// A whole-file reference reads what no fragment has, and fragments
    /// after it add nothing it already read.
    func testWholeFileAndFragmentReferencesReadEachWordOnce() throws {
        let html = #"<html><body><h1 id="t">Soundings</h1><p id="p">Nine fathoms.</p></body></html>"#

        XCTAssertEqual(try spokenText(of: extract(["t", ""], from: html)), "Soundings\n\nNine fathoms.")
        XCTAssertEqual(try spokenText(of: extract(["", "p"], from: html)), "Soundings\n\nNine fathoms.")
    }

    // MARK: - Whole Book

    /// Through the full DAISY 2.02 path, from NCC to SMIL to content, a
    /// sentence with emphasized children reaches the book text whole, once.
    func testDAISY202BookReadsWholeInlineSentences() throws {
        let zip = try makeTemporaryDAISYZip(entries: [
            "ncc.html": """
            <html><head><meta name="dc:title" content="Harbor Soundings"/></head>
            <body><h1><a href="part1.smil#p1">Leadline Readings</a></h1></body></html>
            """,
            "part1.smil": """
            <smil><body><seq>
            <par id="p1"><text src="text.html#s1"/></par>
            <par id="p2"><text src="text.html#e1"/></par>
            <par id="p3"><text src="text.html#s2"/></par>
            </seq></body></smil>
            """,
            "text.html": """
            <html><body><p>
            <span id="s1">The lead struck <em id="e1">coarse</em> sand at <strong>nine</strong> fathoms.</span>
            <span id="s2">The tide was <b>falling</b>.</span>
            </p></body></html>
            """
        ])
        defer { try? FileManager.default.removeItem(at: zip) }

        let markdown = try DAISYParser.extractMarkdown(from: zip)

        XCTAssertEqual(
            try spokenText(of: markdown),
            "The lead struck coarse sand at nine fathoms.\n\nThe tide was falling."
        )
    }

    // MARK: - Helpers

    /// Extract the fragments named by `ids` from `html`, served as
    /// `text.html`, in the given order; an empty id names the whole file.
    private func extract(_ ids: [String], from html: String) throws -> String {
        try DAISYParser.extractDAISY202Fragments(
            from: ids.map { $0.isEmpty ? "text.html" : "text.html#\($0)" },
            provider: InMemoryDAISYPackage(["text.html": html])
        )
    }

    /// The words a reader hears for `markdown`.
    private func spokenText(of markdown: String) throws -> String {
        try MarkdownDocParser.parse(markdown: markdown).chapters[0].text
    }
}
