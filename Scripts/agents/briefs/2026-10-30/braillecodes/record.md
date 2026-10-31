# Task `record`: a braille book's file code in its row, its package record, and its removal marker

Team `braillecodes`, lead `braillecodes-lead`. Your slug is `braillecodes-record`, your branch `braillecodes/record`, made from `team/braillecodes`. Read `Scripts/agents/briefs/2026-10-30/teams-common.md`, "The worker's part", first, and follow it.

## Background

A BRF or BRL braille file writes each six-dot cell as one character, in one of several codes ("braille file characters"): North American Braille ASCII (id `ascii-na`), Eurobraille six-dot (`ascii-eurobraille`), Unicode braille patterns (`unicode`). Another task of the team is building the code type (`BrailleFileCode`) at the same time as you; you do not need it and must not refer to it in code (doc comments may name it). Your task is the record: one optional string, the code's id, kept exactly as a braille book's table is kept (`brailleTable`), with the rule the text encoding uses so that the package record's value stands over a library row that lags behind it. The design is `BRAILLE-CODES-RESEARCH-2026-10-25.md`, section 8.4; you need nothing else from it.

The rules, settled:

1. The field is `brailleFileCode: String?`, the code's id. Nil means the book records none: every braille book imported before this work, every PEF, and every book of another format. Nil is read as North American Braille ASCII by a later task; an id this TextMouth does not know (a later TextMouth's) is kept exactly as stored, through every save, and refused by name when the book is read, never read as another code.
2. Who writes it: an import (a later task) writes the code a BRF or BRL is read with; Book Information's re-read in other braille file characters (a later task) writes the new id into the package record first, with the new text, and the library row takes it afterwards. So the record is never behind the row, and **the record's value stands when it names one; the row's otherwise** (`recorded ?? row`). A re-read always writes an explicit id, North American's included, never nil, so the rule holds.
3. An older TextMouth ignores the key (and drops it at its next write); a damaged value (not a string) reads as none and never fails the row, the record, or the marker.

## What to change

1. **The rule.** New file `TextMouth/Models/BrailleFileCodeRecord.swift`: `enum BrailleFileCodeRecord` with `static func standing(row: String?, recorded: String?) -> String?` returning `recorded ?? row`, its doc comment saying why (item 2 above), after the model of `TextEncodingRecord.standing(row:recorded:)` (`TextMouth/Models/TextEncodingRecord.swift` lines 67-81), whose rule it is with no "who decided" field: the first build guesses nothing, so it records no source (research 8.4).
2. **`Book`** (`TextMouth/Models/Book.swift`):
   - The stored property `var brailleFileCode: String?` right after `brailleTableVersion` (line 375), with a doc comment in the style of `brailleTable`'s (lines 351-363) saying items 1 to 3 above, and that it is kept in the row, the record, and the removal marker.
   - The memberwise `init` (line ~468): a parameter `brailleFileCode: String? = nil` right after `brailleTableVersion`, assigned with the others (line ~519).
   - The decoder (lines ~605-614): `brailleFileCode = fields.optionalValue(.brailleFileCode) { $0 }` after `brailleTableVersion`'s line, with a comment: a value that cannot be read counts as none, and the record's, when it names one, stands over it.
   - `makeBookInfo()` (line ~1235): `info.metadata.brailleFileCode = brailleFileCode`.
   - `init(record:filePath:folderPath:tmbDirectoryName:)` (line ~1297): `brailleFileCode: metadata.brailleFileCode`.
   - `bookInfo(replacing:contentIndex:revisionFloor:decidingTextEncoding:)` (lines 1087-1176): a new last parameter `decidingBrailleFileCode: Bool = false`, documented in the doc comment beside `decidingTextEncoding`'s paragraph (a re-read in other braille file characters, `LibraryPersistenceService.saveContentAnalysis`'s `brailleFileCode`); and, after the braille table's lines: `info.metadata.brailleFileCode = decidingBrailleFileCode && brailleFileCode != nil ? brailleFileCode : BrailleFileCodeRecord.standing(row: brailleFileCode, recorded: stored?.info.metadata.brailleFileCode)`, with a comment.
   - `recordedBrailleFileCode()`, right after `recordedTextEncodingRecord()` (lines 1061-1085): for a braille book with a package, the code that stands between the row's and the package record's (`BrailleFileCodeRecord.standing`), the record counting only when it is this book's (its `bookID` is the row's id), and read without downloading anything; any other book returns its row's. Do not copy the record read: move lines 1080-1083's reading of this book's own stored metadata into one `private func` (for example `ownStoredMetadata() -> BookMetadata?`) that both functions call; `recordedTextEncodingRecord()` must behave exactly as before.
   - `LibraryFields` (lines 873-911), what a reader takes from the library's row of its open book: add `var brailleFileCode: String?` after `textEncoding`, read and written in `libraryFields`, and say in the struct's doc comment that it carries the braille file code too, so the reader's Book Information shows a new choice.
