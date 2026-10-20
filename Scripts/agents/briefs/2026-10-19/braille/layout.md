# Task `layout`: lay braille out in pages, and write BRF and PEF (FMT22, Phase A)

- **Slug:** `braille-layout`. **Branch:** `braille/layout`, made with `git checkout -b braille/layout team/braille`.
- Read `Scripts/agents/briefs/2026-10-19/braille/common.md` first.
- **Files (yours alone):** new `TextMouth/Services/BrailleLayout.swift` and `TextMouth/Services/BrailleFileWriter.swift`; new `TextMouthProductionTests/BrailleLayoutTests.swift` and `BrailleFileWriterTests.swift`; the regenerated `project.pbxproj`.
- **Read first:** `TextMouth/Parsers/BrailleCells.swift` (all); the prototype, `Scripts/agents/briefs/2026-10-19/braille-reference/ueb.py` lines 177 to 313 (its layout and its two writers, which made the samples you must reproduce).
- **Not yours:** translation (print to braille is liblouis's, through another task's `BrailleTranslator`), the reading side, and every `BookExport*` file and `TextMouth/Views/Export/` (team `export` owns them until it merges). Touch nothing else.
- Two commits: the layout with its tests, then the writers with theirs.

## Commit 1: the layout (`BrailleLayout.swift`)
Pure Swift, no file or process access. Its input is braille: each `BrailleBlock`'s text is Unicode cells with one blank cell (U+2800) between words.

1. **The page format:**
   ```swift
   /// How braille pages are laid out (FMT22): the export's page options.
   struct BraillePageFormat: Equatable, Sendable {
       /// Cells per line, 18 to 80 (BANA's 40 by default).
       var cellsPerLine = 40
       /// Lines per page, 4 to 50 (BANA's 25 by default).
       var linesPerPage = 25
       /// Whether each page's last line carries its braille page number.
       var numbersPages = true
       static let cellsPerLineRange = 18...80
       static let linesPerPageRange = 4...50
       /// This format with each number held to its range.
       var clamped: BraillePageFormat { ... }
   }
   ```
   The layout always uses `format.clamped`.
2. **`BrailleLayout.pages(of blocks: [BrailleBlock], format: BraillePageFormat) -> [[String]]`** returns pages, each exactly `linesPerPage` rows; a row is its cells with no trailing blank cells ("" for a blank row). The rules, from BANA's Braille Formats (2016), as the prototype does them:
   1. **Lines for text:** with page numbers on, the last line of every page is the page-number line and text uses the lines above it; with them off, every line holds text.
   2. **Words are never divided** at a line's end: a line takes as many whole words as fit, with one blank cell between them. A word longer than a whole line (from its indent) is the one exception: it fills the line to its last cell, and the rest of it goes on at the next line's indent, as many lines as it needs.
   3. **Paragraphs:** the first line starts in cell 3 (2 blank cells), runover lines in cell 1.
   4. **List items** at depth d (1 or more): the first line starts in cell 2d−1, runovers in cell 2d+1 (1-3, 3-5, 5-7, …), with the depth held so the runover indent is at most a third of the line.
   5. **Headings of levels 1 and 2 are centered:** each line of the heading has (cellsPerLine − its length) / 2 blank cells before it, rounded down (the extra cell goes on the right), and at least 3 blank cells on each side, so a heading line holds at most cellsPerLine − 6 cells; a longer heading is wrapped as item 2.2 wraps, at that shorter width, and each line centered. A blank line comes before (except at the top of a page) and after it.
   6. **A level-3 heading starts in cell 5, levels 4 to 6 in cell 7**, their runover lines at the same cell, with a blank line before (except at the top of a page) and none after.
   7. **Blank lines:** never two in a row, never one at the top of a page (it is dropped there), and none between paragraphs. A heading's blank line before is not added when the line above is already blank.
   8. **A heading is never the last text on its page** (BANA 4.3.9): when a heading's lines, its blank line after (for levels 1 and 2), and one line of the next block do not all fit in the lines left on the page, the page ends there (its remaining text lines blank) and the heading begins the next page. A heading that is the book's last block is never moved for this.
   9. **The braille page number** (with page numbers on) is the number sign ⠼ then the page's number in the digit cells (1 ⠁, 2 ⠃, 3 ⠉, 4 ⠙, 5 ⠑, 6 ⠋, 7 ⠛, 8 ⠓, 9 ⠊, 0 ⠚; so page 12 is ⠼⠁⠃), at the right margin of the page's last line, with blank cells before it (always at least 3, since lines are at least 18 cells). Pages are numbered from 1.
   10. Every page is filled to `linesPerPage` rows with blank rows. No blocks give no pages.
   11. A block whose text is empty or only blank cells is skipped.
   12. Linear time: build rows as arrays of scalars and join each once.

