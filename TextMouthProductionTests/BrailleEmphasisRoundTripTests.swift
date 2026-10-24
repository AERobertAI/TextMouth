import XCTest
@testable import TextMouth

/// Emphasis through braille and back (October 21, 2026): a book whose
/// content.md has italic, bold, and both is exported to BRF through the
/// Export dialog's own writer, then read back as a braille book is imported
/// (`BrailleBookReader.markdown`). The user asked that reading braille keep
/// "all text formatting extractable from the braille", and that exported
/// braille mark italics.
///
/// - **UEB** writes its indicators, and every word of the sample comes back
///   with the Markdown emphasis it went out with, uncontracted and
///   contracted alike. Contracted UEB, though, misreads a contraction just
///   before an emphasis terminator, which is liblouis's own reading, pinned
///   by name with the review's six cases (E1); uncontracted UEB reads them
///   exactly.
/// - **EBAE** writes its signs, and every word comes back with its emphasis
///   too (October 24, 2026): the braille helper reads EBAE's signs itself,
///   which liblouis 3.39.0 misreads, and from review E2 (October 21) until
///   then EBAE wrote none.
/// - **A table of this Mac's that liblouis cannot read back** (Norwegian)
///   writes no emphasis at all (review E2): its signs, read again, changed
///   words of TextMouth's own exports. Its export is the export of the same
///   book plain, byte for byte, and comes back word for word.
final class BrailleEmphasisRoundTripTests: XCTestCase {
    /// The book's content.md: a heading with an italic word, then italic,
    /// bold, and both, on single words and on passages of two to five words,
    /// two of them ending at punctuation, the review's EBAE cases (a stray
    /// sign before the comma read as ">", a passage before a period).
    private let source = """
    # The *Sea* Chapter

    A plain line with an *italic* word, a **bold** word, and ***both*** at once.

    *Three italic words* and then **four bold words here** and ***two both*** done.

    *one two three four five*, six

    *it was not at all*.
    """

    /// The same book with no emphasis: `source` without its delimiters, which
    /// are its only asterisks.
    private var plainSource: String {
        source.replacingOccurrences(of: "*", with: "")
    }

    /// The content.md of `source` as a braille book's reader writes it, every
    /// punctuation character escaped: what a table that writes emphasis and
    /// reads it back brings back, word for word.
    private let emphasizedReadBack = """
    # The *Sea* Chapter

    A plain line with an *italic* word\\, a **bold** word\\, and ***both*** at once\\.

    *Three italic words* and then **four bold words here** and ***two both*** done\\.

    *one two three four five*\\, six

    *it was not at all*\\.
    """

    /// The content.md of `plainSource` as a braille book's reader writes it,
    /// every punctuation character escaped: what a table that writes no
    /// emphasis brings back, word for word.
    private let plainReadBack = """
    # The Sea Chapter

    A plain line with an italic word\\, a bold word\\, and both at once\\.

    Three italic words and then four bold words here and two both done\\.

    one two three four five\\, six

    it was not at all\\.
    """

    /// The table of this Mac's that the Norwegian test uses: uncontracted
    /// Norwegian, whose emphasis indicators liblouis cannot read back. The
    /// helper written before review E2 wrote them, and 98 of 120 random
    /// emphasized sentences came back changed, with ";" or "\56/" in their
    /// words.
    private let norwegian = "mac:no-no-g0.utb"

    // MARK: - Helpers

    /// `markdown` exported to BRF with `table` through the Export dialog's
    /// own writer: the file's bytes, and the content.md a braille book of
    /// that file would have.
    private func roundTrip(_ markdown: String, _ table: String) throws -> (brf: Data, readBack: String) {
        let document = try ExportDocumentWalker.document(fromMarkdown: markdown, book: ExportBookDetails(title: "The Sea"))
        let folder = try makeSandboxDirectory("BrailleEmphasisRoundTrip")
        let url = folder.appendingPathComponent("sea.brf")
        try BRFExportWriter().write(
            document, options: BrailleExportOptions(table: table), to: url, cancellation: BookExportCancellation()
        )
        return (try Data(contentsOf: url), try BrailleBookReader.markdown(of: url, table: table))
    }

    /// The words of `markdown`'s headings and paragraphs, in order, each
    /// with the emphasis the export model reads on its letters: "italic/i",
    /// "bold/b", "both/ib", "plain/" (`ExportDocumentWalker`, the reader of
    /// content.md every writer starts from). Punctuation beside a word is
    /// part of the word, and its emphasis does not count, as it is not the
    /// word's.
    private func words(_ markdown: String) throws -> [String] {
        let document = try ExportDocumentWalker.document(fromMarkdown: markdown, book: ExportBookDetails(title: ""))
        var words: [String] = []
        for block in document.blocks {
            let runs: [ExportRun]
            switch block {
            case let .heading(heading): runs = heading.runs
            case let .paragraph(paragraphRuns): runs = paragraphRuns
            default: continue
            }
            var word = ""
            var flags = Set<String>()
            // Each character with the run it is in, and a space at the end
            // so that the last word is kept too.
            let characters: [(Character, ExportRun)] = runs.flatMap { run in run.text.map { ($0, run) } }
            for (character, style) in characters + [(Character(" "), ExportRun(""))] {
                if character.isWhitespace {
                    if !word.isEmpty { words.append(word + "/" + flags.sorted().joined()) }
                    word = ""
                    flags = []
                } else {
                    word.append(character)
                    guard character.isLetter || character.isNumber else { continue }
                    if style.isEmphasis { flags.insert("i") }
                    if style.isStrong { flags.insert("b") }
                }
            }
        }
        return words
    }

