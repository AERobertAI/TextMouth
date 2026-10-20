# Second review round, part A: the analyzer (E1, E4, E8, and E6 if it fits)

- **Slug:** `braille-review2a`. **Branch:** `braille/review2-analyzer`, made with `git checkout -b braille/review2-analyzer team/braille`.
- Read `Scripts/agents/briefs/2026-10-19/braille/common.md` first, then the reviewer's report, `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/8d971e15-7103-46cf-b45e-5c4d099f2f74/scratchpad/review-braille-e-report.md` (its items 1, 3, 4, and 6 are yours).
- **Files (yours alone):** `TextMouth/Parsers/BraillePageAnalyzer.swift`; `TextMouth/Parsers/BrailleFileReader.swift` (only the PEF's volume attributes, item E4); `TextMouth/Parsers/BrailleBookReader.swift` (only its one call to the analyzer, if E4 needs it); `TextMouthProductionTests/BraillePageAnalyzerTests.swift`, `BrailleFileReaderTests.swift`, `BrailleImportTests.swift` (E4's round trip only). Not `BrailleLayout.swift` or anything of Phase B's: another worker has those.
- **Read first:** `BraillePageAnalyzer.swift` whole (about 800 lines); the reviewer's harnesses in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/8d971e15-7103-46cf-b45e-5c4d099f2f74/scratchpad/review-braille-e/`: `headings/main.swift` (centered headings laid out and read back at each width), `lists/main.swift` (lists as Phase B exports them), `harness/Stubs.swift` (what they compile with), and `files/` (`third-party-titles.brf`, the 233 Pride and Prejudice titles wrapped at 34 cells; `twoline-title.brf`; `block-style.brf`). Reviewer D's fuzz is in `.../scratchpad/review-braille-d/fuzz/main.swift`. Copy all of them into a new folder of your own in the scratchpad and build them there with `xcrun swiftc -O` from your branch's files; run nothing in the reviewers' folders.
- One commit per item, each with its tests.

## E1 (medium): centered headings of several lines are split
M2 made a row at indent 4 or 6 a cell-5 or cell-7 heading before any centered run is tried, and such a row also ends a centered run. So a centered heading with one line at margin 4 or 6 is cut apart: 98 of the 233 titles (42%) read wrong where Phase A read all of them right, and TextMouth's own files at 18 to 21 cells lose 60 to 74 of 400 centered headings per width.
1. **The rule,** at a row that may begin a heading (after a blank row, the top of a page, the start of the book, or another heading):
   1. Collect the centered run there: the consecutive rows of the same page, none blank, each centered (at least 3 blank cells each side, the two sides differing by at most 1), whatever their indent, 4 and 6 included; it must end at a blank row, the page's end, or the book's end.
   2. A run of 2 or more rows is one level-1 heading, unless every row of it has the same indent and that indent is 4 or 6: then it is a wrapped cell-5 or cell-7 heading (level 2 or 3).
   3. Otherwise a row at indent 4 or 6 is a cell-5 or cell-7 heading, with the following rows of its indent (as M2 made it).
   4. Otherwise a run of 1 row is a level-1 heading.
   5. Otherwise the paragraph rules.
2. **Pin** (`BraillePageAnalyzerTests`):
   - Add the reviewer's `third-party-titles.brf` to the samples as `TestData/format-samples/brf/wrapped-titles.brf`, unchanged, with a row in `TestData/format-samples/samples.tsv` in the form of the braille rows there (source: made on this Mac by the October 20 review from the chapter titles of Project Gutenberg #1342, wrapped at 34 cells; licence CC0-1.0, the text public domain; its size and SHA-256; what it holds). Tests read it through `copyOfFormatSample`, as every sample is read. Every one of its 233 titles reads as one level-1 heading, as Phase A read them.
   - M2's own lengths still read as level 2 at cell 5 (31 to 33 cells at 40) and level 3 at cell 7 (27 to 29).
   - `twoline-title.brf`'s title is one level-1 heading (build its rows in the test).
3. **Counts, honestly:** run the reviewer's `headings` harness at 18 to 40 cells and reviewer D's fuzz, before and after, and report every count per width; at 18 to 23 cells, report how many misreads keep the heading's whole text.

## E4 (low): with page numbers off, centered headings are lost in a short book
With no page numbers to measure, the width is the longest row, so a short book's centered heading measures off-centre: the Grade 2 book, exported at 40 by 25 with page numbers off, imports with its title "Grade Two Sample" as a paragraph, from BRF and from PEF.
1. **PEF:** the reader keeps the volume's `cols` attribute (a whole number from 18 to 80, else ignored), and the analyzer uses it as the line width when it is there, before any other rule.
2. **BRF, and a PEF without `cols`:** when no page has a page-number row, the width is the largest of the longest row and the *implied width* of the rows that stand alone (a blank row or a page's edge before and after) with at least 3 blank cells before them, where a row's implied width is twice its left margin plus its length, taken as the most common such value (ties to the larger). Comment why: TextMouth's own export centers its headings, so a short book's title gives its width.
3. **Pin** (`BrailleImportTests`): the Grade 2 book (a heading `Grade Two Sample` and the three sentences) exported at 40 by 25 with page numbers off, as BRF and as PEF (through `BrailleDocumentWriter`), and imported: its headings are exactly `["1: Grade Two Sample"]` (compare the headings, not only the text), in both formats; a 32-cell BRF with page numbers off whose title is centered reads it as level 1.

## E8 (low): L8 merges block-style paragraphs
L8 drops blank rows at a page's top, which joins two paragraphs written in block style (in cell 1, with a blank row between them) when that blank row falls at a page's top (`block-style.brf`).
1. Drop a page's top blank rows only in a book whose paragraphs are BANA's (begin in cell 3): when more of its paragraphs begin at indent 2 than begin at indent 0 after a blank row. In a block-style book a blank row at a page's top stays, and ends the paragraph before it.
2. **Pin:** `block-style.brf`'s paragraphs stay apart; the sample's two pages with `\f\r\n` between them still read as 14 blocks (L8's test).

## E6 (low, if it fits): lists from Phase B read back broken
TextMouth writes a list item's first line in cell 1 and its runovers in cell 3 (a nested item: 3 and 5). Read back, a cell-1 item joins the paragraph before it, each runover starts a new paragraph, and a nested item's runover at a page's top becomes a heading.
1. **The tool:** a layout never divides a word and fills each line greedily, so a row continues the block above only if its first word could not have fitted on the row above (that row's length, one blank cell, and the word's length come to more than the line width). Use this test, with the indents, to tell a runover from a new block: a row at the block's runover indent that passes it is a runover; one that fails it begins a new block.
2. **At least:** no runover row ever becomes a heading (the runover test comes before the cell-5 and cell-7 rules, also at a page's top), and TextMouth's own list items, in cells 1 and 3 and in 3 and 5, read back one paragraph per item. Single-row items in cell 1 come back as one paragraph each only if this test separates them; say what it does with them.
3. **Pin** with the reviewer's `lists` harness cases, as tests; report what still reads wrong.
4. If this does not fit, leave it, and say so: it is a named follow-up.

## Tests to run
`BraillePageAnalyzerTests`, `BrailleFileReaderTests`, `BrailleImportTests`, `BrailleLayoutTests`, `BrailleDocumentWriterTests`, `BrailleExportWriterTests`, and the area `braille`.