3. **`BookMetadata`** (`TextMouth/Models/BookInfo.swift`, after `brailleTableVersion`, line ~136): `@LenientOptional var brailleFileCode: String? = nil`, documented as the row's field kept in the record, nil for every book that records none and for a record written before it was kept, a damaged value reading as nil (as `textEncoding`'s, line 145).
4. **`RemovedFromLibraryMarker`** (`TextMouth/Models/RemovedFromLibraryMarker.swift`): `@LenientOptional var brailleFileCode: String? = nil` after `brailleTableVersion` (line ~40), documented (bookInfo.json, which also holds it, is deleted by the removal, so a book added back would otherwise be read as North American Braille ASCII; a marker written before it existed has none), and set in `init(book:removedAt:)` from `book.brailleFileCode`.
5. **The book added back from its marker** (`TextMouth/Services/FileImportService+Packages.swift`, lines ~427-432): `brailleFileCode: format == .braille ? marker.brailleFileCode : nil,` after `brailleTableVersion`'s line, its comment folded into the braille table's.
6. **`ContentAnalysisSummary`** (`TextMouth/ViewModels/ContentAnalysisSummaryBuffer.swift`): `let brailleFileCode: String?` after `textEncodingSource` (line 40), documented as the record's code, taken back by a row that lags behind a re-read or lost its own; `init(committed:movedPlaces:)` (line 52) sets it from `committed.brailleFileCode`; `init(recovered:record:)` (line 76) from `record.brailleFileCode` only when `record.id == recovered.id && recovered.format == .braille`, else nil (as the encoding's lines 81-83 do for text formats); `apply(to:)` (line 155) adds `book.brailleFileCode = BrailleFileCodeRecord.standing(row: book.brailleFileCode, recorded: brailleFileCode)`, and its doc comment says so.
7. **`LibraryPersistenceService.saveContentAnalysis`** (`TextMouth/Services/LibraryPersistenceService.swift`, its doc comment and body at lines ~600-695, the function at line 649): a new last parameter `brailleFileCode: String? = nil`, documented beside `textEncoding`'s paragraph (lines ~622-631): the code a re-read in other braille file characters read the new text with, which is a decision and replaces the one the record holds. In the body: `if let brailleFileCode { merged.brailleFileCode = brailleFileCode }` beside the encoding's lines, and pass `decidingBrailleFileCode: brailleFileCode != nil` to `writeMerged`. Thread a `decidingBrailleFileCode: Bool = false` parameter through `writeMerged` (line 821) and `writeBookInfo` (line ~1004) down to `bookInfo(replacing:...)`, exactly as `decidingTextEncoding` is threaded, each with its doc line.

Nothing reads the field yet: no reader, import, setting, or view changes in this task.

## Tests

New `TextMouthProductionTests/BrailleFileCodeRecordTests.swift`, class `BrailleFileCodeRecordTests`, after the model of `BookTextEncodingTests.swift` (read its tests at lines 39-200 and 303-350 for their shapes; reuse nothing from it by editing it):