    /// Asserts that `table` writes no emphasis and loses no word: the BRF of
    /// `source` is the BRF of `plainSource`, byte for byte, so it holds no
    /// emphasis sign, and it reads back as `plainReadBack`.
    private func assertWritesNoEmphasis(_ table: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let emphasized = try roundTrip(source, table)
        let plain = try roundTrip(plainSource, table)
        XCTAssertFalse(emphasized.brf.isEmpty, table, file: file, line: line)
        XCTAssertEqual(emphasized.brf, plain.brf, "\(table): the BRF holds emphasis signs", file: file, line: line)
        XCTAssertEqual(emphasized.readBack, plainReadBack, table, file: file, line: line)
        XCTAssertEqual(try words(emphasized.readBack), try words(plainSource), table, file: file, line: line)
    }

    // MARK: - UEB

    /// UEB, uncontracted and contracted: every word of the sample comes back
    /// with its emphasis, the heading's italic word and the passages that end
    /// at punctuation too, and content.md is exactly the source in the
    /// reader's own form, its punctuation escaped.
    func testUEBBringsEveryWordsEmphasisBack() throws {
        for table in ["en-ueb-g1.ctb", "en-ueb-g2.ctb"] {
            let back = try roundTrip(source, table).readBack
            XCTAssertEqual(try words(back), try words(source), table)
            XCTAssertEqual(back, emphasizedReadBack, table)
        }
    }

    // MARK: - Contracted UEB: liblouis's Own Misreadings

    /// The review's six sentences of contracted UEB (E1, October 21, 2026),
    /// under a plain heading of their own, so the export adds no title
    /// heading. Each ends its emphasis just after a word UEB contracts, so
    /// liblouis writes the contraction with the emphasis terminator after
    /// it, which is valid UEB.
    private let contractionCases = """
    # The Sea Chapter

    for the *people*'s sake

    the *Knowledge*'s keeper

    a *can*'t

    gave them *all of his* things

    *that they were* here

    *It was enough*
    """

    /// Uncontracted UEB brings the six sentences back exactly. Contracted
    /// UEB, the default table, brings them back with liblouis 3.39.0's own
    /// misreadings, pinned here by name: reading back, liblouis takes a
    /// whole-word contraction followed by the terminator for the letter or
    /// part-word sign its cell also is, since the terminator is no space:
    /// - "people" (⠏) as "p", "Knowledge" (⠠⠅) as "K", and "can" (⠉) as "c",
    ///   before the apostrophe the terminator stands before;
    /// - "his" (⠦) as a double quote, "were" (⠶) as a prime (U+2032), and
    ///   "enough" (⠢) as "en", at the end of a passage.
    ///
    /// Without emphasis the same sentences read back exactly, so the
    /// terminator alone causes them. The export cannot avoid them cheaply:
    /// it would have to write such a word uncontracted, or move the
    /// terminator onto letters that were not emphasized, both wrong braille
    /// for the file's reader. Their cure is a reading pass that tells
    /// liblouis where the terminators were (a follow-up). Random emphasized
    /// sentences change in 1 or 2 of 400 (the review), and in 2 of 120 of a
    /// sample dense with contractions.
    func testContractedUEBMisreadsAContractionBeforeAnEmphasisEnd() throws {
        XCTAssertEqual(try roundTrip(contractionCases, "en-ueb-g1.ctb").readBack, #"""
        # The Sea Chapter

        for the *people*\'s sake

        the *Knowledge*\'s keeper

        a *can*\'t

        gave them *all of his* things

        *that they were* here

        *It was enough*
        """#)
        XCTAssertEqual(try roundTrip(contractionCases, "en-ueb-g2.ctb").readBack, #"""
        # The Sea Chapter

        for the *p*\'s sake

        the *K*\'s keeper

        a *c*\'t

        gave them *all of* \" things

        *that they* \#u{2032} here

        *It was en*
        """#)
        // Without emphasis, contracted UEB reads the same sentences exactly.
        XCTAssertEqual(try roundTrip(contractionCases.replacingOccurrences(of: "*", with: ""), "en-ueb-g2.ctb").readBack, #"""
        # The Sea Chapter

        for the people\'s sake

        the Knowledge\'s keeper

        a can\'t

        gave them all of his things

        that they were here

        It was enough
        """#)
    }

    // MARK: - EBAE

    /// EBAE, uncontracted and contracted, writes its signs (the export
    /// differs from the plain book's), and every word of the sample comes
    /// back with its emphasis, the bold italic words and the passages that
    /// end at punctuation too: content.md is exactly UEB's. liblouis 3.39.0
    /// alone read the italic sign before a word as a period (".italic"), and
    /// the stray sign it writes before the comma after a passage as ">"
    /// (".five> six"); the helper now reads EBAE's signs itself.
    func testEBAEBringsEveryWordsEmphasisBack() throws {
        for table in ["en-us-g1.ctb", "en_US.tbl"] {
            let emphasized = try roundTrip(source, table)
            XCTAssertNotEqual(emphasized.brf, try roundTrip(plainSource, table).brf, "\(table): the BRF holds no emphasis sign")
            XCTAssertEqual(try words(emphasized.readBack), try words(source), table)
            XCTAssertEqual(emphasized.readBack, emphasizedReadBack, table)
        }
    }

    // MARK: - Tables liblouis Cannot Read Back

    /// One of this Mac's tables liblouis cannot read back, uncontracted
    /// Norwegian, writes no emphasis either, and every word comes back. Skips
    /// on a Mac that does not offer it.
    func testAMacTableLiblouisCannotReadBackWritesNoEmphasis() throws {
        try XCTSkipIf(BrailleTableCatalog.table(withID: norwegian) == nil,
                      "This Mac does not offer its uncontracted Norwegian table (\(BrailleTableCatalog.macTablesFolder.path))")
        try assertWritesNoEmphasis(norwegian)
    }
}
