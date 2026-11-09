import XCTest
@testable import TextMouth

/// Kindle (MOBI 6) books built in code (`MOBIFixture`), to prove each part of
/// the reader against the format's specification and not only against the
/// few real files: the text records and their trailing entries, PalmDOC
/// compression, the contents (NCX) and its depths, the `filepos` anchors,
/// the markup, the encodings, the metadata, and each refusal.
final class MOBIBookStructureTests: XCTestCase {

    // MARK: - Helpers

    /// `fixture` read as a file, the way an import reads it.
    private func prepared(_ fixture: MOBIFixture) throws -> MOBIParser.PreparedBook {
        try MOBIParser.prepareBook(url: writeMOBI(fixture.data()))
    }

    /// `fixture` opened in memory, before the HTML is converted.
    private func opened(_ fixture: MOBIFixture) throws -> MOBIBook {
        try MOBIBook(bytes: fixture.data())
    }

    /// The byte offset of `needle` in `html`'s UTF-8, which is where a
    /// contents entry or a `filepos` names it.
    private func offset(of needle: String, in html: String) throws -> Int {
        let range = try XCTUnwrap(html.range(of: needle), needle)
        return html.utf8.distance(from: html.startIndex, to: range.lowerBound)
    }

    /// `text` with every run of white space made one space.
    private func spaced(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `html` from its `<body` tag on: the part of a book the reader reads. What
    /// comes before, the head, is about the book and is left out.
    private func fromBody(_ html: String) -> String {
        html.range(of: "<body").map { String(html[$0.lowerBound...]) } ?? html
    }

    /// A text long enough for several records, with phrases that repeat (so
    /// a PalmDOC compressor uses back references) and spaces before capitals
    /// (so it uses the space codes).
    private func longHTML() -> String {
        let sentence = "The ferry leaves the Tallow Quay at seven. Ask for Odalys at the hatch. "
        let body = (0..<120).map { "<p>Crossing \($0): " + sentence + "</p>" }.joined()
        return "<html><head></head><body>" + body + "</body></html>"
    }

    // MARK: - The text records

    func testTheTextOfEveryCompressionAndRecordSizeReadsBack() throws {
        let html = longHTML()
        for compression in [1, 2] {
            for recordSize in [4096, 1000, 77] {
                var fixture = MOBIFixture()
                fixture.html = html
                fixture.compression = compression
                fixture.recordSize = recordSize
                let book = try opened(fixture)
                XCTAssertEqual(book.sections.count, 1, "compression \(compression), records of \(recordSize)")
                XCTAssertEqual(book.sections[0].html, fromBody(html), "compression \(compression), records of \(recordSize)")
            }
        }
    }

    func testTrailingEntriesAreTakenOffEveryRecord() throws {
        for compression in [1, 2] {
            var fixture = MOBIFixture()
            fixture.html = longHTML()
            fixture.compression = compression
            fixture.recordSize = 500
            fixture.trailingEntry = Array("TRAILING ENTRY".utf8)
            XCTAssertEqual(try opened(fixture).sections[0].html, fromBody(fixture.html), "compression \(compression)")
        }
    }

    func testTheUsableLengthOfARecordFollowsItsExtraDataFlags() throws {
        // Four text bytes, an entry of two bytes whose size, 3, is its last
        // byte with the high bit set, then nothing: flag bit 1.
        let withEntry = MOBIView([0x61, 0x62, 0x63, 0x64, 0x7E, 0x7F, 0x83])
        XCTAssertEqual(try MOBIText.usableLength(of: withEntry, flags: 0b10), 4)
        // The same record without flags is all text.
        XCTAssertEqual(try MOBIText.usableLength(of: withEntry, flags: 0), 7)
        // Bit 0: the last byte, 0x01, says (1 & 3) + 1 = 2 bytes of a
        // multibyte character that goes on in the next record.
        XCTAssertEqual(try MOBIText.usableLength(of: MOBIView([0x61, 0x62, 0xE2, 0x01]), flags: 0b1), 2)
        // Both: the entry comes off first, then the overlap.
        XCTAssertEqual(try MOBIText.usableLength(of: MOBIView([0x61, 0x62, 0xE2, 0x01, 0x7E, 0x7F, 0x83]), flags: 0b11), 2)
        // A size of two bytes, 0x81 0x05: the byte with the high bit starts the number, so 1 * 128 + 5 = 133.
        var long = [UInt8](repeating: 0x61, count: 200)
        long += [UInt8](repeating: 0x7E, count: 131) + [0x81, 0x05]
        XCTAssertEqual(try MOBIText.usableLength(of: MOBIView(long), flags: 0b10), 200)
    }

    func testAnEntryLargerThanItsRecordIsDamage() {
        // The size, 0x85 = 5, is more than the three bytes there are.
        XCTAssertThrowsError(try MOBIText.usableLength(of: MOBIView([0x61, 0x62, 0x85]), flags: 0b10)) {
            guard case .damaged = $0 as? MOBIError else { return XCTFail("\($0)") }
        }
        // No byte in the last four starts a number.
        XCTAssertThrowsError(try MOBIText.usableLength(of: MOBIView([0x01, 0x02, 0x03, 0x04, 0x05]), flags: 0b10))
        // A multibyte overlap of more than the record.
        XCTAssertThrowsError(try MOBIText.usableLength(of: MOBIView([0x03]), flags: 0b1))
    }

    // MARK: - PalmDOC compression

    /// `bytes` decompressed as one record after `earlier` bytes of output.
    private func decompressed(_ bytes: [UInt8], after earlier: [UInt8] = [], limit: Int = 1000) throws -> [UInt8] {
        var output = earlier
        try MOBIText.decompressPalmDOC(bytes, 0..<bytes.count, into: &output, limit: limit)
        return Array(output.dropFirst(earlier.count))
    }

    func testPalmDOCCodesEachDoWhatTheFormatSays() throws {
        // A byte as itself, and NUL.
        XCTAssertEqual(try decompressed([0x61, 0x00, 0x7F]), [0x61, 0x00, 0x7F])
        // 0x03: the next three bytes, as they are.
        XCTAssertEqual(try decompressed([0x03, 0xC3, 0xA9, 0x41]), [0xC3, 0xA9, 0x41])
        // 0xC1: a space, then 0x41 ("A").
        XCTAssertEqual(try decompressed([0xC1]), [0x20, 0x41])
        // "abc", then distance 3 and length 6: 0x8000 | 3 << 3 | (6 - 3) = 0x801B.
        XCTAssertEqual(String(decoding: try decompressed([0x61, 0x62, 0x63, 0x80, 0x1B]), as: UTF8.self), "abcabcabc")
        // Distance 1, length 10: one byte repeated, a phrase that overlaps itself.
        XCTAssertEqual(String(decoding: try decompressed([0x78, 0x80, 0x0F]), as: UTF8.self), "xxxxxxxxxxx")
    }

    func testEveryBadPalmDOCRecordIsRefused() {
        let bad: [(String, [UInt8], [UInt8])] = [
            ("a phrase before the start of the record", [0x80, 0x0B], []),
            ("a distance of 0", [0x61, 0x80, 0x03], []),
            // Earlier records' output is not reachable from this one.
            ("a phrase into the record before", [0x61, 0x80, 0x1B], Array("abcdef".utf8)),
            ("a phrase cut off after its first byte", [0x61, 0x80], []),
            ("a run longer than what is left", [0x05, 0x61, 0x62], []),
        ]
        for (name, record, earlier) in bad {
            XCTAssertThrowsError(try decompressed(record, after: earlier), name) {
                guard case .damaged = $0 as? MOBIError else { return XCTFail("\(name): \($0)") }
            }
        }
    }

    func testDecompressionStopsAtTheLimitItIsGiven() throws {
        // One letter, then phrase after phrase of ten, 3000 times over.
        let bomb: [UInt8] = [0x61] + Array([[UInt8]](repeating: [0x80, 0x0F], count: 3000).joined())
        XCTAssertEqual(try decompressed(bomb, limit: 100).count, 100)
    }

    func testTheCompressorOfTheFixtureAndTheReaderAgreeOnRandomText() throws {
        var generator = SeededGenerator(state: 42)
        for round in 0..<20 {
            // Letters from a small alphabet, so phrases repeat; spaces; and a few high bytes.
            let alphabet = Array("abcde ABCDE\u{0}\n".utf8) + [0xC3, 0xA9]
            let input = (0..<(200 + round * 90)).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] }
            let compressed = MOBIFixture.compress(input)
            XCTAssertEqual(try decompressed(compressed, limit: 100_000), input, "round \(round)")
        }
    }

    // MARK: - The contents (NCX)

    /// A book of two parts, the first with a section, and a contents that
    /// names all three.
    private func twoPartBook() throws -> MOBIFixture {
        var fixture = MOBIFixture()
        fixture.html = "<html><head></head><body>"
            + "<p>Part One opens on the quay.</p>"
            + "<p>Section A holds the harbour notes.</p>"
            + "<p>Part Two begins at dusk.</p>"
            + "</body></html>"
        fixture.entries = [
            .init(label: "Part One", offset: try offset(of: "<p>Part One", in: fixture.html), depth: 0),
            .init(label: "Section A", offset: try offset(of: "<p>Section A", in: fixture.html), depth: 1),
            .init(label: "Part Two", offset: try offset(of: "<p>Part Two", in: fixture.html), depth: 0),
        ]
        return fixture
    }

    func testTopLevelEntriesAreChaptersAndDeeperEntriesAreHeadings() throws {
        let book = try prepared(twoPartBook())
        XCTAssertEqual(book.chapters.map(\.chapter.title), ["Part One", "Part Two"])
        guard book.chapters.count == 2 else { return XCTFail("chapters: \(book.chapters.map(\.chapter.title))") }
        let first = book.chapters[0].chapter
        XCTAssertEqual(first.headings.map(\.text), ["Part One", "Section A"])
        XCTAssertEqual(first.headings.map(\.level), [1, 2])
        // The heading is at the words it names, and adds none of its own.
        let section = try XCTUnwrap(first.headings.last)
        XCTAssertTrue(String(first.text.dropFirst(section.characterOffset)).hasPrefix("Section A holds the harbour notes."))
        XCTAssertEqual(spaced(first.text), "Part One opens on the quay. Section A holds the harbour notes.")
        XCTAssertEqual(spaced(book.chapters[1].chapter.text), "Part Two begins at dusk.")
    }

    func testTheMarkdownKeepsEntriesAsAnnotationsNotWords() throws {
        let book = try prepared(twoPartBook())
        XCTAssertTrue(book.chapters[0].markdown.contains("<!-- textmouth-heading: "))
        XCTAssertFalse(book.chapters.first?.chapter.text.contains("textmouth") ?? true)
    }

    func testWordsBeforeTheFirstEntryAreAChapterOfTheirOwn() throws {
        var fixture = MOBIFixture()
        fixture.html = "<html><body><p>A dedication to the ferry crew.</p><p>The story starts.</p></body></html>"
        fixture.entries = [.init(label: "The Story", offset: try offset(of: "<p>The story", in: fixture.html))]
        let book = try prepared(fixture)
        XCTAssertEqual(book.chapters.map(\.chapter.title), ["Chapter 1", "The Story"])
        XCTAssertEqual(spaced(book.chapters.first?.chapter.text ?? ""), "A dedication to the ferry crew.")
    }

    func testTwoEntriesAtOnePlaceAreOneChapterAndAnEntryPastTheEndIsPassedOver() throws {
        var fixture = MOBIFixture()
        fixture.html = "<html><body><p>One.</p><p>Two.</p></body></html>"
        let start = try offset(of: "<p>One", in: fixture.html)
        fixture.entries = [
            .init(label: "First Name", offset: start),
            .init(label: "Second Name", offset: start),
            .init(label: "Nowhere", offset: 9_999_999),
        ]
        let book = try prepared(fixture)
        XCTAssertEqual(book.chapters.map(\.chapter.title), ["First Name"])
    }

    func testAnEntryInTheMiddleOfATagIsAnchoredAtTheTagsStart() throws {
        var fixture = MOBIFixture()
        fixture.html = "<html><body><p>Lead.</p><p align=\"left\" class=\"x\">Second part words.</p></body></html>"
        // Three bytes into the second paragraph's tag.
        fixture.entries = [.init(label: "Second", offset: try offset(of: "<p align", in: fixture.html) + 3)]
        let book = try opened(fixture)
        XCTAssertEqual(book.sections.count, 2)
        XCTAssertTrue(book.sections[1].html.hasPrefix("<a id=\"filepos-\(fixture.entries[0].offset)\"></a><p align="))
    }

    // MARK: - Without a contents

    func testPageBreaksCutChaptersWhenThereIsNoContents() throws {
        var fixture = MOBIFixture()
        fixture.html = "<html><body><p>First words.</p><mbp:pagebreak/><h2>Second Part</h2><p>Second words.</p>"
            + "<mbp:pagebreak /><p>Third words.</p></body></html>"
        let book = try prepared(fixture)
        // A chapter with a heading of its own takes the heading as its title.
        XCTAssertEqual(book.chapters.map(\.chapter.title), ["Chapter 1", "Second Part", "Chapter 3"])
        XCTAssertEqual(spaced(book.chapters.dropFirst().first?.chapter.text ?? ""), "Second Part Second words.")
        // A page break is a layout break, never a print page.
        XCTAssertTrue(book.chapters.allSatisfy { $0.chapter.pages.isEmpty })
        XCTAssertFalse(book.chapters.contains { $0.markdown.contains("pagebreak") })
    }

    func testPageBreaksAreNoChapterBoundariesWhenThereIsAContents() throws {
        var fixture = MOBIFixture()
        fixture.html = "<html><body><p>Only chapter words.</p><mbp:pagebreak/><p>More words after a break.</p></body></html>"
        fixture.entries = [.init(label: "Everything", offset: try offset(of: "<p>Only", in: fixture.html))]
        let book = try prepared(fixture)
        XCTAssertEqual(book.chapters.map(\.chapter.title), ["Everything"])
        XCTAssertEqual(spaced(book.chapters.first?.chapter.text ?? ""), "Only chapter words. More words after a break.")
    }

    func testChaptersThatHoldNoWordsAreLeftOut() throws {
        var fixture = MOBIFixture()
        fixture.html = "<html><body><mbp:pagebreak/> <mbp:pagebreak/><p>Words at last.</p></body></html>"
        let book = try prepared(fixture)
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertEqual(book.chapters[0].chapter.title, "Chapter 1")
    }

    // MARK: - The markup

    func testFileposLinksGetDestinationsAndAreReadAsPlainWords() throws {
        var fixture = MOBIFixture()
        fixture.html = "<html><body><p>See <a filepos=0000000000>the end</a> for the last word.</p><p id=\"x\">The end.</p></body></html>"
        let target = try offset(of: "<p id", in: fixture.html)
        fixture.html = fixture.html.replacingOccurrences(of: "filepos=0000000000", with: String(format: "filepos=%010d", target))
        let book = try opened(fixture)
        XCTAssertTrue(book.sections[0].html.contains("<a id=\"filepos-\(target)\"></a><p id"))
        let chapter = try XCTUnwrap(try prepared(fixture).chapters.first).chapter
        XCTAssertEqual(spaced(chapter.text), "See the end for the last word. The end.")
        XCTAssertFalse(chapter.text.contains("filepos"))
    }

    func testMobipocketTagsAreTakenOutAndTheirWordsKept() throws {
        var fixture = MOBIFixture()
        fixture.html = "<html><body><mbp:section><p>Inside <mbp:nu>numbered</mbp:nu> words.</p></mbp:section></body></html>"
        let chapter = try XCTUnwrap(try prepared(fixture).chapters.first).chapter
        XCTAssertEqual(spaced(chapter.text), "Inside numbered words.")
        XCTAssertFalse(try opened(fixture).sections[0].html.contains("mbp:"))
    }

    func testAnImageKeepsItsAltTextAndAnImageWithoutOneAddsNoWords() throws {
        var fixture = MOBIFixture()
        fixture.html = "<html><body><p>Look: <img recindex=\"00001\" alt=\"a chalk map of the pier\"/> and <img recindex=\"00002\"/> done.</p></body></html>"
        let chapter = try XCTUnwrap(try prepared(fixture).chapters.first).chapter
        XCTAssertEqual(spaced(chapter.text), "Look: a chalk map of the pier and done.")
    }

    func testHeadingsFromTheMarkupBecomeHeadings() throws {
        var fixture = MOBIFixture()
        fixture.html = "<html><body><h1>The Book</h1><p>Words.</p><h2>A Part</h2><p>More words.</p></body></html>"
        let chapter = try XCTUnwrap(try prepared(fixture).chapters.first).chapter
        XCTAssertEqual(chapter.headings.map { "\($0.level): \($0.text)" }, ["1: The Book", "2: A Part"])
        XCTAssertEqual(chapter.title, "The Book")
    }

    func testTheScanFindsEveryFileposAndPageBreak() {
        let html = "<a filepos=0000000012>x</a><A FILEPOS='34'>y</A><a href=\"q\" filepos = \"56\">z</a>"
            + "<mbp:pagebreak/><MBP:PAGEBREAK><pagebreak/>"
            + "<!-- <a filepos=99> --><a title=\"filepos=77\">t</a><a filepos=12345678901>too long</a>"
        let scan = MOBIMarkup.scan(Array(html.utf8))
        XCTAssertEqual(scan.fileposTargets, [12, 34, 56])
        XCTAssertEqual(scan.pageBreakOffsets.count, 3)
    }

    func testAQuotedGreaterThanDoesNotEndATag() {
        let html = "<a title=\"a > b\" filepos=5>x</a>"
        XCTAssertEqual(MOBIMarkup.scan(Array(html.utf8)).fileposTargets, [5])
    }

    func testAnchorsSnapToTheStartOfTheTagTheyFallIn() {
        let text = Array("<p>ab</p><p class=\"c\">de</p>".utf8)
        // 1 is inside "<p>", 4 is the text "b" (a tag-free place), 14 is inside the second tag.
        let anchors = MOBIMarkup.anchors(for: [1, 4, 14, 999], in: text)
        XCTAssertEqual(anchors.map(\.offset), [1, 4, 14])
        XCTAssertEqual(anchors.map(\.position), [0, 4, 9])
    }

    func testMarkupNestedTooDeeplyIsRefusedAndAReasonableOneIsNot() throws {
        func book(depth: Int) -> MOBIFixture {
            var fixture = MOBIFixture()
            fixture.html = "<html><body>" + String(repeating: "<div>", count: depth) + "words"
                + String(repeating: "</div>", count: depth) + "</body></html>"
            return fixture
        }
        // Three times the deepest real book, and well inside what a debug build's
        // converter survives on a worker's stack (about 108 levels).
        XCTAssertNoThrow(try prepared(book(depth: 36)))
        XCTAssertThrowsError(try prepared(book(depth: 300))) {
            XCTAssertEqual($0 as? MarkupRefusal, .nestedTooDeeply(limit: MarkupGuard.Limits.standard.deepestNesting))
        }
        // End tags a book leaves out do not count as nesting for a paragraph.
        var loose = MOBIFixture()
        loose.html = "<html><body>" + String(repeating: "<p>word<br>", count: 5000) + "</body></html>"
        XCTAssertNoThrow(try prepared(loose))
    }

    // MARK: - Encodings

    func testWindows1252TextIsReadAsWindows1252() throws {
        var fixture = MOBIFixture()
        fixture.encoding = 1252
        // "Café “quoted” –" with 0xE9, the curly quotes 0x93 and 0x94, and an en dash 0x96.
        fixture.textBytes = Array("<html><body><p>Caf".utf8) + [0xE9, 0x20, 0x93] + Array("quoted".utf8) + [0x94, 0x20, 0x96]
            + Array("</p></body></html>".utf8)
        let chapter = try XCTUnwrap(try prepared(fixture).chapters.first).chapter
        XCTAssertEqual(spaced(chapter.text), "Café “quoted” –")
    }

    func testABadByteInUTF8TextCostsOneCharacterNotTheBook() throws {
        var fixture = MOBIFixture()
        fixture.textBytes = Array("<html><body><p>Before ".utf8) + [0xFF] + Array(" after.</p></body></html>".utf8)
        let chapter = try XCTUnwrap(try prepared(fixture).chapters.first).chapter
        XCTAssertEqual(spaced(chapter.text), "Before \u{FFFD} after.")
    }

    // MARK: - The metadata

    func testTheTitleComesFromEXTHThenTheHeaderThenTheDatabaseName() throws {
        var fixture = MOBIFixture()
        XCTAssertEqual(try prepared(fixture).title, "Fixture Book")
        fixture.title = nil
        XCTAssertEqual(try prepared(fixture).title, "Fixture Book Full Name")
        fixture.fullName = ""
        XCTAssertEqual(try prepared(fixture).title, "Fixture Book")
        fixture.databaseName = "Dock_Notes_Volume_2"
        XCTAssertEqual(try prepared(fixture).title, "Dock Notes Volume 2")
    }

    func testAuthorsAreJoinedEntitiesAreRead_AndNoAuthorIsUnknown() throws {
        var fixture = MOBIFixture()
        fixture.authors = ["Imre Falk", "Tom &amp; Jerry Brannock"]
        XCTAssertEqual(try prepared(fixture).author, "Imre Falk, Tom & Jerry Brannock")
        fixture.authors = []
        XCTAssertEqual(try prepared(fixture).author, Book.unknownAuthor)
        XCTAssertEqual(try prepared(fixture).language, "en")
        fixture.language = nil
        XCTAssertNil(try prepared(fixture).language)
    }

    func testABookWithNoNameAtAllTakesTheFilesName() throws {
        var fixture = MOBIFixture()
        fixture.title = nil
        fixture.fullName = ""
        fixture.databaseName = ""
        let url = try writeMOBI(fixture.data(), named: "Harbour Almanac.mobi")
        XCTAssertEqual(try MOBIParser.prepareBook(url: url).title, "Harbour Almanac")
    }

    // MARK: - A plain PalmDOC book

    func testAPalmDOCBookIsOneChapterOfItsLines() throws {
        var fixture = MOBIFixture()
        fixture.type = "TEXt"
        fixture.creator = "REAd"
        fixture.hasMOBIHeader = false
        fixture.databaseName = "Plain_Notes"
        fixture.compression = 2
        fixture.textBytes = Array("First line & more\r\nSecond <line>\rCaf".utf8) + [0xE9]
        let book = try prepared(fixture)
        XCTAssertEqual(book.title, "Plain Notes")
        XCTAssertEqual(book.author, Book.unknownAuthor)
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertEqual(spaced(book.chapters[0].chapter.text), "First line & more Second <line> Café")
    }

    /// An early Mobipocket book: type TEXtREAd, no MOBI header, and a text
    /// that is HTML with an OEB metadata block in its head.
    private func textReadHTMLBook(_ html: String) -> MOBIFixture {
        var fixture = MOBIFixture()
        fixture.type = "TEXt"
        fixture.creator = "REAd"
        fixture.hasMOBIHeader = false
        fixture.databaseName = "Early_Book"
        fixture.textBytes = Array(html.utf8)
        return fixture
    }

    func testAPalmDOCBookWhoseTextIsHTMLIsReadAsHTMLAndItsHeadIsNotRead() throws {
        let fixture = textReadHTMLBook(
            "<HTML><HEAD><metadata><dc-metadata><dc:Title>Hidden Title</dc:Title><dc:Creator>Hidden Maker</dc:Creator>"
                + "</dc-metadata></metadata><GUIDE><REFERENCE type=\"toc\" title=\"Hidden Guide\" filepos=0000000300 /></GUIDE></HEAD>"
                + "<BODY><P>Shown words come first.</P><P>Then more words.</P></BODY></HTML>")
        let chapter = try XCTUnwrap(try prepared(fixture).chapters.first).chapter
        XCTAssertEqual(spaced(chapter.text), "Shown words come first. Then more words.")
        for hidden in ["Hidden", "<", "metadata"] { XCTAssertFalse(chapter.text.contains(hidden), hidden) }
    }

    func testAPalmDOCBookWithAngleBracketsFarInIsStillPlainText() throws {
        var fixture = MOBIFixture()
        fixture.type = "TEXt"
        fixture.creator = "REAd"
        fixture.hasMOBIHeader = false
        // The first 4,096 bytes hold no tag; an <html further on is only words.
        fixture.textBytes = Array((String(repeating: "Plain line of words.\n", count: 250) + "Then <html> is a tag.").utf8)
        let chapter = try XCTUnwrap(try prepared(fixture).chapters.first).chapter
        XCTAssertTrue(chapter.text.contains("<html> is a tag."), String(chapter.text.suffix(60)))
    }

    func testTheHeadOfAnyBookIsNotRead() throws {
        // With a body tag the words start there.
        var withBody = MOBIFixture()
        withBody.html = "<html><head><metadata><dc:Title>Hidden Title</dc:Title></metadata><guide><reference title=\"Hidden\"/></guide></head>"
            + "<body><p>Shown.</p></body></html>"
        XCTAssertEqual(spaced(try XCTUnwrap(try prepared(withBody).chapters.first).chapter.text), "Shown.")
        // With none the words start after the head.
        var noBody = MOBIFixture()
        noBody.html = "<html><head><metadata><dc:Title>Hidden Title</dc:Title></metadata></head><p>Shown too.</p></html>"
        XCTAssertEqual(spaced(try XCTUnwrap(try prepared(noBody).chapters.first).chapter.text), "Shown too.")
    }

    func testATextThatDecompressesPastItsDeclaredLengthIsCutThereAndRead() throws {
        for compression in [1, 2] {
            var fixture = MOBIFixture()
            fixture.html = "<html><body><p>Alpha beta gamma.</p></body></html>"
            fixture.compression = compression
            var bytes = fixture.data()
            // The header declares seven bytes fewer than the records hold: "</html>" is cut off.
            let record0 = MOBIFixture.recordOffsets(of: bytes)[0]
            MOBIFixture.put32(&bytes, record0 + 4, fixture.text.count - 7)
            let book = try MOBIBook(bytes: bytes)
            XCTAssertEqual(book.sections.first?.html, fromBody(String(fixture.html.dropLast(7))), "compression \(compression)")
        }
    }

    // MARK: - Refusals

    private func assertRefused(
        _ fixture: MOBIFixture, _ error: MOBIError, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try opened(fixture), file: file, line: line) {
            XCTAssertEqual($0 as? MOBIError, error, file: file, line: line)
        }
    }

    func testEncryptionAndDRMAreRefusedAsCopyProtection() {
        for encryption in [1, 2] {
            var fixture = MOBIFixture()
            fixture.encryption = encryption
            assertRefused(fixture, .copyProtected)
        }
        for drmOffset in [0, 0x1234, 0xFFFF_FFFE] {
            var fixture = MOBIFixture()
            fixture.drmOffset = drmOffset
            assertRefused(fixture, .copyProtected)
        }
        // A KF8 book that is protected is named for its protection first.
        var both = MOBIFixture()
        both.version = 8
        both.encryption = 2
        assertRefused(both, .copyProtected)
    }

    func testAKF8BookWithoutItsTablesIsDamagedAndAHybridWithoutASecondPartReadsAsMOBI6() throws {
        // A header of version 8 with no skeleton or fragment index is a KF8
        // book that cannot be read; the sentence tells the listener what to do.
        var kf8 = MOBIFixture()
        kf8.version = 8
        XCTAssertThrowsError(try opened(kf8)) {
            guard case .damaged? = $0 as? MOBIError else { return XCTFail("\($0)") }
            XCTAssertTrue($0.localizedDescription.hasSuffix("Get a fresh copy of the book, then import it again."))
        }

        // A hybrid file: version 6, and EXTH 121 naming where the KF8 part
        // begins. Here no record is there, so the book is the MOBI 6 book
        // it opens as, in whichever half is asked for.
        var hybrid = MOBIFixture()
        hybrid.extraEXTH[121] = MOBIFixture.be32(40)
        XCTAssertEqual(try opened(hybrid).sections.count, 1)
        XCTAssertEqual(try MOBIBook(bytes: hybrid.data(), hybrid: .kf8).sections.count, 1)
    }

    func testACompressionNoOneDefinedIsRefused() {
        for compression in [0, 3, 17479] {
            var fixture = MOBIFixture()
            fixture.compression = compression
            assertRefused(fixture, .unsupportedCompression)
        }
        XCTAssertEqual(MOBIError.unsupportedCompression.localizedDescription,
                       "This Kindle book is compressed in a way TextMouth can't read yet.")
    }

    // MARK: - HUFF/CDIC

    /// A book for the small Huffman code of the fixture: capitals with their
    /// lowercase (12-bit codewords), "hello" (an entry that is itself coded),
    /// and plain bytes (8-bit codewords).
    private func huffmanBook() -> MOBIFixture {
        var fixture = MOBIFixture()
        fixture.html = "<html><body>" + (0..<60).map { "<p>Crossing \($0): Aa Bb hello Zz hello world, Quay.</p>" }.joined()
            + "</body></html>"
        fixture.compression = 17480
        return fixture
    }

    func testHuffmanCompressedTextReadsBack() throws {
        for recordSize in [4096, 300, 41] {
            var fixture = huffmanBook()
            fixture.recordSize = recordSize
            XCTAssertEqual(try opened(fixture).sections[0].html, fromBody(fixture.html), "records of \(recordSize)")
        }
        var trailing = huffmanBook()
        trailing.recordSize = 500
        trailing.trailingEntry = Array("TRAILING".utf8)
        XCTAssertEqual(try opened(trailing).sections[0].html, fromBody(trailing.html))
    }

    func testHuffmanTextBeforeAndAfterAContentsReadsAsChapters() throws {
        var fixture = huffmanBook()
        fixture.html = "<html><body><p>First hello part.</p><p>Second Aa part.</p></body></html>"
        fixture.entries = [
            .init(label: "First", offset: try offset(of: "<p>First", in: fixture.html)),
            .init(label: "Second", offset: try offset(of: "<p>Second", in: fixture.html)),
        ]
        let book = try prepared(fixture)
        XCTAssertEqual(book.chapters.map(\.chapter.title), ["First", "Second"])
        XCTAssertEqual(spaced(book.chapters.dropFirst().first?.chapter.text ?? ""), "Second Aa part.")
    }

    func testFilesThatAreNotKindleBooksAreRefused() {
        var wrongType = MOBIFixture().data()
        wrongType.replaceSubrange(60..<68, with: Array("PNRdPPrs".utf8))
        let notBooks: [[UInt8]] = [[], [0x50, 0x4B], Array("not a Kindle book".utf8), [UInt8](repeating: 0, count: 200), wrongType]
        for bytes in notBooks {
            XCTAssertThrowsError(try MOBIBook(bytes: bytes), "\(bytes.count) bytes") {
                XCTAssertEqual($0 as? MOBIError, .notAKindleBook)
            }
        }
    }

    func testABookWithoutTextIsRefusedAsHavingNoTextToRead() {
        var empty = MOBIFixture()
        empty.html = ""
        XCTAssertThrowsError(try opened(empty)) {
            XCTAssertEqual($0.localizedDescription, "This file has no text to read.")
        }
        var blank = MOBIFixture()
        blank.html = "<html><body> <p> </p> </body></html>"
        XCTAssertThrowsError(try prepared(blank)) {
            XCTAssertEqual($0.localizedDescription, "This file has no text to read.")
        }
    }

    func testTheLimitOnAnImportedDocumentsSizeAppliesToTheDeclaredText() {
        var bytes = MOBIFixture().data()
        // Record 0 starts after the table; the text length is at byte 4 of it.
        let record0 = MOBIFixture.recordOffsets(of: bytes)[0]
        MOBIFixture.put32(&bytes, record0 + 4, 0xFFFF_FFFF)
        XCTAssertThrowsError(try MOBIBook(bytes: bytes)) { XCTAssertTrue($0 is DocumentTooLargeError, "\($0)") }
    }

    // MARK: - Soft hyphens

    /// A soft hyphen (U+00AD) a publisher put inside a word is not part of what a listener reads: it hid
    /// the word from search, was a hyphen in braille, and was a pause in speech (measured November 9, 2026; see
    /// `ParserUtilities.removingSoftHyphens`). A MOBI 6 book loses them as a KF8 book does, in every spelling
    /// its markup has for one and in its contents' labels and headings.
    func testSoftHyphensAreLeftOutOfAMOBI6BooksWordsAndItsContentsLabels() throws {
        var fixture = MOBIFixture()
        fixture.html = "<html><body><h1>Chap\u{AD}ter</h1><p>hy\u{AD}phen hy&shy;phen hy&#173;phen hy&#xAD;phen hy&#xad;phen. A \u{AD}stray.</p>"
            + "<p>Second part.</p></body></html>"
        fixture.entries = [
            .init(label: "Chap\u{AD}ter &shy;one", offset: try offset(of: "<h1>", in: fixture.html)),
            .init(label: "Sec\u{AD}ond", offset: try offset(of: "<p>Second", in: fixture.html)),
        ]
        let book = try prepared(fixture)
        let all = book.chapters.map(\.chapter.text).joined(separator: " ")
        XCTAssertFalse(all.unicodeScalars.contains("\u{AD}"), "a soft hyphen was read: \(all.debugDescription)")
        XCTAssertEqual(spaced(all), "Chapter hyphen hyphen hyphen hyphen hyphen. A stray. Second part.")
        let headings = book.chapters.flatMap { $0.chapter.headings.map(\.text) }
        XCTAssertFalse(headings.contains { $0.unicodeScalars.contains("\u{AD}") || $0.contains("&shy;") }, "\(headings)")
        XCTAssertEqual(book.chapters.map(\.chapter.title), ["Chapter one", "Second"], "the labels are the chapters' titles")
    }

    /// A Windows-1252 book spells it as the byte 0xAD, and a plain PalmDOC book holds the same byte in its lines;
    /// the text "&shy;" in a plain book is the author's own text and stays.
    func testSoftHyphensAreLeftOutOfAWindows1252BookAndAPlainPalmDOCBook() throws {
        var windows = MOBIFixture()
        windows.encoding = 1252
        windows.textBytes = Array("<html><body><p>hy".utf8) + [0xAD] + Array("phen.</p></body></html>".utf8)
        XCTAssertEqual(spaced(try XCTUnwrap(try prepared(windows).chapters.first).chapter.text), "hyphen.")

        var plain = MOBIFixture()
        plain.type = "TEXt"
        plain.creator = "REAd"
        plain.hasMOBIHeader = false
        plain.databaseName = "Plain_Notes"
        plain.textBytes = Array("hy".utf8) + [0xAD] + Array("phen and &shy; typed".utf8)
        XCTAssertEqual(spaced(try XCTUnwrap(try prepared(plain).chapters.first).chapter.text), "hyphen and &shy; typed")
    }
}
