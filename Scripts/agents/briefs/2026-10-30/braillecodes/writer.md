# Task `writer`: BRF export in a chosen braille file code, and its pop-up in the Export dialog

Team `braillecodes`, lead `braillecodes-lead`. Your slug is `braillecodes-writer`, your branch `braillecodes/writer`, made from `team/braillecodes`. Read `Scripts/agents/briefs/2026-10-30/teams-common.md`, "The worker's part", first, and follow it.

## Background

`TextMouth/Parsers/BrailleFileCode.swift` is the catalog of braille file codes (read it whole; it is short): `BrailleFileCode.all` is North American Braille ASCII (`.northAmerican`, the default), Eurobraille (`.eurobraille`), and Unicode braille patterns (`.unicode`), each with a `name` and a `kind` (`.sevenBit(SevenBitBrailleTable)`, whose `byte(forCell:)` gives the byte for a six-dot cell, or `.unicodePatterns`). The reader already reads all three (`BrailleFileReader.read(_:as:code:)` and `pages(fromText:kind:code:)`). The design is `BRAILLE-CODES-RESEARCH-2026-10-25.md`, sections 8.3 (the Export dialog's paragraph) and 8.7 (the writer's paragraph).

## What to change

1. **`BrailleFileWriter.brf(pages:lineEnd:)`** (`TextMouth/Services/BrailleFileWriter.swift`, lines 67-100) takes `code: BrailleFileCode = .northAmerican` as its last parameter. The cells of each row are found exactly as now (`sixDotCells(of:)`: the escape backslash U+2873 as ⠳, any other eight-dot cell refused with `EightDotCell`, a scalar that is no pattern as a blank cell, trailing blank cells left out); only how each cell is written depends on the code:
   - a seven-bit code writes `table.byte(forCell:)` (the blank cell's byte is the space in both tables; keep a fallback to the space, never a force unwrap);
   - Unicode braille patterns write each cell as its pattern's UTF-8, the blank cell as U+2800 (never the ASCII space), with no byte order mark.
   Line ends and form feeds are the same bytes in every code. Rename `asciiBytes(of:)` to `bytes(of:in:)` (or similar) and keep it the one place that writes a row. Update the doc comments: "The result is ASCII only" becomes true of the seven-bit codes, and Unicode braille patterns write UTF-8; the PEF writer does not change (a PEF is always Unicode braille patterns).
2. **`BrailleExportOptions`** (`TextMouth/Services/BrailleDocumentWriter.swift`, lines 9-45): `var fileCode = BrailleFileCode.northAmerican`, documented as the braille file characters a BRF writes (a PEF writes Unicode braille patterns whatever it is). `standard()` keeps it North American: a later task presets it from the Braille setting. `BrailleDocumentWriter.brf(of:options:workingIn:)` (line 226) passes `code: options.fileCode`.
3. **The pop-up** in `BrailleExportOptionsView` (`TextMouth/Views/Export/BrailleExportOptionsView.swift`, lines 358-457), shown only for a BRF (`choosesLineEnds`), placed **after** the Line ends pop-up so every existing control keeps its place in the reading order: a `Picker` over `BrailleFileCode.all`, each listed by its `name`, bound to `$options.fileCode`, drawn as `lineEndPicker` is (`.pickerStyle(.menu)`, `.fixedSize()`, `.accessibilityLabel`, `.accessibilityHint`). Its value is the selected code's name, so VoiceOver says "North American Braille ASCII, Braille file characters, pop-up button".
4. **Wording**, each constant pinned by a test:
   - `BrailleSettingsWording.fileCodeLabel = "Braille file characters"`, added to `BrailleSettingsWording` (`TextMouth/Views/Settings/BrailleSettingsView.swift`, lines 7-32, after `contractionHint`), documented as the label of the pop-up that chooses how a BRF or BRL file writes each cell as a character, shared by the Braille tab and Export's braille options as the other labels are. (Sentence case, as "Braille code" and "Line ends" beside it; Book Information's row will be "Braille File Characters", title case, as its "Braille Code" row.) Touch nothing else in that file: a later task adds the Braille tab's pop-up.
   - `BrailleExportWording.fileCodeHint = "How the BRF file writes each braille cell. Most braille displays and embossers read North American Braille ASCII, and those set up for German read Eurobraille. To share braille with a reader elsewhere, export a PEF."` (research 8.9: Eurobraille makes a file only German-style embossers and software read as written; a PEF needs no such choice).
   - Update `BrailleExportOptionsView`'s doc comment (lines 360-366) to name the new pop-up.

## Tests

1. `BrailleFileWriterTests`: a page in each code: North American writes today's bytes exactly (an existing test may already pin them: do not change it); Eurobraille writes the lowercase form (dot 1 is "a", dots 4-5-6 "_", the digits as Eurobraille writes them); Unicode writes UTF-8 patterns, U+2800 for an inner blank cell, nothing for trailing blank cells, CR LF and form feeds as bytes; the escape backslash U+2873 is written as ⠳'s byte or pattern in each code; an eight-dot cell is refused in each code. And a round trip for each code: pages written then read back with `BrailleFileReader.pages(fromText:kind: .brf, code:)` are the same pages (rows without their trailing blank cells, as the writer leaves them out).
2. `BrailleDocumentWriterTests`: `brf(of:options:workingIn:)` with `options.fileCode = .eurobraille` writes Eurobraille, and the default options write North American Braille ASCII (one translation run each, as the class's other tests run them).
3. `BrailleExportWriterTests`:
   - `testEveryWordingConstantIsPinned` (line ~326): add `fileCodeHint`, and `BrailleSettingsWording.fileCodeLabel`.
   - The hosted options tests: the BRF options now draw 5 pop-ups, the PEF options still 3. In `testTheControlsSetTheOptions` (lines ~430-470) change only what the new pop-up changes: `popUps: 4` and each `count == 4` become 5, and add, after the line end's assertions: the fifth pop-up's items are the three names in `BrailleFileCode.all`'s order, North American selected, and choosing its second item sets `box.options.fileCode` to `.eurobraille`. In the PEF test (lines ~410-424), assert too that no control is labelled "Braille file characters". Find any other hosted test of these options that counts pop-ups (`grep -n "popUps:\|NSPopUpButton.self).count" TextMouthProductionTests/BrailleExportWriterTests.swift`) and raise only its BRF count. Change nothing else; if another existing test fails, stop and ask your lead.
   - A test that the pop-up is found by its label "Braille file characters" with the hint exactly (follow the label-and-hint test of `BrailleSettingsViewTests.swift` lines 39-55, with its skip for runners whose hosted windows expose no accessibility).

Run, through the wrapper: `BrailleFileWriterTests BrailleDocumentWriterTests BrailleExportWriterTests BrailleEmphasisRoundTripTests BrailleFileReaderTests BrailleSettingsViewTests`. Then `make lint-tests LINT_BASE=team/braillecodes` and `make lint-a11y` (a new control).

## Do not

- Touch the reader, `BrailleBookReader`, any book or record type, `BraillePreferences`, the Braille tab's view (beyond the one wording constant), any `*.md` file, or `Scripts/test/areas.conf`.
- Read anything under `~/.TextMouth`.
