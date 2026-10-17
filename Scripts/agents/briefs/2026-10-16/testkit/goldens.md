# testkit/goldens: readable golden files for every document in TestData

Slug `testkit-goldens`. Branch `testkit/goldens`, made from `team/testkit` (after `testkit/runner` is integrated, so `Scripts/test/run-area.py` exists: if it does not, build the Swift part first and rebase for the script). You build; at most two builders run at once. Read `teams-common.md`'s worker's part first.

## Why

A change to a parser, the text pipeline, or heading detection can alter what the user hears for a book without any test noticing. `TextPipelineGoldenTests.swift` already pins 64-bit digests of content.md and of each reading, but a digest says only "something changed", not what. This task adds the readable half: for each document in `TestData/`, a small text file recording the facts a person would check (title, author, headings with levels, text length, a checksum, the first and last 300 characters, audio tracks), and a test that names every difference. A deliberate change is recorded with one command. It is the safety net under the parsers for everyone else's work tonight.

## Ground truth (read these line ranges and nothing more)

- `TextMouthProductionTests/TextPipelineFixtures.swift:21-91` (`digest`, `testDataBookNames`, `testDataBooks()`), `:745-753` (`imported(_:for:)`: imports a file into the hosted tests' sandbox library and removes the package at teardown). Reuse these; do not write another importer.
- `TextMouthProductionTests/TextPipelineGoldenTests.swift:1-24, 95-130` (how a book is imported and loaded: `try TextPipelineFixtures.imported(url, for: self)`, then `try BookContentAnalysisService.load(book: book)` giving `.content.chapters` (`Chapter`: `title`, `text`, `headings`), `.index` (`BookContentIndex`: `totalWordCount`, `totalCharacterCount`, `totalAudioDuration`), `.audioSegments` (`[AudioSegment]?`: `title`, `clips` of `AudioClip(file, startTime, endTime)`).
- `TextMouth/Models/DocumentContent.swift:90-100, 155-170` (`Chapter`, `Heading`: `level` 1 to 6, `text`, `characterOffset`), `TextMouth/Models/Book.swift:100-110` (`title`, `author`, `format`), `TextMouth/Services/FileImportService.swift:63-70` (`ImportedBook.report.message` for chapters left out).
- `LegacyScenarioHarness.swift:88-110`: `requireFile(_:)`, `testFilePath(_:)` find files in `TestData/` from `#filePath`; do the same for `TestData/golden/`.
- **`.gitignore` ignores `*.txt` and `*.md`.** Name the goldens `<document file name>.golden` (`alice.epub.golden`) so git sees them.
- The documents (named, not found by scanning, as the existing golden test does: some checkouts hold more): `TextPipelineFixtures.testDataBookNames` (10 files) plus the PDFs `test_formatted.pdf` and `test_with_outline.pdf`. Skip Ogg files (never decode Ogg in the test host: AGENTS.md's B06 lesson), `TestData/feeds/`, and `TestData/audio/`. The two large optional DAISY audio books (`optionalTestDataBookNames`) are compared only when present AND a golden for them exists; never record them.
- PDF text comes from PDFKit and Vision and changes with the macOS version (the existing golden test leaves PDFs out for this reason). A PDF's golden records `macOS: <ProcessInfo operatingSystemVersion major.minor>`; on a Mac whose major version differs, the PDF comparison is skipped with an `XCTSkip` whose message says how to re-record. All other documents are compared on every Mac.
- `SourceScanTestSupport.swift` and `AppSourceFile.folder` show the `#filePath` idiom for finding the source tree.

## What you build

1. `TextMouthProductionTests/DocumentDump.swift`, a support type (new file; `xcodegen`):
   - `struct DocumentDump`: built from an imported `Book` plus its loaded `BookContentAnalysisService.Result` and the import report. Fields: file name, format, title, author, chapter count, word count, text length in UTF-16 units, a text checksum (`TextPipelineFixtures.digest` of the reading text, which is the chapters' `text` joined with `"\n"`; say so in the comment), the headings (level, text, and the title of the chapter each lies in is NOT needed; offsets are NOT recorded: the checksum covers text and position), the first 300 and last 300 characters of the reading text (newlines shown as `\n`, so each sample is one line), the report message when chapters were left out, and for books with audio: the segment list (`title | file | start-end seconds`) and `totalAudioDuration` rounded to 0.01 s, with no playback.
   - `func rendered() -> String`: the golden format, line-oriented, LF, UTF-8, final newline. A header `# TextMouth document golden, format 1`, then `key: value` lines, then the headings as `heading: <level> | <text>` lines and tracks as `track: ...` lines. Plain words; sections in a fixed order.
   - `static func differences(golden: String, actual: String) -> [String]`: every difference named, one sentence each, in words a reader can act on: `title: golden is "A", now "B"`, `text length: golden 148907, now 148900 (7 fewer)`, `headings: golden has 14, now 13`, `heading 3: golden "2 | Down the Rabbit-Hole", now "1 | Down the Rabbit-Hole"`, `heading 9 only in golden: ...`. A heading difference lists at most 10 and then says how many more. Compare by key, not by raw line, so unrelated lines do not shift the report.
2. `TextMouthProductionTests/DocumentGoldenTests.swift`: `final class DocumentGoldenTests: XCTestCase`:
   - `testEveryDocumentMatchesItsGolden`: for each non-PDF document, import, dump, compare; one `XCTFail` per document that differs, listing its differences, ending with the sentence `If the change is deliberate, record it with: Scripts/test/update-goldens.sh`. A document that cannot be imported fails by name and the rest are still compared. A missing golden fails with that same command.
   - `testPDFsMatchTheirGoldensOnTheMacTheyWereRecordedOn`: the same for the two PDFs, with the macOS rule above.
   - `testEveryGoldenFileHasADocument`: a golden whose document is not in the named list and not an optional absent one fails (stale goldens are removed in the same commit as their document).
   - Update mode: when the environment variable `TEXTMOUTH_UPDATE_GOLDENS` is `1`, the first two tests do not compare: they write each golden into the SOURCE tree (`TestData/golden/`, found from `#filePath`) and print `GOLDEN RECORDED: <name>` per file, then pass. Write atomically; never write outside `TestData/golden/`.
3. `TextMouthProductionTests/DocumentDumpTests.swift`: `final class DocumentDumpTests: XCTestCase`, unit tests of the dump and the differences on small synthetic `DocumentDump` values (no import): rendering is stable and round-trips through `differences` with none; each field's change is named in the words above; a changed heading list names the heading; a long heading difference list is cut at 10 and counted; newlines in samples are escaped; two dumps equal by every field produce no difference; a missing key in the golden is named.
4. `TestData/golden/*.golden`: recorded by running the update mode once, reviewed by you (read each; check the heading lists look right for the book; a golden that looks wrong is a finding, not something to hide).
5. `Scripts/test/update-goldens.sh` (bash, header comment doubling as `-h`, in the style of `Scripts/perf-baselines.sh`): runs `python3 "$(dirname "$0")/run-area.py" --classes DocumentGoldenTests --env TEXTMOUTH_UPDATE_GOLDENS=1`, then prints `git status --short TestData/golden` and says `Review the diff of TestData/golden, then commit it with the change it records.` Exit status is the runner's.

## Tests to run

`DocumentDumpTests` and `DocumentGoldenTests` (one xcodebuild, both classes; the build folder is your own). Run `DocumentGoldenTests` a second time without the update variable after recording, and show it passes. Also run `TextPipelineGoldenTests` once to prove you changed nothing it depends on.

## Do not

Edit `TextPipelineFixtures.swift`, `TextPipelineGoldenTests.swift`, or any existing test or fixture. Record the large optional books. Decode an Ogg file. Touch `~/.TextMouth`. Let a test trap (no `[0]` without a guard, no `!`).

## Commits

1. `DocumentDump` and `DocumentDumpTests` (+ `project.pbxproj` from `xcodegen`).
2. `DocumentGoldenTests` and the recorded goldens.
3. `Scripts/test/update-goldens.sh`.

## Report (at most 15 lines)

Branch; commits; the exact result lines of your last runs; the number of goldens and any one that looks wrong; how long `DocumentGoldenTests` takes; decisions (what you recorded for audio packages).
