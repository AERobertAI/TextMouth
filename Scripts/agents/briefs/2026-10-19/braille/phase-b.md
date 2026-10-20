# Phase B: BRF and PEF in the Export dialog (FMT22, the charter's decision 15)

- **Branch:** `braille/phase-b`, made from `team/braille` after it is rebased onto main (your lead says when; main then holds team export's merge, 0db62a38 or later).
- Read `Scripts/agents/briefs/2026-10-19/braille/common.md` first, then team export's note, `Scripts/agents/briefs/2026-10-19/export/interface-for-braille.md` (all of it: the model, the walker, the writer interface, and how to test a writer), and the public declarations and comments of `TextMouth/Services/Export/TextExportWriter.swift`, `ExportDocument.swift`, and `WordDocExportWriter.swift` (a writer to copy).
- **Braille's side, already on the branch:** `BrailleDocumentWriter` and `BrailleExportOptions` (`TextMouth/Services/BrailleDocumentWriter.swift`), `BraillePageFormat` (`BrailleLayout.swift`), `BrailleLineEnd` and `PEFMetadata` (`BrailleFileWriter.swift`), `BrailleTableCatalog`, `BraillePreferences`, `BrailleSettingsChoice` and `BrailleSettingsWording` (`BrailleSettingsView.swift`), `BrailleTranslator.Failure`.
- **Files:** new `TextMouth/Services/Export/BrailleExportWriters.swift`, `TextMouth/Views/Export/BrailleExportOptionsView.swift`, `TextMouthProductionTests/BrailleExportWriterTests.swift`; two lines in `TextExportWriters.all` (in `TextExportWriter.swift`), after the Word writer; `BrailleDocumentWriter.swift` only to make `BrailleExportOptions` conform to `TextExportOptions` (and `BraillePageFormat` and `BrailleLineEnd` `Hashable`); the regenerated `project.pbxproj`. Of export's files, nothing else. Edit no `*.md`.
- About three commits: the blocks and the two writers; the options view; the round trips.

## 1. From the export model to braille blocks
`BrailleExportBlocks.blocks(of document: ExportDocument) -> [BrailleBlock]`, print text, in reading order:
1. `document.titleHeading`, when there is one, first, as `.heading(level: 1, …)`.
2. `.heading(h)`: `.heading(level: h.level, text: h.plainText)`. `.paragraph(runs)`: `.paragraph(text: runs.plainText)`.
3. `.list(list)`: walk each item's `blocks`, never its `plainText` (the note says why): each paragraph in an item is a `.listItem(depth: list.depth + 1, text:)`, an inner `.list` recurses (its own `depth` already counts), and any other block inside an item is handled as below at the item's depth. An ordered list's item's first paragraph begins with its number, `"\(list.start + index). "`; an unordered list's items have no mark (BANA lays lists out by their margins).
4. `.blockQuote(blocks)`: its blocks, handled as these rules handle them.
5. `.codeBlock(text)`: one `.paragraph` for each of its lines that is not empty.
6. `.table(table)`: one `.paragraph` for each row, its cells joined by `"; "`.
7. `.thematicBreak`: nothing (it holds no text).

## 2. The writers
In `BrailleExportWriters.swift`, two `TextExportWriter`s that share everything but their file:
- `BRFExportWriter`: `id` `brf`, `name` `BRF`, `hint` `Braille Ready Format: pages of braille ASCII, for braille displays and embossers.`, `fileExtension` `brf`.
- `PEFExportWriter`: `id` `pef`, `name` `PEF`, `hint` `Portable Embosser Format: pages of Unicode braille in XML, for embossers.`, `fileExtension` `pef`.
- **Options:** `BrailleExportOptions`, conforming to `TextExportOptions`; `defaultOptions()` is `BrailleExportOptions.standard()` (40 cells, 25 lines, page numbers on, CR LF, and the Braille setting's table: the user's October 17 defaults).
- **`write`:** `try cancellation.checkCancelled()`, then the blocks of item 1, then `BrailleDocumentWriter.brf(of:options:workingIn:)` (or `.pef(of:metadata:options:workingIn:)`) with `url.deletingLastPathComponent()` as the working folder (the export's scratch folder), then `try cancellation.checkCancelled()` again, then the bytes written to `url`. A PEF's metadata: the book's title, its author or "" when unknown, its language or `en`, `urn:uuid:` and a new UUID, and today's date as `yyyy-MM-dd` in the Gregorian calendar and the POSIX locale.
- **Errors:** a `BrailleTranslator.Failure` becomes `TextExportError(failure.localizedDescription)`, so the dialog says "Couldn't export <file name>: TextMouth stopped the braille translation because …"; a `CancellationError` passes on unchanged.

## 3. The options view (`BrailleExportOptionsView.swift`)
Shown under the Convert to picker while BRF or PEF is chosen, bound to the options. In a `Form` or `VStack` as the dialog's other controls are drawn (look at `TextMouth/Views/Export/` for the dialog's style); every control labelled, hinted, with its value spoken, and reachable by the keyboard:
1. **Braille code** and **Contraction**: the same two pop-ups as the Braille tab, with the same choice rules (`BrailleSettingsChoice`), the same labels (`BrailleSettingsWording.codeLabel`, `.contractionLabel`), and these hints: `The braille code the book is written in.` and `Whether that code's braille is contracted.`
2. **Cells per line**: a `Stepper` from 18 to 80, labelled `Cells per line`, its spoken value the number and `cells` (`40 cells`), hint `How many braille cells each line holds, from 18 to 80.`
3. **Lines per page**: a `Stepper` from 4 to 50, labelled `Lines per page`, value `25 lines`, hint `How many lines each braille page holds, from 4 to 50.`
4. **Braille page numbers**: a `Toggle`, hint `Whether each page's last line carries its braille page number.`
5. **Line ends** (BRF only, absent for PEF, which always uses LF): a `Picker` labelled `Line ends` of `CR LF` and `LF`, hint `CR LF suits most braille displays and embossers.`
Put every string in one `enum BrailleExportWording` in that file, and use the steppers' counts through `CountWording` if it has cells and lines (else plain `"\(n) cells"`).

## 4. Tests (`BrailleExportWriterTests`)
1. **Blocks:** a hand-built `ExportDocument` with a title heading, headings of levels 1 to 3, a paragraph with emphasis and a link (its plain text only), an ordered list starting at 3 with a nested unordered list, a block quote, a two-line code block, a table, and a thematic break gives exactly the blocks item 1 says, depths included.
2. **The writers:** `BRFExportWriter` of a document walked from Markdown (`# Pride and Prejudice`, `## Chapter I`, and the sample's 12 paragraphs, from `brf/pride-and-prejudice-ch1.txt`) with `en-ueb-g1.ctb` at 40 by 25 writes exactly what `BrailleDocumentWriter.brf(of:…)` writes for those blocks; `PEFExportWriter`'s file has the book's title, author, and language, a `urn:uuid:` identifier, and today's date.
3. **Options:** `defaultOptions()` inside `BraillePreferences.$tableForImports.withValue("en-us-g1.ctb")` has that table and 40, 25, numbers on, CR LF; the options view, hosted as `BrailleSettingsViewTests` hosts the tab, has the pop-ups, steppers, toggle, and (BRF only) the line ends picker by their labels and hints; every `BrailleExportWording` string pinned.
4. **Cancelled:** a `BookExportCancellation` cancelled before `write` makes it throw `CancellationError` and write nothing.
5. **Registered:** `TextExportWriters.all`'s ids end `brf`, `pef`, after `doc`; `writer(id:)` finds both.
6. **The Grade 2 round trip (decision 15):** a book whose `content.md` holds the Grade 2 sample's three sentences, each its own paragraph, exported through `BookExportService.export(…)` with `.text(TextExportConversion(BRFExportWriter(), options: …))` and `en-ueb-g2.ctb`, then the BRF imported (`importedForTest`, inside `$tableForImports.withValue("en-ueb-g2.ctb")`): its text is the three sentences, with liblouis's own differences named in the test, if any.
7. **M6's round trip through the dialog's path:** the same with `Москва`, `中文`, and `🙂`, to BRF and to PEF: neither import is refused, and the text is what `BrailleDocumentWriterTests` pins for them.

Run `BrailleExportWriterTests`, the areas `braille` and `export`, and `BrailleSettingsViewTests`; `make lint-tests LINT_BASE=team/braille` and `make lint-a11y LINT_BASE=team/braille`.
