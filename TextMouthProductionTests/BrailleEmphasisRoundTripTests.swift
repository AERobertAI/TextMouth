import XCTest
@testable import TextMouth

/// Emphasis through braille and back (October 21, 2026): a book whose
/// content.md has italic, bold, and both is exported to BRF with each of the
/// four bundled tables through the Export dialog's own writer, then read
/// back as a braille book is imported (`BrailleBookReader.markdown`). The
/// user asked that reading braille keep "all text formatting extractable
/// from the braille", and that exported braille mark italics.
///
/// In UEB, uncontracted and contracted, every word comes back with the
/// Markdown emphasis it went out with, and the Markdown itself is the same
/// but for escaping. In EBAE the export writes EBAE's own signs, but
/// liblouis 3.39.0 cannot read them back, so the words come back plain, and
/// liblouis's own readings of EBAE's signs, pinned here by name, change the
/// text: the italic sign before "italic" is read as a period.
final class BrailleEmphasisRoundTripTests: XCTestCase {
    /// The book's content.md: a heading with an italic word, then italic,
    /// bold, and both, on single words and on passages of two to four words.
    private let source = """
    # The *Sea* Chapter

    A plain line with an *italic* word, a **bold** word, and ***both*** at once.

    *Three italic words* and then **four bold words here** and ***two both*** done.
    """

    // MARK: - Helpers

    /// `source` exported to BRF with `table`, then read back as an import
    /// reads it: the content.md a braille book of that file would have.
    private func roundTrip(_ table: String) throws -> String {
        let document = try ExportDocumentWalker.document(fromMarkdown: source, book: ExportBookDetails(title: "The Sea"))
        let folder = try makeSandboxDirectory("BrailleEmphasisRoundTrip")
        let url = folder.appendingPathComponent("sea.brf")
        try BRFExportWriter().write(
            document, options: BrailleExportOptions(table: table), to: url, cancellation: BookExportCancellation()
        )
        return try BrailleBookReader.markdown(of: url, table: table)
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

    // MARK: - UEB

    /// UEB, uncontracted and contracted: every word comes back with its
    /// emphasis, the heading's italic word too, and content.md is exactly
    /// the source in the reader's own form, its punctuation escaped.
    func testUEBBringsEveryWordsEmphasisBack() throws {
        let expected = """
        # The *Sea* Chapter

        A plain line with an *italic* word\\, a **bold** word\\, and ***both*** at once\\.

        *Three italic words* and then **four bold words here** and ***two both*** done\\.
        """
        for table in ["en-ueb-g1.ctb", "en-ueb-g2.ctb"] {
            let back = try roundTrip(table)
            XCTAssertEqual(try words(back), try words(source), table)
            XCTAssertEqual(back, expected, table)
        }
    }

    // MARK: - EBAE

    /// EBAE, uncontracted and contracted: the BRF holds EBAE's own signs for
    /// the emphasis (`BrailleHelperProtocolTests` pins them), but liblouis
    /// 3.39.0 reads none back, so no word comes back emphasized. Its own
    /// readings of the signs, by name, the same in both tables:
    /// - the italic sign (dots 4-6) before "italic", in both paragraphs, is
    ///   read as a period, ".italic";
    /// - the same sign before "Sea" and "Three" (where the capital sign
    ///   follows it) and before "words" is read as nothing;
    /// - the bold sign (dots 4-5-6, 4-6), and the signs of a bold passage
    ///   and of words both bold and italic, are read as nothing.
    func testEBAEBringsTheWordsBackPlainWithLiblouisOwnPeriods() throws {
        let expected = """
        # The Sea Chapter

        A plain line with an \\.italic word\\, a bold word\\, and both at once\\.

        Three \\.italic words and then four bold words here and two both done\\.
        """
        for table in ["en-us-g1.ctb", "en_US.tbl"] {
            let back = try roundTrip(table)
            XCTAssertFalse(try words(back).contains { !$0.hasSuffix("/") }, "\(table): \(back)")
            XCTAssertEqual(back, expected, table)
        }
    }
}
