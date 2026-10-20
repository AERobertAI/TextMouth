# Task `writer`: from print blocks to a BRF or PEF file (FMT22, Phase A)

- **Slug:** `braille-writer`. **Branch:** `braille/writer`, made with `git checkout -b braille/writer team/braille`.
- Read `Scripts/agents/briefs/2026-10-19/braille/common.md` first.
- **Files:** new `TextMouth/Services/BrailleDocumentWriter.swift`; new `TextMouthProductionTests/BrailleDocumentWriterTests.swift`; the regenerated `project.pbxproj`.
- **Read first:** the public declarations and comments of `TextMouth/Services/BrailleLayout.swift` (`BraillePageFormat`, `BrailleLayout.pages(of:format:)`), `TextMouth/Services/BrailleFileWriter.swift` (`BrailleLineEnd`, `PEFMetadata`, `brf`, `pef`), `TextMouth/Services/BrailleTranslator.swift` (`translate(_:table:direction:workingIn:)`), and `TextMouth/Models/BrailleTableCatalog.swift` (`BraillePreferences`, `defaultTableID`); `TextMouthProductionTests/BrailleTranslatorTests.swift`'s Grade 1 forward test (how the samples' paragraphs are made, and liblouis's two named differences).
- **Not yours:** every `BookExport*` file and `TextMouth/Views/Export/` (team `export`'s until it merges: Phase B wires this writer into the Export dialog); everything else.

## What to build
1. **The options,** the user's October 17 defaults (40 cells, 25 lines, Unified English Braille contracted, page numbers on, CR LF), each changeable in the Export dialog in Phase B:
   ```swift
   /// What a braille export writes (FMT22).
   struct BrailleExportOptions: Equatable, Sendable {
       /// Cells per line, lines per page, and page numbers.
       var page = BraillePageFormat()
       /// The table, by file name: the code and its contraction.
       var table = BrailleTableCatalog.defaultTableID
       var lineEnd = BrailleLineEnd.crlf
       /// The defaults, with the table the Braille setting chose.
       static func standard() -> BrailleExportOptions
   }
   ```
   `standard()` takes its table from `BraillePreferences.importTable()` (the setting, or a test's bound table).
2. **`enum BrailleDocumentWriter`:**
   - `static func pages(of blocks: [BrailleBlock], options: BrailleExportOptions, workingIn folder: URL) throws -> [[String]]`: the blocks' print, translated to braille with `BrailleTranslator.translate(_, table: options.table, direction: .printToBraille, workingIn: folder)`, each block keeping its kind (`withText`), then laid out with `BrailleLayout.pages(of:format: options.page)`.
   - `static func brf(of blocks: [BrailleBlock], options: BrailleExportOptions, workingIn folder: URL) throws -> Data`: `BrailleFileWriter.brf(pages:lineEnd:)` of those pages.
   - `static func pef(of blocks: [BrailleBlock], metadata: PEFMetadata, options: BrailleExportOptions, workingIn folder: URL) throws -> Data`: `BrailleFileWriter.pef(pages:metadata:format:)` of them.
   - Errors are the translator's, passed on unchanged. No blocks give an empty BRF and a PEF with no page.
3. Each function's comment says the input is print (from the document walker team `export` writes, in Phase B), and that the layout and the writers are pure, so only the translation runs a process.

## Tests (`BrailleDocumentWriterTests`), with the real helper
Make the blocks from the print sample: `.heading(level: 1, "Pride and Prejudice")`, `.heading(level: 2, "Chapter I")`, then the 12 paragraphs of `pride-and-prejudice-ch1.txt`.
1. **Grade 1 against the samples:** with `en-ueb-g1.ctb` at 40 by 25, page numbers on, CR LF, `brf(of:…)` equals the BRF sample except for liblouis's two named differences from the prototype that wrote it: the question mark at a word's end (⠦ where the sample has ⠰⠦) and `_You_`'s underscores (⠨⠤ each, where the sample has the italic word indicator before the word). Pin that exactly: the expected file is `BrailleFileWriter.brf(pages: BrailleLayout.pages(of: <the BRL sample's 14 lines with ";8" replaced by "8" and ".1,YOU" by ".-,YOU.-", converted, as the same heading and paragraph blocks>, format: …), lineEnd: .crlf)`, and the test says in its comment which sample lines the differences touch. The same for `pef(of:…)` with the PEF sample's metadata, against the PEF built the same way.
2. **Grade 2:** the Grade 2 sample's three sentences, each a paragraph, with `en-ueb-g2.ctb`, give pages whose text rows are the BRF sample's three rows, each now starting in cell 3 (a paragraph's first line), and whose last row is `⠼⠁` at the right.
3. **Options:** 32 cells by 10 lines, page numbers off, LF: every row at most 32 cells, every page 10 rows, no `⠼⠁` on a last line, and LF line ends; `standard()` inside `BraillePreferences.$tableForImports.withValue("en-us-g1.ctb")` has that table and 40, 25, numbers on, CR LF.
4. **No blocks:** an empty BRF; a PEF with no `page`.
5. **Tidy:** the working folder is empty after each call.

Run `BrailleDocumentWriterTests`, `BrailleLayoutTests`, `BrailleFileWriterTests`, and `BrailleTranslatorTests`.
