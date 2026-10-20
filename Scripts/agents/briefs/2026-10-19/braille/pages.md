# Task `pages`: read a braille book's structure from its pages (FMT20)

- **Slug:** `braille-pages`. **Branch:** `braille/pages`, made with `git checkout -b braille/pages team/braille`.
- Read `Scripts/agents/briefs/2026-10-19/braille/common.md` first.
- **Files (yours alone):** new `TextMouth/Parsers/BraillePageAnalyzer.swift`; new `TextMouthProductionTests/BraillePageAnalyzerTests.swift`; the regenerated `project.pbxproj`.
- **Read first:** `TextMouth/Parsers/BrailleCells.swift` (all); the prototype's reader, `Scripts/agents/briefs/2026-10-19/braille-reference/ueb.py` lines 177 to 262 (how its layout writes pages: what you read back) and `verify_samples.py` lines 93 to 145 (how it reads the sample's paragraphs back).
- **Not yours:** reading files into pages is task `reader` (in flight beside you: do not wait for it, and do not use its types); turning braille into print is liblouis's. Touch nothing else.

## What to build
The analyzer takes pages of rows of Unicode braille, as a BRF or PEF holds them, and finds the book's headings and paragraphs, following BANA's Braille Formats (2016) as the prototype writes them, and each page's numbers. It is pure Swift: no file, no process.

1. **Types**, in `BraillePageAnalyzer.swift`:
   ```swift
   /// What a braille book's pages hold (FMT20): its blocks, in braille, and each page's numbers.
   struct BrailleStructure: Equatable, Sendable {
       /// The headings and paragraphs, in order; each text is braille
       /// cells with one blank cell (U+2800) between words.
       var blocks: [BrailleBlock]
       /// One entry for each page of the file, in order.
       var pages: [BraillePageNumbers]
   }

   /// The numbers a braille page carries, kept for navigation by braille
   /// or print page, which is a follow-up; each is braille cells, such as "⠼⠁".
   struct BraillePageNumbers: Equatable, Sendable {
       var braillePageNumber: String?
       var printPageNumber: String?
       /// The number of each print page change line on the page, in order.
       var printPageChanges: [String] = []
       /// The index in `blocks` of the first block with text on this page
       /// (a paragraph continued from the page before counts); for a page
       /// with no text, the index of the next block that has some.
       var firstBlockIndex: Int
   }
   ```
2. **`BraillePageAnalyzer.structure(of pages: [[String]], formatted: Bool) -> BrailleStructure`.** `formatted` is false for an unformatted BRL: then every row that is not blank becomes a paragraph (its blank cells trimmed at both ends and runs of blank cells inside made one), there are no headings, and `pages` has one entry with no numbers. The rest of this list is for formatted pages.
3. **Rows.** A row's trailing blank cells are not part of it. A row is blank when nothing is left. Its *indent* is the number of blank cells before its first cell. The *line width* is the longest row of the whole file (after trailing blanks are dropped), held to 18...80 (a shorter result counts as 18, a longer as 80). Measure it before anything is taken out.
4. **A page number** is one *number word*: a run of at most 8 cells with no blank cell, holding the number sign ⠼ (U+283C) directly followed by at least one of the ten digit cells ⠁⠃⠉⠙⠑⠋⠛⠓⠊⠚ (a to j). It may have letters before or after (`⠏⠼⠁`, p1, is a preliminary page; `⠁⠼⠁`, a1, a continuation page). For a row to carry one at its right, the word must be the row's last word, end exactly at the line width, and have at least 3 blank cells before it (or be alone on the row).
   1. **The braille page number:** the last row of the page that is not blank, when it carries a number word at its right, as above. The word is the page's `braillePageNumber`, and is taken out of the row; what is left of the row (text before the 3 or more blanks) stays as text.
   2. **The print page number:** the page's first row that is not blank, when it carries a number word at its right, and the row is not the one item 4.1 took its number from. The word is the page's `printPageNumber`, and is taken out of the row the same way.
   3. **A print page change line:** a row that, with its leading blanks dropped, is at least 3 cells of ⠤ (U+2824, dots 3-6), then directly a number word, and nothing else. The whole row is taken out, and its number word added to the page's `printPageChanges`. It is not a blank row: it neither ends a paragraph nor separates anything (it must never be read mid-sentence, and the paragraph it interrupts goes on).
