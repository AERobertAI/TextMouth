# Team `braillecodes`: braille file character codes (October 30, 2026)

Read `teams-common.md` beside this file first: it is the pattern, the rules, and the report format, and it stands in for AGENTS.md. You are the lead, `braillecodes-lead`, on branch `team/braillecodes`, made from local `main` by name (`git checkout -b team/braillecodes main`; your worktree may start on an older commit).

## Why
TextMouth reads BRF and BRL files, and writes BRF from Export, in North American Braille ASCII only (`TextMouth/Parsers/BrailleCells.swift`). Some countries' software writes braille files in other character codes, which TextMouth would read as the wrong cells, silently. On October 25, 2026 the user said: "I don't read other braille books, but I still want Text Mouth to support them if possible and I feel like it might be easier to add a structure now then lader if other people start using it." A research agent wrote `BRAILLE-CODES-RESEARCH-2026-10-25.md` (now on main, in the repository root). Its section 8, "What TextMouth should build now", is your design: read sections 1, 4, 8, and 9 and Appendix A in full, and the rest as you need it.

## What to build
Section 8.8's order of work, steps 1 to 9, with the research's recommended answers to its questions (section 8.10), which the user has not answered yet and can change later:
- **The label** is "Braille File Characters", everywhere the research names it (Settings, Export, Book Information, Speak Full Info's "Braille characters: …" sentence; keep that sentence as the research words it).
- **Three codes ship:** North American Braille ASCII (`ascii-na`, the default, and what a book that records no code is read as), Eurobraille six-dot (`ascii-eurobraille`), and Unicode braille patterns (`unicode`).
- **No guessing** among seven-bit codes; only the certain signals of section 8.5 (Unicode patterns in a .brf or .brl are read as `unicode` and recorded so; an eight-bit file keeps being refused, with the better sentence 8.5 gives).
- **The record:** `brailleFileCode: String?` on the row, the package record, and the removal marker, with the `standing` rule the text encoding uses (`TextEncodingRecord.standing(row:recorded:)`). An older TextMouth ignores the key; say in your report whether that is PATCH or MINOR under the version policy (`docs/developer/building.md`, "Versions"), with the reason.
- **Book Information's pop-up** follows the Text Encoding pop-up (`TextEncodingChoiceModel`, its alert, its re-read flow, its busy refusals, its accessibility wording, value first), sharing code with it wherever the two do the same thing (the project's DRY rule); its alert says the research's sentence that nothing checks the choice.
- **Vendor** `en-us-brf.dis`, `de-eurobrl6.dis`, and `de-eurobrl6u.dis` from liblouis 3.39.0 unchanged, for the tests, listed in `docs/developer/third-party-code.md` by the documentation pass (you edit no `*.md`; put the wording in your report). If you cannot obtain them from the 3.39.0 release offline, take the 64 entries from Appendix A and the research's cross-checks, and say so.
- **Never read the Mac's own `.dis` files** for a book's code (section 2).

Step 10 (the documents and the changelog) is the orchestrator's: put every sentence a listener hears, and the documentation wording, in your report.

## Things to get right
- **The listener's text must never change silently.** Every existing braille book (none records a code) reads exactly as before: prove it with a test that reads every BRF and BRL sample in `TestData/format-samples/` before and after, byte for byte the same content.md.
- **The page analyzer's labels** stay in North American Braille ASCII whatever the book's code (section 8.7), with the same-labels test.
- **Untrusted input:** a file's bytes are untrusted; bound everything.
- **Tests to name in briefs,** besides the new ones: the braille test classes (`grep -rln "Braille" TextMouthProductionTests | head -40`), `OnDiskContractTests` (a new record field), `ContentAnalysisMergeTests` (a new field on `Book`), the config and settings test classes for the new key, `SettingsTabFitTests` (a new Settings control), `UncheckedConcurrencyPolicyTests` and `LogContentPolicyTests` if you add such a type or a log tag, and `make lint-a11y` for every new control.

## Files
You own the braille parsers and writers (`BrailleCells.swift`, `BrailleFileReader.swift`, `BrailleFileWriter.swift`, `BraillePageAnalyzer.swift`'s label function, `BrailleBookReader.swift`), `BrailleTableCatalog.swift`'s `BraillePreferences`, `BrailleSettingsView.swift`, `BrailleExportOptionsView.swift` and the export options, the new code and choice-model files, and their tests. Shared files where you add only your own lines: `Book.swift`, `BookInfo.swift`, `RemovedFromLibraryMarker.swift`, `LibraryInfoWording.swift`, `LibrarySheetViews.swift` (the Book Information row), `ConfigService.swift`, `SettingsViewModel.swift`, `FileImportService.swift` and `FileImportService+Packages.swift`, `MarkdownCacheService.swift`, `BookContentAnalysisService.swift`, `BookParser.swift`, `LibraryViewModel+TextEncoding.swift` (if you share its re-read flow), `Scripts/test/areas.conf`, `project.pbxproj` (by `xcodegen generate` only). The `views` team edits `ConfigService.swift`, `SettingsViewModel.swift`, `SettingsView.swift`, and the Library window tonight, and the `bughunt` team fixes bugs anywhere: claim your files, read the claims, and agree on the board before editing a region another team claims.

## When you are done
Follow "Finish" in `teams-common.md`: rebase on main, one full suite, report, including the app's size change if a vendored file is bundled.