1. A row holds the key only when the book has a code; a row without the key, or with a damaged value (a number, an object), decodes with nil and keeps every other field.
2. The package record keeps it (`makeBookInfo()` and `BookInfo` through JSON); a record without the key, or with a damaged value, still loads, with nil.
3. A book rebuilt from its record (`Book(record:...)`) has it; an unknown id (`"ascii-braillo-no-047-01"`) survives row, record, and marker unchanged.
4. `BrailleFileCodeRecord.standing`: the record's when it names one, whatever the row holds; the row's when the record names none; nil when neither.
5. `bookInfo(replacing:contentIndex:)` over a stored record that names `ascii-eurobraille`, from a row that holds `ascii-na` (a row lagging behind a re-read) or nil, writes `ascii-eurobraille`; with `decidingBrailleFileCode: true` it writes the row's `ascii-na`; over a stored record that names none it writes the row's.
6. `recordedBrailleFileCode()` on a braille book with a real package in a sandbox folder (`makeSandboxDirectory`; write the record with `BookInfo`'s own save, as `BookTextEncodingTests` does): the record's code over the row's; the row's when the record names none or names another book (another `bookID`); the row's for a book of another format, without reading.
7. `ContentAnalysisSummary`: `init(recovered:record:)` takes the record's code for a braille book of the same id, and nil for another format or another id; `apply(to:)` follows the rule.
8. The removal marker keeps it, a marker JSON without the key decodes with nil, and the book added back from a marker of a braille book has it (follow `testABookRebuiltFromItsMarkerKeepsItsEncoding`, `BookTextEncodingTests.swift` line ~177).
9. `saveContentAnalysis(..., brailleFileCode: "ascii-eurobraille")` on a braille book's package writes it into the record and the returned book, and a later save from a row still holding `ascii-na` without the parameter keeps the record's `ascii-eurobraille` (follow `TextEncodingChoiceTests.swift` line ~157 for a call of `saveContentAnalysis` with `textEncoding:`).

Existing tests to bring up to date, because they pin every field or key (a new field is the change they ask for; change nothing else in them):

- `OnDiskContractTests`: add `"brailleFileCode"` to the library row's keys (line ~278-285; with a comment like the encoding's: "braillecodes: the braille file characters a BRF or BRL book is read with, by the code's id. An optional key, read leniently; an older TextMouth drops it, and the book then reads as North American Braille ASCII.") and to the record's metadata keys (line ~315-317), and `brailleFileCode: "ascii-eurobraille"` to its `bookWithEveryFieldSet()` (line ~639).
- `ContentAnalysisMergeTests.bookWithEveryFieldSet(seed:)` (line ~850): `brailleFileCode: "code-\(seed)"`, so books of two seeds still differ in every field.
- `DuplicateReplacementTests.bookWithEveryFieldSet()` (line ~936): `brailleFileCode: "ascii-eurobraille"`, so `testAnotherIDChangesNothingElse` proves the field is carried.

Run, through the wrapper: `BrailleFileCodeRecordTests OnDiskContractTests ContentAnalysisMergeTests DuplicateReplacementTests BookTextEncodingTests TextEncodingChoiceTests TextEncodingRereadTests ContentAnalysisSummaryBufferTests BookMetadataUpdateTests HandEditedMetadataTests LibraryOnlyRemovalTests BrailleImportTests`. Then `make lint-tests LINT_BASE=team/braillecodes`.

## Do not

- Touch any braille parser, writer, reader, setting, view, or `FileImportService.swift` (only `FileImportService+Packages.swift`, item 5).
- Change what any existing field does, or `recordedTextEncodingRecord()`'s behaviour.
- Edit any `*.md` file or `Scripts/test/areas.conf` (the lead places your new class).
- Read anything under `~/.TextMouth`.

## Builds: wait for the lead's go

Another worker of your team holds the team's one build now. Write your code and tests first; **do not start any build until your lead posts `build: go` to you.** Wait for it with `python3 .claude/skills/agent-bbs/scripts/bbs.py watch braillecodes-record --timeout 600`, repeated (never a sleep loop). When your last build ends, remove your build folder at once (the two commands under "Builds" in `teams-common.md`) and say so in your `done:` post.