5. **Blocks**, read row by row through all the pages in order, after item 4's rows and words are taken out:
   1. A blank row ends the current block.
   2. **A centered heading** (level 1): a row with at least 3 blank cells on each side (left: its indent; right: the line width less its indent and length), the two sides differing by at most 1, that has a blank row (or the top of its page, or the start of the book) before it, and a blank row (or the end of its page, or the end of the book) after the run of such rows it belongs to. Consecutive centered rows form one heading, their texts joined by one blank cell. Check this before items 5.3 to 5.5.
   3. **A cell-5 heading** (level 2) or **cell-7 heading** (level 3): a row of indent 4 or 6, not centered, that comes after a blank row, the top of a page, the start of the book, or another heading. Following rows of the same indent belong to it. It ends at a blank row or a row of another indent.
   4. **A paragraph** begins at a row of indent 2 (cell 3), and at a row of any other indent that items 5.2 and 5.3 did not take. Its runover rows are the rows of indent 0 (cell 1) that follow it.
   5. A row of indent 0 with no current paragraph (the start of the book, after a heading, or after a blank row) begins a paragraph. So the Grade 2 sample's three lines, each starting in cell 1 with no blank row between them, are one paragraph.
   6. **A paragraph continues across a page break:** the end of a page does not end a block; only a blank row, a heading, or a new paragraph's first row does. So the sample's 7th paragraph, which goes on in cell 1 at the top of page 2, is one paragraph.
   7. A block's text is its rows' cells, leading and trailing blank cells dropped and runs of blank cells inside made one, joined by one blank cell.
6. **Page entries:** one `BraillePageNumbers` for each page given, including blank pages, with `firstBlockIndex` as its comment says.
7. Everything is linear in the input: a 64 MB file of rows must not take quadratic time (no repeated `String` concatenation in a loop over the whole book; collect scalars or rows in arrays and join once).

## Tests (`BraillePageAnalyzerTests`)
Build pages in the tests from strings. For the samples, a private helper reads a sample's bytes, splits pages at form feeds and rows at CR LF, and converts each byte with `BrailleCells.cell(forASCII:)` (three lines; the real reader is another task's).
1. **The BRF sample** gives 14 blocks: `.heading(level: 1, …)` for the title and for "Chapter I", then 12 paragraphs whose texts are exactly the BRL sample's lines 3 to 14, each converted to cells (blank cells for spaces). Its pages: `braillePageNumber` `⠼⠁` and `⠼⠃`, no print page numbers or changes, and `firstBlockIndex` 0 and 8 (the 7th paragraph is block 8 and continues on page 2).
2. **The Grade 2 sample:** one paragraph, its three lines joined by blank cells; page number `⠼⠁`.
3. **Page numbers:** a last row with text, 3 blanks, and a number word at the right keeps its text; with only 2 blanks before the word, nothing is taken; a word that does not end at the line width is not taken; `⠏⠼⠁` and `⠁⠼⠁` are taken; a word of 9 cells is not; a page whose last row is text is left whole.
4. **Print page number** at the right of a page's first row is taken out, and the row's text (a paragraph's first line) kept.
5. **Print page change line** `⠤⠤⠤⠤⠤⠤⠼⠉⠃` between two runover rows of a paragraph: one paragraph whose text has no ⠤ cells, and `printPageChanges == ["⠼⠉⠃"]`.
6. **Headings:** a cell-5 heading after a blank row is level 2, a cell-7 level 3, each followed by a paragraph at cell 3; a cell-5 row in the middle of a paragraph's runovers (no blank row before) is a paragraph, not a heading; two consecutive centered rows between blank rows are one level-1 heading; a centered row with text right after it (no blank row) is a paragraph.
7. **Width:** a file whose longest row is 30 cells centers against 30; one whose rows are all 10 cells is measured as 18; 90 as 80.
8. **Unformatted:** three rows with leading and doubled blanks give three paragraphs, trimmed and single-spaced; a blank row gives nothing.
9. **Empty:** no pages, and pages of blank rows, give no blocks; each page still has its entry.

Run `BraillePageAnalyzerTests` and `BrailleCellsTests`.
