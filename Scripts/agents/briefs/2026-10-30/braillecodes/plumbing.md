# Task `plumbing`: a braille book is read, at import and every rebuild, with the file code it records

Team `braillecodes`, lead `braillecodes-lead`. Your slug is `braillecodes-plumbing`, your branch `braillecodes/plumbing`, made from `team/braillecodes`. Read `Scripts/agents/briefs/2026-10-30/teams-common.md`, "The worker's part", first, and follow it.

## Background

On the team branch already:
- `TextMouth/Parsers/BrailleFileCode.swift`: the catalog (`BrailleFileCode.code(forStored:)` gives North American Braille ASCII for a stored nil or "", the code for a known id, nil for an id this TextMouth lacks).
- `BrailleFileReader.read(_:as:code:)`, `BrailleFileReader.certainCode(ofFileAt:)` (`.unicode` when a file's bytes say so for certain, else nil), and `BrailleFileError.unknownFileCode(String)` ("TextMouth has no braille file characters named “x”.").
- `Book.brailleFileCode` (the stored id; nil reads as North American), `Book.recordedBrailleFileCode()` (the code that stands between the row's and the package record's), and the record and marker fields.

Nothing reads `Book.brailleFileCode` yet: every reading of a braille book is North American Braille ASCII. This task passes the book's code down every reading path, records it at import, and adds the setting an import reads (its pop-up and config.json come in a later task). The design is `BRAILLE-CODES-RESEARCH-2026-10-25.md`, sections 8.3 (Import), 8.4, and 8.5.

## What to change

1. **The setting** (`TextMouth/Models/BrailleTableCatalog.swift`, `BraillePreferences`, lines 817-853), beside `table`, `tableForImports`, and `importTable()`, each documented as those are:
   - `static let fileCode = StoredPreference<String>(key: "brailleFileCode", ...)`: reads the stored id when it is a code of `BrailleFileCode.all`, and `BrailleFileCode.defaultCode.id` otherwise (empty, missing, or unknown); writes the id.
   - `@TaskLocal static var fileCodeForImports: String? = nil`, which a hosted test binds, as `tableForImports`.
   - `static func importFileCode() -> String`: `fileCodeForImports ?? fileCode.read(from: TextMouthRuntime.current.preferences)`.
2. **The import** (`TextMouth/Services/FileImportService.swift`, lines 916-956): read beside the table, once, for a braille book: `let brailleFileCode = format == .braille ? Self.brailleFileCode(ofImported: stagedFile) : nil`, passed as `brailleFileCode:` to the `Book` after `brailleTableVersion:`, with the comment block of lines 950-953 saying it too. A new `static func brailleFileCode(ofImported url: URL) -> String?` in the same file, documented: nil for a PEF (`BrailleBookReader.kind(of:)`; a PEF is always Unicode braille patterns, and records none); for a BRF or BRL, `BrailleFileReader.certainCode(ofFileAt:)`'s id when the bytes say Unicode braille patterns for certain, and the Braille setting's (`BraillePreferences.importFileCode()`) otherwise. No other code is ever guessed (research 8.5). The import records the id explicitly, North American's included, as it records the table.
3. **The reader** (`TextMouth/Parsers/BrailleBookReader.swift`): `markdown(of:table:recordedVersion:includesPages:)` (lines 55-152) and `parse(url:title:table:recordedVersion:)` (lines 185-196) take `fileCode: String? = nil`, the book's stored id, documented beside `table` and `recordedVersion`. In `markdown`, after `requireUnchangedTable` and before the size check: for a BRF or BRL (not a PEF, whose stored code, which none has, is ignored), resolve `BrailleFileCode.code(forStored: fileCode)`, throwing `BrailleFileError.unknownFileCode(fileCode ?? "")` for nil, so a code this TextMouth lacks is refused by name and never read as another; then `BrailleFileReader.read(url, as: fileKind, code: code)`. Update the type's doc comment (lines 3-13) and `markdown`'s Throws.
4. **Every reading path** passes the book's code:
   - `BookParser.parse(url:format:brailleTable:brailleTableVersion:encodingPolicy:)` (`TextMouth/Parsers/BookParser.swift`): `brailleFileCode: String? = nil` after `brailleTableVersion`, documented, passed to `BrailleBookReader.parse`.
   - `MarkdownCacheService` (`TextMouth/Services/MarkdownCacheService.swift`): `extractCache` (lines 590-669) takes `brailleFileCode: String?` after `brailleTableVersion` and passes it to `BrailleBookReader.markdown(... fileCode:)`; its doc comment's braille sentence (lines 598-604) says the book is read with its file code too. Its callers: `writeCache` (lines 213-232) passes a new `private static func brailleFileCode(of book: Book, decidingEncoding: Bool) -> String?`, beside `encodingPolicy(of:decidingEncoding:)` (lines 195-205) and documented like it: for a read `decidingEncoding` (an import of a file the user chose, and a re-read from Book Information), the row's `brailleFileCode`, as the row says; for any other read, `book.recordedBrailleFileCode()`. `extractedText(for:includesPages:)` (lines 336-348) passes `current.recordedBrailleFileCode()`.
   - In `generateReportedCacheAnalyzeAndStamp` (lines 423-474), after the encoding's lines and as they do: `if !decidingEncoding { book.brailleFileCode = book.recordedBrailleFileCode() }`, commented: the book takes the code its file was just read with, the record's for a row that lags behind a re-read or lost its own.
   - The doc comments of `decidingEncoding` (lines 167-178 and 432-443) say that such a read also reads a braille book's file with the code its row records, which a re-read in other braille file characters sets on the row before the read (a later task); do not rename the parameter.
   - `BookContentAnalysisService` (`TextMouth/Services/BookContentAnalysisService.swift`, lines 81-85): `brailleFileCode: book.recordedBrailleFileCode()`.
5. `grep -rn "BrailleBookReader.markdown\|BrailleBookReader.parse\|BookParser.parse(" TextMouth` must show no braille reading in the app that leaves the code out, but those of tests and the two defaults.

## Tests

New class `BrailleFileCodeImportTests` (file `TextMouthProductionTests/BrailleFileCodeImportTests.swift`), with `LibraryIndexSandbox` as `BrailleImportTests.swift` lines 11-29 use it, every import with its table and code bound (`BraillePreferences.$tableForImports.withValue(...)`, `BraillePreferences.$fileCodeForImports.withValue(...)`), never the user's settings:

1. A copy of `brf/pride-and-prejudice-ch1-grade1.brf` imported with the setting North American records `"ascii-na"` in its row and its package record (`StoredBookRecord.read` or `BookInfo.load`), and reads as it always did (compare content.md with the same sample's import in `BrailleSampleGoldenTests`' terms, or simply with a second import of the sample: equal).
2. The same sample, its bytes converted to Eurobraille (each byte that is a North American cell to `SevenBitBrailleTable.eurobraille.byte(forDots:)` of the same dots; CR, LF, and form feed kept), imported with the setting Eurobraille, records `"ascii-eurobraille"` and gives byte for byte the content.md of the North American sample; imported with the setting North American instead, it gives other text and no error (the silent case that makes the choice matter: assert the content.md differs).
3. The sample converted to Unicode braille patterns (UTF-8) imports as `"unicode"` whatever the setting (bind Eurobraille to prove it), with the North American sample's content.md.
4. A PEF (`pef/pride-and-prejudice-ch1-grade1.pef`) records none (nil), whatever the setting.
5. A rebuild reads the record's code over a lagging row: import the Eurobraille copy with the setting Eurobraille, set the row's `brailleFileCode` to `"ascii-na"` without touching the record, and `MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(for: &book, replacingEditedText: true)` writes the same content.md as before and leaves `book.brailleFileCode == "ascii-eurobraille"`.
6. An unknown code is refused by name and changes nothing: a book whose row and record hold `"ascii-braillo-no-047-01"` (write the record through `LibraryPersistenceService` or `BookInfo`'s own save, as `BrailleImportTests` writes one, or set both fields before the rebuild) fails its rebuild with exactly "TextMouth has no braille file characters named “ascii-braillo-no-047-01”.", and its content.md is unchanged, byte for byte; `BookParser.parse(url:format: .braille, brailleFileCode: "ascii-braillo-no-047-01")` throws the same.
7. The setting: `BraillePreferences.fileCode` in a sandboxed store (follow how `BrailleTableCatalogTests` or `BrailleSettingsViewTests` make one) reads North American when unset, empty, or unknown, and a known id as itself; `importFileCode()` gives the bound id when one is bound.

Run, through the wrapper: `BrailleFileCodeImportTests BrailleImportTests BrailleSampleGoldenTests BrailleFileCodeRecordTests BrailleBookPageTests PagesUpgradeTests MacBrailleTableBookTests BrailleEmphasisReadingTests TextPipelineGoldenTests BrailleTableCatalogTests`. Then `make lint-tests LINT_BASE=team/braillecodes`.

## Do not

- Touch the reader's or writer's internals, `Book`, `BookInfo`, the marker, the settings model or views, config.json, any `*.md` file, or `Scripts/test/areas.conf`.
- Read anything under `~/.TextMouth`.
- `FileImportService.swift` is large and other teams may edit it tonight: claim your lines on the board (`bbs claim`) and read the claims first.