## Commit 2: the writers (`BrailleFileWriter.swift`)
1. **Line ends:** `enum BrailleLineEnd: Equatable, Sendable { case crlf, lf }`, CR LF by default (the user's choice, October 17).
2. **`BrailleFileWriter.brf(pages: [[String]], lineEnd: BrailleLineEnd) -> Data`:** each row converted cell by cell with `BrailleCells.ascii(for:)`, each row followed by its line end (the last row of a page too), and one form feed (0x0C) between pages, none after the last. A cell with dot 7 or 8 cannot be written in braille ASCII: it is written as its six-dot part (its value with dots 7 and 8 cleared), which a comment and a test say. ASCII only: the result decodes as ASCII.
3. **`BrailleFileWriter.pef(pages: [[String]], metadata: PEFMetadata, format: BraillePageFormat) -> Data`**, PEF 2008-1, byte for byte the prototype's `write_pef` form (lines 284 to 313): the XML declaration; `<pef version="2008-1" xmlns="http://www.daisy.org/ns/2008/pef">`; `head` with `meta xmlns:dc="http://purl.org/dc/elements/1.1/"` holding `dc:format` (`application/x-pef+xml`), `dc:identifier`, `dc:title`, `dc:creator`, `dc:date`, `dc:language`, in that order; `body` > one `volume cols="<cellsPerLine>" rows="<linesPerPage>" rowgap="0" duplex="false"` > one `section` > a `page` per page > a `row` per row, a blank row as `<row/>`; tabs for indentation and LF line ends exactly as the prototype writes them, and a final LF.
   ```swift
   /// What a PEF says about its book (FMT22).
   struct PEFMetadata: Equatable, Sendable {
       var title: String
       var author: String
       /// A BCP 47 language tag, such as "en".
       var language: String
       /// A unique identifier, such as "urn:uuid:" and a UUID.
       var identifier: String
       /// The day it was made, written yyyy-mm-dd.
       var date: String
   }
   ```
   Every text in it is XML-escaped (`&`, `<`, `>`, and in attributes `"`); write one small private escaping function. A `dc:creator` with an empty author is left out.

## Tests
- `BrailleLayoutTests`:
  1. **The samples:** the blocks `.heading(level: 1, title)`, `.heading(level: 2, "Chapter I")`, then the 12 paragraphs, all taken from the BRL sample's 14 lines converted with `BrailleCells.cell(forASCII:)`, laid out at 40 by 25 with page numbers, give exactly the BRF sample's two pages, row for row (read the BRF in the test by splitting at the form feed and CR LF and converting each byte; three lines).
  2. Word wrapping never divides a word; a word longer than a line is cut at the line's end and goes on at the next line's indent; one exactly a line long fits.
  3. Margins: paragraphs 3-1; list items 1-3 and, at depth 2, 3-5; level-3 headings in cell 5 and level-5 in cell 7, with a blank line before and none after.
  4. Centering of an even and an odd length; a heading too long for one centered line is wrapped and each line centered with at least 3 blank cells each side.
  5. Blank lines: none at the top of a page, never two in a row, none between paragraphs.
  6. A heading that would be the last text on a page moves to the next page, with its page's remaining lines blank.
  7. Page numbers: ⠼⠁ on page 1 and ⠼⠁⠃ on page 12, right-aligned on the last line; with page numbers off the last line holds text and no number appears.
  8. Formats: 18 by 4 works; 10 and 100 cells are clamped to 18 and 80, 2 and 99 lines to 4 and 50.
  9. No blocks give no pages; a blank block is skipped.
- `BrailleFileWriterTests`:
  1. `brf` of the BRF sample's own pages (read as in the layout test) gives the sample's bytes exactly, and with `.lf` the same with LF line ends.
  2. `pef` of those pages with the sample's metadata (`urn:uuid:5b0a3f6e-6c1d-4a35-9d57-0e2f6a1b7c10`, `Pride and Prejudice, Chapter I (Grade 1 UEB sample)`, `Jane Austen`, `2026-10-17`, `en`) at 40 by 25 gives the PEF sample's bytes exactly.
  3. A title holding `&`, `<`, and `>` is escaped; an empty author leaves out `dc:creator`.
  4. A cell with dot 7 (U+2841) is written in BRF as `A` (its six-dot part, ⠁); a PEF keeps it.
  5. Form feeds: one between two pages, none after the last; one page gives none.

Run `BrailleLayoutTests`, `BrailleFileWriterTests`, and `BrailleCellsTests`.
