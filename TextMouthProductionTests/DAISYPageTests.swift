import XCTest
@testable import TextMouth

/// The pages of DAISY text books (PG08): a DTBook `pagenum` and a DAISY 2.02
/// NCC page entry each become a page marker in content.md, which is never
/// read and so moves no saved place, while the page number itself is no
/// longer spoken. With `includesPages: false` the Markdown is byte for byte
/// what cache format 3.0.7 wrote.
final class DAISYPageTests: XCTestCase {

    // MARK: - Helpers

    /// The Markdown of a copy of the sample at `relativePath` inside
    /// `TestData/format-samples`.
    private func extractedMarkdown(ofFormatSample relativePath: String, includesPages: Bool = true) throws -> String {
        let copy = try copyOfFormatSample(relativePath)
        return try DAISYParser.extractMarkdown(from: copy, includesPages: includesPages)
    }

    /// The Markdown of a copy of the book at `name` inside `TestData`.
    private func extractedMarkdown(ofTestBook name: String, includesPages: Bool = true) throws -> String {
        let source = try requireFile(name)
        let folder = try makeSandboxDirectory("DAISYPages")
        let copy = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: copy)
        return try DAISYParser.extractMarkdown(from: copy, includesPages: includesPages)
    }

    /// What the reader makes of `markdown`, as the cache parses it.
    private func parsed(_ markdown: String) -> DocumentContent {
        MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: "Pages", bookAuthor: "Test")
    }

    /// Each page as "label: the first `length` UTF-16 units of the reading
    /// text from where the page begins", so one comparison names every page
    /// and the words it starts at.
    private func pageLines(of content: DocumentContent, opening length: Int = 14) -> [String] {
        content.pages.breaks.map { page in
            guard page.chapterIndex < content.chapters.count else { return "\(page.label): (no chapter)" }
            let text = content.chapters[page.chapterIndex].text
            let opening = Array(text.utf16.dropFirst(page.characterOffset).prefix(length))
            return "\(page.label): \(String(decoding: opening, as: UTF16.self))"
        }
    }

    /// The reading text of every chapter, joined by blank lines.
    private func spokenText(of content: DocumentContent) -> String {
        content.chapters.map(\.text).joined(separator: "\n\n")
    }

    /// A DTBook whose `level1` holds `body`, converted to Markdown.
    private func convertDTBook(_ body: String, includesPages: Bool = true) throws -> String {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <dtbook xmlns="http://www.daisy.org/z3986/2005/dtbook/" version="2005-3">
        <head><meta name="dc:Title" content="T"/></head>
        <book><bodymatter><level1>\(body)</level1></bodymatter></book></dtbook>
        """
        return try DTBookToMarkdownConverter(data: Data(xml.utf8), file: "book.xml", includesPages: includesPages)
            .convert().markdown
    }

    // MARK: - The new DTBook sample

    /// Pages ii, 1, 2, an empty one labelled by its ordinal (4), and 5 at
    /// the end of the text, each at the right words, in order.
    func testSamplePagesFallWhereTheSourcePutThem() throws {
        let markdown = try extractedMarkdown(ofFormatSample: "dtbook/pages-front-and-inline.xml")
        let content = parsed(markdown)

        XCTAssertEqual(content.pages.count, 5)
        XCTAssertEqual(Array(pageLines(of: content, opening: 8).prefix(4)), [
            "ii: Quay Pag",
            "1: The Seaw",
            "2: stood dr",
            "4: The last"
        ])
        // Page 5 is the last thing in the book, so it begins at the text's end.
        guard let last = content.pages.breaks.last else { return }
        XCTAssertEqual(last.label, "5")
        XCTAssertEqual(last.characterOffset, content.chapters[last.chapterIndex].text.utf16.count)
    }

    /// The sentence a page number interrupts reads with one space, and no
    /// page number is spoken or left in the Markdown as text.
    func testSampleReadsWithoutPageNumbersAndKeepsWordsApart() throws {
        let markdown = try extractedMarkdown(ofFormatSample: "dtbook/pages-front-and-inline.xml")
        let spoken = spokenText(of: parsed(markdown))

        XCTAssertTrue(markdown.contains("harbour wall <!-- page: 2 -->stood dry"))
        XCTAssertTrue(spoken.contains("At low tide the harbour wall stood dry above the slipway."))
        XCTAssertFalse(markdown.contains("[Page"))
        XCTAssertFalse(spoken.contains("[Page"))
        XCTAssertFalse(spoken.contains("<!--"))
    }

    // MARK: - harbour-standalone.xml

    /// The standalone DTBook's two `pagenum` elements are its pages, at the
    /// paragraphs they open, and "[Page 1]" and "[Page 3]" are no longer read.
    func testHarbourPagesReplaceTheSpokenPageLines() throws {
        let markdown = try extractedMarkdown(ofFormatSample: "dtbook/harbour-standalone.xml")
        let content = parsed(markdown)

        XCTAssertEqual(pageLines(of: content, opening: 8), ["1: The ferr", "3: Prices —"])
        let spoken = spokenText(of: content)
        XCTAssertFalse(spoken.contains("[Page 1]"))
        XCTAssertFalse(spoken.contains("[Page 3]"))
    }

    // MARK: - includesPages: false

    /// Without pages every DTBook reads "[Page N]" on a line of its own, as
    /// cache format 3.0.7 wrote it, and no marker is written.
    func testWithoutPagesDTBooksKeepTheSpokenPageLines() throws {
        let sample = try extractedMarkdown(ofFormatSample: "dtbook/pages-front-and-inline.xml", includesPages: false)
        XCTAssertFalse(sample.contains("<!-- page:"))
        XCTAssertTrue(sample.contains("[Page ii]"))
        XCTAssertTrue(sample.contains("[Page 1]"))
        XCTAssertTrue(sample.contains("wall\n[Page 2]\nstood"))
        XCTAssertTrue(sample.contains("[Page ]"))
        XCTAssertTrue(sample.contains("[Page 5]"))

        let harbour = try extractedMarkdown(ofFormatSample: "dtbook/harbour-standalone.xml", includesPages: false)
        XCTAssertFalse(harbour.contains("<!-- page:"))
        XCTAssertTrue(harbour.contains("[Page 1]"))
        XCTAssertTrue(harbour.contains("[Page 3]"))

        let lathe = try extractedMarkdown(ofTestBook: "lathe_of_heaven_daisy.zip", includesPages: false)
        XCTAssertFalse(lathe.contains("<!-- page:"))
        XCTAssertTrue(lathe.contains("[Page"))
    }

    /// The Lathe of Heaven's one `pagenum` has no words, so its page is
    /// labelled by its ordinal and its "[Page ]" line is no longer read.
    func testLathePageIsLabelledByItsOrdinal() throws {
        let markdown = try extractedMarkdown(ofTestBook: "lathe_of_heaven_daisy.zip")
        XCTAssertTrue(markdown.contains("<!-- page: 1 -->"))
        XCTAssertFalse(markdown.contains("[Page"))
        let content = parsed(markdown)
        XCTAssertEqual(content.pages.breaks.map(\.label), ["1"])
    }

    // MARK: - wipo-treaty-d202-text-only.zip

    /// The treaty's NCC lists two page entries, labelled as it labels them.
    /// Each stands where its number was, and the numbers are no longer read;
    /// without pages they are read exactly as before.
    func testWIPOPagesStandWhereTheirNumbersWereRead() throws {
        let withPages = try extractedMarkdown(ofTestBook: "wipo-treaty-d202-text-only.zip")
        let without = try extractedMarkdown(ofTestBook: "wipo-treaty-d202-text-only.zip", includesPages: false)

        let content = parsed(withPages)
        XCTAssertEqual(content.pages.breaks.map(\.label), ["1", "2"])
        XCTAssertFalse(without.contains("<!-- page:"))

        // With pages: the same paragraphs, less the two page numbers, plus
        // the two markers; each marker stands where its number was.
        let paragraphsWithout = without.components(separatedBy: "\n\n")
        let paragraphsWith = withPages.components(separatedBy: "\n\n")
        let markers = paragraphsWith.filter { $0.hasPrefix("<!-- page:") }
        XCTAssertEqual(markers, ["<!-- page: 1 -->", "<!-- page: 2 -->"])
        let numbers = paragraphsWithout.enumerated().filter { $0.element == "1" || $0.element == "2" }
        XCTAssertEqual(numbers.map(\.element), ["1", "2"])
        var replaced = paragraphsWithout
        for (index, element) in numbers.reversed() {
            replaced[index] = "<!-- page: \(element) -->"
        }
        XCTAssertEqual(paragraphsWith, replaced)
    }

    // MARK: - DAISY 2.02 resolution

    /// An NCC with page entries pointing at a `par`, at a `text`, at nothing
    /// but an empty label, and at a SMIL file no heading reads.
    private static func daisy202Files(extraNCC: String = "", extraFiles: [String: String] = [:]) -> [String: String] {
        let ncc = """
        <html><head><meta name="dc:title" content="Pages"/></head><body>
        <h1 id="h"><a href="s1.smil#t_h">Chapter</a></h1>
        <span class="page-normal" id="n1"><a href="s1.smil#par_12">12</a></span>
        <span class="page-front" id="n2"><a href="s1.smil#txt_xi">  xi
        </a></span>
        <span class="page-special" id="n3"><a href="s1.smil#par_blank"></a></span>
        <span class="page-normal" id="n4"><a href="s2.smil#par_99">99</a></span>
        \(extraNCC)
        </body></html>
        """
        let s1 = """
        <smil><body><seq>
        <par id="par_h"><text id="t_h" src="c.html#h"/></par>
        <par id="par_a"><text id="txt_a" src="c.html#a"/></par>
        <par id="par_12"><text id="txt_12" src="c.html#pg12"/></par>
        <par id="par_b"><text id="txt_b" src="c.html#b"/></par>
        <par id="par_xi"><text id="txt_xi" src="c.html#pgxi"/></par>
        <par id="par_c"><text id="txt_c" src="c.html#c"/></par>
        <par id="par_blank"><text id="txt_blank" src="c.html#pgblank"/></par>
        <par id="par_d"><text id="txt_d" src="c.html#d"/></par>
        </seq></body></smil>
        """
        let s2 = """
        <smil><body><seq><par id="par_99"><text id="txt_99" src="c.html#pg99"/></par></seq></body></smil>
        """
        let content = """
        <html><body><h1 id="h">Chapter</h1><p id="a">Alpha words</p><p id="pg12">12</p>
        <p id="b">Beta words</p><p id="pgxi">xi</p><p id="c">Gamma words</p><p id="pgblank">blank</p>
        <p id="d">Delta words</p><p id="pg99">99</p></body></html>
        """
        return ["ncc.html": ncc, "s1.smil": s1, "s2.smil": s2, "c.html": content].merging(extraFiles) { $1 }
    }

    /// Pages whose link names a `par` and one whose link names a `text` both
    /// resolve to their content fragment; an entry without words takes its
    /// place in the NCC (3) as its label; a page whose fragment no heading's
    /// SMIL reads is dropped. No page number is read.
    func testDAISY202PagesResolveThroughParAndTextIDs() throws {
        let markdown = try DAISYParser.extractDAISY202Markdown(from: InMemoryDAISYPackage(Self.daisy202Files()))
        let content = parsed(markdown)

        XCTAssertEqual(pageLines(of: content, opening: 5), [
            "12: Beta ",
            "xi: Gamma",
            "3: Delta"
        ])
        XCTAssertEqual(spokenText(of: content), "Chapter\n\nAlpha words\n\nBeta words\n\nGamma words\n\nDelta words")
    }

    /// Without pages the 2.02 book is read exactly as before: every page
    /// number is a paragraph of its own, and there is no marker.
    func testDAISY202WithoutPagesReadsThePageNumbers() throws {
        let markdown = try DAISYParser.extractDAISY202Markdown(
            from: InMemoryDAISYPackage(Self.daisy202Files()),
            includesPages: false
        )
        XCTAssertFalse(markdown.contains("<!-- page:"))
        XCTAssertEqual(
            markdown,
            "# Chapter\n\nAlpha words\n\n12\n\nBeta words\n\nxi\n\nGamma words\n\nblank\n\nDelta words"
        )
    }

    /// A page entry that points at real text (a faulty link) never costs the
    /// book its words: the marker goes before the paragraph, which is read
    /// as ever. So does one that points at a short caption holding its
    /// number, such as "Page 12" for the entry "12": only the page's own
    /// label is replaced (stable020 review, finding 2), and a caption is
    /// heard, as it was before pages.
    func testDAISY202PageThatPointsAtTextKeepsTheText() throws {
        let ncc = """
        <html><body>
        <h1><a href="s1.smil#t_h">Chapter</a></h1>
        <span class="page-normal"><a href="s1.smil#par_a">7</a></span>
        <span class="page-normal"><a href="s1.smil#par_pg">12</a></span>
        <span class="page-normal"><a href="s1.smil#par_long">9</a></span>
        </body></html>
        """
        let smil = """
        <smil><body><seq>
        <par id="par_h"><text id="t_h" src="c.html#h"/></par>
        <par id="par_a"><text id="txt_a" src="c.html#a"/></par>
        <par id="par_pg"><text id="txt_pg" src="c.html#pg"/></par>
        <par id="par_long"><text id="txt_long" src="c.html#long"/></par>
        </seq></body></smil>
        """
        let sentence = "Beta words continue for a very long sentence that is far beyond thirty-two characters"
        let page = """
        <html><body><h1 id="h">Chapter</h1><p id="a">Alpha words</p><p id="pg">Page 12</p>
        <p id="long">\(sentence)</p></body></html>
        """
        let markdown = try DAISYParser.extractDAISY202Markdown(
            from: InMemoryDAISYPackage(["ncc.html": ncc, "s1.smil": smil, "c.html": page])
        )
        let content = parsed(markdown)

        XCTAssertEqual(spokenText(of: content), "Chapter\n\nAlpha words\n\nPage 12\n\n\(sentence)")
        XCTAssertEqual(pageLines(of: content, opening: 5), ["7: Alpha", "12: Page ", "9: Beta "])
    }

    /// A page entry that points at a heading which looks like a number
    /// ("IV", "XII.", "I", "1984", "1, 2, 3.") under another page's label
    /// keeps the heading, which is read, with the page beginning at it
    /// (stable020 review, finding 2: these were dropped and marked read, so
    /// never spoken). Fragments holding the page's own number ("10" for the
    /// entry "10") or its twin ("XI" for "11") are still replaced.
    func testDAISY202PageThatPointsAtANumberLikeHeadingKeepsIt() throws {
        // Each page entry, by its label, and the id of the fragment it names:
        // a heading for "5" to "9", the page's own number for "10", and the
        // twin of the page's number for "11".
        let entries = [("5", "g5"), ("6", "g6"), ("7", "g7"), ("8", "g8"), ("9", "g9"), ("10", "own"), ("11", "twin")]
        let nccEntries = entries.map { label, id in
            "<span class=\"page-normal\"><a href=\"s1.smil#par_\(id)\">\(label)</a></span>"
        }
        let ncc = "<html><body><h1><a href=\"s1.smil#txt_h\">Chapter</a></h1>\n"
            + nccEntries.joined(separator: "\n") + "\n</body></html>"
        // The SMIL reads the fragments in document order: the chapter's
        // heading, the five headings, then the page's own number before Echo
        // and the twin before Foxtrot.
        let smilOrder = ["h", "g5", "g6", "g7", "g8", "g9", "own", "e", "twin", "f"]
        let smilPars = smilOrder.map { id in
            "<par id=\"par_\(id)\"><text id=\"txt_\(id)\" src=\"c.html#\(id)\"/></par>"
        }
        let smil = "<smil><body><seq>\n" + smilPars.joined(separator: "\n") + "\n</seq></body></smil>"
        let page = """
        <html><body><h1 id="h">Chapter</h1>
        <h2 id="g5">IV</h2><h2 id="g6">XII.</h2><h2 id="g7">I</h2><h2 id="g8">1984</h2><h2 id="g9">1, 2, 3.</h2>
        <p id="own">10</p><p id="e">Echo words</p><p id="twin">XI</p><p id="f">Foxtrot words</p>
        </body></html>
        """
        let markdown = try DAISYParser.extractDAISY202Markdown(
            from: InMemoryDAISYPackage(["ncc.html": ncc, "s1.smil": smil, "c.html": page])
        )
        let content = parsed(markdown)

        XCTAssertEqual(
            spokenText(of: content),
            "Chapter\n\nIV\n\nXII.\n\nI\n\n1984\n\n1, 2, 3.\n\nEcho words\n\nFoxtrot words"
        )
        XCTAssertEqual(
            pageLines(of: content, opening: 4),
            ["5: IV\n\n", "6: XII.", "7: I\n\n1", "8: 1984", "9: 1, 2", "10: Echo", "11: Foxt"]
        )
    }

    /// A page entry whose SMIL file is missing is dropped, as a heading
    /// whose SMIL file is missing is skipped; the rest of the book reads on.
    func testDAISY202PageWithMissingSMILIsDropped() throws {
        let files = Self.daisy202Files(
            extraNCC: #"<span class="page-normal"><a href="gone.smil#par_1">7</a></span>"#
        )
        let markdown = try DAISYParser.extractDAISY202Markdown(from: InMemoryDAISYPackage(files))
        XCTAssertEqual(parsed(markdown).pages.breaks.map(\.label), ["12", "xi", "3"])
    }

    /// A page's SMIL file that is damaged stops the book's extraction naming
    /// that file, as a heading's damaged SMIL file does; without pages the
    /// file is never read, so the book extracts as before.
    func testDAISY202PageWithDamagedSMILThrowsNamingTheFile() throws {
        let damaged = #"<smil><body><seq><par id="par_5"><text id="t5" src="c.html#pg99"/>"#
        let files = Self.daisy202Files(
            extraNCC: #"<span class="page-normal"><a href="bad.smil#par_5">5</a></span>"#,
            extraFiles: ["bad.smil": damaged]
        )
        let package = InMemoryDAISYPackage(files)

        XCTAssertThrowsError(try DAISYParser.extractDAISY202Markdown(from: package)) { error in
            guard case DAISYParserError.malformedXML(let file, _) = error else {
                return XCTFail("Expected malformedXML, got \(error)")
            }
            XCTAssertEqual(file, "bad.smil")
        }
        XCTAssertNoThrow(try DAISYParser.extractDAISY202Markdown(from: package, includesPages: false))
    }

    /// A page link that names no id, or one the SMIL file does not hold, is
    /// dropped, and so is one whose text source names a whole file: a marker
    /// must never take the place of a file's text.
    func testDAISY202PagesWithoutAFragmentAreDropped() throws {
        let smil = """
        <smil><body><seq>
        <par id="par_h"><text id="t_h" src="c.html#h"/></par>
        <par id="par_a"><text id="txt_a" src="c.html#a"/></par>
        <par id="par_whole"><text id="txt_whole" src="c.html"/></par>
        </seq></body></smil>
        """
        let ncc = """
        <html><body>
        <h1><a href="s1.smil#t_h">Chapter</a></h1>
        <span class="page-normal"><a href="s1.smil">1</a></span>
        <span class="page-normal"><a href="s1.smil#nowhere">2</a></span>
        <span class="page-normal"><a href="s1.smil#par_whole">3</a></span>
        <span class="page-normal">4</span>
        </body></html>
        """
        let content = #"<html><body><h1 id="h">Chapter</h1><p id="a">Alpha words</p></body></html>"#
        let markdown = try DAISYParser.extractDAISY202Markdown(
            from: InMemoryDAISYPackage(["ncc.html": ncc, "s1.smil": smil, "c.html": content])
        )
        XCTAssertFalse(markdown.contains("<!-- page:"))
        XCTAssertTrue(markdown.contains("Alpha words"))
    }

    /// The SMIL parser maps every `text` element's id, and its enclosing
    /// `par`'s id, to the first source they hold, from the same parse that
    /// lists the sources.
    func testSMILParserMapsParAndTextIDsToTheirSources() throws {
        let smil = """
        <smil><body><seq>
        <par id="p1"><text id="t1" src="a.html#x"/><text id="t2" src="a.html#y"/></par>
        <par><text id="t3" src="b.html#z"/></par>
        <par id="p4"><text src="c.html#w"/></par>
        </seq></body></smil>
        """
        let references = try DAISYSMILParser(data: Data(smil.utf8), file: "s.smil").parseReferences()

        XCTAssertEqual(references.textReferences, ["a.html#x", "a.html#y", "b.html#z", "c.html#w"])
        XCTAssertEqual(references.textReferencesByID, [
            "p1": "a.html#x", "t1": "a.html#x", "t2": "a.html#y", "t3": "b.html#z", "p4": "c.html#w"
        ])
        XCTAssertEqual(
            try DAISYSMILParser(data: Data(smil.utf8), file: "s.smil").parseTextReferences(),
            references.textReferences
        )
    }

    /// The NCC lists its page entries in document order with their labels
    /// and links, whatever the case of their class names.
    func testNCCListsPageEntriesInOrder() throws {
        let html = """
        <html><body>
        <h1><a href="a.smil#1">One</a></h1>
        <span class="PAGE-Front other"><a href="a.smil#2">iv</a></span>
        <span class="page-special"><a href="a.smil#3"> A - 1 </a></span>
        <span class="sentence"><a href="a.smil#4">not a page</a></span>
        </body></html>
        """
        let result = try DAISY202NCCParser(html: html, file: "ncc.html").parse()

        XCTAssertEqual(result.headings.map(\.text), ["One"])
        XCTAssertEqual(result.pages.map(\.label), ["iv", "A - 1"])
        XCTAssertEqual(result.pages.map(\.href), ["a.smil#2", "a.smil#3"])
    }

    // MARK: - DTBook converter

    /// A page number in the middle of a word run reads as a space, with or
    /// without whitespace around it in the source.
    func testPageNumberInRunningTextReadsAsOneSpace() throws {
        let tight = try convertDTBook("<p>before<pagenum>12</pagenum>after</p>")
        XCTAssertEqual(tight, "before <!-- page: 12 -->after")

        let spaced = try convertDTBook("<p>before <pagenum>12</pagenum> after</p>")
        XCTAssertEqual(spaced, "before <!-- page: 12 -->after")
    }

    /// A page number between blocks, or opening one, is a block of its own.
    func testPageNumberAtABlockBoundaryIsABlock() throws {
        let markdown = try convertDTBook("<p>one</p><pagenum>7</pagenum><p><pagenum>8</pagenum>two</p>")
        XCTAssertEqual(markdown, "one\n\n<!-- page: 7 -->\n\n<!-- page: 8 -->\n\ntwo")
    }

    /// A page number inside a table row or a list item is inline, and the
    /// row and the item read as they did, apart from the number.
    func testPageNumberInATableRowAndAListItemIsInline() throws {
        let body = """
        <table><tr><td>Alpha</td><td>Beta<pagenum>7</pagenum>gamma</td></tr></table>
        <list type="ul"><li>Bread<pagenum>8</pagenum> and butter</li></list>
        """
        let markdown = try convertDTBook(body)
        let spoken = spokenText(of: parsed(markdown))

        XCTAssertTrue(markdown.contains("Beta <!-- page: 7 -->gamma"))
        XCTAssertTrue(markdown.contains("- Bread <!-- page: 8 -->and butter"))
        XCTAssertEqual(spoken, "Alpha Beta gamma\n\nBread and butter")
        XCTAssertEqual(parsed(markdown).pages.breaks.map(\.label), ["7", "8"])
    }

    /// A page number opening a list item is a block inside the item, before
    /// its words: a marker after the item's marker would turn the item's
    /// whole first line into raw HTML and take its words from speech.
    func testPageNumberOpeningAListItemKeepsTheItemsWords() throws {
        let markdown = try convertDTBook("<list type=\"ol\"><li>First</li><li><pagenum>9</pagenum>Second</li></list>")
        let content = parsed(markdown)

        XCTAssertEqual(spokenText(of: content), "First\n\nSecond")
        XCTAssertEqual(pageLines(of: content), ["9: Second"])
    }

    /// The same with the source's whitespace after `<li>` and around the page
    /// number, where the marker began an indented line, read aloud as code
    /// with the item's words.
    func testPageNumberOpeningAListItemAfterWhitespaceKeepsTheItemsWords() throws {
        let markdown = try convertDTBook(
            "<list type=\"ul\"><li>First item words.</li><li>\n  <pagenum>7</pagenum>\n  Second item words.</li></list>"
        )
        let content = parsed(markdown)

        XCTAssertEqual(spokenText(of: content), "First item words.\n\nSecond item words.")
        XCTAssertEqual(pageLines(of: content), ["7: Second item wo"])
    }

    /// A page number opening a block quote or a heading, with the source's
    /// whitespace around it, is written inside it before its words, so the
    /// quote keeps its words and the heading its label, and nothing is read
    /// as code.
    func testPageNumberOpeningAQuoteOrAHeadingKeepsTheirWords() throws {
        let quote = parsed(try convertDTBook("<blockquote>\n  <pagenum>3</pagenum>\n  Quoted words.</blockquote>"))
        XCTAssertEqual(spokenText(of: quote), "Quoted words.")
        XCTAssertEqual(pageLines(of: quote), ["3: Quoted words."])

        let heading = parsed(try convertDTBook("<h2>\n  <pagenum>9</pagenum>\n  Chapter Two</h2><p>Body text.</p>"))
        XCTAssertEqual(spokenText(of: heading), "Chapter Two\n\nBody text.")
        XCTAssertEqual(heading.allHeadings.map(\.text), ["Chapter Two"])
        XCTAssertEqual(pageLines(of: heading), ["9: Chapter Two\n\nB"])
    }

    /// Page numbers in lists keep every word and are never read. A nested
    /// item's paragraph breaks the list apart, as the source's whitespace
    /// and the item's `<p>` leave it, and its lines four columns in are code:
    /// a page number after that paragraph is a block at the margin, never
    /// on one of those lines (are-you-ready-d3-audio's page 11). One opening
    /// a nested item is a block after the item's opening, four columns in;
    /// one between two items with only spaces around it is written at the
    /// end of the item before, not on a line the next item would run into.
    func testPageNumbersInNestedListsKeepEveryItemsWords() throws {
        let brokenApart = parsed(try convertDTBook(
            "<list type=\"ul\"><li><p>One.</p><list type=\"ol\"><li><p>Two words.</p>\n  <pagenum>11</pagenum>\n</li>"
                + "<li><p>Three words.</p></li></list></li></list>"
        ))
        let spoken = spokenText(of: brokenApart)
        XCTAssertFalse(spoken.contains("<!--"), spoken)
        for words in ["One.", "Two words.", "Three words."] {
            XCTAssertTrue(spoken.contains(words), "\(words) is missing from: \(spoken)")
        }
        XCTAssertEqual(brokenApart.pages.breaks.map(\.label), ["11"])

        let opening = parsed(try convertDTBook(
            "<list type=\"ul\"><li>Alpha<list type=\"ol\"><li>Beta</li><li><pagenum>8</pagenum>Gamma words</li></list></li></list>"
        ))
        XCTAssertEqual(spokenText(of: opening), "Alpha\n\nBeta\n\nGamma words")
        XCTAssertEqual(pageLines(of: opening, opening: 5), ["8: Gamma"])

        let spaced = parsed(try convertDTBook("<list type=\"ul\"><li>First</li> <pagenum>8</pagenum> <li>Second</li></list>"))
        XCTAssertEqual(spokenText(of: spaced), "First\n\nSecond")
        XCTAssertEqual(pageLines(of: spaced, opening: 6), ["8: Second"])
    }

    /// Markup inside a page number is not written; only its words name the page.
    func testMarkupInsideAPageNumberIsNotWritten() throws {
        let markdown = try convertDTBook("<p>one</p><pagenum><em>iv</em> <span>b</span></pagenum><p>two</p>")
        XCTAssertEqual(markdown, "one\n\n<!-- page: iv b -->\n\ntwo")
    }

    /// A label with characters a comment cannot hold survives a round trip
    /// through content.md, and one that is too long is cut.
    func testUnusualLabelsRoundTrip() throws {
        let long = String(repeating: "x", count: 40)
        let markdown = try convertDTBook("<p>a</p><pagenum>A--3 &lt;b&gt;</pagenum><p>b</p><pagenum>\(long)</pagenum><p>c</p>")
        let content = parsed(markdown)

        XCTAssertEqual(content.pages.breaks.map(\.label), ["A--3 <b>", String(repeating: "x", count: 32)])
        XCTAssertEqual(spokenText(of: content), "a\n\nb\n\nc")
    }

    /// A `pagenum` with only whitespace is labelled by its ordinal, the
    /// number of `pagenum` elements read before it, plus one.
    func testEmptyPageNumberTakesItsOrdinal() throws {
        let markdown = try convertDTBook("<p>a</p><pagenum>5</pagenum><p>b</p><pagenum>  </pagenum><p>c</p><pagenum/>")
        XCTAssertEqual(parsed(markdown).pages.breaks.map(\.label), ["5", "2", "3"])
    }

    /// A DTBook whose `level1` holds `body`, as a file of the package built by `twoFilePackage`.
    private static func dtbookFile(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <dtbook xmlns="http://www.daisy.org/z3986/2005/dtbook/" version="2005-3">
        <head><meta name="dc:Title" content="T"/></head>
        <book><bodymatter><level1>\(body)</level1></bodymatter></book></dtbook>
        """
    }

    /// A DAISY 3 package whose spine names two DTBook files, `one.xml` and `two.xml`.
    private func twoFilePackage(one: String, two: String) throws -> URL {
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://openebook.org/namespaces/oeb-package/1.0/">
        <metadata><dc-metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:Title>Two Files</dc:Title><dc:Creator>Odile Marchetti</dc:Creator>
        </dc-metadata></metadata>
        <manifest>
        <item id="one" href="one.xml" media-type="application/x-dtbook+xml"/>
        <item id="two" href="two.xml" media-type="application/x-dtbook+xml"/>
        </manifest>
        <spine><itemref idref="one"/><itemref idref="two"/></spine>
        </package>
        """
        return try DAISYPackageFixtures.writeFolder(
            ["book.opf": opf, "one.xml": Self.dtbookFile(one), "two.xml": Self.dtbookFile(two)],
            named: "TwoFiles", in: try makeSandboxDirectory("DAISYPagesTwoFiles"))
    }

    /// A page with no words is labelled by its place in the whole book, not
    /// in its file: two files with an empty page number each give 1, 2, then
    /// 3, 4, where each file began again at 1 before.
    func testEmptyPageNumbersCountThroughTheFilesOfABook() throws {
        let package = try twoFilePackage(
            one: "<p>a</p><pagenum> </pagenum><p>b</p><pagenum/>",
            two: "<p>c</p><pagenum></pagenum><p>d</p><pagenum> </pagenum>")
        let markdown = try DAISYParser.extractMarkdown(from: package)
        XCTAssertEqual(parsed(markdown).pages.breaks.map(\.label), ["1", "2", "3", "4"])
    }

    /// A page that has words keeps its own label, and still counts toward the
    /// ordinal of the next empty one, in its file and the files after it.
    func testNumberedPagesCountTowardTheNextFilesOrdinals() throws {
        let package = try twoFilePackage(
            one: "<p>a</p><pagenum>iv</pagenum><p>b</p><pagenum>5</pagenum>",
            two: "<p>c</p><pagenum> </pagenum><p>d</p>")
        let markdown = try DAISYParser.extractMarkdown(from: package)
        XCTAssertEqual(parsed(markdown).pages.breaks.map(\.label), ["iv", "5", "3"])
    }

    /// With pages off the converter writes "[Page N]" on a line of its own,
    /// as it did, even for markup inside the number.
    func testPageNumberWithoutPagesIsTheOldLine() throws {
        let markdown = try convertDTBook("<p>before<pagenum>12</pagenum>after</p>", includesPages: false)
        XCTAssertEqual(markdown, "before\n[Page 12]\nafter")
    }

    /// A file that breaks off inside a page number still gets that page's
    /// marker, so no "[Page" or half a comment reaches speech.
    func testDamageInsidePageNumberClosesItsMarker() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <dtbook xmlns="http://www.daisy.org/z3986/2005/dtbook/"><book><bodymatter><level1>
        <p>Some words here.</p><pagenum>12</pagenum><p>More words <pagenum>13</pagenum> and <pagenum>14
        """
        let conversion = try DTBookToMarkdownConverter(data: Data(xml.utf8), file: "book.xml").convert()

        XCTAssertNotNil(conversion.diagnostic)
        XCTAssertFalse(conversion.markdown.contains("[Page"))
        XCTAssertTrue(conversion.markdown.contains("<!-- page: 12 -->"))
        XCTAssertTrue(conversion.markdown.contains("<!-- page: 13 -->"))
        // The page cut short is closed too, labelled by what was read of it.
        XCTAssertEqual(conversion.markdown.components(separatedBy: "<!-- page:").count - 1, 3)
        let spoken = spokenText(of: parsed(conversion.markdown))
        XCTAssertFalse(spoken.contains("<!--"))
        XCTAssertTrue(spoken.contains("More words"))
    }
}
