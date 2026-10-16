# testkit/fuzz: an import fuzz sweep, damaged copies of every document

Slug `testkit-fuzz`. Branch `testkit/fuzz`, made from `team/testkit` AFTER `testkit/runner` was integrated (it is: `Scripts/test/run-area.py` exists). You build; at most two builders run at once. Read `teams-common.md`'s worker's part first.

## Why

A book that makes TextMouth crash or hang on import is the worst failure for a blind user: there is no way to see what went wrong, and the app may have to be killed. Today a few targeted tests hand the parsers a truncated EPUB, a misencoded feed, a malformed XML part. Nobody has asked, systematically, what every importer does with a damaged copy of every kind of file it reads. The user said "reusable testing scripts for anything you can test outside of VoiceOver": a seeded, repeatable sweep that damages each TestData document in a dozen ways and imports every copy, checking the invariants that matter (no crash, no hang, a clean refusal or a readable book, nothing half-published, the original untouched), is that. A crash it finds is a real bug report with a seed to reproduce it.

## Ground truth

- Import entry point: `FileImportService.importFileWithReport(from:toFolder:observer:)` (TextMouth/Services/FileImportService.swift:776) returns an `ImportedBook` (`book`, `report`) or throws an `ImportFailure` (TextMouth/Services/ImportFailure.swift) naming the file and the failed step. The package is staged hidden (`ImportStaging.swift`) and published only after every step succeeded; the source file is never touched. `BookContentAnalysisService.load(book:)` reads an imported book as the reader does.
- `TextPipelineFixtures.imported(_:for:)` (TextMouthProductionTests/TextPipelineFixtures.swift:749) imports into the hosted sandbox library and removes the package at teardown; `TextPipelineFixtures.testDataBookNames` (:82) names the documents; `requireFile(_:)` (LegacyScenarioHarness.swift:95) finds a TestData file. Reuse them. PDFs `test_formatted.pdf` and `test_with_outline.pdf` are small; PDF import can use Vision OCR, so include PDFs only when `TEXTMOUTH_IMPORT_FUZZ_PDF=1`.
- NEVER decode Ogg in the test host (AGENTS.md's B06 lesson). The sweep imports documents only, no audio files.
- `IntegrationImportTests.swift:70-85` shows a truncated EPUB import (the failure message format, the folder checks `folder.entries()`), `ImportStagingTests.swift` and `StagedImportTests.swift` show how a staged leftover is detected.
- Opt-in classes skip with `XCTSkip` when their variable is unset; `Scripts/test/run-area.py --classes X --env NAME=VALUE` runs them.

## What you build

1. `TextMouthProductionTests/ImportFuzzMutator.swift`: a pure, seeded mutator. A tiny deterministic generator (SplitMix64) so a seed reproduces a case exactly on any Mac. `enum ImportFuzzMutation` with cases for: truncate to 10, 25, 50, 75, 90, 99 percent; empty file; flip 1, 8, or 64 random bytes; zero a 1 KB window; delete a 1 KB window; duplicate a 1 KB window; prepend 1 KB of random bytes; append 1 KB of random bytes; for ZIP-based documents (EPUB, DOCX, ZIP) corrupt the last 64 bytes (the central directory) and corrupt the first local header; for text-like documents (TXT, Markdown, HTML) insert NUL bytes, insert invalid UTF-8 (0xC0 0xAF, 0xFF), and add a 1 MB line; for HTML/XHTML nest 5,000 `<div>` levels. `func apply(_ mutation, to data: Data, fileName: String, seed: UInt64) -> Data` returns the damaged bytes, and `func applicable(to fileName: String) -> [ImportFuzzMutation]` filters by document type. Every case has a stable id string: `alice.epub#flip8#seed=…`.
2. `TextMouthProductionTests/ImportFuzzMutatorTests.swift`: always-on unit tests: the same seed gives identical bytes; a different seed differs; truncation lengths are exact; flips change exactly the stated number of bytes (or fewer only by coincidence of the same value: use bytes that differ); empty is empty; window operations keep or change the length as stated; ZIP corruption touches only the last 64 / first header bytes; applicability filters (no ZIP mutations for a TXT); case ids are stable text.
3. `TextMouthProductionTests/ImportFuzzTests.swift`: `final class ImportFuzzTests: XCTestCase` with `testImportDamagedCopiesOfEveryDocument`, skipping with `XCTSkip("Set TEXTMOUTH_IMPORT_FUZZ=1 to run the import fuzz sweep.")` unless `TEXTMOUTH_IMPORT_FUZZ` is `1`. Variables: `TEXTMOUTH_IMPORT_FUZZ_SEED` (default 20261016), `TEXTMOUTH_IMPORT_FUZZ_DOCS` (comma-separated file names, default every `testDataBookNames` entry under 300 KB, so not pride.txt or frankenstein.html), `TEXTMOUTH_IMPORT_FUZZ_PDF`, `TEXTMOUTH_IMPORT_FUZZ_SECONDS` (per-import watchdog, default 60), `TEXTMOUTH_IMPORT_FUZZ_REPORT` (report path; default in the sandbox, and print `IMPORT FUZZ REPORT: <path>`). For each document and each applicable mutation: write the damaged bytes to a file of its own in a sandbox folder (named so the extension still says what it should be: the importer decides by extension), print `FUZZ CASE <id>` and flush stdout BEFORE importing (if the host crashes, the log's last case is the culprit), import on a background thread under the watchdog, and classify the case `imported`, `refused`, or `timed out`. After it, check the invariants and record every violation by case id:
   - the damaged file's bytes are unchanged and the file is still there;
   - a refused case published no package (the library folder gained no book) and left no staged leftover (find what `ImportStaging` leaves and look for it);
   - an imported case loads: `BookContentAnalysisService.load(book:)` does not throw, and the book is either non-empty or its report says why;
   - a timed-out case is a violation (and the sweep goes on; the abandoned thread may finish later).
   After each case append its line to the report (`imported|refused|timed out`, the refusal message for a refusal) and flush. The test fails only on invariant violations (list them all in one failure, with their ids and the command that reproduces one: `Scripts/test/import-fuzz.sh --docs alice.epub --seed N`); a crash is the host's, which the log's last `FUZZ CASE` identifies. Clean the case's files and package at once to keep the sandbox small.
4. `Scripts/test/import-fuzz.sh [--seed N] [--docs a.epub,b.docx] [--pdf] [--seconds N] [report.md]` (bash, header comment doubling as `-h`, style of `Scripts/perf-baselines.sh`): runs `python3 "$(dirname "$0")/run-area.py" --classes ImportFuzzTests --env TEXTMOUTH_IMPORT_FUZZ=1 ...` with the other variables from its options, then prints the report's path and its counts line, and, if the run crashed (the report has no final `done` line), prints the last case id and the command to reproduce it. Say in the header that a crash of the test host is a finding, not a script failure, and that the user will see a crash dialog if one happens.

## Tests to run

`ImportFuzzMutatorTests`, then `ImportFuzzTests` (skip line shown), then ONE real sweep with the defaults through the script. Report the counts; if it finds a crash, hang, or invariant violation, do not fix the app: reproduce it once with the seed, post a finding (`bbs post testkit-fuzz --tag finding --file <app file> --topic "..."`) with the case id and the reproduction command, add that case to a `knownIssues` dictionary in `ImportFuzzTests` (id to a one-line note, so the sweep stays green and the issue stays visible: a known issue that now passes fails the test with `remove it from the list`), and carry on. If a crash kills the sweep, add the crashing case to a `skippedCases` set (never to be run, with the note) and rerun; list all of them in your report.

## Do not

Edit the app or any existing test. Decode Ogg. Read `~/.TextMouth`. Let a test trap. Run the sweep against the user's own files (only TestData copies). Make the always-on tests slow (under 2 seconds in all).

## Commits

1. `ImportFuzzMutator` + `ImportFuzzMutatorTests` (+ `project.pbxproj` from `xcodegen`).
2. `ImportFuzzTests` and the script.
3. Known issues, if any, with their findings.

## Report (at most 15 lines)

Branch; commits; exact result lines; the sweep's counts line and runtime; every finding (case id, reproduction, one-line symptom); what you could not verify.
