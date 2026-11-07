import XCTest
import SwiftSoup
@testable import TextMouth

// MARK: - Footnotes and Endnotes in Rich Text

/// How TextMouth's own reader of rich text reads footnotes and endnotes
/// (`\footnote`, with `\ftnalt` for an endnote): after the main text, in the
/// order the file keeps them, in paragraphs of their own, with no heading,
/// no reference mark, and no page.
final class RTFNotesTests: XCTestCase {

    /// The paragraphs of the HTML the reader makes of `source`, as text.
    private func paragraphs(_ source: String) throws -> [String] {
        try rtfBody(try rtfHTML(source)).select("p, li, h1, h2, h3").array().map { try $0.text() }
    }

    // MARK: Order

    /// Footnotes and endnotes are read after the main text, in the order the
    /// file keeps them, whichever they are.
    func testNotesAreReadAfterTheMainTextInTheFilesOrder() throws {
        let source = #"""
            {\rtf1\ansi First{\super\chftn{\footnote\pard\plain {\super\chftn} Note one.}} para.\par
            Second{\super\chftn{\footnote\ftnalt\pard\plain {\super\chftn} Endnote two.}} para.\par
            Third{\super\chftn{\footnote\pard\plain {\super\chftn} Note three.}} para.\par}
            """#
        XCTAssertEqual(try paragraphs(source), ["First para.", "Second para.", "Third para.", "Note one.", "Endnote two.", "Note three."])
    }

    /// A starred footnote destination (`{\*\footnote`) is a note too.
    func testAStarredFootnoteIsANote() throws {
        let source = #"{\rtf1\ansi Body{\*\footnote\pard\plain Starred note.} text.\par}"#
        XCTAssertEqual(try paragraphs(source), ["Body text.", "Starred note."])
    }

    /// The main text carries on across a note: a reference in the middle of
    /// a sentence breaks neither the sentence nor the emphasis around it.
    func testTheMainParagraphRunsOnAcrossANote() throws {
        let html = try rtfHTML(#"{\rtf1\ansi {\b Bold start{\footnote\pard\plain Aside.} bold end}.\par}"#)
        XCTAssertEqual(try rtfBody(html).select("strong").array().map { try $0.text() }, ["Bold start bold end"])
        XCTAssertEqual(try rtfBody(html).select("p").array().map { try $0.text() }, ["Bold start bold end.", "Aside."])
    }

    // MARK: What a note keeps

    /// A note keeps its paragraphs, and its own emphasis; the reference
    /// mark (`\chftn`) is not read.
    func testANotesParagraphsAndEmphasisAreKept() throws {
        let html = try rtfHTML(#"{\rtf1\ansi Text{\footnote\chftn\pard\plain {\b Bold} and {\i slanted}.\par Second paragraph.\par}.\par}"#)
        let body = try rtfBody(html)
        XCTAssertEqual(try body.select("p").array().map { try $0.text() }, ["Text.", "Bold and slanted.", "Second paragraph."])
        XCTAssertEqual(try body.select("strong").array().map { try $0.text() }, ["Bold"])
        XCTAssertEqual(try body.select("em").array().map { try $0.text() }, ["slanted"])
    }

    /// The emphasis of the reference's own run is not the note's: a note
    /// begins in the plain style, bold or italic only where it says so.
    func testANoteDoesNotInheritTheReferencesEmphasis() throws {
        let html = try rtfHTML(#"{\rtf1\ansi Some plain words here. {\b\i\fs40 Loud{\footnote Quiet note.}} more.\par}"#)
        let body = try rtfBody(html)
        XCTAssertEqual(try body.select("strong").array().map { try $0.text() }, ["Loud"])
        XCTAssertEqual(try body.select("em").array().map { try $0.text() }, ["Loud"])
        XCTAssertEqual(try body.select("p").array().map { try $0.text() }, ["Some plain words here. Loud more.", "Quiet note."])
    }

    /// Hidden text and deleted text inside a note are left out as they are in
    /// the body, and a note whose every word is hidden writes no paragraph.
    func testHiddenAndDeletedTextInANoteIsLeftOut() throws {
        let source = #"{\rtf1\ansi A{\footnote\pard\plain Shown {\v secret }{\deleted removed }words.} B{\footnote\pard\plain {\v All hidden.}\par} C{\footnote\pard\plain {\deleted All deleted.}\par}.\par}"#
        XCTAssertEqual(try paragraphs(source), ["A B C.", "Shown words."])
    }

    /// A note whose reference nobody sees is not read: one whose reference
    /// was deleted, moved away, or hidden, in a run of its own or in the run
    /// around it, even though the note itself begins with `\pard\plain`.
    func testANoteWhoseReferenceIsNotSeenIsLeftOut() throws {
        let note = #"{\footnote\pard\plain Unseen note.}"#
        for reference in [
            #"{\deleted\super\chftn\#(note)}"#, #"{\mvf\super\chftn\#(note)}"#, #"{\v\super\chftn\#(note)}"#,
            #"{\v Hidden words\#(note) more}"#, #"{\deleted gone \#(note)}"#,
        ] {
            let source = #"{\rtf1\ansi Kept\#(reference) text.\par}"#
            XCTAssertEqual(try paragraphs(source), ["Kept text."], reference)
        }
        // A reference that is read brings its note.
        XCTAssertEqual(try paragraphs(#"{\rtf1\ansi Kept{\super\chftn\#(note)} text.\par}"#), ["Kept text.", "Unseen note."])
    }

    /// A note's custom mark (text before its first `\pard`, as short as a mark
    /// is) is not read; text that long enough to be words is, and a note with no
    /// `\pard` at all keeps its text.
    func testACustomMarkIsNotReadButWordsAre() throws {
        // LibreOffice writes the mark of a note whose mark is a dollar sign this way
        XCTAssertEqual(try paragraphs(#"{\rtf1\ansi Text{\*\footnote\ftnalt $\pard\plain Titolo note}.\par}"#), ["Text.", "Titolo note"])
        XCTAssertEqual(try paragraphs(#"{\rtf1\ansi Text{\footnote (1)\pard\plain Note words.}.\par}"#), ["Text.", "Note words."])
        XCTAssertEqual(
            try paragraphs(#"{\rtf1\ansi Text{\footnote Real words before the paragraph. \pard\plain More.}.\par}"#),
            ["Text.", "Real words before the paragraph. More."]
        )
        XCTAssertEqual(try paragraphs(#"{\rtf1\ansi Text{\footnote No paragraph word at all.}.\par}"#), ["Text.", "No paragraph word at all."])
        XCTAssertEqual(try paragraphs(#"{\rtf1\ansi Text{\footnote Short.\par Next.\par}.\par}"#), ["Text.", "Short.", "Next."])
    }

    /// A note's own text is not a heading, by style or by outline level, and
    /// does not make a document that names no headings one that does.
    func testANotesTextIsNeverAHeading() throws {
        let styled = try rtfHTML(#"""
            {\rtf1\ansi{\stylesheet{\s1\outlinelevel0 heading 1;}}
            \pard\s1 Chapter{\footnote\pard\plain\s1\outlinelevel0 Note in heading style.\par}\par
            \pard Body.\par}
            """#)
        XCTAssertEqual(try rtfHeadings(styled), ["1: Chapter"])
        XCTAssertEqual(try rtfBody(styled).select("p").array().map { try $0.text() }, ["Body.", "Note in heading style."])
        // Large bold text in a note is not a heading by size either.
        let bySize = try rtfHTML(#"{\rtf1\ansi\fs24 Plain body.{\footnote\pard\plain\b\fs48 Large bold note.\par}\par}"#)
        XCTAssertEqual(try rtfHeadings(bySize), [])
    }

    /// The list item a note interrupts is still a list item with its number.
    func testAListItemRunsOnAcrossANote() throws {
        let html = try rtfHTML(#"""
            {\rtf1\ansi{\*\listtable{\list\listid10{\listlevel\levelnfc0{\leveltext\'02\'00.;}}}}
            {\*\listoverridetable{\listoverride\listid10\ls1}}
            \pard\ls1\ilvl0{\listtext 1.\tab}Item{\footnote\pard\plain Aside.\par} continues\par
            \pard\ls1\ilvl0{\listtext 2.\tab}Next\par}
            """#)
        XCTAssertEqual(try rtfBody(html).select("ol > li").array().map { try $0.text() }, ["Item continues", "Next"])
        XCTAssertEqual(try rtfBody(html).select("p").array().map { try $0.text() }, ["Aside."])
    }

    /// A note referenced from a table cell keeps the cell's text in its
    /// cell, and is read after the table, not inside it.
    func testANoteInATableCellIsReadAfterTheTable() throws {
        let html = try rtfHTML(#"""
            {\rtf1\ansi\trowd\cellx3000\cellx6000
            \pard\intbl Left{\footnote\pard\plain Cell note.\par}\cell\pard\intbl Right\cell\row
            \pard After table.\par}
            """#)
        let body = try rtfBody(html)
        XCTAssertEqual(try body.select("td").array().map { try $0.text() }, ["Left", "Right"])
        XCTAssertEqual(try body.select("body > p").array().map { try $0.text() }, ["After table.", "Cell note."])
    }

    // MARK: Pages

    /// A note adds no page: a page break in it begins none, and the main
    /// text's pages are the same with the note or without.
    func testANoteAddsNoPage() throws {
        let withNote = try rtfHTML(#"""
            {\rtf1\ansi Page one{\footnote\pard\plain\pagebb Note.\page More note.\par}.\page Page two.\par}
            """#)
        XCTAssertEqual(try rtfPages(withNote), ["1", "2"])
        let without = try rtfHTML(#"{\rtf1\ansi Page one.\page Page two.\par}"#)
        XCTAssertEqual(try rtfPages(without), ["1", "2"])
        // A note's text does not count toward the limit on pages either: a
        // document whose only page breaks are in notes has one page.
        let onlyInNotes = try rtfHTML(#"{\rtf1\ansi Body{\footnote\page\page\page One.\par}.\par}"#)
        XCTAssertEqual(try rtfPages(onlyInNotes), ["1"])
    }

    // MARK: What is not a note

    /// A footnote separator is not a note, and a note in a header, a footer,
    /// or another note is not read.
    func testSeparatorsAndNotesInHeadersAreNotRead() throws {
        let source = #"""
            {\rtf1\ansi{\header Head{\footnote\pard\plain In the header.}}
            {\*\ftnsep\chftnsep}{\*\ftnsepc\chftnsepc}{\*\aftnsep\chftnsep}
            Body{\footnote\pard\plain Outer {\footnote inner} note.}.\par}
            """#
        XCTAssertEqual(try paragraphs(source), ["Body.", "Outer note."])
    }

    /// A note whose reference is in a text box is read, as the reference is
    /// seen: after the main text, in the file's order, where a DOCX reads it.
    /// A note in a note in a box is not read, and a reference in hidden text in
    /// the box brings no note.
    func testANoteWhoseReferenceIsInATextBoxIsRead() throws {
        let source = #"""
            {\rtf1\ansi A{\shp{\*\shpinst{\shptxt Boxed{\super\chftn{\footnote\pard\plain Box note.}}\par}}}B{\super\chftn{\footnote\pard\plain Body note.}}\par}
            """#
        XCTAssertEqual(try paragraphs(source), ["AB", "Boxed", "Box note.", "Body note."])
        let hidden = #"{\rtf1\ansi A{\shp{\*\shpinst{\shptxt Boxed{\v{\footnote\pard\plain Unseen.}}\par}}}B\par}"#
        XCTAssertEqual(try paragraphs(hidden), ["AB", "Boxed"])
        let inner = #"{\rtf1\ansi A{\shp{\*\shpinst{\shptxt Boxed{\footnote\pard\plain Outer {\footnote inner} note.}\par}}}B\par}"#
        XCTAssertEqual(try paragraphs(inner), ["AB", "Boxed", "Outer note."])
        // A note and a box left open at the end of the file are both finished.
        XCTAssertEqual(try paragraphs(#"{\rtf1\ansi A{\shp{\*\shpinst{\shptxt Boxed{\footnote\pard\plain Open"#), ["A", "Boxed", "Open"])
    }

    /// A note's words go through the same escaping as any text.
    func testANotesTextIsEscaped() throws {
        let html = try rtfHTML(#"{\rtf1\ansi Body{\footnote\pard\plain <b>Fish</b> & chips.}.\par}"#)
        XCTAssertEqual(try rtfBody(html).select("b").count, 0)
        XCTAssertTrue(html.contains("&lt;b&gt;Fish&lt;/b&gt; &amp; chips."), html)
    }

    // MARK: Damaged and hostile files

    /// A note that the document ends in the middle of is read as far as it
    /// goes, and the main text before it is whole.
    func testANoteLeftOpenAtTheEndIsRead() throws {
        let html = try rtfHTML(#"{\rtf1\ansi Body{\footnote\pard\plain Unfinished note"#)
        XCTAssertEqual(try rtfBody(html).select("p").array().map { try $0.text() }, ["Body", "Unfinished note"])
    }

    /// A document that is nothing but notes still reads, and has its page 1.
    func testADocumentOfOnlyNotesIsRead() throws {
        let html = try rtfHTML(#"{\rtf1\ansi{\footnote\pard\plain Only a note.}\par}"#)
        XCTAssertEqual(try rtfBody(html).select("p").array().map { try $0.text() }, ["Only a note."])
        XCTAssertEqual(try rtfPages(html), ["1"])
    }

    /// Notes are charged to the same budget as the body: a document of notes
    /// past the limit is refused, as one of body text is.
    func testNotesCountTowardTheSizeLimit() throws {
        let source = "{\\rtf1 Body" + String(repeating: "{\\footnote word}", count: 20_000) + ".\\par}"
        try DocumentByteLimit.$current.withValue(10_000) {
            XCTAssertThrowsError(try RTFDocumentReader.html(from: Data(source.utf8), includesPages: true)) { error in
                XCTAssertEqual(error as? DocumentTooLargeError, DocumentTooLargeError(limit: 10_000))
            }
        }
        // Body and notes together are held to one limit, not one each.
        let half = String(repeating: "word ", count: 600)
        let both = "{\\rtf1 " + half + "\\par{\\footnote " + half + "}}"
        try DocumentByteLimit.$current.withValue(4_000) {
            XCTAssertThrowsError(try RTFDocumentReader.html(from: Data(both.utf8), includesPages: true))
        }
        try DocumentByteLimit.$current.withValue(8_000) {
            XCTAssertNoThrow(try RTFDocumentReader.html(from: Data(both.utf8), includesPages: true))
        }
    }

    /// Groups opened inside a note and never closed, and notes nested a
    /// thousand deep, are read or refused cleanly.
    func testDeeplyNestedNotesAreHandled() throws {
        let nested = "{\\rtf1 A" + String(repeating: "{\\footnote B", count: 1_000) + ".\\par}"
        let html = try rtfHTML(nested)
        XCTAssertEqual(try rtfBody(html).select("p").count, 2)
    }
}
