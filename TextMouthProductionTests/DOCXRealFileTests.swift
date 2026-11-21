import XCTest
@testable import TextMouth

// MARK: - Real Word Documents from LibreOffice

/// The DOCX reader on real documents from LibreOffice's test data
/// (`TestData/format-samples/docx/libreoffice-*.docx`, MPL-2.0, listed in
/// `samples.tsv`), each chosen because it holds what the policy every
/// document reader of TextMouth follows speaks of: hidden text (by a run, a
/// character style, and a paragraph style), footnotes and endnotes (and
/// separators that hold words, which are not notes), and text boxes written
/// twice. Each is asked its question by name, so a failure says what changed.
final class DOCXRealFileTests: XCTestCase {

    /// The Markdown the reader makes of the sample named `name` (a file of
    /// `docx/libreoffice-<name>.docx`).
    private func markdown(of name: String, includesPages: Bool = false) throws -> String {
        let copy = try copyOfFormatSample("docx/libreoffice-\(name).docx")
        return try DOCXParser.extractMarkdown(from: copy, includesPages: includesPages)
    }

    // MARK: - Hidden text

    /// A paragraph style and a character style that both hide: the text the
    /// paragraph style hides stays hidden, and a run whose character style
    /// hides too is shown again (the toggle rule of ECMA-376 17.7.3).
    func testAHidingParagraphStyleAndACharacterStyleToggle() throws {
        let result = try markdown(of: "tdf154370")
        XCTAssertFalse(result.contains("Parastyle Hidden chars"), "The hiding paragraph style's own words are hidden")
        XCTAssertTrue(result.contains("CharStyle Hidden"), "A hiding character style in a hiding paragraph shows its run")
        // The other paragraphs, which hide nothing, are read.
        XCTAssertTrue(result.contains("ParaStyle SmallcapsImprint and CharStyle SmallcapsImprint"), result)
    }

    /// Runs hidden directly with w:vanish are not read.
    func testRunsHiddenDirectlyAreNotRead() throws {
        let result = try markdown(of: "tdf138771")
        XCTAssertFalse(result.contains("Internship Participants"), result)
        XCTAssertFalse(result.contains("Mitacs"), result)
    }

    /// A heading whose first run is hidden is the heading of the words that
    /// are not, and the hidden words are heard nowhere.
    func testAHeadingKeepsItsVisibleWords() throws {
        let result = try markdown(of: "tdf32363")
        XCTAssertTrue(
            result.contains("# Replace the heading completely using the referred character style only on the invisible text"),
            result
        )
        XCTAssertFalse(result.contains("Hidden text with the referred character style"), result)
        XCTAssertTrue(result.contains("# Shortening numbered headings"), result)
        // The white space at the edge of a bold run is outside its marks (it was
        // "**with arbitrary text **using", which is read with its asterisks)
        XCTAssertTrue(result.contains("**with arbitrary text** using"), result)
        let heard = try MarkdownDocParser.parseChapter(markdown: result).text
        XCTAssertFalse(heard.contains("*"), "A mark of emphasis is read aloud")
    }

    // MARK: - Notes

    /// A footnote is read after the text that refers to it.
    func testAFootnoteFollowsTheText() throws {
        XCTAssertEqual(try markdown(of: "footnote"), "Foo\n\nbar")
    }

    /// An endnote is read after the text too.
    func testAnEndnoteFollowsTheText() throws {
        let result = try markdown(of: "tdf109310_endnoteStyleForMSO")
        let text = try XCTUnwrap(result.range(of: "Endnote test"))
        let note = try XCTUnwrap(result.range(of: "Only was missing in MS Word"))
        XCTAssertLessThan(text.lowerBound, note.lowerBound)
        XCTAssertTrue(result.contains("Endnote number was not superscript"), result)
    }

    /// Footnotes over two pages are read after all the text, in the order the
    /// part keeps them.
    func testFootnotesAreReadAfterAllTheText() throws {
        let result = try markdown(of: "tdf92470_footnoteRestart")
        let paragraphs = result.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        XCTAssertEqual(Array(paragraphs.suffix(4)), [
            "First footnote", "Second footnote", "First footnote on page 2", "Second footnote on page 2",
        ])
        XCTAssertEqual(Array(paragraphs.prefix(2)), ["This is some text\\.", "This is some more text\\."])
    }

    /// Footnote separators that hold words are not notes: their words are
    /// not read, and the real footnotes (one of two paragraphs) are.
    func testSeparatorsThatHoldWordsAreNotRead() throws {
        let result = try markdown(of: "tdf123262_textFootnoteSeparators")
        XCTAssertFalse(result.contains("Text in footnote separator"), result)
        XCTAssertFalse(result.contains("Text in the continuous separator"), result)
        for note in [
            "Microsoft Office\\.", "Including multiple paragraphs\\.",
            "Ensure that multiple paragraphs work in footnotes…", "LibreOffice",
            "It is just a separator line true\\/false\\.",
        ] {
            XCTAssertTrue(result.contains(note), "\(note) in \(result)")
        }
        let text = try XCTUnwrap(result.range(of: "The footnote separator in Word can be any imaginable text"))
        let firstNote = try XCTUnwrap(result.range(of: "Microsoft Office"))
        XCTAssertLessThan(text.lowerBound, firstNote.lowerBound)
    }

    // MARK: - Text boxes

    /// A text box written in both mc:Choice and mc:Fallback is read once, in
    /// a table cell as well.
    func testATextBoxInAlternateContentIsReadOnce() throws {
        let result = try markdown(of: "tdf119800")
        for word in ["ABCD", "EFGH", "IJKL"] {
            XCTAssertEqual(occurrences(of: word, in: result), 1, "\(word) in \(result)")
        }
        XCTAssertTrue(result.contains("Para1"), result)
        XCTAssertTrue(result.contains("Para3"), result)
    }

    /// Alternate content inside alternate content reads each text box once.
    func testNestedAlternateContentIsReadOnce() throws {
        XCTAssertEqual(try markdown(of: "nestedAlternateContent"), "ABC\n\nPQR")
    }
}
