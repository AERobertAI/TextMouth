# Task keepexport: Export offers the kept original of converted audio (FMT14, step 3)

Slug `audiofmt-keepexport`, branch `audiofmt/keepexport` made from `team/audiofmt`. Read `Scripts/agents/briefs/2026-10-18/audiofmt/common.md` first.

Task `keeporig` (on `team/audiofmt` already) added the setting "Keep originals of converted audio". With it on, an import keeps each source it converts in the package's hidden folder `.convertedOriginals` (`ImportAudioConverter.keptOriginalsFolderName`), under its path from the book's folder of tracks. `ImportAudioConverter.keptOriginals(inPackage:)` lists them. The setting's caption promises "Export offers it as the Original file." This task keeps that promise, and checks that the storage figures and the data folder's move count the kept files.

## 1. Export: `TextMouth/Services/BookExportService.swift`
- **A new item.** In `offer(for:access:)` (lines 216-267), an audiobook whose package holds kept originals gets an `.originalFile` item. Model the function, `convertedOriginalItem(of:stem:access:)`, on `originalAudioItem(of:stem:access:)` (lines 430-478), which does the same for the audio editor's originals: the same cloud handling and the same listing (`regularFiles(in:)`), through `access`.
  - A book of one file exports its one kept original under the original's own name, as a text book's Original file is exported (`ownFileItem`, line 278).
  - A book of tracks exports them in a folder named "<stem> - Original Files", each under its path inside `.convertedOriginals`.
  - Nil when the folder is absent or empty.
- **Nothing else changes.** `.audio` stays the converted audio the book plays, and the editor's "Original audio (before edits)" stays as it is.
- **The hint.** `BookExportWording.hint(for: .originalFile)` (`TextMouth/Models/BookExportWording.swift`, about line 28) becomes: "The book's own file, as it was imported; for an audiobook, its audio files as they were before TextMouth converted them." Update any test that pins the old hint: that is the intended change; name it in your report.
- **A kept .ogg is copied as bytes,** never opened (the October 14 rule). `BookExportFile.Source.copy` does exactly that.

## 2. The storage figures
- Find the figures (`grep -rn "DataDirectoryCopyPlan\|librarySize" TextMouth/Services`).
- Check by a test that the data folder's copy plan (`DataDirectoryCopyPlan`) counts and copies a package's `.convertedOriginals` files: a move of the data folder must never lose them.
- If a figure or the plan passes hidden files by, stop and ask your lead before changing it.

## 3. Tests
Append to `ConvertedOriginalTests` (made by task `keeporig`), or add a class beside it.
- **The single file.** An imported .ogg kept with the setting on: the Export offer has an `.originalFile` item whose one file is the kept .ogg, under its own name, with its byte count.
- **A book of tracks** with `01.ogg` and `02.mp3`: the folder item "<stem> - Original Files" holds `01.ogg` alone.
- **No kept original,** and no `.originalFile` item for an audiobook (as today).
- **The hint's new words.**
- **Exporting** the single file's item writes a copy byte for byte equal to the kept original. Use the Export tests' own way to run an export into a temporary folder: `grep -ln "BookExportService" TextMouthProductionTests/*.swift`.
- **`DataDirectoryCopyPlan`** includes the kept files.

## Commits
1. The Export item and its hint, with their tests.
2. The storage check's test (and only a test, unless your lead agrees to more).

## Test classes (one run)
`ConvertedOriginalTests`, the Export classes (`grep -l "BookExportService\|BookExportWording" TextMouthProductionTests/*.swift`), the data folder's move classes (`grep -l "DataDirectoryCopyPlan" TextMouthProductionTests/*.swift`), `UncheckedConcurrencyPolicyTests`, and `LogContentPolicyTests`.

## Do not touch
The import, the setting, `ImportAudioConverter.swift` (use `keptOriginals(inPackage:)` and `keptOriginalsFolderName` as they are), and any `*.md`.
