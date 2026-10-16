# testkit/corpus-report: a Markdown report on any folder of documents

Slug `testkit-corpus-report`. Branch `testkit/corpus-report`, made from `team/testkit` AFTER `testkit/goldens` and `testkit/runner` were integrated (`TextMouthProductionTests/DocumentDump.swift` and `Scripts/test/run-area.py` exist on your branch; if either does not, stop and tell `testkit-lead`). You build; at most two builders run at once. Read `teams-common.md`'s worker's part first.

## Why

TODO T10 ("Validate PDF reading order and heading heuristics on a representative corpus", TODO-2026-09-04.md line 3535) and the acceptance matrix's "Real documents" row need someone to import real files and look. The user is blind and cannot skim a library visually: they want a plain report on a folder, one section per file, that they can read with VoiceOver, saying what the importer made of it: format, title, author, headings with levels, text length, the first lines, every warning or refusal. This is the machine's half of that check; judging whether the reading order is right is still a person's.

## Ground truth

- `DocumentDump` (from `testkit/goldens`): builds the facts of an imported book; reuse it for everything it holds and extend it in YOUR OWN file with an `extension DocumentDump` (do not edit `DocumentDump.swift`).
- Import: `TextPipelineFixtures.imported(_:for:)` is for a plain book; to also get the report of chapters left out and the failure of a file that cannot be imported, call `FileImportService.importFileWithReport(from:)` (TextMouth/Services/FileImportService.swift:776) yourself: `ImportedBook` has `book` and `report` (`ExtractionReport.message`). A failure is an `ImportFailure` (TextMouth/Services/ImportFailure.swift) whose message names the file and the failed step: record its `localizedDescription` verbatim.
- PDF: `PDFImportReportTests.swift` and `PDFExtractionDiagnosticsTests.swift` show the extraction diagnostics the importer keeps (pages read by text, by recognition, short embedded text kept): include the PDF report text when the import gives one.
- Ogg files (`.ogg`, `.oga`, `.opus`): NEVER decode them in the test host (AGENTS.md's B06 lesson: Apple's Vorbis decoder hung the Mac). The report gets one line for each: `skipped: Ogg audio is never decoded in the test host`.
- The importer may delete an original after importing, depending on the user's "After Importing a Book" setting: so COPY every file into a folder inside the test's own sandbox first and import the copy; the user's files are never opened for writing.
- `.gitignore` ignores `*.md`: the report is written outside the repository, to the path named by `TEXTMOUTH_CORPUS_REPORT`.
- Never read the user's library: the class reads only the folder named by `TEXTMOUTH_CORPUS_DIR`.

## What you build

1. `TextMouthProductionTests/CorpusReportTests.swift`: `final class CorpusReportTests: XCTestCase`. The hosted test `testReportOnTheCorpusFolder` throws `XCTSkip("Set TEXTMOUTH_CORPUS_DIR to a folder of documents to run this.")` unless `TEXTMOUTH_CORPUS_DIR` is set to an existing folder. It walks the folder recursively (sorted by relative path; skips hidden files, `.DS_Store`, and package internals), caps at `TEXTMOUTH_CORPUS_MAX_FILES` (default 200; says so in the report when it cut), copies each file into the sandbox, imports it with a per-file time limit `TEXTMOUTH_CORPUS_FILE_SECONDS` (default 180; on a timeout the file's section says `timed out after N seconds` and the walk goes on; run the import off the main thread), and appends the file's section to the report **as soon as it is done** (so a crash or hang leaves a usable partial report; write the report atomically per section or append-flush).
2. The report (Markdown, read through VoiceOver and a braille display: headings and bullet lists, one fact per line, no tables, no emoji, no color words as the only signal; say `refused`, `warning`, `imported` in words):
   - `# Corpus report`, the folder name (its last path component only, not the full path), the date, the macOS version, the app build, the counts line `N files: A imported, B with warnings, C refused, D skipped`.
   - `## <relative path>` per file, then bullets: `Format:` (as the importer detects it), `Result:` (`imported`, `imported with warnings`, `refused`, `skipped`, `timed out`), `Title:`, `Author:`, `Text length:` (UTF-16 units and words), `Chapters:`, `Import time:` (seconds, one decimal), `Warnings:` (the report message, when chapters were left out), `Refusal:` (the failure message verbatim), `Headings:` count, then the headings as a nested list `- level 2: Text` (cap 200, then `and N more`), `First lines:` the first 5 non-empty lines of the reading text, each cut at 120 characters, for audio books the track count and total duration.
   - the file's report ends with a line `Checksum: <digest>` (the same digest as the golden dump), so two reports on two Macs or two builds can be compared with `diff`.
3. `Scripts/test/corpus-report.sh <folder> [report.md]` (bash, header comment doubling as `-h`, style of `Scripts/perf-baselines.sh`): checks the folder exists, picks the report path (default `${TMPDIR}textmouth-corpus-report.md`), runs `python3 "$(dirname "$0")/run-area.py" --classes CorpusReportTests --env TEXTMOUTH_CORPUS_DIR=<absolute folder> --env TEXTMOUTH_CORPUS_REPORT=<absolute report>`, then prints the report's path and its counts line (the line starting `N files:`), and exits with the runner's status. The script only ever reads the folder it is given.
4. `CorpusReportFormatTests` in the same file or `CorpusReportFormatTests.swift`: unit tests of the report builder on synthetic values (no import): a section for each result kind (imported, warnings, refused, skipped Ogg, timed out); headings capped at 200 with the `and N more` line; first lines cut at 120 characters and at 5 lines; the counts line; a path with a space or accents; the report never contains the full path of the folder (use a fake folder name containing `/Users/someone/secret`).
5. A test that proves the originals are safe: build a small corpus folder (made inside the test's own sandbox, never a real folder) holding a TXT, a Markdown file, and a damaged EPUB (`Not a ZIP archive.`), run the report's walk on it, and check afterwards that every original is still there with the same bytes and that the sandbox holds no staged leftovers. (`FileImportService` never touches the source file itself and the deletion of originals is a library-UI decision, so a direct call cannot delete one; the test pins that, and the copy-first rule keeps it true if that ever changes.)

## Tests to run

`CorpusReportFormatTests` and `CorpusReportTests` (the opt-in test skips cleanly when the variable is unset: show the skip line). Then run it for real once on `TestData` (`Scripts/test/corpus-report.sh TestData <scratch>/report.md`), read the report, and describe three things you checked in it.

## Do not

Edit `DocumentDump.swift` or any existing test. Read `~/.TextMouth` or any folder other than the one given. Decode Ogg. Let a test trap.

## Commits

1. The report builder with `CorpusReportFormatTests`.
2. `CorpusReportTests` (the opt-in run) and the sandbox test.
3. `Scripts/test/corpus-report.sh`.

## Report (at most 15 lines)

Branch; commits; exact result lines; the three things you checked in the TestData report; how long the TestData run took; findings.
